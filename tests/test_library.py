"""The library's master copy: Transcript.from_dict and `transcribe export`."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from transcribe import cli
from transcribe.exporters import EXPORTERS, ExportOptions, render
from transcribe.types import Segment, Transcript, Word


def full_transcript() -> Transcript:
    t = Transcript(
        text="Hello there. General Kenobi.",
        language="English",
        duration=61.5,
        backend="qwen3-mlx",
        model="Qwen/Qwen3-ASR-1.7B",
        segments=[Segment("Hello there.", 0.0, 30.0), Segment("General Kenobi.", 30.0, 61.5, speaker="B")],
        cues=[Segment("Hello there.", 0.12, 1.5), Segment("General Kenobi.", 30.2, 31.75)],
        cue_timing="aligned",
        words=[Word("Hello", 0.12, 0.5), Word("there.", 0.6, 1.5)],
    )
    t.warn("truncated", "chunk 2 hit the token limit", [(30.0, 61.5)])
    return t


def plain_transcript() -> Transcript:
    return Transcript(text="你好。世界！", language="Chinese", duration=4.0, backend="x", model="m",
                      segments=[Segment("你好。世界！", 0.0, 4.0)])  # fmt: skip


@pytest.mark.parametrize("make", [full_transcript, plain_transcript])
def test_from_dict_round_trips_through_json(make):
    t = make()
    data = json.loads(render("json", t, ExportOptions(source="talk.wav")))
    assert data["source"] == "talk.wav"
    back = Transcript.from_dict(data)
    assert back == t
    for timestamps in (False, True):
        opts = ExportOptions(timestamps=timestamps, title="talk", source="talk.wav")
        for fmt in EXPORTERS:
            assert render(fmt, back, opts) == render(fmt, t, opts), fmt


def test_from_dict_rejects_bad_shapes():
    with pytest.raises(ValueError, match="missing 'language'"):
        Transcript.from_dict({"text": "x", "duration": 1})
    with pytest.raises(ValueError):
        Transcript.from_dict({"text": "x", "language": "en", "duration": 1, "segments": [{"text": "a"}]})
    with pytest.raises(ValueError):
        Transcript.from_dict(["not", "an", "object"])


def save(tmp_path: Path, t: Transcript, source: str | None = "talk.wav", name: str = "transcript.json") -> Path:
    path = tmp_path / name
    path.write_text(render("json", t, ExportOptions(source=source)), encoding="utf-8")
    return path


def test_export_writes_formats_named_after_the_source(tmp_path, capsys):
    src = save(tmp_path, full_transcript())
    out = tmp_path / "out"
    assert cli.main(["export", str(src), "-f", "md,srt,vtt,txt,json", "-o", str(out)]) == 0
    captured = capsys.readouterr()
    names = sorted(p.name for p in out.iterdir())
    assert names == ["talk.json", "talk.md", "talk.srt", "talk.txt", "talk.vtt"]
    assert captured.out.split() == [str(out / f"talk.{f}") for f in ("md", "srt", "vtt", "txt", "json")]
    assert captured.err == ""  # aligned cues: no estimated-timing notice
    opts = ExportOptions(title="talk", source="talk.wav")
    for fmt in ("md", "srt", "vtt", "txt", "json"):
        assert (out / f"talk.{fmt}").read_text(encoding="utf-8") == render(fmt, full_transcript(), opts)
    assert "# talk" in (out / "talk.md").read_text() and "Source: `talk.wav`" in (out / "talk.md").read_text()


def test_export_title_source_timestamps_and_overwrite(tmp_path, capsys):
    src = save(tmp_path, full_transcript())
    (tmp_path / "My Talk.md").write_text("old")
    assert cli.main(["export", str(src), "-f", "md", "--title", "My Talk", "--source", "x.m4a", "-t"]) == 0
    md = (tmp_path / "My Talk.md").read_text()
    assert md.startswith("# My Talk\n") and "Source: `x.m4a`" in md and "**[00:00:30]** General Kenobi." in md


def test_export_title_falls_back_to_the_transcript_stem(tmp_path, capsys):
    src = save(tmp_path, plain_transcript(), source=None, name="lecture.json")
    assert cli.main(["export", str(src), "-f", "txt", "-o", str(tmp_path / "o")]) == 0
    assert (tmp_path / "o" / "lecture.txt").read_text() == "你好。世界！\n"


def test_export_srt_without_cues_estimates_and_says_so(tmp_path, capsys):
    src = save(tmp_path, plain_transcript())
    assert cli.main(["export", str(src), "-f", "srt", "-o", str(tmp_path)]) == 0
    err = capsys.readouterr().err
    assert "estimated" in err and err.count("\n") == 1
    assert (tmp_path / "talk.srt").read_text().startswith("1\n00:00:00,000 --> ")


@pytest.mark.parametrize("content", ["{not json", '{"text": "x"}', "[1, 2]", None])
def test_export_bad_input_fails_with_a_message(tmp_path, capsys, content):
    src = tmp_path / "t.json"
    if content is not None:
        src.write_text(content)
    assert cli.main(["export", str(src), "-f", "md", "-o", str(tmp_path / "o")]) == 1
    err = capsys.readouterr().err
    assert err.startswith("transcribe: ") and str(src) in err
    assert not (tmp_path / "o").exists() or not any((tmp_path / "o").iterdir())


def test_export_does_not_import_numpy_or_mlx(tmp_path):
    src = save(tmp_path, full_transcript())
    code = (
        "import sys; from transcribe import cli; rc = cli.main(['export', sys.argv[1], '-f', 'md,srt']); "
        "heavy = [m for m in sys.modules if m.split('.')[0] in ('numpy', 'mlx', 'mlx_audio')]; "
        "print(heavy, file=sys.stderr); sys.exit(rc or (1 if heavy else 0))"
    )
    proc = subprocess.run([sys.executable, "-c", code, str(src)], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr


# -- transcribe align ----------------------------------------------------------------------------

import dataclasses  # noqa: E402
import wave  # noqa: E402

from fakes import FakeBackend  # noqa: E402
from transcribe import backends  # noqa: E402


def make_wav(path: Path, seconds: float) -> Path:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16_000)
        w.writeframes(b"\x00\x00" * int(16_000 * seconds))
    return path


def estimated_transcript() -> Transcript:
    """What a run with alignment off (or before an aligner existed) saved: no cues, a truncated notice."""
    t = Transcript(text="hello there general kenobi", language="English", duration=40.0, backend="fake",
                   model="fake/default", segments=[Segment("hello there", 0.0, 30.0),
                                                   Segment("general kenobi", 30.0, 40.0)])  # fmt: skip
    t.warn("truncated", "chunk 2 hit the token limit", [(30.0, 40.0)])
    t.warn("timing_estimated", "subtitle timing is estimated", [(0.0, 40.0)])
    return t


@pytest.fixture
def fake_backend(monkeypatch):
    FakeBackend.reset()
    FakeBackend.aligns = True
    monkeypatch.setattr(backends, "create", lambda name, model=None: FakeBackend(model))
    yield FakeBackend
    FakeBackend.reset()


def test_align_rewrites_cues_in_place_and_keeps_the_rest(tmp_path, capsys, fake_backend):
    src = save(tmp_path, estimated_transcript())
    wav = make_wav(tmp_path / "talk.wav", 40)
    assert cli.main(["align", str(src), str(wav), "--progress", "none"]) == 0
    assert capsys.readouterr().out.strip() == str(src)
    data = json.loads(src.read_text(encoding="utf-8"))
    assert data["source"] == "talk.wav" and data["text"] == "hello there general kenobi"
    assert data["cue_timing"] == "aligned"
    assert [c["text"] for c in data["cues"]] == ["hello there", "general kenobi"]
    assert data["cues"][1]["start"] == pytest.approx(30.1)
    assert [w["text"] for w in data["words"]] == ["hello", "there", "general", "kenobi"]
    assert [n["code"] for n in data["notices"]] == ["truncated"]
    assert data["warnings"] == ["chunk 2 hit the token limit"]
    # Each segment is aligned against its own clip; the ASR model is never loaded.
    assert fake_backend.align_log == ["align:0-30:30s", "align:30-40:10s"]
    assert fake_backend.log == []
    assert not list(tmp_path.glob(".*.part"))
    srt = render("srt", Transcript.from_dict(data), ExportOptions())
    assert "00:00:30,100 --> " in srt


def test_align_to_another_file_leaves_the_original(tmp_path, capsys, fake_backend):
    src = save(tmp_path, estimated_transcript())
    before = src.read_text()
    out = tmp_path / "sub" / "aligned.json"
    assert cli.main(["align", str(src), str(make_wav(tmp_path / "a.wav", 40)), "-o", str(out), "--progress", "none"]) == 0
    assert src.read_text() == before
    assert json.loads(out.read_text())["cue_timing"] == "aligned"


def test_align_keeps_estimated_parts_when_the_aligner_cannot(tmp_path, capsys, fake_backend):
    fake_backend.aligns = False
    src = save(tmp_path, estimated_transcript())
    assert cli.main(["align", str(src), str(make_wav(tmp_path / "a.wav", 40)), "--progress", "none"]) == 0
    data = json.loads(src.read_text())
    assert data["cue_timing"] == "estimated"
    assert [n["code"] for n in data["notices"]] == ["truncated", "timing_estimated"]  # one, re-reported


def test_align_errors(tmp_path, capsys, fake_backend, monkeypatch):
    src = save(tmp_path, estimated_transcript())
    before = src.read_text()
    # The source is clearly another file.
    assert cli.main(["align", str(src), str(make_wav(tmp_path / "short.wav", 12)), "--progress", "none"]) == 1
    assert "is it the right source file" in capsys.readouterr().err
    # Missing source.
    assert cli.main(["align", str(src), str(tmp_path / "gone.wav"), "--progress", "none"]) == 1
    assert "no such file" in capsys.readouterr().err
    # A language the backend has no aligner for.
    monkeypatch.setattr(FakeBackend, "info", dataclasses.replace(FakeBackend.info, aligned_languages=frozenset({"Chinese"})))
    assert cli.main(["align", str(src), str(make_wav(tmp_path / "a.wav", 40)), "--progress", "none"]) == 1
    assert "no forced aligner for English" in capsys.readouterr().err
    # A transcript with no text.
    empty = save(tmp_path, Transcript(text="", language="Chinese", duration=40.0, backend="x", model="m"), name="e.json")
    assert cli.main(["align", str(empty), str(tmp_path / "a.wav"), "--progress", "none"]) == 1
    assert "nothing to align" in capsys.readouterr().err
    assert src.read_text() == before


def test_align_chinese_keeps_text_and_source(tmp_path, capsys, fake_backend, monkeypatch):
    t = Transcript(text="你好 世界", language="Chinese", duration=4.0, backend="x", model="m",
                   segments=[Segment("你好 世界", 0.0, 4.0)])  # fmt: skip
    src = save(tmp_path, t, source="讲座.m4a")
    assert cli.main(["align", str(src), str(make_wav(tmp_path / "a.wav", 4.5)), "--progress", "none"]) == 0
    data = json.loads(src.read_text(encoding="utf-8"))
    assert data["source"] == "讲座.m4a" and data["cues"][0]["text"] == "你好 世界"
    assert "你好" in src.read_text(encoding="utf-8")  # not \u-escaped
