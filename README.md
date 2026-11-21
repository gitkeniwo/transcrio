<p align="center">
  <img src="gui/icons/a3b-lcd-clay.svg" width="240" height="240" alt="Transcrio">
</p>

<h1 align="center">Transcrio</h1>

<p align="center">
  <a href="https://github.com/gitkeniwo/transcrio/actions/workflows/test.yml"><img src="https://github.com/gitkeniwo/transcrio/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <a href="https://github.com/gitkeniwo/transcrio/actions/workflows/build.yml"><img src="https://github.com/gitkeniwo/transcrio/actions/workflows/build.yml/badge.svg" alt="Build"></a>
</p>

Local audio and video transcription on Apple silicon. Transcrio is a native macOS app
(SwiftUI) on top of `transcribe`, a Python command-line tool that runs
[Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) on MLX. Drop in files and get
Markdown, text, SRT, VTT or JSON. Nothing leaves your Mac.

## Install

```sh
brew install --cask gitkeniwo/transcrio/transcrio
```

Or download the DMG from [Releases](https://github.com/gitkeniwo/transcrio/releases/latest),
open it and drag Transcrio into Applications. The rolling
[nightly](https://github.com/gitkeniwo/transcrio/releases/tag/nightly) prerelease is built from
the latest `main`.

Open Transcrio and click **Install Command-Line Tool**; it needs [uv](https://docs.astral.sh/uv/)
and `ffmpeg` (`brew install uv ffmpeg`, which the cask does for you). Transcrio isn't notarized:
the first time you open it, go to **System Settings › Privacy & Security** and click
**Open Anyway**. Requires macOS 14 (Sonoma) or later on Apple silicon.

## Repository

| Path | What |
|---|---|
| `src/transcribe`, `tests` | The `transcribe` CLI (Python, uv) and its tests |
| `gui` | Transcrio.app (Swift package); see [gui/README.md](gui/README.md) |
| `packaging/homebrew-transcrio` | Cask and README templates for the [Homebrew tap](https://github.com/gitkeniwo/homebrew-transcrio) |
| `scripts/release.sh` | Builds the DMG, wheel and cask; CI runs it for nightlies and releases |
| `skills/transcribe` | An agent skill that drives the CLI |

### Releasing

Bump `version` in `pyproject.toml` and `__version__` in `src/transcribe/__init__.py`, commit,
then push a tag: `git tag v1.2.3 && git push origin v1.2.3`. The Release workflow builds the
DMG and wheel, publishes the GitHub release and updates the Homebrew tap.

## License

[GLWTPL](LICENSE). Good luck.

## The `transcribe` CLI

Local transcription for audio and video files on Apple Silicon. The default backend is
[Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) running on MLX via
[mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr). Any format ffmpeg can read
works (mp3, m4a, wav, flac, ogg, mp4, mov, mkv, ...).

### Setup

```bash
brew install ffmpeg
uv sync
uv run transcribe doctor
```

To get a global `transcribe` command: `uv tool install .`

### Usage

```bash
uv run transcribe episode.mp3                       # -> episode.md next to the input
uv run transcribe episode.mp3 -f md,srt -t          # Markdown with timestamps + subtitles
uv run transcribe talk.mp4 -f srt -l en -o subs/    # force language, choose output dir
uv run transcribe memo.m4a -f txt --stdout          # print instead of writing files
uv run transcribe a.mp3 b.mp4 --json                # machine-readable summary on stdout
uv run transcribe backends                          # list backends, models, aligned languages
uv run transcribe models                            # model catalog: status, disk and RAM use
uv run transcribe models download 0.6b              # fetch a model ahead of time (byte progress)
uv run transcribe models remove aligner --json      # delete it from the Hugging Face cache
uv run transcribe serve                             # resident worker: NDJSON jobs on stdin (see below)
uv run transcribe export talk.json -f srt,md -o out/ # re-render formats from a saved -f json transcript
uv run transcribe align talk.json talk.mp4          # add aligned subtitle timing to a saved transcript
```

| Format | Content |
|---|---|
| `md` | Title, metadata, one paragraph per ~30 s of speech; `-t` adds `**[hh:mm:ss]**` |
| `txt` | Plain paragraphs; `-t` adds `[hh:mm:ss]` |
| `srt` / `vtt` | Subtitle cues, word-aligned for zh/en/yue/fr/de/it/ja/ko/pt/ru/es, estimated otherwise |
| `json` | Full `Transcript`: text, language, segments, cues, words, warnings |

Other flags: `--context "names jargon"` biases recognition, `-m 0.6b` for the faster/smaller
model, `--overwrite`, `--progress ndjson` for machine-readable progress on stderr.

`transcribe export TRANSCRIPT.json -f FMT[,FMT] [-o DIR] [-t] [--title T] [--source NAME]` renders
any format from a transcript saved with `-f json`, without loading a model (it doesn't even import
numpy). Files are `<title>.<fmt>` in `-o` (default: next to the transcript), overwriting; the title
defaults to the stem of the JSON's `source` (the original input), else the transcript file's stem.
srt/vtt from a transcript without cues get estimated timing, with a one-line notice on stderr.
Unreadable or invalid JSON exits 1 with a message.

Exit codes: 0 ok, 1 some inputs failed, 2 usage error, 3 environment problem, 128+signal when
stopped (SIGTERM → 143). Outputs are written atomically; a stopped run leaves no partial files.

### Architecture

```
cli.py ──> audio.py (ffmpeg -> 16 kHz mono float32)
serve.py ┘     │
   │           ├──> pipeline.py  chunk loop: stream, align per chunk, cancel between chunks
   │           │       └── backends/ (registry)  split / transcribe_chunk / align_chunk / assemble
   │           │               └── qwen3_mlx.py   Qwen3-ASR + Qwen3-ForcedAligner
   │           └──> exporters.py  Transcript -> md | txt | srt | vtt | json
   └──> models.py + download.py  catalog, cache status, cancellable downloads with byte progress
```

Batch mode (`transcribe FILE...`) and `serve` run the same `pipeline.transcribe_audio`, so their
outputs are identical.

`types.Transcript` is the only thing backends and exporters share:

- `segments`: paragraph-sized timed spans (always present)
- `cues`: subtitle-sized timed spans (when SRT/VTT is requested), with `cue_timing`
  `aligned` | `estimated` | `mixed`
- `words`: word/character timings when a forced aligner ran

#### Adding a backend

1. Create `src/transcribe/backends/<name>.py` with a `Backend` subclass: set `info`
   (name, default model, aliases, aligned languages, `models=(ModelInfo(...),)`), implement
   `load()` (and `unload()`/`loaded` so `serve` can free memory), then either `transcribe_whole()`
   for an engine that takes a whole file, or `split()` / `transcribe_chunk()` / `assemble()` /
   `align_chunk()` to be driven chunk by chunk (streaming segments, per-chunk alignment, cancel
   between chunks). Fill `segments` always, `cues` when `request.want_cues`. If the engine has
   no word timing, `segmenting.estimate_cues()` gives usable approximate cues.
2. Register it in `backends/__init__.py` `_REGISTRY`.

It then shows up in `transcribe backends` and `-b <name>`.

#### Integrating a GUI: batch mode

Run the CLI as a subprocess: `transcribe FILE -f md,srt -o DIR --json --progress ndjson`.
Each stderr line is a JSON event:
`{"file", "event": "progress", "stage": "decode|load|download|transcribe|align", "progress": 0..1}`
(`download` adds `model`, `model_id`, `downloaded_bytes`, `total_bytes` on first run),
then `file_done` (with `outputs`, `elapsed`, `language`, `duration`, `model`, `cue_timing`,
`warnings`, `notices`, `segments`), `file_error` (with `error`), or `file_stopped` after
SIGTERM/SIGINT. `segments` is `[{start, end, text}]`, one entry per transcribed chunk.
`notices` are `{code, message, spans}` with codes `truncated`, `alignment_failed`,
`timing_estimated`. stdout carries the final `--json` summary, also after a stop.

#### Integrating a GUI: `transcribe serve`

`transcribe serve [--idle-unload SEC]` is a resident worker: one process, the model stays in
memory between files, jobs can be cancelled one by one. **stdin and stdout are NDJSON, one object
per line; stdout carries nothing else** (fd 1 is pointed at stderr at start-up, so a library's
`print` or progress bar cannot reach it). stderr is for logs. Times are seconds, `index` and
`chunk` are 1-based.

```
→ {"op":"enqueue","job":{"id":"j1","input":"/a.m4a","formats":["md","srt"],"output_dir":null,
     "timestamps":false,"language":null,"context":"","overwrite":false,"model":"1.7b",
     "align":false,"transcript_path":null}}
← {"id":"j1","event":"accepted"}
← {"id":"j1","event":"progress","stage":"decode","progress":0.0}
← {"id":"j1","event":"progress","stage":"download","progress":0.42,"model":"Qwen/Qwen3-ASR-1.7B",
    "model_id":"1.7b","downloaded_bytes":1975000000,"total_bytes":4703055333}   (first use only;
    the bytes cover the whole model, so a resumed download starts from what is already cached)
← {"id":"j1","event":"progress","stage":"load","progress":0.0}   … then 1.0 (only if it had to load)
← {"id":"j1","event":"progress","stage":"transcribe","progress":0.0,"chunk":null,"total_chunks":7}
← {"id":"j1","event":"segment","index":1,"total_chunks":7,"start":0.0,"end":30.0,"text":"…","language":"English"}
← {"id":"j1","event":"progress","stage":"align","progress":0.14,"chunk":1,"total_chunks":7}   (srt/vtt only)
   … one segment (and align) per chunk …
← {"id":"j1","event":"file_done","outputs":{"md":"/a.md","srt":"/a.srt"},"elapsed":41.2,
    "language":"English","duration":205.0,"model":"Qwen/Qwen3-ASR-1.7B","cue_timing":"aligned",
    "warnings":[],"notices":[],"segments":[{"start":0.0,"end":30.0,"text":"…"}, …],
    "transcript":"/lib/a/transcript.json"}   (only when the job had a transcript_path)
← {"event":"idle"}                       # queue drained (after every job, however it ended)
```

| Op | Effect |
|---|---|
| `enqueue` | Queue a job (all fields but `id` and `input` optional). Answered at once with `accepted`. Jobs run one at a time, in order. A bad job is answered with `file_error` and never queued. |
| `enqueue` library fields | `align: true` asks for subtitle cues (forced alignment) whatever the formats, i.e. cues are made when `align` is true or `formats` has srt/vtt. `transcript_path` (absolute) asks for the master copy: the full transcript JSON (what the `json` format writes, with `source` = the input's file name) is written atomically to exactly that path, creating parent folders and always overwriting (`overwrite` does not apply to it), and `file_done` carries `"transcript": <path>`. With a `transcript_path`, `formats` may be `[]` (only the master is written); without one, a missing or empty `formats` means `["md"]`. A relative `transcript_path` is a `file_error`. Like the other outputs, the master is deleted if the job is stopped or fails after writing it. |
| `export {id, transcript, formats, output_dir, timestamps?, title?}` | Render `formats` (non-empty) from a saved transcript JSON into `output_dir` (created if needed) as `<title>.<fmt>`, overwriting; `title` defaults as in `transcribe export`. No model is loaded. Answered with `{"event":"exported","id":…,"outputs":{"md":"/dir/a.md",…},"estimated_cues":bool}` (`estimated_cues`: srt/vtt was asked for but the transcript has no cues, so their timing is estimated) or `{"event":"export_error","id":…,"message":"…"}`. An export without a string `id` is only logged. |
| `align {id, transcript, source, output?}` | Re-time a saved transcript's subtitles with the forced aligner, without transcribing again (paths absolute; `output` defaults to `transcript`). Queued and run like a job, because it loads the aligner (never the ASR model): `{"id":…,"event":"accepted"}`, progress with `stage` `decode`/`download`/`align`, then `{"event":"aligned","id":…,"transcript":"<output>","cue_timing":"aligned","notices":[…]}` or `{"event":"align_error","id":…,"message":"…"}`. The text and segments are kept; `cues`, `words` and `cue_timing` are rewritten, old `timing_estimated`/`alignment_failed` notices are replaced, other keys (`source`) are kept, and the file is written atomically. Fails when the language has no forced aligner or the source's length doesn't match the transcript's `duration`. `cancel {id}` answers `align_error` with `cancelled: true`. Same as `transcribe align`. |
| `cancel {id}` | Queued: removed, `file_stopped` with `stopped_at: 0`. Running: stops before the next chunk (or mid-download/decode), deletes its output files, `file_stopped` with `stopped_at` = seconds transcribed. Unknown id: logged and ignored. |
| `cancel_all` | `cancel` for the running job and every queued one. |
| `configure {idle_unload_sec}` | Idle time before the model is unloaded (0 = never; default 300 or `--idle-unload`). Answered with `configured`. |
| `preload {model}` | Load a model ahead of time (downloading it if needed). `model_ready {model}` or `model_error`. |
| `models` | `{"event":"models","models":[{id, repo, kind, params, size_bytes, ram_gb, languages, aligned_languages, license, url, status, bytes_on_disk, loaded, name, notes}]}`. `status` is `not_downloaded`, `partial` or `downloaded`; `bytes_on_disk` is the real size of the repo's blobs, each counted once, following huggingface_hub 2.x's symlinks into the shared `<hub>/blobs/` store (a file two repos share counts in both). `loaded` is true for the ASR model in memory and for the aligner once a srt/vtt job has loaded it. Also sent unasked whenever a catalog model is loaded or unloaded. |
| `download {model}` | Fetch a model on its own thread. Progress events have no `id`, `stage:"download"`, `model` (catalog id), `repo`, `downloaded_bytes`, `total_bytes` (the whole model; `downloaded_bytes` starts at what is already cached); then `model_ready {model}` or `model_error {model, error}`. |
| `cancel_download {model}` | Kills the transfer within ~0.1 s; `model_error` with `cancelled: true`. Files that finished stay (`status: partial`, `bytes_on_disk` = what is really on disk) and a later `download` skips them; **the file that was in progress is thrown away** (huggingface_hub writes it under a name only that transfer uses, so it cannot be resumed). Cancelling a job while its model downloads behaves the same and sends this `model_error` before the job's `file_stopped`. |
| `remove_model {model}` | Deletes the model's cache folder and every shared-store file (`<hub>/blobs/xx/<hash>`) no other cached repo links to; `model_removed {model, freed_bytes}` (the bytes really freed), then `models`. Refused (`model_error`) while it is downloading or while a job is running on it. |
| `shutdown` | Same as stdin EOF or SIGTERM: cancels the running job (`file_stopped`), answers queued jobs with `file_stopped`, unloads, exits 0. |

Every event carries the job `id`, except the worker-level ones: `idle`, `models`, `configured`,
`unloaded {model, reason: idle|switch|remove|shutdown}`, `model_ready`, `model_error`,
`model_removed`, download events from the `download` op, and `log {level, message}` (malformed
input, unknown ops, duplicate job ids). Only one ASR model is held in memory: a job for another
model unloads the current one first (together with the aligner). Loading a model cannot be
interrupted, so a cancel that arrives during the load takes effect once it finishes.

`export` runs on the thread that reads stdin, not in the job queue, so it is answered promptly
even while a job is transcribing, a model is loading or downloading. Ordering guarantees: each
`export` gets exactly one reply (`exported` or `export_error`) before any later op is read, so
replies come in request order and before the reply to any op sent after it; they are not ordered
against the events of a running job (an `exported` may arrive between two `segment`s). Exporting
the `transcript_path` of a job that is still running reads the previous version, or fails if
there is none yet (the file is replaced atomically, so an export never sees half of it).

`file_error` and `file_stopped` end a job just like `file_done`; exactly one of the three is sent
for every accepted job, and `idle` follows whenever the queue is then empty (also when the job
ended before a model was loaded, e.g. "output exists"; the model may or may not be in memory). Output files are only written once the whole transcript is rendered, and
removed again if the job is stopped.

### Models

`transcribe models` lists the catalog; `ram_gb` is the peak MLX memory measured with
`mx.get_peak_memory()` on a 70 s clip (ASR alone: 1.7B 8.2 GB, 0.6B 3.2 GB; the forced aligner
peaks at 3.7 GB when it runs), `size_bytes` the full download. Models live in the Hugging Face
cache (`HF_HOME`/`HF_HUB_CACHE`).

### Tests

```bash
uv run pytest
```

`tests/test_serve.py` drives `serve` through a fake backend (`tests/fakes.py`), so no model or
download is needed.
