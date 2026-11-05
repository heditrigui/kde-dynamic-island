#!/usr/bin/env bash
# Installs or removes the Dynamic Island systemd user service.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$HOME/.local/share/dynamic-island"
unit_dir="$HOME/.config/systemd/user"
host_name="com.github.heditrigui.dynamic_island"
extension_id="hekedoiedpcpppcpkajheahaefapiail"
browser_dirs=(BraveSoftware/Brave-Browser google-chrome chromium microsoft-edge vivaldi)

if [[ "${1:-}" == "--uninstall" ]]; then
    systemctl --user disable --now dynamic-island.service dynamic-island-tray.service 2>/dev/null || true
    rm -f "$unit_dir/dynamic-island.service" "$unit_dir/dynamic-island-tray.service"
    systemctl --user daemon-reload
    for browser in "${browser_dirs[@]}"; do
        rm -f "$HOME/.config/$browser/NativeMessagingHosts/$host_name.json"
    done
    # Leave the folder alone if it is a git checkout rather than an installed copy.
    if [[ ! -d "$app_dir/.git" ]]; then
        rm -f "$app_dir/island.qml" "$app_dir/tray.py" "$app_dir/tab_media_host.py"
        rm -rf "$app_dir/browser-extension"
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
[[ "$src" -ef "$app_dir" ]] || cp -r "$src/island.qml" "$src/tray.py" "$src/tab_media_host.py" "$src/browser-extension" "$app_dir/"
sed "s|/usr/bin/qml6|$(command -v qml6)|" "$src/dynamic-island.service" > "$unit_dir/dynamic-island.service"

cp "$src/dynamic-island-tray.service" "$unit_dir/dynamic-island-tray.service"

# Lets the optional browser extension start its helper, in the browsers installed here.
for browser in "${browser_dirs[@]}"; do
    [[ -d "$HOME/.config/$browser" ]] || continue
    mkdir -p "$HOME/.config/$browser/NativeMessagingHosts"
    cat > "$HOME/.config/$browser/NativeMessagingHosts/$host_name.json" <<EOF
{
  "name": "$host_name",
  "description": "Gives each browser tab with media its own MPRIS player",
  "path": "$app_dir/tab_media_host.py",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$extension_id/"]
}
EOF
done

systemctl --user daemon-reload
systemctl --user enable dynamic-island.service dynamic-island-tray.service
systemctl --user restart dynamic-island.service dynamic-island-tray.service
echo "Dynamic Island installed. Move your cursor to the top centre of the screen."
