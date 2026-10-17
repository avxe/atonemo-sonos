#!/usr/bin/env python3
"""Play the Atonemo NTS Radio Player on Sonos.

The player's NTS buttons, mixtape knob, volume knob and stop drive a Sonos
room. Standard library only. https://github.com/avxe/atonemo-sonos
"""
import argparse
import json
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from html import escape

__version__ = "0.1.0"

NTS_SERVICE = "atonemoNts"  # serviceID the player reports for NTS streams
POLL = 0.5                  # seconds between player reads
RETRY = 5                   # seconds to wait after an error
REDISCOVER_AFTER = 6        # errors in a row before looking for devices again
STALE = 60                  # seconds without a reading before changes stop counting
SWITCHING = "switching"     # player is between streams; wait for it


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def http(url, data=None, headers=None, timeout=5, limit=1 << 20):
    """Fetch a URL. Gives up after about `timeout` seconds in total."""
    deadline = time.monotonic() + timeout
    req = urllib.request.Request(url, data=data, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = b""
        while len(body) < limit:
            chunk = r.read1(65536)
            if not chunk:
                return body
            body += chunk
            if time.monotonic() > deadline:
                raise TimeoutError(f"{url}: too slow")
        raise ValueError(f"{url}: reply too large")


# --- discovery ---------------------------------------------------------------

def ssdp(wait=3.0):
    """Return {ip: {description urls}} for every UPnP device that answers."""
    query = ('M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
             'MAN: "ssdp:discover"\r\nMX: 2\r\nST: upnp:rootdevice\r\n\r\n').encode()
    found = {}
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        s.settimeout(0.3)
        for _ in range(2):  # UDP may drop one
            s.sendto(query, ("239.255.255.250", 1900))
        end = time.monotonic() + wait
        while time.monotonic() < end:
            try:
                data, (ip, _) = s.recvfrom(4096)
            except socket.timeout:
                continue
            for line in data.decode(errors="replace").splitlines():
                key, _, value = line.partition(":")
                if key.strip().lower() == "location":
                    found.setdefault(ip, set()).add(value.strip())
    return found


def discover():
    """Return (player_ips, sonos_ips) found on the network."""
    players, sonos = [], []
    for ip, urls in sorted(ssdp().items()):
        for url in urls:
            parts = urllib.parse.urlparse(url)
            if parts.scheme != "http" or parts.hostname != ip:
                continue  # only trust the device's own web server
            try:
                desc = http(url, timeout=2, limit=1 << 18).decode(errors="replace")
            except Exception:  # one odd device must not stop discovery
                continue
            if "<manufacturer>Atonemo" in desc:
                players.append(ip)
                break
            if "<manufacturer>Sonos" in desc:
                sonos.append(ip)
                break
    return players, sonos


# --- Atonemo -----------------------------------------------------------------

def nts_stream(data):
    """Player data -> (uri, title) while NTS plays, None when not, or SWITCHING."""
    value = (data or {}).get("value") or {}
    state = value.get("state")
    if state in ("stopped", "paused"):
        return None
    if state != "playing":
        return SWITCHING
    track = value.get("trackRoles") or {}
    media = track.get("mediaData") or {}
    if (media.get("metaData") or {}).get("serviceID") != NTS_SERVICE:
        return None  # AirPlay, Spotify, Cast...
    uri = ((media.get("resources") or [{}])[0] or {}).get("uri")
    return (uri, track.get("title") or "NTS") if uri else SWITCHING


class Player:
    """The player's local web API (the one its app uses)."""

    def __init__(self, ip):
        self.ip = ip

    def get(self, path):
        query = urllib.parse.urlencode({"path": path, "roles": "@all"})
        return json.loads(http(f"http://{self.ip}/api/getData?{query}"))

    def read(self):
        """Return (stream, volume 0-100)."""
        stream = nts_stream(self.get("player:player/data"))
        volume = (self.get("player:volume").get("value") or {}).get("i32_") or 0
        return stream, volume


# --- Sonos -------------------------------------------------------------------

CONTROL = {
    "AVTransport": "/MediaRenderer/AVTransport/Control",
    "GroupRenderingControl": "/MediaRenderer/GroupRenderingControl/Control",
    "ZoneGroupTopology": "/ZoneGroupTopology/Control",
}


def soap(ip, service, action, **args):
    """Call a Sonos UPnP action. Returns the response values as a dict."""
    urn = f"urn:schemas-upnp-org:service:{service}:1"
    body = "".join(f"<{k}>{escape(str(v), quote=False)}</{k}>" for k, v in args.items())
    envelope = (
        '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        f'<u:{action} xmlns:u="{urn}">{body}</u:{action}></s:Body></s:Envelope>'
    )
    headers = {"Content-Type": 'text/xml; charset="utf-8"', "SOAPACTION": f'"{urn}#{action}"'}
    try:
        xml = http(f"http://{ip}:1400{CONTROL[service]}", envelope.encode(), headers, timeout=15)
    except urllib.error.HTTPError as e:
        try:
            code = ET.fromstring(e.read()).findtext(".//{*}errorCode")
        except ET.ParseError:
            code = None
        raise RuntimeError(f"Sonos {action} failed (UPnP error {code or e.code})") from None
    return {el.tag: el.text or "" for el in ET.fromstring(xml).iter() if len(el) == 0}


def parse_rooms(zone_group_state):
    """ZoneGroupState XML -> {room name: ip of its group coordinator}."""
    rooms = {}
    for group in ET.fromstring(zone_group_state).iter("ZoneGroup"):
        members = {m.get("UUID"): m for m in group.findall("ZoneGroupMember")}
        coordinator = members.get(group.get("Coordinator"))
        if coordinator is None:
            continue
        ip = urllib.parse.urlparse(coordinator.get("Location")).hostname
        for m in members.values():
            if m.get("Invisible") != "1":  # hides the second speaker of a pair
                rooms[m.get("ZoneName")] = ip
    return rooms


def rooms_of(ip):
    """{room: coordinator ip} of the Sonos system that speaker `ip` belongs to."""
    return parse_rooms(soap(ip, "ZoneGroupTopology", "GetZoneGroupState")["ZoneGroupState"])


def all_rooms(speakers):
    """{room: coordinator ip} for every Sonos system the speakers belong to."""
    rooms = {}
    for ip in speakers:
        try:
            for room, coordinator in rooms_of(ip).items():
                rooms.setdefault(room, coordinator)
        except Exception:  # speaker asleep or gone
            continue
    return rooms


def radio_uri(uri):
    """Sonos plays live streams from x-rincon-mp3radio:// URIs."""
    return "x-rincon-mp3radio://" + uri.split("://", 1)[-1]


def didl(title):
    return (
        '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">'
        f'<item id="R:0/0/0" parentID="R:0/0" restricted="true"><dc:title>{escape(title)}</dc:title>'
        "<upnp:class>object.item.audioItem.audioBroadcast</upnp:class>"
        '<desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON65031_</desc>'
        "</item></DIDL-Lite>"
    )


class Sonos:
    """One Sonos room. Commands go to its group coordinator, found each time."""

    def __init__(self, ip, room, dry_run=False):
        self.ip, self.room, self.dry_run = ip, room, dry_run  # ip: any speaker in the room's system

    def coordinator(self):
        ip = rooms_of(self.ip).get(self.room)
        if ip is None:
            raise RuntimeError(f"Sonos room '{self.room}' not found")
        return ip

    def current_uri(self):
        return soap(self.coordinator(), "AVTransport", "GetMediaInfo", InstanceID=0)["CurrentURI"]

    def send(self, service, *calls):
        if self.dry_run:
            return
        ip = self.coordinator()
        for action, args in calls:
            soap(ip, service, action, InstanceID=0, **args)

    def play(self, uri, title):
        self.send("AVTransport",
                  ("SetAVTransportURI", {"CurrentURI": radio_uri(uri), "CurrentURIMetaData": didl(title)}),
                  ("Play", {"Speed": 1}))

    def stop(self):
        self.send("AVTransport", ("Stop", {}))

    def set_volume(self, volume):
        self.send("GroupRenderingControl",
                  ("SnapshotGroupVolume", {}),  # keeps the balance between grouped rooms
                  ("SetGroupVolume", {"DesiredVolume": volume}))


# --- bridge ------------------------------------------------------------------

class Bridge:
    """Turns changes on the player into Sonos commands."""

    def __init__(self, sonos, max_volume=30):
        self.sonos, self.max_volume = sonos, max_volume
        self.uri = None     # stream the player plays, or None
        self.volume = None  # knob position
        self.seen = None    # time of the last reading handled without error

    def ours(self):
        return self.uri is not None and self.sonos.current_uri() == radio_uri(self.uri)

    def step(self, stream, volume, now=None):
        now = time.time() if now is None else now
        fresh = self.seen is not None and now - self.seen <= STALE
        if stream == SWITCHING:
            if fresh:
                self.seen = now
            return
        uri = stream[0] if stream else None
        if not fresh:
            # First reading, or none for a minute (computer asleep, device offline,
            # Sonos failing): take the player as it is, so old changes never start music.
            self.uri, self.volume, self.seen = uri, volume, now
            return
        if uri != self.uri:
            if uri:
                try:
                    self.sonos.set_volume(self.scale(volume))  # before Play, so it never starts loud
                except RuntimeError as e:  # e.g. a room with fixed volume
                    log(f"{e}. Playing anyway.")
                self.sonos.play(*stream)
                log(f"{stream[1]} -> Sonos")
            elif self.ours():
                self.sonos.stop()
                log("Stopped -> Sonos stopped")
            self.uri = uri
        elif uri and volume != self.volume and self.ours():
            self.sonos.set_volume(self.scale(volume))
            log(f"Volume {volume} -> {self.scale(volume)}")
        self.volume, self.seen = volume, now

    def scale(self, volume):
        return (volume * self.max_volume + 50) // 100  # round half up, like the Mac app


def find(args):
    """Return (player ips, {room: coordinator ip}), honouring --player and --sonos."""
    players, speakers = ([], []) if args.player and args.sonos else discover()
    return [args.player] if args.player else players, all_rooms([args.sonos] if args.sonos else speakers)


def run(args):
    players, rooms = find(args)
    if not players:
        sys.exit("No player found. Same network? Pass its IP with --player.")
    if not rooms:
        sys.exit("No Sonos found. Same network? Pass a speaker IP with --sonos.")
    if len(players) > 1:
        log(f"Found players {', '.join(players)}. Using {players[0]}. Pick one with --player.")
    room = args.room or (next(iter(rooms)) if len(rooms) == 1 else None)
    if room not in rooms:
        sys.exit(f"Pick a room with --room: {', '.join(sorted(rooms))}")
    player, sonos = Player(players[0]), Sonos(rooms[room], room, args.dry_run)
    bridge = Bridge(sonos, args.max_volume)
    log(f"Player {player.ip} -> Sonos '{room}'{' (dry run)' if args.dry_run else ''}. Use the knobs.")

    errors, last_error = 0, None
    while True:
        try:
            bridge.step(*player.read())
            errors, last_error = 0, None
            time.sleep(POLL)
        except Exception as e:  # keep running through Wi-Fi drops and reboots
            errors += 1
            if str(e) != last_error:
                log(f"{type(e).__name__}: {e}")
                last_error = str(e)
            if errors % REDISCOVER_AFTER == 0:  # DHCP may have moved a device
                try:
                    players, rooms = find(args)
                except Exception:
                    players, rooms = [], {}
                player.ip = players[0] if players else player.ip
                sonos.ip = rooms.get(room, sonos.ip)
            time.sleep(RETRY)


def main(argv=None):
    p = argparse.ArgumentParser(prog="atonemo-sonos", description="Play the Atonemo NTS Radio Player on Sonos.")
    p.add_argument("--room", help="Sonos room (default: the only one)")
    p.add_argument("--max-volume", type=int, default=30, metavar="N", help="Sonos volume at full knob (default: 30)")
    p.add_argument("--player", metavar="IP", help="player IP (default: find it)")
    p.add_argument("--sonos", metavar="IP", help="any Sonos speaker IP (default: find them)")
    p.add_argument("--dry-run", action="store_true", help="log what would happen, change nothing")
    p.add_argument("--version", action="version", version=__version__)
    args = p.parse_args(argv)
    if not 0 <= args.max_volume <= 100:
        p.error("--max-volume must be 0-100")
    try:
        run(args)
    except KeyboardInterrupt:
        pass
    except OSError as e:  # no network at start
        sys.exit(f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
