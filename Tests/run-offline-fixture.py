#!/usr/bin/env python3
"""Run unchanged XCTest fixtures on CLT using a temporary assertion adapter."""
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
name = sys.argv[1]
assert name in {"AudioLeaseTests", "PlaybackLifecycleTests"}
build = root / ".build" / "offline-model-tests" / name
build.mkdir(parents=True, exist_ok=True)
source = (root / "Tests" / "NESNPlayerTests" / (name + ".swift")).read_text()
# Audio already supplies its own CLT adapter. UI uses this small local shim.
if name == "PlaybackLifecycleTests":
    source = source.replace("import XCTest", "").replace("@testable import NESNPlayer", "")
    source = '''
class XCTestCase {}
private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b) }
private func XCTAssertTrue(_ value: Bool) { precondition(value) }
private func XCTAssertFalse(_ value: Bool) { precondition(!value) }
private func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
''' + source
methods = re.findall(r"func (test\w+)\(\)([^\{]*)\{", source)
calls = []
for method, qualifiers in methods:
    calls.append(("try " if "throws" in qualifiers else "") + ("await " if "async" in qualifiers else "") + "tests." + method + "()")
if '@main' not in source:
    source += '\n@main struct OfflineRunner { @MainActor static func main() async throws {\n'
    source += 'let tests = ' + name + '()\n' + '\n'.join(calls)
    source += '\nprint("' + name + ': ' + str(len(methods)) + ' offline tests passed")\n}}\n'
fixture = build / "Fixture.swift"
fixture.write_text(source)
sources = sorted((root / "Sources" / "NESNPlayer").glob("*.swift"))
sources = [str(p) for p in sources if p.name != "main.swift"]
if name == "PlaybackLifecycleTests":
    # Include declarations only; the application launch block is never compiled.
    entry = (root / "Sources" / "NESNPlayer" / "main.swift").read_text()
    assert '\ndo {\n' in entry, 'Entry-point boundary changed; review offline adapter'
    declarations = build / "AppDeclarations.swift"
    declarations.write_text(entry.split('\ndo {\n', 1)[0])
    sources.append(str(declarations))
command = ["nice", "-n", "10", "xcrun", "swiftc", "-parse-as-library", "-D", "AUDIO_LEASE_STANDALONE", *sources, str(fixture), "-o", str(build / "runner")]
subprocess.run(command, check=True)
subprocess.run([str(build / "runner")], check=True)
