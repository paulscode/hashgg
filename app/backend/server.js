'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

const state = require('./state');
const playitManager = require('./playit-manager');
const claimFlow = require('./claim-flow');
const tunnelStatus = require('./tunnel-status');
const vpsManager = require('./vps-manager');
const sshKeygenHelper = require('./ssh-keygen-helper');

const PORT = 3000;
const FRONTEND_DIR = '/usr/local/lib/hashgg/frontend';
const CONFIG_FILE = '/root/start9/config.yaml';

const MIME_TYPES = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.json': 'application/json',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

// Read config for the stratum port. Precedence: DATUM_STRATUM_PORT env var
// (plain Docker use), then StartOS config.yaml, then default 23335.
function getStratumPort() {
  if (process.env.DATUM_STRATUM_PORT) {
    const p = parseInt(process.env.DATUM_STRATUM_PORT, 10);
    if (p) return p;
  }
  try {
    const { execSync } = require('child_process');
    const port = execSync(`yq e '.advanced.datum_stratum_port // 23335' ${CONFIG_FILE}`, { encoding: 'utf8' }).trim();
    return parseInt(port, 10) || 23335;
  } catch {
    return 23335;
  }
}

// Serve static files
function serveStatic(req, res) {
  let filePath = req.url === '/' ? '/index.html' : req.url;
  // Prevent directory traversal
  filePath = path.normalize(filePath).replace(/^(\.\.[\/\\])+/, '');
  const fullPath = path.join(FRONTEND_DIR, filePath);

  // Verify the resolved path is within FRONTEND_DIR
  if (!fullPath.startsWith(FRONTEND_DIR)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  const ext = path.extname(fullPath);
  const contentType = MIME_TYPES[ext] || 'application/octet-stream';

  fs.readFile(fullPath, (err, data) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Not found' }));
      return;
    }
    res.writeHead(200, { 'Content-Type': contentType });
    res.end(data);
  });
}

// Parse JSON body
function parseBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 1024 * 10) { // 10KB limit
        reject(new Error('Body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      const body = Buffer.concat(chunks).toString();
      if (!body) { resolve({}); return; }
      try {
        resolve(JSON.parse(body));
      } catch (e) {
        reject(new Error('Invalid JSON'));
      }
    });
    req.on('error', reject);
  });
}

// Send JSON response
function sendJson(res, statusCode, data) {
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

// API route handlers
async function handleApi(req, res) {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  const pathname = url.pathname;

  // GET /api/status
  if (pathname === '/api/status' && req.method === 'GET') {
    const s = state.get();
    sendJson(res, 200, {
      agent_status: s.agent_status,
      public_endpoint: s.public_endpoint,
      tunnel_id: s.tunnel_id,
      claim_status: s.claim_status,
      has_secret: !!s.playit_secret,
      uptime: playitManager.getUptime(),
    });
    return;
  }

  // POST /api/claim/start
  if (pathname === '/api/claim/start' && req.method === 'POST') {
    const result = await claimFlow.startClaim();
    sendJson(res, 200, result);
    return;
  }

  // GET /api/claim/status
  if (pathname === '/api/claim/status' && req.method === 'GET') {
    sendJson(res, 200, claimFlow.getClaimStatus());
    return;
  }

  // POST /api/secret
  if (pathname === '/api/secret' && req.method === 'POST') {
    const body = await parseBody(req);
    const key = body.secret_key;

    if (!key || typeof key !== 'string') {
      sendJson(res, 400, { error: 'secret_key is required' });
      return;
    }

    // Validate hex string
    if (!/^[0-9a-fA-F]+$/.test(key)) {
      sendJson(res, 400, { error: 'secret_key must be a hex string' });
      return;
    }

    state.update({
      playit_secret: key,
      claim_status: 'completed',
      claim_code: null,
    });

    // Start the agent with the new key
    playitManager.restart();
    const stratumPort = getStratumPort();
    tunnelStatus.startPolling(stratumPort);

    sendJson(res, 200, { ok: true });
    return;
  }

  // POST /api/restart
  if (pathname === '/api/restart' && req.method === 'POST') {
    playitManager.restart();
    sendJson(res, 200, { ok: true });
    return;
  }

  // POST /api/reset
  if (pathname === '/api/reset' && req.method === 'POST') {
    playitManager.stop();
    tunnelStatus.stopPolling();
    // Clean up any VPS artifacts too (defensive — in case state had leftover VPS data)
    try { require('fs').unlinkSync('/root/data/vps_ssh_key'); } catch (_) {}
    try { require('fs').unlinkSync('/root/data/vps_known_hosts'); } catch (_) {}
    state.reset();
    sendJson(res, 200, { ok: true });
    return;
  }

  // --- VPS Tunnel API ---

  // GET /api/tunnel/mode
  if (pathname === '/api/tunnel/mode' && req.method === 'GET') {
    sendJson(res, 200, { mode: state.get().tunnel_mode });
    return;
  }

  // POST /api/tunnel/mode
  if (pathname === '/api/tunnel/mode' && req.method === 'POST') {
    const body = await parseBody(req);
    if (body.mode !== 'playit' && body.mode !== 'vps') {
      sendJson(res, 400, { error: 'mode must be playit or vps' });
      return;
    }
    state.update({ tunnel_mode: body.mode });
    sendJson(res, 200, { ok: true });
    return;
  }

  // GET /api/vps/key — return (or generate) the SSH public key
  if (pathname === '/api/vps/key' && req.method === 'GET') {
    let s = state.get();
    if (!s.vps_ssh_public_key || !s.vps_ssh_private_key) {
      const { privateKeyPem, publicKeyOpenSSH } = sshKeygenHelper.generateKeyPair();
      state.update({ vps_ssh_private_key: privateKeyPem, vps_ssh_public_key: publicKeyOpenSSH });
      s = state.get();
    }
    sendJson(res, 200, { public_key: s.vps_ssh_public_key });
    return;
  }

  // GET /api/vps/setup-script — return bash script with public key embedded
  if (pathname === '/api/vps/setup-script' && req.method === 'GET') {
    let s = state.get();
    if (!s.vps_ssh_public_key || !s.vps_ssh_private_key) {
      const { privateKeyPem, publicKeyOpenSSH } = sshKeygenHelper.generateKeyPair();
      state.update({ vps_ssh_private_key: privateKeyPem, vps_ssh_public_key: publicKeyOpenSSH });
      s = state.get();
    }
    const remotePort = s.vps_remote_port || 23335;
    const script = buildSetupScript(s.vps_ssh_public_key, remotePort);
    sendJson(res, 200, { script });
    return;
  }

  // POST /api/vps/configure
  if (pathname === '/api/vps/configure' && req.method === 'POST') {
    const body = await parseBody(req);
    const host = body.host;
    const sshPort = body.ssh_port !== undefined ? Number(body.ssh_port) : undefined;
    const sshUser = body.ssh_user;
    const remotePort = body.remote_port !== undefined ? Number(body.remote_port) : undefined;

    if (!host || typeof host !== 'string') {
      sendJson(res, 400, { error: 'host is required' });
      return;
    }
    if (!/^[a-zA-Z0-9.\-:]+$/.test(host) || host.length > 255) {
      sendJson(res, 400, { error: 'invalid host' });
      return;
    }
    if (sshPort !== undefined && (isNaN(sshPort) || sshPort < 1 || sshPort > 65535)) {
      sendJson(res, 400, { error: 'ssh_port must be 1–65535' });
      return;
    }
    if (sshUser !== undefined && !/^[a-z_][a-z0-9_\-]{0,31}$/.test(sshUser)) {
      sendJson(res, 400, { error: 'invalid ssh_user' });
      return;
    }
    if (remotePort !== undefined && (isNaN(remotePort) || remotePort < 1024 || remotePort > 65535)) {
      sendJson(res, 400, { error: 'remote_port must be 1024–65535' });
      return;
    }

    const patch = { vps_host: host };
    if (sshPort !== undefined) patch.vps_ssh_port = sshPort;
    if (sshUser !== undefined) patch.vps_ssh_user = sshUser;
    if (remotePort !== undefined) patch.vps_remote_port = remotePort;
    state.update(patch);
    sendJson(res, 200, { ok: true });
    return;
  }

  // POST /api/vps/connect
  if (pathname === '/api/vps/connect' && req.method === 'POST') {
    const s = state.get();
    if (!s.vps_host || !s.vps_ssh_private_key) {
      sendJson(res, 400, { error: 'VPS not configured' });
      return;
    }
    vpsManager.start();
    sendJson(res, 200, { ok: true });
    return;
  }

  // POST /api/vps/disconnect
  if (pathname === '/api/vps/disconnect' && req.method === 'POST') {
    vpsManager.stop();
    sendJson(res, 200, { ok: true });
    return;
  }

  // GET /api/vps/status
  if (pathname === '/api/vps/status' && req.method === 'GET') {
    const s = state.get();
    sendJson(res, 200, {
      configured: !!(s.vps_host && s.vps_ssh_private_key),
      host: s.vps_host,
      remote_port: s.vps_remote_port || 23335,
      tunnel_status: s.vps_tunnel_status || 'disconnected',
      last_error: s.vps_last_error || null,
      public_endpoint: s.public_endpoint,
      uptime: vpsManager.getUptime(),
    });
    return;
  }

  // POST /api/vps/reset
  if (pathname === '/api/vps/reset' && req.method === 'POST') {
    vpsManager.stop();
    // Clear known_hosts so next connect re-verifies host key
    try { require('fs').unlinkSync('/root/data/vps_known_hosts'); } catch (_) {}
    try { require('fs').unlinkSync('/root/data/vps_ssh_key'); } catch (_) {}
    state.update({
      vps_host: null,
      vps_ssh_port: 22,
      vps_ssh_user: 'hashgg',
      vps_remote_port: 23335,
      vps_ssh_private_key: null,
      vps_ssh_public_key: null,
      vps_tunnel_status: 'disconnected',
      vps_last_error: null,
      tunnel_mode: null,
      public_endpoint: null,
    });
    sendJson(res, 200, { ok: true });
    return;
  }

  // POST /api/vps/test-connection
  if (pathname === '/api/vps/test-connection' && req.method === 'POST') {
    const s = state.get();
    if (!s.vps_host || !s.vps_ssh_private_key) {
      sendJson(res, 400, { error: 'VPS not configured' });
      return;
    }
    const result = await testVpsSshAuth(s);
    sendJson(res, 200, result);
    return;
  }

  // GET /api/diag — test internal stratum connectivity
  if (pathname === '/api/diag' && req.method === 'GET') {
    const net = require('net');
    const stratumPort = getStratumPort();
    const results = {};

    // Test 1: Can we connect to 127.0.0.1:stratumPort (socat)?
    const testLocal = () => new Promise((resolve) => {
      const sock = net.createConnection({ host: '127.0.0.1', port: stratumPort }, () => {
        results.local_connect = 'ok';
        // Test 2: Send mining.subscribe and check response
        const msg = JSON.stringify({id:1,method:'mining.subscribe',params:['diag/1.0']}) + '\n';
        sock.write(msg);
        sock.setTimeout(5000);
        sock.on('data', (data) => {
          results.local_response = data.toString().trim();
          sock.destroy();
          resolve();
        });
        sock.on('timeout', () => {
          results.local_response = 'timeout (5s)';
          sock.destroy();
          resolve();
        });
        sock.on('error', (err) => {
          results.local_response = 'error: ' + err.message;
          resolve();
        });
      });
      sock.on('error', (err) => {
        results.local_connect = 'error: ' + err.message;
        resolve();
      });
      sock.setTimeout(5000);
    });

    // Test 3: Can we connect to Datum directly at its configured host:port?
    // Matches the entrypoint's DATUM_HOST default so plain-Docker users don't
    // see a bogus failure here; StartOS inherits 'datum.embassy'.
    const datumHost = process.env.DATUM_HOST || 'datum.embassy';
    const testDatum = () => new Promise((resolve) => {
      const sock = net.createConnection({ host: datumHost, port: stratumPort }, () => {
        results.datum_connect = 'ok';
        const msg = JSON.stringify({id:1,method:'mining.subscribe',params:['diag/1.0']}) + '\n';
        sock.write(msg);
        sock.setTimeout(5000);
        sock.on('data', (data) => {
          results.datum_response = data.toString().trim();
          sock.destroy();
          resolve();
        });
        sock.on('timeout', () => {
          results.datum_response = 'timeout (5s)';
          sock.destroy();
          resolve();
        });
        sock.on('error', (err) => {
          results.datum_response = 'error: ' + err.message;
          resolve();
        });
      });
      sock.on('error', (err) => {
        results.datum_connect = 'error: ' + err.message;
        resolve();
      });
      sock.setTimeout(5000);
    });

    await testLocal();
    await testDatum();
    results.stratum_port = stratumPort;
    results.datum_host = datumHost;

    // Test 3: Check V1 rundata (what playitd daemon uses for OriginLookup)
    const s2 = state.get();
    if (s2.playit_secret) {
      try {
        const v1Res = await new Promise((resolve, reject) => {
          const payload = JSON.stringify({});
          const reqOpts = {
            hostname: 'api.playit.gg',
            port: 443,
            path: '/v1/agents/rundata',
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Authorization': `agent-key ${s2.playit_secret}`,
              'Content-Length': Buffer.byteLength(payload),
            },
          };
          const apiReq = require('https').request(reqOpts, (apiRes) => {
            let d = '';
            apiRes.on('data', (c) => { d += c; });
            apiRes.on('end', () => {
              try { resolve({ status: apiRes.statusCode, body: JSON.parse(d) }); }
              catch (_) { resolve({ status: apiRes.statusCode, body: d }); }
            });
          });
          apiReq.on('error', reject);
          apiReq.setTimeout(8000, () => apiReq.destroy(new Error('timeout')));
          apiReq.write(payload);
          apiReq.end();
        });

        if (v1Res.status === 200) {
          const v1Data = v1Res.body?.data || v1Res.body || {};
          const tunnels = v1Data.tunnels || [];
          results.v1_tunnel_count = tunnels.length;
          if (tunnels.length > 0) {
            const t = tunnels[0];
            results.v1_tunnel = {
              id: t.id,
              internal_id: t.internal_id,
              name: t.name,
              display_address: t.display_address,
              tunnel_type: t.tunnel_type,
              agent_config_fields: (t.agent_config?.fields || []).map(f => `${f.name}=${f.value}`),
              disabled_reason: t.disabled_reason || null,
            };
          }
        } else {
          results.v1_error = `HTTP ${v1Res.status}: ${JSON.stringify(v1Res.body)}`;
        }
      } catch (err) {
        results.v1_error = err.message;
      }
    }

    // Test 4: Count running playitd processes
    try {
      const { execSync } = require('child_process');
      const ps = execSync('ps aux | grep playitd | grep -v grep', { encoding: 'utf8' }).trim();
      const lines = ps.split('\n').filter(Boolean);
      results.playitd_process_count = lines.length;
      results.playitd_processes = lines.map(l => l.replace(/\s+/g, ' ').substring(0, 120));
    } catch (_) {
      results.playitd_process_count = 0;
    }

    console.log('[diag] Results: ' + JSON.stringify(results));
    sendJson(res, 200, results);
    return;
  }

  sendJson(res, 404, { error: 'Not found' });
}

// Main request handler
async function handleRequest(req, res) {
  try {
    if (req.url.startsWith('/api/')) {
      await handleApi(req, res);
    } else {
      serveStatic(req, res);
    }
  } catch (err) {
    console.error(`[server] Error handling ${req.method} ${req.url}: ${err.message}`);
    sendJson(res, 500, { error: 'Internal server error' });
  }
}

// Generate the VPS setup script with the public key and stratum port embedded
function buildSetupScript(publicKey, stratumPort) {
  return `#!/bin/bash
set -euo pipefail

HASHGG_PUBKEY="${publicKey}"
STRATUM_PORT="${stratumPort}"
SSH_USER="hashgg"
SSH_HOME="/home/hashgg"
SSHD_CONF_DIR="/etc/ssh/sshd_config.d"

echo "=== HashGG VPS Setup ==="

# --- OS Detection ---
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_FAMILY="\${ID_LIKE:-} \${ID:-}"
else
  echo "Cannot detect OS"; exit 1
fi

is_debian() { echo "$OS_FAMILY" | grep -qiE 'debian|ubuntu'; }
is_rhel()   { echo "$OS_FAMILY" | grep -qiE 'rhel|fedora|centos|rocky|alma'; }

# --- Ensure openssh-server is present ---
if ! command -v sshd &>/dev/null; then
  echo "Installing openssh-server..."
  if is_debian; then
    apt-get update -qq && apt-get install -y -qq openssh-server
  elif is_rhel; then
    dnf install -y -q openssh-server 2>/dev/null || yum install -y -q openssh-server
    systemctl enable --now sshd
  else
    echo "Unsupported OS. Please install openssh-server manually."; exit 1
  fi
fi

# --- Create / fix hashgg user ---
if ! id "$SSH_USER" &>/dev/null; then
  echo "Creating user: $SSH_USER"
  useradd -r -m -d "$SSH_HOME" -s /usr/sbin/nologin "$SSH_USER"
else
  echo "User $SSH_USER already exists — repairing if needed"
fi
# Force home dir to be correct in /etc/passwd (fixes older scripts that used -M)
usermod -d "$SSH_HOME" "$SSH_USER" 2>/dev/null || true
usermod -s /usr/sbin/nologin "$SSH_USER" 2>/dev/null || true

# --- Set up home dir and SSH authorized_keys ---
mkdir -p "$SSH_HOME/.ssh"
echo "$HASHGG_PUBKEY" > "$SSH_HOME/.ssh/authorized_keys"
# Critical: sshd StrictModes requires these exact ownerships and permissions
chown -R "$SSH_USER:$SSH_USER" "$SSH_HOME" 2>/dev/null || chown -R "$SSH_USER" "$SSH_HOME"
chmod 755 "$SSH_HOME"
chmod 700 "$SSH_HOME/.ssh"
chmod 600 "$SSH_HOME/.ssh/authorized_keys"

# --- Ensure sshd reads drop-in configs ---
MAIN_CONF="/etc/ssh/sshd_config"
if [ -d "$SSHD_CONF_DIR" ]; then
  if ! grep -qE "^\\s*Include\\s+$SSHD_CONF_DIR/\\*\\.conf" "$MAIN_CONF" 2>/dev/null; then
    echo "Adding Include directive to $MAIN_CONF"
    # Include must be at the top, before any Match blocks
    sed -i "1i Include $SSHD_CONF_DIR/*.conf" "$MAIN_CONF"
  fi
  CONF_FILE="$SSHD_CONF_DIR/hashgg.conf"
else
  mkdir -p "$SSHD_CONF_DIR"
  CONF_FILE="$SSHD_CONF_DIR/hashgg.conf"
  if ! grep -qE "^\\s*Include\\s+$SSHD_CONF_DIR/\\*\\.conf" "$MAIN_CONF" 2>/dev/null; then
    sed -i "1i Include $SSHD_CONF_DIR/*.conf" "$MAIN_CONF"
  fi
fi

# --- Configure sshd for remote port forwarding (always overwrite our file) ---
cat > "$CONF_FILE" << 'SSHEOF'
# HashGG tunnel config — managed by HashGG, do not edit manually
Match User hashgg
    AllowTcpForwarding remote
    GatewayPorts clientspecified
    X11Forwarding no
    PermitTTY no
    ForceCommand /bin/false
    PubkeyAuthentication yes
    PasswordAuthentication no
    AuthorizedKeysFile /home/hashgg/.ssh/authorized_keys
SSHEOF
chmod 644 "$CONF_FILE"
echo "Wrote $CONF_FILE"

# --- Validate sshd config before reloading ---
if ! sshd -t 2>/tmp/sshd-test.log; then
  echo "ERROR: sshd config test failed:"
  cat /tmp/sshd-test.log
  exit 1
fi

# --- Open firewall port ---
echo "Opening port $STRATUM_PORT/tcp in firewall..."
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$STRATUM_PORT/tcp" comment "HashGG stratum" || true
elif command -v firewall-cmd &>/dev/null; then
  firewall-cmd --permanent --add-port="$STRATUM_PORT/tcp" --quiet 2>/dev/null || true
  firewall-cmd --reload --quiet 2>/dev/null || true
else
  echo "(No active firewall detected — ensure port $STRATUM_PORT is open in your VPS provider firewall.)"
fi

# --- Restart sshd (reload may not pick up Match blocks correctly on all distros) ---
echo "Restarting sshd..."
if systemctl list-units --type=service --all 2>/dev/null | grep -q "ssh\\.service"; then
  systemctl restart ssh
elif systemctl list-units --type=service --all 2>/dev/null | grep -q "sshd\\.service"; then
  systemctl restart sshd
else
  service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
fi

# --- Self-test: show what sshd will actually apply for the hashgg user ---
echo ""
echo "=== Verification ==="
echo "User entry:      $(getent passwd $SSH_USER)"
echo "Home dir exists: $([ -d "$SSH_HOME" ] && echo yes || echo no)"
echo "authorized_keys: $(wc -l < "$SSH_HOME/.ssh/authorized_keys" 2>/dev/null || echo MISSING) line(s), $(stat -c '%a %U:%G' "$SSH_HOME/.ssh/authorized_keys" 2>/dev/null || echo '?')"
EFFECTIVE_AUTH=$(sshd -T -C user=$SSH_USER 2>/dev/null | grep -i authorizedkeysfile || echo "(not set)")
echo "sshd effective:  $EFFECTIVE_AUTH"
EFFECTIVE_PUBKEY=$(sshd -T -C user=$SSH_USER 2>/dev/null | grep -i pubkeyauthentication || echo "(not set)")
echo "sshd pubkeyauth: $EFFECTIVE_PUBKEY"

echo ""
echo "=== Setup complete! ==="
echo "Return to HashGG and click Test Connection."
`;
}

// Test SSH authentication (non-forwarding) — returns { success, error }
function testVpsSshAuth(s) {
  return new Promise((resolve) => {
    const { spawn: spawnProc } = require('child_process');
    const KEY_FILE = '/root/data/vps_ssh_key';
    const KNOWN_HOSTS_FILE = '/root/data/vps_known_hosts';
    try { require('fs').writeFileSync(KEY_FILE, s.vps_ssh_private_key, { mode: 0o600 }); }
    catch (e) { return resolve({ success: false, error: 'Failed to write key file' }); }

    // IPv6 addresses require bracket notation in SSH user@host form
    const sshHost = s.vps_host.includes(':') ? `[${s.vps_host}]` : s.vps_host;
    const args = [
      '-o', 'StrictHostKeyChecking=accept-new',
      '-o', `UserKnownHostsFile=${KNOWN_HOSTS_FILE}`,
      '-o', 'ConnectTimeout=10',
      '-o', 'BatchMode=yes',
      '-i', KEY_FILE,
      '-p', String(s.vps_ssh_port || 22),
      `${s.vps_ssh_user || 'hashgg'}@${sshHost}`,
    ];

    let stderr = '';
    const proc = spawnProc('/usr/bin/ssh', args, { stdio: ['ignore', 'ignore', 'pipe'] });
    proc.stderr.on('data', (d) => { stderr += d.toString(); });
    proc.on('error', (e) => resolve({ success: false, error: e.message }));
    proc.on('close', (code) => {
      // code 255 = SSH error (connection refused, auth failed, etc.)
      // code 0 or 1 = SSH connected (ForceCommand /bin/false exits 1)
      if (code === 255) {
        const msg = stderr.trim().split('\n').pop() || 'Connection failed';
        resolve({ success: false, error: msg });
      } else {
        resolve({ success: true, error: null });
      }
    });
    // Safety timeout
    setTimeout(() => { try { proc.kill(); } catch (_) {} resolve({ success: false, error: 'Timed out' }); }, 15000);
  });
}

// Startup
function main() {
  // Load state (applies migration for pre-VPS installs)
  state.load();

  // Check if secret was set via StartOS config
  const s = state.get();
  try {
    const { execSync } = require('child_process');
    const configSecret = execSync(`yq e '.playit.secret_key // ""' ${CONFIG_FILE}`, { encoding: 'utf8' }).trim();
    if (configSecret && configSecret !== 'null' && configSecret !== s.playit_secret) {
      console.log('[server] Secret key provided via StartOS config');
      state.update({ playit_secret: configSecret, claim_status: 'completed', tunnel_mode: 'playit' });
    }
  } catch (err) {
    console.log('[server] Could not read StartOS config, using stored state');
  }

  const mode = state.get().tunnel_mode;
  console.log(`[server] Tunnel mode: ${mode || 'not set'}`);

  const stratumPort = getStratumPort();

  if (mode === 'playit' && state.get().playit_secret) {
    playitManager.start();
    tunnelStatus.startPolling(stratumPort);
  } else if (mode === 'vps') {
    if (state.get().vps_host && state.get().vps_ssh_private_key) {
      vpsManager.start();
    }
  }

  // Watch for mode/claim changes driven from the UI:
  //  - fresh install picks 'playit' → completes claim → start playitd
  //  - existing install switches mode → start the right manager
  // The watcher runs unconditionally because `tunnel_mode` can become 'playit'
  // after boot on a fresh install.
  setInterval(() => {
    const current = state.get();
    if (current.tunnel_mode === 'playit'
        && current.claim_status === 'completed'
        && current.playit_secret
        && playitManager.status === 'stopped') {
      console.log('[server] Claim completed — starting playit agent');
      playitManager.start();
      tunnelStatus.startPolling(stratumPort);
    }
  }, 1000);

  // Start HTTP server
  const server = http.createServer(handleRequest);
  server.listen(PORT, '0.0.0.0', () => {
    console.log(`[server] HashGG backend listening on port ${PORT}`);
  });

  // Graceful shutdown: stop child tunnel processes so the container can exit.
  // Without this, SIGTERM exits node immediately but playitd/ssh children are
  // orphaned and the container hits the 30s SIGKILL timeout ("stuck in Stopping").
  const shutdown = (signal) => {
    console.log(`[server] Received ${signal}, shutting down...`);
    try { playitManager.stop(); } catch (_) {}
    try { vpsManager.stop(); } catch (_) {}
    try { tunnelStatus.stopPolling(); } catch (_) {}
    server.close(() => process.exit(0));
    // Failsafe: exit after 5s even if server.close hangs
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main();
