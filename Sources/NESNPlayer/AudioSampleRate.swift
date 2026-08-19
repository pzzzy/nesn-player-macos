import CoreAudio
import Foundation

final class AudioSampleRateLease: @unchecked Sendable {
    private struct DeviceState {
        let id: AudioDeviceID
        let originalRate: Float64
        let appliedRate: Float64
    }

    private let preferredRate: Float64
    private var device: DeviceState?
    private var isRestored = false
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let rateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(preferredRate: Float64) throws {
        self.preferredRate = preferredRate
        try refreshDefaultOutput()
        do {
            try startMonitoringDefaultOutput()
        } catch {
            restore()
            throw error
        }
    }

    deinit {
        restore()
    }

    func refreshDefaultOutput() throws {
        guard !isRestored else { return }
        let outputDevice = try Self.defaultOutputDevice()
        guard device?.id != outputDevice else { return }
        restoreCurrentDevice()
        device = try align(deviceID: outputDevice)
    }

    func restore() {
        guard !isRestored else { return }
        isRestored = true
        stopMonitoringDefaultOutput()
        restoreCurrentDevice()
    }

    private func startMonitoringDefaultOutput() throws {
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                do {
                    try self?.refreshDefaultOutput()
                } catch {
                    fputs("Could not align the new audio output: \(error)\n", stderr)
                }
            }
        }
        try Self.check(AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
        ))
        outputListener = listener
    }

    private func stopMonitoringDefaultOutput() {
        guard let outputListener else { return }
        var address = Self.defaultOutputAddress
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener
        )
        if status != noErr {
            fputs("Could not stop monitoring the audio output (Core Audio \(status))\n", stderr)
        }
        self.outputListener = nil
    }

    private func align(deviceID: AudioDeviceID) throws -> DeviceState {
        var address = rateAddress
        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        guard AudioObjectHasProperty(deviceID, &address),
              settableStatus == noErr, isSettable.boolValue else {
            throw NSError(domain: "NESNAudioClock", code: -1)
        }

        let originalRate = try Self.sampleRate(deviceID: deviceID, address: &address)
        let state = DeviceState(id: deviceID, originalRate: originalRate, appliedRate: preferredRate)
        guard !Self.ratesEqual(originalRate, preferredRate) else {
            fputs("4K audio clock already aligned at \(Int(preferredRate)) Hz\n", stderr)
            return state
        }

        do {
            try Self.setSampleRate(preferredRate, deviceID: deviceID, address: &address)
            guard try Self.waitForRate(preferredRate, deviceID: deviceID, address: &address) else {
                throw NSError(domain: "NESNAudioClock", code: -2)
            }
        } catch {
            Self.rollback(state, address: &address)
            throw error
        }
        fputs("4K audio clock aligned: \(Int(originalRate)) Hz -> \(Int(preferredRate)) Hz\n", stderr)
        return state
    }

    private func restoreCurrentDevice() {
        guard let state = device else { return }
        device = nil
        var address = rateAddress
        do {
            let currentRate = try Self.sampleRate(deviceID: state.id, address: &address)
            // Do not overwrite a newer choice made by the user or another app.
            guard Self.ratesEqual(currentRate, preferredRate),
                  !Self.ratesEqual(currentRate, state.originalRate) else { return }
            try Self.setSampleRate(state.originalRate, deviceID: state.id, address: &address)
            guard try Self.waitForRate(state.originalRate, deviceID: state.id, address: &address) else {
                throw NSError(domain: "NESNAudioClock", code: -3)
            }
        } catch {
            fputs("Could not restore audio sample rate: \(error)\n", stderr)
        }
    }

    private static func rollback(_ state: DeviceState, address: inout AudioObjectPropertyAddress) {
        do {
            let currentRate = try sampleRate(deviceID: state.id, address: &address)
            // Do not overwrite a rate chosen while our confirmation was pending.
            guard ratesEqual(currentRate, state.appliedRate),
                  !ratesEqual(currentRate, state.originalRate) else { return }
            try setSampleRate(state.originalRate, deviceID: state.id, address: &address)
            guard try waitForRate(state.originalRate, deviceID: state.id, address: &address) else {
                throw NSError(domain: "NESNAudioClock", code: -4)
            }
        } catch {
            fputs("Could not roll back audio sample rate: \(error)\n", stderr)
        }
    }

    private static func defaultOutputDevice() throws -> AudioDeviceID {
        var outputDevice = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultOutputAddress
        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &outputDevice
        ))
        guard outputDevice != kAudioObjectUnknown else {
            throw NSError(domain: "NESNAudioClock", code: -5)
        }
        return outputDevice
    }

    private static func sampleRate(
        deviceID: AudioDeviceID,
        address: inout AudioObjectPropertyAddress
    ) throws -> Float64 {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate))
        return rate
    }

    private static func setSampleRate(
        _ rate: Float64,
        deviceID: AudioDeviceID,
        address: inout AudioObjectPropertyAddress
    ) throws {
        var requestedRate = rate
        try check(AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &requestedRate
        ))
    }

    private static func waitForRate(
        _ expectedRate: Float64,
        deviceID: AudioDeviceID,
        address: inout AudioObjectPropertyAddress
    ) throws -> Bool {
        for _ in 0..<50 {
            if ratesEqual(try sampleRate(deviceID: deviceID, address: &address), expectedRate) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private static func ratesEqual(_ lhs: Float64, _ rhs: Float64) -> Bool {
        abs(lhs - rhs) < 0.5
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw NSError(domain: "NESNAudioClock", code: Int(status))
        }
    }
}
