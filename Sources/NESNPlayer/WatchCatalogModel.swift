import Foundation

enum WatchKind: Int, Equatable {
    case liveEvent = 0
    case linearChannel = 1
    case replay = 2
}

struct WatchChoice: Equatable {
    let id: String
    let title: String
    let kind: WatchKind
    let isLive: Bool
    var channelID: String? = nil
}

func isFullGameReplay(title: String) -> Bool {
    let lower = title.lowercased()
    return lower.contains("replay") && !lower.contains("highlight")
}

func automaticChoice(from choices: [WatchChoice]) -> WatchChoice? {
    let liveRedSox = choices.filter {
        $0.kind == .liveEvent && $0.isLive && $0.title.localizedCaseInsensitiveContains("Red Sox")
    }
    let ultraHD = liveRedSox.filter {
        $0.title.localizedCaseInsensitiveContains("4K") || $0.title.localizedCaseInsensitiveContains("UHD")
    }
    if ultraHD.count == 1 { return ultraHD[0] }
    if liveRedSox.count == 1 { return liveRedSox[0] }
    return nil
}

func chooserChoices(from choices: [WatchChoice]) -> [WatchChoice] {
    var seen = Set<String>()
    return choices.enumerated()
        .filter { seen.insert($0.element.id).inserted }
        .sorted {
            if $0.element.kind.rawValue != $1.element.kind.rawValue {
                return $0.element.kind.rawValue < $1.element.kind.rawValue
            }
            return $0.offset < $1.offset
        }
        .map(\.element)
}
