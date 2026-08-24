"""
hunt_dispatch.py - the judgment-call dispatch adapter (PLAN-recipe-hunter-v3 section 4.1a, D9).

    python hunt_dispatch.py --selftest
    python hunt_dispatch.py --agent recipe-source-qa --prompt-file p.txt [--reconstruct] [--json]

WHAT THIS IS. The daemon owns mechanics; judgment still goes to a Claude agent. This is the one road
those calls take: a headless `claude -p` invocation whose agent, model, effort and tool list come from
`.claude\\agents\\<name>.md` and from nowhere else (section 4.4a: the frontmatter is the single
authority, and nothing in v3 hardcodes a model).

THE ROAD, CORRECTED 2026-08-24 AND MEASURED ON CLI 2.1.173.
Section 4.1a was written on the premise that "`claude -p` cannot invoke a named subagent as its
top-level agent - subagents in `.claude\\agents\\` are things a running session delegates to, not
entry points", and therefore ordered the adapter to RECONSTRUCT each agent from its definition file
(--model + --append-system-prompt <body> + --allowedTools <list>). That premise is false on this CLI,
and the measurement is in the drill report:

    echo <prompt> | claude -p --agent recipe-source-qa --output-format json
      -> result "WebFetch, Read, Grep, Glob, Bash, PowerShell" when asked to name its own tools,
         which is that agent's frontmatter list EXACTLY;
      -> modelUsage carries claude-fable-5, which is that agent's frontmatter model;
      -> num_turns 1, one context. Nothing delegates to anything.

So `--agent` is the PRIMARY road, and it is better than the reconstruction the plan ordered for a
reason beyond convenience: reconstruction makes this file a SECOND reader of the frontmatter, and two
readers of one authority is how the estate's forked-taxonomy defects start. With --agent the CLI reads
the file and this adapter cannot disagree with it.

The reconstruction road is still built, still fixtured, and still one flag away (`reconstruct=True`).
It is the fallback if a future CLI drops --agent, and it is what the drill diffs the primary road
against.

WHAT IS STILL THIS FILE'S JOB, unchanged from 4.1a:
  * parse the frontmatter anyway - for `effort` (passed explicitly; the same value the file states, so
    it cannot disagree) and to CHECK that the model which actually ran is the model the file pins;
  * parse the JSON result envelope;
  * validate the payload against the stage schema HERE, in the daemon's own process;
  * re-ask ONCE on schema failure, quoting every named violation, and NEVER auto-coerce. On the
    phase-1 gate run a decider whose prompt spelled out the closed enums still returned nine invented
    values; silently coercing an invented taxonomy into a legal one is how a ledger stops noticing it
    is being forked;
  * a transport or timeout failure is a null - STUCK, never a verdict (B5).

EXIT CODES (section 4.5): 0 clean / 1 findings / 2 could-not-run. Marker HUNT-DISPATCH-COMPLETE.
INTERPRETER: C:\\Codex\\Python312\\python.exe.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)
sys.path.insert(0, HERE)

import hunt_lib                                                  # noqa: E402

AGENT_DIR = os.path.join(REPO, ".claude", "agents")
CLAUDE_BIN = os.environ.get("TC_CLAUDE_BIN", "claude")


# =====================================================================================================
# The agent definition file is the authority. This reads it; it never overrides it.
# =====================================================================================================

class AgentDef(object):
    __slots__ = ("name", "model", "effort", "tools", "body", "path", "description")

    def __init__(self, name, model, effort, tools, body, path, description):
        self.name = name
        self.model = model
        self.effort = effort
        self.tools = tools          # [] means the frontmatter declared none, i.e. ALL tools
        self.body = body
        self.path = path
        self.description = description

    def as_dict(self):
        return {"name": self.name, "model": self.model, "effort": self.effort,
                "tools": list(self.tools), "body_bytes": len(self.body.encode("utf-8")),
                "path": self.path}


def parse_agent(name, agent_dir=None):
    """Read `.claude\\agents\\<name>.md`. Raises if it is missing - a dispatch to an agent nobody
    defined must never fall back to 'the default agent', which would run the wrong model silently."""
    path = os.path.join(agent_dir or AGENT_DIR, "%s.md" % name)
    if not os.path.exists(path):
        raise FileNotFoundError("no agent definition at %s" % path)
    with open(path, "r", encoding="utf-8-sig") as f:
        text = f.read().replace("\r\n", "\n")
    if not text.startswith("---\n"):
        raise ValueError("%s has no frontmatter block" % path)
    end = text.find("\n---\n", 3)
    if end < 0:
        raise ValueError("%s has an unterminated frontmatter block" % path)
    fm_text, body = text[4:end + 1], text[end + 5:]
    fm = {}
    for line in fm_text.split("\n"):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", line)
        if m:
            fm[m.group(1).strip()] = m.group(2).strip()
    tools = [t.strip() for t in (fm.get("tools") or "").split(",") if t.strip()]
    return AgentDef(name=fm.get("name") or name, model=fm.get("model") or "",
                    effort=fm.get("effort") or "", tools=tools, body=body.strip(), path=path,
                    description=fm.get("description") or "")


def model_matches(pinned, model_usage_keys):
    """Did the model the frontmatter pins actually run?

    Alias-aware, because the frontmatter legitimately writes `fable` where the API reports
    `claude-fable-5`. Deliberately NOT a prefix match: `opus-5` must not be satisfied by
    `claude-opus-4-8`, which is exactly the confusion a silent tier drop would hide behind.

    A headless invocation also bills a small auxiliary model call (measured: ~450 input tokens of
    haiku alongside every dispatch, for the CLI's own housekeeping). That is why this asks whether the
    pinned model is PRESENT rather than whether it is the only one.
    """
    want = str(pinned or "").strip().lower()
    if not want:
        return True, "the frontmatter pins no model, so nothing was overridden"
    want = want[len("claude-"):] if want.startswith("claude-") else want
    keys = [str(k).lower() for k in (model_usage_keys or [])]
    for k in keys:
        bare = k[len("claude-"):] if k.startswith("claude-") else k
        if bare == want or bare.startswith(want + "-") or bare == want.replace("claude-", ""):
            return True, k
    return False, ("the frontmatter pins %r and the call billed %s - the pin was dropped"
                   % (pinned, ", ".join(keys) or "nothing"))


# =====================================================================================================
# The dispatch
# =====================================================================================================

class DispatchResult(object):
    """What the daemon gets back. `payload` is None whenever no usable verdict exists, and `failure`
    says which kind of nothing it is - the distinction B5 exists to preserve."""

    __slots__ = ("agent", "payload", "text", "failure", "detail", "problems", "reasked",
                 "tokens_in", "tokens_out", "cache_read", "cache_creation", "cost_usd",
                 "seconds", "calls", "api_turns", "model_usage", "session_id", "denials", "findings")

    def __init__(self, agent):
        self.agent = agent
        self.payload = None
        self.text = ""
        self.failure = None        # None | transport | timeout | empty | schema
        self.detail = ""
        self.problems = []
        self.reasked = False
        self.tokens_in = 0         # input + cache_read + cache_creation, the lane-tokens.ps1 rule
        self.tokens_out = 0
        self.cache_read = 0
        self.cache_creation = 0
        self.cost_usd = 0.0
        self.seconds = 0.0
        self.calls = 0
        # F (2026-08-24, off the 6b run). `calls` counts BILLED CLI INVOCATIONS - a re-ask makes it 2 -
        # and criterion 1 depends on it meaning exactly that. It is NOT the number of API round trips,
        # and the round trips are what actually drive cost: every one re-reads the whole conversation,
        # so a session that made 47 of them billed ~500k tokens while `calls` read 1. Diagnosing the 6b
        # run therefore needed transcript archaeology outside the pipeline - the very thing C1 was built
        # to end. The envelope has carried `num_turns` all along and nothing read it.
        self.api_turns = 0
        self.model_usage = {}
        self.session_id = ""
        self.denials = []
        self.findings = []

    @property
    def ok(self):
        return self.payload is not None

    @property
    def all_models(self):
        """C1: (all_in, all_out, cost, names) across EVERY model this dispatch billed, subagents
        included. Derived rather than stored, so it can never disagree with model_usage."""
        return model_usage_totals(self.model_usage)

    def as_dict(self):
        return {"agent": self.agent, "ok": self.ok, "failure": self.failure, "detail": self.detail,
                "problems": list(self.problems), "reasked": self.reasked,
                "tokens_in": self.tokens_in, "tokens_out": self.tokens_out,
                "cache_read": self.cache_read, "cache_creation": self.cache_creation,
                "cost_usd": round(self.cost_usd, 6), "seconds": round(self.seconds, 2),
                "calls": self.calls, "api_turns": self.api_turns, "model_usage": self.model_usage,
                "all_models_in": self.all_models[0], "all_models_out": self.all_models[1],
                "all_models_cost_usd": self.all_models[2], "models": self.all_models[3],
                "denials": self.denials, "findings": list(self.findings),
                "payload": self.payload, "text": self.text[:2000]}


# C1 (added 2026-08-24, phase 6a / pin P10). THE PER-MODEL KEY NAMES ARE READ OFF A REAL ENVELOPE, NOT
# GUESSED. Taken from a phase-5 gate transcript on 2026-08-24, verbatim:
#
#   "modelUsage":{"claude-haiku-4-5-20251001":{"inputTokens":447,"outputTokens":12,
#                 "cacheReadInputTokens":0,"cacheCreationInputTokens":0,"webSearchRequests":0,
#                 "costUSD":0.000507,"contextWindow":200000,"maxOutputTokens":32000},
#                 "claude-fable-5":{"inputTokens":1,"outputTokens":4,...}}
#
# camelCase per model, snake_case in the top-level `usage` block - the two blocks do NOT share a
# spelling, which is exactly the sort of thing a guess gets wrong in a way nothing notices.
#
# WHY IT MATTERS. Top-level `usage` covers the MAIN AGENT ONLY. The phase-5 mapper batch spawned a
# 21-turn Opus subagent that appeared in no lane stamp and no ledger - $1.64 of invisible spend - and
# `modelUsage` is the one place in the envelope where it shows up at all.
MODEL_USAGE_KEYS = ("inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens")


def model_usage_totals(model_usage):
    """Sum a modelUsage map into (all_in, all_out, cost, model_names).

    `all_in` follows lane-tokens.ps1's rule exactly as DispatchResult.tokens_in does: input plus cache
    read plus cache write. A total that counted only uncached input would read as a rounding error next
    to the real bill.
    """
    all_in = all_out = 0
    cost = 0.0
    names = []
    for name, u in sorted((model_usage or {}).items()):
        if not isinstance(u, dict):
            continue
        names.append(str(name))
        all_in += (int(u.get("inputTokens") or 0)
                   + int(u.get("cacheReadInputTokens") or 0)
                   + int(u.get("cacheCreationInputTokens") or 0))
        all_out += int(u.get("outputTokens") or 0)
        try:
            cost += float(u.get("costUSD") or 0.0)
        except (TypeError, ValueError):
            pass
    return all_in, all_out, round(cost, 6), names


def build_argv(agent, reconstruct=False, extra=None):
    """The exact argv. Kept separate from the call so the fixtures can assert its SHAPE without
    spending a token - the shape is what carries the model pin and the tool contract."""
    argv = [CLAUDE_BIN, "-p", "--output-format", "json"]
    if reconstruct:
        # THE FALLBACK ROAD - section 4.1a as originally written. Every field re-stated by this
        # process rather than read by the CLI.
        if agent.model:
            argv += ["--model", agent.model]
        argv += ["--append-system-prompt", agent.body]
        if agent.tools:
            argv += ["--allowedTools", ",".join(agent.tools)]
    else:
        argv += ["--agent", agent.name]
    if agent.effort:
        argv += ["--effort", agent.effort]
    argv += list(extra or [])
    return argv


def _run(argv, prompt, timeout, cwd=None):
    """One headless invocation. The prompt goes on STDIN, never in argv: Windows caps a command line
    at 32,767 characters and a dossier batch alone can approach that, and `--tools`-style variadic
    flags will happily swallow a positional prompt (measured 2026-08-24: `--tools "" <prompt>` exits
    with 'Input must be provided either through stdin or as a prompt argument')."""
    t0 = time.time()
    try:
        p = subprocess.run(argv, input=prompt.encode("utf-8"), capture_output=True,
                           timeout=timeout, cwd=cwd or REPO)
    except subprocess.TimeoutExpired:
        return None, "timeout", "no answer within %ss" % timeout, round(time.time() - t0, 2)
    except OSError as e:
        return None, "transport", "could not start %s (%s)" % (argv[0], e), round(time.time() - t0, 2)
    secs = round(time.time() - t0, 2)
    out = (p.stdout or b"").decode("utf-8", errors="replace")
    err = (p.stderr or b"").decode("utf-8", errors="replace")
    if p.returncode != 0 and not out.strip():
        return None, "transport", ("claude exited %d: %s" % (p.returncode, (err or "").strip()[:300])), secs
    try:
        env = json.loads(out)
    except Exception:
        return None, "transport", "the result envelope did not parse: %s" % out.strip()[:300], secs
    return env, None, "", secs


_FENCE = re.compile(r"```(?:json)?\s*(.*?)```", re.S)


def extract_payload(text):
    """Pull the JSON object out of an agent's answer. A model that wraps its verdict in a fence or in
    a sentence has still answered; a model that returned prose has not, and that must read as a schema
    failure rather than as a transport one - the two get different treatment (re-ask vs STUCK)."""
    if not text:
        return None
    for m in _FENCE.finditer(text):
        try:
            return json.loads(m.group(1).strip())
        except Exception:
            continue
    s = text.strip()
    try:
        return json.loads(s)
    except Exception:
        pass
    # last resort: the outermost balanced {...}
    start = s.find("{")
    while start >= 0:
        depth, in_str, esc = 0, False, False
        for i in range(start, len(s)):
            c = s[i]
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
                continue
            if c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(s[start:i + 1])
                    except Exception:
                        break
        start = s.find("{", start + 1)
    return None


def _absorb(res, env):
    u = (env or {}).get("usage") or {}
    res.tokens_in += (int(u.get("input_tokens") or 0)
                      + int(u.get("cache_read_input_tokens") or 0)
                      + int(u.get("cache_creation_input_tokens") or 0))
    res.tokens_out += int(u.get("output_tokens") or 0)
    res.cache_read += int(u.get("cache_read_input_tokens") or 0)
    res.cache_creation += int(u.get("cache_creation_input_tokens") or 0)
    res.cost_usd += float(env.get("total_cost_usd") or 0.0)
    res.calls += 1
    # ACCUMULATED, like calls and tokens: a re-asked dispatch made round trips in BOTH sessions and
    # the cost of both is real. 0 when the envelope omits it, which reads as "not reported" downstream
    # rather than as a session that somehow made no calls.
    res.api_turns += int(env.get("num_turns") or 0)
    # MERGED, NOT OVERWRITTEN (C1, 2026-08-24). A re-ask is a SECOND billed call, and `res.calls`,
    # `tokens_in` and `cost_usd` all accumulate across the pair. Replacing the map here made the
    # subagent-inclusive total report only the LAST call's models, which on a re-asked dispatch is the
    # cheaper half - a stamp that understates exactly the dispatches worth looking at.
    for _m, _u in (env.get("modelUsage") or {}).items():
        if not isinstance(_u, dict):
            continue
        prev = res.model_usage.get(_m)
        if not isinstance(prev, dict):
            res.model_usage[_m] = dict(_u)
            continue
        merged = dict(prev)
        for _k in MODEL_USAGE_KEYS:
            merged[_k] = int(prev.get(_k) or 0) + int(_u.get(_k) or 0)
        try:
            merged["costUSD"] = float(prev.get("costUSD") or 0.0) + float(_u.get("costUSD") or 0.0)
        except (TypeError, ValueError):
            pass
        res.model_usage[_m] = merged
    res.session_id = env.get("session_id") or res.session_id
    for d in env.get("permission_denials") or []:
        res.denials.append(d if isinstance(d, str) else json.dumps(d)[:200])


RETURN_CONTRACT = """

-------------------------------------------------------------------------------
RETURN CONTRACT for this stage. Answer with ONE JSON object and nothing else
after it. Required fields (the answer is REFUSED WHOLE without them):
%s
The full shape, optional fields included:
%s
Everything you would otherwise write as a report goes in the free-text field of
that object. A rich report in any other shape is not an answer.
-------------------------------------------------------------------------------
"""


def contract_text(schema):
    """The required-field contract, DERIVED from the schema the caller passed.

    WHY THE ADAPTER APPENDS THIS AND NOT EACH PROMPT (added 2026-08-24, found live by the phase-4 gate
    run). The adapter validates against the stage schema and re-asks once quoting the violations - but
    on the FIRST call it was telling the agent nothing about the shape at all. Every daemon prompt was
    therefore carrying its own return contract or, more often, not carrying one: the phase-4 write lane
    dispatched six writers and every one returned its own rich report shape
    ({blockers, data_flags, recommended_next_action, ...}) with no `status` field, burned the one
    re-ask, and came back NO VERDICT. 259k input tokens for a refusal, five times, until the breaker
    opened - which is the breaker doing its job on a defect that was ours.

    A prompt is the wrong home for it. There are seven lanes, each with its own prompt, and a contract
    that lives in seven places is a contract that drifts in six of them; the schema is already the
    single authority and this is read straight off it. Derived, never quoted.
    """
    if not schema:
        return ""
    props = (schema.get("properties") or {})
    req = list(schema.get("required") or [])
    lines = []
    for k in req:
        d = (props.get(k) or {}).get("description") or (props.get(k) or {}).get("type") or ""
        lines.append("  - %s%s" % (k, ("   (%s)" % d) if d else ""))
    if not lines:
        lines.append("  (none named, but the answer must still be one JSON object)")
    return RETURN_CONTRACT % ("\n".join(lines), json.dumps(schema, indent=2)[:1200])


REASK_PREAMBLE = """Your previous answer did not conform to the schema this stage requires, so it was
REFUSED WHOLE and nothing was written. Nothing has been coerced or half-applied on your behalf.

The named violations, every one of them:
%s

What you returned:
%s

Return the SAME judgment again, corrected against those violations and nothing else. Do not soften a
verdict to make it fit, and do not invent a value to fill a field - if a legal value does not describe
what you found, say so in the reason and pick the closest legal one, because a value outside the
closed set mints an identity nothing downstream will ever match again.

Answer with the JSON object only.
"""


def dispatch(agent_name, prompt, schema=None, validator=None, timeout=None, reconstruct=False,
             agent_dir=None, cwd=None, runner=None):
    """One judgment call. Returns a DispatchResult; `payload is None` means NO VERDICT (B5).

    `validator` is an extra check run after the schema one - hunt_lib.validate_decide is the caller
    the DECIDE enums exist for. Both feed the SAME single re-ask, so an answer with a missing field
    and an invented enum value is corrected once rather than twice.
    """
    timeout = hunt_lib.DISPATCH_TIMEOUT if timeout is None else timeout
    # Resolved HERE rather than inside _run, so an injected runner sees the same working directory the
    # real one would. A default that only the real path applies is a default the fixtures cannot check.
    cwd = cwd or REPO
    agent = parse_agent(agent_name, agent_dir)
    res = DispatchResult(agent_name)
    call = runner or _run
    argv = build_argv(agent, reconstruct=reconstruct)

    # THE CONTRACT RIDES WITH THE FIRST CALL, not only with the re-ask. See contract_text().
    env, failure, detail, secs = call(argv, prompt + contract_text(schema), timeout, cwd)
    res.seconds += secs
    if failure:
        res.failure, res.detail = failure, detail
        return res
    _absorb(res, env)

    ok_model, why = model_matches(agent.model, (env.get("modelUsage") or {}).keys())
    if not ok_model:
        # RECORDED, not refused. The pin is the frontmatter's to state and the CLI's to honor; this
        # adapter noticing a disagreement is worth more than this adapter overriding one.
        res.findings.append("MODEL PIN: " + why)

    if env.get("is_error"):
        res.failure = "transport"
        res.detail = "the CLI reported is_error (%s)" % (env.get("api_error_status") or "no status")
        return res

    res.text = str(env.get("result") or "")

    # ---- B1 / PIN P1: NO SCHEMA AND NO VALIDATOR MEANS THE TEXT *IS* THE VERDICT. ----------------
    # Measured on the phase-5 gate run: the price lane passes neither, so extract_payload returned
    # None on every single pricer call, `problems` read "the answer carried no JSON object at all",
    # and a WHOLE SECOND SESSION was bought to demand an object nobody wanted - 15 turns and ~$0.61
    # per batch, 15% of the lane, for a payload the lane never reads (the price lane derives every
    # recipe state from the QUEUE, never from the answer).
    #
    # AND THE OBVIOUS FIX IS THE ONE THAT BREAKS THE LANE, so it is written out here rather than left
    # to be re-derived. "Skip extraction when schema-less" leaves `payload` None; `ok` is
    # `payload is not None`; Daemon.dispatch returns `res.payload`; and with_retry reads None as NO
    # VERDICT - up to MAX_STAGE_RETRIES fresh pricer sessions, then STUCK, with the breaker counting
    # every one as a failure. That costs far more than the re-ask it removes. So the text is PROMOTED
    # to a payload instead: `ok` stays payload-based and nothing upstream changes shape.
    #
    # An EMPTY answer is still nothing. With no schema there is no second thing to check, so an empty
    # result is `empty` - a named kind of nothing (B5), never a verdict made of a blank string.
    if schema is None and validator is None:
        if not res.text.strip():
            res.failure = "empty"
            res.detail = ("the answer was empty, and with no schema the text IS the verdict - so there "
                          "is no verdict here")
            return res
        res.payload = {"text": res.text}
        return res

    payload = extract_payload(res.text)
    problems = []
    if payload is None:
        problems = ["the answer carried no JSON object at all"]
    else:
        if schema:
            problems += hunt_lib.validate_schema(payload, schema)
        if validator:
            problems += list(validator(payload) or [])
    if not problems:
        res.payload = payload
        return res

    # ---- ONE re-ask, quoting every named violation. Never a coercion, never a second re-ask. -------
    res.reasked = True
    res.problems = list(problems)
    reask = (REASK_PREAMBLE % ("\n".join("  - " + p for p in problems), res.text[:4000])
             + "\n\nTHE ORIGINAL REQUEST FOLLOWS.\n\n" + prompt + contract_text(schema))
    env2, failure2, detail2, secs2 = call(argv, reask, timeout, cwd)
    res.seconds += secs2
    if failure2:
        res.failure, res.detail = failure2, detail2
        return res
    _absorb(res, env2)
    if env2.get("is_error"):
        res.failure = "transport"
        res.detail = "the re-ask reported is_error"
        return res
    res.text = str(env2.get("result") or "")
    payload2 = extract_payload(res.text)
    problems2 = []
    if payload2 is None:
        problems2 = ["the re-ask carried no JSON object either"]
    else:
        if schema:
            problems2 += hunt_lib.validate_schema(payload2, schema)
        if validator:
            problems2 += list(validator(payload2) or [])
    if problems2:
        res.failure = "schema"
        res.problems = list(problems2)
        res.detail = ("the re-ask still does not conform (%d violation(s)); NOTHING was written - "
                      "half a verdict on disk is worse than none" % len(problems2))
        return res
    res.payload = payload2
    return res


# =====================================================================================================
# FIXTURES. The dispatch itself is INJECTED (`runner`), so everything below runs for zero tokens. What
# is under test is the adapter: the argv it builds, the envelope it reads, what it re-asks, and what it
# refuses. The one thing a fixture cannot prove is that the CLI honors --agent, which is why the drill
# exists and why its measurement is recorded in the drill report rather than asserted here.
# =====================================================================================================

def _model_row(in_tok, out_tok, cache_read=0, cache_creation=0, cost=0.01):
    """One modelUsage value, in the REAL envelope's own spelling. Frozen 2026-08-24 from a phase-5 gate
    transcript: camelCase per model, snake_case in the top-level `usage` block, and the two do not
    share a spelling - which is exactly the sort of thing a guess gets wrong in a way nothing notices.
    """
    return {"inputTokens": in_tok, "outputTokens": out_tok,
            "cacheReadInputTokens": cache_read, "cacheCreationInputTokens": cache_creation,
            "webSearchRequests": 0, "costUSD": cost,
            "contextWindow": 200000, "maxOutputTokens": 32000}


def _env(result_text, in_tok=100, out_tok=50, cache_read=0, cache_creation=0, model="claude-fable-5",
         is_error=False, extra_models=None):
    mu = {model: _model_row(in_tok, out_tok, cache_read, cache_creation)}
    for name, row in (extra_models or {}).items():
        mu[name] = row
    return {"type": "result", "subtype": "success", "is_error": is_error, "result": result_text,
            "session_id": "s1", "total_cost_usd": 0.01, "num_turns": 1, "permission_denials": [],
            # `usage` covers THE MAIN AGENT ONLY. That is the whole reason C1 also reads modelUsage.
            "usage": {"input_tokens": in_tok, "output_tokens": out_tok,
                      "cache_read_input_tokens": cache_read,
                      "cache_creation_input_tokens": cache_creation},
            "modelUsage": mu}


class FakeRunner(object):
    """Returns a scripted envelope per call and records the argv and prompt it was given."""

    def __init__(self, script):
        self.script = list(script)
        self.calls = []

    def __call__(self, argv, prompt, timeout, cwd):
        self.calls.append({"argv": list(argv), "prompt": prompt, "timeout": timeout, "cwd": cwd})
        step = self.script.pop(0) if self.script else ("env", _env("{}"))
        kind, val = step
        if kind == "env":
            return val, None, "", 0.5
        return None, kind, val, 0.5


def selftest():
    import shutil                                                # noqa: PLC0415
    import tempfile                                              # noqa: PLC0415
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    print("hunt_dispatch self-test  (every dispatch is injected: zero tokens)")
    print("")

    # ---- the frontmatter is the authority, and it is READ, never restated ------------------------
    tmp = tempfile.mkdtemp(prefix="agentdefs-")
    try:
        def write_agent(name, fm, body="You are a test agent.\n\nRAILS:\n- do the thing"):
            with open(os.path.join(tmp, name + ".md"), "w", encoding="utf-8") as f:
                f.write("---\n" + fm + "\n---\n\n" + body + "\n")

        write_agent("t-full", "name: t-full\nmodel: claude-opus-4-8\neffort: high\n"
                              "tools: Read, Grep, Glob")
        write_agent("t-notools", "name: t-notools\nmodel: fable\neffort: medium")
        a = parse_agent("t-full", tmp)
        T("the frontmatter's model, effort and tool list are read verbatim",
          a.model == "claude-opus-4-8" and a.effort == "high" and a.tools == ["Read", "Grep", "Glob"],
          json.dumps(a.as_dict()))
        T("the body is everything after the frontmatter block",
          a.body.startswith("You are a test agent.") and "RAILS" in a.body, a.body[:60])
        b = parse_agent("t-notools", tmp)
        T("CLEAN TWIN an agent declaring no tools yields an EMPTY list, which means all tools - not "
          "an invented default",
          b.tools == [], str(b.tools))
        threw = False
        try:
            parse_agent("t-missing", tmp)
        except FileNotFoundError:
            threw = True
        T("MUST FIRE  a dispatch to an agent nobody defined raises rather than silently running the "
          "default agent on the wrong model", threw, "it fell back")

        # ---- the argv, both roads --------------------------------------------------------------
        primary = build_argv(a)
        T("MUST FIRE  the primary road names the AGENT and never a model - the CLI reads the pin, so "
          "this adapter cannot disagree with it",
          "--agent" in primary and "t-full" in primary and "--model" not in primary,
          " ".join(primary))
        T("the frontmatter's effort rides along (--effort exists on CLI 2.1.173; section 4.1a "
          "predates it)",
          primary[primary.index("--effort") + 1] == "high", " ".join(primary))
        T("every dispatch asks for the JSON envelope",
          primary[primary.index("--output-format") + 1] == "json", " ".join(primary))
        recon = build_argv(a, reconstruct=True)
        T("CLEAN TWIN the fallback road restates model, body and tools (section 4.1a as written)",
          recon[recon.index("--model") + 1] == "claude-opus-4-8"
          and recon[recon.index("--allowedTools") + 1] == "Read,Grep,Glob"
          and recon[recon.index("--append-system-prompt") + 1].startswith("You are a test agent."),
          " ".join(x[:30] for x in recon))
        recon2 = build_argv(b, reconstruct=True)
        T("MUST FIRE  the fallback road omits --allowedTools for an agent that declares none, rather "
          "than passing an empty list and disabling every tool",
          "--allowedTools" not in recon2, " ".join(recon2))

        # ---- B5: a transport failure is a null, never a verdict --------------------------------
        print("")
        r = dispatch("t-full", "go", schema=hunt_lib.STAGE, agent_dir=tmp,
                     runner=FakeRunner([("transport", "claude exited 1: auth expired")]))
        T("MUST FIRE  B5 - a transport failure is a null, never a verdict",
          r.payload is None and r.failure == "transport" and not r.reasked, str(r.as_dict())[:200])
        r = dispatch("t-full", "go", schema=hunt_lib.STAGE, agent_dir=tmp,
                     runner=FakeRunner([("timeout", "no answer within 3600s")]))
        T("MUST FIRE  B5 - a timeout is a null too, and it says which kind of nothing it was",
          r.payload is None and r.failure == "timeout", str(r.failure))
        r = dispatch("t-full", "go", schema=hunt_lib.STAGE, agent_dir=tmp,
                     runner=FakeRunner([("env", _env("", is_error=True))]))
        T("MUST FIRE  is_error in the envelope is a transport failure, not an empty verdict",
          r.payload is None and r.failure == "transport", str(r.failure))

        # ---- the happy path, and the token stamp ------------------------------------------------
        print("")
        good = json.dumps({"slug": "s", "status": "ok", "state": "extracted"})
        fr = FakeRunner([("env", _env(good, in_tok=12, out_tok=340, cache_read=21142,
                                      cache_creation=10235))])
        r = dispatch("t-full", "go", schema=hunt_lib.STAGE, agent_dir=tmp, runner=fr)
        T("CLEAN TWIN a conforming answer lands with no re-ask",
          r.ok and not r.reasked and r.payload["slug"] == "s", str(r.as_dict())[:200])
        T("MUST FIRE  the input stamp counts cache reads and cache writes as input, exactly as "
          "lane-tokens.ps1 does - a lane log that reported 12 here would be a fiction",
          r.tokens_in == 12 + 21142 + 10235 and r.tokens_out == 340,
          "in=%d out=%d" % (r.tokens_in, r.tokens_out))
        T("the prompt travels on stdin, never in argv (Windows caps a command line at 32,767 chars)",
          fr.calls[0]["prompt"].startswith("go") and "go" not in fr.calls[0]["argv"],
          " ".join(fr.calls[0]["argv"]))
        # THE RETURN CONTRACT RIDES WITH THE FIRST CALL (added 2026-08-24, found live). The adapter
        # validated against the schema and re-asked quoting the violations, while the first call told
        # the agent nothing about the shape at all. The phase-4 write lane dispatched six writers,
        # every one returned its own rich report shape with no `status`, burned the one re-ask and
        # came back NO VERDICT - 259k input tokens per refusal until the breaker opened.
        T("MUST FIRE  the FIRST call carries the required-field contract, derived from the schema",
          "RETURN CONTRACT" in fr.calls[0]["prompt"] and "- slug" in fr.calls[0]["prompt"],
          fr.calls[0]["prompt"][:200])
        T("CLEAN TWIN a dispatch with NO schema gets no contract appended - nothing to derive one from",
          contract_text(None) == "", contract_text(None)[:80])
        T("the call runs at the repo root, so the estate's settings and CLAUDE.md apply",
          fr.calls[0]["cwd"] == REPO, str(fr.calls[0]["cwd"]))

        # ---- payload extraction -----------------------------------------------------------------
        print("")
        for label, text in (("a bare object", good),
                            ("a fenced object", "Here it is:\n```json\n%s\n```\n" % good),
                            ("an object inside prose", "I ruled as follows: %s  - done." % good)):
            r = dispatch("t-full", "go", schema=hunt_lib.STAGE, agent_dir=tmp,
                         runner=FakeRunner([("env", _env(text))]))
            T("the verdict is found when the model returns %s" % label, r.ok, str(r.problems))
        r = dispatch("t-full", "go", schema=hunt_lib.STAGE, agent_dir=tmp,
                     runner=FakeRunner([("env", _env("I could not do this.")),
                                        ("env", _env("Still no."))]))
        T("MUST FIRE  prose with no JSON is a SCHEMA failure (one re-ask), not a transport failure "
          "(straight to STUCK) - the two get different treatment on purpose",
          r.payload is None and r.failure == "schema" and r.reasked, str(r.failure))

        # ---- THE ONE RE-ASK, and the refusal to coerce -------------------------------------------
        print("")
        bad_then_good = FakeRunner([
            ("env", _env(json.dumps({"slug": "s", "status": "ok"}))),          # `state` missing
            ("env", _env(good))])
        r = dispatch("t-full", "go", schema=hunt_lib.STAGE, agent_dir=tmp, runner=bad_then_good)
        T("MUST FIRE  a schema failure buys exactly ONE re-ask, and the corrected answer lands",
          r.ok and r.reasked and r.calls == 2, "calls=%d ok=%s" % (r.calls, r.ok))
        T("MUST FIRE  the re-ask QUOTES the named violation back to the agent",
          "state" in bad_then_good.calls[1]["prompt"]
          and "REFUSED WHOLE" in bad_then_good.calls[1]["prompt"],
          bad_then_good.calls[1]["prompt"][:160])
        T("MUST FIRE  the re-ask carries the ORIGINAL request too - a correction with no question "
          "attached is a different question",
          ("\n\ngo" in bad_then_good.calls[1]["prompt"]), "the original prompt was dropped")
        T("MUST FIRE  the re-ask shows the agent what it actually returned",
          '"slug": "s"' in bad_then_good.calls[1]["prompt"]
          or '"slug":"s"' in bad_then_good.calls[1]["prompt"],
          "the prior answer was not quoted")
        twice_bad = FakeRunner([("env", _env(json.dumps({"slug": "s", "status": "ok"}))),
                                ("env", _env(json.dumps({"slug": "s"})))])
        r = dispatch("t-full", "go", schema=hunt_lib.STAGE, agent_dir=tmp, runner=twice_bad)
        T("MUST FIRE  a second failure is NOT a second re-ask - one, then refuse whole",
          r.payload is None and r.failure == "schema" and r.calls == 2 and not twice_bad.script,
          "calls=%d" % r.calls)
        T("MUST FIRE  and the refusal names every surviving violation rather than the first",
          len(r.problems) == 2, json.dumps(r.problems))

        # ---- enum violations ARE schema failures, and are never coerced -------------------------
        print("")
        invented = {"decisions": [{"slug": "a", "verdict": "accepted", "reason": "r",
                                   "record": {"name": "A", "protein": "turkey/beef",
                                              "method": "soup/stew", "verdict": "accepted",
                                              "reason": "r"}}]}
        legal = {"decisions": [{"slug": "a", "verdict": "accepted", "reason": "r",
                                "record": {"name": "A", "protein": "turkey", "method": "any",
                                           "verdict": "accepted", "reason": "r"}}]}
        methods = {"skillet", "bake", "any"}
        enum_run = FakeRunner([("env", _env(json.dumps(invented))),
                               ("env", _env(json.dumps(legal)))])
        r = dispatch("t-full", "rule on these", schema=hunt_lib.DECIDE,
                     validator=lambda p: hunt_lib.validate_decide(p, methods=methods),
                     agent_dir=tmp, runner=enum_run)
        T("MUST FIRE  an invented enum value is a schema failure and the re-ask names BOTH of them "
          "(`turkey/beef` and `soup/stew` were really returned on 2026-08-23)",
          "turkey/beef" in enum_run.calls[1]["prompt"] and "soup/stew" in enum_run.calls[1]["prompt"],
          enum_run.calls[1]["prompt"][:200])
        T("CLEAN TWIN the corrected verdict lands",
          r.ok and r.payload["decisions"][0]["record"]["protein"] == "turkey", str(r.problems))
        never = FakeRunner([("env", _env(json.dumps(invented))), ("env", _env(json.dumps(invented)))])
        r = dispatch("t-full", "rule", schema=hunt_lib.DECIDE,
                     validator=lambda p: hunt_lib.validate_decide(p, methods=methods),
                     agent_dir=tmp, runner=never)
        T("MUST FIRE  the daemon NEVER auto-coerces - an invented taxonomy twice is a refusal, and "
          "nothing legal is written in its place",
          r.payload is None and r.failure == "schema"
          and any("turkey/beef" in p for p in r.problems), str(r.problems)[:200])

        # ---- B1 / PIN P1: A SCHEMA-LESS DISPATCH IS ANSWERED BY PROSE, AND PROSE IS THE ANSWER ---
        # The price lane passes neither a schema nor a validator, and it reads its state from the
        # QUEUE rather than from the answer. Before this, every pricer call bought a second session
        # demanding a JSON object nobody wanted: 15 turns and ~$0.61 a batch on the phase-5 gate run.
        print("")
        prose = ("I checked all seven stores. korean-rice-cakes: Baker's not-carried, Family Fare "
                 "UNUSABLE (Freshop 400), the three attended stores blocked. Verdict PENDING.")
        pf = FakeRunner([("env", _env(prose))])
        r = dispatch("t-full", "price these", agent_dir=tmp, runner=pf)
        T("MUST FIRE  a SCHEMA-LESS dispatch answering pure prose is OK on ONE call, with no re-ask",
          r.ok and r.calls == 1 and not r.reasked and r.failure is None,
          "ok=%s calls=%d reasked=%s failure=%s" % (r.ok, r.calls, r.reasked, r.failure))
        T("MUST FIRE  ...and the TEXT is what lands in the payload, verbatim, uncoerced",
          r.payload == {"text": prose}, json.dumps(r.payload)[:160])
        T("MUST FIRE  ...and the runner was called exactly ONCE - the second session is what this "
          "fixture exists to keep from ever coming back",
          len(pf.calls) == 1, "calls=%d" % len(pf.calls))
        T("CLEAN TWIN and no return contract was appended, because there is no schema to derive one "
          "from - asking for a shape and then accepting prose would be two contracts",
          "RETURN CONTRACT" not in pf.calls[0]["prompt"], pf.calls[0]["prompt"][:120])
        # A schema-less answer that HAPPENS to contain JSON is still delivered as text. The lane asked
        # for no shape, so this adapter invents none - a payload that is sometimes an object and
        # sometimes a wrapper is the shape-drift class, one layer down.
        r = dispatch("t-full", "price these", agent_dir=tmp,
                     runner=FakeRunner([("env", _env('Ruled: {"term": "x", "verdict": "PENDING"}'))]))
        T("CLEAN TWIN a schema-less answer that happens to contain JSON still lands as TEXT, not as a "
          "quietly-parsed object", r.ok and list(r.payload.keys()) == ["text"], json.dumps(r.payload)[:120])
        # ...and nothing is still nothing. An empty result with no schema has no second thing to
        # check, so it is `empty` - a named kind of nothing (B5), never a verdict made of a blank.
        r = dispatch("t-full", "price these", agent_dir=tmp,
                     runner=FakeRunner([("env", _env(" \n \t "))]))
        T("MUST FIRE  an EMPTY schema-less answer is `empty`, never a verdict made of a blank string",
          r.payload is None and r.failure == "empty" and not r.reasked,
          "failure=%s payload=%s" % (r.failure, r.payload))
        # CLEAN TWIN, and it is the half that must NOT move: a stage that DID ask for a shape still
        # re-asks exactly once when the shape does not arrive.
        twin = FakeRunner([("env", _env("I could not do this.")), ("env", _env(good))])
        r = dispatch("t-full", "go", schema=hunt_lib.STAGE, agent_dir=tmp, runner=twin)
        T("CLEAN TWIN a SCHEMA'D dispatch answered with prose still re-asks exactly once, and the "
          "corrected answer lands - B1 narrowed the rule, it did not delete it",
          r.ok and r.reasked and r.calls == 2, "ok=%s reasked=%s calls=%d" % (r.ok, r.reasked, r.calls))
        vtwin = FakeRunner([("env", _env("prose")), ("env", _env("prose again"))])
        r = dispatch("t-full", "go", validator=lambda p: [] if p else ["nothing"], agent_dir=tmp,
                     runner=vtwin)
        T("CLEAN TWIN a VALIDATOR with no schema still demands an object - `schema is None` alone was "
          "never the test",
          r.payload is None and r.reasked and r.calls == 2,
          "payload=%s reasked=%s calls=%d" % (r.payload, r.reasked, r.calls))

        # ---- C1 / PIN P10: THE SUBAGENT'S TOKENS LAND IN THE STAMP ------------------------------
        # The phase-5 mapper batch delegated to a 21-turn Opus subagent that appeared in NO lane stamp
        # and no ledger - $1.64 of invisible spend. Top-level `usage` covers the main agent only;
        # `modelUsage` is the one place in the envelope where a subagent shows up at all. The key names
        # below are read off a REAL envelope rather than guessed - see MODEL_USAGE_KEYS.
        print("")
        two = _env(good, in_tok=13001, out_tok=93903, cache_read=3802874, cache_creation=323820,
                   model="claude-fable-5",
                   extra_models={"claude-opus-5": _model_row(4200, 8800, 210000, 15000, cost=1.64)})
        r = dispatch("t-full", "map these", schema=hunt_lib.STAGE, agent_dir=tmp,
                     runner=FakeRunner([("env", two)]))
        all_in, all_out, cost, names = r.all_models
        T("MUST FIRE  a TWO-MODEL envelope: the subagent's tokens land in the subagent-inclusive "
          "total, which is what the phase-5 mapper's invisible $1.64 was missing from",
          all_out == 93903 + 8800 and all_in == (13001 + 3802874 + 323820) + (4200 + 210000 + 15000),
          "all_in=%d all_out=%d" % (all_in, all_out))
        T("MUST FIRE  ...and the MAIN-AGENT stamp beside it is unchanged, so the DIFFERENCE between "
          "the two is the delegation - a single merged number would hide exactly what this exposes",
          r.tokens_out == 93903 and r.tokens_in == 13001 + 3802874 + 323820,
          "in=%d out=%d" % (r.tokens_in, r.tokens_out))
        T("MUST FIRE  the subagent-inclusive input follows lane-tokens.ps1's rule too - input plus "
          "cache read plus cache write, never uncached input alone",
          all_in == 4368895, "all_in=%d" % all_in)
        T("the roll-up names every model it summed, and adds their costUSD",
          names == ["claude-fable-5", "claude-opus-5"] and abs(cost - 1.65) < 0.001,
          "names=%s cost=%s" % (json.dumps(names), cost))
        T("CLEAN TWIN a single-model dispatch reports the SAME numbers on both sides - no delegation, "
          "no gap",
          model_usage_totals(_env(good, in_tok=12, out_tok=340, cache_read=21142,
                                  cache_creation=10235)["modelUsage"])[:2]
          == (12 + 21142 + 10235, 340),
          str(model_usage_totals(_env(good)["modelUsage"])))
        T("the cache split rides on the result, so a working-set problem is tellable from an output "
          "problem without opening a transcript",
          r.cache_read == 3802874 and r.cache_creation == 323820 and r.calls == 1,
          "read=%d write=%d calls=%d" % (r.cache_read, r.cache_creation, r.calls))
        # A RE-ASK IS A SECOND BILLED CALL, so the map must MERGE rather than be replaced. Overwriting
        # made the subagent-inclusive total report only the LAST call's models - on a re-asked
        # dispatch, the cheaper half, which understates exactly the dispatches worth looking at.
        reask = FakeRunner([
            ("env", _env(json.dumps({"slug": "s", "status": "ok"}), in_tok=1000, out_tok=2000)),
            ("env", _env(good, in_tok=1500, out_tok=2500,
                         extra_models={"claude-opus-5": _model_row(100, 200)}))])
        r2 = dispatch("t-full", "go", schema=hunt_lib.STAGE, agent_dir=tmp, runner=reask)
        a_in, a_out, _c, a_names = r2.all_models
        T("MUST FIRE  a RE-ASKED dispatch sums BOTH calls into the subagent-inclusive total - the map "
          "is merged, never overwritten",
          r2.calls == 2 and a_out == 2000 + 2500 + 200 and a_in == 1000 + 1500 + 100
          and a_names == ["claude-fable-5", "claude-opus-5"],
          "calls=%d all_in=%d all_out=%d names=%s" % (r2.calls, a_in, a_out, json.dumps(a_names)))

        # ---- the model pin is checked, and a drop is REPORTED -----------------------------------
        print("")
        T("CLEAN TWIN the frontmatter alias `fable` is satisfied by claude-fable-5",
          model_matches("fable", ["claude-fable-5"])[0], str(model_matches("fable", ["claude-fable-5"])))
        T("MUST FIRE  `claude-opus-5` is NOT satisfied by claude-opus-4-8",
          not model_matches("claude-opus-5", ["claude-opus-4-8"])[0],
          str(model_matches("claude-opus-5", ["claude-opus-4-8"])))
        T("CLEAN TWIN the auxiliary haiku call every headless dispatch bills does not read as a "
          "dropped pin",
          model_matches("claude-opus-4-8", ["claude-haiku-4-5-20251001", "claude-opus-4-8"])[0],
          "read as a drop")
        r = dispatch("t-full", "go", schema=hunt_lib.STAGE, agent_dir=tmp,
                     runner=FakeRunner([("env", _env(good, model="claude-haiku-4-5-20251001"))]))
        T("MUST FIRE  a silently downgraded model is a FINDING on the result, not a refusal - the "
          "pin is the frontmatter's to state and the CLI's to honor, and this adapter's job is to "
          "notice",
          r.ok and any("MODEL PIN" in f for f in r.findings), json.dumps(r.findings))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # ---- the live agent definitions parse, and their pins are the ones section 4.4a ratified -----
    print("")
    print("the estate's own agent definitions:")
    for name in sorted(os.path.splitext(f)[0] for f in os.listdir(AGENT_DIR) if f.endswith(".md")):
        try:
            a = parse_agent(name)
            T("  %-26s model=%-18s effort=%-7s tools=%s"
              % (a.name, a.model or "(none)", a.effort or "(none)",
                 (str(len(a.tools)) + " declared") if a.tools else "all"),
              bool(a.model) and bool(a.body), a.path)
        except Exception as e:                                    # noqa: BLE001
            T("  %s parses" % name, False, str(e))

    print("")
    if bad:
        print("hunt_dispatch SELF-TEST FAIL (%d)" % len(bad))
        print("HUNT-DISPATCH-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN
    print("hunt_dispatch SELF-TEST PASS")
    print("HUNT-DISPATCH-COMPLETE")
    return hunt_lib.EXIT_CLEAN


def main(argv=None):
    import argparse                                              # noqa: PLC0415
    ap = argparse.ArgumentParser(description="the section 4.1a judgment dispatch adapter")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--agent", default="")
    ap.add_argument("--prompt-file", dest="prompt_file", default="")
    ap.add_argument("--prompt", default="")
    ap.add_argument("--reconstruct", action="store_true",
                    help="use section 4.1a's original road instead of --agent")
    ap.add_argument("--timeout", type=int, default=hunt_lib.DISPATCH_TIMEOUT)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if not a.agent:
        ap.print_help()
        return hunt_lib.EXIT_CANNOT_RUN
    prompt = a.prompt
    if a.prompt_file:
        with open(a.prompt_file, "r", encoding="utf-8-sig") as f:
            prompt = f.read()
    if not prompt.strip():
        print("hunt_dispatch: CANNOT RUN - no prompt")
        print("HUNT-DISPATCH-COMPLETE")
        return hunt_lib.EXIT_CANNOT_RUN
    r = dispatch(a.agent, prompt, timeout=a.timeout, reconstruct=a.reconstruct)
    if a.json:
        print(json.dumps(r.as_dict(), indent=1, ensure_ascii=False))
    else:
        print(r.text)
        print("")
        print("  %s  in=%d out=%d  %.1fs  $%.4f  %s"
              % (a.agent, r.tokens_in, r.tokens_out, r.seconds, r.cost_usd,
                 "OK" if r.ok else ("FAILED: %s - %s" % (r.failure, r.detail))))
        for f in r.findings:
            print("  FINDING  " + f)
    print("HUNT-DISPATCH-COMPLETE")
    return hunt_lib.EXIT_CLEAN if r.ok else hunt_lib.EXIT_FINDINGS


if __name__ == "__main__":
    sys.exit(main())
