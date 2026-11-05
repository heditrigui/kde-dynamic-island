// Dynamic Island for KDE Plasma 6 (Wayland).
// Run with: qml6 --apptype gui island.qml [-- --expanded]
//
// Hidden until the cursor touches the top edge of the screen.
// Left click to pin open · right click to quit.
// With more than one media source, click the dots to switch between them.
import QtQml.Models
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import QtQuick.Window
import org.kde.kirigami as Kirigami
import org.kde.ksysguard.sensors as Sensors
import org.kde.layershell as LayerShell
import org.kde.plasma.private.mpris as Mpris
import org.kde.plasma.workspace.dbus as DBus

Window {
    id: root

    // ---- Tweakables ------------------------------------------------------
    readonly property int topGap: 8           // distance from the screen edge
    readonly property int triggerWidth: 600   // width of the reveal zone, centred
    readonly property int triggerHeight: 2    // this strip takes clicks while hidden
    readonly property int revealDelay: 120    // ms at the edge before it opens
    readonly property bool peekOnTrackChange: false // pop open when the song changes
    readonly property int expandedW: 470
    readonly property int peekSeconds: 4      // how long a new track stays visible
    readonly property int tempWarn: 85        // °C, tints amber
    readonly property int tempCrit: 95        // °C, tints red
    readonly property int loadWarn: 85        // %, CPU and RAM
    readonly property int loadCrit: 95
    readonly property color fallbackAccent: "#7dd3fc"
    // ----------------------------------------------------------------------

    readonly property bool forceExpanded: Qt.application.arguments.indexOf("--expanded") >= 0

    screen: Qt.application.screens[0] // Qt lists the primary screen first
    title: "Dynamic Island"
    color: "transparent"
    flags: Qt.FramelessWindowHint
    visible: true

    LayerShell.Window.scope: "dynamic-island"
    LayerShell.Window.layer: LayerShell.Window.LayerTop
    LayerShell.Window.anchors: LayerShell.Window.AnchorTop
    LayerShell.Window.exclusionZone: -1
    LayerShell.Window.keyboardInteractivity: LayerShell.Window.KeyboardInteractivityNone

    // ---- Data ------------------------------------------------------------
    Mpris.Mpris2Model { id: mpris }
    Instantiator {
        id: playerRows
        model: mpris
        onObjectAdded: Qt.callLater(root.pickPlayer)
        onObjectRemoved: Qt.callLater(root.pickPlayer)
        delegate: QtObject {
            required property var model
            readonly property var container: model.container
            readonly property bool multiplexer: model.isMultiplexer
            readonly property int status: container ? container.playbackStatus : 0
            readonly property string trackName: container ? (container.track || "") : ""
            onStatusChanged: Qt.callLater(root.pickPlayer)
            onTrackNameChanged: Qt.callLater(root.pickPlayer)
        }
    }

    property var player: null
    property var players: []          // what the dots show, in a stable order
    property var chosenPlayer: null   // set by clicking a dot, wins over the ranking
    property var hiddenPlayers: ({})  // HiddenPlayer objects by D-Bus name

    function isBrowser(candidate) {
        return /brave|chrom|firefox|edge|vivaldi|opera|browser/i.test((candidate.desktopEntry || "") + " " + (candidate.identity || ""));
    }

    function isTabPlayer(candidate) {
        return candidate.identity === "Browser tab"; // from tab_media_host.py
    }

    function sameTrack(a, b) {
        const left = a.toLowerCase(), right = b.toLowerCase();
        return left.includes(right) || right.includes(left);
    }

    // Plasma's automatic pick can stay on a browser, where a hover preview or a
    // background tab counts as playing, so rank the players here instead: playing
    // beats paused, and a music app beats a browser. Ties keep the current player.
    function pickPlayer() {
        const rows = [];
        for (let i = 0; i < playerRows.count; i++) {
            const row = playerRows.objectAt(i);
            if (row && row.container && !row.multiplexer && row.trackName !== "" && rows.indexOf(row.container) < 0)
                rows.push(row.container);
        }
        // One tab can show up three times. Keep the integration player, which can
        // skip tracks, then the extension's tab player, then the browser's own.
        const integrated = rows.filter(candidate => candidate.kdePid > 0);
        const tabs = rows.filter(isTabPlayer).filter(tab => !integrated.some(p => sameTrack(p.track, tab.track)));
        const shownTabs = integrated.concat(tabs);
        const others = rows.filter(candidate => candidate.kdePid <= 0 && !isTabPlayer(candidate)
                                   && !(isBrowser(candidate) && shownTabs.some(p => sameTrack(p.track, candidate.track))));
        const found = integrated.concat(tabs, others);
        for (const hidden of Object.values(hiddenPlayers))
            if (hidden.track !== "" && !shownTabs.some(p => sameTrack(p.track, hidden.track)))
                found.push(hidden);

        // Existing players keep their place so a dot doesn't move under the cursor.
        const kept = players.filter(candidate => found.indexOf(candidate) >= 0);
        const ordered = kept.concat(found.filter(candidate => kept.indexOf(candidate) < 0));
        if (ordered.length !== players.length || ordered.some((candidate, i) => candidate !== players[i]))
            players = ordered;

        if (ordered.indexOf(chosenPlayer) < 0)
            chosenPlayer = null;
        const rank = candidate => {
            const status = candidate.playbackStatus;
            const state = status === Mpris.PlaybackStatus.Playing ? 2 : status === Mpris.PlaybackStatus.Paused ? 1 : 0;
            return state * 2 + (isBrowser(candidate) ? 0 : 1);
        };
        let next = chosenPlayer || (ordered.indexOf(player) >= 0 ? player : null);
        if (!chosenPlayer)
            for (const candidate of ordered)
                if (!next || rank(candidate) > rank(next))
                    next = candidate;
        if (next !== player) {
            player = next;
            console.log("Following player:", next ? next.identity : "none");
        }
    }

    function choosePlayer(candidate) {
        chosenPlayer = candidate;
        pickPlayer();
    }

    function sendCommand(member) {
        if (player.send)
            player.send(member, "", []);
        else
            player[member]();
    }

    function seekTo(us) {
        if (player.seekBy)
            player.seekBy(us - player.position);
        else
            player.position = us;
    }

    function busCall(service, path, iface, member, signature, args, done) {
        DBus.SessionBus.asyncCall({ service: service, path: path, iface: iface, member: member, signature: signature, arguments: args },
                                  reply => { if (done) done(reply.value); },
                                  error => console.debug(member, "failed:", error.message));
    }
    function busValue(value) {
        return value !== null && typeof value === "object" && value.value !== undefined ? value.value : value;
    }

    function dropHiddenPlayer(name) {
        const gone = hiddenPlayers[name];
        delete hiddenPlayers[name];
        pickPlayer();
        gone.destroy();
    }

    // Plasma's model hides a browser's own player whenever its integration player
    // exists, yet the two can be different tabs, so look for those over D-Bus.
    function refreshHiddenPlayers() {
        const browserPids = [];
        for (let i = 0; i < playerRows.count; i++) {
            const row = playerRows.objectAt(i);
            if (row && row.container && row.container.kdePid > 0)
                browserPids.push(row.container.kdePid);
        }
        for (const name of Object.keys(hiddenPlayers))
            if (browserPids.indexOf(hiddenPlayers[name].pid) < 0)
                dropHiddenPlayer(name);
        if (browserPids.length === 0)
            return;

        const bus = ["org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus"];
        busCall(...bus, "ListNames", "", [], names => {
            const media = names.filter(name => name.startsWith("org.mpris.MediaPlayer2.") && !name.endsWith(".plasma-browser-integration"));
            for (const name of Object.keys(hiddenPlayers))
                if (media.indexOf(name) < 0)
                    dropHiddenPlayer(name);
            for (const name of media) {
                if (hiddenPlayers[name]) {
                    hiddenPlayers[name].refresh();
                    continue;
                }
                busCall(...bus, "GetConnectionUnixProcessID", "(s)", [new DBus.string(name)], reply => {
                    const pid = busValue(reply);
                    if (browserPids.indexOf(pid) >= 0 && !hiddenPlayers[name])
                        hiddenPlayers[name] = hiddenPlayerComponent.createObject(root, { service: name, pid: pid });
                });
            }
        });
    }
    Component { id: hiddenPlayerComponent; HiddenPlayer {} }
    Timer {
        interval: 1000
        repeat: true
        running: root.bigWindow
        triggeredOnStart: true
        onTriggered: root.refreshHiddenPlayers()
    }

    readonly property bool hasMedia: !!player && (player.track || "") !== ""
    readonly property bool playing: hasMedia && player.playbackStatus === Mpris.PlaybackStatus.Playing
    readonly property string track: hasMedia ? player.track : ""
    readonly property string artist: hasMedia ? (player.artist || player.identity || "") : ""
    readonly property string artUrl: hasMedia ? (player.artUrl || "") : ""

    Sensors.Sensor { id: cpuUsage; sensorId: "cpu/all/usage"; updateRateLimit: 1000 }
    Sensors.Sensor { id: cpuFreq; sensorId: "cpu/all/averageFrequency"; updateRateLimit: 2000 }
    Sensors.Sensor { id: memPercent; sensorId: "memory/physical/usedPercent"; updateRateLimit: 2000 }
    Sensors.Sensor { id: memUsed; sensorId: "memory/physical/used"; updateRateLimit: 2000 }
    Sensors.Sensor { id: tempMax; sensorId: "cpu/all/maximumTemperature"; updateRateLimit: 2000 }
    Sensors.Sensor { id: tempAvg; sensorId: "cpu/all/averageTemperature"; updateRateLimit: 2000 }

    readonly property real cpu: cpuUsage.value || 0
    readonly property real mem: memPercent.value || 0
    readonly property real temp: tempMax.value || 0

    function levelColor(value, warn, crit) {
        return value >= crit ? "#ff6b6b" : value >= warn ? "#ffb454" : "#ffffff";
    }
    function formatTime(us) {
        const total = Math.max(0, Math.floor(us / 1000000));
        const secs = total % 60;
        return Math.floor(total / 60) + ":" + (secs < 10 ? "0" : "") + secs;
    }

    // Album colours tint the equaliser, the progress bar and the rings.
    Kirigami.ImageColors { id: artColors; source: colorSource }
    Image {
        id: colorSource
        visible: false
        source: root.artUrl
        sourceSize: Qt.size(64, 64)
        onStatusChanged: if (status === Image.Ready) artColors.update()
    }
    property color accent: {
        if (!hasMedia || colorSource.status !== Image.Ready)
            return fallbackAccent;
        const c = artColors.dominant;
        return Qt.hsla(c.hslHue < 0 ? 0.55 : c.hslHue, Math.max(c.hslSaturation, 0.55), Math.max(c.hslLightness, 0.68), 1);
    }
    Behavior on accent { ColorAnimation { duration: 500 } }

    // ---- State -----------------------------------------------------------
    property bool hovering: false
    property bool pinned: false
    property bool peeking: false
    property bool bigWindow: forceExpanded
    property bool expanded: forceExpanded

    readonly property bool wantOpen: forceExpanded || pinned || hovering || peeking
    readonly property bool showStats: forceExpanded || pinned || hovering || !hasMedia

    readonly property int expandedH: {
        const media = hasMedia ? 76 : 0;
        const stats = showStats ? 56 : 0;
        return 18 + media + (media && stats ? 16 : 0) + stats + 18;
    }

    // A surface receives clicks over its full area, so it stays a thin strip until
    // the island needs the room. Resizing stalls a frame or two, so the surface
    // grows first and the animation starts once that has settled.
    onWantOpenChanged: {
        if (wantOpen) {
            shrinkTimer.stop();
            bigWindow = true;
            openTimer.restart();
        } else {
            openTimer.stop();
            expanded = false;
            shrinkTimer.restart();
        }
    }
    Timer { id: openTimer; interval: 70; onTriggered: root.expanded = true }
    Timer {
        id: shrinkTimer
        interval: 450
        onTriggered: {
            root.bigWindow = false;
            // A choice lasts while that player is playing; otherwise go back to the ranking.
            if (root.chosenPlayer && root.chosenPlayer.playbackStatus !== Mpris.PlaybackStatus.Playing) {
                root.chosenPlayer = null;
                root.pickPlayer();
            }
        }
    }
    Timer { id: hoverOff; interval: 350; onTriggered: root.hovering = false }
    Timer { id: hoverOn; interval: root.revealDelay; onTriggered: root.hovering = true }
    Timer { id: peekOff; interval: root.peekSeconds * 1000; onTriggered: root.peeking = false }

    // Show the new song for a moment. The delay skips the burst of metadata
    // a player sends at startup and lets paused players stay quiet.
    property string lastTrack: ""
    onTrackChanged: peekDelay.restart()
    Timer {
        id: peekDelay
        interval: 400
        onTriggered: {
            if (root.peekOnTrackChange && root.track !== root.lastTrack && root.track !== "" && root.lastTrack !== "" && root.playing) {
                root.peeking = true;
                peekOff.restart();
            }
            root.lastTrack = root.track;
        }
    }

    // Never narrower than the trigger, or a cursor at its far end would fall
    // outside the opened surface and the island would flap open and closed.
    width: bigWindow ? Math.max(triggerWidth, expandedW + 32) : triggerWidth
    height: bigWindow ? 18 + 76 + 16 + 56 + 18 + topGap + 24 : triggerHeight

    HoverHandler {
        onHoveredChanged: {
            if (hovered) {
                hoverOff.stop();
                hoverOn.restart();
            } else {
                hoverOn.stop();
                hoverOff.restart();
            }
        }
    }

    // ---- The island ------------------------------------------------------
    Rectangle {
        id: pill

        readonly property int targetW: root.expanded ? root.expandedW : 180
        readonly property int targetH: root.expanded ? root.expandedH : 36

        anchors.horizontalCenter: parent.horizontalCenter
        y: root.expanded ? root.topGap : -targetH - 4
        opacity: root.expanded ? 1 : 0
        width: targetW
        height: targetH
        radius: Math.min(height / 2, 30)
        color: "#000000"
        border.color: "#22ffffff"
        border.width: 1
        clip: true

        // Bouncy on the way out of the edge, quick and bounce-free going back.
        Behavior on width { SpringAnimation { spring: root.expanded ? 4.2 : 12; damping: root.expanded ? 0.34 : 1; epsilon: 0.3 } }
        Behavior on height { SpringAnimation { spring: root.expanded ? 4.2 : 12; damping: root.expanded ? 0.36 : 1; epsilon: 0.3 } }
        Behavior on y { SpringAnimation { spring: root.expanded ? 4.2 : 12; damping: root.expanded ? 0.5 : 1; epsilon: 0.3 } }
        Behavior on opacity { NumberAnimation { duration: root.expanded ? 120 : 220 } }

        TapHandler {
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onTapped: (point, button) => {
                if (button === Qt.RightButton)
                    Qt.exit(42); // the service treats 42 as a deliberate quit
                else
                    root.pinned = !root.pinned;
            }
        }

        // ---- Expanded --------------------------------------------------
        Item {
            id: expandedContent
            anchors.horizontalCenter: parent.horizontalCenter
            y: 18
            width: root.expandedW - 36

            // Media
            Item {
                id: mediaBlock
                visible: root.hasMedia
                width: parent.width
                height: 76

                AlbumArt {
                    id: bigArt
                    size: 76
                    corner: 16
                }

                Column {
                    anchors.left: bigArt.right
                    anchors.leftMargin: 14
                    anchors.right: controls.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.track
                        textFormat: Text.PlainText
                        color: "#ffffff"
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                    }
                    Row {
                        width: parent.width
                        spacing: 7

                        Equalizer {
                            id: mediaEq
                            anchors.verticalCenter: parent.verticalCenter
                            barHeight: 11
                        }
                        Text {
                            width: parent.width - mediaEq.width - parent.spacing
                            elide: Text.ElideRight
                            text: root.artist
                            textFormat: Text.PlainText
                            color: "#a0ffffff"
                            font.pixelSize: 12
                        }
                    }
                    Item { width: 1; height: 6 }
                    ProgressLine { width: parent.width }
                }

                Row {
                    id: controls
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    ControlButton {
                        icon: "media-skip-backward"
                        size: 34
                        enabled: root.hasMedia && root.player.canGoPrevious
                        onClicked: root.sendCommand("Previous")
                    }
                    ControlButton {
                        icon: root.playing ? "media-playback-pause" : "media-playback-start"
                        size: 42
                        enabled: root.hasMedia && root.player.canControl
                        onClicked: root.sendCommand("PlayPause")
                    }
                    ControlButton {
                        icon: "media-skip-forward"
                        size: 34
                        enabled: root.hasMedia && root.player.canGoNext
                        onClicked: root.sendCommand("Next")
                    }
                }
            }

            // One dot per media source, in the gap above the stats.
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 76
                visible: root.hasMedia && root.players.length > 1

                Repeater {
                    model: root.players

                    Item {
                        id: dot
                        required property var modelData
                        readonly property bool active: modelData === root.player
                        width: 22
                        height: 16

                        Rectangle {
                            anchors.centerIn: parent
                            width: dot.active ? 16 : 6
                            height: 6
                            radius: 3
                            color: dot.active ? root.accent : "#ffffff"
                            opacity: dot.active || dotArea.containsMouse ? 1
                                     : dot.modelData.playbackStatus === Mpris.PlaybackStatus.Playing ? 0.7 : 0.3
                            Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                            Behavior on opacity { NumberAnimation { duration: 120 } }
                        }
                        MouseArea {
                            id: dotArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.choosePlayer(dot.modelData)
                        }
                    }
                }
            }

            // System
            Row {
                y: root.hasMedia ? 76 + 16 : 0
                width: parent.width
                spacing: 8
                opacity: root.showStats ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 180 } }

                StatRing {
                    label: "CPU"
                    fraction: root.cpu / 100
                    centerText: Math.round(root.cpu) + "%"
                    detail: cpuFreq.value ? (cpuFreq.value / 1000).toFixed(1) + " GHz" : ""
                    alert: root.levelColor(root.cpu, root.loadWarn, root.loadCrit)
                }
                StatRing {
                    label: "RAM"
                    fraction: root.mem / 100
                    centerText: Math.round(root.mem) + "%"
                    detail: memUsed.value ? (memUsed.value / 1073741824).toFixed(1) + " GB" : ""
                    alert: root.levelColor(root.mem, root.loadWarn, root.loadCrit)
                }
                StatRing {
                    label: "TEMP"
                    fraction: Math.max(0, Math.min(1, (root.temp - 30) / 70))
                    centerText: root.temp > 0 ? Math.round(root.temp) + "°" : "–"
                    detail: tempAvg.value ? "avg " + Math.round(tempAvg.value) + "°" : ""
                    alert: root.levelColor(root.temp, root.tempWarn, root.tempCrit)
                }
            }
        }
    }

    // ---- Components ------------------------------------------------------

    // Offers the parts of Plasma's player API the island uses, for a player that
    // only exists on D-Bus. Nothing is watched while the island is closed.
    component HiddenPlayer: QtObject {
        id: hidden
        readonly property string objectPath: "/org/mpris/MediaPlayer2"
        readonly property string playerIface: "org.mpris.MediaPlayer2.Player"
        property string service
        property int pid
        property string identity: "Browser"
        property string desktopEntry
        property int playbackStatus: Mpris.PlaybackStatus.Unknown
        property string track
        property string artist
        property string artUrl
        property real length: 0
        property real position: 0
        property bool canControl
        property bool canGoPrevious
        property bool canGoNext
        property bool canSeek

        onPlaybackStatusChanged: Qt.callLater(root.pickPlayer)
        onTrackChanged: Qt.callLater(root.pickPlayer)

        function refresh() {
            root.busCall(service, objectPath, "org.freedesktop.DBus.Properties", "GetAll", "(s)", [new DBus.string(playerIface)], props => {
                const metadata = root.busValue(props.Metadata) || {};
                const status = root.busValue(props.PlaybackStatus);
                playbackStatus = status === "Playing" ? Mpris.PlaybackStatus.Playing
                               : status === "Paused" ? Mpris.PlaybackStatus.Paused
                               : Mpris.PlaybackStatus.Stopped;
                track = root.busValue(metadata["xesam:title"]) || "";
                artist = Array.from(root.busValue(metadata["xesam:artist"]) || []).join(", ");
                artUrl = root.busValue(metadata["mpris:artUrl"]) || "";
                // A live stream reports an overflowed length.
                const total = Number(root.busValue(metadata["mpris:length"])) || 0;
                length = total > 0 && total < 1e15 ? total : 0;
                position = Number(root.busValue(props.Position)) || 0;
                canControl = !!root.busValue(props.CanControl);
                canGoPrevious = !!root.busValue(props.CanGoPrevious);
                canGoNext = !!root.busValue(props.CanGoNext);
                canSeek = !!root.busValue(props.CanSeek);
            });
        }
        function send(member, signature, args) {
            root.busCall(service, objectPath, playerIface, member, signature, args, () => refresh());
        }
        function seekBy(us) { send("Seek", "(x)", [new DBus.int64(Math.round(us))]); }
        function updatePosition() {}

        Component.onCompleted: {
            root.busCall(service, objectPath, "org.freedesktop.DBus.Properties", "GetAll", "(s)", [new DBus.string("org.mpris.MediaPlayer2")], props => {
                identity = root.busValue(props.Identity) || identity;
                desktopEntry = root.busValue(props.DesktopEntry) || "";
            });
            refresh();
        }
    }

    component AlbumArt: Item {
        id: art
        property int size: 24
        property int corner: 7
        width: size
        height: size

        Rectangle {
            anchors.fill: parent
            radius: art.corner
            color: "#1f1f24"
            Kirigami.Icon {
                anchors.centerIn: parent
                width: parent.width * 0.55
                height: width
                source: "media-album-cover"
                isMask: true
                color: "#80ffffff"
            }
        }
        Image {
            id: artImage
            anchors.fill: parent
            source: root.artUrl
            sourceSize: Qt.size(art.size * 2, art.size * 2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: false
            layer.enabled: true
        }
        Rectangle {
            id: artMask
            anchors.fill: parent
            radius: art.corner
            visible: false
            layer.enabled: true
            layer.smooth: true
        }
        MultiEffect {
            anchors.fill: parent
            source: artImage
            visible: artImage.status === Image.Ready
            maskEnabled: true
            maskSource: artMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }
    }

    component Equalizer: Row {
        id: eq
        property int barHeight: 14
        spacing: 2
        height: barHeight

        Repeater {
            model: [0.55, 1.0, 0.7, 0.9]
            Item {
                required property real modelData
                required property int index
                width: 2.5
                height: eq.barHeight

                Rectangle {
                    id: bar
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    radius: width / 2
                    color: root.accent
                    height: root.playing ? eq.barHeight * parent.modelData : 3
                    Behavior on height { enabled: !barMotion.running; NumberAnimation { duration: 200 } }

                    SequentialAnimation on height {
                        id: barMotion
                        running: root.playing && root.expanded
                        loops: Animation.Infinite
                        NumberAnimation { to: eq.barHeight * 0.25; duration: 260 + index * 70; easing.type: Easing.InOutSine }
                        NumberAnimation { to: eq.barHeight * modelData; duration: 300 + index * 50; easing.type: Easing.InOutSine }
                    }
                }
            }
        }
    }

    component ProgressLine: Column {
        spacing: 3

        Item {
            width: parent.width
            height: 10

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 4
                radius: 2
                color: "#2effffff"

                Rectangle {
                    height: parent.height
                    radius: 2
                    color: root.accent
                    width: root.hasMedia && root.player.length > 0
                           ? parent.width * Math.min(1, root.player.position / root.player.length)
                           : 0
                }
            }
            MouseArea {
                anchors.fill: parent
                enabled: root.hasMedia && root.player.canSeek && root.player.length > 0
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: mouse => root.seekTo(root.player.length * (mouse.x / width))
            }
        }
        Item {
            width: parent.width
            height: 12
            visible: root.hasMedia && root.player.length > 0

            Text {
                text: root.hasMedia ? root.formatTime(root.player.position) : ""
                color: "#80ffffff"
                font.pixelSize: 10
                font.features: { "tnum": 1 }
            }
            Text {
                anchors.right: parent.right
                text: root.hasMedia ? root.formatTime(root.player.length) : ""
                color: "#80ffffff"
                font.pixelSize: 10
                font.features: { "tnum": 1 }
            }
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.expanded && root.playing
        triggeredOnStart: true
        onTriggered: root.player.updatePosition()
    }

    component ControlButton: Item {
        id: button
        property string icon
        property int size: 34
        signal clicked
        width: size
        height: size
        opacity: enabled ? 1 : 0.35
        scale: area.pressed ? 0.86 : 1
        Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutBack } }

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "#ffffff"
            opacity: area.containsMouse ? 0.12 : 0
            Behavior on opacity { NumberAnimation { duration: 120 } }
        }
        Kirigami.Icon {
            anchors.centerIn: parent
            width: Math.round(button.size * 0.52)
            height: width
            source: button.icon
            isMask: true
            color: "#ffffff"
        }
        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }

    component StatRing: Item {
        id: stat
        property string label
        property string detail
        property string centerText
        property real fraction: 0
        property color alert: "#ffffff"
        readonly property bool alerting: alert !== Qt.color("#ffffff")
        readonly property color ringColor: alerting ? alert : root.accent

        width: (expandedContent.width - 16) / 3
        height: 56

        property real shownFraction: Math.max(0, Math.min(1, fraction))
        Behavior on shownFraction { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }

        Item {
            id: ring
            width: 52
            height: 52
            anchors.verticalCenter: parent.verticalCenter

            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    fillColor: "transparent"
                    strokeColor: "#24ffffff"
                    strokeWidth: 4.5
                    capStyle: ShapePath.RoundCap
                    PathAngleArc { centerX: 26; centerY: 26; radiusX: 22; radiusY: 22; startAngle: -90; sweepAngle: 360 }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: stat.ringColor
                    strokeWidth: 4.5
                    capStyle: ShapePath.RoundCap
                    PathAngleArc { centerX: 26; centerY: 26; radiusX: 22; radiusY: 22; startAngle: -90; sweepAngle: 360 * stat.shownFraction }
                }
            }
            Text {
                anchors.centerIn: parent
                text: stat.centerText
                color: stat.alert
                font.pixelSize: 12
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
        }
        Column {
            anchors.left: ring.right
            anchors.leftMargin: 9
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                text: stat.label
                color: "#ffffff"
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.letterSpacing: 0.4
            }
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: stat.detail
                color: "#90ffffff"
                font.pixelSize: 11
                font.features: { "tnum": 1 }
            }
        }
    }
}
