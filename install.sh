#!/usr/bin/env bash
# Installs or removes the Dynamic Island systemd user service.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$HOME/.local/share/dynamic-island"
unit_dir="$HOME/.config/systemd/user"

if [[ "${1:-}" == "--uninstall" ]]; then
    systemctl --user disable --now dynamic-island.service dynamic-island-tray.service 2>/dev/null || true
    rm -f "$unit_dir/dynamic-island.service" "$unit_dir/dynamic-island-tray.service"
    systemctl --user daemon-reload
    # Leave the folder alone if it is a git checkout rather than an installed copy.
    if [[ ! -d "$app_dir/.git" ]]; then
        rm -f "$app_dir/island.qml" "$app_dir/tray.py"
        rmdir "$app_dir" 2>/dev/null || true
    fi
    echo "Dynamic Island removed."
    exit 0
fi

if ! command -v qml6 >/dev/null; then
    echo "qml6 was not found. Install the Qt 6 QML runtime first." >&2
    exit 1
fi

mkdir -p "$app_dir" "$unit_dir"
[[ "$src" -ef "$app_dir" ]] || cp "$src/island.qml" "$src/tray.py" "$app_dir/"
sed "s|/usr/bin/qml6|$(command -v qml6)|" "$src/dynamic-island.service" > "$unit_dir/dynamic-island.service"

cp "$src/dynamic-island-tray.service" "$unit_dir/dynamic-island-tray.service"

systemctl --user daemon-reload
systemctl --user enable dynamic-island.service dynamic-island-tray.service
systemctl --user restart dynamic-island.service dynamic-island-tray.service
echo "Dynamic Island installed. Move your cursor to the top centre of the screen."
