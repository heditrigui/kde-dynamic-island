#!/usr/bin/python3 -I
"""Native messaging host: gives every browser tab with media its own MPRIS player."""
import json
import os
import struct
import sys
import time

import dbus
import dbus.bus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

ROOT_IFACE = "org.mpris.MediaPlayer2"
PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
OBJECT_PATH = "/org/mpris/MediaPlayer2"
IDENTITY = "Browser tab"  # island.qml looks for this name
DESKTOP_ENTRIES = {"brave": "brave-browser", "chrome": "google-chrome", "chromium": "chromium-browser"}
MAX_TEXT = 300
SEEK_JUMP = 2.0  # seconds off the expected position that count as a seek


def clean_text(value):
    """Page titles are untrusted: keep them to plain text of a sane length."""
    return value.replace("\0", "")[:MAX_TEXT] if isinstance(value, str) else ""


def clean_number(value):
    return float(value) if isinstance(value, (int, float)) and value >= 0 else 0.0


def clean_art(value):
    return value[:2000] if isinstance(value, str) and value.startswith(("https://", "http://")) else ""


def browser_entry():
    try:
        with open(f"/proc/{os.getppid()}/comm", encoding="utf-8") as comm:
            return DESKTOP_ENTRIES.get(comm.read().strip(), "")
    except OSError:
        return ""


def send_message(message):
    data = json.dumps(message).encode()
    sys.stdout.buffer.write(struct.pack("=I", len(data)) + data)
    sys.stdout.buffer.flush()


class TabPlayer(dbus.service.Object):
    """One tab's player. It needs its own connection: all players share one object path."""

    def __init__(self, tab, desktop_entry):
        self.conn = dbus.bus.BusConnection(dbus.bus.BUS_SESSION)
        self.bus_name = dbus.service.BusName(f"{ROOT_IFACE}.dynamicisland.instance{os.getpid()}_{tab}", self.conn)
        super().__init__(conn=self.conn, object_path=OBJECT_PATH)
        self.tab = tab
        self.desktop_entry = desktop_entry
        self.playing = False
        self.title = ""
        self.artist = ""
        self.art = ""
        self.duration = 0.0
        self.position = 0.0
        self.rate = 1.0
        self.can_seek = False
        self.updated = time.monotonic()

    def close(self):
        self.remove_from_connection()
        self.conn.close()

    def current_position(self):
        if not self.playing:
            return self.position
        return self.position + (time.monotonic() - self.updated) * self.rate

    def update(self, state):
        expected = self.current_position()
        self.playing = state.get("playing") is True
        self.title = clean_text(state.get("title"))
        self.artist = clean_text(state.get("artist"))
        self.art = clean_art(state.get("art"))
        self.duration = clean_number(state.get("duration"))
        self.position = clean_number(state.get("position"))
        self.rate = clean_number(state.get("rate")) or 1.0
        self.can_seek = state.get("canSeek") is True
        self.updated = time.monotonic()
        self.PropertiesChanged(PLAYER_IFACE, self.player_props(), [])
        if abs(self.position - expected) > SEEK_JUMP:
            self.Seeked(self.position_us())

    def position_us(self):
        return dbus.Int64(int(self.current_position() * 1_000_000))

    def metadata(self):
        data = {
            "mpris:trackid": dbus.ObjectPath(f"/org/dynamicisland/tab{self.tab}"),
            "xesam:title": self.title,
            "xesam:artist": dbus.Array([self.artist], signature="s"),
        }
        if self.art:
            data["mpris:artUrl"] = self.art
        if self.duration:
            data["mpris:length"] = dbus.Int64(int(self.duration * 1_000_000))
        return dbus.Dictionary(data, signature="sv")

    def player_props(self):
        return dbus.Dictionary(
            {
                "PlaybackStatus": "Playing" if self.playing else "Paused",
                "Metadata": self.metadata(),
                "Rate": dbus.Double(self.rate),
                "MinimumRate": dbus.Double(self.rate),
                "MaximumRate": dbus.Double(self.rate),
                "Volume": dbus.Double(1.0),
                "CanControl": dbus.Boolean(True),
                "CanPlay": dbus.Boolean(True),
                "CanPause": dbus.Boolean(True),
                "CanSeek": dbus.Boolean(self.can_seek),
                "CanGoNext": dbus.Boolean(False),
                "CanGoPrevious": dbus.Boolean(False),
            },
            signature="sv",
        )

    def root_props(self):
        return dbus.Dictionary(
            {
                "Identity": IDENTITY,
                "DesktopEntry": self.desktop_entry,
                "CanQuit": dbus.Boolean(False),
                "CanRaise": dbus.Boolean(False),
                "HasTrackList": dbus.Boolean(False),
                "SupportedUriSchemes": dbus.Array([], signature="s"),
                "SupportedMimeTypes": dbus.Array([], signature="s"),
            },
            signature="sv",
        )

    def command(self, name, position=None):
        send_message({"tab": self.tab, "command": name, "position": position})

    @dbus.service.method(PROPS_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface == ROOT_IFACE:
            return self.root_props()
        if interface == PLAYER_IFACE:
            props = self.player_props()
            props["Position"] = self.position_us()
            return props
        return dbus.Dictionary({}, signature="sv")

    @dbus.service.method(PROPS_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, name):
        return self.GetAll(interface)[name]

    @dbus.service.method(PROPS_IFACE, in_signature="ssv")
    def Set(self, interface, name, value):
        pass

    @dbus.service.signal(PROPS_IFACE, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass

    @dbus.service.signal(PLAYER_IFACE, signature="x")
    def Seeked(self, position):
        pass

    @dbus.service.method(ROOT_IFACE)
    def Raise(self):
        pass

    @dbus.service.method(ROOT_IFACE)
    def Quit(self):
        pass

    @dbus.service.method(PLAYER_IFACE)
    def Next(self):
        pass

    @dbus.service.method(PLAYER_IFACE)
    def Previous(self):
        pass

    @dbus.service.method(PLAYER_IFACE)
    def Play(self):
        self.command("play")

    @dbus.service.method(PLAYER_IFACE)
    def Pause(self):
        self.command("pause")

    @dbus.service.method(PLAYER_IFACE)
    def Stop(self):
        self.command("pause")

    @dbus.service.method(PLAYER_IFACE)
    def PlayPause(self):
        self.command("toggle")

    @dbus.service.method(PLAYER_IFACE, in_signature="x")
    def Seek(self, offset):
        if self.can_seek:
            self.command("seek", max(0.0, self.current_position() + offset / 1_000_000))

    @dbus.service.method(PLAYER_IFACE, in_signature="ox")
    def SetPosition(self, track, position):
        if self.can_seek:
            self.command("seek", max(0.0, position / 1_000_000))

    @dbus.service.method(PLAYER_IFACE, in_signature="s")
    def OpenUri(self, uri):
        pass


class Host:
    """Reads the browser's length-prefixed JSON messages from stdin."""

    def __init__(self, loop):
        self.loop = loop
        self.buffer = bytearray()
        self.players = {}
        self.desktop_entry = browser_entry()
        GLib.io_add_watch(0, GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, self.on_input)

    def on_input(self, fd, _condition):
        data = os.read(fd, 65536)
        if not data:
            self.loop.quit()
            return False
        self.buffer += data
        while len(self.buffer) >= 4:
            size = struct.unpack("=I", self.buffer[:4])[0]
            if len(self.buffer) < 4 + size:
                break
            message = bytes(self.buffer[4:4 + size])
            del self.buffer[:4 + size]
            self.handle(json.loads(message))
        return True

    def handle(self, message):
        tab, state = message["tab"], message["state"]
        player = self.players.get(tab)
        if state is None:
            if player:
                del self.players[tab]
                player.close()
            return
        if not player:
            player = self.players[tab] = TabPlayer(int(tab), self.desktop_entry)
        player.update(state)


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    loop = GLib.MainLoop()
    Host(loop)
    loop.run()


if __name__ == "__main__":
    main()
