"""Replace a whole file with new text and do not return until the DEVICE has the bytes.

The Python half of Brad's I117 ruling, 2026-09-12. Verbatim:

    "Files rebuilt from source (boards, price tables, reports) never flush; the next build is the
    repair. Ledgers that are not re-derived if their last write is lost flush to disk before the
    replace: graph/learning/promote_aliases.py's holds, grocery/rollback-first-seen.json and
    grocery/sale-windows.json. Implement it once, as an opt-in switch on Write-TcAtomicFile (and the
    Python equivalent for the holds), never as a default for every write. Any new ledger that is
    read-modify-written across runs states in its header which of the two classes it is in. The
    unverified claim that NTFS needs no separate directory flush stays registered as C182 until
    someone checks it."

The PowerShell half is `lib/atomic-write.ps1`'s `-Flush` switch, whose header carries the same
ruling and the argument behind it. THIS FILE IS NOT A SECOND COPY OF THAT ONE: it is the same idiom
in the other language, because `promotion-holds.json` is written by Python and nothing else here is.
It lives in `graph/lib` because that directory is already on `promote_aliases.py`'s import path; a
future Python ledger outside `graph/` imports it rather than copying it.

WHICH CLASS A FILE IS IN is the whole decision, and the test is not "is this file important" but
"if its last write vanished, would anything notice or re-derive it?"

  * REBUILT FROM SOURCE - the boards, the price tables, the reports, every cache. Never flushes. The
    next build is the repair, and paying for durability on a file that is about to be recomputed buys
    nothing.
  * NOT RE-DERIVED - a ledger read, modified and written back across runs, whose lost write is simply
    gone. Flushes. `promotion-holds.json` is one: holds only ever accumulate, nothing expires them,
    and nothing recomputes them, so a lost write is a hold that silently never happened - and the
    guard suite that produced it has already gone green and moved on.

WHAT THE FLUSH BUYS, AND WHAT IT DOES NOT. `write()` returning is a statement about the page cache,
not about the disk, and the canonical idiom is write, fsync, close, RENAME - the fsync being what
makes "the name now points at the new file" imply "the new file's bytes are on the device". Without
it a power loss in that window can leave the real name pointing at a short or empty file, which is
worse than not writing at all because a good file has been replaced by a bad one. It needs a HARD
power event: a crash of the writing PROCESS is harmless either way, because the page cache belongs
to the OS and outlives the process. That narrowness is exactly why this is opt-in.

THE DIRECTORY ENTRY IS NOT FLUSHED, AND THAT IS AN UNVERIFIED CLAIM, NOT A DECISION. On POSIX the
idiom is two fsyncs, the file and then the directory holding its name, because the data blocks and
the directory entry naming them are different objects. Windows has no directory handle to flush, and
the belief that NTFS records the directory entry in the same metadata transaction is why there is one
call here and not two. It is registered as claim C182 in the skills store and has NOT been measured.
If it is wrong, this flushes the file and not the name. A port of this file to POSIX owes the second
fsync and must not read the absence of one here as a finding that it is unnecessary.

THE REPLACE CAN BE REFUSED BY A READER, IN ANY LANGUAGE, BECAUSE IT IS A WINDOWS RULE AND NOT A
POWERSHELL ONE. A handle opened without FILE_SHARE_DELETE blocks a replace outright, and the C
runtime opens a file for reading without it - so `os.replace` raises PermissionError while a plain
`open(path)` elsewhere holds the destination. `lib/atomic-write.ps1` measured that shape on the
PowerShell side (387 of 400 bare replaces landing beside a reader, 400 of 400 with a retry) and the
retry here is the same answer. THE PYTHON SIDE WAS NOT SEPARATELY MEASURED: the constants below are
lifted from that file, so they are a borrowed first plausible value and not the survivor of a sweep
in this language.

IS THE RETRY IDEMPOTENT? Yes, and that is why it is safe. Each attempt replaces the WHOLE file with
the WHOLE text, so a retry after a refusal, a lost answer or a crashed-and-restarted caller all reach
the same state. An APPEND would not have this property - a retry there duplicates a line - which is
why this file writes whole files only and says so rather than leaving the reader to work it out.

SCOPE OF A CLEAN REPORT: the self-test drives real file handles on this machine's file system. A pass
proves the bytes are exactly what was asked for, that the refusal is retried and then raised rather
than swallowed, and that the fsync CALL completed - `flush_count()` is incremented after `os.fsync`
returns, never before, so it is evidence the call ran and not merely that the branch was entered.
NOTHING HERE PROVES BYTES REACHED THE PLATTER. That needs a power cut, not a test.

SELF-TEST:  python graph/lib/durable_write.py --selftest
Exit 0 ok, 2 self-test failure.
"""
from __future__ import annotations

import os
import time

# BORROWED FROM lib/atomic-write.ps1, NOT SWEPT HERE (see the header). 40 attempts with a sleep of
# 25 ms x min(attempt, 8) is about 7.3 s in all, which there was 8x the worst attempt count measured
# under load. What it does when the producer stops: nothing - it only runs when a writer calls it.
REPLACE_ATTEMPTS = 40
REPLACE_BASE_SLEEP_MS = 25

_FLUSHES = 0


def flush_count() -> int:
    """How many fsyncs this process has COMPLETED. A test seam; see SCOPE in the header."""
    return _FLUSHES


def _is_refusal(exc: OSError, tmp: str, dest: str) -> bool:
    """True when a failed replace is the transient refusal worth waiting out.

    Decided by STATE rather than by exception type, the same rule `Test-TcReplaceRefusal` follows:
    a vanished temp file and a missing destination directory will not come back by waiting, so they
    are raised at once instead of after the whole budget.
    """
    if not isinstance(exc, OSError):
        return False
    if not os.path.exists(tmp):
        return False
    parent = os.path.dirname(os.path.abspath(dest))
    if parent and not os.path.isdir(parent):
        return False
    return True


def write_bytes_durably(path: str, data: bytes, max_attempts: int = REPLACE_ATTEMPTS,
                        base_sleep_ms: int = REPLACE_BASE_SLEEP_MS, on_refusal=None) -> int:
    """Replace `path` with `data`, flushed to the device before the replace.

    Returns the number of replace attempts it took (1 when nothing was in the way). Raises at once on
    a failure waiting cannot fix, and after the budget on a refusal that outlasts it - with the
    previous file left exactly as it was and the message saying the write is NOT on disk.

    `on_refusal(attempt)` runs after each refused attempt, before the sleep. It is the seam a test
    uses to PROVE a replace met a reader instead of timing it; a caller may use it to log.
    """
    global _FLUSHES
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
        fh.flush()               # Python's own buffer into the OS. Not durability, only the first leg.
        os.fsync(fh.fileno())    # THE step this file exists for: on Windows, FlushFileBuffers.
    # Counted after fsync RETURNED, never before: see SCOPE in the header.
    _FLUSHES += 1

    if max_attempts < 1:
        max_attempts = 1
    last = ""
    for attempt in range(1, max_attempts + 1):
        try:
            os.replace(tmp, path)
            return attempt
        except OSError as exc:
            last = str(exc)
            if not _is_refusal(exc, tmp, path):
                _drop_debris(tmp, path)
                raise
            if on_refusal is not None:
                on_refusal(attempt)
            if attempt < max_attempts:
                time.sleep(base_sleep_ms * min(attempt, 8) / 1000.0)
    kept = _drop_debris(tmp, path)
    raise OSError("write_bytes_durably: could not replace %s after %d attempt(s) - another handle "
                  "kept it open. The previous file is intact and this write is NOT on disk.%s "
                  "Last error: %s" % (path, max_attempts, kept, last))


def write_text_durably(path: str, text: str, encoding: str = "utf-8", **kwargs) -> int:
    """`write_bytes_durably` for text. BINARY underneath on purpose.

    Python's text mode on Windows turns every "\\n" into "\\r\\n", which has already cost this estate
    a tracked file's whole line ending set in one write (`fdc_lookup.cache_write`, 2026-09-11). The
    bytes here are exactly `text.encode(encoding)`: no BOM, no translation, and nothing appended.
    """
    return write_bytes_durably(path, text.encode(encoding), **kwargs)


def _drop_debris(tmp: str, dest: str) -> str:
    """After a failure: the destination survives, so the temp copy is debris. If the destination is
    gone, the temp copy is the only one left, so it stays and the returned text says where."""
    if os.path.exists(dest):
        try:
            os.remove(tmp)
        except OSError:
            pass
        return ""
    if os.path.exists(tmp):
        return " The destination is MISSING; the new text is still at %s." % tmp
    return ""


def _selftest() -> int:
    import tempfile

    fails = []
    ran = []

    def T(name, cond, got=""):
        ran.append(name)
        print(("  ok    " if cond else "  X     ") + name + ("" if cond else "   got: %s" % (got,)))
        if not cond:
            fails.append(name)

    root = tempfile.mkdtemp(prefix="tc-dw-")
    try:
        # ---- the bytes are exactly the bytes asked for -------------------------------------------
        doc = '{\n  "holds": [\n    {"commodity": "café"}\n  ]\n}'
        p = os.path.join(root, "bytes.json")
        write_text_durably(p, doc)
        with open(p, "rb") as fh:
            raw = fh.read()
        T("MUST FIRE  the file holds exactly text.encode('utf-8'): no BOM, no CRLF translation, nothing appended",
          raw == doc.encode("utf-8"), repr(raw[:40]))
        T("MUST FIRE  a LF in the text survives on Windows, where text mode would have written CRLF",
          b"\r\n" not in raw and raw.count(b"\n") == doc.count("\n"), repr(raw[:40]))

        # ---- the MECHANISM, which is the only part a test can reach --------------------------
        before = flush_count()
        write_text_durably(os.path.join(root, "counted.json"), "x")
        T("MUST FIRE  one fsync COMPLETES per write, counted after os.fsync returns rather than on entry",
          flush_count() - before == 1, flush_count() - before)

        # ---- replacing an existing file, and leaving no debris -----------------------------------
        p2 = os.path.join(root, "replace.json")
        write_text_durably(p2, "first")
        n = write_text_durably(p2, "second")
        with open(p2, "rb") as fh:
            after = fh.read()
        T("CLEAN TWIN  a second write replaces the first whole, in one attempt, and leaves no .tmp behind",
          after == b"second" and n == 1 and not os.path.exists(p2 + ".tmp"), "%r n=%s" % (after, n))

        # ---- a reader that does NOT let go: refused, loudly, with the old file intact -------------
        # No clock anywhere: the reader is held open across the whole call, so the outcome is fixed.
        p3 = os.path.join(root, "held.json")
        write_text_durably(p3, "old")
        refusals = []
        err = ""
        reader = open(p3, "rb")
        try:
            write_text_durably(p3, "new", max_attempts=3, base_sleep_ms=1,
                               on_refusal=lambda a: refusals.append(a))
        except OSError as exc:
            err = str(exc)
        finally:
            reader.close()
        with open(p3, "rb") as fh:
            kept = fh.read()
        T("MUST FIRE  PREMISE: on Windows an open READER refuses a replace, in Python exactly as in PowerShell",
          len(refusals) > 0, "os.replace was never refused - this platform assumption has changed")
        T("MUST FIRE  an exhausted budget RAISES, names the file and says the write is not on disk",
          "after 3 attempt(s)" in err and "NOT on disk" in err and p3 in err, err or "did not raise")
        T("MUST FIRE  every attempt in the budget was really tried, counted by the refusal seam and not by a clock",
          refusals == [1, 2, 3], refusals)
        T("CLEAN TWIN  the refused file still holds exactly its previous bytes", kept == b"old", repr(kept))
        T("MUST NOT FIRE  and the temp copy of a refused write is removed rather than left as debris",
          not os.path.exists(p3 + ".tmp"), "tmp left behind")

        # ---- a reader that DOES let go: the write lands ------------------------------------------
        # The reader closes from inside the refusal seam, so the rendezvous is the replace itself.
        p4 = os.path.join(root, "lets-go.json")
        write_text_durably(p4, "old")
        reader = open(p4, "rb")
        seen = []

        def _release(attempt):
            seen.append(attempt)
            if attempt == 1:
                reader.close()

        n4 = write_text_durably(p4, "new", max_attempts=5, base_sleep_ms=1, on_refusal=_release)
        reader.close()
        with open(p4, "rb") as fh:
            landed = fh.read()
        T("MUST FIRE  a write that met a reader LANDS once the reader lets go, on the attempt after it",
          landed == b"new" and n4 > 1 and seen[:1] == [1], "%r n=%s refusals=%s" % (landed, n4, seen))

        # ---- a failure waiting cannot fix is raised AT ONCE, not after the budget -----------------
        p5 = os.path.join(root, "fail-fast.json")
        write_text_durably(p5, "old")
        gone = []
        ffErr = ""
        reader = open(p5, "rb")
        try:
            write_text_durably(p5, "new", max_attempts=40, base_sleep_ms=1,
                               on_refusal=lambda a: (gone.append(a), os.remove(p5 + ".tmp")))
        except OSError as exc:
            ffErr = str(exc)
        finally:
            reader.close()
        T("MUST NOT FIRE  the retry stops once waiting cannot help: a temp file gone mid-wait raises its own error on the next attempt",
          len(gone) == 1 and ffErr != "" and "attempt(s)" not in ffErr, "refusals=%s err=%s" % (gone, ffErr))

        # ---- a first write, where there is nothing to replace -------------------------------------
        p6 = os.path.join(root, "sub", "fresh.json")
        os.makedirs(os.path.dirname(p6))
        n6 = write_text_durably(p6, "hello")
        T("CLEAN TWIN  a file that does not exist yet is created, in one attempt",
          os.path.exists(p6) and n6 == 1, n6)
    finally:
        # One unique root per run, removed in finally: two concurrent pushes run this same suite.
        import shutil
        shutil.rmtree(root, ignore_errors=True)

    if fails:
        print("durable-write SELF-TEST FAIL: %d of %d case(s)" % (len(fails), len(ran)))
        return 2
    print("durable-write SELF-TEST PASS: %d case(s), led by the one that can actually go stale - "
          "the PREMISE that a Windows reader refuses a replace in Python the same way it does in "
          "PowerShell, which is what the retry exists for" % len(ran))
    return 0


if __name__ == "__main__":
    import argparse
    import sys

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        sys.exit(_selftest())
    print("durable_write is a library. Run it with --selftest, or import write_text_durably.")
    sys.exit(0)
