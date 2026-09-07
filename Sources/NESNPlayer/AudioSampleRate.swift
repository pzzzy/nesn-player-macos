import CoreAudio
import Foundation

/// All adapter calls occur on the lease's private serial queue, never on the UI thread.
protocol AudioRateDeviceAdapter: Sendable {
    func defaultOutput() throws -> UInt32
    func rate(_ device: UInt32) throws -> Double
    func supports(_ rate: Double, device: UInt32) throws -> Bool
    func setRate(_ rate: Double, device: UInt32) throws
    func startMonitoring(_ changed: @escaping @Sendable () -> Void) throws
    func stopMonitoring()
}

/// Explicit lifetime: callers must await restoreAndWait before orderly termination.
/// No deinit restoration: escaping work from deinit cannot provide a shutdown guarantee.
final class AudioSampleRateLease: Sendable {
    private let worker: Worker

    /// Source-compatible, nonblocking bridge. Errors are logged asynchronously.
    /// Prefer init(inactivePreferredRate:) + refreshAndWait() when errors matter.
    convenience init(preferredRate: Double) throws {
        self.init(inactivePreferredRate: preferredRate)
        try refreshDefaultOutput()
    }

    convenience init(inactivePreferredRate: Double) {
        self.init(preferredRate: inactivePreferredRate, adapter: CoreAudioRateAdapter())
    }

    init(preferredRate: Double, adapter: any AudioRateDeviceAdapter,
         confirmationAttempts: Int = 50, pollNanoseconds: UInt64 = 20_000_000) {
        worker = Worker(rate: preferredRate, adapter: adapter,
                        attempts: max(1, confirmationAttempts), delay: pollNanoseconds)
    }

    func refreshDefaultOutput() throws {
        worker.submitRefresh(token: CancellationFlag(), completion: Self.logFailure)
    }
    func restore() { worker.submitRestore(completion: Self.logFailure) }

    func refreshAndWait() async throws {
        let token = CancellationFlag()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                worker.submitRefresh(token: token) { continuation.resume(with: $0) }
            }
        } onCancel: { token.cancel() }
    }

    /// Cleanup is deliberately not cancelled with the caller: a pending acquisition
    /// must finish its bounded rollback before this continuation is resumed.
    func restoreAndWait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.submitRestore { continuation.resume(with: $0) }
        }
    }

    private static func logFailure(_ result: Result<Void, Error>) {
        if case let .failure(error) = result { NSLog("Audio clock lease: %@", String(describing: error)) }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.withLock { value = true } }
    var cancelled: Bool { lock.withLock { value } }
}

private enum LeaseError: Error { case closed, unsupported, confirmationTimeout }

/// Queue confinement includes ownership, listener lifetime, generations and jobs.
/// Polling uses asyncAfter; there is no sleeping thread or reentrant actor transaction.
private final class Worker: @unchecked Sendable {
    typealias Completion = @Sendable (Result<Void, Error>) -> Void
    private struct Ownership {
        let device: UInt32
        let original: Double
        var acquisitionConfirmed = false
    }
    private let queue = DispatchQueue(label: "NESNPlayer.audio-rate-lease", qos: .utility)
    private let adapter: any AudioRateDeviceAdapter
    private let preferred: Double
    private let attempts: Int
    private let delay: UInt64
    private var ownership: Ownership?
    private var generation: UInt64 = 0
    private var closed = false
    private var monitoring = false
    private var jobs: [@Sendable () -> Void] = []
    private var busy = false

    init(rate: Double, adapter: any AudioRateDeviceAdapter, attempts: Int, delay: UInt64) {
        preferred = rate; self.adapter = adapter; self.attempts = attempts; self.delay = delay
    }
    func submitRefresh(token: CancellationFlag, completion: @escaping Completion) {
        queue.async {
            guard !self.closed else { completion(.failure(LeaseError.closed)); return }
            self.generation &+= 1
            let generation = self.generation
            self.jobs.append {
                self.refresh(generation: generation, token: token) { result in
                    completion(result); self.finished()
                }
            }
            self.drain()
        }
    }
    func submitRestore(completion: @escaping Completion) {
        queue.async {
            self.closed = true
            self.generation &+= 1
            if self.monitoring { self.adapter.stopMonitoring(); self.monitoring = false }
            self.jobs.append {
                self.release { result in completion(result); self.finished() }
            }
            self.drain()
        }
    }
    private func drain() {
        guard !busy, !jobs.isEmpty else { return }
        busy = true
        jobs.removeFirst()()
    }
    private func finished() { busy = false; drain() }
    private func valid(_ generation: UInt64, _ token: CancellationFlag) -> Bool {
        !closed && self.generation == generation && !token.cancelled
    }
    private func refresh(generation: UInt64, token: CancellationFlag, completion: @escaping Completion) {
        guard valid(generation, token) else { completion(.failure(CancellationError())); return }
        do {
            if !monitoring {
                try adapter.startMonitoring { [weak self] in
                    self?.submitRefresh(token: CancellationFlag()) { result in
                        if case let .failure(error) = result { NSLog("Audio route alignment: %@", String(describing: error)) }
                    }
                }
                monitoring = true
            }
            let device = try adapter.defaultOutput()
            if ownership?.device == device { completion(.success(())); return }
            release { result in
                // A connected device whose restoration failed retains ownership;
                // do not apply another lease until that restoration can be retried.
                if case .failure = result, self.ownership != nil { completion(result); return }
                guard self.valid(generation, token) else { completion(.failure(CancellationError())); return }
                self.align(device, generation: generation, token: token, completion: completion)
            }
        } catch { completion(.failure(error)) }
    }
    private func align(_ device: UInt32, generation: UInt64, token: CancellationFlag, completion: @escaping Completion) {
        do {
            let original = try adapter.rate(device)
            guard !equal(original, preferred) else { completion(.success(())); return }
            guard preferred.isFinite, preferred > 0,
                  try adapter.supports(preferred, device: device) else { throw LeaseError.unsupported }
            guard valid(generation, token) else { throw CancellationError() }
            ownership = Ownership(device: device, original: original)
            try adapter.setRate(preferred, device: device)
            confirm(preferred, device: device, remaining: attempts,
                    cancelled: { !self.valid(generation, token) }) { result in
                switch result {
                case .success:
                    self.ownership?.acquisitionConfirmed = true
                    completion(result)
                case .failure: self.release { _ in completion(result) }
                }
            }
        } catch {
            // Some drivers apply a write then return an error: retain ownership
            // before issuing it so rollback still observes the user-rate guard.
            release { _ in completion(.failure(error)) }
        }
    }
    private func release(completion: @escaping Completion) {
        release(remaining: attempts, completion: completion)
    }
    private func release(remaining: Int, completion: @escaping Completion) {
        guard let state = ownership else { completion(.success(())); return }
        let current: Double
        do { current = try adapter.rate(state.device) }
        catch {
            // Disconnected/unreadable device cannot safely be written. Drop the
            // numeric ID, which CoreAudio may later recycle for another device.
            ownership = nil; completion(.failure(error)); return
        }
        if equal(current, state.original), !state.acquisitionConfirmed, remaining > 1 {
            // An accepted (or throwing) setter may still be pending after a
            // timeout/cancellation. Seeing the original once is not rollback.
            // Keep this transaction serialized for one full confirmation window.
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(min(delay, UInt64(Int.max))))) {
                self.release(remaining: remaining - 1, completion: completion)
            }
            return
        }
        guard equal(current, preferred), !equal(current, state.original) else {
            // A third rate is a user/device change, never ours to overwrite.
            // A stable original is only bounded evidence of quiescence: CoreAudio
            // supplies no fence/cancel API for a write delayed beyond this window.
            ownership = nil; completion(.success(())); return
        }
        do {
            try adapter.setRate(state.original, device: state.device)
            confirm(state.original, device: state.device, remaining: attempts, cancelled: { false }) { result in
                if case .success = result { self.ownership = nil }
                completion(result)
            }
        } catch { completion(.failure(error)) }
    }
    private func confirm(_ expected: Double, device: UInt32, remaining: Int,
                         cancelled: @escaping @Sendable () -> Bool, completion: @escaping Completion) {
        guard !cancelled() else { completion(.failure(CancellationError())); return }
        do {
            if equal(try adapter.rate(device), expected) { completion(.success(())); return }
            guard remaining > 1 else { throw LeaseError.confirmationTimeout }
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(min(delay, UInt64(Int.max))))) {
                self.confirm(expected, device: device, remaining: remaining - 1,
                             cancelled: cancelled, completion: completion)
            }
        } catch { completion(.failure(error)) }
    }
    private func equal(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.5 }
}

/// Constructing this adapter performs no hardware access. Only worker jobs call it.
private final class CoreAudioRateAdapter: AudioRateDeviceAdapter, @unchecked Sendable {
    private let listenerQueue = DispatchQueue(label: "NESNPlayer.audio-route-notifications")
    private var listener: AudioObjectPropertyListenerBlock?
    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    private func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: "NESNAudioClock", code: Int(status)) }
    }
    func defaultOutput() throws -> UInt32 {
        var value = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: value))
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &value))
        guard value != kAudioObjectUnknown else { throw NSError(domain: "NESNAudioClock", code: -5) }
        return value
    }
    func rate(_ device: UInt32) throws -> Double {
        var value: Double = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        var property = address(kAudioDevicePropertyNominalSampleRate)
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value))
        return value
    }
    func supports(_ rate: Double, device: UInt32) throws -> Bool {
        var property = address(kAudioDevicePropertyNominalSampleRate)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &property) else { return false }
        try check(AudioObjectIsPropertySettable(device, &property, &settable))
        guard settable.boolValue else { return false }
        property = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size))
        let stride = MemoryLayout<AudioValueRange>.stride
        guard size > 0, Int(size) % stride == 0 else { return false }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / stride)
        try ranges.withUnsafeMutableBytes { buffer in
            try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, buffer.baseAddress!))
        }
        return ranges.contains { rate >= $0.mMinimum && rate <= $0.mMaximum }
    }
    func setRate(_ rate: Double, device: UInt32) throws {
        var value = rate
        var property = address(kAudioDevicePropertyNominalSampleRate)
        try check(AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value))
    }
    func startMonitoring(_ changed: @escaping @Sendable () -> Void) throws {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        try check(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, listenerQueue, block))
        listener = block
    }
    func stopMonitoring() {
        guard let listener else { return }
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, listenerQueue, listener)
        if status != noErr { NSLog("Audio route listener removal failed: %d", status) }
        self.listener = nil
    }
}
