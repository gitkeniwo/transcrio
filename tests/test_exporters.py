from transcribe.exporters import ExportOptions, render
from transcribe.languages import normalize
from transcribe.segmenting import display_width, estimate_cues
from transcribe.types import Segment, Transcript


def _t(**kw):
    base = dict(text="你好。世界！", language="Chinese", duration=4.0, backend="x", model="m",
                segments=[Segment("你好。世界！", 0.0, 4.0)])
    base.update(kw)
    return Transcript(**base)


def test_normalize():
    assert normalize("zh") == "Chinese"
    assert normalize("auto") is None
    assert normalize("german") == "German"


def test_estimate_cues_splits_sentences_and_spans_time():
    cues = estimate_cues([Segment("你好。世界！", 10.0, 14.0)], "Chinese")
    assert [c.text for c in cues] == ["你好。", "世界！"]
    assert cues[0].start == 10.0 and abs(cues[-1].end - 14.0) < 1e-9


def test_estimate_cues_wraps_long_latin_text():
    text = " ".join(["word"] * 40) + "."
    cues = estimate_cues([Segment(text, 0, 20)], "English", max_width=42)
    assert all(display_width(c.text) <= 42 for c in cues)
    assert " ".join(c.text for c in cues) == text


def test_srt_uses_cues_when_present():
    t = _t(cues=[Segment("你好。", 0.0, 1.5), Segment("世界！", 1.5, 3.25)], cue_timing="aligned")
    assert render("srt", t, ExportOptions()) == (
        "1\n00:00:00,000 --> 00:00:01,500\n你好。\n\n2\n00:00:01,500 --> 00:00:03,250\n世界！\n"
    )


def test_md_timestamps_and_vtt():
    t = _t(segments=[Segment("a", 0, 30), Segment("b", 3725, 3730)])
    md = render("md", t, ExportOptions(timestamps=True, title="ep1", source="ep1.mp3"))
    assert md.startswith("# ep1\n") and "**[01:02:05]** b" in md
    assert render("vtt", t, ExportOptions()).startswith("WEBVTT\n\n00:00:00.000 --> ")


def test_write_text_is_atomic(tmp_path):
    from transcribe.exporters import write_text

    out = tmp_path / "a.md"
    write_text("hello", out)
    assert out.read_text() == "hello"
    assert [p.name for p in tmp_path.iterdir()] == ["a.md"]


def test_warn_records_message_and_notice():
    t = _t()
    t.warn("timing_estimated", "estimated", [(0.0, 3.6003125)])
    assert t.warnings == ["estimated"]
    assert t.to_dict()["notices"] == [{"code": "timing_estimated", "message": "estimated", "spans": [(0.0, 3.6)]}]


def test_stop_reports_unfinished_files(tmp_path, capsys):
    import argparse
    from pathlib import Path

    from transcribe.cli import Progress, _report_stopped

    partial = tmp_path / "b.md"
    partial.write_text("x")
    args = argparse.Namespace(inputs=[Path("a.mp3"), Path("b.mp3"), Path("c.mp3")])
    results = [
        {"input": "a.mp3", "outputs": {"md": "a.md"}, "error": None, "elapsed": 1.0},
        {"input": "b.mp3", "outputs": {"md": str(partial)}, "error": None},
    ]
    _report_stopped(args, Progress("ndjson"), results)
    assert [r.get("stopped", False) for r in results] == [False, True, True]
    assert results[1]["outputs"] == {} and not partial.exists()
    events = capsys.readouterr().err.splitlines()
    assert events == ['{"file": "b.mp3", "event": "file_stopped"}', '{"file": "c.mp3", "event": "file_stopped"}']


def test_reconcile_language_trusts_script():
    from transcribe.languages import reconcile_language

    assert reconcile_language("English", "大家好，这是一段用于测试转录应用的简短录音。") == "Chinese"
    assert reconcile_language("English", "こんにちは、今日はテストです。") == "Japanese"
    assert reconcile_language("English", "안녕하세요 테스트입니다") == "Korean"
    assert reconcile_language("English", "We tested Kubernetes 和 Docker today.") == "English"
    assert reconcile_language("Cantonese", "大家好") == "Cantonese"
    assert reconcile_language("Spanish", "hola a todos") == "Spanish"
