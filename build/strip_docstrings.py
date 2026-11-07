#!/usr/bin/env python3
"""Remove module/class/function docstrings from Python files, in place.

Used before Cython compilation so the compiled .so carries no human-readable prose explaining the
logic (Cython embeds docstrings into the binary otherwise). Only the leading string-literal
statement of each module/class/function is removed; if that leaves an empty body a `pass` is
inserted. Code is otherwise preserved. Files that fail to parse are left untouched.

Usage: strip_docstrings.py <file.py> [<file.py> ...]
"""
import ast
import sys


class DocstringStripper(ast.NodeTransformer):
    def _strip(self, node):
        self.generic_visit(node)
        body = node.body
        if (body and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)):
            body = body[1:] or [ast.Pass()]
            node.body = body
        return node

    visit_Module = _strip
    visit_ClassDef = _strip
    visit_FunctionDef = _strip
    visit_AsyncFunctionDef = _strip


def main(paths):
    changed = 0
    for path in paths:
        try:
            src = open(path, encoding="utf-8").read()
            tree = ast.parse(src)
        except (OSError, SyntaxError):
            continue
        new = DocstringStripper().visit(tree)
        ast.fix_missing_locations(new)
        try:
            out = ast.unparse(new)
        except Exception:
            continue  # keep the original if unparsing is not possible
        # sanity: the rewritten source must still parse
        try:
            ast.parse(out)
        except SyntaxError:
            continue
        open(path, "w", encoding="utf-8").write(out)
        changed += 1
    print(f"strip_docstrings: rewrote {changed}/{len(paths)} files")


if __name__ == "__main__":
    main(sys.argv[1:])
