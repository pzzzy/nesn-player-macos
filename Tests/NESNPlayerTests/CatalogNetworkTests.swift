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

