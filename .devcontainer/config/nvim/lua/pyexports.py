"""List what each installed top-level Python package exports, for pyexports.lua.

Run by Neovim with the project's own interpreter (the one basedpyright resolves
imports in), as `python -I pyexports.py CACHE_DIR`. Prints JSON:

    {"fingerprint": "...", "packages": {"pandas": [["DataFrame", "class"], ...]}}

The packages are read, never imported. Importing would run their code, take
seconds for the likes of scipy or torch, and could have side effects; reading
the source with `ast` takes well under a second for a large venv. The cost is
that names a package builds at run time are missed, which is why `__all__` is
honoured when it is a literal (lazy-loading packages such as pydantic and
scipy declare their exports that way precisely so tools can see them).

Only the top level of each package is covered, as in Pylance's default index:
`from pandas import DataFrame`, not `from matplotlib.pyplot import subplots`.
A submodule named in `__all__` (scipy's `linalg`) is offered as a module.

The result is cached per interpreter under CACHE_DIR, keyed by a fingerprint of
the installed distributions (the `*.dist-info` names carry versions), so a
`uv pip install` or upgrade invalidates it and an unchanged venv costs one
directory listing.

Kept runnable on Python 3.8, the oldest a supported Ubuntu might still have as
a project interpreter.
"""

import ast
import hashlib
import json
import os
import site
import sys

# Packaging tools sit in every venv and their names only crowd the list.
SKIP = {"pip", "setuptools", "pkg_resources", "wheel", "test", "tests"}

# How far `from .x import *` is followed inside a package. numpy's stub goes
# two deep; three leaves room without risking a walk through a whole package.
STAR_DEPTH = 3


def site_dirs():
    try:
        dirs = site.getsitepackages()
    except AttributeError:  # very old virtualenv's site.py
        dirs = []
    return [d for d in dirs if os.path.isdir(d)]


def fingerprint(dirs):
    h = hashlib.sha1(sys.executable.encode())
    for d in dirs:
        h.update(d.encode())
        try:
            names = sorted(n for n in os.listdir(d) if n.endswith((".dist-info", ".egg-info", ".pth")))
        except OSError:
            continue
        for n in names:
            h.update(n.encode())
    # A change to this script must invalidate caches written by an older one.
    with open(__file__, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def top_level(dirs):
    """{name: (source file, package dir or None)} for every importable top-level
    name. A stub (`.pyi`, or a `<name>-stubs` package) wins over the runtime
    source: it declares the interface, where `__init__.py` may build it
    dynamically."""
    found = {}
    for d in dirs:
        for entry in sorted(os.listdir(d)):
            path = os.path.join(d, entry)
            name = None
            src = None
            pkgdir = None
            if os.path.isdir(path):
                stub = entry[: -len("-stubs")] if entry.endswith("-stubs") else None
                for init in ("__init__.pyi", "__init__.py"):
                    if os.path.isfile(os.path.join(path, init)):
                        name, src, pkgdir = stub or entry, os.path.join(path, init), path
                        break
                if stub and name:
                    found[name] = (src, pkgdir)  # stubs override whatever was found first
                    continue
            elif entry.endswith((".py", ".pyi")):
                name, src = entry.rsplit(".", 1)[0], path
            if name and name.isidentifier() and not name.startswith("_") and name not in SKIP:
                if name not in found or src.endswith(".pyi"):
                    found[name] = (src, pkgdir)
    return found


def guess_kind(name):
    if name.isupper():
        return "constant"
    if name[0].isupper():
        return "class"
    return "function"


def literal_strings(node, lists):
    """The strings of a literal list/tuple, `a + b` of such, or a name bound to
    one earlier in the module. None when any part is not literal."""
    if isinstance(node, (ast.List, ast.Tuple)):
        out = []
        for elt in node.elts:
            if isinstance(elt, ast.Constant) and isinstance(elt.value, str):
                out.append(elt.value)
            else:
                return None
        return out
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left = literal_strings(node.left, lists)
        right = literal_strings(node.right, lists)
        if left is None or right is None:
            return None
        return left + right
    if isinstance(node, ast.Name) and node.id in lists:
        return lists[node.id]
    return None


def module_file(pkgdir, dotted):
    base = os.path.join(pkgdir, *dotted.split("."))
    for cand in (base + ".pyi", base + ".py", os.path.join(base, "__init__.pyi"), os.path.join(base, "__init__.py")):
        if os.path.isfile(cand):
            return cand
    return None


def exports(src, pkg, pkgdir, depth=0):
    """{name: kind} that `from pkg import name` would give, read from `src`."""
    try:
        with open(src, "rb") as f:
            tree = ast.parse(f.read(), src)
    except (OSError, SyntaxError, ValueError):
        return {}
    is_stub = src.endswith(".pyi")
    names = {}
    lists = {}
    all_names = []
    all_literal = None  # None: no __all__ seen; False: seen but not literal

    def note_all(values):
        nonlocal all_literal
        if values is None:
            all_literal = False
        else:
            all_names.extend(values)
            if all_literal is None:
                all_literal = True

    def walk(body):
        for stmt in body:
            if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
                names[stmt.name] = "function"
            elif isinstance(stmt, ast.ClassDef):
                names[stmt.name] = "class"
            elif isinstance(stmt, (ast.Assign, ast.AnnAssign)):
                targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
                for t in targets:
                    if isinstance(t, ast.Name):
                        if t.id == "__all__":
                            note_all(literal_strings(stmt.value, lists) if stmt.value else None)
                        else:
                            names.setdefault(t.id, "constant" if t.id.isupper() else "variable")
                            values = literal_strings(stmt.value, lists) if stmt.value else None
                            if values is not None:
                                lists[t.id] = values
            elif isinstance(stmt, ast.AugAssign) and isinstance(stmt.target, ast.Name) and stmt.target.id == "__all__":
                note_all(literal_strings(stmt.value, lists))
            elif (isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call)
                  and isinstance(stmt.value.func, ast.Attribute)
                  and isinstance(stmt.value.func.value, ast.Name)
                  and stmt.value.func.value.id == "__all__"):
                args = stmt.value.args
                if stmt.value.func.attr == "extend" and len(args) == 1:
                    note_all(literal_strings(args[0], lists))
                elif stmt.value.func.attr == "append" and len(args) == 1 and isinstance(args[0], ast.Constant):
                    note_all([args[0].value])
            elif isinstance(stmt, ast.ImportFrom):
                own = stmt.level > 0 or (stmt.module or "").split(".")[0] == pkg
                for alias in stmt.names:
                    if alias.name == "*":
                        if own and pkgdir and depth < STAR_DEPTH:
                            mod = stmt.module or ""
                            if stmt.level == 0:
                                mod = mod.split(".", 1)[1] if "." in mod else ""
                            sub = module_file(pkgdir, mod) if mod else None
                            if sub:
                                for n, k in exports(sub, pkg, pkgdir, depth + 1).items():
                                    names.setdefault(n, k)
                        continue
                    bound = alias.asname or alias.name
                    # In a stub only `import a as a` re-exports (PEP 484);
                    # in source every from-import binds a public name.
                    if is_stub and alias.asname != alias.name:
                        continue
                    kind = "module" if pkgdir and module_file(pkgdir, alias.name) and own else guess_kind(bound)
                    names.setdefault(bound, kind)
            elif isinstance(stmt, ast.If):
                walk(stmt.body)
                walk(stmt.orelse)
            elif isinstance(stmt, ast.Try) or type(stmt).__name__ == "TryStar":
                walk(stmt.body)
                for h in stmt.handlers:
                    walk(h.body)
                walk(stmt.orelse)
                walk(stmt.finalbody)
            elif isinstance(stmt, ast.With):
                walk(stmt.body)

    walk(tree.body)
    if all_literal:
        out = {}
        for n in all_names:
            if isinstance(n, str) and n.isidentifier() and not n.startswith("_"):
                if n in names:
                    out[n] = names[n]
                elif pkgdir and module_file(pkgdir, n):
                    out[n] = "module"
                else:
                    out[n] = guess_kind(n)
        return out
    return {n: k for n, k in names.items() if not n.startswith("_")}


def build(dirs):
    packages = {}
    for pkg, (src, pkgdir) in sorted(top_level(dirs).items()):
        ex = exports(src, pkg, pkgdir)
        packages[pkg] = sorted([n, k] for n, k in ex.items())
    return packages


def main():
    cache_dir = sys.argv[1] if len(sys.argv) > 1 else None
    dirs = site_dirs()
    fp = fingerprint(dirs)
    cache = None
    if cache_dir:
        key = hashlib.sha1(os.path.realpath(sys.executable).encode() + sys.prefix.encode()).hexdigest()
        cache = os.path.join(cache_dir, key + ".json")
        try:
            with open(cache) as f:
                data = json.load(f)
            if data.get("fingerprint") == fp:
                sys.stdout.write(json.dumps(data))
                return
        except (OSError, ValueError):
            pass
    data = {"fingerprint": fp, "python": sys.executable, "dirs": dirs, "packages": build(dirs)}
    text = json.dumps(data)
    if cache:
        os.makedirs(cache_dir, exist_ok=True)
        tmp = cache + ".tmp"
        with open(tmp, "w") as f:
            f.write(text)
        os.replace(tmp, cache)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
