import AppKit
import AVKit
import AVFoundation
import ObjectiveC

struct Config: Decodable { let contentID, title, url, certificateUrl, licenseUrl, licenseToken: String }

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, AVAssetResourceLoaderDelegate {
    var window: NSWindow!
    var player: AVPlayer!
    var config: Config
    let session = URLSession(configuration: .default)
    init(config: Config) { self.config = config }

    func applicationDidFinishLaunching(_ note: Notification) {
        Task {
            do {
                let token = try OfficialSession.discover().authorizationToken()
                let entitlement = try await EntitlementClient.fetch(contentID: config.contentID, authorization: token)
                let fp = entitlement.fairPlay
                config = Config(contentID: entitlement.contentID, title: entitlement.title, url: fp.url, certificateUrl: fp.certificateUrl, licenseUrl: fp.licenseUrl, licenseToken: fp.licenseToken)
                startPlayback()
            } catch {
                presentPlaybackError(error)
            }
        }
    }

    func startPlayback() {
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
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: item,
            queue: .main
        ) { note in
            guard let event = (note.object as? AVPlayerItem)?.accessLog()?.events.last else { return }
            fputs("Stream quality: indicated=\(Int(event.indicatedBitrate))bps observed=\(Int(event.observedBitrate))bps\n", stderr)
        }
        player = AVPlayer(playerItem: item)
        let initialFrame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        let container = NSView(frame: initialFrame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        let view = AVPlayerView(frame: container.bounds)
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window = NSWindow(contentRect: initialFrame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = config.title
        window.contentView = container
        window.styleMask.insert(.resizable)
        window.contentMinSize = NSSize(width: 320, height: 180)
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center(); window.makeKeyAndOrderFront(nil)
        player.play()
        Task { await inspectMaster(url: asset.url) }
    }

    func presentPlaybackError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "NESN playback could not start"
        alert.informativeText = error.localizedDescription + "\n\nOpen NESN 360, confirm you are signed in, then try again."
        alert.runModal()
    }


    func inspectMaster(url: URL) async {
        do {
            let (data, _) = try await session.data(from: url)
            let q = MasterPlaylistInspector.inspect(String(decoding: data, as: UTF8.self))
            fputs("Master capabilities: \(q.maximumWidth)x\(q.maximumHeight) @ \(q.maximumFrameRate)fps, HDR=\(q.supportsHDR), HEVC=\(q.supportsHEVC), audioChannels=\(q.maximumAudioChannels), bandwidth=\(q.maximumBandwidth)bps\n", stderr)
        } catch {
            fputs("Master inspection failed: \(error)\n", stderr)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url?.scheme == "skd" else { return false }
        Task { await handle(request) }
        return true
    }

    func handle(_ loading: AVAssetResourceLoadingRequest) async {
        do {
            guard let certificateURL = URL(string: config.certificateUrl), certificateURL.scheme == "https",
                  let licenseURL = URL(string: config.licenseUrl), licenseURL.scheme == "https" else {
                throw NSError(domain:"NESN",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid FairPlay endpoint"])
            }
            let (cert, certResponse) = try await session.data(from: certificateURL)
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
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                fputs("License request failed with HTTP \(status)\n", stderr)
                throw NSError(domain:"NESN",code:status)
            }
            loading.dataRequest?.respond(with: ckc)
            loading.finishLoading()
        } catch {
            fputs("FairPlay error: \(error)\n", stderr)
            loading.finishLoading(with: error)
        }
    }
}

do {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let officialSession = try OfficialSession.discover()
    let token = try officialSession.authorizationToken()
    Task { @MainActor in
        do {
            let events = try await ScheduleClient.fetch(authorization: token)
            guard let event = chooseEvent(events), let contentID = event.streamID else {
                throw NSError(domain: "NESNSchedule", code: 404, userInfo: [NSLocalizedDescriptionKey: "No live or upcoming playable NESN events were found."])
            }
            let config = Config(contentID: contentID, title: event.title, url: "", certificateUrl: "", licenseUrl: "", licenseToken: "")
            let delegate = AppDelegate(config: config)
            app.delegate = delegate
            // Keep the delegate alive for the process lifetime.
            objc_setAssociatedObject(app, "NESNPlayerDelegate", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        } catch {
            let alert = NSAlert()
            alert.messageText = "NESN Player could not find an event"
            alert.informativeText = error.localizedDescription + "\n\nOpen NESN 360 and confirm you are signed in, then try again."
            alert.runModal()
        }
    }
    app.run()
} catch {
    let alert = NSAlert()
    alert.messageText = "NESN Player setup needed"
    alert.informativeText = "Install and sign into the official NESN 360 app. You do not need to open a game there.\n\n\(error.localizedDescription)"
    alert.runModal()
}
