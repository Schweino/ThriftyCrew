"""Local + Claude model clients for the ThriftyCrew graph pipeline.

Runtime policy (plan §7): the LOCAL model attempts every judgment task first.
Claude is reserved for real-browser work, contested escalations, recovery beyond
the retry limit, and Learning Stage 2. This module makes that policy mechanical:
`LocalLLM.judge()` returns a confidence, and `should_escalate()` is the single
place the threshold lives.

Two hard-won operational facts are encoded here, both discovered during Phase 0
validation on this box (RTX 5070 Ti, sm_120):

1. Qwen3.8 is a REASONING model. Left alone it spends its entire token budget in
   a `reasoning_content` block and returns an EMPTY `content`. Every structured
   call therefore sends `chat_template_kwargs={"enable_thinking": False}`.
   Measured: 400 tokens burned / empty content -> 315 tokens / valid JSON.

2. llama.cpp can GRAMMAR-CONSTRAIN output to a JSON schema. Using it turns the
   plan's ">=95% valid strict JSON" acceptance bar from a hope into a structural
   guarantee, so schema-bearing calls always pass `response_format`.
"""

from __future__ import annotations

import json
import re
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any

from ids import hash_obj, sha256

DEFAULT_ENDPOINT = os.environ.get("TC_LLM_ENDPOINT", "http://127.0.0.1:8080/v1")
DEFAULT_MODEL = os.environ.get("TC_LLM_MODEL", "local-primary")

# Escalate to Claude below this local confidence (plan §7).
ESCALATION_THRESHOLD = float(os.environ.get("TC_ESCALATE_BELOW", "0.75"))


class LLMError(RuntimeError):
    pass


@dataclass
class LLMResult:
    """One model call, with everything provenance needs."""
    content: str
    model: str
    prompt_tokens: int = 0
    completion_tokens: int = 0
    elapsed_s: float = 0.0
    reasoning: str = ""
    raw: dict = field(default_factory=dict)

    @property
    def tokens_per_s(self) -> float:
        return self.completion_tokens / self.elapsed_s if self.elapsed_s else 0.0

    @property
    def output_hash(self) -> str:
        return sha256(self.content)

    def json(self) -> Any:
        """Parse content as JSON, tolerating a stray markdown fence."""
        text = self.content.strip()
        if text.startswith("```"):
            text = text.split("\n", 1)[1] if "\n" in text else text
            text = text.rsplit("```", 1)[0]
        text = text.strip()
        if not text:
            raise LLMError("model returned empty content "
                           "(reasoning budget exhausted? pass think=False)")
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            # REGEX PAYLOADS BREAK JSON. The learning loop asks the model for
            # include patterns like \s+ and \d, and a lone backslash is not a
            # legal JSON escape — so a perfectly good proposal arrives as an
            # unparseable document and the whole batch dies (measured
            # 2026-08-20 on stage1_analyze). llama.cpp's grammar does not save
            # us here: it constrains the SHAPE of the string, not whether its
            # escapes are legal.
            #
            # Repair only what actually failed to parse, and only the invalid
            # escapes: a backslash NOT followed by one of the eight legal JSON
            # escape characters is doubled. A document that parses is never
            # touched.
            # Scan backslash+char PAIRS left to right, never re-examining a
            # consumed character. A naive lookahead is wrong and was measured
            # wrong here: on the already-correct "\\s" it skips the first
            # backslash (followed by a backslash, a legal escape) and then
            # doubles the SECOND one, producing "\\\s" — turning a valid
            # document into a broken one.
            def _fix(m):
                nxt = m.group(1)
                return m.group(0) if nxt in '"\\/bfnrtu' else '\\\\' + nxt
            repaired = re.sub(r"\\(.)", _fix, text, flags=re.S)
            return json.loads(repaired)


class LocalLLM:
    """Client for the llama.cpp OpenAI-compatible endpoint.

    timeout: 120 s per HTTP call (2026-08-22, was 600). A resolve call is ~312 tokens in
    and <= 400 out, well under a minute on this box even with four slots busy; a call
    that is still running at two minutes is a hung server or a slot starved by the GPU
    being shared, and waiting ten minutes for it only hid that. The one caller that
    legitimately needs longer - meal-prep/pipeline/local_extract.py asking for 4096
    tokens - passes its own timeout explicitly rather than lifting the default for all.
    """

    def __init__(self, endpoint: str = DEFAULT_ENDPOINT, model: str = DEFAULT_MODEL,
                 timeout: int = 120):
        self.endpoint = endpoint.rstrip("/")
        self.model = model
        self.timeout = timeout

    # -- transport ---------------------------------------------------------
    def _post(self, path: str, payload: dict) -> dict:
        req = urllib.request.Request(
            f"{self.endpoint}{path}",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raise LLMError(f"HTTP {e.code} from {self.endpoint}{path}: "
                           f"{e.read().decode('utf-8', 'replace')[:500]}") from e
        except urllib.error.URLError as e:
            raise LLMError(
                f"cannot reach local endpoint {self.endpoint} ({e.reason}). "
                f"Start it with: pwsh tools/local-llm/serve.ps1") from e

    def health(self) -> bool:
        try:
            base = self.endpoint.rsplit("/v1", 1)[0]
            with urllib.request.urlopen(f"{base}/health", timeout=5) as r:
                return json.loads(r.read()).get("status") == "ok"
        except Exception:
            return False

    # -- generation --------------------------------------------------------
    def chat(self, messages: list[dict], *, max_tokens: int = 2048,
             temperature: float = 0.1, think: bool = False,
             schema: dict | None = None, json_mode: bool = False,
             retries: int = 2) -> LLMResult:
        """One chat completion.

        think=False is the DEFAULT and is deliberate — see the module docstring.
        Pass schema= to grammar-constrain the output to a JSON Schema.
        """
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "chat_template_kwargs": {"enable_thinking": bool(think)},
        }
        if schema is not None:
            payload["response_format"] = {
                "type": "json_schema",
                "json_schema": {"name": "out", "strict": True, "schema": schema},
            }
        elif json_mode:
            payload["response_format"] = {"type": "json_object"}

        last: Exception | None = None
        for attempt in range(retries + 1):
            try:
                t0 = time.time()
                data = self._post("/chat/completions", payload)
                elapsed = time.time() - t0
                msg = (data.get("choices") or [{}])[0].get("message", {}) or {}
                usage = data.get("usage", {}) or {}
                return LLMResult(
                    content=msg.get("content") or "",
                    model=data.get("model", self.model),
                    prompt_tokens=usage.get("prompt_tokens", 0),
                    completion_tokens=usage.get("completion_tokens", 0),
                    elapsed_s=elapsed,
                    reasoning=msg.get("reasoning_content") or "",
                    raw=data,
                )
            except LLMError as e:
                last = e
                if attempt < retries:
                    time.sleep(1.5 * (attempt + 1))
                    continue
                raise
        raise LLMError(str(last))

    def json_call(self, system: str, user: str, schema: dict | None = None,
                  *, max_tokens: int = 2048, retries: int = 2) -> tuple[Any, LLMResult]:
        """Structured call returning (parsed, result). Retries a parse failure once
        with an explicit repair instruction before giving up."""
        messages = [{"role": "system", "content": system},
                    {"role": "user", "content": user}]
        res = self.chat(messages, schema=schema, json_mode=schema is None,
                        max_tokens=max_tokens, retries=retries)
        try:
            return res.json(), res
        except (json.JSONDecodeError, LLMError):
            repair = messages + [
                {"role": "assistant", "content": res.content[:1000]},
                {"role": "user", "content":
                    "That was not valid JSON. Return ONLY the corrected JSON object, "
                    "no prose and no markdown fence."},
            ]
            res2 = self.chat(repair, schema=schema, json_mode=schema is None,
                             max_tokens=max_tokens, retries=1)
            return res2.json(), res2


def should_escalate(confidence: float | None,
                    threshold: float = ESCALATION_THRESHOLD) -> bool:
    """The single place the local->Claude escalation threshold lives (plan §7)."""
    if confidence is None:
        return True
    return confidence < threshold


# --------------------------------------------------------------------------
# Claude escalation
# --------------------------------------------------------------------------

class ClaudeEscalation:
    """Escalation packet builder.

    This deliberately does NOT call the Claude API. In this estate Claude runs as
    scheduled agents with real-Chrome access and repo permissions, not as a
    library call from the daily pipeline. What the pipeline owes Claude is a
    well-formed packet: the subgraph, the local attempt, its confidence, and the
    conflicting evidence (plan §7). This builds that packet and queues it.
    """

    def __init__(self, queue_path: str):
        self.queue_path = queue_path

    @staticmethod
    def build_packet(task: str, local_attempt: Any, confidence: float | None,
                     subgraph: dict, conflicting: list | None = None,
                     step_id: str | None = None) -> dict:
        return {
            "task": task,
            "step_id": step_id,
            "local_attempt": local_attempt,
            "local_confidence": confidence,
            "subgraph": subgraph,
            "conflicting_evidence": conflicting or [],
            "packet_hash": hash_obj([task, local_attempt, subgraph]),
        }

    def enqueue(self, packet: dict, timestamp: str) -> None:
        """Append to the escalation queue.

        NOTE: like grocery/triage-queue.json this file is gitignored on purpose —
        producer and consumer are on the SAME PC, so it never crosses the
        git-bus, and its bodies can carry raw store text.
        """
        os.makedirs(os.path.dirname(self.queue_path), exist_ok=True)
        rows = []
        if os.path.exists(self.queue_path):
            try:
                with open(self.queue_path, encoding="utf-8-sig") as fh:
                    rows = json.load(fh)
            except (json.JSONDecodeError, OSError):
                rows = []
        rows.append({**packet, "queued_at": timestamp})
        with open(self.queue_path, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(rows, fh, indent=2, ensure_ascii=False)
