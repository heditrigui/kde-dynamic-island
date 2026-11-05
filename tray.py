#!/usr/bin/python3
"""System tray icon for Dynamic Island: left click toggles it, right click opens a menu."""
import os

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

UNIT = "dynamic-island.service"
SNI_PATH = "/StatusNotifierItem"
MENU_PATH = "/MenuBar"
SNI_IFACE = "org.kde.StatusNotifierItem"
MENU_IFACE = "com.canonical.dbusmenu"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
WATCHER = "org.kde.StatusNotifierWatcher"

ON_COLOR = (0x7d, 0xd3, 0xfc)
OFF_COLOR = (0x8c, 0x8c, 0x8c)


def pill_pixmap(size, filled):
    """Draws the island as an antialiased pill, in the ARGB order the tray expects."""
    half_w, half_h = size * 0.46, size * 0.22
    radius, center, stroke = half_h, size / 2, max(1.5, size * 0.08)
    red, green, blue = ON_COLOR if filled else OFF_COLOR
    data = bytearray()
    for y in range(size):
        for x in range(size):
            dx = max(abs(x + 0.5 - center) - (half_w - radius), 0)
            dy = abs(y + 0.5 - center)
            edge = (dx * dx + dy * dy) ** 0.5 - radius
            coverage = max(0.0, min(1.0, 0.5 - edge))
            if not filled:
                coverage = min(coverage, max(0.0, min(1.0, 0.5 + edge + stroke)))
            data += bytes((int(coverage * 255), red, green, blue))
    return dbus.Struct((size, size, dbus.ByteArray(bytes(data))), signature="iiay")


class Island:
    """Controls the island's systemd user service."""

    def __init__(self, bus, on_change):
        systemd = bus.get_object("org.freedesktop.systemd1", "/org/freedesktop/systemd1")
        self.manager = dbus.Interface(systemd, "org.freedesktop.systemd1.Manager")
        self.manager.Subscribe()
        path = self.manager.LoadUnit(UNIT)
        self.props = dbus.Interface(bus.get_object("org.freedesktop.systemd1", path), PROPS_IFACE)
        bus.add_signal_receiver(lambda *_: on_change(), "PropertiesChanged", PROPS_IFACE, path=path)

    @property
    def running(self):
        state = self.props.Get("org.freedesktop.systemd1.Unit", "ActiveState")
        return state in ("active", "activating", "reloading")

    def run(self):
        self.manager.StartUnit(UNIT, "replace")

    def quit(self):
        self.manager.StopUnit(UNIT, "replace")

    def restart(self):
        self.manager.RestartUnit(UNIT, "replace")


class Menu(dbus.service.Object):
    """The right-click menu, spoken over the dbusmenu protocol."""

    def __init__(self, bus, tray):
        super().__init__(bus, MENU_PATH)
        self.tray = tray
        self.revision = 1

    def items(self):
        running = self.tray.island.running
        return {
            1: ("Run Island", not running, self.tray.island.run),
            2: ("Quit Island", running, self.tray.island.quit),
            3: ("Restart Island", running, self.tray.island.restart),
        }

    def props_of(self, item_id):
        if item_id == 0:
            return dbus.Dictionary({"children-display": "submenu"}, signature="sv")
        label, enabled, _ = self.items()[item_id]
        return dbus.Dictionary({"label": label, "enabled": dbus.Boolean(enabled)}, signature="sv")

    def node(self, item_id, children=(), variant_level=0):
        return dbus.Struct(
            (item_id, self.props_of(item_id), dbus.Array(children, signature="v")),
            signature="ia{sv}av",
            variant_level=variant_level,
        )

    def changed(self):
        self.revision += 1
        self.LayoutUpdated(self.revision, 0)

    @dbus.service.method(MENU_IFACE, in_signature="iias", out_signature="u(ia{sv}av)")
    def GetLayout(self, parent, depth, names):
        if parent != 0:
            return self.revision, self.node(parent)
        children = [self.node(i, variant_level=1) for i in self.items()] if depth != 0 else []
        return self.revision, self.node(0, children)

    @dbus.service.method(MENU_IFACE, in_signature="aias", out_signature="a(ia{sv})")
    def GetGroupProperties(self, ids, names):
        known = [0, *self.items()]
        wanted = [i for i in ids if i in known] or known
        return dbus.Array(
            [dbus.Struct((i, self.props_of(i)), signature="ia{sv}") for i in wanted],
            signature="(ia{sv})",
        )

    @dbus.service.method(MENU_IFACE, in_signature="is", out_signature="v")
    def GetProperty(self, item_id, name):
        return self.props_of(item_id).get(name, "")

    @dbus.service.method(MENU_IFACE, in_signature="isvu")
    def Event(self, item_id, event, data, timestamp):
        if event == "clicked" and item_id in self.items():
            _, enabled, action = self.items()[item_id]
            if enabled:
                self.tray.call(action)

    @dbus.service.method(MENU_IFACE, in_signature="a(isvu)", out_signature="ai")
    def EventGroup(self, events):
        for item_id, event, data, timestamp in events:
            self.Event(item_id, event, data, timestamp)
        return dbus.Array([], signature="i")

    @dbus.service.method(MENU_IFACE, in_signature="i", out_signature="b")
    def AboutToShow(self, item_id):
        return False

    @dbus.service.method(MENU_IFACE, in_signature="ai", out_signature="aiai")
    def AboutToShowGroup(self, ids):
        return dbus.Array([], signature="i"), dbus.Array([], signature="i")

    @dbus.service.signal(MENU_IFACE, signature="ui")
    def LayoutUpdated(self, revision, parent):
        pass

    @dbus.service.signal(MENU_IFACE, signature="a(ia{sv})a(ias)")
    def ItemsPropertiesUpdated(self, updated, removed):
        pass

    @dbus.service.method(PROPS_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, name):
        return self.GetAll(interface)[name]

    @dbus.service.method(PROPS_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return dbus.Dictionary(
            {"Version": dbus.UInt32(3), "TextDirection": "ltr", "Status": "normal",
             "IconThemePath": dbus.Array([], signature="s")},
            signature="sv",
        )


class Tray(dbus.service.Object):
    """The tray item itself, spoken over the StatusNotifierItem protocol."""

    def __init__(self, bus):
        self.bus = bus
        self.name = dbus.service.BusName(f"org.kde.StatusNotifierItem-{os.getpid()}-1", bus)
        super().__init__(bus, SNI_PATH)
        self.icons = {
            state: dbus.Array([pill_pixmap(s, state) for s in (22, 32, 48, 64)], signature="(iiay)")
            for state in (True, False)
        }
        self.island = Island(bus, self.refresh)
        self.menu = Menu(bus, self)
        bus.watch_name_owner(WATCHER, lambda owner: self.register() if owner else None)

    def register(self):
        try:
            watcher = dbus.Interface(self.bus.get_object(WATCHER, "/StatusNotifierWatcher"), WATCHER)
            watcher.RegisterStatusNotifierItem(self.name.get_name())
        except dbus.DBusException as error:
            print(f"Could not register the tray icon: {error}", flush=True)

    def call(self, action):
        try:
            action()
        except dbus.DBusException as error:
            print(f"Could not change the island service: {error}", flush=True)

    def refresh(self):
        self.NewIcon()
        self.NewToolTip()
        self.menu.changed()

    @dbus.service.method(SNI_IFACE, in_signature="ii")
    def Activate(self, x, y):
        self.call(self.island.quit if self.island.running else self.island.run)

    @dbus.service.method(SNI_IFACE, in_signature="ii")
    def SecondaryActivate(self, x, y):
        pass

    @dbus.service.method(SNI_IFACE, in_signature="ii")
    def ContextMenu(self, x, y):
        pass

    @dbus.service.method(SNI_IFACE, in_signature="is")
    def Scroll(self, delta, orientation):
        pass

    @dbus.service.signal(SNI_IFACE)
    def NewIcon(self):
        pass

    @dbus.service.signal(SNI_IFACE)
    def NewToolTip(self):
        pass

    @dbus.service.method(PROPS_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, name):
        return self.GetAll(interface)[name]

    @dbus.service.method(PROPS_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        running = self.island.running
        no_pixmaps = dbus.Array([], signature="(iiay)")
        tooltip = dbus.Struct(
            ("", no_pixmaps, "Dynamic Island",
             "Running: move the cursor to the top of the screen" if running else "Not running"),
            signature="sa(iiay)ss",
        )
        return dbus.Dictionary(
            {
                "Category": "ApplicationStatus",
                "Id": "dynamic-island",
                "Title": "Dynamic Island",
                "Status": "Active",
                "WindowId": dbus.Int32(0),
                "IconName": "",
                "IconPixmap": self.icons[bool(running)],
                "ToolTip": tooltip,
                "ItemIsMenu": dbus.Boolean(False),
                "Menu": dbus.ObjectPath(MENU_PATH),
            },
            signature="sv",
        )


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    Tray(dbus.SessionBus())
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
