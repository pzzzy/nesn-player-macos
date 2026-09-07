import Foundation

/// Never includes server text, URLs, userInfo, underlying errors, or arbitrary domains.
func safeErrorDescription(_ error: Error) -> String {
    let value = error as NSError
    let labels = ["NESNEntitlement": "Entitlement", "NESNLinearEntitlement": "Live channel", "NESNCatalog": "Catalog", "NESNSchedule": "Schedule", "NESNGraphQL": "Catalog response", "NESNSession": "NESN 360 session", NSURLErrorDomain: "Network"]
    guard let label = labels[value.domain] else { return "The request could not be completed. Please try again." }
    return "\(label) unavailable (code \(value.code)). Please try again."
}

enum APISession {
    static func make() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }
    static let shared = make()
}

struct GraphQLPage {
    let object: [String: Any]
    let warnings: [String]

    static func parse(_ data: Data) throws -> GraphQLPage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let page = payload["page"] as? [String: Any],
              page["modules"] is [Any] else {
            throw NSError(domain: "NESNGraphQL", code: 422)
        }
        let hasErrors = !(root["errors"] as? [Any] ?? []).isEmpty
        return GraphQLPage(object: ["data": payload], warnings: hasErrors ? ["Some catalog data could not be loaded."] : [])
    }
}
