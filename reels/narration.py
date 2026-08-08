"""
narration.py - the engine-agnostic half of turning a script into timed narration.

Both speak-script.py (edge-tts, free) and azure-speak.py (Azure Speech, HD voices) need exactly the
same three things, and none of them care which service produced the audio:

  check_speakable   refuse text the voice will mangle, measured landmine by measured landmine
  align             map word-boundary events back onto the script, so the video can cut on the word
  find_hesitations  report pauses the script did not ask for, and say which ones are actually wrong

It lives here rather than being copied into each engine, because a fix applied to one copy while the
other keeps its own is the single most reliable way this estate ships a bug.
"""
import re

TICKS_PER_SECOND = 10_000_000


def norm(word):
    return re.sub(r"[^a-z0-9]", "", (word or "").lower())


# Things this engine gets WRONG, every one of them measured on this voice rather than assumed. They
# are guards, not style: narration here is assembled from live page data, so a store name or a label
# from the board can carry any of these in without a human ever reading the sentence first.
#
# Asterisks, tildes, brackets, quotes and apostrophes are all SAFE (verified silently dropped), and
# curly versus straight apostrophes render identically. Do not add those.
FORBIDDEN = [
    (re.compile(r"[<>]"),
     "SSML-style tags are READ ALOUD by this engine, not interpreted, and roughly double the render. "
     "There is no SSML on this endpoint at any price"),
    (re.compile(r"_"),
     "underscores are spoken aloud as the word 'underscore'"),
    (re.compile(r"\$\d"),
     "a literal price is read as the full formal 'one dollar and twenty nine cents', about 1.1s "
     "slower per price than 'a dollar twenty nine'. Spell money out with Get-MoneySpeech"),
    (re.compile(r"\d\s*[-–—]\s*\$?\d"),
     "a number range written with a dash loses the dash entirely: '$3-$5' is spoken "
     "'three dollars five dollars'. Write 'three to five dollars'"),
    (re.compile(r"\w/\w"),
     "a slash gets its own token and breaks the phrase: write 'a pound', not '/lb'"),
    (re.compile(r"\b\d+\s*(?:g|ct|pk|ea|qt|doz|in|c)\b"),
     "this unit abbreviation is NOT recognised as a measure and splits into a separate token "
     "(lb, oz, kg, mg, ml, pt, gal, tbsp, tsp and cm ARE recognised). Spell the unit out"),
    # Genuine initialisms are SUPPOSED to be read letter by letter, so caps are correct for them.
    # Measured on this voice: "BBQ Pulled Pork Bowls" is 1.71s against 1.62s for "Barbecue Pulled
    # Pork Bowls", a 5% difference consistent with saying "B-B-Q" as intended. "ALDI has it" is
    # 0.94s against 0.69s for "Aldi has it", +36%, which is a word being spelled out by mistake.
    # BBQ is live in the recipe catalogue, so this list is load-bearing, not hypothetical.
    (re.compile(r"\b(?!(?:BBQ|TV|DIY|USDA|FDA|OK)\b)[A-Z]{2,}\b"),
     "ALL CAPS buys no emphasis at all and breaks proper nouns and units "
     "('ALDI' runs 36% longer than 'Aldi'; '3 LB' splits into two tokens). If this is a real "
     "initialism that should be read letter by letter, add it to the allowlist in speak-script.py"),
    (re.compile(r"[^\x00-\x7F‘’“”…]"),
     "non-ASCII characters get their own token and are spoken: an emoji is read out"),
]


def check_speakable(lines):
    """Refuse to narrate text this engine is known to mangle.

    Every one of these is a regression guard rather than a live problem: the pipeline spells money
    out and writes units in words already. The point is that it stays that way when someone adds a
    scene six months from now."""
    for ln in lines:
        for rx, why in FORBIDDEN:
            m = rx.search(ln["text"])
            if m:
                raise RuntimeError(
                    "line '%s' contains %r, which this voice mis-speaks: %s\n  %s"
                    % (ln["id"], m.group(0), why, ln["text"][:160]))


async def render(text, voice, rate, pitch, mp3_path):
    # boundary defaults to SentenceBoundary in edge-tts 7.x, which is too coarse to place a scene
    # cut mid-sentence and gives no way to notice a tokenisation mismatch. Ask for words.
    kwargs = {"rate": rate, "boundary": "WordBoundary"}
    if pitch:
        kwargs["pitch"] = pitch
    comm = edge_tts.Communicate(text, voice, **kwargs)
    marks = []
    with open(mp3_path, "wb") as fh:
        async for chunk in comm.stream():
            if chunk["type"] == "audio":
                fh.write(chunk["data"])
            elif chunk["type"] == "WordBoundary":
                marks.append({"offset": chunk["offset"], "duration": chunk["duration"],
                              "text": chunk.get("text", "")})
    if not marks:
        raise RuntimeError("edge-tts returned no word boundaries; cannot time the scenes")
    return marks


def align(lines, marks):
    """Walk the boundary events against the expected words, line by line."""
    expected = []
    for li, ln in enumerate(lines):
        for w in ln["text"].split():
            n = norm(w)
            if n:
                expected.append((li, n))

    starts = {}
    ends = {}
    counts = {}
    ei = 0          # index into expected
    drift = 0
    for m in marks:
        mt = norm(m["text"])
        if not mt:
            continue
        if ei < len(expected):
            li, ew = expected[ei]
            if mt != ew:
                # Engine tokenised differently. Look ahead a couple of slots before giving up on
                # this word, so one odd token does not shift every later line.
                hit = None
                for look in range(1, 4):
                    if ei + look < len(expected) and expected[ei + look][1] == mt:
                        hit = ei + look
                        break
                if hit is not None:
                    ei = hit
                    li, ew = expected[ei]
                else:
                    drift += 1
                    li = expected[min(ei, len(expected) - 1)][0]
            starts.setdefault(li, m["offset"])
            ends[li] = m["offset"] + m["duration"]
            counts[li] = counts.get(li, 0) + 1
            ei += 1

    out = []
    for li, ln in enumerate(lines):
        if li not in starts:
            raise RuntimeError("no audio matched line '%s'; the alignment is unusable" % ln["id"])
        out.append({"id": ln["id"],
                    "start": starts[li] / TICKS_PER_SECOND,
                    "end": ends[li] / TICKS_PER_SECOND,
                    "words": counts.get(li, 0)})
    return out, drift


def find_hesitations(lines, marks, floor=0.12):
    """Pauses the SCRIPT did not ask for.

    The engine sometimes stops in the middle of a phrase, and when it does it sounds like the
    narrator losing their place. The one that started this: a sentence-initial "Here is" makes it
    treat "Here" as a standalone discourse marker and hesitate 0.353s before the verb, against 0.014s
    between every other word in the same sentence. A listener hears it immediately. Nothing in the
    build could see it, because the total duration and the loudness were both perfectly fine.

    A pause is expected wherever the text has punctuation, so this reports only the ones with no
    punctuation to justify them. It WARNS rather than fails: the engine's own phrase breaks are
    legitimate and vary with wording, so this is a "go and listen to this spot" signal, not a gate.
    Rephrasing is the fix; contractions ("Here's") and a different opener ("This is") both measured
    clean on the founding case.

    THE FLOOR IS 0.12s, AND IT WAS 0.25s FOR ONE BUILD TOO LONG. At 0.25 this reported a clean sheet
    on a take where Brad heard two defects: a 0.149s break inside "twenty three eighty", which split
    the number into "twenty-three" and "eighty", and a 0.149s one isolating "so" before "come". Both
    were real, both were audible, both sat under the threshold. The ordinary gap between words in
    these renders is 0.000-0.014s, so anything past ~0.12s is already an order of magnitude out and
    worth a human ear. Setting the floor where nothing fires is not the same as nothing being wrong."""
    written = " ".join(ln["text"].strip() for ln in lines).split()
    out, wi = [], 0
    for i in range(1, len(marks)):
        gap = (marks[i]["offset"] - (marks[i - 1]["offset"] + marks[i - 1]["duration"])) / TICKS_PER_SECOND
        if gap <= floor:
            continue
        prev = norm(marks[i - 1]["text"])
        # Walk the written tokens alongside, to see whether THIS word carried punctuation.
        while wi < len(written) and norm(written[wi]) != prev:
            wi += 1
        if wi >= len(written):
            continue
        if not any(ch in written[wi] for ch in ".,?!;:"):
            nxt = norm(marks[i]["text"])
            out.append({"after": marks[i - 1]["text"], "before": marks[i]["text"],
                        "gap": round(gap, 3),
                        "at": round(marks[i]["offset"] / TICKS_PER_SECOND, 2),
                        "suspicious": _is_suspicious(prev, nxt, gap)})
    return out


# Words that carry no stress: a pause straight after one is the engine stranding it, never a breath.
FUNCTION_WORDS = {"so", "and", "but", "or", "the", "a", "an", "to", "of", "is", "it", "in", "on",
                  "at", "for", "that", "this", "here", "there", "with", "from", "as", "if"}
NUMBER_WORDS = {"zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
                "sixty", "seventy", "eighty", "ninety", "hundred", "thousand"}


def _is_suspicious(prev, nxt, gap):
    """Which unjustified pauses are actually WRONG, as opposed to the engine breathing.

    Learned from the two Brad caught that a plain size threshold missed, both at 0.149s:
      - a break INSIDE a spelled number ("twenty three | eighty") splits one figure into two, and on
        a channel that reads prices aloud that is the worst place a pause can land;
      - a break straight after an unstressed function word ("so | come") strands it, which is what
        made "Here | is" sound like a hesitation too.
    Everything else at this size lands at a constituent edge, before a proper noun or a long number
    or a prepositional phrase, which is where a person breathes. Those are recorded but not warned
    about, because a warning that fires six times a build is one nobody reads."""
    if prev in NUMBER_WORDS and nxt in NUMBER_WORDS:
        return True
    if prev in FUNCTION_WORDS:
        return True
    return gap > 0.30


BEAT = "\x00BEAT\x00"


def join_lines(lines, beat=" ."):
    """The script as one continuous paragraph, which is the whole point.

    A line marked "beat" gets a deliberate hold after it, for the one or two moments that should land
    before the next thing starts. HOW that hold is spelled depends on the engine, which is why the
    caller passes it:

      edge-tts   ". "  buys 0.61s, and that is the hard ceiling. There is no SSML on that endpoint,
                 so a longer pause has to be built in the video edit instead.
      Azure HD   <break time="..."/> works and has no practical ceiling: measured 500ms -> 0.551s,
                 900ms -> 1.087s, 1500ms -> 1.724s. Pass narration.BEAT and substitute after the
                 text has been XML-escaped, or the tag gets escaped into spoken words.

    The trick is engine-specific and NOT interchangeable: '. ' on an HD voice measures 0.040s, which
    is identical to a plain full stop, i.e. a silent no-op. It shipped that way for one build."""
    parts = []
    for i, ln in enumerate(lines):
        t = ln["text"].strip()
        if i < len(lines) - 1 and ln.get("beat"):
            t += beat
        parts.append(t)
    return " ".join(parts)


def write_timing(path, voice, rate, timing, drift, hesitations):
    import json
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"voice": voice, "rate": rate, "drift": drift,
                   "lines": timing, "hesitations": hesitations}, fh, indent=2)


def report(drift, hesitations, out):
    import sys
    if drift:
        print("WARNING: %d word(s) could not be matched during alignment" % drift, file=sys.stderr)
    for h in hesitations:
        if h["suspicious"]:
            print("HESITATION: %.3fs between '%s' and '%s' at %.1fs, with no punctuation asking for "
                  "it, and in a place a person would not breathe. Rephrase that line."
                  % (h["gap"], h["after"], h["before"], h["at"]), file=sys.stderr)
    print(out)
