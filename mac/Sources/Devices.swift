import Foundation

let ntsService = "atonemoNts"  // serviceID the player reports for NTS streams

enum DeviceError: LocalizedError {
    case http(Int, Data)
    case sonos(String, String)
    case player(String)
    case noRoom(String)
    case badAddress(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, _): "HTTP \(code)"
        case .sonos(let action, let code): "Sonos \(action) failed (UPnP error \(code))"
        case .player(let message): "Player: \(message)"
        case .noRoom(let room): "Sonos room '\(room)' not found"
        case .badAddress(let ip): "Bad device address '\(ip)'"
        }
    }
}

func url(_ ip: String, port: Int? = nil, path: String, query: [URLQueryItem]? = nil) throws -> URL {
    var components = URLComponents()
    (components.scheme, components.host, components.port, components.path) = ("http", ip, port, path)
    components.queryItems = query
    guard let url = components.url else { throw DeviceError.badAddress(ip) }
    return url
}

private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForResource = 15  // total, so a device that drips bytes cannot stall the app
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
}()

func fetch(_ url: URL, body: Data? = nil, headers: [String: String] = [:], timeout: TimeInterval = 5) async throws -> Data {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    if let body {
        request.httpMethod = "POST"
        request.httpBody = body
    }
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let (data, response) = try await session.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 200
    guard code == 200 else { throw DeviceError.http(code, data) }
    return data
}

// MARK: - Atonemo

func ntsStream(_ data: [String: Any]) -> Reading {
    let value = data["value"] as? [String: Any] ?? [:]
    let state = value["state"] as? String
    if state == "stopped" || state == "paused" {  // a stream error stays until the next play
        return (value["streamerError"] as? [String: Any])?.isEmpty == false ? .failed : .off
    }
    guard state == "playing" else { return .switching }
    let track = value["trackRoles"] as? [String: Any] ?? [:]
    let media = track["mediaData"] as? [String: Any] ?? [:]
    let meta = media["metaData"] as? [String: Any] ?? [:]
    guard meta["serviceID"] as? String == ntsService else { return .off }  // AirPlay, Spotify, Cast...
    guard let uri = (media["resources"] as? [[String: Any]])?.first?["uri"] as? String, !uri.isEmpty else {
        return .switching
    }
    let title = track["title"] as? String ?? ""
    return .nts(uri: uri, title: title.isEmpty ? "NTS" : title)
}

/// The player's local web API (the one its app uses).
struct Player {
    var ip: String

    func get(_ path: String) async throws -> [String: Any] {
        let query = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "roles", value: "@all")]
        let data = try await fetch(url(ip, path: "/api/getData", query: query))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// Writes a value (role "value") or runs an action (role "activate"), like the player's own web page.
    func set(_ path: String, role: String, _ value: [String: Any]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["path": path, "role": role, "value": value])
        let reply = try await fetch(url(ip, path: "/api/setData"), body: body, headers: ["Content-Type": "application/json"])
        if let error = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["error"] as? [String: Any] {
            throw DeviceError.player(error["message"] as? String ?? "command failed")
        }
    }

    /// Plays an NTS stream the same way the player's buttons do, so the bridge sees a normal NTS reading.
    func play(_ channel: Channel) async throws {
        var meta: [String: Any] = ["serviceID": ntsService, "live": true]
        if let source = channel.playbackSource { meta["playbackSourceId"] = source }
        let media: [String: Any] = [
            "type": "audio", "audioType": "audioBroadcast", "title": channel.playerTitle,
            "doNotTrack": true, "persistentMetaData": true,
            "mediaData": ["metaData": meta, "resources": [["uri": channel.stream, "mimeType": "audio/unknown"]]],
        ]
        try await set("player:player/control", role: "activate", ["control": "play", "mediaRoles": media])
    }

    func stop() async throws {
        try await set("player:player/control", role: "activate", ["control": "stop"])
    }

    func setVolume(_ volume: Int) async throws {
        try await set("player:volume", role: "value", ["type": "i32_", "i32_": volume])
    }

    func read() async throws -> (Reading, Int) {
        let reading = ntsStream(try await get("player:player/data"))
        let volume = (try await get("player:volume")["value"] as? [String: Any])?["i32_"] as? Int ?? 0
        return (reading, volume)
    }
}

// MARK: - Sonos

func xmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Calls a Sonos UPnP action. Returns the response values.
@discardableResult
func soap(_ ip: String, _ service: String, _ action: String, _ args: KeyValuePairs<String, String> = [:]) async throws -> [String: String] {
    let urn = "urn:schemas-upnp-org:service:\(service):1"
    let path = service == "ZoneGroupTopology" ? "/ZoneGroupTopology/Control" : "/MediaRenderer/\(service)/Control"
    let body = args.map { "<\($0.key)>\(xmlEscape($0.value))</\($0.key)>" }.joined()
    let envelope = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:\(action) xmlns:u="\(urn)">\(body)</u:\(action)></s:Body></s:Envelope>
        """
    let headers = ["Content-Type": "text/xml; charset=\"utf-8\"", "SOAPACTION": "\"\(urn)#\(action)\""]
    do {
        return leaves(try await fetch(url(ip, port: 1400, path: path), body: Data(envelope.utf8), headers: headers, timeout: 15))
    } catch DeviceError.http(let code, let data) {
        throw DeviceError.sonos(action, leaves(data)["errorCode"] ?? String(code))
    }
}

/// Text of every element without children, by local name.
func leaves(_ xml: Data) -> [String: String] {
    final class Collector: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        private var text = ""
        private var hasChild: [Bool] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if !hasChild.isEmpty { hasChild[hasChild.count - 1] = true }
            hasChild.append(false)
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if hasChild.popLast() == false { values[String(name.split(separator: ":").last ?? "")] = text }
            text = ""
        }
    }
    let collector = Collector()
    let parser = XMLParser(data: xml)
    parser.delegate = collector
    parser.parse()
    return collector.values
}

/// ZoneGroupState XML -> [room name: ip of its group coordinator].
func parseRooms(_ zoneGroupState: String) -> [String: String] {
    final class Collector: NSObject, XMLParserDelegate {
        var rooms: [String: String] = [:]
        private var coordinator = ""
        private var members: [[String: String]] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "ZoneGroup" { (coordinator, members) = (attributes["Coordinator"] ?? "", []) }
            if name == "ZoneGroupMember" { members.append(attributes) }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == "ZoneGroup",
                  let location = members.first(where: { $0["UUID"] == coordinator })?["Location"],
                  let ip = URL(string: location)?.host else { return }
            for member in members where member["Invisible"] != "1" {  // hides the second speaker of a pair
                if let room = member["ZoneName"] { rooms[room] = ip }
            }
        }
    }
    let collector = Collector()
    let parser = XMLParser(data: Data(zoneGroupState.utf8))
    parser.delegate = collector
    parser.parse()
    return collector.rooms
}

/// Sonos plays live streams from x-rincon-mp3radio:// URIs.
func radioURI(_ uri: String) -> String {
    guard let scheme = uri.range(of: "://") else { return "x-rincon-mp3radio://" + uri }
    return "x-rincon-mp3radio://" + uri[scheme.upperBound...]
}

func didl(_ title: String) -> String {
    """
    <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
    xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
    <item id="R:0/0/0" parentID="R:0/0" restricted="true"><dc:title>\(xmlEscape(title))</dc:title>\
    <upnp:class>object.item.audioItem.audioBroadcast</upnp:class>\
    <desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON65031_</desc>\
    </item></DIDL-Lite>
    """
}

/// [room: coordinator ip] of the Sonos system that speaker `ip` belongs to.
func rooms(of ip: String) async throws -> [String: String] {
    parseRooms(try await soap(ip, "ZoneGroupTopology", "GetZoneGroupState")["ZoneGroupState"] ?? "")
}

/// [room: coordinator ip] for every Sonos system the speakers belong to.
func allRooms(_ speakers: [String]) async -> [String: String] {
    var all: [String: String] = [:]
    for ip in speakers {
        if let found = try? await rooms(of: ip) { all.merge(found) { first, _ in first } }  // asleep or gone: skip
    }
    return all
}

/// One Sonos room. Commands go to its group coordinator, found each time.
@MainActor final class Sonos: SonosRoom {
    var room: String
    var speakers: [String: String] = [:]  // room: a speaker in that room's Sonos system

    init(room: String) {
        self.room = room
    }

    func coordinator() async throws -> String {
        guard let speaker = speakers[room], let ip = try await rooms(of: speaker)[room] else {
            throw DeviceError.noRoom(room)
        }
        return ip
    }

    func currentURI() async throws -> String {
        try await soap(coordinator(), "AVTransport", "GetMediaInfo", ["InstanceID": "0"])["CurrentURI"] ?? ""
    }

    func play(_ uri: String, title: String) async throws {
        let ip = try await coordinator()
        try await soap(ip, "AVTransport", "SetAVTransportURI",
                       ["InstanceID": "0", "CurrentURI": radioURI(uri), "CurrentURIMetaData": didl(title)])
        try await soap(ip, "AVTransport", "Play", ["InstanceID": "0", "Speed": "1"])
    }

    func stop() async throws {
        try await soap(coordinator(), "AVTransport", "Stop", ["InstanceID": "0"])
    }

    func isPlaying() async throws -> Bool {
        let state = try await soap(coordinator(), "AVTransport", "GetTransportInfo", ["InstanceID": "0"])["CurrentTransportState"]
        return state == "PLAYING" || state == "TRANSITIONING"
    }

    func resume() async throws {  // same stream, from where it broke
        try await soap(coordinator(), "AVTransport", "Play", ["InstanceID": "0", "Speed": "1"])
    }

    func setVolume(_ volume: Int) async throws {
        let ip = try await coordinator()
        try await soap(ip, "GroupRenderingControl", "SnapshotGroupVolume", ["InstanceID": "0"])  // keeps the balance between grouped rooms
        try await soap(ip, "GroupRenderingControl", "SetGroupVolume", ["InstanceID": "0", "DesiredVolume": String(volume)])
    }
}
