# Background music for Thrifty Crew videos

## Short answer: use Facebook's own library, in the composer

When you upload a Reel, Facebook's composer has a **Sound / Music** button with a built-in library
that is already cleared for use on Facebook and Instagram. Pick a track there, set it low, publish.

That is the recommendation for anything posted only to Facebook, for one reason: the licence risk is
Meta's problem instead of ours. A track we mix in ourselves can get the video muted, region-blocked,
or the Page hit with a copyright claim, and on a business Page that happens more often than on a
personal profile. The composer's library cannot.

**This is why `build-demo-reel.ps1` ships no music by default.** The MP4 comes out with voiceover
only, which is exactly what you want to drop into the composer before adding their track.

## When you need the music baked into the file

Cross-posting to YouTube Shorts, TikTok or the site itself means the Facebook library is not
available, so the file needs its own audio. Use one of these, in this order:

| Source | Licence | Attribution | Notes |
|---|---|---|---|
| [Pixabay Music](https://pixabay.com/music/) | Pixabay Content License | Not required | Free for commercial use, direct MP3 download. Best default. |
| [Mixkit Music](https://mixkit.co/free-stock-music/) | Mixkit Free License | Not required | Free for commercial use, no account needed. |
| [YouTube Audio Library](https://studio.youtube.com) (Create → Audio Library) | Per track | Some tracks require it | Huge and good, but filter to "no attribution required" and read the per-track terms if the video goes anywhere other than YouTube. |
| [Incompetech](https://incompetech.com/music/royalty-free/) | CC BY 4.0 | **Required** | Kevin MacLeod's catalogue. Fine, but you must credit him in the caption every time. |
| [Free Music Archive](https://freemusicarchive.org/) | Mixed, per track | Varies | Check each track. Anything marked **NC** (non-commercial) is off limits for us. |

Rules for us, regardless of source:

1. **Download the licence text with the track.** Put both in `income\assets\music\` so the file and
   its permission live together. A track whose licence you cannot produce on request is not free.
2. **No attribution-required tracks unless the credit goes in the caption.** If it needs a credit and
   the credit is not written, that is a licence breach, not a rounding error.
3. **Instrumental only.** Lyrics fight the voiceover and half the audience watches muted anyway.

## Mixing it in

```bash
powershell -File C:\Codex\income\reels\build-demo-reel.ps1 -Music C:\Codex\income\assets\music\bed.mp3
```

The track is looped to length, faded in and out, mixed at `-MusicGain 0.09` (about 9% under the
voice) and passed through a limiter so a loud bar cannot clip the narration. Raise it with
`-MusicGain 0.14` if the bed is too quiet to hear; anything above about `0.2` starts burying the
voice on a phone speaker.

Check the result on a phone at low volume before posting. A music bed that sounds balanced on desktop
speakers is usually too loud on a phone, which is where every one of these gets watched.
