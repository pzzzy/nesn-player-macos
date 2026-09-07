import Foundation
#if canImport(XCTest) && !AUDIO_LEASE_STANDALONE
import XCTest
typealias AudioLeaseTestBase = XCTestCase
#else
private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
    precondition(actual == expected, "Expected \(expected), got \(actual)")
}
private func XCTFail(_ message: String) { fatalError(message) }
class AudioLeaseTestBase {}
#endif
#if !AUDIO_LEASE_STANDALONE
@testable import NESNPlayer
#endif

private final class FakeAudioDevice: AudioRateDeviceAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var rates: [UInt32: Double] = [1: 44100, 2: 96000]
    private var output: UInt32 = 1
    private var writes: [String] = []
    var unsupported = false
    var ignoreWrites = false
    var failAfterWrite = false
    var failMonitoring = false
    var hideAppliedReads = 0
    // A successful setter can return before hardware applies the requested rate.
    var delayedWriteReads = 0
    private var pendingWrite: (device: UInt32, rate: Double, reads: Int)?
    private var reads = 0
    func defaultOutput() throws -> UInt32 { lock.withLock { output } }
    func rate(_ device: UInt32) throws -> Double {
        try lock.withLock {
            reads += 1
            if var pending = pendingWrite, pending.device == device {
                if pending.reads == 0 {
                    rates[device] = pending.rate
                    pendingWrite = nil
                } else {
                    pending.reads -= 1
                    pendingWrite = pending
                }
            }
            guard let value = rates[device] else { throw TestError.disconnected }
            if value == 48000, hideAppliedReads > 0 {
                hideAppliedReads -= 1
                return 44100
            }
            return value
        }
    }
    func supports(_ rate: Double, device: UInt32) throws -> Bool { !unsupported }
    func setRate(_ rate: Double, device: UInt32) throws {
        try lock.withLock {
            guard rates[device] != nil else { throw TestError.disconnected }
            writes.append("\(device):\(Int(rate))")
            if !ignoreWrites {
                if rate == 48000, delayedWriteReads > 0 {
                    pendingWrite = (device, rate, delayedWriteReads)
                } else { rates[device] = rate }
            }
            if failAfterWrite { failAfterWrite = false; throw TestError.write }
        }
    }
    func startMonitoring(_ changed: @escaping @Sendable () -> Void) throws {
        if failMonitoring { throw TestError.write }
    }
    func stopMonitoring() {}
    func change(_ device: UInt32, rate: Double?) { lock.withLock { rates[device] = rate } }
    func route(_ device: UInt32) { lock.withLock { output = device } }
    func history() -> [String] { lock.withLock { writes } }
    func readCount() -> Int { lock.withLock { reads } }
    func actualRate() -> Double? { lock.withLock { rates[1] } }
    func confirmationStarted() -> Bool { lock.withLock { !writes.isEmpty && hideAppliedReads == 0 } }
    enum TestError: Error { case disconnected, write }
}

// CLT-only runner: swiftc -swift-version 6 -D AUDIO_LEASE_STANDALONE
// Sources/NESNPlayer/AudioSampleRate.swift Tests/NESNPlayerTests/AudioLeaseTests.swift -o /tmp/audio-lease-tests
#if AUDIO_LEASE_STANDALONE
@main
private struct AudioLeaseStandaloneRunner {
    static func main() async throws {
        let tests = AudioLeaseTests()
        try await tests.testRestoresOriginalBeforeSwitchAndOnRelease()
        try await tests.testUserRateIsNotOverwritten()
        try await tests.testAlignedRateNeverOwnedEvenWhenNotSettable()
        await tests.testUnsupportedRateDoesNotWrite()
        await tests.testFailedWriteRollsBackWhenItActuallyApplied()
        await tests.testConfirmationIsBounded()
        try await tests.testDisconnectedDeviceDoesNotBlockNewRoute()
        await tests.testCancelledRequestCannotWrite()
        await tests.testMonitoringFailureNeverWrites()
        try await tests.testCancellationDuringConfirmationRollsBack()
        try await tests.testRestoreInvalidatesPendingGeneration()
        try await tests.testClosedLeaseRejectsLateRefresh()
        try await tests.testTimedOutDelayedWriteIsRolledBack()
        try await tests.testCancelledDelayedWriteIsRolledBack()
        try await tests.testShutdownWaitsForDelayedWriteRollback()
        try await tests.testDelayedWriteDoesNotOverwriteObservedUserRate()
        try await tests.testFailedDelayedWriteIsRolledBack()
        print("PASS: 17 fake-only audio lease tests")
    }
}
#endif

final class AudioLeaseTests: AudioLeaseTestBase, @unchecked Sendable {
    private func lease(_ fake: FakeAudioDevice) -> AudioSampleRateLease {
        AudioSampleRateLease(preferredRate: 48000, adapter: fake, confirmationAttempts: 3, pollNanoseconds: 1_000_000)
    }
    func testRestoresOriginalBeforeSwitchAndOnRelease() async throws {
        let fake = FakeAudioDevice(); let lease = lease(fake)
        try await lease.refreshAndWait()
        fake.route(2)
        try await lease.refreshAndWait()
        try await lease.restoreAndWait()
        XCTAssertEqual(fake.history(), ["1:48000", "1:44100", "2:48000", "2:96000"])
    }
    func testUserRateIsNotOverwritten() async throws {
        let fake = FakeAudioDevice(); let lease = lease(fake)
        try await lease.refreshAndWait()
        fake.change(1, rate: 88200)
        try await lease.restoreAndWait()
        XCTAssertEqual(fake.history(), ["1:48000"])
    }
    func testAlignedRateNeverOwnedEvenWhenNotSettable() async throws {
        let fake = FakeAudioDevice(); fake.change(1, rate: 48000); fake.unsupported = true
        let lease = lease(fake)
        try await lease.refreshAndWait()
        try await lease.restoreAndWait()
        XCTAssertEqual(fake.history(), [])
    }
    func testUnsupportedRateDoesNotWrite() async {
        let fake = FakeAudioDevice(); fake.unsupported = true; let lease = lease(fake)
        do { try await lease.refreshAndWait(); XCTFail("must reject unsupported rate") } catch {}
        XCTAssertEqual(fake.history(), [])
    }
    func testFailedWriteRollsBackWhenItActuallyApplied() async {
        let fake = FakeAudioDevice(); fake.failAfterWrite = true; let lease = lease(fake)
        do { try await lease.refreshAndWait(); XCTFail("must report failed write") } catch {}
        XCTAssertEqual(fake.history(), ["1:48000", "1:44100"])
    }
    func testConfirmationIsBounded() async {
        let fake = FakeAudioDevice(); fake.ignoreWrites = true; let lease = lease(fake)
        do { try await lease.refreshAndWait(); XCTFail("must time out") } catch {}
        XCTAssertEqual(fake.history(), ["1:48000"])
        // Initial read + three acquisition polls + three rollback polls.
        XCTAssertEqual(fake.readCount(), 7)
    }
    func testDisconnectedDeviceDoesNotBlockNewRoute() async throws {
        let fake = FakeAudioDevice(); let lease = lease(fake)
        try await lease.refreshAndWait()
        fake.change(1, rate: nil); fake.route(2)
        try await lease.refreshAndWait()
        try await lease.restoreAndWait()
        XCTAssertEqual(fake.history(), ["1:48000", "2:48000", "2:96000"])
    }
    func testCancelledRequestCannotWrite() async {
        let fake = FakeAudioDevice(); let lease = lease(fake)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; try await lease.refreshAndWait() }
        do { try await task.value; XCTFail("must cancel") } catch {}
        XCTAssertEqual(fake.history(), [])
    }
    func testMonitoringFailureNeverWrites() async {
        let fake = FakeAudioDevice(); fake.failMonitoring = true; let lease = lease(fake)
        do { try await lease.refreshAndWait(); XCTFail("listener failure") } catch {}
        XCTAssertEqual(fake.history(), [])
    }
    func testCancellationDuringConfirmationRollsBack() async throws {
        let fake = FakeAudioDevice(); fake.hideAppliedReads = 1
        let lease = AudioSampleRateLease(preferredRate: 48000, adapter: fake, confirmationAttempts: 3, pollNanoseconds: 100_000_000)
        let pending = Task { try await lease.refreshAndWait() }
        try await waitUntil { fake.confirmationStarted() }
        pending.cancel()
        do { try await pending.value; XCTFail("cancelled confirmation") } catch {}
        XCTAssertEqual(fake.history(), ["1:48000", "1:44100"])
        try await lease.restoreAndWait()
    }
    func testRestoreInvalidatesPendingGeneration() async throws {
        let fake = FakeAudioDevice(); fake.hideAppliedReads = 1
        let lease = AudioSampleRateLease(preferredRate: 48000, adapter: fake, confirmationAttempts: 3, pollNanoseconds: 100_000_000)
        let pending = Task { try await lease.refreshAndWait() }
        try await waitUntil { fake.confirmationStarted() }
        try await lease.restoreAndWait()
        do { try await pending.value; XCTFail("superseded confirmation") } catch {}
        XCTAssertEqual(fake.history(), ["1:48000", "1:44100"])
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("fake synchronization deadline exceeded")
                throw FakeAudioDevice.TestError.write
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func testTimedOutDelayedWriteIsRolledBack() async throws {
        let fake = FakeAudioDevice(); fake.delayedWriteReads = 4
        let lease = lease(fake)
        do { try await lease.refreshAndWait(); XCTFail("must time out") } catch {}
        XCTAssertEqual(fake.history(), ["1:48000", "1:44100"])
        XCTAssertEqual(fake.actualRate(), 44100)
        try await lease.restoreAndWait()
    }
    func testCancelledDelayedWriteIsRolledBack() async throws {
        let fake = FakeAudioDevice(); fake.delayedWriteReads = 2
        let lease = AudioSampleRateLease(preferredRate: 48000, adapter: fake,
                                        confirmationAttempts: 3, pollNanoseconds: 20_000_000)
        let pending = Task { try await lease.refreshAndWait() }
        try await waitUntil { fake.readCount() >= 2 }
        pending.cancel()
        do { try await pending.value; XCTFail("must cancel") } catch {}
        XCTAssertEqual(fake.history(), ["1:48000", "1:44100"])
        XCTAssertEqual(fake.actualRate(), 44100)
        try await lease.restoreAndWait()
    }
    func testShutdownWaitsForDelayedWriteRollback() async throws {
        let fake = FakeAudioDevice(); fake.delayedWriteReads = 2
        let lease = AudioSampleRateLease(preferredRate: 48000, adapter: fake,
                                        confirmationAttempts: 3, pollNanoseconds: 20_000_000)
        let pending = Task { try await lease.refreshAndWait() }
        try await waitUntil { fake.readCount() >= 2 }
        try await lease.restoreAndWait()
        do { try await pending.value; XCTFail("must be invalidated") } catch {}
        XCTAssertEqual(fake.history(), ["1:48000", "1:44100"])
        XCTAssertEqual(fake.actualRate(), 44100)
    }
    func testDelayedWriteDoesNotOverwriteObservedUserRate() async throws {
        let fake = FakeAudioDevice(); fake.delayedWriteReads = 20
        let lease = AudioSampleRateLease(preferredRate: 48000, adapter: fake,
                                        confirmationAttempts: 3, pollNanoseconds: 20_000_000)
        let pending = Task { try await lease.refreshAndWait() }
        try await waitUntil { fake.readCount() >= 2 }
        fake.change(1, rate: 88200)
        pending.cancel()
        do { try await pending.value; XCTFail("must cancel") } catch {}
        try await lease.restoreAndWait()
        XCTAssertEqual(fake.history(), ["1:48000"])
        XCTAssertEqual(fake.actualRate(), 88200)
    }
    func testFailedDelayedWriteIsRolledBack() async throws {
        let fake = FakeAudioDevice(); fake.delayedWriteReads = 1; fake.failAfterWrite = true
        let lease = lease(fake)
        do { try await lease.refreshAndWait(); XCTFail("must report setter error") } catch {}
        XCTAssertEqual(fake.history(), ["1:48000", "1:44100"])
        XCTAssertEqual(fake.actualRate(), 44100)
        try await lease.restoreAndWait()
    }
    func testClosedLeaseRejectsLateRefresh() async throws {
        let fake = FakeAudioDevice(); let lease = lease(fake)
        try await lease.restoreAndWait()
        do { try await lease.refreshAndWait(); XCTFail("closed") } catch {}
        XCTAssertEqual(fake.history(), [])
    }
}
