import Foundation
import Network

// Bonjour, not SSDP: macOS sends and receives the multicast itself,
// so the app needs no incoming connections through the firewall.

/// Atonemo players and Sonos speakers on the network, as IPv4 addresses.
func discover() async -> (players: [String], sonos: [String]) {
    async let casts = browse("_googlecast._tcp")
    async let speakers = browse("_sonos._tcp")
    let sonos = Set(await speakers.compactMap { $0.txt["location"].flatMap { URL(string: $0)?.host } })
    var players: [String] = []
    for cast in await casts.sorted(by: { $0.isNTS && !$1.isNTS }) {  // NTS Radio Player first
        guard let ip = await ipv4(of: cast.endpoint),
              (try? await Player(ip: ip).get("player:volume")) != nil  // has the player's web API
        else { continue }
        players.append(ip)
    }
    return (players, sonos.sorted())
}

struct Service: Sendable {
    let endpoint: NWEndpoint
    let txt: [String: String]
    var isNTS: Bool { txt["md"]?.contains("NTS") == true }
}

/// Every service of a Bonjour type seen within `wait`.
func browse(_ type: String, wait: Duration = .seconds(3)) async -> [Service] {
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
    let found = Locked<[Service]>([])
    browser.stateUpdateHandler = { state in
        switch state {
        case .waiting(let error), .failed(let error):
            logger.error("Browsing \(type, privacy: .public): \(error.localizedDescription, privacy: .public)")
        default:
            break
        }
    }
    browser.browseResultsChangedHandler = { results, _ in
        found.value = results.map { result in
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            return Service(endpoint: result.endpoint, txt: txt)
        }
    }
    browser.start(queue: .global())
    try? await Task.sleep(for: wait)
    browser.cancel()
    return found.value
}

/// Resolves a Bonjour service to an IPv4 address by connecting to it.
func ipv4(of endpoint: NWEndpoint) async -> String? {
    let parameters = NWParameters.tcp
    (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
    let connection = NWConnection(to: endpoint, using: parameters)
    let resumed = Locked(false)
    return await withCheckedContinuation { continuation in
        @Sendable func finish(_ ip: String?) {
            guard !resumed.swap(true) else { return }
            continuation.resume(returning: ip)
            connection.cancel()
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case .hostPort(.ipv4(let address), _) = connection.currentPath?.remoteEndpoint {
                    finish(address.rawValue.map(String.init).joined(separator: "."))  // "\(address)" adds "%en0"
                } else {
                    finish(nil)
                }
            case .waiting, .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
    }
}

/// A value shared between Network callbacks and async code.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Sets a new value and returns the old one.
    func swap(_ newValue: Value) -> Value {
        lock.withLock {
            defer { stored = newValue }
            return stored
        }
    }
}
