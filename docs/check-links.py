#!/usr/bin/env python3
"""Check relative links and #anchors in all tracked Markdown files.

Usage: python3 docs/check-links.py   (run from the repository root)
Anchors follow GitHub's slug rules. External links are not checked.
"""
import re
import subprocess
import sys
from pathlib import Path


def slug(heading, seen):
    text = re.sub(r"`", "", heading.strip())
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text).lower()
    text = re.sub(r"[^\w\- ]", "", text).replace(" ", "-")
    n = seen.get(text, 0)
    seen[text] = n + 1
    return text if n == 0 else f"{text}-{n}"


def strip_fences(lines):
    fence = False
    for line in lines:
        if line.startswith("```"):
            fence = not fence
            yield None
        else:
            yield None if fence else line


def anchors(path):
    seen, out = {}, set()
    for line in strip_fences(path.read_text().split("\n")):
        if line and (m := re.match(r"#{1,6} +(.*)", line)):
            out.add(slug(m.group(1), seen))
    return out


def main():
    files = subprocess.run(["git", "ls-files", "*.md"], capture_output=True, text=True, check=True).stdout.split()
    files = [Path(f) for f in files if Path(f).exists() and not f.startswith("docs/api/")]
    cache, bad, total = {}, [], 0
    for f in files:
        for n, line in enumerate(strip_fences(f.read_text().split("\n")), 1):
            if not line:
                continue
            line = re.sub(r"`[^`]*`", "", line)
            for m in re.finditer(r"\]\(([^)\s]+)\)", line):
                target = m.group(1)
                if re.match(r"[a-z]+:", target):
                    continue
                total += 1
                path, _, frag = target.partition("#")
                dest = (f.parent / path).resolve() if path else f.resolve()
                if not dest.exists():
                    bad.append(f"{f}:{n}: missing file {target}")
                elif frag and dest.suffix == ".md":
                    if dest not in cache:
                        cache[dest] = anchors(dest)
                    if frag not in cache[dest]:
                        bad.append(f"{f}:{n}: missing anchor {target}")
    for b in bad:
        print(b)
    print(f"{len(files)} files, {total} relative links, {len(bad)} broken")
    sys.exit(1 if bad else 0)


main()
