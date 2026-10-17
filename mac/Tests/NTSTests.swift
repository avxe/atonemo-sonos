import Foundation
import Testing
@testable import AtonemoSonos

@Test func parsesLiveShows() throws {
    let json = #"""
    {"results": [
      {"channel_name": "1", "now": {"broadcast_title": "DON&#039;T TRIP W/ MARGARITA",
        "start_timestamp": "2026-10-16T15:00:00+01:00", "end_timestamp": "2026-10-16T16:00:00+01:00",
        "embeds": {"details": {"location_long": "PHILADELPHIA"}}},
       "next": {"broadcast_title": "OH OH W KO_OL &amp; CO"}},
      {"channel_name": "2", "now": {"broadcast_title": "The Large"}}
    ]}
    """#
    let channels = try NTS.parseLive(Data(json.utf8))
    #expect(channels.map(\.name) == ["NTS 1", "NTS 2"])
    #expect(channels[0].show == "DON'T TRIP W/ MARGARITA")
    #expect(channels[0].location == "Philadelphia")
    #expect(channels[0].end!.timeIntervalSince(channels[0].start!) == 3600)
    #expect(channels[0].next == "OH OH W KO_OL & CO")
    #expect(channels[1].show == "The Large" && channels[1].next.isEmpty)
}

@Test func parsesMixtapes() throws {
    let json = #"""
    {"results": [{"mixtape_alias": "poolside", "title": "Poolside",
      "subtitle": "Balearic, boogie, and sophisti-pop.", "audio_stream_endpoint": "https://stream-mixtape-geo.ntslive.net/mixtape4",
      "media": {"icon_black": "https://media.ntslive.co.uk/crop/128x128/palm.png"}}]}
    """#
    let mixtape = try #require(NTS.parseMixtapes(Data(json.utf8)).first)
    #expect(mixtape.id == "poolside" && !mixtape.isLive)
    #expect(mixtape.icon?.lastPathComponent == "palm.png")
    #expect(mixtape.playerTitle == "NTS Poolside")  // what the knob reports
    #expect(mixtape.stream == "https://stream-mixtape-geo.ntslive.net/mixtape4?client=NTSAtonemo")
}

@Test func matchesThePlayersStream() {
    let nts2 = NTS.live[1]
    #expect(nts2.plays("https://stream-relay-geo.ntslive.net/stream2?client=NTSAtonemo"))
    #expect(nts2.plays("http://stream-relay-geo.ntslive.net/stream2"))
    #expect(!nts2.plays("https://stream-relay-geo.ntslive.net/stream"))
    #expect(!nts2.plays(nil))
    #expect(NTS.live[0].playbackSource == "channel1_0" && NTS.live[0].playerTitle == "NTS Live 1")
}

@Test func unescapesEntities() {
    #expect(NTS.unescape("Rock &amp; Roll &#8217;n&#x27; &lt;3 &bogus; &") == "Rock & Roll \u{2019}n' <3 &bogus; &")
}
