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
# LISTEN_PORT: the port socat/playit use locally (always matches DATUM_STRATUM_PORT on 0.3.5.1;
# on 0.4.0, playit creates its tunnel using this port via the server.js getStratumPort()).
LISTEN_PORT="${LISTEN_PORT:-${DATUM_STRATUM_PORT}}"
# DATUM_REMOTE_PORT: the actual stratum port on Datum Gateway (may differ from LISTEN_PORT on 0.4.0)
DATUM_REMOTE_PORT="${DATUM_REMOTE_PORT:-${DATUM_STRATUM_PORT}}"

echo "[hashgg] Listen port (socat/playit): ${LISTEN_PORT}"
echo "[hashgg] Datum remote port: ${DATUM_REMOTE_PORT}"
echo "[hashgg] Datum host: ${DATUM_HOST}"

# Start socat TCP proxy: forward local listen port to Datum Gateway's stratum port
# Use -d -d for verbose logging so we can see connection issues
echo "[hashgg] Starting socat proxy: 127.0.0.1:${LISTEN_PORT} -> ${DATUM_HOST}:${DATUM_REMOTE_PORT}"
socat -d -d TCP-LISTEN:${LISTEN_PORT},fork,reuseaddr TCP:${DATUM_HOST}:${DATUM_REMOTE_PORT} 2>&1 | while IFS= read -r line; do echo "[socat] $line"; done &
SOCAT_PID=$!

# Start the Node.js backend (manages playit agent lifecycle + serves UI)
echo "[hashgg] Starting backend server..."
exec node /usr/local/lib/hashgg/backend/server.js
