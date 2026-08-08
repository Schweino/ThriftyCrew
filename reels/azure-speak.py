"""
azure-speak.py - the same job as speak-script.py, through Azure Speech instead of edge-tts.

WHY BOTH EXIST
  edge-tts is free and needs no account, and it is what the reels shipped on all day. Azure reaches
  voices that endpoint cannot: the Dragon HD family, which phrases in longer groups rather than
  chopping a sentence into short chunks. Measured on the same 46-second script, edge-tts's Goku
  pauses 30.0 times a minute against Dragon HD Omni's 19.4 at the same total length. It also returns
  48kHz/192kbps audio where edge-tts returns 24kHz/48kbps.

  Everything downstream is identical, so the two engines share narration.py: the same landmine
  guards, the same word alignment, the same hesitation report, the same output files. Only the
  synthesis call differs.

CREDENTIALS
  Read from AZURE_SPEECH_KEY and AZURE_SPEECH_REGION. Never logged, never written to disk. Note that
  `setx` does not reach an already-running shell, so the caller must pass them through explicitly.

RATE
  HD voices do NOT support <prosody>, so --rate is ignored for them and the model sets its own pace.
  It is applied via SSML for ordinary Azure neural voices. The script says which happened rather
  than silently dropping the request.

USAGE
  python azure-speak.py --lines lines.json --voice en-US-Andrew3:DragonHDLatestNeural --out vo.mp3
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import narration

import azure.cognitiveservices.speech as speechsdk


def is_hd(voice):
    return ":Dragon" in voice


def synthesize(text, voice, rate, out_path):
    key = os.environ.get("AZURE_SPEECH_KEY")
    region = os.environ.get("AZURE_SPEECH_REGION", "eastus")
    if not key:
        raise SystemExit("AZURE_SPEECH_KEY is not set for this process")

    cfg = speechsdk.SpeechConfig(subscription=key, region=region)
    cfg.set_speech_synthesis_output_format(
        speechsdk.SpeechSynthesisOutputFormat.Audio48Khz192KBitRateMonoMp3)
    cfg.speech_synthesis_voice_name = voice
    # Word boundaries are what the video cut is built on, so ask for them explicitly rather than
    # relying on them being on by default for a given voice family.
    cfg.set_property(speechsdk.PropertyId.SpeechServiceResponse_RequestWordBoundary, "true")

    synth = speechsdk.SpeechSynthesizer(speech_config=cfg, audio_config=None)
    marks = []
    # The two SDKs disagree on units. edge-tts gives both offset and duration in 100ns ticks; the
    # Azure SDK gives offset in ticks but duration as a datetime.timedelta. Normalise here, so
    # narration.py can stay engine-agnostic and keep doing tick arithmetic.
    synth.synthesis_word_boundary.connect(lambda e: marks.append({
        "offset": e.audio_offset,
        "duration": int(e.duration.total_seconds() * narration.TICKS_PER_SECOND),
        "text": e.text}))

    esc = (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
    if rate and rate != "+0%" and not is_hd(voice):
        body = "<prosody rate='%s'>%s</prosody>" % (rate, esc)
    else:
        body = esc
        if rate and rate != "+0%" and is_hd(voice):
            print("note: %s is an HD voice and ignores rate; the model sets its own pace." % voice,
                  file=sys.stderr)

    ssml = ("<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
            "xmlns:mstts='https://www.w3.org/2001/mstts' xml:lang='en-US'>"
            "<voice name='%s'>%s</voice></speak>" % (voice, body))

    result = synth.speak_ssml_async(ssml).get()
    if result.reason != speechsdk.ResultReason.SynthesizingAudioCompleted:
        det = result.cancellation_details
        raise SystemExit("Azure synthesis failed: %s %s"
                         % (result.reason, det.error_details if det else ""))
    with open(out_path, "wb") as fh:
        fh.write(result.audio_data)
    if not marks:
        raise SystemExit("Azure returned no word boundaries; the video cannot be timed to this take")
    return marks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lines", required=True)
    ap.add_argument("--voice", default="en-US-Andrew3:DragonHDLatestNeural")
    ap.add_argument("--rate", default="+0%")
    ap.add_argument("--pitch", default="")     # accepted and ignored, so the callers can be identical
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.lines, encoding="utf-8-sig") as fh:
        lines = json.load(fh)
    if not lines:
        raise SystemExit("no lines to speak")

    narration.check_speakable(lines)
    text = narration.join_lines(lines)

    marks = synthesize(text, args.voice, args.rate, args.out)
    timing, drift = narration.align(lines, marks)
    hes = narration.find_hesitations(lines, marks)
    narration.write_timing(args.out + ".timing.json", args.voice, args.rate, timing, drift, hes)
    narration.report(drift, hes, args.out + ".timing.json")


if __name__ == "__main__":
    main()
