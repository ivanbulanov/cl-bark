(in-package #:bark-tests)

(5am:in-suite bark-tests)

(5am:test test-save-hook-stops-writer-and-init-hook-restarts-it
  "The save hook drains and joins the writer; the init hook starts a new one and logging resumes."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 64)))
    (unwind-protect
         (progn
           (bark::deliver-line ao "before-save")
           (bark::save-live-outputs)
           (5am:is (eq :stopped (bark::async-output-state ao)))
           (5am:is-false (bt:thread-alive-p (bark::async-output-thread ao)))
           (5am:is (search "before-save" (get-output-stream-string out)))
           (bark::restart-saved-outputs)
           (5am:is (eq :running (bark::async-output-state ao)))
           (5am:is-true (bt:thread-alive-p (bark::async-output-thread ao)))
           (bark::deliver-line ao "after-restore")
           (5am:is-true (bark::flush-async-output ao))
           (5am:is (search "after-restore" (get-output-stream-string out))))
      (bark::stop-async-output ao))))

(5am:test test-stopped-output-stays-stopped-across-save-and-restore
  "An output the user stopped is not restarted by the init hook."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 64)))
    (bark::stop-async-output ao)
    (bark::save-live-outputs)
    (bark::restart-saved-outputs)
    (5am:is (eq :stopped (bark::async-output-state ao)))
    (5am:is-false (bark::async-output-running ao))
    (bark::deliver-line ao "sync")
    (5am:is (search "sync" (get-output-stream-string out)))))

(5am:test test-save-and-init-hooks-are-idempotent
  "Calling either hook twice neither fails nor starts a second writer."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 64)))
    (unwind-protect
         (progn
           (bark::save-live-outputs)
           (bark::save-live-outputs)
           (5am:is (eq :stopped (bark::async-output-state ao)))
           (bark::restart-saved-outputs)
           (let ((thread (bark::async-output-thread ao)))
             (bark::restart-saved-outputs)
             (5am:is (eq thread (bark::async-output-thread ao)))
             (5am:is (eq :running (bark::async-output-state ao)))))
      (bark::stop-async-output ao))))

(5am:test test-save-hook-and-concurrent-producers-lose-no-lines
  "Lines logged while the hooks run are written, none are lost."
  (let* ((out (make-string-output-stream))
         (ao (bark::make-async-output out :capacity 4096))
         (producer (bt:make-thread
                    (lambda ()
                      (dotimes (i 200)
                        (bark::deliver-line ao (format nil "line-~d" i))))
                    :name "producer")))
    (unwind-protect
         (progn
           (bark::save-live-outputs)
           (bark::restart-saved-outputs)
           (bt:join-thread producer)
           (bark::stop-async-output ao)
           (let ((text (get-output-stream-string out)))
             (dotimes (i 200)
               (5am:is (search (format nil "line-~d~%" i) text)))))
      (bark::stop-async-output ao))))

(5am:test test-restart-key-finds-standard-streams-by-name
  "The standard streams are recorded by name and looked up again after restore, because SBCL recreates them."
  (5am:is (eq :stdout (bark::restart-key sb-sys:*stdout*)))
  (5am:is (eq :stderr (bark::restart-key sb-sys:*stderr*)))
  (5am:is (null (bark::restart-key *standard-output*)))
  (5am:is (null (bark::restart-key (make-string-output-stream))))
  (let ((ao (bark::make-async-output (make-string-output-stream) :capacity 8)))
    (unwind-protect
         (progn
           (setf (bark::async-output-restart-key ao) :stdout)
           (5am:is (eq sb-sys:*stdout* (bark::restored-stream ao)))
           (setf (bark::async-output-restart-key ao) :stderr)
           (5am:is (eq sb-sys:*stderr* (bark::restored-stream ao))))
      (bark::stop-async-output ao))))

(5am:test test-file-stream-is-reopened-for-appending-after-restore
  "A file stream does not survive a save; the init hook reopens the file for appending."
  (uiop:with-temporary-file (:stream s :pathname path :keep t :direction :output)
    (unwind-protect
         (let ((ao (bark::make-async-output s :capacity 64)))
           (unwind-protect
               (progn
                 (bark::deliver-line ao "first")
                 (bark::save-live-outputs)
                 (5am:is (equal (pathname s) (second (bark::async-output-restart-key ao))))
                 ;; Simulate the descriptor being gone in the new process.
                 (close s)
                 (bark::restart-saved-outputs)
                 (5am:is (not (eq s (bark::async-output-stream ao))))
                 (bark::deliver-line ao "second")
                 (5am:is-true (bark::flush-async-output ao)))
             (bark::stop-async-output ao))
           (let ((text (uiop:read-file-string path)))
             (5am:is (search "first" text))
             (5am:is (search "second" text))))
      (ignore-errors (delete-file path)))))

(5am:test test-dropped-count-is-cumulative-and-does-not-reset
  "dropped-count sums ring and block drops, survives drop warnings, and resets nothing."
  (let* ((out (make-string-output-stream))
         (logger (bark:make-logger :output out :capacity 64))
         (ao (bark::logger-output logger)))
    (unwind-protect
         (progn
           (5am:is (= 0 (bark:dropped-count logger)))
           (5am:is (= 0 (bark:dropped-count nil)))
           (atomics:atomic-incf (bark::ring-buffer-dropped (bark::async-output-ring ao)) 3)
           (atomics:atomic-incf (bark::async-output-block-dropped ao) 2)
           (5am:is (= 5 (bark:dropped-count logger)))
           (5am:is (= 5 (bark:dropped-count logger)))
           (bark::emit-drop-warning ao)
           (5am:is (= 5 (bark:dropped-count logger)))
           (atomics:atomic-incf (bark::ring-buffer-dropped (bark::async-output-ring ao)) 1)
           (5am:is (= 6 (bark:dropped-count logger))))
      (bark:stop logger))))

(5am:test test-real-save-lisp-and-die-and-restore-in-child-sbcl
  "A child SBCL starts an async logger on stdout and on a file, logs, saves a
core, and a second child runs the core: the save is not refused and logging
resumes on both streams. Skipped when sbcl cannot be run or cl-bark cannot be
loaded in the child."
  (block child-test
    (let ((sbcl (ignore-errors (uiop:run-program '("which" "sbcl") :output '(:string :stripped t))))
          (system-dir (ignore-errors (asdf:system-source-directory :cl-bark))))
      (unless (and sbcl (plusp (length sbcl)) system-dir)
        (5am:skip "child sbcl test skipped: no sbcl on PATH or cl-bark source directory unknown")
        (return-from child-test))
      (let* ((dir (uiop:ensure-directory-pathname
                   (format nil "~a/bark-save-test-~36r/"
                           (string-right-trim "/" (namestring (uiop:temporary-directory)))
                           (random (expt 36 8) (make-random-state t)))))
             (script (merge-pathnames "build.lisp" dir))
             (core (merge-pathnames "child.core" dir))
             (log-file (merge-pathnames "child.log" dir)))
        (ensure-directories-exist dir)
        (unwind-protect
             (progn
               (with-open-file (s script :direction :output :if-exists :supersede)
                 (let ((*print-readably* nil) (*package* (find-package :cl-user)))
                   (format s "~s~%" `(push ,system-dir asdf:*central-registry*))
                   (format s "~s~%" '(asdf:load-system :cl-bark))
                   (format s "~s~%" '(progn (write-line "BARK-LOADED") (finish-output)))
                   (format s "~s~%" `(defvar cl-user::*file-stream*
                                       (open ,(namestring log-file) :direction :output
                                                                    :if-exists :supersede :external-format :utf-8)))
                   (format s "~s~%" '(defvar cl-user::*logger*
                                      (bark:make-logger
                                       :output (bark:make-tee
                                                (list (list :stream sb-sys:*stdout*)
                                                      (list :stream cl-user::*file-stream*))))))
                   (format s "~s~%" '(bark:info cl-user::*logger* "child-before-save"))
                   (format s "~s~%" '(bark:flush cl-user::*logger*))
                   (format s "~s~%"
                           `(sb-ext:save-lisp-and-die
                             ,(namestring core)
                             :toplevel (lambda ()
                                         (bark:info cl-user::*logger* "child-after-restore")
                                         (bark:flush cl-user::*logger*)
                                         (bark:stop cl-user::*logger*)
                                         (sb-ext:exit :code 0 :abort nil))))))
               (let* ((out1 (make-string-output-stream))
                      (err1 (make-string-output-stream))
                      (code1 (ignore-errors
                              (nth-value 2 (uiop:run-program
                                            (list sbcl "--noinform" "--non-interactive" "--load" (namestring script))
                                            :output out1 :error-output err1 :ignore-error-status t))))
                      (text1 (get-output-stream-string out1)))
                 (unless (search "BARK-LOADED" text1)
                   (5am:skip "child sbcl test skipped: cl-bark did not load in the child: ~a"
                             (get-output-stream-string err1))
                   (return-from child-test))
                 (5am:is (eql 0 code1) "building the core failed: ~a" (get-output-stream-string err1))
                 (5am:is (probe-file core) "the core was not written")
                 (when (probe-file core)
                   (5am:is (search "child-before-save" text1))
                   (let* ((out2 (make-string-output-stream))
                          (err2 (make-string-output-stream))
                          (code2 (nth-value 2 (uiop:run-program
                                               (list sbcl "--core" (namestring core) "--noinform")
                                               :output out2 :error-output err2 :ignore-error-status t)))
                          (text2 (get-output-stream-string out2))
                          (file-text (uiop:read-file-string log-file)))
                     (5am:is (eql 0 code2) "running the core failed: ~a" (get-output-stream-string err2))
                     (5am:is (search "child-after-restore" text2)
                             "stdout lacks the line logged after restore: ~s" text2)
                     (5am:is (search "child-before-save" file-text))
                     (5am:is (search "child-after-restore" file-text)
                             "file lacks the line logged after restore: ~s" file-text)))))
          (ignore-errors (uiop:delete-directory-tree dir :validate t)))))))
