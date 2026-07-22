import AppKit
import Foundation

struct WatchItem {
    let choice: WatchChoice
    let contentID: String
    let channelID: String?
}

enum WatchCatalogClient {
    private static let homeQuery = """
    query WatchCatalog($site:String!,$device:Device!,$path:String,$includeContent:Boolean,$platform:EntitlementDevice){page(site:$site,device:$device,path:$path,includeContent:$includeContent,platform:$platform){modules{__typename ... on CuratedTrayModule{title contentData{__typename ... on Game{id title currentState livestreams{id title}} ... on Video{id title}}} ... on GeneratedTrayModule{title contentData{__typename ... on Video{id title}}}}}}
    """
    private static let linearQuery = """
    query LinearCatalog($site:String!,$device:Device!,$path:String,$includeContent:Boolean,$platform:EntitlementDevice){page(site:$site,device:$device,path:$path,includeContent:$includeContent,platform:$platform){modules{__typename ... on LinearchannelStandaloneModule{contentData{__typename id title ... on Linearchannel{channels{id title}}}}}}}
    """

    static func fetch(authorization: String) async throws -> [WatchItem] {
        async let home = fetchPageResult(query: homeQuery, path: "/", authorization: authorization)
        async let linear = fetchPageResult(query: linearQuery, path: "/live", authorization: authorization)
        let (homeResult, linearResult) = await (home, linear)
        var items: [WatchItem] = []
        if case let .success(homeObject) = homeResult { collectHome(homeObject, into: &items) }
        if case let .success(linearObject) = linearResult { collectLinear(linearObject, into: &items) }
        if items.isEmpty {
            if case let .failure(error) = homeResult { throw error }
            if case let .failure(error) = linearResult { throw error }
        }
        let ordered = chooserChoices(from: items.map(\.choice))
        let byID = items.reduce(into: [String: WatchItem]()) { result, item in
            if result[item.choice.id] == nil { result[item.choice.id] = item }
        }
        return ordered.compactMap { byID[$0.id] }
    }

    private static func fetchPageResult(query: String, path: String, authorization: String) async -> Result<Any, Error> {
        do { return .success(try await fetchPage(query: query, path: path, authorization: authorization)) }
        catch { return .failure(error) }
    }

    private static func fetchPage(query: String, path: String, authorization: String) async throws -> Any {
        let body: [String: Any] = [
            "operationName": path == "/live" ? "LinearCatalog" : "WatchCatalog",
            "query": query,
            "variables": ["site": "nesn", "device": "IOS", "path": path, "includeContent": true, "platform": "ios_ipad"],
        ]
        var request = URLRequest(url: URL(string: "https://nesn-cached.api.viewlift.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "NESNCatalog", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func collectHome(_ value: Any, into items: inout [WatchItem]) {
        guard let root = value as? [String: Any],
              let data = root["data"] as? [String: Any],
              let page = data["page"] as? [String: Any],
              let modules = page["modules"] as? [[String: Any]] else { return }
        for module in modules {
            let moduleTitle = (module["title"] as? String) ?? ""
            let rows = module["contentData"] as? [[String: Any]] ?? []
            for row in rows {
                let type = row["__typename"] as? String
                if type == "Game", (row["currentState"] as? String)?.lowercased() == "live",
                   let streams = row["livestreams"] as? [[String: Any]],
                   let gameTitle = row["title"] as? String {
                    let candidates = streams.compactMap { stream -> WatchStream? in
                        guard let id = stream["id"] as? String else { return nil }
                        return WatchStream(id: id, title: (stream["title"] as? String) ?? gameTitle)
                    }
                    guard let stream = preferredLiveStream(candidates) else { continue }
                    let isUHD = stream.title.localizedCaseInsensitiveContains("4K") || stream.title.localizedCaseInsensitiveContains("UHD")
                    let title = isUHD ? stream.title : gameTitle
                    let choice = WatchChoice(id: stream.id, title: title, kind: .liveEvent, isLive: true)
                    items.append(WatchItem(choice: choice, contentID: stream.id, channelID: nil))
                } else if type == "Video", moduleTitle.localizedCaseInsensitiveContains("FULL GAME REPLAYS"),
                          let id = row["id"] as? String, let title = row["title"] as? String,
                          isFullGameReplay(title: title) {
                    let choice = WatchChoice(id: id, title: title.trimmingCharacters(in: .whitespaces), kind: .replay, isLive: false)
                    items.append(WatchItem(choice: choice, contentID: id, channelID: nil))
                }
            }
        }
    }

    private static func collectLinear(_ value: Any, into items: inout [WatchItem]) {
        func walk(_ object: Any) {
            if let dictionary = object as? [String: Any] {
                if dictionary["__typename"] as? String == "Linearchannel",
                   let linearID = dictionary["id"] as? String,
                   let channels = dictionary["channels"] as? [[String: Any]] {
                    for channel in channels {
                        guard let channelID = channel["id"] as? String,
                              let title = channel["title"] as? String else { continue }
                        let id = "linear:\(linearID):\(channelID)"
                        let choice = WatchChoice(id: id, title: "\(title) — live channel", kind: .linearChannel, isLive: true, channelID: channelID)
                        items.append(WatchItem(choice: choice, contentID: linearID, channelID: channelID))
                    }
                }
                for child in dictionary.values { walk(child) }
            } else if let array = object as? [Any] {
                for child in array { walk(child) }
            }
        }
        walk(value)
    }
}

@MainActor
func chooseWatchItem(_ items: [WatchItem]) -> WatchItem? {
    if let automatic = automaticChoice(from: items.map(\.choice)) {
        return items.first { $0.choice == automatic }
    }
    guard !items.isEmpty else { return nil }
    let alert = NSAlert()
    alert.messageText = "What would you like to watch?"
    alert.informativeText = "No live Red Sox game is available. Choose another live NESN source or a recent full-game replay."
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 520, height: 30), pullsDown: false)
    for item in items {
        let prefix: String
        switch item.choice.kind {
        case .liveEvent: prefix = "LIVE EVENT"
        case .linearChannel: prefix = "LIVE TV"
        case .replay: prefix = "REPLAY"
        }
        popup.addItem(withTitle: "[\(prefix)] \(item.choice.title)")
    }
    alert.accessoryView = popup
    alert.addButton(withTitle: "Watch")
    alert.addButton(withTitle: "Cancel")
    // Require an explicit click instead of letting Return accept the default.
    alert.buttons[0].keyEquivalent = ""
    NSApplication.shared.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return nil }
    return items.indices.contains(popup.indexOfSelectedItem) ? items[popup.indexOfSelectedItem] : nil
}
