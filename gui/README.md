# Transcrio for macOS

A native SwiftUI front end for the `transcribe` CLI in this repository. The app never runs
Python or does any speech recognition itself. It starts one `transcribe run … --json --progress ndjson`
process per batch, reads the NDJSON events from stderr and the summary from stdout, and stops a
batch with SIGTERM.

Requires macOS 14 or later, Apple Silicon (for the MLX backend), Xcode 16 / Swift 6, and ffmpeg.
It has no third-party dependencies.

## Build and run

```bash
cd gui
swift build                 # debug build
swift run TranscribeApp     # run without a bundle (fine for development)
swift test                  # TranscribeKit unit and integration tests
./scripts/bundle.sh         # release build → build/Transcrio.app (icon, Info.plist, ad-hoc signed)
open build/Transcrio.app
```

The app finds the CLI in this order:

1. the path set in **Settings… → CLI path**
2. `~/.local/bin/transcribe` (install it with `uv tool install .` from a checkout), or
   `$UV_TOOL_BIN_DIR/transcribe` when that is set
3. `uv run --project <project folder> transcribe`, with the folder set in Settings (default `~/transcrio`)

When none is found, the banner offers **Install Command-Line Tool**: it runs
`uv tool install --force --python 3.12 <wheel>` with the wheel `scripts/release.sh` puts in
`Transcrio.app/Contents/Resources`. A development bundle (`scripts/bundle.sh`) has no wheel and
installs the release wheel for its version from GitHub instead; under `swift run` (no app
version) the button is hidden. When the installed CLI's `--version` differs from the app's,
release builds show **Update Command-Line Tool** (not for a Settings path or `uv run`).
`TRANSCRIBE_WHEEL=/path/to.whl` stands in for the bundled wheel; with `UV_TOOL_DIR` and
`UV_TOOL_BIN_DIR` the install goes to a scratch directory instead of `~/.local`.

Apps launched from Finder get a minimal `PATH`, so the child process always gets an explicit
`PATH` that includes `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`.

Options (model, formats, timestamps, destination, language, context terms, overwrite) are kept
in user defaults. To reset them:

```bash
defaults delete io.github.gitkeniwo.transcribe
```

`swift run` uses the `TranscribeApp` defaults domain instead.

## Layout

| Path | What |
| --- | --- |
| `Sources/TranscribeKit` | No UI. NDJSON splitter and event decoding, command builder, CLI locator, HF cache check, queue state machine, process runner (actor), AVFoundation duration and waveform, transcript parser. |
| `Sources/TranscribeApp` | SwiftUI app: queue sidebar, center pane, inspector, banners, settings, palette and shared components. |
| `Tests/TranscribeKitTests` | Swift Testing suites. `Fixtures/` holds NDJSON, stdout and outputs recorded from the real CLI. |
| `scripts/fake-transcribe.sh` | Replays a fixture as if it were the CLI. |
| `scripts/record-fixture.py` | Records a fixture from the real CLI (development only; the app never runs Python). |
| `scripts/make-chunk-fixture.py` | Writes a synthetic fixture with N chunks (`chunks8`, `chunks136`). |
| `scripts/bundle.sh`, `scripts/make-icon.*` | App bundle and icon (rendered from `icons/a3b-lcd-clay.svg`). |

## Fake-CLI dev mode

`scripts/fake-transcribe.sh` behaves like `transcribe` (`run`, `doctor --json`,
`backends --json`, `--version`). It maps a recorded fixture onto whatever files you pass,
replays the events with their original timing, writes the recorded outputs next to the inputs
(or into `-o`), honours `-f`, prints the summary and exits with the recorded code. It handles
SIGTERM/SIGINT like the real CLI: `file_stopped` for every unfinished file, the summary with
those entries marked `stopped`, and exit 143 (130 for SIGINT).

```bash
TRANSCRIBE_CLI=$PWD/scripts/fake-transcribe.sh \
TRANSCRIBE_FAKE_FIXTURE=long TRANSCRIBE_FAKE_SPEED=2 \
swift run TranscribeApp
```

| Variable | Effect |
| --- | --- |
| `TRANSCRIBE_CLI` | Use this executable as the CLI (checked before the Settings path). |
| `TRANSCRIBE_FAKE_FIXTURE` | `success` (default), `mixed` (a failure, a no-audio file, a success), `exists` (output exists), `notices` (estimated timing), `long` (14 chunks), `chunks8` / `chunks136` (synthetic, 8 / 136 chunks, all four formats; `chunks136` has an estimated span), `stopped` (waits for Stop), `download` (first run: real download events for the 0.6B model and the aligner; use a high speed). |
| `TRANSCRIBE_FAKE_SPEED` | Divides the recorded delays (`10` is ten times faster). |
| `TRANSCRIBE_FAKE_LOAD_STALL` | Seconds of silence after the load event: a download without download events, for the fallback "Preparing model" guess. |
| `TRANSCRIBE_FAKE_HF_CACHE` | `hf_cache` reported by `doctor --json`. Point it at an empty folder so the models look missing. |
| `TRANSCRIBE_FAKE_EXIT` | `3` (ffmpeg missing) or `2` (usage error). |

To re-record a fixture from the real CLI (paths are rewritten to `/tmp/fixture/…`):

```bash
scripts/record-fixture.py stopped --stop-after 40 -- run a.m4a long.mp4 zh.mp3 -f md,srt
scripts/record-fixture.py download --hf-home /tmp/empty-hf -- run a.m4a -f md,srt -m 0.6b
```

## Development hooks

These environment variables do nothing unless set. They exist for scripted checks and screenshots.

| Variable | Effect |
| --- | --- |
| `TRANSCRIBE_APPEARANCE=light\|dark` | Force an appearance. |
| `TRANSCRIBE_ADD="/a.m4a\|/b.mp4"` | Add files at launch (argv paths are treated as documents to open). |
| `TRANSCRIBE_SELECT=<row>\|none` | Select a row. |
| `TRANSCRIBE_AUTOSTART=1` | Press Start. |
| `TRANSCRIBE_STOP_AFTER=<s>` | Stop without the dialog after s seconds. |
| `TRANSCRIBE_RETRY_AFTER=<s>:<row>` | Press Retry on a row. |
| `TRANSCRIBE_QUIT_AFTER=<s>` | Quit after s seconds and confirm the "stop and quit" dialog. |
| `TRANSCRIBE_WINDOW_SIZE=<w>x<h>` | Set the main window's content size (narrow-width checks). |
| `TRANSCRIBE_OPEN_SETTINGS=1` | Open Settings (snapshots then capture it). `TRANSCRIBE_SETTINGS_TAB=general\|library\|appearance\|models` picks the tab. |
| `TRANSCRIBE_LIBRARY=/dir` | Use this library folder instead of ~/Transcrio Library (nothing is stored). Use a scratch folder for checks: Remove from History moves entry folders to the Trash. |
| `TRANSCRIBE_LIBRARY_SEED="demo\|/a.m4a"` | Fill an empty library: `demo` adds four entries whose sources are missing; each path adds an entry with that file's real fingerprint, so dropping it again is a known file. |
| `TRANSCRIBE_HISTORY_SELECT=<row>` | Select a History row. |
| `TRANSCRIBE_HISTORY_COLLAPSED=1\|0` | Collapse or expand History (remembered, like ⌃⌘H). |
| `TRANSCRIBE_SEARCH=<text>` | Type into the sidebar search. |
| `TRANSCRIBE_DROP_LATER="<s>:/a\|/b"` | Drop files after s seconds (fingerprinted like a real drop, so the re-drop notice shows). |
| `TRANSCRIBE_AGAIN_SHEET="<s>:<row>"` | Open Transcribe Again… for a History row. |
| `TRANSCRIBE_AGAIN="<s>:<row>"` | Queue a History row again with the other model and start it. |
| `TRANSCRIBE_REMOVE_ENTRY="<s>:<row>"` | Remove a History row, confirming 1 s later (`TRANSCRIBE_REMOVE_ENTRY_ASK_ONLY=1` leaves the alert up). |
| `TRANSCRIBE_STATE_LOG=/path` | Append every row's status, the History titles and any drop notice once a second. |
| `TRANSCRIBE_SNAPSHOTS="3:/a.png,8:/b.png"` | Render the window into PNGs at those times, then quit. This runs in-process, so it needs no Screen Recording permission. |
| `TRANSCRIBE_GALLERY=1` | Show the component gallery instead of the app. |
| `TRANSCRIBE_PREVIEW_SCRIPT="1:hover=2,4:select=1-3,5:copy=stamped,6:find=chunk"` | Drive the finished preview for snapshots: hover or select paragraphs, copy (plain or `stamped`), type into the find bar, `scroll=<s>` / `seek=<s>` like the overview, `menu` (logs the Edit and context menus). `TRANSCRIBE_PREVIEW_LOG=/path` collects the clipboard and overview spans. |
| `TRANSCRIBE_HANG_LOG=/path.json` | Measure main-thread latency (5 ms pings; hangs over 50 ms, overall and in the 15 s after Start) and CPU use; the JSON is rewritten every second. |
| `TRANSCRIBE_SMOKE_AUDIO=/path.m4a` | (tests) Run the real-CLI smoke test against this file. |

Example: snapshot a long run in dark mode.

```bash
TRANSCRIBE_APPEARANCE=dark TRANSCRIBE_ADD="$HOME/a.m4a" TRANSCRIBE_SELECT=0 \
TRANSCRIBE_CLI=$PWD/scripts/fake-transcribe.sh TRANSCRIBE_FAKE_FIXTURE=long \
TRANSCRIBE_AUTOSTART=1 TRANSCRIBE_SNAPSHOTS="10:/tmp/run.png,30:/tmp/done.png" \
.build/debug/TranscribeApp
```

## Keyboard

| Key | Action |
| --- | --- |
| ⌘O | Add files |
| ⌘R / ⌘. | Start / Stop (Stop asks first: it ends the whole batch) |
| ↑ ↓ | Move through the queue |
| Delete or ⌘⌫ | Remove the selected row (not while it's in the running batch) |
| Space or ⌘Y | Quick Look the selected file's first output (or the media if unfinished) |
| ⌥⌘1 / ⌥⌘I | Show or hide the center pane / inspector |
| ⌃⌘H | Collapse or expand History |
| ⇧⌘R | Show the selected output or library folder in Finder |
| Delete (in History) | Remove the selected entries from History (asks first; folders go to the Trash) |
