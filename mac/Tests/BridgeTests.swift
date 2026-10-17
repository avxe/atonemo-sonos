import Foundation
import Testing
@testable import AtonemoSonos

@MainActor final class FakeSonos: SonosRoom {
    var room = "Living Room"
    var nowPlaying: [String: String] = [:]  // room: uri
    var calls: [String] = []
    var refuseVolume = false
    var playing = true

    func currentURI() async throws -> String { nowPlaying[room] ?? "" }
    func isPlaying() async throws -> Bool { playing }
    func resume() async throws { calls.append("resume \(room)") }
    func play(_ uri: String, title: String) async throws {
        calls.append("play \(title) in \(room)")
        nowPlaying[room] = radioURI(uri)
    }
    func stop() async throws {
        calls.append("stop \(room)")
        nowPlaying[room] = nil
    }
    func setVolume(_ volume: Int) async throws {
        if refuseVolume { throw DeviceError.sonos("SetGroupVolume", "800") }
        calls.append("volume \(volume)")
    }
}

let nts1 = Reading.nts(uri: "https://stream-relay-geo.ntslive.net/stream?client=NTSAtonemo", title: "NTS Live 1")
let nts2 = Reading.nts(uri: "https://stream-relay-geo.ntslive.net/stream2?client=NTSAtonemo", title: "NTS Live 2")
let t0 = Date(timeIntervalSince1970: 0)

@MainActor func started(_ sonos: FakeSonos) async throws -> Bridge {
    let bridge = Bridge(sonos: sonos, maxVolume: 30)
    _ = try await bridge.step(.off, volume: 50, now: t0)  // bridge starts, player stopped
    return bridge
}

@MainActor @Test func startNeverPlays() async throws {
    let sonos = FakeSonos()
    let bridge = Bridge(sonos: sonos, maxVolume: 30)
    _ = try await bridge.step(nts1, volume: 50, now: t0)
    #expect(sonos.calls.isEmpty)
    _ = try await bridge.step(nts2, volume: 50, now: t0 + 1)
    #expect(sonos.calls == ["volume 15", "play NTS Live 2 in Living Room"])
}

@MainActor @Test func knobsDriveSonos() async throws {
    let sonos = FakeSonos()
    let bridge = try await started(sonos)
    _ = try await bridge.step(nts1, volume: 50, now: t0 + 1)
    _ = try await bridge.step(.switching, volume: 50, now: t0 + 2)
    _ = try await bridge.step(nts1, volume: 100, now: t0 + 3)
    _ = try await bridge.step(.off, volume: 100, now: t0 + 4)
    #expect(sonos.calls == ["volume 15", "play NTS Live 1 in Living Room", "volume 30", "stop Living Room"])
}

@MainActor @Test func leavesTVAlone() async throws {
    let sonos = FakeSonos()
    let bridge = try await started(sonos)
    _ = try await bridge.step(nts1, volume: 50, now: t0 + 1)
    sonos.nowPlaying["Living Room"] = "x-sonos-htastream:RINCON_000000000001:spdif"
    _ = try await bridge.step(nts1, volume: 80, now: t0 + 2)
    _ = try await bridge.step(.off, volume: 80, now: t0 + 3)
    #expect(sonos.calls == ["volume 15", "play NTS Live 1 in Living Room"])
}

@MainActor @Test func streamErrorKeepsSonosPlaying() async throws {
    let sonos = FakeSonos()
    let bridge = try await started(sonos)
    var tries = 0
    bridge.resumePlayer = { _ in tries += 1 }
    _ = try await bridge.step(nts1, volume: 50, now: t0 + 1)
    _ = try await bridge.step(.failed, volume: 50, now: t0 + 2)  // the player's stream broke; nobody pressed stop
    #expect(tries == 0)  // waits 3 s first
    for t in 3..<120 { _ = try await bridge.step(.failed, volume: 50, now: t0 + TimeInterval(t)) }
    #expect(tries == 3)  // at 5, 17 and 47 s, then it leaves it
    #expect(!sonos.calls.contains { $0.hasPrefix("stop") })
}

@MainActor @Test func resumedStreamRestartsSonosOnlyIfItStopped() async throws {
    let sonos = FakeSonos()
    let bridge = try await started(sonos)
    bridge.resumePlayer = { _ in }
    _ = try await bridge.step(nts1, volume: 50, now: t0 + 1)
    _ = try await bridge.step(.failed, volume: 50, now: t0 + 2)
    _ = try await bridge.step(.failed, volume: 50, now: t0 + 5)
    _ = try await bridge.step(nts1, volume: 50, now: t0 + 7)  // the player has it back, Sonos never stopped
    #expect(!sonos.calls.contains("resume Living Room"))
    _ = try await bridge.step(.failed, volume: 50, now: t0 + 8)
    sonos.playing = false  // this time Sonos lost the stream too
    _ = try await bridge.step(nts1, volume: 50, now: t0 + 12)
    #expect(sonos.calls.last == "resume Living Room")
}

@MainActor @Test func streamErrorAtStartCountsAsStopped() async throws {
    let sonos = FakeSonos()
    let bridge = Bridge(sonos: sonos, maxVolume: 30)
    bridge.resumePlayer = { _ in Issue.record("nothing to resume") }
    _ = try await bridge.step(.failed, volume: 50, now: t0)
    _ = try await bridge.step(.failed, volume: 50, now: t0 + 10)
    _ = try await bridge.step(nts1, volume: 50, now: t0 + 11)  // a button press plays as usual
    #expect(sonos.calls == ["volume 15", "play NTS Live 1 in Living Room"])
}

@MainActor @Test func oldChangeNeverPlays() async throws {
    let sonos = FakeSonos()
    let bridge = try await started(sonos)
    _ = try await bridge.step(nts1, volume: 50, now: t0 + 3600)  // Mac slept for an hour
    #expect(sonos.calls.isEmpty)
    _ = try await bridge.step(nts2, volume: 50, now: t0 + 3601)
    #expect(sonos.calls == ["volume 15", "play NTS Live 2 in Living Room"])
}

@MainActor @Test func refusedVolumeStillPlays() async throws {
    let sonos = FakeSonos()
    sonos.refuseVolume = true
    let bridge = try await started(sonos)
    _ = try await bridge.step(nts1, volume: 50, now: t0 + 1)
    #expect(sonos.calls == ["play NTS Live 1 in Living Room"])
}

@MainActor @Test func roomChangeMovesTheMusic() async throws {
    let sonos = FakeSonos()
    let bridge = try await started(sonos)
    _ = try await bridge.step(nts1, volume: 50, now: t0 + 1)
    let event = try await bridge.move(to: "Kitchen")
    #expect(event == "NTS Live 1 → Kitchen")
    #expect(sonos.calls.suffix(3) == ["stop Living Room", "volume 15", "play NTS Live 1 in Kitchen"])
    _ = try await bridge.step(.off, volume: 50, now: t0 + 2)
    #expect(sonos.calls.last == "stop Kitchen")
}

@MainActor @Test func roomChangeWhileIdleOnlySwitches() async throws {
    let sonos = FakeSonos()
    let bridge = try await started(sonos)
    #expect(try await bridge.move(to: "Kitchen") == nil)
    #expect(sonos.calls.isEmpty && sonos.room == "Kitchen")
}

@Test func parsesPlayer() {
    let data: [String: Any] = ["value": ["state": "playing", "trackRoles": ["title": "NTS Live 2", "mediaData": [
        "resources": [["uri": "https://stream-relay-geo.ntslive.net/stream2"]], "metaData": ["serviceID": "atonemoNts"]]]]]
    #expect(ntsStream(data) == .nts(uri: "https://stream-relay-geo.ntslive.net/stream2", title: "NTS Live 2"))
    #expect(ntsStream(["value": ["state": "stopped"]]) == .off)
    #expect(ntsStream(["value": ["state": "stopped", "streamerError": [String: Any]()]]) == .off)  // a stop press
    #expect(ntsStream(["value": ["state": "stopped", "streamerError": ["domain": "gstreamerResourceError", "code": -19]]]) == .failed)
    #expect(ntsStream(["value": ["state": "transitioning"]]) == .switching)
    #expect(ntsStream(["value": NSNull()]) == .switching)
    let untitled: [String: Any] = ["value": ["state": "playing", "trackRoles": ["title": "", "mediaData": [
        "resources": [["uri": "https://x/stream"]], "metaData": ["serviceID": "atonemoNts"]]]]]
    #expect(ntsStream(untitled) == .nts(uri: "https://x/stream", title: "NTS"))
}

@Test func parsesRooms() {
    let xml = """
        <ZoneGroupState><ZoneGroups>
        <ZoneGroup Coordinator="RINCON_A"><ZoneGroupMember UUID="RINCON_A" Location="http://10.0.0.10:1400/x.xml" ZoneName="Living Room">\
        <Satellite UUID="RINCON_B" Location="http://10.0.0.11:1400/x.xml" ZoneName="Living Room" Invisible="1"/></ZoneGroupMember></ZoneGroup>
        <ZoneGroup Coordinator="RINCON_D"><ZoneGroupMember UUID="RINCON_C" Location="http://10.0.0.12:1400/x.xml" ZoneName="Kitchen"/>\
        <ZoneGroupMember UUID="RINCON_D" Location="http://10.0.0.13:1400/x.xml" ZoneName="Bedroom"/></ZoneGroup>
        </ZoneGroups></ZoneGroupState>
        """
    #expect(parseRooms(xml) == ["Living Room": "10.0.0.10", "Kitchen": "10.0.0.13", "Bedroom": "10.0.0.13"])
}

@Test func soapResponseValues() {
    let xml = #"<s:Envelope xmlns:s="x"><s:Body><u:GetMediaInfoResponse xmlns:u="y"><NrTracks>1</NrTracks><CurrentURI>x-rincon-mp3radio://a/b?c=1&amp;d=2</CurrentURI></u:GetMediaInfoResponse></s:Body></s:Envelope>"#
    #expect(leaves(Data(xml.utf8))["CurrentURI"] == "x-rincon-mp3radio://a/b?c=1&d=2")
}

@Test func deviceURLs() throws {
    #expect(try url("192.168.1.5", port: 1400, path: "/x").absoluteString == "http://192.168.1.5:1400/x")
    #expect(throws: DeviceError.self) { try url("192.168.1.5%en0", path: "/x") }
}
