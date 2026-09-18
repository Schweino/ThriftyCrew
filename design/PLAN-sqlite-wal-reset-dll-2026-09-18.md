# PLAN: close SQLite's WAL-reset bug by swapping one DLL (backlog I213, option 1)

Status: READY FOR BRAD. Nothing here has been run. This changes the shared Python install, so Brad approves
it, or Brad runs it himself.

## Why

https://sqlite.org/wal.html (updated 2026-08-25) records a data race in SQLite 3.7.0 through 3.51.2. It is
fixed in 3.51.3, with backports 3.44.6 and 3.50.7. It can leave part of a committed transaction out of a WAL
database when two connections write or checkpoint at the same instant. Measured 2026-09-18 (backlog I213):
all five Python interpreters on this box report SQLite 3.49.1, `graph\sqlite\graph.db` is in WAL mode, and
nothing but the clock keeps its read-write connections apart. `meal-prep\db\thriftycrew.db` is in DELETE mode
and is not affected.

All five interpreters load `C:\Codex\Python312\DLLs\_sqlite3.pyd`, which links to
`C:\Codex\Python312\DLLs\sqlite3.dll`. So one file is the SQLite of every runtime here.

## Steps

1. Pick a quiet window: not 21:30 to 06:30 (TC Graph Nightly Matching), and not while a capture chain is
   running. Close every Python process first, because Windows will not replace a DLL that is loaded
   (`Get-Process python*`).
2. Download `sqlite-dll-win-x64-3530400.zip` from https://sqlite.org/download.html. Check its SHA3-256
   against the hash printed on that page. Extract `sqlite3.dll`.
3. Back up the current DLL: `Copy-Item C:\Codex\Python312\DLLs\sqlite3.dll
   C:\Codex\Python312\DLLs\sqlite3.dll.3.49.1.bak`. The current file is 1,583,608 bytes, md5
   8748951063B31A52634AC22D77072B1F, signed by the Python Software Foundation.
4. Copy the new `sqlite3.dll` over it.

## Checks (all must pass, or roll back)

- Each interpreter prints 3.53.4:
  `C:\Codex\Python312\python.exe`, `C:\Codex\ThriftyCrew\sidecar\.venv\Scripts\python.exe` and
  `C:\Codex\llm\.venv-train\Scripts\python.exe`, each running
  `-c "import sqlite3; print(sqlite3.sqlite_version)"`.
- Read-only checks on the live database print `wal` and `ok`:
  `PRAGMA journal_mode` and `PRAGMA quick_check` on `graph.db` through a `mode=ro` URI.
- `C:\Codex\Python312\python.exe graph\pipeline\audit_graph_durability.py` exits 0.
- One full `ops\run-gates.ps1` exits 0 (it runs the Python self-tests, including the graph ones).
- The next nightly's durability stage records ok.

## Rollback

Close every Python process, then
`Copy-Item C:\Codex\Python312\DLLs\sqlite3.dll.3.49.1.bak C:\Codex\Python312\DLLs\sqlite3.dll -Force`.
It is one file, and nothing else changes.

## Risks

- **The new DLL is unsigned.** Smart App Control reads 0 (off) on 2026-09-18. If SAC is turned back on, it
  could block an unsigned `sqlite3.dll`, and every Python that imports `sqlite3` would fail with 0xC0E90002
  (memory `smart-app-control-blocks-unsigned-binaries`). Anyone turning SAC on must roll this back first.
- **A Python reinstall or repair puts 3.49.1 back** without saying so. After any change to the Python
  install, run the version check again.
- **Behaviour changes between 3.49 and 3.53 were not reviewed.** https://sqlite.org/formatchng.html
  describes SQLite's file-format compatibility promise, so a rollback should still read the database, but
  this was not tested here. The run-gates pass and the quick_check are the evidence to look at.
