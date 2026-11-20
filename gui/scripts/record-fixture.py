#!/usr/bin/env python3
"""Record a fixture for fake-transcribe.sh from the real `transcribe` CLI.

    scripts/record-fixture.py NAME [--stop-after S] [--hf-home DIR] [--touch FILE] -- run AUDIO... -f md,srt ...

The audio files are copied to a temporary folder, the CLI runs on the copies with
`--json --progress ndjson`, and the result lands in Tests/TranscribeKitTests/Fixtures/NAME/:
stderr.ndjson (non-JSON stderr lines dropped), timing.txt (seconds since start per line),
stdout.json, exit and outputs/. Paths are rewritten to /tmp/fixture/audio and /tmp/fixture/out
so fixtures don't depend on where they were recorded. --stop-after sends SIGTERM after S
seconds, like the app's Stop. This is a development tool; the app never runs Python.
"""
import argparse
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
FIXTURES = HERE.parent / "Tests" / "TranscribeKitTests" / "Fixtures"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--stop-after", type=float)
    ap.add_argument("--hf-home")
    ap.add_argument("--touch", action="append", default=[], help="create this file in the output folder first")
    ap.add_argument("--cli", default=os.path.expanduser("~/.local/bin/transcribe"))
    argv = sys.argv[1:]
    if "--" not in argv:
        ap.error("put the CLI arguments after --")
    cut = argv.index("--")
    a = ap.parse_args(argv[:cut])
    args = argv[cut + 1:]

    work = pathlib.Path(tempfile.mkdtemp(prefix="fixture-"))
    audio, out = work / "audio", work / "out"
    audio.mkdir()
    out.mkdir()
    for name in a.touch:
        (out / name).write_text("existing\n")
    real_args = []
    for arg in args:
        p = pathlib.Path(arg)
        if p.suffix and p.is_file():
            shutil.copy(p, audio / p.name)
            real_args.append(str(audio / p.name))
        else:
            real_args.append(arg)
    if "-o" not in real_args:
        real_args += ["-o", str(out)]
    cmd = [a.cli] + real_args + ["--json", "--progress", "ndjson"]

    env = dict(os.environ)
    if a.hf_home:
        env["HF_HOME"] = a.hf_home
    print("+", " ".join(cmd), file=sys.stderr)
    start = time.monotonic()
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
    if a.stop_after:
        threading.Timer(a.stop_after, lambda: proc.send_signal(signal.SIGTERM)).start()

    lines, times, other = [], [], []
    stdout_chunks = []
    t = threading.Thread(target=lambda: stdout_chunks.append(proc.stdout.read()))
    t.start()
    for line in proc.stderr:
        line = line.rstrip("\n")
        try:
            json.loads(line)
        except ValueError:
            other.append(line)
            continue
        lines.append(line)
        times.append(time.monotonic() - start)
        if '"stage": "download"' not in line:
            print(line[:160], file=sys.stderr)
    code = proc.wait()
    t.join()

    def scrub(s: str) -> str:
        return s.replace(str(audio), "/tmp/fixture/audio").replace(str(out), "/tmp/fixture/out")

    dest = FIXTURES / a.name
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    (dest / "stderr.ndjson").write_text("".join(scrub(l) + "\n" for l in lines))
    (dest / "timing.txt").write_text("".join(f"{x:.3f}\n" for x in times))
    stdout = stdout_chunks[0] if stdout_chunks else ""
    if stdout.strip():
        (dest / "stdout.json").write_text(json.dumps(json.loads(scrub(stdout)), indent=2, ensure_ascii=False) + "\n")
    (dest / "exit").write_text(f"{code}\n")
    outputs = [p for p in out.iterdir() if p.is_file() and not p.name.startswith(".") and p.name not in a.touch]
    if outputs:
        (dest / "outputs").mkdir()
        for p in outputs:
            shutil.copy(p, dest / "outputs" / p.name)
    for line in other:
        print("stderr (not JSON):", line, file=sys.stderr)
    print(f"exit {code}, {len(lines)} events, {len(outputs)} outputs -> {dest}", file=sys.stderr)
    shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
