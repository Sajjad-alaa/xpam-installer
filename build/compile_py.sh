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
#
# ROOT_IS_PACKAGE: how the modules are named. 0 (default, the core): <root-dir> itself is on sys.path
# and its children are imported top-level ("orgs.models"); a stray <root-dir>/__init__.py is moved
# aside during the compile so it is not baked into the names. 1 (facelive): <root-dir> is a package
# imported by its directory name ("facelive.config"); its __init__.py stays so the names keep it.
set -eu

ROOT=${1:?usage: compile_py.sh <root-dir>}
# absolute paths: the script changes into ROOT below, so relative ones would no longer resolve
ROOT=$(CDPATH= cd -- "$ROOT" && pwd)
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYBIN=${PYBIN:-/opt/py3/bin/python}
CYTHONIZE=${CYTHONIZE:-${PYBIN%/python}/cythonize}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
ROOT_IS_PACKAGE=${ROOT_IS_PACKAGE:-0}

# Cython options. annotation_typing=False is essential: by default Cython turns Python type hints into
# runtime type checks and conversions that plain Python never does - "x: list" rejects a Django
# QuerySet, "x: str" rejects None and lazy translation strings, "x: dict" rejects OrderedDict,
# "x: float" turns a Decimal into a float. With it off the compiled module behaves like the source.
CYTHON_OPTS="-3 -X annotation_typing=False"

# Build the C extensions optimized (-O2) and with exploit-mitigation hardening: stack canaries,
# fortified libc calls, and full/immediate RELRO on the shared object. These harden the native code
# against memory-corruption bugs at negligible runtime cost; no application safety check is disabled
# (we deliberately do NOT pass Cython's boundscheck/nonecheck-off "fast" directives, which would
# trade memory/None safety for speed). setuptools honours CFLAGS/LDFLAGS when building each module.
export CFLAGS="${CFLAGS:-} -O2 -fstack-protector-strong -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 -fPIC"
export LDFLAGS="${LDFLAGS:-} -Wl,-z,relro,-z,now"

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

# Hardening: remove docstrings from the modules about to be compiled. Cython embeds docstrings into
# the .so otherwise, and for this code they describe the licence/protection algorithm in plain prose.
# Function/class names still remain (Python needs them), but the explanatory text no longer ships.
# STRIP_DOCSTRINGS=0 disables it. The helper sits next to this script.
STRIP_DOCSTRINGS=${STRIP_DOCSTRINGS:-1}
DS_SCRIPT=${STRIP_DOCSTRINGS_SCRIPT:-$SELF_DIR/strip_docstrings.py}
if [ "$STRIP_DOCSTRINGS" = "1" ] && [ -f "$DS_SCRIPT" ]; then
  list_targets | xargs -0 "$PYBIN" "$DS_SCRIPT" | tail -1
elif [ "$STRIP_DOCSTRINGS" = "1" ]; then
  echo "compile_py: WARNING strip_docstrings.py not found at $DS_SCRIPT; docstrings will remain" >&2
fi

# Cython derives a module's fully-qualified name by walking UP the directory tree while an
# __init__.py exists. The source root is on sys.path (apps are imported top-level, e.g. "orgs"),
# but it also carries a trivial __init__.py; if left in place Cython would bake the root dir name
# into every module (e.g. "work.orgs.models"), which breaks Django's app_label lookup. Move the
# root __init__.py aside for the duration of the compile and restore it afterwards (it is kept as
# source either way). Nested app packages keep their __init__.py, so names stay correct.
# With ROOT_IS_PACKAGE=1 the root __init__.py is the package's own and stays in place.
ROOT_INIT=""
if [ "$ROOT_IS_PACKAGE" != "1" ] && [ -f "$ROOT/__init__.py" ]; then
  ROOT_INIT="$ROOT/__init__.py"
  mv "$ROOT_INIT" "$ROOT/__init__.py.compilebak"
fi
# (an if, not an && chain: with set -e a false test as the function's last status would abort the script)
restore_root_init() {
  if [ -n "$ROOT_INIT" ] && [ -f "$ROOT/__init__.py.compilebak" ]; then
    mv "$ROOT/__init__.py.compilebak" "$ROOT_INIT"
  fi
}
trap restore_root_init EXIT
trap 'restore_root_init; exit 130' INT TERM

# Per-file worker: cythonize -i produces <name>.<abi>.so next to the source (correct ABI name) and
# leaves a <name>.c. On success remove the .py and the .c; on failure keep the .py, clean partials.
export CYTHONIZE CYTHON_OPTS
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
  # shellcheck disable=SC2086 # CYTHON_OPTS is a list of options
  if "$CYTHONIZE" -i $CYTHON_OPTS "$f" >/dev/null 2>&1 && ls "$base".*.so >/dev/null 2>&1; then
    rm -f "$f" "$base.c"
  else
    rm -f "$base.c"
    echo "KEEP(uncompiled): $f"
  fi
' _ {}

# Drop bytecode caches so only the .so (or a kept .py) is importable, and every setuptools build/
# directory that cythonize -i leaves behind (duplicate .so copies, build bloat). Sub-packages that
# carry their own setup.py (vendored vault SDKs, demos, endpoint applets) get a nested build/ too,
# so remove any directory named build that holds setuptools output (lib.*/temp.*), at any depth.
find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find . -type d -name build | while IFS= read -r d; do
  if ls -d "$d"/lib.* >/dev/null 2>&1 || ls -d "$d"/temp.* >/dev/null 2>&1; then rm -rf "$d"; fi
done

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
