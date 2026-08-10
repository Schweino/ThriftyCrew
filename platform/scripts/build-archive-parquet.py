import json
import pathlib
import sys

import pyarrow as pa
import pyarrow.parquet as pq

if len(sys.argv) != 3:
    raise SystemExit("usage: build-archive-parquet.py <export.json> <output.parquet>")

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
document = json.loads(source.read_text(encoding="utf-8"))
rows = document.get("rows")
if not isinstance(rows, list) or not rows:
    raise SystemExit("archive export contains no rows")

table = pa.Table.from_pylist(rows)
target.parent.mkdir(parents=True, exist_ok=True)
pq.write_table(table, target, compression="zstd", version="2.6")
payload = target.read_bytes()
if payload[:4] != b"PAR1" or payload[-4:] != b"PAR1":
    raise SystemExit("generated file failed Parquet magic verification")
verified = pq.read_table(target)
if verified.num_rows != len(rows):
    raise SystemExit(f"Parquet row mismatch: expected {len(rows)}, got {verified.num_rows}")
print(json.dumps({"ok": True, "rows": verified.num_rows, "columns": verified.num_columns, "bytes": len(payload)}))
