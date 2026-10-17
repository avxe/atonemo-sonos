import Foundation

/// An NTS stream the player can play: a live channel or an Infinite Mixtape.
struct Channel: Identifiable, Equatable, Sendable {
    let id: String          // "1", "2", or the mixtape alias
    let name: String        // "NTS 1", "Poolside"
    var show = ""           // live: the show on air; mixtape: its one-line description
    var location = ""       // live only
    var start: Date?        // live only
    var end: Date?
    var next = ""           // live only: the show after this one
    var icon: URL?          // mixtape only: its pictogram
    let stream: String      // as the player plays it

    var isLive: Bool { id == "1" || id == "2" }
    var playerTitle: String { isLive ? "NTS Live \(id)" : "NTS \(name)" }  // what the knobs report
    var playbackSource: String? { isLive ? "channel\(id)_0" : nil }

    func plays(_ uri: String?) -> Bool {
        uri.map { Self.key($0) == Self.key(stream) } ?? false
    }

    /// Host and path, so "http://x/stream?client=a" matches "https://x/stream".
    static func key(_ uri: String) -> String {
        let rest = uri.range(of: "://").map { String(uri[$0.upperBound...]) } ?? uri
        return String(rest.prefix { $0 != "?" })
    }
}

enum NTS {
    private static let client = "?client=NTSAtonemo"  // the player adds this; keep URIs identical
    static let live = ["1", "2"].map {
        Channel(id: $0, name: "NTS \($0)", stream: "https://stream-relay-geo.ntslive.net/stream\($0 == "1" ? "" : $0)" + client)
    }

    /// NTS 1 and 2 with their shows on air, then the Infinite Mixtapes.
    static func channels() async throws -> [Channel] {
        async let liveData = fetch(URL(string: "https://www.nts.live/api/v2/live")!, timeout: 10)
        async let mixtapeData = fetch(URL(string: "https://www.nts.live/api/v2/mixtapes")!, timeout: 10)
        return try parseLive(await liveData) + parseMixtapes(await mixtapeData)
    }

    static func parseLive(_ data: Data) throws -> [Channel] {
        let results = try decoder.decode(Results<LiveChannel>.self, from: data).results
        return live.map { channel in
            guard let result = results.first(where: { $0.channelName == channel.id }) else { return channel }
            var channel = channel
            let now = result.now
            channel.show = unescape(now.broadcastTitle ?? "")
            channel.location = tidy(now.embeds?.details?.locationLong ?? "")
            (channel.start, channel.end) = (now.startTimestamp, now.endTimestamp)
            channel.next = unescape(result.next?.broadcastTitle ?? "")
            return channel
        }
    }

    static func parseMixtapes(_ data: Data) throws -> [Channel] {
        try decoder.decode(Results<Mixtape>.self, from: data).results.map {
            Channel(id: $0.mixtapeAlias, name: unescape($0.title), show: unescape($0.subtitle ?? ""),
                    icon: $0.media?.iconBlack, stream: $0.audioStreamEndpoint + client)
        }
    }

    // MARK: - API shapes (https://www.nts.live/api/v2/live and /mixtapes)

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private struct Results<T: Decodable>: Decodable { let results: [T] }
    private struct LiveChannel: Decodable {
        let channelName: String
        let now: Broadcast
        let next: Broadcast?
    }
    private struct Broadcast: Decodable {
        let broadcastTitle: String?
        let startTimestamp: Date?
        let endTimestamp: Date?
        let embeds: Embeds?
    }
    private struct Embeds: Decodable { let details: Details? }
    private struct Details: Decodable { let locationLong: String? }
    private struct Media: Decodable { let iconBlack: URL? }
    private struct Mixtape: Decodable {
        let mixtapeAlias: String
        let title: String
        let subtitle: String?
        let audioStreamEndpoint: String
        let media: Media?
    }

    /// "DON&#039;T TRIP" -> "DON'T TRIP". NTS titles carry HTML entities.
    static func unescape(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = "", rest = Substring(text)
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#039": "'"]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            if let semi = rest.prefix(10).firstIndex(of: ";") {
                let entity = String(rest[rest.index(after: rest.startIndex)..<semi])
                let number = entity.hasPrefix("#x") ? Int(entity.dropFirst(2), radix: 16)
                    : entity.hasPrefix("#") ? Int(entity.dropFirst()) : nil
                let decoded = named[entity] ?? number.flatMap(UnicodeScalar.init).map { String(Character($0)) }
                if let decoded {
                    out += decoded
                    rest = rest[rest.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = rest.dropFirst()
        }
        return out + rest
    }

    /// "PHILADELPHIA" -> "Philadelphia"; mixed case stays as it is.
    static func tidy(_ place: String) -> String {
        place == place.uppercased() ? place.capitalized : place
    }
}
