import Foundation

/// What the player is doing, as far as the bridge cares.
enum Reading: Equatable {
    case switching                        // between streams; wait
    case off                              // stopped, paused, or not NTS
    case nts(uri: String, title: String)

    var uri: String? {
        if case .nts(let uri, _) = self { uri } else { nil }
    }
}

@MainActor protocol SonosRoom: AnyObject {
    var room: String { get set }
    func currentURI() async throws -> String
    func play(_ uri: String, title: String) async throws
    func stop() async throws
    func setVolume(_ volume: Int) async throws
}

/// Turns changes on the player into Sonos commands. Same rules as atonemo_sonos.py.
@MainActor final class Bridge {
    static let stale: TimeInterval = 60  // seconds without a reading before changes stop counting

    let sonos: any SonosRoom
    var maxVolume: Int
    private(set) var uri: String?  // stream the player plays, or nil
    private var title = "NTS"
    private var volume = 0         // knob position
    private var seen: Date?        // last reading handled without error

    init(sonos: any SonosRoom, maxVolume: Int) {
        self.sonos = sonos
        self.maxVolume = maxVolume
    }

    /// Reacts to one player reading. Returns what happened, if anything.
    func step(_ reading: Reading, volume: Int, now: Date = Date()) async throws -> String? {
        let fresh = seen.map { now.timeIntervalSince($0) <= Self.stale } ?? false
        if reading == .switching {
            if fresh { seen = now }
            return nil
        }
        guard fresh else {
            // First reading, or none for a minute (Mac asleep, device offline, Sonos failing):
            // take the player as it is, so old changes never start music.
            (uri, self.volume, seen) = (reading.uri, volume, now)
            if case .nts(_, let title) = reading { self.title = title }
            return nil
        }
        var event: String?
        if reading.uri != uri {
            if case .nts(let newURI, let newTitle) = reading {
                try await start(newURI, title: newTitle, volume: volume)
                title = newTitle
                event = "\(newTitle) → Sonos"
            } else if try await ours() {
                try await sonos.stop()
                event = "Stopped"
            }
            uri = reading.uri
        } else if reading.uri != nil, volume != self.volume, try await ours() {
            try await sonos.setVolume(scale(volume))
            event = "Volume \(volume) → \(scale(volume))"
        }
        (self.volume, seen) = (volume, now)
        return event
    }

    /// Moves NTS to another room: stops it in the old room, plays it in the new one.
    func move(to room: String) async throws -> String? {
        let playing = (try? await ours()) ?? false  // the old room may be gone
        if playing { try? await sonos.stop() }
        sonos.room = room
        guard playing, let uri else { return nil }
        try await start(uri, title: title, volume: volume)
        return "\(title) → \(room)"
    }

    /// Sends the knob's volume again, e.g. after Max Volume changed. Only while Sonos plays our stream.
    func resendVolume() async throws {
        guard try await ours() else { return }
        try await sonos.setVolume(scale(volume))
    }

    func scale(_ volume: Int) -> Int { (volume * maxVolume + 50) / 100 }

    private func start(_ uri: String, title: String, volume: Int) async throws {
        do {
            try await sonos.setVolume(scale(volume))  // before Play, so it never starts loud
        } catch let error as DeviceError {  // e.g. a room with fixed volume
            logger.error("\(error.localizedDescription, privacy: .public). Playing anyway.")
        }
        try await sonos.play(uri, title: title)
    }

    private func ours() async throws -> Bool {
        guard let uri else { return false }
        return try await sonos.currentURI() == radioURI(uri)
    }
}
