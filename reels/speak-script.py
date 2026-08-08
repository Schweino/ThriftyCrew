"""
speak-script.py - read the whole narration as ONE take, and report where each line lands.

WHY
  Rendering a video's narration one scene at a time is the single biggest reason AI voiceover sounds
  like AI. Each call is a separate utterance, so the voice opens and closes ten times in seventy
  seconds: every line gets a full falling-cadence ending and a fresh start, and the seams between
  them have to be padded, which stacks dead air on top of the wrong intonation. Measured on the first
  cut of the demo reel: nine gaps of 1.30 to 1.34 seconds, one at every scene boundary, against
  0.35-0.50s for the voice's own natural sentence breaks.

  A person reading a script does not do that. They read it as one paragraph, and the sentences lean
  into each other. So this renders the entire script in a single call and asks the engine where each
  word landed, which lets the video cut on the word instead of the audio being cut to fit the video.

HOW
  edge-tts streams WordBoundary events alongside the audio: offset and duration in 100-nanosecond
  units, plus the word itself. Aligning those against the input tells us the timestamp of the first
  word of every line. The video then holds each scene until the narration reaches the next one.

  Alignment matches the boundary's own TEXT against the expected token rather than trusting the
  counts to line up: the engine occasionally splits or merges a token, and a blind count would slide
  every timestamp after it silently, which would look like a video that drifts out of sync for no
  visible reason.

USAGE
  python speak-script.py --lines lines.json --voice en-US-AndrewNeural --rate -3% --out vo.mp3
    lines.json: [{"id": "hook", "text": "..."}, ...]
    writes vo.mp3 and vo.mp3.timing.json: [{"id","start","end","words"}]
"""
import argparse
import asyncio
import json
import re
import sys

import edge_tts

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lines", required=True)
    ap.add_argument("--voice", default="en-US-AndrewNeural")
    ap.add_argument("--rate", default="+0%")
    ap.add_argument("--pitch", default="")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.lines, encoding="utf-8-sig") as fh:
        lines = json.load(fh)
    if not lines:
        raise SystemExit("no lines to speak")

    check_speakable(lines)

    # Joining. Measured pause lengths for this engine, which are the ENTIRE pacing vocabulary
    # available (there is no SSML, so <break> does not exist at any price):
    #     space                 0.01s   no pause at all
    #     comma                 0.20s   a beat
    #     period OR newline     0.40s   a sentence break
    #     ". "                  0.61s   the longest pause text can buy
    # Everything else is one of those in disguise. Ellipses are NOT dramatic (0.16-0.21s, at or under
    # a comma) and em dashes are just commas, so writing without them costs nothing.
    #
    # Lines already end in sentence punctuation, so a plain space between them yields the 0.40s
    # break. A line marked "beat" gets the extra " ." that buys 0.61s, for the one or two moments
    # that should land before the next thing starts. Past 0.61s the engine simply will not go; a
    # longer hold has to be built in the video edit instead.
    parts = []
    for i, ln in enumerate(lines):
        t = ln["text"].strip()
        if i < len(lines) - 1 and ln.get("beat"):
            t += " ."
        parts.append(t)
    text = " ".join(parts)

    marks = asyncio.run(render(text, args.voice, args.rate, args.pitch, args.out))
    timing, drift = align(lines, marks)
    with open(args.out + ".timing.json", "w", encoding="utf-8") as fh:
        json.dump({"voice": args.voice, "rate": args.rate, "drift": drift, "lines": timing}, fh, indent=2)

    if drift:
        print("WARNING: %d word(s) could not be matched during alignment" % drift, file=sys.stderr)
    print(args.out + ".timing.json")


if __name__ == "__main__":
    main()
