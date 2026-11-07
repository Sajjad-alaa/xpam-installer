#!/bin/sh
# Compile a Python source tree to native extension modules (.so) with Cython, in place.
#
# Usage: compile_py.sh <root-dir>
#
# Every .py under <root-dir> is turned into a compiled .so and the .py is removed, EXCEPT the
# files that Python / Django must be able to read as source (see the keep-list below) and any file
# Cython cannot compile (those are left as .py so the application still runs). The result imports
# and behaves exactly like the source tree but ships no readable source for the compiled modules.
#
# Kept as source on purpose:
#   - every __init__.py            (package markers; keeping them as source avoids edge cases where
#                                    a package initializer must be plain source)
#   - */migrations/*.py            (Django reads and rewrites migration source)
#   - jumpserver/settings/*.py     (settings are read and sometimes exec'd dynamically)
#   - manage.py, asgi.py, wsgi.py  (entry points)
#   - conftest.py / tests          (not sensitive; excluded from compilation)
set -eu

ROOT=${1:?usage: compile_py.sh <root-dir>}
PYBIN=${PYBIN:-/opt/py3/bin/python}
CYTHONIZE=${CYTHONIZE:-${PYBIN%/python}/cythonize}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}

cd "$ROOT"

list_targets() {
  find . -name '*.py' \
    ! -name '__init__.py' \
    ! -name '__main__.py' \
    ! -name 'manage.py' \
    ! -name 'asgi.py' \
    ! -name 'wsgi.py' \
    ! -name 'conftest.py' \
    ! -path '*/migrations/*' \
    ! -path './jumpserver/settings/*' \
    ! -name 'tests.py' \
    ! -name 'test_*.py' \
    ! -path '*/tests/*' \
    -print0
}

TOTAL=$(list_targets | tr -d -c '\0' | wc -c)
echo "compile_py: $TOTAL modules to compile under $ROOT (jobs=$JOBS)"

# Cython derives a module's fully-qualified name by walking UP the directory tree while an
# __init__.py exists. The source root is on sys.path (apps are imported top-level, e.g. "orgs"),
# but it also carries a trivial __init__.py; if left in place Cython would bake the root dir name
# into every module (e.g. "work.orgs.models"), which breaks Django's app_label lookup. Move the
# root __init__.py aside for the duration of the compile and restore it afterwards (it is kept as
# source either way). Nested app packages keep their __init__.py, so names stay correct.
ROOT_INIT=""
if [ -f "$ROOT/__init__.py" ]; then
  ROOT_INIT="$ROOT/__init__.py"
  mv "$ROOT_INIT" "$ROOT/__init__.py.compilebak"
fi
restore_root_init() { [ -n "$ROOT_INIT" ] && [ -f "$ROOT/__init__.py.compilebak" ] && mv "$ROOT/__init__.py.compilebak" "$ROOT_INIT"; }
trap restore_root_init EXIT INT TERM

# Per-file worker: cythonize -i produces <name>.<abi>.so next to the source (correct ABI name) and
# leaves a <name>.c. On success remove the .py and the .c; on failure keep the .py, clean partials.
export CYTHONIZE
list_targets | xargs -0 -P "$JOBS" -I{} sh -c '
  f="$1"; base="${f%.py}"
  # Cython cannot compile a @staticmethod/@classmethod that is also @abstractmethod: abc tries to set
  # __isabstractmethod__ on the C-level descriptor and the module fails to import. Keep such files as
  # source (detected here so the rule is self-healing if more are added later).
  if awk '"'"'
      function deco(l){return l ~ /^[[:space:]]*@(staticmethod|classmethod)[[:space:]]*$/}
      function absm(l){return l ~ /^[[:space:]]*@(abc\.)?abstractmethod/}
      prev!=""{ if((deco(prev)&&absm($0))||(absm(prev)&&deco($0))){found=1; exit} }
      {prev=$0}
      END{exit !found}
    '"'"' "$f"; then
    echo "KEEP(abstract-static): $f"
    exit 0
  fi
  if "$CYTHONIZE" -i -3 "$f" >/dev/null 2>&1 && ls "$base".*.so >/dev/null 2>&1; then
    rm -f "$f" "$base.c"
  else
    rm -f "$base.c"
    echo "KEEP(uncompiled): $f"
  fi
' _ {}

# Drop bytecode caches so only the .so (or a kept .py) is importable, and the setuptools build/
# temp dir that cythonize -i leaves in the working directory (duplicate .so copies, build bloat).
find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
rm -rf "$ROOT/build"

# Strip debug symbols from the compiled modules (cuts their size by ~70%); harmless if strip absent.
if command -v strip >/dev/null 2>&1; then
  find . -name '*.so' -exec strip --strip-unneeded {} + 2>/dev/null || true
fi

restore_root_init
trap - EXIT INT TERM

SO=$(find . -name '*.so' | wc -l)
REMAIN=$(list_targets | tr -d -c '\0' | wc -c)
echo "compile_py: done. compiled .so=$SO ; still-source(targets)=$REMAIN"

# Fail loudly if nothing compiled (broken toolchain: no compiler, missing headers, cythonize not on
# PATH). Otherwise the build would silently ship readable source, as happened once. A tree genuinely
# having no eligible modules would not have reached here with TOTAL>0.
if [ "$TOTAL" -gt 0 ] && [ "$SO" -eq 0 ]; then
  echo "compile_py: ERROR - 0 modules compiled out of $TOTAL; the build toolchain is not working." >&2
  exit 1
fi
# Also fail if an unexpectedly large share stayed as source (a few known-incompatible files are fine).
if [ "$REMAIN" -gt "${MAX_UNCOMPILED:-25}" ]; then
  echo "compile_py: ERROR - $REMAIN modules left as source (> ${MAX_UNCOMPILED:-25}); compilation is failing for many files." >&2
  exit 1
fi
