#!/usr/bin/env python3
"""Opt-in real 4K PQ encode heartbeat check. Argument: local video-only 4K PQ MP4.
No provider/credentials, visible window, installed app or hardware audio lease.
Instrument a temporary source copy to observe the actual current-buffer encoder.
"""
import pathlib, subprocess, json, sys, tempfile
repo = pathlib.Path(__file__).resolve().parent.parent
fixture = pathlib.Path(sys.argv[1]).resolve(strict=True)
with tempfile.TemporaryDirectory(prefix="nesn-capture-heartbeat-") as tmp:
    root = pathlib.Path(tmp)
    text = (repo / "Sources/NESNPlayer/FrameCapture.swift").read_text()
    needle = "private static func encodeCurrentBuffer(_ buffer: CVPixelBuffer) throws -> Screenshot {"
    assert text.count(needle) == 1
    instrumented = text.replace(needle, needle + "\n        EncodeProbe.shared.begin()\n        defer { EncodeProbe.shared.end() }")
    source = root / "FrameCapture.swift"
    source.write_text(instrumented)
    binary = root / "probe"
    subprocess.run(["nice", "-n", "10", "xcrun", "swiftc", "-swift-version", "6", "-target", "arm64-apple-macosx14.0", "-parse-as-library", str(source), str(repo / "Tests/CaptureResponsiveness/Probe.swift"), "-o", str(binary)], check=True)
    result = root / "result.json"
    subprocess.run([str(binary), str(result), str(fixture)], check=True, timeout=30)
    r = json.loads(result.read_text())
    outcome = r["outcome"]
    assert outcome.get("width") == 3840 and outcome.get("height") == 2160, outcome
    assert outcome["hdr"] and outcome["bits"] == 16 and outcome["savedUnique"] and outcome["savedBytesEqual"], outcome
    assert r["remainingOutputs"] == 0 and r["sameItem"] and r["layerPlayerUnchanged"]
    assert r["encodeWindows"], "Actual current-buffer encoder not exercised"
    for start, main, end in r["encodeWindows"]:
        beats = [s for s in r["samples"] if start < s["host"] < end]
        assert not main, "Conversion/encoding ran on main thread"
        assert len(beats) >= 2, "Main run loop did not advance during encoding"
        advance = beats[-1]["player"] - beats[0]["player"]
        assert advance > 0, "Player did not advance during encoding"
        assert all(not flag for s in r["samples"] for flag in s["outputSuppression"])
        print(json.dumps({"encodingSeconds": end-start, "heartbeatsDuringEncoding": len(beats), "playerAdvanceDuringEncoding": advance, "encodedOffMain": True, "uniqueTIFFsVerified": True}))
