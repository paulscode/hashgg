'use strict';

const POLL_INTERVAL = 3000;
let pollHandle = null;
let currentScreen = null;
let currentMode = null; // 'playit' | 'vps' | null

// DOM elements
const screens = {
  setup: document.getElementById('screen-setup'),
  claim: document.getElementById('screen-claim'),
  dashboard: document.getElementById('screen-dashboard'),
  'tunnel-choice': document.getElementById('screen-tunnel-choice'),
  'vps-instructions': document.getElementById('screen-vps-instructions'),
  'vps-key': document.getElementById('screen-vps-key'),
  'vps-configure': document.getElementById('screen-vps-configure'),
  'vps-connecting': document.getElementById('screen-vps-connecting'),
};

const els = {
  // Setup (playit)
  btnStartClaim: document.getElementById('btn-start-claim'),
  btnSubmitSecret: document.getElementById('btn-submit-secret'),
  inputSecret: document.getElementById('input-secret'),
  // Claim
  claimUrl: document.getElementById('claim-url'),
  claimStatusDot: document.getElementById('claim-status-dot'),
  claimStatusText: document.getElementById('claim-status-text'),
  btnCancelClaim: document.getElementById('btn-cancel-claim'),
  // Dashboard (shared)
  endpointText: document.getElementById('endpoint-text'),
  btnCopy: document.getElementById('btn-copy'),
  copyFeedback: document.getElementById('copy-feedback'),
  dotTunnel: document.getElementById('dot-tunnel'),
  dotDatum: document.getElementById('dot-datum'),
  dotAgent: document.getElementById('dot-agent'),
  statusTunnel: document.getElementById('status-tunnel'),
  statusDatum: document.getElementById('status-datum'),
  statusAgent: document.getElementById('status-agent'),
  btnRestartTunnel: document.getElementById('btn-restart-tunnel'),
  btnReset: document.getElementById('btn-reset'),
  // Tunnel choice
  btnChoosePlayit: document.getElementById('btn-choose-playit'),
  btnChooseVps: document.getElementById('btn-choose-vps'),
  // VPS instructions
  btnVpsInstructionsContinue: document.getElementById('btn-vps-instructions-continue'),
  btnVpsInstructionsBack: document.getElementById('btn-vps-instructions-back'),
  // VPS configure (step 1: enter IP)
  inputVpsHost: document.getElementById('input-vps-host'),
  inputVpsSshPort: document.getElementById('input-vps-ssh-port'),
  inputVpsUser: document.getElementById('input-vps-user'),
  inputVpsRemotePort: document.getElementById('input-vps-remote-port'),
  btnVpsConfigureContinue: document.getElementById('btn-vps-configure-continue'),
  btnVpsConfigureBack: document.getElementById('btn-vps-configure-back'),
  // VPS key/script (step 2: run script)
  vpsSshCmd: document.getElementById('vps-ssh-cmd'),
  btnCopySshCmd: document.getElementById('btn-copy-ssh-cmd'),
  copySshCmdFeedback: document.getElementById('copy-ssh-cmd-feedback'),
  vpsScriptText: document.getElementById('vps-script-text'),
  btnCopyScript: document.getElementById('btn-copy-script'),
  copyScriptFeedback: document.getElementById('copy-script-feedback'),
  btnVpsTest: document.getElementById('btn-vps-test'),
  vpsTestStatus: document.getElementById('vps-test-status'),
  btnVpsConnect: document.getElementById('btn-vps-connect'),
  btnVpsKeyBack: document.getElementById('btn-vps-key-back'),
  // VPS connecting
  vpsConnectingDot: document.getElementById('vps-connecting-dot'),
  vpsConnectingText: document.getElementById('vps-connecting-text'),
  btnVpsConnectingCancel: document.getElementById('btn-vps-connecting-cancel'),
  // Error
  errorBar: document.getElementById('error-bar'),
  errorText: document.getElementById('error-text'),
};

// Screen management
function showScreen(name) {
  Object.values(screens).forEach(s => { if (s) s.style.display = 'none'; });
  if (screens[name]) {
    screens[name].style.display = 'block';
    currentScreen = name;
  }
}

function showError(msg) {
  els.errorText.textContent = msg;
  els.errorBar.style.display = 'block';
  setTimeout(() => { els.errorBar.style.display = 'none'; }, 8000);
}

// Copy helper. Three paths:
//   1. navigator.clipboard.writeText (modern, requires secure context + iframe clipboard-write permission)
//   2. document.execCommand('copy') via a hidden textarea (legacy fallback)
//   3. If both fail (e.g. embedded in Umbrel's iframe with no clipboard permission),
//      visually select the source element so the user can Ctrl-C manually with one
//      keystroke. The feedback text changes to make that clear.
function copyText(text, feedbackEl, sourceEl) {
  const flashFeedback = (msg) => {
    const originalText = feedbackEl.textContent;
    if (msg) feedbackEl.textContent = msg;
    feedbackEl.style.display = 'inline-block';
    setTimeout(() => {
      feedbackEl.style.display = 'none';
      if (msg) feedbackEl.textContent = originalText;
    }, 3000);
  };

  const tryExec = () => {
    try {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand('copy');
      document.body.removeChild(ta);
      return ok;
    } catch (_) {
      return false;
    }
  };

  const selectSource = () => {
    if (!sourceEl) return;
    const range = document.createRange();
    range.selectNodeContents(sourceEl);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  };

  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text)
      .then(() => flashFeedback())
      .catch(() => {
        if (tryExec()) flashFeedback();
        else { selectSource(); flashFeedback('Select & Ctrl-C'); }
      });
  } else if (tryExec()) {
    flashFeedback();
  } else {
    selectSource();
    flashFeedback('Select & Ctrl-C');
  }
}

// API helpers
async function api(method, path, body) {
  const opts = { method, headers: {} };
  if (body) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(`/api${path}`, opts);
  return res.json();
}

// ─── Status polling ────────────────────────────────────────────────────────────

async function pollStatus() {
  try {
    // Fetch tunnel mode first (cheap)
    const modeRes = await api('GET', '/tunnel/mode');
    const mode = modeRes.mode;
    currentMode = mode;

    if (!mode) {
      // Fresh install — show mode selection
      if (currentScreen !== 'tunnel-choice') showScreen('tunnel-choice');
      return;
    }

    if (mode === 'playit') {
      const status = await api('GET', '/status');
      updatePlayitUI(status);
    } else if (mode === 'vps') {
      const status = await api('GET', '/vps/status');
      // Only drive routing from poll if not in the setup flow
      if (!['vps-instructions', 'vps-key', 'vps-configure'].includes(currentScreen)) {
        updateVpsUI(status);
      }
    }
  } catch (err) {
    console.error('Poll error:', err);
  }
}

function startPolling() {
  stopPolling();
  pollStatus();
  pollHandle = setInterval(pollStatus, POLL_INTERVAL);
}

function stopPolling() {
  if (pollHandle) {
    clearInterval(pollHandle);
    pollHandle = null;
  }
}

// ─── Playit.gg UI logic ────────────────────────────────────────────────────────

function updatePlayitUI(status) {
  if (!status.has_secret && status.claim_status !== 'pending') {
    showScreen('setup');
    return;
  }
  if (status.claim_status === 'pending') {
    if (currentScreen !== 'claim') showScreen('claim');
    updateClaimUI(status);
    return;
  }
  showScreen('dashboard');
  updateDashboard(status, 'playit');
}

function updateClaimUI(status) {
  api('GET', '/claim/status').then(cs => {
    if (cs.claim_url) {
      els.claimUrl.href = cs.claim_url;
      els.claimUrl.textContent = cs.claim_url;
    }
    if (cs.status === 'completed') {
      els.claimStatusDot.className = 'dot dot-green';
      els.claimStatusText.textContent = 'Approved! Setting up tunnel...';
    } else if (cs.status === 'failed') {
      els.claimStatusDot.className = 'dot dot-red';
      els.claimStatusText.textContent = 'Setup failed. Please try again.';
      setTimeout(() => showScreen('setup'), 2000);
    } else {
      els.claimStatusDot.className = 'dot dot-yellow';
      els.claimStatusText.textContent = 'Waiting for approval...';
    }
  }).catch(() => {});
}

// ─── VPS UI logic ──────────────────────────────────────────────────────────────

function updateVpsUI(status) {
  if (!status.configured) {
    // Not yet configured — start VPS flow from configure (IP entry)
    if (!['vps-configure', 'vps-instructions'].includes(currentScreen)) {
      showScreen('vps-configure');
    }
    return;
  }
  if (status.tunnel_status === 'connected') {
    showScreen('dashboard');
    updateDashboard(status, 'vps');
    return;
  }
  if (currentScreen === 'vps-connecting') {
    // Update connecting screen live
    if (status.tunnel_status === 'error') {
      els.vpsConnectingDot.className = 'dot dot-red';
      els.vpsConnectingText.textContent = status.last_error || 'Connection failed — retrying…';
    } else {
      els.vpsConnectingDot.className = 'dot dot-yellow';
      els.vpsConnectingText.textContent = `Establishing SSH tunnel to ${status.host}…`;
    }
    return;
  }
  // If we have a host and aren't in setup flow, show dashboard with disconnected state
  if (status.host && currentScreen === 'dashboard') {
    updateDashboard(status, 'vps');
  }
}

// ─── Shared dashboard ─────────────────────────────────────────────────────────

function updateDashboard(status, mode) {
  // Endpoint
  if (status.public_endpoint) {
    const endpoint = `stratum+tcp://${status.public_endpoint}`;
    els.endpointText.textContent = endpoint;
    els.btnCopy.style.display = 'inline-block';
  } else {
    els.endpointText.textContent = mode === 'vps' ? 'Waiting for tunnel…' : 'Waiting for tunnel allocation…';
    els.btnCopy.style.display = 'none';
  }

  if (mode === 'vps') {
    // Tunnel status
    const tsMap = {
      connected:    { dot: 'dot-green', text: `Connected (${status.host})` },
      connecting:   { dot: 'dot-yellow', text: 'Connecting…' },
      error:        { dot: 'dot-red', text: status.last_error ? `Error: ${status.last_error}` : 'Error — retrying…' },
      disconnected: { dot: 'dot-gray', text: 'Disconnected' },
    };
    const ts = tsMap[status.tunnel_status] || { dot: 'dot-gray', text: status.tunnel_status };
    els.dotTunnel.className = `dot ${ts.dot}`;
    els.statusTunnel.textContent = ts.text;

    // Agent = SSH tunnel process
    if (status.tunnel_status === 'connected') {
      els.dotAgent.className = 'dot dot-green';
      els.statusAgent.textContent = `SSH tunnel (${formatUptime(status.uptime)})`;
    } else {
      els.dotAgent.className = 'dot dot-yellow';
      els.statusAgent.textContent = 'SSH tunnel';
    }

    els.btnRestartTunnel.style.display = 'inline-block';
  } else {
    // Playit mode
    if (status.public_endpoint) {
      els.dotTunnel.className = 'dot dot-green';
      els.statusTunnel.textContent = 'Connected';
    } else if (status.agent_status === 'running') {
      els.dotTunnel.className = 'dot dot-yellow';
      els.statusTunnel.textContent = 'Pending';
    } else {
      els.dotTunnel.className = 'dot dot-red';
      els.statusTunnel.textContent = 'Disconnected';
    }

    const agentMap = {
      running: { dot: 'dot-green', text: `Running (${formatUptime(status.uptime)})` },
      starting: { dot: 'dot-yellow', text: 'Starting...' },
      crashed: { dot: 'dot-red', text: 'Error — restarting...' },
      stopped: { dot: 'dot-gray', text: 'Stopped' },
    };
    const agent = agentMap[status.agent_status] || { dot: 'dot-gray', text: status.agent_status };
    els.dotAgent.className = `dot ${agent.dot}`;
    els.statusAgent.textContent = agent.text;

    els.btnRestartTunnel.style.display = 'none';
  }

  // Datum — same for both modes
  els.dotDatum.className = 'dot dot-green';
  els.statusDatum.textContent = 'Reachable';
}

function formatUptime(seconds) {
  if (!seconds || seconds < 60) return `${seconds || 0}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return `${h}h ${m}m`;
}

// ─── Event handlers: Tunnel choice ────────────────────────────────────────────

els.btnChoosePlayit.addEventListener('click', async () => {
  try {
    await api('POST', '/tunnel/mode', { mode: 'playit' });
    currentMode = 'playit';
    showScreen('setup');
  } catch (err) {
    showError('Failed to set tunnel mode: ' + err.message);
  }
});

els.btnChooseVps.addEventListener('click', async () => {
  try {
    await api('POST', '/tunnel/mode', { mode: 'vps' });
    currentMode = 'vps';
    showScreen('vps-instructions');
  } catch (err) {
    showError('Failed to set tunnel mode: ' + err.message);
  }
});

// ─── Event handlers: VPS instructions ────────────────────────────────────────

els.btnVpsInstructionsContinue.addEventListener('click', () => {
  showScreen('vps-configure');
});

els.btnVpsInstructionsBack.addEventListener('click', () => {
  showScreen('tunnel-choice');
});

// ─── Event handlers: VPS configure (step 1) ──────────────────────────────────

els.btnVpsConfigureContinue.addEventListener('click', async () => {
  const host = els.inputVpsHost.value.trim();
  if (!host) { showError('Please enter the VPS IP address'); return; }
  const configBody = buildVpsConfigBody();
  if (!configBody) return;
  try {
    await api('POST', '/vps/configure', configBody);
    // Fetch the setup script (generates keypair if needed)
    const res = await api('GET', '/vps/setup-script');
    if (!res.script) { showError('Failed to load setup script'); return; }
    els.vpsScriptText.textContent = res.script;
    // Build SSH login command
    const sshPort = parseInt(els.inputVpsSshPort.value, 10) || 22;
    const sshCmd = sshPort === 22 ? `ssh root@${host}` : `ssh -p ${sshPort} root@${host}`;
    els.vpsSshCmd.textContent = sshCmd;
    // Clear any stale test status
    els.vpsTestStatus.textContent = '';
    els.vpsTestStatus.className = 'test-status';
    showScreen('vps-key');
  } catch (err) {
    showError('Failed to save config: ' + err.message);
  }
});

els.btnVpsConfigureBack.addEventListener('click', () => {
  showScreen('vps-instructions');
});

// ─── Event handlers: VPS key/script (step 2) ─────────────────────────────────

els.btnCopySshCmd.addEventListener('click', () => {
  copyText(els.vpsSshCmd.textContent, els.copySshCmdFeedback, els.vpsSshCmd);
});

els.btnCopyScript.addEventListener('click', () => {
  copyText(els.vpsScriptText.textContent, els.copyScriptFeedback, els.vpsScriptText);
});

els.btnVpsTest.addEventListener('click', async () => {
  try {
    els.vpsTestStatus.textContent = 'Testing…';
    els.vpsTestStatus.className = 'test-status test-status-pending';
    const res = await api('POST', '/vps/test-connection');
    if (res.success) {
      els.vpsTestStatus.textContent = '✓ Connection successful!';
      els.vpsTestStatus.className = 'test-status test-status-ok';
    } else {
      els.vpsTestStatus.textContent = '✗ ' + (res.error || 'Connection failed');
      els.vpsTestStatus.className = 'test-status test-status-err';
    }
  } catch (err) {
    els.vpsTestStatus.textContent = '✗ Error: ' + err.message;
    els.vpsTestStatus.className = 'test-status test-status-err';
  }
});

els.btnVpsConnect.addEventListener('click', async () => {
  try {
    await api('POST', '/vps/connect');
    showScreen('vps-connecting');
  } catch (err) {
    showError('Failed to connect: ' + err.message);
  }
});

els.btnVpsKeyBack.addEventListener('click', () => {
  showScreen('vps-configure');
});

function buildVpsConfigBody() {
  const host = els.inputVpsHost.value.trim();
  if (!host) { showError('Please enter the VPS IP address'); return null; }
  const body = { host };
  const sshPort = parseInt(els.inputVpsSshPort.value, 10);
  const sshUser = els.inputVpsUser.value.trim();
  const remotePort = parseInt(els.inputVpsRemotePort.value, 10);
  if (sshPort) body.ssh_port = sshPort;
  if (sshUser) body.ssh_user = sshUser;
  if (remotePort) body.remote_port = remotePort;
  return body;
}

// ─── Event handlers: VPS connecting ──────────────────────────────────────────

els.btnVpsConnectingCancel.addEventListener('click', async () => {
  try { await api('POST', '/vps/disconnect'); } catch (_) {}
  showScreen('vps-configure');
});

// ─── Event handlers: Dashboard ────────────────────────────────────────────────

els.btnRestartTunnel.addEventListener('click', async () => {
  try {
    await api('POST', '/vps/disconnect');
    setTimeout(async () => {
      try { await api('POST', '/vps/connect'); } catch (_) {}
    }, 1000);
  } catch (err) {
    showError('Failed to restart tunnel: ' + err.message);
  }
});

// ─── Event handlers: Playit.gg setup ─────────────────────────────────────────

els.btnStartClaim.addEventListener('click', async () => {
  try {
    const result = await api('POST', '/claim/start');
    if (result.claim_url) {
      els.claimUrl.href = result.claim_url;
      els.claimUrl.textContent = result.claim_url;
      showScreen('claim');
    } else {
      showError('Failed to start claim flow');
    }
  } catch (err) {
    showError('Failed to start setup: ' + err.message);
  }
});

els.btnSubmitSecret.addEventListener('click', async () => {
  const key = els.inputSecret.value.trim();
  if (!key) { showError('Please enter a secret key'); return; }
  if (!/^[0-9a-fA-F]+$/.test(key)) { showError('Secret key must be a hex string'); return; }
  try {
    await api('POST', '/secret', { secret_key: key });
    els.inputSecret.value = '';
    showScreen('dashboard');
  } catch (err) {
    showError('Failed to save secret key: ' + err.message);
  }
});

els.btnCancelClaim.addEventListener('click', () => { showScreen('setup'); });

// ─── Event handlers: Copy endpoint ───────────────────────────────────────────

els.btnCopy.addEventListener('click', () => {
  copyText(els.endpointText.textContent, els.copyFeedback, els.endpointText);
});

// ─── Event handlers: Reset ───────────────────────────────────────────────────

els.btnReset.addEventListener('click', async () => {
  const mode = currentMode;
  const msg = mode === 'vps'
    ? 'This will disconnect the VPS tunnel and clear all VPS configuration. Continue?'
    : 'This will disconnect the tunnel and clear your playit.gg credentials. Continue?';
  if (!confirm(msg)) return;
  try {
    if (mode === 'vps') {
      await api('POST', '/vps/reset');
      currentMode = null;
      showScreen('tunnel-choice');
    } else {
      await api('POST', '/reset');
      currentMode = null;
      showScreen('tunnel-choice');
    }
  } catch (err) {
    showError('Failed to reset: ' + err.message);
  }
});

// ─── Initialize ───────────────────────────────────────────────────────────────

startPolling();
