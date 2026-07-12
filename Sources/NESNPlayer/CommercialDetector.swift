import Foundation

struct CommercialState: Equatable {
    let isCommercial: Bool
    let elapsed: Double?
}

enum SCTE35Parser {
    static func state(in playlist: String) -> CommercialState {
        // Harmonic/Transmit repeats TYPE=0x36 with increasing ELAPSED while an
        // avail is active, and emits TYPE=0x37 when program content resumes.
        let markers = playlist.split(separator: "\n").filter { $0.hasPrefix("#EXT-X-SCTE35:") }
        guard let last = markers.last else { return CommercialState(isCommercial: false, elapsed: nil) }
        let line = String(last)
        if line.contains("TYPE=0x37") { return CommercialState(isCommercial: false, elapsed: nil) }
        guard line.contains("TYPE=0x36") else { return CommercialState(isCommercial: false, elapsed: nil) }
        let elapsed = line.range(of: #"ELAPSED=([0-9.]+)"#, options: .regularExpression).flatMap {
            Double(line[$0].dropFirst("ELAPSED=".count))
        }
        return CommercialState(isCommercial: true, elapsed: elapsed)
    }
}

actor CommercialDetector {
    private let session: URLSession
    private let masterURL: URL
    private var mediaURL: URL?

    init(masterURL: URL, session: URLSession = .shared) {
        self.masterURL = masterURL
        self.session = session
    }

    func poll() async throws -> CommercialState {
        if mediaURL == nil { mediaURL = try await highestVideoPlaylist() }
        guard let mediaURL else { return CommercialState(isCommercial: false, elapsed: nil) }
        var request = URLRequest(url: mediaURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "CommercialDetector", code: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return SCTE35Parser.state(in: String(decoding: data, as: UTF8.self))
    }

    private func highestVideoPlaylist() async throws -> URL? {
        let (data, _) = try await session.data(from: masterURL)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        var best: (bandwidth: Int, url: URL)?
        for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
            guard index + 1 < lines.count else { continue }
            let info = lines[index]
            let bandwidth = info.range(of: #"BANDWIDTH=(\d+)"#, options: .regularExpression).flatMap {
                Int(info[$0].dropFirst("BANDWIDTH=".count))
            } ?? 0
            guard let url = URL(string: lines[index + 1], relativeTo: masterURL)?.absoluteURL else { continue }
            if best == nil || bandwidth > best!.bandwidth { best = (bandwidth, url) }
        }
        return best?.url
    }
}
