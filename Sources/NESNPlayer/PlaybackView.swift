import AppKit
import AVFoundation
import AVKit

@MainActor final class ActionButton: NSButton {
    var actionHandler: (() -> Void)?
    init(title: String, symbolName: String? = nil, handler: @escaping () -> Void) {
        actionHandler = handler
        super.init(frame: .zero)
        bezelStyle = .texturedRounded; isBordered = false; contentTintColor = .white
        font = .systemFont(ofSize: 14, weight: .semibold)
        if let symbolName {
            setSymbol(symbolName, accessibleTitle: title)
        } else { self.title = title }
        target = self; action = #selector(invoke)
        toolTip = title; setAccessibilityLabel(title)
    }
    /// Keep the drawable cell title empty, including after transport state changes.
    /// Accessibility and tooltips carry the action name independently of drawing.
    func setSymbol(_ name: String, accessibleTitle: String) {
        title = ""; alternateTitle = ""
        image = NSImage(systemSymbolName: name, accessibilityDescription: accessibleTitle)
        imagePosition = .imageOnly
        toolTip = accessibleTitle; setAccessibilityLabel(accessibleTitle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { actionHandler?() }
}

@MainActor final class PlaybackScrubber: NSSlider {
    var beginDrag: (() -> Void)?
    var endDrag: (() -> Void)?
    private(set) var dragging = false
    override func mouseDown(with event: NSEvent) {
        dragging = true; beginDrag?()
        super.mouseDown(with: event)
        dragging = false; endDrag?()
    }
}

@MainActor final class PlaybackView: NSView, @preconcurrency AVRoutePickerViewDelegate {
    let player: AVPlayer
    let isLiveContent: Bool
    private let videoView = AVPlayerView()
    private let controls = NSVisualEffectView()
    private let volumeLabel = NSTextField(labelWithString: "100%")
    private let liveButton = ActionButton(title: "LIVE", handler: {})
    private let playButton = ActionButton(title: "Play", symbolName: "play.fill", handler: {})
    private let routePicker = AVRoutePickerView()
    private let scrubber = PlaybackScrubber(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let statusLabel = NSTextField(labelWithString: "Loading")
    private var captureStatus: String?
    private var captureStatusExpiry: ContinuousClock.Instant?
    func showCaptureStatus(_ text: String, detail: String? = nil) {
        guard !isDisposed else { return }
        captureStatus = text
        captureStatusExpiry = .now.advanced(by: .seconds(5))
        statusLabel.toolTip = detail ?? text
        updateState(); showControls()
    }
    private var timeObserver: Any?
    private var trackingAreaRef: NSTrackingArea?
    private var hideWorkItem: DispatchWorkItem?
    private var eventMonitor: Any?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var intent = PlaybackIntent()
    private var scrub = ScrubSession()
    private var routePickerActive = false
    private(set) var isDisposed = false
    var onFailure: ((Error) -> Void)?
    /// Explicit source-scoped capture integration; never a desktop screenshot.
    var onCaptureFrame: (() -> Void)?
    var onChooseSource: (() -> Void)?
    var activeObserverCount: Int { observations.count + notifications.count + (timeObserver == nil ? 0 : 1) + (eventMonitor == nil ? 0 : 1) }

    init(frame: NSRect, player: AVPlayer, isLiveContent: Bool) {
        self.player = player; self.isLiveContent = isLiveContent
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        setupControls(); monitorPlayback(); monitorEvents()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Call before releasing or replacing the view. Idempotent and main-thread scoped.
    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        hideWorkItem?.cancel(); hideWorkItem = nil; scrub.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }; timeObserver = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }; eventMonitor = nil
        observations.forEach { $0.invalidate() }; observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications.removeAll()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }; trackingAreaRef = nil
        videoView.player = nil; routePicker.player = nil; routePicker.delegate = nil
        onFailure = nil; onCaptureFrame = nil; onChooseSource = nil
    }
    func play() { guard !isDisposed else { return }; intent.play(); player.play(); updateState() }

    private func setupControls() {
        videoView.player = player; videoView.controlsStyle = .none; videoView.videoGravity = .resizeAspect
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.material = .hudWindow; controls.blendingMode = .withinWindow; controls.state = .active
        controls.wantsLayer = true; controls.layer?.cornerRadius = 12
        addSubview(controls)
        let replay = ActionButton(title: "Replay 30 seconds", symbolName: "gobackward.30") { [weak self] in self?.replayThirtySeconds() }
        let mute = ActionButton(title: "Mute or unmute", symbolName: "speaker.wave.2.fill") { [weak self] in
            guard let self else { return }; self.player.isMuted.toggle(); self.updateVolumeLabel(); self.showControls()
        }
        playButton.actionHandler = { [weak self] in self?.togglePlayback() }
        liveButton.actionHandler = { [weak self] in self?.goLive() }
        routePicker.player = player; routePicker.delegate = self
        routePicker.setRoutePickerButtonColor(.white, for: .normal)
        routePicker.setRoutePickerButtonColor(.systemBlue, for: .active)
        routePicker.toolTip = "AirPlay to Apple TV"; routePicker.setAccessibilityLabel("AirPlay to Apple TV")
        let transport = NSStackView(views: isLiveContent ? [mute, volumeLabel, replay, playButton, routePicker, liveButton] : [mute, volumeLabel, replay, playButton, routePicker])
        transport.orientation = .horizontal; transport.alignment = .centerY; transport.spacing = 4
        for label in [volumeLabel, timeLabel, statusLabel] {
            label.textColor = .white; label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }
        let capture = ActionButton(title: "Capture frame", symbolName: "camera") { [weak self] in
            guard let self, !self.isDisposed else { return }; self.onCaptureFrame?()
        }
        let browse = ActionButton(title: "Browse sources", symbolName: "list.bullet") { [weak self] in
            guard let self, !self.isDisposed else { return }; self.onChooseSource?()
        }
        let utilities = NSStackView(views: [browse, statusLabel, capture])
        utilities.orientation = .horizontal; utilities.alignment = .centerY; utilities.spacing = 8
        var rows: [NSView] = [transport, utilities]
        if !isLiveContent {
            scrubber.isContinuous = true; scrubber.target = self; scrubber.action = #selector(scrubChanged(_:))
            scrubber.setAccessibilityLabel("Replay position"); scrubber.toolTip = "Seek within this replay"
            scrubber.beginDrag = { [weak self] in self?.beginScrubbing() }
            scrubber.endDrag = { [weak self] in self?.finishScrubbing() }
            rows.insert(timeLabel, at: 0); rows.insert(scrubber, at: 0)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(stack)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor), videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor), videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.centerXAnchor.constraint(equalTo: centerXAnchor), controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            controls.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 10), stack.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: controls.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -8),
            routePicker.widthAnchor.constraint(equalToConstant: 28), routePicker.heightAnchor.constraint(equalToConstant: 28),
            volumeLabel.widthAnchor.constraint(equalToConstant: 38)
        ])
        if !isLiveContent {
            scrubber.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        }
        updateVolumeLabel(); showControls()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        guard !isDisposed else { return }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); trackingAreaRef = area
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true }
    override func mouseMoved(with event: NSEvent) { showControls() }
    override func mouseEntered(with event: NSEvent) { showControls() }
    override func mouseExited(with event: NSEvent) { showControls() }

    private func monitorEvents() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            guard let self, !self.isDisposed, let window = self.window,
                  event.window === window, window.isKeyWindow, window.attachedSheet == nil, !self.routePickerActive else { return event }
            if event.type == .scrollWheel {
                if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), event.scrollingDeltaY != 0 { self.adjustVolume(deltaY: event.scrollingDeltaY) }
                return nil // Live scroll must never seek through AVPlayerView's private subviews.
            }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(window.firstResponder is NSTextView), !(window.firstResponder is NSControl) else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": self.togglePlayback()
            case "m": self.player.isMuted.toggle(); self.updateVolumeLabel()
            case "r": self.replayThirtySeconds()
            case "l" where self.isLiveContent: self.goLive()
            case "s" where self.onCaptureFrame != nil: self.onCaptureFrame?()
            default:
                if event.keyCode == 126 { self.adjustVolume(deltaY: 1) }
                else if event.keyCode == 125 { self.adjustVolume(deltaY: -1) }
                else { return event }
            }
            self.showControls(); return nil
        }
    }
    private func adjustVolume(deltaY: CGFloat) {
        player.volume = adjustedVolume(current: player.volume, scrollingDeltaY: deltaY)
        updateVolumeLabel(); showControls()
    }
    private func replayThirtySeconds() {
        guard let item = player.currentItem else { return }
        let current = player.currentTime().seconds
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue)
        // Stay in the current DVR segment rather than seeking across an expired gap.
        let range = ranges.first { CMTimeRangeContainsTime($0, time: player.currentTime()) }
        let start = range?.start.seconds ?? (isLiveContent ? current : 0)
        guard current.isFinite, start.isFinite else { return }
        player.seek(to: CMTime(seconds: replayTarget(current: current, seekableStart: start), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        play(); showControls()
    }
    private func goLive() {
        guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return }
        let end = CMTimeRangeGetEnd(range)
        guard end.seconds.isFinite else { return }
        player.seek(to: end, toleranceBefore: .zero, toleranceAfter: .zero)
        play(); showControls()
    }
    private func togglePlayback() {
        guard !isDisposed, player.currentItem?.status != .failed else { return }
        if intent.phase(status: player.timeControlStatus) == .ended {
            player.seek(to: .zero)
        }
        intent.toggle()
        if intent.wantsPlayback { player.play() } else { player.pause() }
        updateState(); showControls()
    }
    private func monitorPlayback() {
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateState() }
        })
        if let item = player.currentItem {
            observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, !self.isDisposed else { return }
                    if item.status == .failed { self.fail(item.error) }; self.updateState()
                }
            })
            for name in [Notification.Name.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime, .AVPlayerItemPlaybackStalled] {
                notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] note in
                    let name = note.name
                    let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    MainActor.assumeIsolated {
                        guard let self, !self.isDisposed else { return }
                        if name == .AVPlayerItemDidPlayToEndTime { self.intent.end() }
                        if name == .AVPlayerItemFailedToPlayToEndTime { self.fail(error) }
                        self.updateState(); self.showControls()
                    }
                })
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateState(); self?.updateScrubber() }
        }
    }
    private func fail(_ error: Error?) {
        guard intent.phase(status: player.timeControlStatus) != .failed else { return }
        intent.fail(); player.pause(); scrub.cancel(); updateState(); showControls()
        onFailure?(error ?? NSError(domain: "AVFoundationErrorDomain", code: -1))
    }
    private func updateState() {
        guard !isDisposed else { return }
        let label = intent.actionLabel
        if playButton.accessibilityLabel() != label {
            playButton.setSymbol(intent.wantsPlayback ? "pause.fill" : "play.fill", accessibleTitle: label)
        }
        let phase = intent.phase(status: player.timeControlStatus)
        playButton.isEnabled = phase != .failed
        if let expiry = captureStatusExpiry, ContinuousClock.now >= expiry {
            captureStatus = nil; captureStatusExpiry = nil; statusLabel.toolTip = nil
        }
        // A capture result must never hide a playback failure.
        statusLabel.stringValue = phase == .failed ? phase.rawValue : (captureStatus ?? phase.rawValue)
        if isLiveContent {
            var label = "WAITING"
            if let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue {
                let current = player.currentTime().seconds, end = CMTimeRangeGetEnd(range).seconds
                if current.isFinite, end.isFinite { label = LivePlaybackState(lag: liveLag(current: current, seekableEnd: end)) == .live ? "LIVE" : "GO LIVE" }
            }
            liveButton.title = label; liveButton.setAccessibilityLabel(label)
            liveButton.contentTintColor = label == "LIVE" ? .systemGreen : (label == "GO LIVE" ? .systemRed : .white)
            liveButton.toolTip = label == "LIVE" ? "At the live edge" : "Return to the live edge"
        }
    }
    private func updateVolumeLabel() { volumeLabel.stringValue = player.isMuted ? "Muted" : "\(Int((player.volume * 100).rounded()))%" }
    private func beginScrubbing() {
        guard !isDisposed, !scrub.isActive else { return }
        scrub.begin(wasPlaying: intent.wantsPlayback); player.pause(); showControls()
    }
    @objc private func scrubChanged(_ sender: NSSlider) {
        let duration = player.currentItem?.duration.seconds ?? 0
        guard !isLiveContent, duration.isFinite, duration > 0 else { return }
        beginScrubbing()
        let target = scrubTarget(fraction: sender.doubleValue, duration: duration)
        scrub.update(target: target)
        timeLabel.stringValue = "\(formatTime(target)) / \(formatTime(duration))"
        if !scrubber.dragging { finishScrubbing() }
        showControls()
    }
    private func finishScrubbing() {
        guard !isDisposed else { return }
        let resume = scrub.resumePlayback
        let target = scrub.finish()
        if let target {
            player.currentItem?.cancelPendingSeeks()
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if resume && intent.wantsPlayback { player.play() }
        showControls()
    }
    private func updateScrubber() {
        guard !isLiveContent, !scrub.isActive, !isDisposed else { return }
        let duration = player.currentItem?.duration.seconds ?? 0, current = player.currentTime().seconds
        scrubber.isEnabled = duration.isFinite && duration > 0
        scrubber.doubleValue = scrubFraction(current: current, duration: duration)
        timeLabel.stringValue = "\(formatTime(current)) / \(formatTime(duration))"
    }
    private func formatTime(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return "–:––" }
        let total = Int(value.rounded(.down)), hours = Int(value / 3600)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
    private func showControls() {
        guard !isDisposed else { return }
        hideWorkItem?.cancel(); controls.alphaValue = 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDisposed else { return }
            let point = self.convert(self.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            let focused = (self.window?.firstResponder as? NSView).map { $0.isDescendant(of: self.controls) } ?? false
            guard shouldHidePlaybackControls(playing: self.player.timeControlStatus == .playing, scrubbing: self.scrub.isActive,
                pointerInControls: self.controls.frame.contains(point), focusedControl: focused, routePickerActive: self.routePickerActive) else { self.showControls(); return }
            self.controls.animator().alphaValue = 0
        }
        hideWorkItem = work; DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { routePickerActive = true; showControls() }
    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) { routePickerActive = false; showControls() }
}
