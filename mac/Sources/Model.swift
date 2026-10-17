import AppKit
import os
import ServiceManagement
import SwiftUI

let logger = Logger(subsystem: "io.github.avxe.atonemo-sonos", category: "bridge")

/// What the Sonos room is doing.
enum SonosState: Equatable {
    case unknown, ours, tv, other, stopped, unreachable
}

/// What the panel shows, plus the bridge loop. Main actor only; every network call is async.
@MainActor @Observable final class AppModel {
    // Connection. `status` is empty when all is well; otherwise a note or an error for the footer.
    private(set) var searching = true
    private(set) var status = ""
    private(set) var statusIsError = false

    // Player
    private(set) var playerURI: String?  // NTS stream the player plays; nil when it plays none
    private(set) var playerTitle = ""
    private(set) var currentID: String?  // the channel playing, if it is one we know
    private(set) var lastID: String?     // the channel played last; shown while stopped, and Play resumes it
    private(set) var volume = 0          // the volume knob, 0-100

    // NTS
    private(set) var channels = NTS.live {
        didSet { updateCurrent() }
    }
    private(set) var glyphs = ["1", "2"].reduce(into: [String: NSImage]()) { $0[$1] = Glyphs.numeral($1) }  // channel id → key pictogram

    // Sonos
    private(set) var rooms: [String] = []
    private(set) var sonosState = SonosState.unknown  // refreshed while the panel is open

    // Settings
    var room = UserDefaults.standard.string(forKey: "room") ?? "" {
        didSet { UserDefaults.standard.set(room, forKey: "room"); kick() }  // the loop moves the music
    }
    var maxVolume = UserDefaults.standard.object(forKey: "maxVolume") as? Int ?? 30 {
        didSet {
            UserDefaults.standard.set(maxVolume, forKey: "maxVolume")
            bridge?.maxVolume = maxVolume
            resendVolume = true
            kick()
        }
    }
    var bridgeHere = UserDefaults.standard.object(forKey: "bridgeHere") as? Bool ?? true {
        didSet { UserDefaults.standard.set(bridgeHere, forKey: "bridgeHere"); kick() }
    }
    private(set) var openAtLogin = AppModel.loginItemOn

    var current: Channel? { currentID.flatMap { id in channels.first { $0.id == id } } }
    var last: Channel? { lastID.flatMap { id in channels.first { $0.id == id } } }
    var isPlaying: Bool { playerURI != nil }
    var sonosVolume: Int { (volume * maxVolume + 50) / 100 }

    @ObservationIgnored private var player: Player?
    @ObservationIgnored private var sonos: Sonos?
    @ObservationIgnored private var bridge: Bridge?
    @ObservationIgnored private var lastConnect = Date.distantPast
    @ObservationIgnored private var forceConnect = false
    @ObservationIgnored private var resendVolume = false
    @ObservationIgnored private var nap: Task<Void, Never>?
    @ObservationIgnored private var kicked = false
    @ObservationIgnored private var errorUntil = Date.distantPast
    @ObservationIgnored private var lastLogged: (text: String, at: Date)?
    @ObservationIgnored private var expected: (uri: String?, until: Date)?  // a click the player hasn't shown yet
    @ObservationIgnored private var lastCommand = Date.distantPast
    @ObservationIgnored private var nextCommand: Command?
    @ObservationIgnored private var commandDelay = Duration.zero
    @ObservationIgnored private var commandSerial = 0
    @ObservationIgnored private var commandSender: Task<Void, Never>?
    @ObservationIgnored private var volumeHold = Date.distantPast
    @ObservationIgnored private var volumeToSend: Int?
    @ObservationIgnored private var volumeSender: Task<Void, Never>?
    @ObservationIgnored private var panelTask: Task<Void, Never>?
    @ObservationIgnored private var glyphSources: [String: URL] = [:]  // channel id → icon shown or loading
    @ObservationIgnored private let activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Follows the player's knobs")  // no App Nap

    private enum Command {
        case play(Channel)
        case stop
    }

    init() {
        Task { await run() }
        Task { await refreshChannels() }
    }

    // MARK: - Actions from the panel

    func play(_ channel: Channel, after delay: Duration = .zero) {
        logger.notice("Panel: play \(channel.name, privacy: .public)")
        show(uri: channel.stream, title: channel.playerTitle)  // answer the click at once
        expected = (channel.stream, Date() + 3)
        send(.play(channel), after: delay)
    }

    func stop() {
        logger.notice("Panel: stop")
        show(uri: nil, title: "")
        expected = (nil, Date() + 3)
        send(.stop)
    }

    func togglePlay() {
        if isPlaying {
            stop()
        } else if let channel = last ?? channels.first {
            play(channel)
        }
    }

    /// The next or previous channel in panel order. Waits for the key to settle before the player switches.
    func skip(_ offset: Int) {
        guard !channels.isEmpty else { return }
        let index = channels.firstIndex { $0.id == currentID } ?? (offset > 0 ? -1 : 0)
        play(channels[(index + offset + channels.count) % channels.count], after: .milliseconds(250))
    }

    /// Turns the player's volume knob. At most one command per 60 ms; the last value always goes out.
    func setVolume(_ value: Int) {
        let value = min(max(value, 0), 100)
        guard value != volume, let player else { return }
        volume = value
        volumeHold = Date() + 1.5  // don't let a slow reading move the slider back
        volumeToSend = value
        guard volumeSender == nil else { return }
        volumeSender = Task {
            var sent = value
            while let next = volumeToSend {
                volumeToSend = nil
                do { try await player.setVolume(next) } catch { report(error) }
                sent = next
                kick()
                try? await Task.sleep(for: .milliseconds(60))
            }
            logger.notice("Panel: volume \(sent)")  // once per drag or key press, not per step
            volumeSender = nil
        }
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            report(error)
        }
        openAtLogin = Self.loginItemOn
        if SMAppService.mainApp.status == .requiresApproval {
            note("Approve it in System Settings → General → Login Items")
        }
    }

    func retry() {
        forceConnect = true
        kick()
    }

    func panelOpened() {
        guard panelTask == nil else { return }
        panelTask = Task {
            while !Task.isCancelled {
                await refreshSonosState()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        kick()
    }

    func panelClosed() {
        panelTask?.cancel()
        panelTask = nil
    }

    // MARK: - Loops

    private func run() async {
        var readErrors = 0, sonosErrors = 0
        while true {
            let sonosMissing = sonos == nil && Date().timeIntervalSince(lastConnect) > 30
            if player == nil || forceConnect || readErrors >= 6 || sonosErrors >= 10 || sonosMissing {
                forceConnect = false
                await connect()  // first start, Try Again, DHCP may have moved a device, or Sonos was missing
                (readErrors, sonosErrors) = (0, 0)
            }
            guard let player else {
                await rest(.seconds(searching ? 3 : 10))  // never found yet: look again soon
                continue
            }
            let reading: Reading, knob: Int
            do {
                (reading, knob) = try await player.read()
                readErrors = 0
                if searching { searching = false }
            } catch {
                readErrors += 1
                report(error)
                await rest(.seconds(3))
                continue
            }
            show(reading, knob)
            do {
                try await followOnSonos(reading, knob)
                sonosErrors = 0
                clearError()
            } catch {
                sonosErrors += 1  // keep reading the player; only Sonos is failing
                report(error)
            }
            await rest(.milliseconds(500))
        }
    }

    private func followOnSonos(_ reading: Reading, _ knob: Int) async throws {
        guard let sonos, let bridge else { return }
        if sonos.room != room {
            if bridgeHere, let event = try await bridge.move(to: room) {
                logger.notice("\(event, privacy: .public)")
            } else {
                sonos.room = room
            }
        }
        guard bridgeHere else { return }
        if resendVolume {
            resendVolume = false
            try await bridge.resendVolume()
        }
        if let event = try await bridge.step(reading, volume: knob) {
            logger.notice("\(event, privacy: .public)")
            if panelTask != nil { Task { await refreshSonosState() } }
        }
    }

    private func connect() async {
        lastConnect = Date()
        let found = await discover()
        logger.notice("Found players \(found.players, privacy: .public), Sonos \(found.sonos, privacy: .public)")
        if let playerIP = found.players.first {
            player = Player(ip: playerIP)
            UserDefaults.standard.set(playerIP, forKey: "playerIP")
        } else if player == nil, let saved = UserDefaults.standard.string(forKey: "playerIP"),
                  (try? await Player(ip: saved).get("player:volume")) != nil {
            player = Player(ip: saved)  // Bonjour missed it, but it still answers where it was
        } else if player == nil {
            note("No player found. Same Wi-Fi? Local network allowed?")
            return
        }  // else keep the last address; it may still work
        let roomIPs = await allRooms(found.sonos)
        guard !roomIPs.isEmpty else {
            note("No Sonos found. Same Wi-Fi? Local network allowed?")
            return
        }
        rooms = roomIPs.keys.sorted()
        if room.isEmpty { room = rooms[0] }  // first start; never replace a saved room
        if sonos == nil {
            let sonos = Sonos(room: room)
            (self.sonos, bridge) = (sonos, Bridge(sonos: sonos, maxVolume: maxVolume))
        }
        sonos?.speakers = roomIPs
        if roomIPs[room] == nil {
            note("Sonos room '\(room)' not found")
        } else if !statusIsError {
            status = ""
        }
    }

    /// NTS show info and mixtape icons. Separate from the bridge loop, so a slow NTS site never delays Sonos.
    private func refreshChannels() async {
        while true {
            var wait = Duration.seconds(60)  // retry soon if NTS is unreachable
            if let fresh = try? await NTS.channels(), !fresh.isEmpty {
                if fresh != channels { channels = fresh }
                for channel in fresh where channel.icon != nil { Task { await loadGlyph(channel) } }
                let nextShow = fresh.compactMap(\.end).filter { $0 > Date() }.min()
                let seconds = min(300, (nextShow?.timeIntervalSinceNow ?? 300) + 10)  // right after a show ends
                wait = .seconds(max(30, seconds))
            }
            try? await Task.sleep(for: wait)
        }
    }

    /// A mixtape's icon, polished for its key. Kept on disk, so the keys are complete at once on the next start.
    private func loadGlyph(_ channel: Channel) async {
        guard let url = channel.icon, glyphSources[channel.id] != url else { return }
        glyphSources[channel.id] = url
        let file = Self.glyphCache.appending(path: url.lastPathComponent)  // NTS names icons by content
        if let data = try? Data(contentsOf: file), let glyph = Glyphs.polish(data) {
            glyphs[channel.id] = glyph
        } else if let data = try? await fetch(url, timeout: 15), let glyph = Glyphs.polish(data) {
            glyphs[channel.id] = glyph
            try? FileManager.default.createDirectory(at: Self.glyphCache, withIntermediateDirectories: true)
            try? data.write(to: file)
        } else {
            glyphSources[channel.id] = nil  // try again on the next refresh
        }
    }

    private static let glyphCache = URL.cachesDirectory.appending(path: "io.github.avxe.atonemo-sonos/icons")

    private func refreshSonosState() async {
        guard let sonos else { return }
        let state: SonosState
        do {
            let ip = try await sonos.coordinator()
            async let media = soap(ip, "AVTransport", "GetMediaInfo", ["InstanceID": "0"])
            async let transport = soap(ip, "AVTransport", "GetTransportInfo", ["InstanceID": "0"])
            let (mediaInfo, transportInfo) = try await (media, transport)
            let uri = mediaInfo["CurrentURI"] ?? ""
            let transportState = transportInfo["CurrentTransportState"] ?? ""
            if uri.hasPrefix("x-sonos-htastream:") {
                state = .tv
            } else if transportState == "PLAYING" || transportState == "TRANSITIONING" {
                state = playerURI.map(radioURI) == uri ? .ours : .other
            } else {
                state = .stopped
            }
        } catch {
            state = .unreachable
        }
        // Skip while the panel closes, and while Sonos is still catching up with a click.
        guard !Task.isCancelled, panelTask != nil, Date().timeIntervalSince(lastCommand) > 2.5 || state == .ours else { return }
        if state != sonosState { withAnimation(.smooth(duration: 0.25)) { sonosState = state } }
    }

    // MARK: - Helpers

    /// One player command at a time; a newer one replaces any that hasn't gone out yet.
    private func send(_ command: Command, after delay: Duration = .zero) {
        (nextCommand, commandDelay, lastCommand) = (command, delay, Date())
        commandSerial += 1
        guard commandSender == nil, let player else { return }
        commandSender = Task {
            while let command = nextCommand {
                if commandDelay > .zero {
                    let serial = commandSerial
                    try? await Task.sleep(for: commandDelay)
                    if serial != commandSerial { continue }  // a newer press came in; let it settle
                }
                nextCommand = nil
                do {
                    switch command {
                    case .play(let channel): try await player.play(channel)
                    case .stop: try await player.stop()
                    }
                } catch {
                    expected = nil  // show what the player really does
                    report(error)
                }
                kick()
            }
            commandSender = nil
        }
    }

    private func show(_ reading: Reading, _ knob: Int) {
        if reading != .switching {
            if let expected, Date() < expected.until, Channel.key(reading.uri ?? "") != Channel.key(expected.uri ?? "") {
                // The player hasn't caught up with a click yet; keep showing the click.
            } else {
                expected = nil
                if case .nts(let uri, let title) = reading { show(uri: uri, title: title) } else { show(uri: nil, title: "") }
            }
        }
        if Date() > volumeHold, knob != volume { volume = knob }
    }

    private func show(uri: String?, title: String) {
        if playerURI != uri { playerURI = uri }
        if playerTitle != title { playerTitle = title }
        updateCurrent()
    }

    private func updateCurrent() {
        let id = channels.first { $0.plays(playerURI) }?.id
        if id != currentID { currentID = id }
        if let id, id != lastID { lastID = id }
    }

    private func report(_ error: Error) {
        let text = error.localizedDescription
        if lastLogged.map({ $0.text != text || Date() > $0.at + 60 }) ?? true {  // a device offline for hours logs once a minute
            logger.error("\(text, privacy: .public)")
            lastLogged = (text, Date())
        }
        (status, statusIsError, errorUntil) = (text, true, Date() + 4)  // readable for 4 s
    }

    private func note(_ text: String) {
        (status, statusIsError) = (text, false)
    }

    private func clearError() {
        if statusIsError, Date() > errorUntil { (status, statusIsError) = ("", false) }
    }

    /// Sleeps, unless `kick()` wakes it early or already asked for a wake-up.
    private func rest(_ duration: Duration) async {
        if kicked {
            kicked = false
            return
        }
        let nap = Task { _ = try? await Task.sleep(for: duration) }
        self.nap = nap
        await nap.value
        kicked = false
    }

    private func kick() {
        kicked = true
        nap?.cancel()
    }

    private static var loginItemOn: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }
}
