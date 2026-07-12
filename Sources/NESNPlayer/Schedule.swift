import AppKit
import Foundation

struct LiveEvent: Decodable {
    struct States: Decodable {
        struct Point: Decodable { let startDateTime: Double?; let endDateTime: Double? }
        let live: Point?
        let end: Point?
    }
    struct Stream: Decodable { let id: String; let title: String? }
    let id: String
    let title: String
    let currentState: String?
    let states: States?
    let livestreams: [Stream]?

    var streamID: String? { livestreams?.first?.id }
    var start: Date { Date(timeIntervalSince1970: states?.live?.startDateTime ?? 0) }
}

enum ScheduleClient {
    private static let query = """
    query LiveSchedule($site:String!,$device:Device!,$path:String,$includeContent:Boolean,$platform:EntitlementDevice){page(site:$site,device:$device,path:$path,includeContent:$includeContent,platform:$platform){modules{__typename ... on CuratedTrayModule{title contentData{__typename ... on Game{id title currentState states{live{startDateTime} end{endDateTime}} livestreams{id title}}}}}}}
    """

    static func fetch(authorization: String) async throws -> [LiveEvent] {
        let body: [String: Any] = [
            "operationName": "LiveSchedule",
            "query": query,
            "variables": ["site": "nesn", "device": "IOS", "path": "/", "includeContent": true, "platform": "ios_ipad"]
        ]
        var request = URLRequest(url: URL(string: "https://nesn-cached.api.viewlift.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain:"NESNSchedule", code:(response as? HTTPURLResponse)?.statusCode ?? 0) }
        let object = try JSONSerialization.jsonObject(with: data)
        var results: [LiveEvent] = []
        collectGames(object, into: &results)
        let unique = Dictionary(grouping: results.filter { $0.streamID != nil }, by: { $0.id }).compactMap(\.value.first)
        return unique.sorted { lhs, rhs in
            let ll = lhs.currentState?.lowercased() == "live"
            let rl = rhs.currentState?.lowercased() == "live"
            return ll == rl ? lhs.start < rhs.start : ll && !rl
        }
    }

    private static func collectGames(_ value: Any, into results: inout [LiveEvent]) {
        if let dictionary = value as? [String: Any] {
            if dictionary["__typename"] as? String == "Game",
               let data = try? JSONSerialization.data(withJSONObject: dictionary),
               let event = try? JSONDecoder().decode(LiveEvent.self, from: data) { results.append(event) }
            for child in dictionary.values { collectGames(child, into: &results) }
        } else if let array = value as? [Any] {
            for child in array { collectGames(child, into: &results) }
        }
    }
}

@MainActor func chooseEvent(_ events: [LiveEvent]) -> LiveEvent? {
    guard events.count > 1 else { return events.first }
    let live = events.filter { $0.currentState?.lowercased() == "live" }
    if live.count == 1 { return live[0] }
    // Prefer the primary Boston Red Sox telecast over simultaneous minor-league
    // or alternate events; otherwise let the subscriber choose.
    let primaryRedSox = live.filter {
        $0.title.localizedCaseInsensitiveContains("Boston Red Sox") &&
        !$0.title.localizedCaseInsensitiveContains("Worcester")
    }
    if primaryRedSox.count == 1 { return primaryRedSox[0] }
    let candidates = live.isEmpty ? events : live
    let alert = NSAlert()
    alert.messageText = live.isEmpty ? "Choose an upcoming NESN event" : "Choose a live NESN event"
    alert.informativeText = candidates.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
    for index in candidates.indices.prefix(3) { alert.addButton(withTitle: "\(index + 1)") }
    alert.addButton(withTitle: "Cancel")
    let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    return candidates.indices.contains(response) ? candidates[response] : nil
}
