#!/usr/bin/env python3
"""Run unchanged XCTest fixtures on CLT using a temporary assertion adapter."""
import pathlib
import platform
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
name = sys.argv[1]
if name not in {"AudioLeaseTests", "PlaybackLifecycleTests", "AppIntegrationTests"}:
    raise ValueError("Unsupported offline fixture: " + name)
needs_app_declarations = name in {"PlaybackLifecycleTests", "AppIntegrationTests"}
build = root / ".build" / "offline-model-tests" / name
build.mkdir(parents=True, exist_ok=True)
source = (root / "Tests" / "NESNPlayerTests" / (name + ".swift")).read_text()
# Audio supplies its own CLT adapter; UI/integration share this fail-fast shim.
if needs_app_declarations:
    source = source.replace("import XCTest", "").replace("@testable import NESNPlayer", "")
    source = '''
class XCTestCase {}
private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { precondition(a == b, "Expected \\(a) == \\(b)", file: file, line: line) }
private func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(value, "Expected true", file: file, line: line) }
private func XCTAssertFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { precondition(!value, "Expected false", file: file, line: line) }
private func XCTAssertNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) { precondition(value == nil, "Expected nil", file: file, line: line) }
''' + '#sourceLocation(file: "Tests/NESNPlayerTests/' + name + '.swift", line: 1)\n' + source
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
if needs_app_declarations:
    # Include declarations only; the application launch block is never compiled.
    entry = (root / "Sources" / "NESNPlayer" / "main.swift").read_text()
    # The unique preserved boundary is the contract, not the launch dispatch syntax.
    # Refuse missing/duplicate markers rather than risk compiling app startup.
    marker = '// XCTest imports do not execute this entry point. Explicit finite no-start mode.'
    if entry.count(marker) != 1 or ('\n' + marker + '\n') not in entry:
        raise RuntimeError('Entry-point boundary changed; review offline adapter')
    prefix, _ = entry.split('\n' + marker + '\n', 1)
    declarations = build / "AppDeclarations.swift"
    declarations.write_text(prefix + '\n')
    sources.append(str(declarations))
command = ["nice", "-n", "10", "xcrun", "swiftc", "-swift-version", "6", "-target", platform.machine() + "-apple-macosx14.0", "-parse-as-library", "-D", "AUDIO_LEASE_STANDALONE", *sources, str(fixture), "-o", str(build / "runner")]
subprocess.run(command, check=True)
subprocess.run([str(build / "runner")], check=True)
