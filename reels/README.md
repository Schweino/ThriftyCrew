# Thrifty Crew video pipeline

Two kinds of video, one stack, zero recurring cost. Everything runs locally on free tools:
headless Chrome for rendering and for driving the live site, `edge-tts` for the voice, `ffmpeg` for
the cut. Nothing is uploaded automatically; both builders leave an MP4 and a caption file for Brad
to post by hand.

| Builder | What it is | Cadence |
|---|---|---|
| `build-reel.ps1` | **Recipe of the day.** Sells one dinner: price, protein, shopping list, takeout comparison. Scenes are rendered from JSON, so the site is never on camera. | Scheduled daily 10:00 ("SMP Daily Facebook Reel") |
| `build-demo-reel.ps1` | **How the page works.** A product demo of a live recipe page: serving control, the three pricing tabs, the "already have it, untick it" checkboxes. | On demand |
| `build-demo-reel.ps1 -PinnedOverview` | **Pinned Page overview.** Leads with the annual takeout leak, tours the meal-prep library and one recipe end to end, then lightly introduces grocery search. | Pin to the Facebook Page |

Install or repair the local daily task with `powershell -ExecutionPolicy Bypass -File .\install-daily-task.ps1`. The task wakes the PC, starts missed runs when the PC becomes available, and only writes local files for manual posting.

## The demo reel

```bash
powershell -File C:\Codex\ThriftyCrew\reels\build-demo-reel.ps1

# Build the broader Page overview intended to stay pinned
powershell -File C:\Codex\ThriftyCrew\reels\build-demo-reel.ps1 -PinnedOverview
```

Outputs into `reels\out\`:

- `<date>-how-it-works-<slug>.mp4` (1080x1920, H.264/AAC, ~73s)
- `<date>-how-it-works-<slug>.txt` the Facebook caption
- `<date>-how-it-works-<slug>-script.txt` the narration, per scene, for reading before posting

Useful switches: `-Slug <recipe>` to pick the recipe, `-SmallServings 4` to change what the serving
demo scales down to, `-SkipCapture` to re-cut the video from the frames already shot, `-NoVoice` for
a silent cut, `-Music <path>` to bake in a track (read `MUSIC.md` first), `-KeepFrames` to also keep
the rendered cards, voice clips and per-scene video in `out\.demo-work\`. The page captures live in
`out\.demo-work\shots\` and are always kept, which is what makes `-SkipCapture` possible; a fresh
capture wipes that folder first so it never mixes two recipes.

By default it demos **this week's number one free-rotation recipe**, so the page a viewer lands on is
open rather than paywalled. Passing a `-Slug` outside the rotation is allowed; the run says so and
the closing card drops the "free this week" badge.

### How it is put together

```
capture-demo.py   drives the LIVE page over CDP (cdp.py) and photographs each beat
                    -> shots\*.png + demo-manifest.json
narration.py      the engine-agnostic core: landmine guards, word alignment, paragraph join,
                  hesitation detector. Shared, never copied.
  speak-script.py   edge-tts   (free, no account)
  azure-speak.py    Azure      (Dragon HD voices, needs a key)
                    -> narration.mp3 + word-level timing
build-demo-reel.ps1 writes the narration FROM the manifest, renders cards and frame furniture,
                    and cuts the video TO the narration
                    -> out\*.mp4
```

**Two engines, one interface.** Both synthesis scripts take identical arguments and emit identical
timing files, because everything that isn't the synthesis call lives in `narration.py`. Which one
runs is decided by the voice name alone (`Get-SpeakerScript` in `voices.ps1`); nothing else in either
builder knows or cares. If you add a third engine, put it beside those two and change nothing else.

One trap the shared core hides: edge-tts reports word offset **and** duration in 100ns ticks, while
the Azure SDK reports offset in ticks and duration as a `datetime.timedelta`. Same field, different
units, normalised at the boundary. Getting that wrong produces a subtly mistimed video, not an error.

**The video is cut to the voice, not the other way round.** The first version spoke each scene
separately and padded the seams, which is the single biggest reason AI voiceover sounds like AI: ten
utterances means ten closing cadences and ten cold starts. Measured, that version had nine gaps of
1.30-1.34s, one at every scene boundary. Reading the script in one pass and cutting the picture on
the word gives gaps of 0.44s, which is the voice's own breath, and takes nine seconds off the runtime
without cutting a word. Clips are rendered silent and the narration is laid over the finished cut, so
there is no audio seam to click or drift.

Narration is written to be **spoken**: contractions, one idea per sentence, a leading word before any
figure, and an "and" before the last item of a list. Those are not stylistic preferences, they are
what stops a neural voice reading a sentence as a data dump.

### Pacing: what the engine actually gives you

**There is no SSML on this endpoint, at any price.** Tags typed into the narration are not stripped
and not interpreted, they are **read out loud as words**: `<break time="1500ms"/>` becomes the
narrator saying "break time = 1500ms" and doubles the render. Raw SSML forced past the library's
escaper is rejected by the server outright. `speak-script.py` therefore refuses any line containing
`<`, `>` or `_` (underscores are vocalised too), which is a real footgun in a pipeline that assembles
narration from data.

So pacing comes from exactly two levers. Measured pause lengths, the whole vocabulary:

| separator | pause | use |
|---|---|---|
| space | 0.01s | none |
| `…` or `...` or `—` or `;` | 0.16 to 0.23s | all just a comma in disguise |
| `,` | 0.20s | a beat |
| `.` or a newline | 0.40s | a sentence break |
| `,\n` | 0.40s | a full beat mid-sentence, without a terminal period |
| `. ` | **0.61s** | the longest pause text can buy |

Folklore that did **not** survive measurement: ellipses are not dramatic (they are at or under a
comma), em dashes are not longer than commas (so the no-em-dash rule costs nothing), paragraph breaks
add nothing over a single newline, and stacking punctuation does not scale (`. . . ` collapses back to
0.19s). ALL CAPS and `*asterisks*` do not reliably emphasise: across three test words the effect was
strong, absent, and then *reversed*. Do not build on it.

`Add-Card`/`Add-Screen` take `-Beat` for the 0.61s hold. Use it once or twice in a reel; a pause
everywhere is just a slow read. Anything longer than 0.61s has to be built in the video edit.

**Rate: -8%, about 156 wpm.** This voice at +0% runs 168 wpm, which is news-anchor fast against the
~150 that narration wants. **Do not tune rate in 1% steps**: the engine's response is genuinely
non-monotonic there (-1% measured slower than -3%, repeatably) because the rate hint re-plans pauses.
Move in 5% increments. `volume` does nothing useful, normalise in ffmpeg instead; `pitch` muddied the
pause structure on this voice and is left at 0.

Money is spelled out conversationally ("two forty nine", not "$2.49") by `speech.ps1`. That is not
only about pronunciation: the engine expands `$2.49` into the full formal "two dollars and forty-nine
cents", which costs a second per price and sounds stilted.

**Budget: 60 seconds is about 145 words at -8%.** Measured on our own narration, which runs 147 wpm
overall and 157 wpm speaking. Do not use the 130-145 wpm figure from voiceover blogs (that is human
VO and would leave you 25 seconds short), and do not use the ~193 wpm one research pass measured on
denser copy. Measure the real thing: `narration.mp3.timing.json` has the words and the span.

### Narration guards

`speak-script.py` refuses to speak text containing any of these. All measured on this voice. They are
regression guards, not live problems, because narration is assembled from live page data and a store
name or board label can carry one in without a human ever reading the sentence.

| blocked | why |
|---|---|
| `<` `>` | SSML is read ALOUD and roughly doubles the render |
| `_` | spoken as the word "underscore" |
| `$12.34` | read as the formal "twelve dollars and thirty four cents", ~1.1s slower per price |
| `$3-$5` | the dash vanishes: spoken "three dollars five dollars" |
| `word/word` | the slash takes its own token. Write "a pound", not "/lb" |
| `500 g`, `12 ct`, `3 qt` | `g ct pk ea qt doz in c` are NOT recognised as units and split off. `lb oz kg mg ml pt gal tbsp tsp cm` are fine |
| `ALDI` | ALL CAPS gains no emphasis and breaks proper nouns (+77%) and units (`3 LB` splits in two) |
| emoji, non-ASCII | gets its own token and is spoken aloud |

Asterisks, tildes, brackets, quotes and both apostrophe styles are safe, verified silently dropped.
Do not add them to the list.

Two more measured writing rules worth keeping in mind, not enforceable by a guard:

- **Back-load the number.** Sentence-final lengthening is real and large: the same price stretches
  about 29% at the end of a sentence versus the front. Put the figure last and the engine emphasises
  it for free.
- **A question mark only rises on the right grammar.** Declarative-shaped questions rise hard
  ("Chicken thighs cost ninety nine cents?" +81 Hz). Wh-questions correctly fall, and rhetorical
  imperatives like "Guess what that costs?" fall too, landing flat.

`-VoiceSamples` renders the whole narration in each voice on the roster into
`out\demo-voice-samples\`. Judge a voice over the full script, never over one stock line.

### Standing content rules

`copy-rules.ps1` holds rules about what the videos may **say**, and it fails the build rather than
relying on anyone remembering them. Both builders check every scene as it is authored plus the
finished post text, before any synthesis or rendering, so a violation costs a second instead of a
video nobody notices is wrong until it is live.

Currently one rule: **never name Omaha.** Say "real stores" or "store prices". The prices are
Omaha's, but naming the city tells everyone outside it that the page is not for them, and the goal is
enough traffic that requests to expand become the signal for where to go next. Applies to narration,
cards, captions, post text and hashtags. It does **not** apply to the site, the board or the recipe
pages, where the specificity is what earns trust.

Each banned term carries its reason in the error, so whoever trips it can judge whether the rule
still applies rather than just deleting the check. Add a rule by adding one entry to
`$script:TcBannedCopy`; nothing else needs changing.

This lives in code and not in a note because **the daily reel runs unattended from a scheduled task
with no human and no model in the loop.** There is no agent to instruct.

### Audio finishing

The narration is mastered before it goes on the cut: high-pass, three small EQ moves, compression,
limiting for gain staging, then two-pass `loudnorm` to **-14 LUFS / -1.5 dBTP**, delivered as 128k
AAC at 48 kHz. Raw edge-tts arrives at -21.5 LUFS, which on a phone speaker at half volume in a noisy
feed is close to inaudible. That +7.3 LU is the whole point of the chain.

**It does not make the voice sound less synthetic, and it cannot.** That tell is prosody, and no
filter re-times a syllable. The measured proof is the loudness range: the narration is 3.0 LU, so the
content itself is flat, and compression makes it flatter still. Everything in the chain was measured
on this voice reading this script; steps that did not survive measurement are deliberately absent:

| tried | verdict |
|---|---|
| de-esser | this source is not sibilant. Sweeping intensity moved the sibilance peak 0.5 dB. Dropped |
| synthetic room tone | real but sits ~25 dB SPL on a phone, far below any room you'd watch in. Dropped |
| `aecho` fake room | net negative, costs 2 to 4 LU and hurts intelligibility on small speakers |
| `vibrato`/`tremolo` jitter | no measurable effect when subtle, seasick when audible |
| `asubboost` | collapsed level by 8.2 LU, and phones cannot reproduce it anyway |

Traps, all measured, all easy to reintroduce:

- **`loudnorm` must be two-pass.** Single-pass targeting -14 lands at -15.1, because the filter has
  not heard the content yet. Pass one costs 0.07s on a 66s file.
- **Never pass `offset` into pass two.** It gets applied a second time: -13.5 with it, -14.2 without.
- **Measure per file, every run.** Never cache the `measured_*` values. A stored loudness figure
  outliving its audio is the same bug class as a stamped date outliving its data.
- **Measure the finished MIX, not the bare voice.** Music under the voice moves integrated loudness,
  so normalising the voice and then adding music lands off target.
- **Lossy encoding raises true peak** (-1.5 in, -1.2 out at 128k). That is why the target is -1.5
  rather than -1.0, which would clip on some decoders after encoding.
- The build **verifies its own output** and warns if the finished file is more than 1 LU off target,
  because a filter chain that silently no-ops looks exactly like one that worked.

Meta publishes no official LUFS target and re-normalises client side, so -14 is for consistency
across our own reels, not compliance. Do not chase 0.2 LU.

### The narrator roster

Voices are referred to by name. `voices.ps1` maps names to Microsoft ids and is shared by both
builders, so the two reels on the Page always speak in the same voice and there is one place to
change it. A full Microsoft id works anywhere a name does.

| name | id | engine | notes |
|---|---|---|---|
| **goku-podcast** | `en-US-Andrew3:DragonHDLatestNeural` | Azure | **the house voice.** Brad's pick, 2026-08-08, after hearing three HD voices read a whole reel |
| goku-omni | `en-US-Andrew:DragonHDOmniLatestNeural` | Azure | fewest pauses per minute measured (19.4 vs Goku's 30.0) |
| goku-hd | `en-US-Andrew:DragonHDLatestNeural` | Azure | same persona, base HD model |
| goku | `en-US-AndrewMultilingualNeural` | edge-tts | the free fallback, and what shipped before HD |
| andrew | `en-US-AndrewNeural` | edge-tts | older generation, slightly clipped |
| brian | `en-US-BrianMultilingualNeural` | edge-tts | approachable, casual, sincere |
| christopher | `en-US-ChristopherNeural` | edge-tts | deep authority. Rejected: reads as documentary narration |
| guy | `en-US-GuyNeural` | edge-tts | passion |
| emma / ava | `en-US-Emma…` / `en-US-Ava…` | edge-tts | female, untested on this script |

**HD voices ignore `-RatePct`.** They don't support `<prosody>` and set their own pace, which is why
the daily reel runs ~40s on words that took Goku 46s. If an HD voice reads rushed, that is not
tunable; the only lever is writing longer sentences.

```bash
powershell -File C:\Codex\ThriftyCrew\reels\build-demo-reel.ps1 -SkipCapture -Voice Brian
```

An unknown name fails immediately with the list of valid ones, rather than three minutes later as an
opaque refusal from the TTS service after every frame has already rendered.

### Azure credentials

The HD voices need an Azure Speech resource. It runs on the **free F0 tier** at our volume (about
40,000 characters a month against a 500,000 allowance), so there is nothing to pay.

The key lives in **user environment variables**, never in this repo:

```bash
setx AZURE_SPEECH_KEY "your-key"
```

```bash
setx AZURE_SPEECH_REGION "eastus"
```

`Get-SpeakerScript` reads them per run and passes them to the child process. They are never echoed,
and `.gitignore` refuses `*.key` and `*secret*` in case anyone tries a file instead.

**The region is the one setting you cannot get wrong.** HD voices exist in nine regions only:
`eastus`, `eastus2`, `westus2`, `canadacentral`, `westeurope`, `swedencentral`, `francecentral`,
`centralindia`, `southeastasia`. Notably **not** `centralus`, `westus`, `southcentralus`,
`northcentralus` or `uksouth`, several of which look like the obvious pick from the Midwest and would
silently offer no HD voices at all.

**If Azure fails, the daily reel falls back to `goku` on the free endpoint and warns loudly.** That
is deliberate: this job runs unattended at 10:00, and a missed day of content is worse than a reel in
the previous voice. Not knowing which voice shipped would be worse than either, hence the warning.

The single rule that makes this trustworthy: **every number spoken or captioned is read out of the
manifest, and the manifest is read off the page.** Nothing is typed by hand and nothing is
recomputed. If the widget shows a different total tomorrow, the script says the new total. The
builder also cross-checks the card's own "saves $X versus everyday" sentence against the difference
between its two totals and refuses to narrate either if they disagree.

Frame layout, 1080x1920:

```
   0 - 120   masthead
 120 - 1370  the phone screen: exactly what capture-demo.py shoots, 375x434 CSS at 2.88x
1370 - 1620  caption band, the text description introducing each new thing
1620 - 1920  left empty, because Facebook's UI sits over the bottom of a Reel
```

Change `CSS_H` in `capture-demo.py` and the screen window in `build-demo-reel.ps1` together or the
capture stops matching the frame.

## Adding another video

Most new ideas are a new scene list, not a new pipeline. To make one:

1. If it shows the live site, add beats to `capture-demo.py` (scroll, act, `cap.frame(...)`, record
   what the page said into `facts`). If it does not, skip straight to step 2.
2. Write the scene list with `Add-Card` / `Add-Screen` in a copy of `build-demo-reel.ps1`. Cards are
   the transitions; screens are the evidence.
3. Never hand-type a figure into narration or a caption. Read it from the manifest, or capture it.

## Things that will bite you

- **Chrome will not screenshot if another instance owns the profile.** `cdp.py` uses a throwaway
  `--user-data-dir` for exactly this. Do not "simplify" that away.
- **Headless Chrome only runs IntersectionObserver callbacks when it paints.** A single jump-scroll
  moves the page without firing them, so the floating servings bar stays hidden and the demo loses
  the control it is demonstrating. `Capture.scroll_to` scrolls in steps on purpose.
- **`clip` in `Page.captureScreenshot` is not the device scale factor.** Emulation already renders at
  the emulated DPR; passing dsf as `scale` gives you a 3110px-wide image.
- **The join interstitial shows to everyone on a free-rotation recipe page.** That is its design.
  `capture-demo.py` suppresses it, and answers the cookie banner as decline.
- **Lazy images do not load because you clipped over them.** The capture scrolls the whole page once
  to warm them, or the reel opens on an empty white box.
- **Never go back to per-scene TTS.** It reads as robotic and it costs nine seconds of dead air. If a
  scene needs to run longer than its line, write a longer line.
- **`edge_tts.Communicate` defaults to `boundary="SentenceBoundary"` in 7.x.** Word timings, which
  the cut depends on, only arrive if you ask for `WordBoundary`.
- **argparse eats `--rate -3%` as a flag.** Only `--rate=-3%` survives.
- **Facebook Reels caps at 90 seconds.** The builder warns past that. Cut a beat, do not speed it up.
- Music: not baked in by default, on purpose. See `MUSIC.md`.
