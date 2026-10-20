#!/bin/bash
set -e

echo "=========================================="
echo " Seamless Clipboard Sync - Ubuntu Setup "
echo "=========================================="

# 1. Interactive Parameters with generic defaults
read -p "Enter Windows IP / Host [default: 192.168.1.100]: " WIN_HOST
WIN_HOST=${WIN_HOST:-192.168.1.100}

read -p "Enter Windows SSH Port [default: 2222]: " WIN_PORT
WIN_PORT=${WIN_PORT:-2222}

read -p "Enter Windows Username [default: antonc]: " WIN_USER
WIN_USER=${WIN_USER:-antonc}

LOCAL_USER=$(whoami)
HOME_DIR=$HOME

echo ""
echo "Configuration parameters:"
echo "  Local Ubuntu User: $LOCAL_USER ($HOME_DIR)"
echo "  Windows Target:    $WIN_USER@$WIN_HOST:$WIN_PORT"
echo ""

# 2. Package Dependency Checks
echo "[1/6] Checking and installing apt dependencies..."
sudo apt update
sudo apt install -y wl-clipboard python3 openssh-client

# 3. Passwordless SSH Verification
echo "[2/6] Verifying SSH connectivity to Windows host..."
if ! ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$WIN_PORT" "$WIN_USER@$WIN_HOST" exit 2>/dev/null; then
    echo " -> WARNING: Passwordless SSH authentication failed."
    read -p "Would you like to setup SSH key copying now (ssh-copy-id)? (y/n): " SETUP_SSH
    if [[ "$SETUP_SSH" =~ ^[Yy]$ ]]; then
        ssh-copy-id -p "$WIN_PORT" "$WIN_USER@$WIN_HOST"
    fi
fi

# 4. Generate ~/sync_daemon.py (Async Unix Socket & TCP Listener with Wayland support)
echo "[3/6] Generating ~/sync_daemon.py..."
cat << 'EOF' > "$HOME_DIR/sync_daemon.py"
import asyncio
import base64
import os
import subprocess
import sys

UNIX_SOCKET_PATH = f"/run/user/{os.getuid()}/clip_sync.sock"
WIN_HOST = "__WIN_HOST__"
WIN_PORT = "__WIN_PORT__"
WIN_USER = "__WIN_USER__"
LISTEN_TCP_PORT = 9999

last_text = ""

def sanitize(text):
    if not text:
        return ""
    return text.lstrip("\ufeff").strip()

def set_ubuntu_clip(text):
    """Applies incoming text from Windows to local Ubuntu clipboard using wl-copy."""
    clean = sanitize(text)
    if not clean:
        return

    try:
        # Pass Wayland runtime environment explicitly for background daemon
        env = os.environ.copy()
        env["XDG_RUNTIME_DIR"] = f"/run/user/{os.getuid()}"
        if not env.get("WAYLAND_DISPLAY"):
            env["WAYLAND_DISPLAY"] = "wayland-0"

        subprocess.run(
            ["wl-copy"],
            input=clean.encode("utf-8"),
            env=env,
            check=True
        )
        print(f"[+] Updated Ubuntu Clipboard via wl-copy: {repr(clean[:35])}")
    except Exception as e:
        print(f"[-] Error setting clipboard via wl-copy: {e}")

async def send_to_windows(text):
    """Encodes PowerShell command to UTF-16LE Base64 (-EncodedCommand) for safe dispatch."""
    try:
        raw_b64 = base64.b64encode(text.encode("utf-8")).decode("ascii")

        ps_script = (
            f"$bytes = [Convert]::FromBase64String('{raw_b64}'); "
            f"[IO.File]::WriteAllBytes(\"$HOME\\.clip\\to_win.txt\", $bytes); "
            f"schtasks /run /tn PasteWinClip"
        )

        encoded_ps = base64.b64encode(ps_script.encode("utf-16le")).decode("ascii")

        cmd = [
            "ssh",
            "-p", WIN_PORT,
            f"{WIN_USER}@{WIN_HOST}",
            f"powershell -NoProfile -EncodedCommand {encoded_ps}"
        ]

        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode == 0:
            print("[+] Dispatched Base64 payload to Windows successfully.")
        else:
            print(f"[-] SSH delivery failed (code {proc.returncode}): {stderr.decode().strip()}")
    except Exception as e:
        print(f"[-] SSH delivery exception: {e}")

async def handle_gnome_client(reader, writer):
    """Processes incoming clipboard notifications from GNOME extension socket."""
    global last_text
    try:
        data = await reader.read(-1)
        writer.close()
        await writer.wait_closed()

        text = data.decode("utf-8", errors="ignore")
        clean = sanitize(text)

        if clean and clean != last_text:
            last_text = clean
            print(f"[+] Local Copy Captured via GNOME Socket: {repr(clean[:35])}")
            await send_to_windows(clean)
    except Exception as e:
        print(f"[-] GNOME socket read error: {e}")

async def handle_win_client(reader, writer):
    """Processes incoming clipboard data forwarded from Windows via reverse SSH tunnel."""
    global last_text
    try:
        data = await reader.read(-1)
        writer.close()
        await writer.wait_closed()

        text = data.decode("utf-8", errors="ignore")
        clean = sanitize(text)

        if clean and clean != last_text:
            last_text = clean
            print(f"[+] Incoming Copy Received from Windows: {repr(clean[:35])}")
            set_ubuntu_clip(clean)
    except Exception as e:
        print(f"[-] TCP listener error: {e}")

async def start_unix_socket_server():
    if os.path.exists(UNIX_SOCKET_PATH):
        os.remove(UNIX_SOCKET_PATH)

    server = await asyncio.start_unix_server(handle_gnome_client, path=UNIX_SOCKET_PATH)
    os.chmod(UNIX_SOCKET_PATH, 0o600)
    print(f"[+] Listening for GNOME clipboard events at {UNIX_SOCKET_PATH}")
    async with server:
        await server.serve_forever()

async def start_tcp_server():
    server = await asyncio.start_server(handle_win_client, "127.0.0.1", LISTEN_TCP_PORT)
    print(f"[+] Listening for Windows incoming tunnel data on 127.0.0.1:{LISTEN_TCP_PORT}")
    async with server:
        await server.serve_forever()

async def main():
    print("[+] Starting Clipboard Sync Daemon...")
    await asyncio.gather(
        start_unix_socket_server(),
        start_tcp_server()
    )

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[-] Sync daemon stopped.")
EOF

sed -i "s/__WIN_USER__/$WIN_USER/g" "$HOME_DIR/sync_daemon.py"
sed -i "s/__WIN_HOST__/$WIN_HOST/g" "$HOME_DIR/sync_daemon.py"
sed -i "s/__WIN_PORT__/$WIN_PORT/g" "$HOME_DIR/sync_daemon.py"
chmod +x "$HOME_DIR/sync_daemon.py"

# 5. Generate ~/start-clip-sync.sh (Runs daemon and persistent reverse SSH tunnel)
echo "[4/6] Generating ~/start-clip-sync.sh..."
cat << EOF > "$HOME_DIR/start-clip-sync.sh"
#!/bin/bash
cleanup() {
    pkill -P \$\$ 2>/dev/null
    exit 0
}
trap cleanup INT TERM EXIT

# Run async socket daemon in background
python3 "$HOME_DIR/sync_daemon.py" &

# Maintain persistent reverse SSH tunnel for Windows -> Ubuntu communication
while true; do
    ssh -o ConnectTimeout=5 -N -R 9999:127.0.0.1:9999 -p "$WIN_PORT" "$WIN_USER@$WIN_HOST"
    sleep 3
done
EOF

chmod +x "$HOME_DIR/start-clip-sync.sh"

# 6. Install GNOME Shell Extension for Wayland Clipboard Interception
echo "[5/6] Installing GNOME Shell Extension..."
EXT_DIR="$HOME_DIR/.local/share/gnome-shell/extensions/clip-sync-bridge@local"
mkdir -p "$EXT_DIR"

cat << 'EOF' > "$EXT_DIR/metadata.json"
{
  "name": "Clip Sync Bridge",
  "description": "Bridge local GNOME Wayland clipboard changes to Sunshine sync daemon via Unix socket",
  "uuid": "clip-sync-bridge@local",
  "shell-version": [ "45", "46", "47", "48", "49", "50" ]
}
EOF

cat << 'EOF' > "$EXT_DIR/extension.js"
import Meta from 'gi://Meta';
import St from 'gi://St';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';

export default class ClipSyncBridgeExtension extends Extension {
    enable() {
        this._selection = global.display.get_selection();
        this._selectionId = this._selection.connect('owner-changed', (selection, selectionType) => {
            if (selectionType === Meta.SelectionType.SELECTION_CLIPBOARD) {
                this._onClipboardChanged();
            }
        });
    }

    _onClipboardChanged() {
        let clipboard = St.Clipboard.get_default();
        clipboard.get_text(St.ClipboardType.CLIPBOARD, (cb, text) => {
            if (text) {
                this._sendToSocket(text);
            }
        });
    }

    _sendToSocket(text) {
        try {
            let socketPath = `${GLib.get_user_runtime_dir()}/clip_sync.sock`;
            let file = Gio.File.new_for_path(socketPath);
            if (!file.query_exists(null)) return;

            let address = Gio.UnixSocketAddress.new_with_type(
                socketPath,
                Gio.UnixSocketAddressType.PATH
            );
            let client = new Gio.SocketClient();

            client.connect_async(address, null, (source, res) => {
                try {
                    let conn = client.connect_finish(res);
                    let output = conn.get_output_stream();
                    let encoder = new TextEncoder();
                    let bytes = new GLib.Bytes(encoder.encode(text));

                    output.write_bytes_async(bytes, GLib.PRIORITY_DEFAULT, null, (outSource, outRes) => {
                        try {
                            output.write_bytes_finish(outRes);
                            conn.close(null);
                        } catch (e) {}
                    });
                } catch (e) {}
            });
        } catch (e) {}
    }

    disable() {
        if (this._selectionId) {
            this._selection.disconnect(this._selectionId);
            this._selectionId = null;
        }
    }
}
EOF

# 7. Configure GNOME Autostart & enable extension
echo "[6/6] Configuring GNOME Autostart & enabling extension..."
mkdir -p "$HOME_DIR/.config/autostart"
cat << EOF > "$HOME_DIR/.config/autostart/clip-sync.desktop"
[Desktop Entry]
Type=Application
Name=Seamless Clipboard Sync
Exec=$HOME_DIR/start-clip-sync.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

# Automatically enable the extension via gnome-extensions CLI if available
if command -v gnome-extensions &> /dev/null; then
    gnome-extensions enable clip-sync-bridge@local || true
fi

echo ""
echo "=== Ubuntu Setup Completed Successfully ==="
echo "Generated files:"
echo "  - $HOME_DIR/sync_daemon.py"
echo "  - $HOME_DIR/start-clip-sync.sh"
echo "  - $HOME_DIR/.config/autostart/clip-sync.desktop"
echo "  - $EXT_DIR/"
