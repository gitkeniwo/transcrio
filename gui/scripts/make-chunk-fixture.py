#!/usr/bin/env python3
"""Writes a synthetic fake-CLI fixture with N chunks (development only; the app never runs Python).

The events follow the shape of the recorded `long` fixture: decode, load, one `transcribe`
event at the start and end of every chunk, `align` per chunk, then `file_done`. The outputs
are md (with timestamps), txt, srt and vtt built from deterministic filler text, so the
finished preview has real paragraphs and cue times to work with.

    scripts/make-chunk-fixture.py chunks136 --chunks 136 --duration 2641.6 --estimated 950:1044
    scripts/make-chunk-fixture.py chunks8 --chunks 8 --duration 240
"""
import argparse
import json
import os
import random

WORDS = (
    "the city council met on tuesday to talk about traffic on the main road and the new bike lanes "
    "people said the buses come too late in the morning while others asked for more parking near "
    "the schools a planner showed how the lights could be timed so that cars and bikes share the "
    "street more safely and the meeting ended with a plan to test the idea for three months"
).split()


def stamp(t, sep=","):
    ms = int(round(t * 1000))
    h, ms = divmod(ms, 3_600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d}{sep}{ms:03d}"


def hms(t):
    t = int(t)
    return f"{t // 3600:02d}:{t % 3600 // 60:02d}:{t % 60:02d}"


def sentence(rng):
    n = rng.randint(6, 14)
    start = rng.randrange(len(WORDS))
    words = [WORDS[(start + i) % len(WORDS)] for i in range(n)]
    return " ".join(words).capitalize() + "."


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--chunks", type=int, required=True)
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--chunk-seconds", type=float, default=2.3, help="processing time per chunk")
    ap.add_argument("--estimated", help="START:END seconds whose timing is estimated (adds a notice)")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "..", "Tests", "TranscribeKitTests", "Fixtures", args.name)
    os.makedirs(os.path.join(out, "outputs"), exist_ok=True)
    stem = args.name
    src = f"/tmp/fixture/audio/{stem}.m4a"
    rng = random.Random(args.chunks)

    # Cues of 3–6 s covering the audio, then paragraphs of 6–10 cues.
    cues, t = [], 0.0
    while t < args.duration - 1:
        d = min(rng.uniform(3, 6), args.duration - t)
        cues.append((t, t + d * 0.92, sentence(rng)))
        t += d
    paras, i = [], 0
    while i < len(cues):
        n = rng.randint(6, 10)
        group = cues[i:i + n]
        paras.append((group[0][0], " ".join(c[2] for c in group)))
        i += n

    events, times, clock = [], [], 0.0

    def emit(dt, **e):
        nonlocal clock
        clock += dt
        events.append({"file": src, **e})
        times.append(round(clock, 3))

    total = args.chunks
    emit(0.25, event="progress", stage="decode", progress=0.0)
    emit(2.4, event="progress", stage="load", progress=0.0)
    emit(3.1, event="progress", stage="transcribe", progress=0.0, chunk=None, total_chunks=total)
    for c in range(1, total + 1):
        start = (c - 1) / total
        emit(0.02 if c > 1 else 0.0, event="progress", stage="transcribe", progress=start, chunk=c, total_chunks=total)
        emit(args.chunk_seconds * rng.uniform(0.8, 1.2), event="progress", stage="transcribe",
             progress=c / total, chunk=c, total_chunks=total)
    for c in range(total + 1):
        emit(0.15 if c else 0.05, event="progress", stage="align", progress=c / total)

    outputs = {f: f"/tmp/fixture/out/{stem}.{f}" for f in ("md", "srt", "txt", "vtt")}
    notices, warnings, timing = [], [], "aligned"
    if args.estimated:
        a, b = (float(x) for x in args.estimated.split(":"))
        msg = (f"subtitle timing is estimated from {hms(a)[3:]} to {hms(b)[3:]}: "
               "the aligner could not match this part")
        notices.append({"code": "timing_estimated", "message": msg, "spans": [[a, b]]})
        warnings.append(msg)
        timing = "mixed"
    elapsed = round(clock + 0.4, 2)
    done = {"outputs": outputs, "elapsed": elapsed, "language": "English", "duration": args.duration,
            "model": "Qwen/Qwen3-ASR-1.7B", "cue_timing": timing, "warnings": warnings, "notices": notices}
    emit(0.4, event="file_done", **done)

    with open(os.path.join(out, "stderr.ndjson"), "w") as f:
        for e in events:
            f.write(json.dumps(e) + "\n")
    with open(os.path.join(out, "timing.txt"), "w") as f:
        f.write("\n".join(f"{x:.3f}" for x in times) + "\n")
    with open(os.path.join(out, "exit"), "w") as f:
        f.write("0\n")
    summary = {"results": [{"input": src, "outputs": outputs, "error": None, "language": "English",
                            "duration": args.duration, "elapsed": elapsed, "backend": "qwen3-mlx",
                            "model": "Qwen/Qwen3-ASR-1.7B", "cue_timing": timing,
                            "warnings": warnings, "notices": notices}]}
    with open(os.path.join(out, "stdout.json"), "w") as f:
        json.dump(summary, f, indent=2)
        f.write("\n")

    o = os.path.join(out, "outputs", stem)
    with open(o + ".md", "w") as f:
        f.write(f"# {stem}\n\n- Source: `{stem}.m4a`\n- Duration: {hms(args.duration)}\n"
                "- Language: English\n- Model: Qwen/Qwen3-ASR-1.7B\n\n---\n\n")
        f.write("\n\n".join(f"**[{hms(s)}]** {text}" for s, text in paras) + "\n")
    with open(o + ".txt", "w") as f:
        f.write("\n\n".join(text for _, text in paras) + "\n")
    with open(o + ".srt", "w") as f:
        f.write("\n".join(f"{n}\n{stamp(a)} --> {stamp(b)}\n{text}\n" for n, (a, b, text) in enumerate(cues, 1)))
    with open(o + ".vtt", "w") as f:
        f.write("WEBVTT\n\n" + "\n".join(f"{stamp(a, '.')} --> {stamp(b, '.')}\n{text}\n" for a, b, text in cues))
    print(f"{out}: {total} chunks, {len(paras)} paragraphs, {len(cues)} cues, {clock:.0f} s")


if __name__ == "__main__":
    main()
