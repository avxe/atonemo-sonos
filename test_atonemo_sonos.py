import unittest

from atonemo_sonos import FAILED, SWITCHING, Bridge, didl, nts_stream, parse_rooms, radio_uri

NTS1 = "https://stream-relay-geo.ntslive.net/stream?client=NTSAtonemo"
NTS2 = "https://stream-relay-geo.ntslive.net/stream2?client=NTSAtonemo"
TV = "x-sonos-htastream:RINCON_000000000001:spdif"


def player_data(state, uri=NTS1, title="NTS Live 1", service="atonemoNts"):
    """Trimmed copy of the player's player:player/data reply."""
    return {"path": "player:player/externalData", "value": {"state": state, "trackRoles": {
        "title": title, "audioType": "audioBroadcast",
        "mediaData": {"resources": [{"uri": uri}], "metaData": {"serviceID": service, "live": True}}}}}


class FakeSonos:
    def __init__(self):
        self.now_playing, self.calls, self.is_playing = "", [], True

    def current_uri(self):
        return self.now_playing

    def playing(self):
        return self.is_playing

    def resume(self):
        self.calls.append(("resume",))

    def play(self, uri, title):
        self.calls.append(("play", title))
        self.now_playing = radio_uri(uri)

    def stop(self):
        self.calls.append(("stop",))

    def set_volume(self, volume):
        self.calls.append(("volume", volume))


class PlayerParsing(unittest.TestCase):
    def test_nts_playing(self):
        self.assertEqual(nts_stream(player_data("playing")), (NTS1, "NTS Live 1"))

    def test_stopped_and_paused(self):
        self.assertIsNone(nts_stream(player_data("stopped")))
        self.assertIsNone(nts_stream(player_data("paused")))
        self.assertIsNone(nts_stream({"value": {"state": "stopped", "trackRoles": {}}}))

    def test_switching(self):
        self.assertEqual(nts_stream(player_data("transitioning")), SWITCHING)

    def test_stream_error(self):
        broken = {"value": {"state": "stopped", "streamerError": {"domain": "gstreamerResourceError", "code": -19}}}
        self.assertEqual(nts_stream(broken), FAILED)
        self.assertIsNone(nts_stream({"value": {"state": "stopped", "streamerError": {}}}))  # a stop press

    def test_other_source(self):
        self.assertIsNone(nts_stream(player_data("playing", service="airplay")))

    def test_nulls_and_empty_values(self):
        self.assertEqual(nts_stream({"value": None}), SWITCHING)
        self.assertIsNone(nts_stream({"value": {"state": "playing", "trackRoles": {"mediaData": None}}}))
        self.assertEqual(nts_stream(player_data("playing", title="")), (NTS1, "NTS"))
        self.assertEqual(nts_stream(player_data("playing", uri="")), SWITCHING)


class Topology(unittest.TestCase):
    XML = """<ZoneGroupState><ZoneGroups>
      <ZoneGroup Coordinator="RINCON_A" ID="RINCON_A:1">
        <ZoneGroupMember UUID="RINCON_A" Location="http://10.0.0.10:1400/xml/device_description.xml" ZoneName="Living Room">
          <Satellite UUID="RINCON_B" Location="http://10.0.0.11:1400/xml/device_description.xml" ZoneName="Living Room" Invisible="1"/>
        </ZoneGroupMember>
      </ZoneGroup>
      <ZoneGroup Coordinator="RINCON_D" ID="RINCON_D:2">
        <ZoneGroupMember UUID="RINCON_C" Location="http://10.0.0.12:1400/xml/device_description.xml" ZoneName="Kitchen"/>
        <ZoneGroupMember UUID="RINCON_D" Location="http://10.0.0.13:1400/xml/device_description.xml" ZoneName="Bedroom"/>
        <ZoneGroupMember UUID="RINCON_E" Location="http://10.0.0.14:1400/xml/device_description.xml" ZoneName="Bedroom" Invisible="1"/>
      </ZoneGroup>
    </ZoneGroups></ZoneGroupState>"""

    def test_rooms_map_to_group_coordinator(self):
        self.assertEqual(parse_rooms(self.XML),
                         {"Living Room": "10.0.0.10", "Kitchen": "10.0.0.13", "Bedroom": "10.0.0.13"})


class Uris(unittest.TestCase):
    def test_radio_uri_keeps_query(self):
        self.assertEqual(radio_uri(NTS1), "x-rincon-mp3radio://stream-relay-geo.ntslive.net/stream?client=NTSAtonemo")

    def test_didl_escapes_title(self):
        self.assertIn("<dc:title>Rock &amp; Roll</dc:title>", didl("Rock & Roll"))


class BridgeLogic(unittest.TestCase):
    def setUp(self):
        self.sonos = FakeSonos()
        self.bridge = Bridge(self.sonos, max_volume=30)
        self.bridge.step(None, 50)  # bridge starts, player stopped

    def test_start_never_plays(self):
        bridge = Bridge(self.sonos, max_volume=30)
        bridge.step((NTS1, "NTS Live 1"), 50)  # player already on NTS at start
        bridge.step((NTS1, "NTS Live 1"), 50)
        self.assertEqual(self.sonos.calls, [])
        bridge.step((NTS2, "NTS Live 2"), 50)  # the next knob turn plays
        self.assertEqual(self.sonos.calls, [("volume", 15), ("play", "NTS Live 2")])

    def test_play_sets_volume_first(self):
        self.bridge.step((NTS1, "NTS Live 1"), 50)
        self.assertEqual(self.sonos.calls, [("volume", 15), ("play", "NTS Live 1")])

    def test_channel_change(self):
        self.bridge.step((NTS1, "NTS Live 1"), 50)
        self.bridge.step((NTS2, "NTS Live 2"), 50)
        self.assertEqual(self.sonos.calls[-1], ("play", "NTS Live 2"))

    def test_same_stream_new_title_does_not_restart(self):
        self.bridge.step((NTS1, "NTS Live 1"), 50)
        self.bridge.step((NTS1, "Another show"), 50)
        self.assertEqual(len(self.sonos.calls), 2)

    def test_volume_knob(self):
        self.bridge.step((NTS1, "NTS Live 1"), 50)
        self.bridge.step((NTS1, "NTS Live 1"), 100)
        self.bridge.step((NTS1, "NTS Live 1"), 5)
        self.assertEqual(self.sonos.calls[-2:], [("volume", 30), ("volume", 2)])

    def test_stop(self):
        self.bridge.step((NTS1, "NTS Live 1"), 50)
        self.bridge.step(None, 50)
        self.assertEqual(self.sonos.calls[-1], ("stop",))

    def test_leaves_tv_alone(self):
        self.bridge.step((NTS1, "NTS Live 1"), 50)
        self.sonos.now_playing = TV  # someone switched Sonos to TV
        self.bridge.step((NTS1, "NTS Live 1"), 80)
        self.bridge.step(None, 80)
        self.assertEqual(self.sonos.calls, [("volume", 15), ("play", "NTS Live 1")])

    def test_ignores_switching(self):
        self.bridge.step((NTS1, "NTS Live 1"), 50)
        self.bridge.step(SWITCHING, 50)
        self.assertEqual(len(self.sonos.calls), 2)

    def test_button_takes_over_tv(self):
        self.sonos.now_playing = TV
        self.bridge.step((NTS1, "NTS Live 1"), 60)
        self.assertEqual(self.sonos.calls, [("volume", 18), ("play", "NTS Live 1")])

    def test_player_stopped_by_hand_after_restart(self):
        self.sonos.now_playing = radio_uri(NTS1)  # an earlier run left NTS 1 on Sonos
        bridge = Bridge(self.sonos, max_volume=30)
        bridge.step((NTS1, "NTS Live 1"), 50)
        bridge.step(None, 50)
        self.assertEqual(self.sonos.calls, [("stop",)])

    def test_retries_after_failure(self):
        def fail(uri, title):
            raise OSError("Sonos unreachable")
        self.sonos.play = fail
        with self.assertRaises(OSError):
            self.bridge.step((NTS1, "NTS Live 1"), 50)
        del self.sonos.play  # back to FakeSonos.play
        self.bridge.step((NTS1, "NTS Live 1"), 50)
        self.assertEqual(self.sonos.calls[-1], ("play", "NTS Live 1"))

    def test_refused_volume_still_plays(self):
        def refuse(volume):
            raise RuntimeError("Sonos SetGroupVolume failed (UPnP error 800)")
        self.sonos.set_volume = refuse
        self.bridge.step((NTS1, "NTS Live 1"), 50)
        self.assertEqual(self.sonos.calls, [("play", "NTS Live 1")])

    def test_old_change_never_plays(self):
        bridge = Bridge(self.sonos, max_volume=30)
        bridge.step(None, 50, now=0)
        bridge.step((NTS1, "NTS Live 1"), 50, now=3600)  # computer slept for an hour
        self.assertEqual(self.sonos.calls, [])
        bridge.step((NTS2, "NTS Live 2"), 50, now=3601)
        self.assertEqual(self.sonos.calls, [("volume", 15), ("play", "NTS Live 2")])

    def test_failed_play_expires(self):
        def fail(uri, title):
            raise OSError("Sonos unreachable")
        bridge = Bridge(self.sonos, max_volume=30)
        bridge.step(None, 50, now=0)
        self.sonos.play = fail
        for t in range(1, 60, 5):  # Sonos stays unplugged for a minute; each retry fails
            with self.assertRaises(OSError):
                bridge.step((NTS1, "NTS Live 1"), 50, now=t)
        del self.sonos.play
        bridge.step((NTS1, "NTS Live 1"), 50, now=75)  # plugged back in: no surprise music
        self.assertNotIn(("play", "NTS Live 1"), self.sonos.calls)

    def test_stream_error_keeps_sonos_playing(self):
        tries = []
        bridge = Bridge(self.sonos, max_volume=30, resume=lambda: tries.append(1))
        bridge.step(None, 50, now=0)
        bridge.step((NTS1, "NTS Live 1"), 50, now=1)
        bridge.step(FAILED, 50, now=2)  # the player's stream broke; nobody pressed stop
        self.assertEqual(tries, [])     # waits 3 s first
        for t in range(3, 120):
            bridge.step(FAILED, 50, now=t)
        self.assertEqual(len(tries), 3)  # at 5, 17 and 47 s, then it leaves it
        self.assertNotIn(("stop",), self.sonos.calls)

    def test_resumed_stream_restarts_sonos_only_if_it_stopped(self):
        bridge = Bridge(self.sonos, max_volume=30, resume=lambda: None)
        bridge.step(None, 50, now=0)
        bridge.step((NTS1, "NTS Live 1"), 50, now=1)
        bridge.step(FAILED, 50, now=2)
        bridge.step(FAILED, 50, now=5)
        bridge.step((NTS1, "NTS Live 1"), 50, now=7)  # the player has it back, Sonos never stopped
        self.assertNotIn(("resume",), self.sonos.calls)
        bridge.step(FAILED, 50, now=8)
        self.sonos.is_playing = False  # this time Sonos lost the stream too
        bridge.step((NTS1, "NTS Live 1"), 50, now=12)
        self.assertEqual(self.sonos.calls[-1], ("resume",))

    def test_stream_error_at_start_counts_as_stopped(self):
        bridge = Bridge(self.sonos, max_volume=30, resume=lambda: self.fail("nothing to resume"))
        bridge.step(FAILED, 50, now=0)
        bridge.step(FAILED, 50, now=10)
        bridge.step((NTS1, "NTS Live 1"), 50, now=11)  # a button press plays as usual
        self.assertEqual(self.sonos.calls, [("volume", 15), ("play", "NTS Live 1")])

    def test_new_station_after_stream_error(self):
        bridge = Bridge(self.sonos, max_volume=30, resume=lambda: None)
        bridge.step(None, 50, now=0)
        bridge.step((NTS1, "NTS Live 1"), 50, now=1)
        bridge.step(FAILED, 50, now=2)
        bridge.step((NTS2, "NTS Live 2"), 50, now=4)
        self.assertEqual(self.sonos.calls[-1], ("play", "NTS Live 2"))

    def test_switching_keeps_reading_fresh(self):
        bridge = Bridge(self.sonos, max_volume=30)
        bridge.step(None, 50, now=0)
        for t in range(10, 100, 10):  # player buffers for a while
            bridge.step(SWITCHING, 50, now=t)
        bridge.step((NTS1, "NTS Live 1"), 50, now=100)
        self.assertEqual(self.sonos.calls[-1], ("play", "NTS Live 1"))


if __name__ == "__main__":
    unittest.main()
