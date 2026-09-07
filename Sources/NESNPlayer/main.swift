import AppKit
import AVKit
import AVFoundation
import ObjectiveC

enum PlayerLaunchMode { case normal, smoke, noStart }
func playerLaunchMode(arguments: [String]) -> PlayerLaunchMode {
    if arguments.contains("--smoke-test") { return .smoke }
    return arguments.contains("--no-start") ? .noStart : .normal
}

func playbackIsUltraHD(_ choice: WatchChoice) -> Bool {
    let feed = choice.streamTitle ?? (choice.kind == .linearChannel ? choice.title : "")
    return feed.localizedCaseInsensitiveContains("4K") || feed.localizedCaseInsensitiveContains("UHD")
}

/// Serial transitions retain the lease through restoration, including shutdown.
@MainActor final class PlaybackAudioCoordinator {
    private let acquire: () async throws -> Void
    private let release: () async throws -> Void
    private var tail: Task<Void, Never>?
    private var generation = 0
    private var stopped = false
    private(set) var restorationSucceeded = false
    init(acquire: @escaping () async throws -> Void, release: @escaping () async throws -> Void) {
        self.acquire = acquire; self.release = release
    }
    func setLocalPlayback(_ local: Bool) {
        guard !stopped else { return }
        generation += 1
        let current = generation
        let previous = tail
        tail = Task {
            await previous?.value
            guard current == generation else { return }
            do {
                if local { try await acquire() } else { try await release() }
            } catch { fputs("Audio clock transition: \(safeErrorDescription(error))\n", stderr) }
        }
    }
    func wait() async { await tail?.value }
    func shutdown() async {
        if stopped {
            await tail?.value
            if restorationSucceeded { return }
        }
        stopped = true; generation += 1
        let previous = tail
        tail = Task {
            await previous?.value
            do { try await release(); restorationSucceeded = true }
            catch { fputs("Audio clock restoration: \(safeErrorDescription(error))\n", stderr) }
        }
        await tail?.value
    }
}

final class LaunchDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
}

struct Config: Decodable { let contentID, title, url, certificateUrl, licenseUrl, licenseToken: String }

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, AVAssetResourceLoaderDelegate {
    var window: NSWindow!
    var player: AVPlayer!
    var config: Config
    let channelID: String?
    let launchWindow: NSWindow?
    let isLiveContent: Bool
    let isUltraHD: Bool
    private var audioCoordinator: PlaybackAudioCoordinator?
    private var cleanupTask: Task<Void, Never>?
    private var terminationPending = false
    var onRecovery: ((Bool) -> Void)?
    var onPlaybackStarted: (() -> Void)?
    var externalPlaybackObservation: NSKeyValueObservation?
    let session = APISession.make()
    private var startupTask: Task<Void, Never>?
    private var inspectionTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var keyTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var accessLogObserver: NSObjectProtocol?
    private(set) var isStopped = false
    private var presentingError = false
    var pendingTaskCount: Int { keyTasks.count + (startupTask == nil ? 0 : 1) + (inspectionTask == nil ? 0 : 1) }
    init(config: Config, channelID: String? = nil, launchWindow: NSWindow? = nil, isLiveContent: Bool = true, isUltraHD: Bool = false) {
        self.config = config
        self.channelID = channelID
        self.launchWindow = launchWindow
        self.isLiveContent = isLiveContent
        self.isUltraHD = isUltraHD
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        guard !isStopped, startupTask == nil else { return }
        startupTask = Task {
            defer { startupTask = nil }
            do {
                let token = try OfficialSession.discover().authorizationToken()
                let entitlement: Entitlement
                if let channelID {
                    entitlement = try await LinearEntitlementClient.fetch(linearID: config.contentID, channelID: channelID, authorization: token)
                } else {
                    entitlement = try await EntitlementClient.fetch(contentID: config.contentID, authorization: token)
                }
                try Task.checkCancellation()
                guard !isStopped else { return }
                if let fp = entitlement.fairPlay {
                    config = Config(contentID: entitlement.contentID, title: config.title, url: fp.url, certificateUrl: fp.certificateUrl, licenseUrl: fp.licenseUrl, licenseToken: fp.licenseToken)
                } else if let hls = entitlement.hlsURL {
                    // NESN's dedicated 4K feed is currently delivered as a direct
                    // HLS asset rather than the FairPlay object used by HD feeds.
                    config = Config(contentID: entitlement.contentID, title: config.title, url: hls, certificateUrl: "", licenseUrl: "", licenseToken: "")
                } else {
                    throw NSError(domain: "NESNEntitlement", code: 404, userInfo: [NSLocalizedDescriptionKey: "NESN did not return a playable HLS asset."])
                }
                startPlayback()
                if player != nil { onPlaybackStarted?() }
            } catch {
                guard !Task.isCancelled, !isStopped else { return }
                presentPlaybackError(error)
            }
        }
    }

    func startPlayback() {
        guard !isStopped, player == nil else { return }
        guard let streamURL = URL(string: config.url), streamURL.scheme == "https" else {
            presentPlaybackError(NSError(domain: "NESNPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "NESN returned an invalid stream URL."]))
            return
        }
        let asset = AVURLAsset(url: streamURL)
        asset.resourceLoader.setDelegate(self, queue: DispatchQueue(label: "nesn.fairplay"))
        let item = AVPlayerItem(asset: asset)
        // No bitrate or resolution ceiling: this allows future 4K/HDR variants.
        item.preferredPeakBitRate = 0
        item.preferredMaximumResolution = .zero
        item.preferredForwardBufferDuration = 20
        accessLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: item,
            queue: .main
        ) { note in
            guard let event = (note.object as? AVPlayerItem)?.accessLog()?.events.last else { return }
            let indicated = event.indicatedBitrate
            let observed = event.observedBitrate
            guard indicated.isFinite, observed.isFinite, indicated >= 0, observed >= 0,
                  indicated < Double(Int.max), observed < Double(Int.max) else { return }
            fputs("Stream quality: indicated=\(Int(indicated))bps observed=\(Int(observed))bps\n", stderr)
        }
        player = AVPlayer(playerItem: item)
        configurePlayerForAirPlay(player)
        if let sampleRate = preferredOutputSampleRate(isUltraHD: isUltraHD, isLiveContent: isLiveContent) {
            // A restored lease is terminal. Reacquisition must create a new one.
            var lease: AudioSampleRateLease?
            audioCoordinator = PlaybackAudioCoordinator(acquire: {
                if let previous = lease { try await previous.restoreAndWait(); lease = nil }
                let next = AudioSampleRateLease(inactivePreferredRate: sampleRate)
                lease = next
                try await next.refreshAndWait()
            }, release: {
                if let current = lease { try await current.restoreAndWait(); lease = nil }
            })
        }
        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                // Read the current route on the main actor, never a stale KVO value.
                self.audioCoordinator?.setLocalPlayback(!self.player.isExternalPlaybackActive)
            }
        }
        let initialFrame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        let playbackView = PlaybackView(frame: initialFrame, player: player, isLiveContent: isLiveContent)
        playbackView.onFailure = { [weak self] error in self?.presentPlaybackError(error) }
        playbackView.onCaptureFrame = { [weak self] in self?.captureFrame() }
        playbackView.onChooseSource = { [weak self] in self?.recover(chooseAnother: true) }
        window = NSWindow(contentRect: initialFrame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = config.title
        window.delegate = self
        window.contentView = playbackView
        window.styleMask.insert(.resizable)
        window.contentMinSize = NSSize(width: 320, height: 180)
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center(); window.makeKeyAndOrderFront(nil)
        playbackView.play()
        inspectionTask = Task { defer { inspectionTask = nil }; await inspectMaster(url: asset.url) }
    }

    func captureFrame() {
        guard !isStopped, captureTask == nil, let player, let source = player.currentItem else { return }
        captureTask = Task {
            defer { captureTask = nil }
            do {
                let image = try await FrameCapture.capture(player: player, authorized: true)
                try Task.checkCancellation()
                guard !isStopped, player.currentItem === source else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [image.contentType]
                panel.nameFieldStringValue = "NESN-frame.\(image.fileExtension)"
                panel.message = "\(image.width) × \(image.height) · \(image.dynamicRangeNote)"
                let response = await panel.beginSheetModal(for: window)
                try Task.checkCancellation()
                guard !isStopped, player.currentItem === source, response == .OK, let url = panel.url else { return }
                try FrameCapture.save(image, to: url, overwriteConfirmed: true)
            } catch {
                guard !Task.isCancelled, !isStopped else { return }
                let alert = NSAlert()
                alert.messageText = "Screenshot unavailable"
                alert.informativeText = (error as? FrameCapture.Failure)?.errorDescription ?? "The screenshot could not be saved."
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    func presentPlaybackError(_ error: Error) {
        guard !isStopped, !presentingError else { return }
        presentingError = true
        let alert = NSAlert()
        alert.messageText = "NESN playback could not start"
        alert.informativeText = safeErrorDescription(error) + "\n\nRetry requests fresh authorization for this source. Choose Another never bypasses a denied entitlement."
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Choose Another")
        alert.addButton(withTitle: "Quit")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, !self.isStopped else { return }
            self.presentingError = false
            if response == .alertFirstButtonReturn { self.recover(chooseAnother: false) }
            else if response == .alertSecondButtonReturn { self.recover(chooseAnother: true) }
            else { NSApplication.shared.terminate(nil) }
        }
        if let target = window ?? launchWindow { alert.beginSheetModal(for: target, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }

    func recover(chooseAnother: Bool) {
        guard !isStopped else { return }
        stopPlayback()
        Task {
            await cleanupTask?.value
            while let coordinator = audioCoordinator, !coordinator.restorationSucceeded {
                guard !terminationPending else { return }
                let alert = NSAlert()
                alert.messageText = "Audio output could not be restored"
                alert.informativeText = "Restore the local audio output before changing sources."
                alert.addButton(withTitle: "Retry Restoration")
                alert.addButton(withTitle: "Quit")
                if alert.runModal() != .alertFirstButtonReturn { NSApplication.shared.terminate(nil); return }
                await coordinator.shutdown()
            }
            guard !terminationPending else { return }
            onRecovery?(chooseAnother)
        }
    }


    func inspectMaster(url: URL) async {
        do {
            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()
            guard !isStopped, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let playlist = String(decoding: data, as: UTF8.self)
            guard playlist.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return }
            let q = MasterPlaylistInspector.inspect(playlist)
            fputs("Master capabilities: \(q.maximumWidth)x\(q.maximumHeight) @ \(q.maximumFrameRate)fps, HDR=\(q.supportsHDR), HEVC=\(q.supportsHEVC), audioChannels=\(q.maximumAudioChannels), bandwidth=\(q.maximumBandwidth)bps\n", stderr)
        } catch {
            fputs("Master inspection failed: \(safeErrorDescription(error))\n", stderr)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        stopPlayback()
        Task {
            await cleanupTask?.value
            await audioCoordinator?.shutdown()
            let restored = audioCoordinator?.restorationSucceeded ?? true
            if !restored { terminationPending = false }
            sender.reply(toApplicationShouldTerminate: restored)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { stopPlayback() }
    func windowWillClose(_ notification: Notification) { stopPlayback() }
    func stopPlayback() {
        guard !isStopped else { return }
        isStopped = true
        startupTask?.cancel(); startupTask = nil
        inspectionTask?.cancel(); inspectionTask = nil
        captureTask?.cancel(); captureTask = nil
        if let sheet = window?.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        keyTasks.values.forEach { $0.cancel() }; keyTasks.removeAll()
        (window?.contentView as? PlaybackView)?.dispose()
        if let accessLogObserver { NotificationCenter.default.removeObserver(accessLogObserver) }; accessLogObserver = nil
        externalPlaybackObservation?.invalidate(); externalPlaybackObservation = nil
        player?.currentItem?.asset.cancelLoading()
        session.invalidateAndCancel()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        let coordinator = audioCoordinator
        cleanupTask = Task {
            await coordinator?.shutdown()
            if coordinator?.restorationSucceeded == true { audioCoordinator = nil }
        }
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url?.scheme == "skd" else { return false }
        Task { @MainActor in
            guard !isStopped, !request.isCancelled else { return }
            let id = ObjectIdentifier(request)
            keyTasks[id] = Task { defer { keyTasks[id] = nil }; await handle(request) }
        }
        return true
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        Task { @MainActor in keyTasks.removeValue(forKey: ObjectIdentifier(request))?.cancel() }
    }

    func handle(_ loading: AVAssetResourceLoadingRequest) async {
        do {
            guard let certificateURL = URL(string: config.certificateUrl), certificateURL.scheme == "https",
                  let licenseURL = URL(string: config.licenseUrl), licenseURL.scheme == "https" else {
                throw NSError(domain:"NESN",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid FairPlay endpoint"])
            }
            let (cert, certResponse) = try await session.data(from: certificateURL)
            try Task.checkCancellation()
            guard !isStopped, !loading.isCancelled else { return }
            guard (certResponse as? HTTPURLResponse)?.statusCode == 200, !cert.isEmpty else {
                throw NSError(domain:"NESN",code:2,userInfo:[NSLocalizedDescriptionKey:"FairPlay certificate unavailable"])
            }
            guard let skd = loading.request.url?.absoluteString,
                  let contentId = skd.replacingOccurrences(of: "skd://", with: "").data(using: .utf8) else { throw NSError(domain:"NESN",code:1) }
            let spc = try loading.streamingContentKeyRequestData(forApp: cert, contentIdentifier: contentId, options: nil)
            var req = URLRequest(url: licenseURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue(config.licenseToken, forHTTPHeaderField: "X-AxDRM-Message")
            req.httpBody = spc
            let (ckc, response) = try await session.data(for: req)
            try Task.checkCancellation()
            guard !isStopped, !loading.isCancelled else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                fputs("License request failed with HTTP \(status)\n", stderr)
                throw NSError(domain:"NESN",code:status)
            }
            loading.dataRequest?.respond(with: ckc)
            loading.finishLoading()
        } catch {
            guard !Task.isCancelled, !isStopped, !loading.isCancelled else { return }
            fputs("FairPlay error: \(safeErrorDescription(error))\n", stderr)
            loading.finishLoading(with: error)
        }
    }
}

@MainActor final class WatchLauncher: NSObject, NSWindowDelegate {
    let app: NSApplication
    let window: NSWindow
    var task: Task<Void, Never>?
    var active: AppDelegate?
    private var generation = 0
    private(set) var isCancelled = false
    private var closingAfterSuccess = false
    var fetchCatalog: () async throws -> WatchCatalogResult = {
        let token = try OfficialSession.discover().authorizationToken()
        return try await WatchCatalogClient.fetchResult(authorization: token)
    }
    var selectItem: ([WatchItem], Bool) -> WatchItem? = { chooseWatchItem($0, allowAutomatic: $1) }
    var beginPlayback: (AppDelegate) -> Void = {
        $0.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }
    init(app: NSApplication, window: NSWindow) {
        self.app = app; self.window = window
        super.init()
        window.delegate = self
    }
    func cancel() {
        isCancelled = true
        generation += 1
        task?.cancel()
        task = nil
        active?.stopPlayback()
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
    }
    func windowWillClose(_ notification: Notification) {
        guard !closingAfterSuccess else { return }
        cancel()
    }
    private func isCurrent(_ current: Int) -> Bool { !isCancelled && current == generation }
    func load(previous: WatchItem? = nil, forceChooser: Bool = false) {
        task?.cancel()
        generation += 1
        let current = generation
        isCancelled = false
        window.makeKeyAndOrderFront(nil)
        task = Task {
            defer { if current == generation { task = nil } }
            do {
                guard isCurrent(current), !Task.isCancelled else { return }
                let item: WatchItem
                if let previous, !forceChooser {
                    item = previous
                } else {
                    let result = try await fetchCatalog()
                    try Task.checkCancellation()
                    guard isCurrent(current) else { return }
                    for warning in result.warnings { fputs("Catalog warning: \(warning)\n", stderr) }
                    if !result.warnings.isEmpty {
                        let alert = NSAlert()
                        alert.messageText = "Some NESN programming could not be loaded"
                        alert.informativeText = result.warnings.joined(separator: "\n")
                        alert.runModal()
                    }
                    guard isCurrent(current), !Task.isCancelled else { return }
                    guard !result.items.isEmpty else {
                        throw NSError(domain: "NESNCatalog", code: 404, userInfo: [NSLocalizedDescriptionKey: "NESN returned no playable programs."])
                    }
                    let selected = selectItem(result.items, !forceChooser)
                    guard isCurrent(current), !Task.isCancelled else { return }
                    guard let selected else {
                        app.terminate(nil); return
                    }
                    item = selected
                }
                try Task.checkCancellation()
                guard isCurrent(current) else { return }
                let config = Config(contentID: item.contentID, title: item.choice.title, url: "", certificateUrl: "", licenseUrl: "", licenseToken: "")
                let delegate = AppDelegate(config: config, channelID: item.channelID, launchWindow: window,
                                           isLiveContent: item.choice.isLive, isUltraHD: playbackIsUltraHD(item.choice))
                delegate.onRecovery = { [weak self] chooseAnother in
                    guard let self, self.isCurrent(current) else { return }
                    self.load(previous: item, forceChooser: chooseAnother)
                }
                delegate.onPlaybackStarted = { [weak self] in
                    guard let self, self.isCurrent(current) else { return }
                    self.closingAfterSuccess = true
                    defer { self.closingAfterSuccess = false }
                    self.window.close()
                }
                let old = active
                active = delegate
                app.delegate = delegate
                old?.window?.close()
                beginPlayback(delegate)
            } catch {
                guard !Task.isCancelled, isCurrent(current) else { return }
                let alert = NSAlert()
                alert.messageText = "NESN Player could not load the watch catalog"
                alert.informativeText = safeErrorDescription(error) + "\n\nOpen NESN 360 and confirm you are signed in."
                alert.addButton(withTitle: "Retry")
                alert.addButton(withTitle: "Quit")
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard let self, self.isCurrent(current) else { return }
                    if response == .alertFirstButtonReturn { self.load(previous: previous, forceChooser: forceChooser) }
                    else { self.app.terminate(nil) }
                }
            }
        }
    }
}

/// Isolated UI-only exercise: no session discovery, entitlement, asset or audio lease.
@MainActor func runSmokeTest() -> Int32 {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let player = AVPlayer()
    player.isMuted = true
    player.allowsExternalPlayback = false
    var passed = true
    for live in [true, false] {
        let frame = NSRect(x: -30000, y: -30000, width: 1280, height: 720)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = PlaybackView(frame: NSRect(origin: .zero, size: frame.size), player: player, isLiveContent: live)
        window.contentView = view
        for size in [NSSize(width: 320, height: 180), NSSize(width: 1280, height: 720)] {
            window.setContentSize(size)
            view.layoutSubtreeIfNeeded()
            passed = passed && view.bounds.width > 0 && !window.isVisible && !window.isKeyWindow
        }
        view.dispose()
        passed = passed && view.isDisposed && view.activeObserverCount == 0
        window.close()
    }
    passed = passed && player.currentItem == nil && player.isMuted && !app.isActive
    print(passed ? "SMOKE_TEST_PASS: isolated live/replay layout and cleanup" : "SMOKE_TEST_FAIL")
    return passed ? 0 : 1
}

// XCTest imports do not execute this entry point. Explicit finite no-start mode.
switch playerLaunchMode(arguments: CommandLine.arguments) {
case .noStart: break
case .smoke: exit(runSmokeTest())
case .normal:
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let launchDelegate = LaunchDelegate()
    app.delegate = launchDelegate
    objc_setAssociatedObject(app, "NESNPlayerLaunchDelegate", launchDelegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "NESN Player"
    window.center()
    let label = NSTextField(labelWithString: "Loading NESN programming…")
    label.alignment = .center
    label.font = .systemFont(ofSize: 17, weight: .medium)
    label.frame = NSRect(x: 30, y: 72, width: 480, height: 28)
    window.contentView?.addSubview(label)
    let launcher = WatchLauncher(app: app, window: window)
    objc_setAssociatedObject(app, "NESNPlayerLauncher", launcher, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    launchDelegate.onTerminate = { [weak launcher] in launcher?.cancel() }
    launcher.load()
    app.activate(ignoringOtherApps: true)
    app.run()
}
