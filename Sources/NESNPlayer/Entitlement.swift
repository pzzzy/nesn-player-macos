import Foundation

struct FairPlayInfo: Decodable {
    let url: String
    let certificateUrl: String
    let licenseUrl: String
    let licenseToken: String
}

struct Entitlement: Decodable {
    struct Video: Decodable {
        struct StreamingInfo: Decodable {
            struct VideoAssets: Decodable {
                let fairPlay: FairPlayInfo?
                let hls: String?
                let is4K: Bool?
            }
            let videoAssets: VideoAssets
        }
        let id: String
        let title: String
        let streamingInfo: StreamingInfo
    }
    let playable: Bool
    let success: Bool
    let video: Video

    var contentID: String { video.id }
    var title: String { video.title }
    var fairPlay: FairPlayInfo? { video.streamingInfo.videoAssets.fairPlay }
    var hlsURL: String? { video.streamingInfo.videoAssets.hls }
    var is4K: Bool { video.streamingInfo.videoAssets.is4K == true }

    static func parse(_ data: Data) throws -> Entitlement {
        let value = try JSONDecoder().decode(Entitlement.self, from: data)
        guard value.success, value.playable else { throw NSError(domain: "NESNEntitlement", code: 403) }
        return value
    }
}

struct StreamCapabilities {
    var maximumWidth = 0
    var maximumHeight = 0
    var maximumFrameRate = 0.0
    var maximumBandwidth = 0
    var maximumAudioChannels = 0
    var supportsHDR = false
    var supportsHEVC = false
}

enum MasterPlaylistInspector {
    static func inspect(_ text: String) -> StreamCapabilities {
        var q = StreamCapabilities()
        for line in text.split(separator: "\n").map(String.init) {
            if let r = line.range(of: #"RESOLUTION=(\d+)x(\d+)"#, options: .regularExpression) {
                let parts = line[r].dropFirst("RESOLUTION=".count).split(separator: "x")
                q.maximumWidth = max(q.maximumWidth, Int(parts[0]) ?? 0)
                q.maximumHeight = max(q.maximumHeight, Int(parts[1]) ?? 0)
            }
            if let r = line.range(of: #"FRAME-RATE=([0-9.]+)"#, options: .regularExpression) {
                q.maximumFrameRate = max(q.maximumFrameRate, Double(line[r].dropFirst("FRAME-RATE=".count)) ?? 0)
            }
            if let r = line.range(of: #"BANDWIDTH=(\d+)"#, options: .regularExpression) {
                q.maximumBandwidth = max(q.maximumBandwidth, Int(line[r].dropFirst("BANDWIDTH=".count)) ?? 0)
            }
            if let r = line.range(of: #"CHANNELS="?(\d+)"?"#, options: .regularExpression) {
                let digits = line[r].filter(\.isNumber)
                q.maximumAudioChannels = max(q.maximumAudioChannels, Int(digits) ?? 0)
            }
            let upper = line.uppercased()
            q.supportsHDR = q.supportsHDR || upper.contains("VIDEO-RANGE=PQ") || upper.contains("VIDEO-RANGE=HLG")
            q.supportsHEVC = q.supportsHEVC || line.contains("hvc1") || line.contains("hev1")
        }
        return q
    }
}

struct OfficialSession {
    let container: URL
    static func discover() throws -> OfficialSession {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers")
        for candidate in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let data = candidate.appendingPathComponent("Data")
            if FileManager.default.fileExists(atPath: data.appendingPathComponent("Library/Preferences/com.nesn.nesngo.plist").path), FileManager.default.fileExists(atPath: data.appendingPathComponent("Documents/TokenSettings.plist").path) { return OfficialSession(container: data) }
        }
        throw NSError(domain:"NESNSession",code:404,userInfo:[NSLocalizedDescriptionKey:"Install and sign into NESN 360 first."])
    }
    func authorizationToken() throws -> String {
        for name in ["Documents/TokenSettings.plist", "Documents/UserDetails.plist"] {
            let url = container.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let token = plist["authorizationToken"] as? String, !token.isEmpty else { continue }
            return token
        }
        throw NSError(domain:"NESNSession",code:401,userInfo:[NSLocalizedDescriptionKey:"Sign into NESN 360 again."])
    }
    func latestContentID() throws -> String {
        // The official app caches its home/schedule model on launch. Prefer any
        // currently-live game's livestream video ID, so users need not open it.
        let page = container.appendingPathComponent("Documents/PageCached.json")
        if let data = try? Data(contentsOf: page),
           let object = try? JSONSerialization.jsonObject(with: data),
           let live = findLiveStreamID(in: object) { return live }
        // Fallback for older app versions: most recent cached entitlement request.
        let db = try Data(contentsOf: container.appendingPathComponent("Library/Caches/com.nesn.nesngo/Cache.db"))
        let text = String(decoding: db, as: UTF8.self)
        let re = try NSRegularExpression(pattern: #"/v3/entitlement/video/status\?id=([0-9a-fA-F-]{36})"#)
        let matches = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = matches.last, let range = Range(match.range(at: 1), in: text) else {
            throw NSError(domain:"NESNSession",code:404,userInfo:[NSLocalizedDescriptionKey:"Open NESN 360 once so its live schedule can refresh."])
        }
        return String(text[range])
    }
    private func findLiveStreamID(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if (dictionary["currentState"] as? String)?.lowercased() == "live",
               let streams = dictionary["livestreams"] as? [[String: Any]],
               let id = streams.first?["id"] as? String { return id }
            for child in dictionary.values { if let id = findLiveStreamID(in: child) { return id } }
        } else if let array = value as? [Any] {
            for child in array { if let id = findLiveStreamID(in: child) { return id } }
        }
        return nil
    }
}
enum EntitlementClient {
    static func fetch(contentID: String, authorization: String) async throws -> Entitlement {
        var components = URLComponents(string: "https://nesn.api.viewlift.com/v3/entitlement/video/status")!
        components.queryItems = [
            .init(name: "id", value: contentID),
            .init(name: "deviceId", value: UUID().uuidString),
            .init(name: "deviceType", value: "ios_ipad"),
            .init(name: "contentConsumption", value: "ios")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("HDCP-2.2", forHTTPHeaderField: "hdcp")
        request.setValue("L1", forHTTPHeaderField: "sl")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NESN 360/8 CFNetwork/3860 Darwin/25", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "NESNEntitlement", code: (response as? HTTPURLResponse)?.statusCode ?? 0) }
        return try Entitlement.parse(data)
    }
}

enum LinearEntitlementClient {
    static func fetch(linearID: String, channelID: String, authorization: String) async throws -> Entitlement {
        var components = URLComponents(string: "https://nesn.api.viewlift.com/v3/entitlement/linearchannel")!
        components.queryItems = [
            .init(name: "id", value: linearID), .init(name: "deviceId", value: UUID().uuidString),
            .init(name: "deviceType", value: "ios_ipad"), .init(name: "contentConsumption", value: "ios"),
            .init(name: "channelId", value: channelID),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("HDCP-2.2", forHTTPHeaderField: "hdcp")
        request.setValue("L1", forHTTPHeaderField: "sl")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NESN 360/8 CFNetwork/3860 Darwin/25", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "NESNLinearEntitlement", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard object?["playable"] as? Bool == true,
              let linear = object?["linearchannel"] as? [String: Any],
              let info = linear["streamingInfo"] as? [String: Any],
              let assets = info["videoAssets"] as? [String: Any],
              let fp = assets["fairPlay"] as? [String: Any],
              let url = fp["url"] as? String, let certificate = fp["certificateUrl"] as? String,
              let license = fp["licenseUrl"] as? String, let token = fp["licenseToken"] as? String,
              let id = linear["id"] as? String, let title = linear["title"] as? String else {
            throw NSError(domain: "NESNLinearEntitlement", code: 422)
        }
        let synthetic: [String: Any] = ["playable": true, "success": true, "video": [
            "id": id, "title": title, "streamingInfo": ["videoAssets": ["fairPlay": [
                "url": url, "certificateUrl": certificate, "licenseUrl": license, "licenseToken": token,
            ]]],
        ]]
        return try Entitlement.parse(JSONSerialization.data(withJSONObject: synthetic))
    }
}
