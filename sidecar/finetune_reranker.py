"""
finetune_reranker.py - train the resolve lane's own copy of the cross-encoder.

PLAN-local-matching section 6. The sweep's model is PINNED (sidecar rule 3: a swap changes every
score in the estate), so this writes a SEPARATE COPY that only the resolve lane reaches, via
--reranker. Nothing here can move the pin: it refuses to write anywhere lib_match could load by
default, and it never touches RERANK_MODEL.

NO NEW DEPENDENCIES, ON PURPOSE. sentence-transformers' own trainer wants `datasets` and
`accelerate`, and this venv is the one the 07:00 sweep runs on - installing into it to save fifty
lines of training loop would put the daily semantic auditor at the mercy of a resolver dependency.
torch + transformers are already here and are all this needs. The saved directory is a plain
AutoModelForSequenceClassification, which is exactly what `CrossEncoder(path)` loads, so the
artefact this writes is consumable by backtest.py --reranker and hardeval.py --reranker unchanged.

THE GATES (section 6 as the 2026-08-22 prep corrected it, not as written):
  - hardeval GOLD is the number that DECIDES. backtest.py's 25 negatives are all dramatically
    wrong and never ask a hard question; run both, believe GOLD.
  - "still 100% recall on the 24 known defects" cannot stand - stock itself is 17/25 today, and a
    candidate cannot be held to a bar the incumbent fails. The bar is NO WORSE THAN STOCK, same
    day, same frozen defs, both sides.
  - the holdout is by commodity FAMILY, so the test set is cold by construction. The AUC printed
    here each epoch is on that holdout; it is the training signal, not the acceptance gate.

IMBALANCE. The corpus is 2,958 positive / 4,123 negative after the near-miss mining of 2026-08-23
(before it, 6.6:1 the other way). pos_weight is set from the ACTUAL ratio in the training split and
recorded, rather than left at 1.0 and hoped for.
"""
from __future__ import annotations
import argparse, json, os, random, sys, time

import torch
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForSequenceClassification, AutoTokenizer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib_match import DEVICE, RERANK_MODEL                                     # noqa: E402
from hardeval import auc                                                       # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
MODELS = os.path.join(HERE, "models")


def log(m: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def read_jsonl(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        return [json.loads(ln) for ln in f if ln.strip()]


class Pairs(Dataset):
    def __init__(self, rows: list[dict]):
        self.rows = rows

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, i: int):
        r = self.rows[i]
        return r["query"], r["doc"], float(r["label"])


def collate(tok, max_len: int):
    def fn(batch):
        q, d, y = zip(*batch)
        enc = tok(list(q), list(d), padding=True, truncation=True,
                  max_length=max_len, return_tensors="pt")
        return enc, torch.tensor(y, dtype=torch.float)
    return fn


@torch.no_grad()
def score_all(model, tok, rows: list[dict], max_len: int, batch: int) -> list[float]:
    model.eval()
    out = []
    for i in range(0, len(rows), batch):
        chunk = rows[i:i + batch]
        enc = tok([r["query"] for r in chunk], [r["doc"] for r in chunk], padding=True,
                  truncation=True, max_length=max_len, return_tensors="pt").to(DEVICE)
        with torch.autocast("cuda", dtype=torch.bfloat16, enabled=(DEVICE == "cuda")):
            logits = model(**enc).logits.squeeze(-1).float()
        out.extend(torch.sigmoid(logits).tolist())
    return out


def holdout_auc(model, tok, rows: list[dict], max_len: int, batch: int) -> tuple[float, float]:
    s = score_all(model, tok, rows, max_len, batch)
    pos = [v for v, r in zip(s, rows) if r["label"] == 1]
    neg = [v for v, r in zip(s, rows) if r["label"] == 0]
    mined = [v for v, r in zip(s, rows) if r["label"] == 0 and r["source"] == "mined_near_miss"]
    return auc(pos, neg), (auc(pos, mined) if mined else float("nan"))


def main() -> int:
    ap = argparse.ArgumentParser(description="Fine-tune a resolve-lane copy of the cross-encoder")
    ap.add_argument("--corpus", default=os.path.join(DATA, "pair-corpus"))
    ap.add_argument("--out", default=os.path.join(MODELS, "resolve-ce-v1"))
    ap.add_argument("--base", default=RERANK_MODEL)
    ap.add_argument("--epochs", type=int, default=2)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--eval-batch", type=int, default=64)
    ap.add_argument("--lr", type=float, default=1e-5)
    ap.add_argument("--warmup", type=float, default=0.1, help="fraction of steps spent warming up")
    ap.add_argument("--max-len", type=int, default=160, help="lib_match loads the CrossEncoder at 160")
    ap.add_argument("--seed", type=int, default=20260823)
    ap.add_argument("--grad-checkpointing", action="store_true",
                    help="trade ~30%% speed for activation memory if the card is short")
    ap.add_argument("--dry-run", action="store_true", help="report the plan, load nothing, write nothing")
    a = ap.parse_args()

    # THE PIN. A candidate is a separate copy reached via --reranker; it never lands where
    # lib_match.RERANK_MODEL points and never overwrites the frozen records.
    out = os.path.abspath(a.out)
    if os.path.basename(out) in ("", ".") or out.startswith(os.path.abspath(DATA)):
        log(f"REFUSED: {out} is inside data/ - a candidate model is not an evaluation record")
        return 2

    train = read_jsonl(os.path.join(a.corpus, "train.jsonl"))
    test = read_jsonl(os.path.join(a.corpus, "test.jsonl"))
    manifest = {}
    mp = os.path.join(a.corpus, "manifest.json")
    if os.path.exists(mp):
        manifest = json.load(open(mp, encoding="utf-8"))
    tp = sum(1 for r in train if r["label"] == 1)
    tn = len(train) - tp
    pos_weight = tn / max(1, tp)
    steps = (len(train) + a.batch - 1) // a.batch * a.epochs

    log(f"base={a.base}  ->  out={out}")
    log(f"corpus={a.corpus}  defs={manifest.get('defs', 'UNRECORDED')}  "
        f"holdout={','.join(manifest.get('holdout_families', []) or ['?'])}")
    log(f"train {len(train)} (+{tp}/-{tn}, pos_weight {pos_weight:.3f})  test {len(test)}")
    log(f"{a.epochs} epoch(s), batch {a.batch}, lr {a.lr}, max_len {a.max_len}, {steps} steps")
    if DEVICE == "cuda":
        free, total = torch.cuda.mem_get_info()
        log(f"card: {free / 2**20:.0f} MiB free of {total / 2**20:.0f}")
        if free / 2**20 < 11000:
            log("REFUSED: under 11 GiB free. Something else holds the card (llama-server? the "
                "sweep?) and this box cannot host two of them.")
            return 2
    if a.dry_run:
        log("dry run; nothing loaded, nothing written")
        return 0

    random.seed(a.seed)
    torch.manual_seed(a.seed)

    tok = AutoTokenizer.from_pretrained(a.base)
    model = AutoModelForSequenceClassification.from_pretrained(a.base, num_labels=1).to(DEVICE)
    if a.grad_checkpointing:
        model.gradient_checkpointing_enable()

    base_auc, base_mined = holdout_auc(model, tok, test, a.max_len, a.eval_batch)
    log(f"BEFORE (stock, on this holdout): AUC {base_auc:.4f}  mined-only {base_mined:.4f}")

    dl = DataLoader(Pairs(train), batch_size=a.batch, shuffle=True,
                    collate_fn=collate(tok, a.max_len), drop_last=False)
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=0.01)
    sched = torch.optim.lr_scheduler.OneCycleLR(
        opt, max_lr=a.lr, total_steps=steps, pct_start=a.warmup, anneal_strategy="linear")
    lossf = torch.nn.BCEWithLogitsLoss(pos_weight=torch.tensor(pos_weight, device=DEVICE))

    history = []
    t0 = time.time()
    for ep in range(1, a.epochs + 1):
        model.train()
        run, n = 0.0, 0
        for i, (enc, y) in enumerate(dl, 1):
            enc = {k: v.to(DEVICE) for k, v in enc.items()}
            y = y.to(DEVICE)
            with torch.autocast("cuda", dtype=torch.bfloat16, enabled=(DEVICE == "cuda")):
                logits = model(**enc).logits.squeeze(-1).float()
            loss = lossf(logits, y)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            sched.step()
            opt.zero_grad(set_to_none=True)
            run += loss.item() * len(y)
            n += len(y)
            if i % 50 == 0:
                log(f"  epoch {ep} step {i}/{len(dl)}  loss {run / max(1, n):.4f}")
        ep_auc, ep_mined = holdout_auc(model, tok, test, a.max_len, a.eval_batch)
        log(f"EPOCH {ep}: train loss {run / max(1, n):.4f}  holdout AUC {ep_auc:.4f} "
            f"(stock {base_auc:.4f})  mined-only {ep_mined:.4f} (stock {base_mined:.4f})")
        history.append({"epoch": ep, "train_loss": run / max(1, n),
                        "holdout_auc": ep_auc, "holdout_auc_mined_only": ep_mined})

    os.makedirs(out, exist_ok=True)
    model.save_pretrained(out)
    tok.save_pretrained(out)
    card = {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "base": a.base, "is_the_pinned_model": (a.base == RERANK_MODEL),
        "corpus": a.corpus, "corpus_manifest": manifest,
        "hyper": {"epochs": a.epochs, "batch": a.batch, "lr": a.lr, "warmup": a.warmup,
                  "max_len": a.max_len, "seed": a.seed, "pos_weight": pos_weight,
                  "precision": "bf16 autocast, fp32 master weights"},
        "train_rows": len(train), "test_rows": len(test),
        "stock_holdout_auc": base_auc, "stock_holdout_auc_mined_only": base_mined,
        "history": history,
        "elapsed_sec": round(time.time() - t0, 1),
        "NOT_A_GATE": "the holdout AUC here is the training signal. The gate is hardeval.py "
                      "--stage score --reranker <this dir> --defs <the same frozen snapshot>, "
                      "GOLD deciding, and backtest.py alongside it.",
    }
    with open(os.path.join(out, "training-card.json"), "w", encoding="utf-8") as f:
        json.dump(card, f, indent=2, ensure_ascii=False)
    log(f"wrote {out} in {time.time() - t0:.0f}s")
    log(f"next: hardeval.py --stage score --reranker {out} --tag <name> "
        f"--defs {manifest.get('defs', 'the frozen snapshot')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
