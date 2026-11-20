#!/bin/bash
# Fake `transcribe` CLI for tests and UI development. It replays a fixture recorded from
# the real CLI (Tests/TranscribeKitTests/Fixtures/<name>/) with the recorded delays, maps
# the fixture's input files onto the real arguments, copies the recorded outputs into
# place, and handles SIGTERM/SIGINT like the real CLI: a file_stopped event for the current
# file and every file not started yet, the summary with those entries marked stopped, and
# exit 143 (130 for SIGINT).
#
# Environment:
#   TRANSCRIBE_FAKE_FIXTURE     fixture name (default: success); see Fixtures/
#   TRANSCRIBE_FAKE_FIXTURES    fixtures directory (default: next to this script)
#   TRANSCRIBE_FAKE_SPEED       delay divisor, e.g. 10 = ten times faster (default: 1)
#   TRANSCRIBE_FAKE_LOAD_STALL  extra silent seconds after the `load` event (a download without
#                               download events, for the fallback guess)
#   TRANSCRIBE_FAKE_EXIT        3 = pretend ffmpeg is missing; 2 = usage error
#   TRANSCRIBE_FAKE_HF_CACHE    hf_cache reported by `doctor --json`
#
# Works with the stock macOS bash 3.2.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="${TRANSCRIBE_FAKE_FIXTURES:-$HERE/../Tests/TranscribeKitTests/Fixtures}"
FIXTURE="${TRANSCRIBE_FAKE_FIXTURE:-success}"
SPEED="${TRANSCRIBE_FAKE_SPEED:-1}"
LOAD_STALL="${TRANSCRIBE_FAKE_LOAD_STALL:-0}"
DIR="$FIXTURES/$FIXTURE"

SLEEP_PID=""
STOP_CODE=""
on_signal() {
    STOP_CODE=$1
    [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
}
trap 'on_signal 143' TERM
trap 'on_signal 130' INT

# Interruptible sleep: a trapped signal ends `wait` immediately.
nap() {
    local secs
    secs=$(awk -v d="$1" -v s="$SPEED" 'BEGIN { v = d / s; if (v < 0) v = 0; printf "%.3f", v }')
    sleep "$secs" &
    SLEEP_PID=$!
    wait "$SLEEP_PID"
    SLEEP_PID=""
}

json_escape() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }

case "${1:-}" in
    doctor)
        if [ "${TRANSCRIBE_FAKE_EXIT:-}" = 3 ]; then
            sed -e 's/"ok": true/"ok": false/' -e 's#"ffmpeg": "[^"]*"#"ffmpeg": null#' "$FIXTURES/doctor.json"
            exit 3
        fi
        if [ -n "${TRANSCRIBE_FAKE_HF_CACHE:-}" ]; then
            sed "s#\"hf_cache\": \"[^\"]*\"#\"hf_cache\": \"$(json_escape "$TRANSCRIBE_FAKE_HF_CACHE")\"#" "$FIXTURES/doctor.json"
        else
            cat "$FIXTURES/doctor.json"
        fi
        exit 0 ;;
    backends) cat "$FIXTURES/backends.json"; exit 0 ;;
    --version) echo "transcribe 0.0.0-fake"; exit 0 ;;
    run) shift ;;
esac

INPUTS=(); OUT_DIR=""; WANT_JSON=0; FORMATS="md"
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--format) FORMATS="$2"; shift 2 ;;
        -l|--language|-m|--model|-b|--backend|--context|--progress) shift 2 ;;
        -o|--output-dir) OUT_DIR="$2"; shift 2 ;;
        --output-dir=*) OUT_DIR="${1#*=}"; shift ;;
        --json) WANT_JSON=1; shift ;;
        -*) shift ;;
        *) INPUTS+=("$1"); shift ;;
    esac
done

if [ "${TRANSCRIBE_FAKE_EXIT:-}" = 3 ]; then
    echo "transcribe: ffmpeg not found on PATH (install with: brew install ffmpeg)" >&2
    exit 3
fi
if [ "${TRANSCRIBE_FAKE_EXIT:-}" = 2 ] || [ ${#INPUTS[@]} -eq 0 ]; then
    echo "usage: transcribe run [-h] ... inputs [inputs ...]" >&2
    exit 2
fi
[ -d "$DIR" ] || { echo "fake-transcribe: no fixture $DIR" >&2; exit 2; }

# Fixture lines, their timestamps, and the distinct fixture inputs in order of appearance.
LINES=(); TIMES=(); FX=()
while IFS= read -r line; do
    [ -z "$line" ] && continue
    LINES+=("$line")
    f=${line#*\"file\": \"}; f=${f%%\"*}
    seen=0
    for x in ${FX[@]+"${FX[@]}"}; do [ "$x" = "$f" ] && seen=1; done
    [ $seen = 0 ] && FX+=("$f")
done < "$DIR/stderr.ndjson"
while IFS= read -r t; do TIMES+=("$t"); done < "$DIR/timing.txt"

N=${#INPUTS[@]}; G=${#FX[@]}
FAILED=0; RESULTS=""; PREV_T=""
FINISHED=","   # indexes of inputs that got file_done or file_error

abs_input() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$PWD/$1" ;; esac; }

# What the real CLI does after SIGTERM/SIGINT: file_stopped for every unfinished input, then
# the summary (stopped entries included) and exit 143/130.
stop_now() {
    local i real
    for (( i = 0; i < N; i++ )); do
        case "$FINISHED" in *",$i,"*) continue ;; esac
        real=$(json_escape "$(abs_input "${INPUTS[$i]}")")
        printf '{"file": "%s", "event": "file_stopped"}\n' "$real" >&2
        RESULTS="${RESULTS:+$RESULTS, }{\"input\": \"$real\", \"outputs\": {}, \"error\": null, \"stopped\": true}"
    done
    echo "/fake/resource_tracker.py:254: UserWarning: resource_tracker: There appear to be 1 leaked semaphore objects to clean up at shutdown" >&2
    [ $WANT_JSON = 1 ] && printf '{"results": [%s]}\n' "$RESULTS"
    exit "$STOP_CODE"
}

for (( r = 0; r * G < N; r++ )); do
    for (( j = 0; j < ${#LINES[@]}; j++ )); do
        line=${LINES[$j]}
        f=${line#*\"file\": \"}; f=${f%%\"*}
        k=0; for (( m = 0; m < G; m++ )); do [ "${FX[$m]}" = "$f" ] && k=$m; done
        i=$(( r * G + k ))
        [ $i -ge $N ] && continue
        # The model loads (and downloads) once per process: only the first pass sends those.
        case "$line" in *'"stage": "load"'*|*'"stage": "download"'*) [ $r -gt 0 ] && continue ;; esac

        t=${TIMES[$j]:-0}
        [ -n "$PREV_T" ] && nap "$(awk -v a="$t" -v b="$PREV_T" 'BEGIN { print a - b }')"
        [ -n "$STOP_CODE" ] && stop_now
        PREV_T=$t

        real=$(abs_input "${INPUTS[$i]}")
        stem=$(basename "${real%.*}")
        fstem=$(basename "${f%.*}")
        out=${OUT_DIR:-$(dirname "$real")}
        line=${line//"$f"/$(json_escape "$real")}
        pat="/tmp/fixture/out/$fstem."
        line=${line//"$pat"/$(json_escape "$out/$stem.")}
        case "$line" in
            *'"event": "file_done"'*)
                # Keep only the requested formats, as the real CLI would write.
                for fmt in md txt srt vtt json; do
                    case ",$FORMATS," in *",$fmt,"*) ;; *)
                        line=$(printf '%s' "$line" | sed -E "s/\"$fmt\": \"[^\"]*\", ?//; s/, \"$fmt\": \"[^\"]*\"//") ;;
                    esac
                done ;;
        esac
        case "$line" in *'"event": "file_stopped"'*) continue ;; esac
        printf '%s\n' "$line" >&2

        case "$line" in
            *'"event": "file_done"'*)
                FINISHED="$FINISHED$i,"
                mkdir -p "$out"
                for src in "$DIR/outputs/$fstem".*; do
                    ext=${src##*.}
                    case ",$FORMATS," in *",$ext,"*) [ -e "$src" ] && cp "$src" "$out/$stem.$ext" ;; esac
                done
                entry=${line/\"file\": /\"input\": }
                entry=${entry/\"event\": \"file_done\", /\"error\": null, \"backend\": \"qwen3-mlx\", }
                RESULTS="${RESULTS:+$RESULTS, }$entry" ;;
            *'"event": "file_error"'*)
                FINISHED="$FINISHED$i,"
                FAILED=1
                entry=${line/\"file\": /\"input\": }
                entry=${entry/\"event\": \"file_error\", /\"outputs\": {}, }
                RESULTS="${RESULTS:+$RESULTS, }$entry" ;;
            *'"stage": "load"'*)
                [ "$LOAD_STALL" != 0 ] && nap "$(awk -v a="$LOAD_STALL" -v s="$SPEED" 'BEGIN { print a * s }')" ;;
        esac
        [ -n "$STOP_CODE" ] && stop_now
    done
done

# A fixture recorded with a stop ends mid-file: wait to be stopped, like the real run would.
case "$(cat "$DIR/exit" 2>/dev/null)" in
    143|130|SIGTERM) while :; do nap 3600; [ -n "$STOP_CODE" ] && stop_now; done ;;
esac

[ $WANT_JSON = 1 ] && printf '{"results": [%s]}\n' "$RESULTS"
exit $FAILED
