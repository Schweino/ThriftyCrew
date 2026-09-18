"""count_unchecked_child_parse.py - the Python half of ops/count-unchecked-child-parse.ps1 (backlog I188).

A REPORT, never a gate. It answers one question over the tracked .py outside archive/: where is the output of a
child process or a web call parsed as data (json.loads, json.load, .split, .splitlines, requests' .json()) with
neither an exit/status read nor a shape check of the parsed value in the same scope?

THE TEST (it is the acceptance bar written into design/BACKLOG-course-findings.md I188 before the first count):
  * A SOURCE is subprocess.run/Popen/check_output/call/check_call, os.popen, urlopen, or requests.<verb>, reached
    directly, through .stdout/.text/.content/.read()/.decode()/.strip()/.communicate()/[i], or through
    assignments (or `with ... as`, or tuple unpacking) in the same scope, --max-hops of them (default 1).
  * EXIT READ: .returncode, .status_code, .status, .getcode() or raise_for_status() anywhere in the scope.
    IMPLICIT: check_output, check_call, check=True, urlopen - they raise on failure by construction, recorded as
    their own class because a 200 carrying an error page still passes a status check.
  * SHAPE CHECK: the parsed value's name appears in an if/while/assert/if-expression test or an isinstance()
    call AFTER the site, in the same scope.
  * A scope is a function body, or the module's statements outside every function.

SCOPE OF A CLEAN REPORT: UNSOUND. A source wrapped in a helper function (a `run_git()` returning stdout) is not
followed across the call, so a parse of a helper's result is not a site; a try/except around the parse is not
read as a shape check. A site is a CANDIDATE to read by eye and an absent file proves nothing.

Usage:
  python ops/count_unchecked_child_parse.py --root <repo> --files <list.txt> --out <rows.jsonl>
  python ops/count_unchecked_child_parse.py --selftest
Last line is COUNT-UNCHECKED-CHILD-PARSE-PY-COMPLETE (or the self-test verdict).
"""
import argparse
import ast
import json
import os
import sys
import warnings

SUBPROC = {"run", "Popen", "check_output", "call", "check_call", "getoutput", "getstatusoutput"}
IMPLICIT_CALLS = {"check_output", "check_call", "urlopen"}
REQ_VERBS = {"get", "post", "put", "patch", "delete", "head", "request"}
PASS_ATTRS = {"stdout", "stderr", "text", "content", "output", "read", "decode", "strip", "rstrip", "lstrip",
              "communicate", "readlines", "readline"}


def dotted(node):
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
    return ".".join(reversed(parts))


class Scope:
    def __init__(self, node, stmts):
        self.node = node
        self.nodes = []
        for s in stmts:
            self._collect(s)
        self.assigns = {}
        for n in self.nodes:
            if isinstance(n, ast.Assign):
                for t in n.targets:
                    self._bind(t, n.value)
            elif isinstance(n, (ast.AnnAssign, ast.AugAssign)) and n.value is not None:
                self._bind(n.target, n.value)
            elif isinstance(n, (ast.With, ast.AsyncWith)):
                for it in n.items:
                    if it.optional_vars is not None:
                        self._bind(it.optional_vars, it.context_expr)
            elif isinstance(n, ast.NamedExpr):
                self._bind(n.target, n.value)

    def _collect(self, node):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
            return
        self.nodes.append(node)
        for ch in ast.iter_child_nodes(node):
            if isinstance(ch, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
                continue
            self._collect(ch)

    def _bind(self, target, value):
        if isinstance(target, ast.Name):
            self.assigns.setdefault(target.id, []).append(value)
        elif isinstance(target, (ast.Tuple, ast.List)):
            for elt in target.elts:
                # out, err = p.communicate(): each name is bound to the whole source call
                self._bind(elt, value)


MAX_HOPS = [1]  # the I188 bar: "directly or through one assignment in the same scope"


def source_kind(node, scope, depth=0, hops=0):
    """(kind, implicit) where kind is 'native', 'web' or None. depth is a hang guard; hops counts assignments."""
    if node is None or depth > 16 or hops > MAX_HOPS[0]:
        return (None, False)
    if isinstance(node, ast.Call):
        name = dotted(node.func)
        leaf = name.split(".")[-1] if name else ""
        if name.startswith("subprocess.") and leaf in SUBPROC:
            implicit = leaf in IMPLICIT_CALLS or any(
                k.arg == "check" and isinstance(k.value, ast.Constant) and k.value.value is True for k in node.keywords)
            return ("native", implicit)
        if name in SUBPROC and name in scope_imports.get("subprocess", set()):
            implicit = name in IMPLICIT_CALLS or any(
                k.arg == "check" and isinstance(k.value, ast.Constant) and k.value.value is True for k in node.keywords)
            return ("native", implicit)
        if name == "os.popen":
            return ("native", False)
        if leaf == "urlopen":
            return ("web", True)
        if name.startswith("requests.") and leaf in REQ_VERBS:
            return ("web", False)
        if isinstance(node.func, ast.Attribute) and node.func.attr in PASS_ATTRS:
            return source_kind(node.func.value, scope, depth + 1, hops)
        return (None, False)
    if isinstance(node, ast.Attribute):
        if node.attr in PASS_ATTRS:
            return source_kind(node.value, scope, depth + 1, hops)
        return (None, False)
    if isinstance(node, ast.Subscript):
        return source_kind(node.value, scope, depth + 1, hops)
    if isinstance(node, ast.Name):
        for v in scope.assigns.get(node.id, []):
            k = source_kind(v, scope, depth + 1, hops + 1)
            if k[0]:
                return k
    return (None, False)


scope_imports = {}


def load_imports(tree):
    global scope_imports
    scope_imports = {}
    for n in ast.walk(tree):
        if isinstance(n, ast.ImportFrom) and n.module:
            scope_imports.setdefault(n.module, set()).update(a.asname or a.name for a in n.names)


def parse_sites(scope):
    """Yield (node, input_expr, op) for every parse operation in the scope."""
    for n in scope.nodes:
        if not isinstance(n, ast.Call):
            continue
        name = dotted(n.func)
        if name in ("json.loads", "json.load") and n.args:
            yield n, n.args[0], name
        elif isinstance(n.func, ast.Attribute) and n.func.attr in ("split", "splitlines"):
            yield n, n.func.value, "." + n.func.attr
        elif isinstance(n.func, ast.Attribute) and n.func.attr == "json" and not n.args:
            yield n, n.func.value, ".json()"


def result_names(scope, call):
    names = set()
    for n in scope.nodes:
        if isinstance(n, ast.Assign) and _contains(n.value, call):
            for t in n.targets:
                for x in ast.walk(t):
                    if isinstance(x, ast.Name):
                        names.add(x.id)
    return names


def _contains(tree, target):
    return any(x is target for x in ast.walk(tree))


def has_exit_read(scope):
    for n in scope.nodes:
        if isinstance(n, ast.Attribute) and n.attr in ("returncode", "status_code", "status"):
            return True
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr in ("raise_for_status", "getcode"):
            return True
    return False


def has_shape_check(scope, names, after_line):
    if not names:
        return False
    for n in scope.nodes:
        tests = []
        if isinstance(n, (ast.If, ast.While, ast.IfExp)):
            tests.append(n.test)
        elif isinstance(n, ast.Assert):
            tests.append(n.test)
        elif isinstance(n, ast.comprehension):
            tests.extend(n.ifs)
        elif isinstance(n, ast.Call) and dotted(n.func) == "isinstance":
            tests.append(n)
        for t in tests:
            if getattr(t, "lineno", 0) < after_line:
                continue
            for x in ast.walk(t):
                if isinstance(x, ast.Name) and x.id in names:
                    return True
    return False


def scan_source(text, rel):
    rows = []
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")  # an invalid escape in a scanned file is its business, not this report's
            tree = ast.parse(text)
    except SyntaxError:
        return None
    load_imports(tree)
    scopes = [Scope(tree, [s for s in tree.body
                           if not isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))])]
    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            scopes.append(Scope(n, n.body))
    for sc in scopes:
        exit_read = None
        for call, inp, op in parse_sites(sc):
            kind, implicit = source_kind(inp, sc)
            if not kind:
                continue
            if exit_read is None:
                exit_read = has_exit_read(sc)
            names = result_names(sc, call)
            shape = has_shape_check(sc, names, call.lineno)
            status = "read" if exit_read else ("implicit" if implicit else "none")
            rows.append({
                "lang": "py", "file": rel, "line": call.lineno, "op": op, "class": kind,
                "exit": status, "shape": shape, "unguarded": (status == "none" and not shape),
            })
    return rows


def selftest():
    cases = []

    def case(label, src, want_sites, want_unguarded):
        rows = scan_source(src, "fx.py") or []
        got_u = sum(1 for r in rows if r["unguarded"])
        ok = len(rows) == want_sites and got_u == want_unguarded
        cases.append(ok)
        print(("PASS " if ok else "FAIL ") + label + "  sites=%d unguarded=%d" % (len(rows), got_u))

    case("MUST FIRE      subprocess stdout into json.loads, no returncode, no check",
         "import json, subprocess\ndef f():\n    p = subprocess.run(['git','x'], capture_output=True, text=True)\n"
         "    d = json.loads(p.stdout)\n    return d['a']\n", 1, 1)
    case("MUST FIRE      requests .json() with no status read",
         "import requests\ndef f(u):\n    r = requests.get(u)\n    return r.json()\n", 1, 1)
    case("MUST NOT FIRE  returncode read in the same scope",
         "import json, subprocess\ndef f():\n    p = subprocess.run(['git'], capture_output=True, text=True)\n"
         "    if p.returncode != 0:\n        raise SystemExit(1)\n    return json.loads(p.stdout)\n", 1, 0)
    case("MUST NOT FIRE  shape check on the parsed name",
         "import json, subprocess\ndef f():\n    out = subprocess.run(['x'], capture_output=True).stdout\n"
         "    d = json.loads(out)\n    if not isinstance(d, dict):\n        return None\n    return d\n", 1, 0)
    case("MUST NOT FIRE  a file read is not a child's output",
         "import json\ndef f(p):\n    return json.loads(open(p).read())\n", 0, 0)
    case("CLEAN TWIN     check_output is a site, recorded as implicit, not unguarded",
         "import subprocess\ndef f():\n    return subprocess.check_output(['git','ls-files']).decode().splitlines()\n", 1, 0)
    total = len(cases)
    passed = sum(cases)
    print("count_unchecked_child_parse self-test: %s (%d of %d cases pass)" % ("PASS" if passed == total else "FAIL", passed, total))
    return 0 if passed == total else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root")
    ap.add_argument("--files")
    ap.add_argument("--out")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--max-hops", type=int, default=1)
    a = ap.parse_args()
    MAX_HOPS[0] = a.max_hops
    if a.selftest:
        return selftest()
    with open(a.files, encoding="utf-8") as fh:
        rels = [l.strip() for l in fh if l.strip()]
    rows, unparsed = [], []
    for rel in rels:
        path = os.path.join(a.root, rel)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            unparsed.append(rel)
            continue
        r = scan_source(text, rel)
        if r is None:
            unparsed.append(rel)
            continue
        rows.extend(r)
    with open(a.out, "w", encoding="utf-8", newline="\n") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
    print("py files=%d unparsed=%d sites=%d" % (len(rels), len(unparsed), len(rows)))
    for u in unparsed:
        print("  unparsed: " + u)
    print("COUNT-UNCHECKED-CHILD-PARSE-PY-COMPLETE files=%d sites=%d" % (len(rels), len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
