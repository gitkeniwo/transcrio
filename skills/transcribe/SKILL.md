---
name: transcribe
description: Transcribe local audio or video files (mp3, m4a, wav, flac, mp4, mov, mkv, ...) to Markdown/text transcripts or SRT/VTT subtitles, fully on-device. Use when the user asks to transcribe a podcast, recording, meeting or video, or to make subtitles. Handles Chinese, English, Japanese, Spanish, German and ~25 more languages, with auto-detection.
---

# transcribe

A local CLI (Qwen3-ASR on Apple Silicon via MLX). Nothing is uploaded.

Run plain `transcribe ...` once it is installed (Transcrio's **Install Command-Line Tool**,
or `uv tool install .` from a checkout), or `uv run --project <checkout> transcribe ...`.

## Common calls

```bash
# Podcast -> Markdown with paragraph timestamps, next to the input file
transcribe episode.mp3 -f md -t --json

# Video -> subtitles (word-aligned timing) in a chosen folder
transcribe talk.mp4 -f srt -o ~/Subtitles --json

# Several outputs at once
transcribe a.m4a b.mp4 -f md,srt,json --json

# Read the transcript directly without writing files (one input, one format)
transcribe memo.m4a -f txt --stdout
```

## Options that matter

- `-f md|txt|srt|vtt|json` (comma-separated). `json` has segments, cues and word timings.
- `-t` adds `[hh:mm:ss]` paragraph timestamps to md/txt.
- `-l zh|en|ja|es|de|...` forces the language; omit to auto-detect (works for mixed zh/en).
- `--context "names terms"` biases spelling of names/jargon. Use it when the user mentions
  proper nouns, products or people that appear in the audio.
- `-m 0.6b` is faster but noticeably less accurate; default is `1.7b`.
- `--overwrite` is required to replace existing outputs.

## Reading the result

With `--json`, stdout is `{"results": [{input, outputs: {fmt: path}, error, language,
duration, elapsed, cue_timing, warnings}]}`. Progress goes to stderr; ignore it.

Exit codes: `0` ok, `1` one or more inputs failed (see each `error`), `2` bad arguments,
`3` environment problem (ffmpeg missing, not Apple Silicon) — run `transcribe doctor`.

`cue_timing: "estimated"` means the language has no forced aligner, so subtitle times are
approximate; mention this to the user if they asked for subtitles.

## Notes

- Speed on an M1 Pro: roughly 4x faster than real time with the 1.7B model (1 h audio ≈ 15 min).
- The first run downloads ~4 GB of model weights into the Hugging Face cache.
- Long files are fine; audio is chunked at ~30 s pauses internally.
