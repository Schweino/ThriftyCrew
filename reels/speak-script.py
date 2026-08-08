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
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import narration
from narration import TICKS_PER_SECOND, norm, check_speakable, align, find_hesitations

import edge_tts


async def render(text, voice, rate, pitch, mp3_path):
    """The edge-tts half. Everything after this is shared with azure-speak.py via narration.py."""
    # boundary defaults to SentenceBoundary in edge-tts 7.x, which is too coarse to place a scene cut
    # mid-sentence and gives no way to notice a tokenisation mismatch. Ask for words.
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
    text = narration.join_lines(lines)

    marks = asyncio.run(render(text, args.voice, args.rate, args.pitch, args.out))
    timing, drift = align(lines, marks)
    hes = find_hesitations(lines, marks)
    narration.write_timing(args.out + ".timing.json", args.voice, args.rate, timing, drift, hes)
    narration.report(drift, hes, args.out + ".timing.json")


if __name__ == "__main__":
    main()
