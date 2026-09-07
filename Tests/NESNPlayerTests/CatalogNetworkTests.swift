import Foundation
#if canImport(XCTest) && !CATALOG_STANDALONE
import XCTest
@testable import NESNPlayer
final class CatalogNetworkTests: XCTestCase {
    func testFixtures() { runCatalogNetworkTests() }
}
#endif

private func expect(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
    #if canImport(XCTest) && !CATALOG_STANDALONE
    XCTAssertTrue(condition, file: file, line: line)
    #else
    if !condition { print("FAIL: \(file):\(line)"); exit(1) }
    #endif
}
func runCatalogNetworkTests() {
    parentQualityDoesNotOverrideChild()
    catalogFixtures()
    orderedFeedFixtures()
    partialSourceFixtures()
    successfulVideoAndMissingAssetsFixtures()
    linearFixtures()
    diagnosticsFixtures()
    ambiguousStreamsRequireChoice()
    exactHLSAttributes()
    denialWithoutVideoIsAuthorizationError()
    print("Catalog/network fixtures passed")
}

private func parentQualityDoesNotOverrideChild() {
    let data = Data(#"{"data":{"page":{"modules":[{"contentData":[{"__typename":"Game","title":"Red Sox 4K","currentState":"live","livestreams":[{"id":"hd","title":"HD"},{"id":"uhd","title":"UHD"}]}]}]}}}"#.utf8)
    do {
        let items = try WatchCatalogClient.parsePage(data, linear: false).items
        expect(automaticChoice(from: items.map(\.choice))?.id == "uhd")
    } catch { expect(false) }
}

private func partialSourceFixtures() {
    do {
        let home = try homeFixture([["id": "primary", "title": "4K"]])
        let linear = WatchCatalogResult(items: [WatchItem(choice: .init(id: "linear", title: "NESN", kind: .linearChannel, isLive: true), contentID: "channel", channelID: "hd")], warnings: ["Some catalog data could not be loaded."])
        let failure: Result<WatchCatalogResult, Error> = .failure(NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [NSLocalizedDescriptionKey: "secret https://private.invalid/token"]))
        let homeOnly = try WatchCatalogClient.mergeResults(home: .success(home), linear: failure)
        expect(homeOnly.items.map(\.contentID) == ["primary"])
        expect(homeOnly.warnings.count == 1 && homeOnly.warnings[0].contains("Network"))
        expect(!homeOnly.warnings.joined().contains("secret"))
        expect(automaticChoice(from: homeOnly.items.map(\.choice))?.id == "primary")
        expect(automaticChoice(from: homeOnly.items.map(\.choice), forceChooser: true) == nil)
        let linearOnly = try WatchCatalogClient.mergeResults(home: failure, linear: .success(linear))
        expect(linearOnly.items.map(\.contentID) == ["channel"])
        expect(linearOnly.warnings.count == 2)
        let all = try WatchCatalogClient.mergeResults(home: .success(home), linear: .success(linear))
        expect(all.items.map(\.contentID) == ["primary", "channel"])
        expect(all.warnings == linear.warnings)
        let empty = WatchCatalogResult(items: [], warnings: [])
        expect(try WatchCatalogClient.mergeResults(home: .success(empty), linear: .success(empty)).items.isEmpty)
        do { _ = try WatchCatalogClient.mergeResults(home: failure, linear: failure); expect(false) }
        catch { expect((error as NSError).code == -1009) }
        do { _ = try WatchCatalogClient.mergeResults(home: .success(empty), linear: failure); expect(false) }
        catch { expect((error as NSError).code == -1009) }
    } catch { expect(false) }
}

private func homeFixture(_ streams: [[String: String]], title: String = "Red Sox 4K") throws -> WatchCatalogResult {
    let row: [String: Any] = ["__typename": "Game", "title": title, "currentState": "live", "livestreams": streams]
    return try WatchCatalogClient.parsePage(JSONSerialization.data(withJSONObject: ["data": ["page": ["modules": [["contentData": [row]]]]]]), linear: false)
}

private func orderedFeedFixtures() {
    do {
        for feeds in [
            [["id": "alt", "title": "Alternate 4K"], ["id": "multi", "title": "Multiview UHD"], ["id": "hd", "title": "HD"], ["id": "uhd", "title": "UHD"]],
            [["id": "uhd", "title": "UHD"], ["id": "hd", "title": "HD"], ["id": "multi", "title": "Multiview UHD"], ["id": "alt", "title": "Alternate 4K"]]
        ] {
            let choices = try homeFixture(feeds).items.map(\.choice)
            expect(choices.count == 4)
            expect(automaticChoice(from: choices)?.id == "uhd")
        }
        let twoUHD = try homeFixture([["id": "a", "title": "4K"], ["id": "b", "title": "UHD"]]).items.map(\.choice)
        expect(automaticChoice(from: twoUHD) == nil)
        let hd = try homeFixture([["id": "hd", "title": "HD"], ["id": "unknown"]]).items.map(\.choice)
        expect(automaticChoice(from: hd) == nil) // Unknown child must not inherit parent quality.
        let unrelated = try homeFixture([["id": "boxing", "title": "UHD"]], title: "Boxing").items.map(\.choice)
        let primary = try homeFixture([["id": "primary", "title": "HD"]]).items.map(\.choice)
        expect(automaticChoice(from: unrelated + primary)?.id == "primary")
    } catch { expect(false) }
}

private func successfulVideoAndMissingAssetsFixtures() {
    for assets in [
        #"{"hls":"https://example.invalid/direct.m3u8","is4K":false}"#,
        #"{"fairPlay":{"url":"https://example.invalid/drm.m3u8","certificateUrl":"https://example.invalid/cert","licenseUrl":"https://example.invalid/license","licenseToken":"fixture-only"},"is4K":true}"#
    ] {
        do {
            let value = try Entitlement.parse(Data((#"{"success":true,"playable":true,"video":{"id":"video","title":"Fixture","streamingInfo":{"videoAssets": "# + assets + "}}}").utf8))
            expect(value.contentID == "video" && value.title == "Fixture")
            if value.is4K {
                expect(value.fairPlay?.url == "https://example.invalid/drm.m3u8")
                expect(value.fairPlay?.certificateUrl == "https://example.invalid/cert")
                expect(value.fairPlay?.licenseUrl == "https://example.invalid/license")
                expect(value.fairPlay?.licenseToken == "fixture-only")
                expect(value.hlsURL == nil)
            } else {
                expect(value.hlsURL == "https://example.invalid/direct.m3u8")
                expect(value.fairPlay == nil)
            }
        } catch { expect(false) }
    }
    for info in [#"{}"#, #"{"videoAssets":{}}"#, #"{"videoAssets":{"hls":""}}"#] {
        do {
            _ = try Entitlement.parse(Data((#"{"success":true,"playable":true,"video":{"id":"missing","title":"Fixture","streamingInfo": "# + info + "}}").utf8))
            expect(false)
        } catch { expect(true) }
        do {
            _ = try LinearEntitlementClient.parse(Data((#"{"success":true,"playable":true,"linearchannel":{"id":"missing","title":"Fixture","streamingInfo": "# + info + "}}").utf8))
            expect(false)
        } catch { expect(true) }
    }
}

private func catalogFixtures() {
    let home = Data(#"{"data":{"page":{"modules":[{"contentData":[{"__typename":"Game","title":"Rays at Red Sox","currentState":"live","livestreams":[{"id":"hd","title":"HD"},{"id":"alt","title":"Alternate HD"},{"id":"uhd","title":"4K"}]}]}]}},"errors":[{"message":"secret https://private.invalid/token"}]}"#.utf8)
    do {
        let result = try WatchCatalogClient.parsePage(home, linear: false)
        expect(result.items.map(\.contentID) == ["hd", "alt", "uhd"])
        expect(result.items[1].choice.title.contains("Alternate"))
        expect(result.items[2].choice.title.contains("Red Sox"))
        expect(automaticChoice(from: result.items.map(\.choice))?.id == "uhd")
        expect(result.warnings.count == 1)
        expect(!result.warnings.joined().contains("secret"))
        let ambiguous = result.items.filter { $0.contentID != "uhd" && $0.contentID != "alt" } + [WatchItem(choice: .init(id: "other", title: "Rays at Red Sox HD", kind: .liveEvent, isLive: true), contentID: "other", channelID: nil)]
        expect(automaticChoice(from: ambiguous.map(\.choice)) == nil)
    } catch { expect(false) }
    do {
        _ = try WatchCatalogClient.parsePage(Data(#"{"errors":[{"message":"private"}],"data":null}"#.utf8), linear: false)
        expect(false)
    } catch { expect((error as NSError).domain == "NESNGraphQL") }
}

private func linearFixtures() {
    let video = #""linearchannel":{"id":"linear","title":"NESN","streamingInfo":{"videoAssets":{"hls":"https://example.invalid/live.m3u8","is4K":true}}}"#
    do {
        let value = try LinearEntitlementClient.parse(Data(("{\"playable\":true," + video + "}").utf8))
        expect(value.hlsURL == "https://example.invalid/live.m3u8")
        expect(value.is4K)
    } catch { expect(false) }
    for status in ["\"success\":false,\"playable\":true", "\"success\":true,\"playable\":false"] {
        do { _ = try LinearEntitlementClient.parse(Data(("{" + status + "," + video + "}").utf8)); expect(false) }
        catch { expect((error as NSError).code == 403) }
    }
}

private func diagnosticsFixtures() {
    let error = NSError(domain: "https://secret.invalid/token", code: 99, userInfo: [NSLocalizedDescriptionKey: "Bearer TOP_SECRET", NSUnderlyingErrorKey: NSError(domain: "private", code: 1)])
    let text = safeErrorDescription(error)
    expect(!text.contains("secret") && !text.contains("TOP_SECRET") && !text.contains("Bearer"))
    expect(safeErrorDescription(NSError(domain: "NESNEntitlement", code: 403)).contains("403"))
    let session = APISession.make()
    expect(session.configuration.urlCache == nil)
    expect(session.configuration.httpCookieStorage == nil)
    expect(session.configuration.urlCredentialStorage == nil)
    expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    session.invalidateAndCancel()
}

private func ambiguousStreamsRequireChoice() {
    expect(preferredLiveStream([.init(id: "a", title: "HD"), .init(id: "b", title: "HD")]) == nil)
}

private func exactHLSAttributes() {
    let q = MasterPlaylistInspector.inspect("""
    #EXTM3U
    #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=900,BANDWIDTH=1200,RESOLUTION=3840x2160,FRAME-RATE=59.94,CODECS="hvc1.2,mp4a.40.2",VIDEO-RANGE=PQ
    https://example.invalid/hvc1/RESOLUTION=9999x9999
    #EXT-X-MEDIA:TYPE=AUDIO,CHANNELS="6/JOC",NAME="BANDWIDTH=999999"
    """)
    expect(q.maximumBandwidth == 1200)
    expect(q.maximumWidth == 3840)
    expect(q.maximumAudioChannels == 6)
    expect(q.supportsHEVC && q.supportsHDR)
    let decoy = MasterPlaylistInspector.inspect("#EXT-X-STREAM-INF:X-BANDWIDTH=999,CODECS=\"avc1\",X-VIDEO-RANGE=PQ\nhvc1.m3u8")
    expect(decoy.maximumBandwidth == 0)
    expect(!decoy.supportsHDR && !decoy.supportsHEVC)
}

private func denialWithoutVideoIsAuthorizationError() {
    do {
        _ = try Entitlement.parse(Data(#"{"success":false,"playable":false,"message":"private token"}"#.utf8))
        expect(false)
    } catch {
        expect((error as NSError).domain == "NESNEntitlement")
        expect((error as NSError).code == 403)
    }
}

