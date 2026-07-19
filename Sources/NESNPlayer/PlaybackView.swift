import AppKit
import AVFoundation
import AVKit

@MainActor
final class ActionButton: NSButton {
    var actionHandler: (() -> Void)?

    init(title: String, symbolName: String? = nil, handler: @escaping () -> Void) {
        self.actionHandler = handler
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = .texturedRounded
        self.isBordered = false
        self.contentTintColor = .white
        self.font = .systemFont(ofSize: 14, weight: .semibold)
        if let symbolName {
            self.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
            self.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        self.target = self
        self.action = #selector(invoke)
        self.toolTip = title
        self.setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() { actionHandler?() }
}

@MainActor
final class ScrollPlayerView: AVPlayerView {
    var scrollHandler: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), event.scrollingDeltaY != 0 else { return }
        scrollHandler?(event.scrollingDeltaY)
    }
}

@MainActor
final class PlaybackView: NSView {
    let player: AVPlayer
    private let videoView = ScrollPlayerView()
    private let controls = NSVisualEffectView()
    private let volumeLabel = NSTextField(labelWithString: "100%")
    private let liveLight = NSView()
    private let liveButton = ActionButton(title: "LIVE", handler: {})
    private let playButton = ActionButton(title: "Pause", symbolName: "pause.fill", handler: {})
    private var timeObserver: Any?
    private var trackingAreaRef: NSTrackingArea?
    private var hideWorkItem: DispatchWorkItem?
    private var scrollMonitor: Any?

    init(frame: NSRect, player: AVPlayer) {
        self.player = player
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setupVideo()
        setupControls()
        monitorPlayback()
        monitorScrolling()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupVideo() {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.player = player
        videoView.controlsStyle = .none
        videoView.videoGravity = .resizeAspect
        videoView.scrollHandler = { [weak self] deltaY in self?.adjustVolume(deltaY: deltaY) }
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupControls() {
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.material = .hudWindow
        controls.blendingMode = .withinWindow
        controls.state = .active
        controls.wantsLayer = true
        controls.layer?.cornerRadius = 14
        controls.layer?.masksToBounds = true
        addSubview(controls)

        let volumeIcon = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Volume")!)
        volumeIcon.contentTintColor = .white
        volumeIcon.setContentHuggingPriority(.required, for: .horizontal)
        volumeLabel.textColor = .white
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        volumeLabel.alignment = .right
        volumeLabel.toolTip = "Scroll up or down anywhere over the video to change volume"

        let replayButton = ActionButton(title: "Replay 30 seconds", symbolName: "gobackward.30") { [weak self] in
            self?.replayThirtySeconds()
        }
        replayButton.imagePosition = .imageOnly
        replayButton.toolTip = "Replay 30 seconds"

        playButton.actionHandler = { [weak self] in self?.togglePlayback() }
        playButton.imagePosition = .imageOnly

        liveLight.translatesAutoresizingMaskIntoConstraints = false
        liveLight.wantsLayer = true
        liveLight.layer?.cornerRadius = 5
        liveButton.actionHandler = { [weak self] in self?.goLive() }
        liveButton.toolTip = "Return to the live edge"

        let liveStack = NSStackView(views: [liveLight, liveButton])
        liveStack.orientation = .horizontal
        liveStack.spacing = 5
        liveStack.alignment = .centerY

        let stack = NSStackView(views: [volumeIcon, volumeLabel, replayButton, playButton, liveStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        controls.addSubview(stack)

        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
            controls.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            stack.topAnchor.constraint(equalTo: controls.topAnchor),
            stack.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
            liveLight.widthAnchor.constraint(equalToConstant: 10),
            liveLight.heightAnchor.constraint(equalToConstant: 10),
            volumeLabel.widthAnchor.constraint(equalToConstant: 40),
        ])
        updateVolumeLabel()
        showControls()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) { showControls() }
    override func mouseEntered(with event: NSEvent) { showControls() }

    override func scrollWheel(with event: NSEvent) {
        handleScroll(event)
    }

    private func monitorScrolling() {
        // AVPlayerView contains private child views which can consume wheel
        // events before the outer view sees them. A local event monitor makes
        // vertical scrolling consistently control volume anywhere in this
        // player window, while swallowing the event so it can never scrub.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.handleScroll(event)
            return nil
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), event.scrollingDeltaY != 0 else { return }
        adjustVolume(deltaY: event.scrollingDeltaY)
    }

    private func adjustVolume(deltaY: CGFloat) {
        player.volume = adjustedVolume(current: player.volume, scrollingDeltaY: deltaY)
        updateVolumeLabel()
        showControls()
    }

    private func replayThirtySeconds() {
        guard let item = player.currentItem else { return }
        let current = player.currentTime().seconds
        let start = item.seekableTimeRanges.first?.timeRangeValue.start.seconds ?? 0
        guard current.isFinite, start.isFinite else { return }
        let target = replayTarget(current: current, seekableStart: start)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        updatePlayButton()
        showControls()
    }

    private func goLive() {
        guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return }
        let end = CMTimeRangeGetEnd(range)
        player.seek(to: end, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        updatePlayButton()
        showControls()
    }

    private func togglePlayback() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
        updatePlayButton()
        showControls()
    }

    private func monitorPlayback() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateLiveState()
                self?.updatePlayButton()
            }
        }
    }

    private func updateLiveState() {
        let current = player.currentTime().seconds
        guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else {
            liveLight.layer?.backgroundColor = NSColor.systemRed.cgColor
            liveButton.title = "LIVE"
            return
        }
        let end = CMTimeRangeGetEnd(range).seconds
        let lag = current.isFinite && end.isFinite ? liveLag(current: current, seekableEnd: end) : .infinity
        let state = LivePlaybackState(lag: lag)
        liveLight.layer?.backgroundColor = (state == .live ? NSColor.systemGreen : NSColor.systemRed).cgColor
        liveButton.title = state == .live ? "LIVE" : "GO LIVE"
    }

    private func updatePlayButton() {
        let playing = player.timeControlStatus == .playing
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: playing ? "Pause" : "Play")
        playButton.toolTip = playing ? "Pause" : "Play"
    }

    private func updateVolumeLabel() {
        volumeLabel.stringValue = "\(Int((player.volume * 100).rounded()))%"
    }

    private func showControls() {
        hideWorkItem?.cancel()
        controls.animator().alphaValue = 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.player.timeControlStatus == .playing else { return }
            self.controls.animator().alphaValue = 0
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
