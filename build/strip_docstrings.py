#!/usr/bin/env python3
"""Remove module/class/function docstrings from Python files, in place.

Used before Cython compilation so the compiled .so carries no human-readable prose explaining the
logic (Cython embeds docstrings into the binary otherwise). Only the leading string-literal
statement of each module/class/function is removed; if that leaves an empty body a `pass` is
inserted. Code is otherwise preserved. Files that fail to parse are left untouched.

With --unsafe-list <file>, it also appends to <file> the path of every file that cannot be compiled
safely (see super_in_comprehension); --no-strip only does that check.

Usage: strip_docstrings.py [--no-strip] [--unsafe-list <file>] <file.py> [<file.py> ...]
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


COMPREHENSIONS = (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)


def super_in_comprehension(tree):
    """True if a zero-argument super() sits inside a comprehension or generator expression: valid
    Python, but once compiled by Cython it raises "RuntimeError: super(): no arguments" when called."""
    return any(isinstance(sub, ast.Call) and isinstance(sub.func, ast.Name) and sub.func.id == 'super'
               and not sub.args
               for comp in ast.walk(tree) if isinstance(comp, COMPREHENSIONS) for sub in ast.walk(comp))


def main(paths, strip=True, unsafe_list=None):
    changed = 0
    for path in paths:
        try:
            src = open(path, encoding="utf-8").read()
            tree = ast.parse(src)
        except (OSError, SyntaxError, ValueError):  # ValueError: not UTF-8 / null bytes
            continue
        if unsafe_list and super_in_comprehension(tree):
            with open(unsafe_list, "a", encoding="utf-8") as f:
                f.write(path + "\n")
        if not strip:
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
    if strip:
        print(f"strip_docstrings: rewrote {changed}/{len(paths)} files")


if __name__ == "__main__":
    args, strip, unsafe_list = sys.argv[1:], True, None
    if args[:1] == ["--no-strip"]:
        strip, args = False, args[1:]
    if args[:1] == ["--unsafe-list"]:
        unsafe_list, args = args[1], args[2:]
    main(args, strip=strip, unsafe_list=unsafe_list)
