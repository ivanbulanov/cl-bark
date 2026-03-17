#!/usr/bin/env python3
"""Post-process Staple HTML output for cl-bark API docs."""
import re, sys, textwrap

path = sys.argv[1]
html = open(path).read()

# Fix title (Staple titleizes "cl-bark" -> "Cl Bark")
html = html.replace("<title>Cl Bark</title>", "<title>cl-bark</title>")
html = html.replace("<h1>cl bark</h1>", "<h1>cl-bark</h1>")

# Remove SBCL source-transform entries (internal compiler noise)
html = re.sub(
    r"<li>\s*<article[^>]*id=\"SOURCE-TRANSFORM[^\"]*\".*?</article>\s*</li>",
    "", html, flags=re.DOTALL)

# Strip leading indentation from docstrings in <pre> blocks.
# CL docstrings have an unindented first line, then continuation lines
# indented to align with the opening quote in source. Strip that indent.
def dedent_pre(m):
    text = m.group(1)
    lines = text.split("\n")
    if len(lines) < 2:
        return m.group(0)
    # Find minimum indentation of non-empty continuation lines
    indents = [len(l) - len(l.lstrip()) for l in lines[1:] if l.strip()]
    if not indents:
        return m.group(0)
    trim = min(indents)
    if trim == 0:
        return m.group(0)
    stripped = [lines[0]] + [l[trim:] if len(l) > trim else l for l in lines[1:]]
    return "<pre>" + "\n".join(stripped) + "</pre>"

html = re.sub(r"<pre>(.*?)</pre>", dedent_pre, html, flags=re.DOTALL)

# Rename SBCL's generic "INSTANCE" parameter to the struct name for accessors.
# defstruct generates accessors with (INSTANCE) — replace with the struct name.
STRUCT_PREFIXES = {
    "BUFFER-ENTRY-": "ENTRY",
    "CAPTURED-ERROR-": "CAPTURED-ERROR",
    "WINDOWED-COUNTER-": "COUNTER",
    "CONSISTENT-SAMPLER-": "SAMPLER",
}

def fix_accessor_param(m):
    article = m.group(0)
    func_id = m.group(1)
    for prefix, param_name in STRUCT_PREFIXES.items():
        if prefix in func_id:
            return article.replace(
                '<li class="argument">INSTANCE</li>',
                f'<li class="argument">{param_name}</li>')
    return article

html = re.sub(
    r'<article class="definition function callable" id="(FUNCTION BARK:[^"]+)".*?</article>',
    fix_accessor_param, html, flags=re.DOTALL)

open(path, "w").write(html)
