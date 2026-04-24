#!/bin/sh
set -e

mkdir -p /root/data

# Read config values (config.yaml exists on 0.3.5.1, may not on 0.4.0)
if [ -f /root/start9/config.yaml ]; then
  DATUM_STRATUM_PORT=$(yq e '.advanced.datum_stratum_port // 23335' /root/start9/config.yaml)
else
  DATUM_STRATUM_PORT="${DATUM_STRATUM_PORT:-23335}"
fi
DATUM_HOST="${DATUM_HOST:-datum.embassy}"
# LISTEN_PORT: the port socat/playit/ssh-tunnel use locally.
# Defaults to DATUM_STRATUM_PORT so the simple case doesn't need configuration.
LISTEN_PORT="${LISTEN_PORT:-${DATUM_STRATUM_PORT}}"
# DATUM_REMOTE_PORT: the actual stratum port on Datum Gateway (may differ from LISTEN_PORT).
DATUM_REMOTE_PORT="${DATUM_REMOTE_PORT:-${DATUM_STRATUM_PORT}}"

# Export so the node backend's managers (vps-manager, tunnel-status) can read them.
# Without export, these are shell-local and process.env won't see them.
export DATUM_STRATUM_PORT DATUM_HOST LISTEN_PORT DATUM_REMOTE_PORT

echo "[hashgg] Listen port (socat/playit): ${LISTEN_PORT}"
echo "[hashgg] Datum remote port: ${DATUM_REMOTE_PORT}"
echo "[hashgg] Datum host: ${DATUM_HOST}"

# Start socat TCP proxy directly in background (no pipeline subshell — that would
# orphan the process and cause "stuck in Stopping" on container shutdown).
echo "[hashgg] Starting socat proxy: 127.0.0.1:${LISTEN_PORT} -> ${DATUM_HOST}:${DATUM_REMOTE_PORT}"
socat -d -d TCP-LISTEN:${LISTEN_PORT},fork,reuseaddr TCP:${DATUM_HOST}:${DATUM_REMOTE_PORT} &
SOCAT_PID=$!

# Start the Node.js backend (manages playit/ssh agent lifecycle + serves UI)
echo "[hashgg] Starting backend server..."
node /usr/local/lib/hashgg/backend/server.js &
NODE_PID=$!

# Forward SIGTERM/SIGINT to children so the container stops cleanly.
# Without this, `docker stop` / StartOS "Stop" will hit the 30s grace timeout
# and fall back to SIGKILL — which manifests in the UI as "stuck in Stopping".
shutdown() {
  echo "[hashgg] Received shutdown signal, stopping children..."
  kill -TERM "$NODE_PID" 2>/dev/null || true
  kill -TERM "$SOCAT_PID" 2>/dev/null || true
  wait "$NODE_PID" 2>/dev/null || true
  wait "$SOCAT_PID" 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT

# Wait on whichever child exits first, then tear down the other.
# `wait -n` isn't portable to all /bin/sh, so poll instead.
while kill -0 "$NODE_PID" 2>/dev/null && kill -0 "$SOCAT_PID" 2>/dev/null; do
  sleep 1
done
echo "[hashgg] A child process exited, stopping the other..."
kill -TERM "$NODE_PID" 2>/dev/null || true
kill -TERM "$SOCAT_PID" 2>/dev/null || true
wait
exit 1
