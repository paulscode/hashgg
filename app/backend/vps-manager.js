'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const EventEmitter = require('events');
const state = require('./state');

const SSH_BIN = '/usr/bin/ssh';
const KEY_FILE = '/root/data/vps_ssh_key';
const KNOWN_HOSTS_FILE = '/root/data/vps_known_hosts';
// Port that socat listens on inside the container — where the SSH reverse tunnel
// forwards miner traffic. Must match the entrypoint's LISTEN_PORT, which defaults
// to DATUM_STRATUM_PORT. Hardcoding 23335 here was fine when that was always the
// default, but since v0.4.0.0 we honor DATUM_STRATUM_PORT from env (Umbrel sets
// 23334, for example) — so re-read it.
const LOCAL_STRATUM_PORT = parseInt(process.env.LISTEN_PORT || process.env.DATUM_STRATUM_PORT, 10) || 23335;
const MAX_BACKOFF = 60000;
const STABLE_AFTER_MS = 5000;

class VpsManager extends EventEmitter {
  constructor() {
    super();
    this.process = null;
    this.generation = 0;
    this.status = 'disconnected';
    this.backoff = 2000;
    this.restartTimer = null;
    this.stableTimer = null;
    this.upSince = null;
  }

  start() {
    const s = state.get();
    if (!s.vps_host || !s.vps_ssh_private_key) {
      console.log('[vps] Not configured, skipping start');
      return;
    }
    if (this.process) {
      console.log('[vps] Already running');
      return;
    }

    // Write private key file (chmod 600)
    try {
      fs.writeFileSync(KEY_FILE, s.vps_ssh_private_key, { mode: 0o600 });
    } catch (err) {
      console.error(`[vps] Failed to write key file: ${err.message}`);
      this._setStatus('error', 'Failed to write SSH key file');
      this._scheduleRestart();
      return;
    }

    this.generation++;
    const gen = this.generation;

    this._setStatus('connecting', null);

    const sshPort = String(s.vps_ssh_port || 22);
    const sshUser = s.vps_ssh_user || 'hashgg';
    const remotePort = String(s.vps_remote_port || 23335);
    const forwardSpec = `0.0.0.0:${remotePort}:127.0.0.1:${LOCAL_STRATUM_PORT}`;
    // IPv6 addresses require bracket notation in SSH user@host form
    const sshHost = s.vps_host.includes(':') ? `[${s.vps_host}]` : s.vps_host;

    const args = [
      '-N',
      '-o', 'StrictHostKeyChecking=accept-new',
      '-o', `UserKnownHostsFile=${KNOWN_HOSTS_FILE}`,
      '-o', 'ServerAliveInterval=30',
      '-o', 'ServerAliveCountMax=3',
      '-o', 'ConnectTimeout=30',
      '-o', 'ExitOnForwardFailure=yes',
      '-o', 'BatchMode=yes',
      '-i', KEY_FILE,
      '-R', forwardSpec,
      '-p', sshPort,
      `${sshUser}@${sshHost}`,
    ];

    console.log(`[vps] Connecting to ${sshUser}@${s.vps_host}:${sshPort} (forward ${forwardSpec})`);

    const proc = spawn(SSH_BIN, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    this.process = proc;

    let lastStderr = '';

    proc.stdout.on('data', (data) => {
      const line = data.toString().trim();
      if (line) console.log(`[vps:out] ${line}`);
    });

    proc.stderr.on('data', (data) => {
      const line = data.toString().trim();
      if (line) {
        console.log(`[vps:err] ${line}`);
        lastStderr = line;
      }
    });

    proc.on('error', (err) => {
      if (this.generation !== gen) return;
      console.error(`[vps] Spawn error: ${err.message}`);
      this._clearStable();
      this.process = null;
      this._setStatus('error', err.message);
      this._scheduleRestart();
    });

    proc.on('close', (code) => {
      if (this.generation !== gen) {
        console.log(`[vps] Stale process (gen ${gen}) exited, ignoring`);
        return;
      }
      console.log(`[vps] SSH exited with code ${code}`);
      this._clearStable();
      this.process = null;
      if (this.status !== 'disconnected') {
        const errMsg = lastStderr || `SSH exited (code ${code})`;
        this._setStatus('error', errMsg);
        state.update({ public_endpoint: null });
        this._scheduleRestart();
      }
    });

    // Mark stable (connected) after STABLE_AFTER_MS if process is still alive
    this.stableTimer = setTimeout(() => {
      this.stableTimer = null;
      if (this.generation === gen && this.process && this.status === 'connecting') {
        console.log('[vps] SSH tunnel stable — marking connected');
        this.backoff = 2000;
        this.upSince = Date.now();
        this._setStatus('connected', null);
        // Publish the public endpoint and mark host key as verified
        const s2 = state.get();
        state.update({
          public_endpoint: `${s2.vps_host}:${s2.vps_remote_port || 23335}`,
          vps_host_key_verified: true,
        });
      }
    }, STABLE_AFTER_MS);
  }

  stop() {
    this._clearRestart();
    this._clearStable();
    if (this.process) {
      this._setStatus('disconnected', null);
      const proc = this.process;
      this.process = null;
      this.generation++;
      proc.kill('SIGTERM');
      const pid = proc.pid;
      setTimeout(() => {
        try { process.kill(pid, 'SIGKILL'); } catch (_) {}
      }, 5000);
    } else {
      this._setStatus('disconnected', null);
    }
    this.upSince = null;
    state.update({ public_endpoint: null });
  }

  restart() {
    this.stop();
    setTimeout(() => this.start(), 1000);
  }

  getUptime() {
    if (!this.upSince) return 0;
    return Math.floor((Date.now() - this.upSince) / 1000);
  }

  _setStatus(status, errorMsg) {
    this.status = status;
    const patch = { vps_tunnel_status: status };
    if (errorMsg !== undefined && errorMsg !== null) {
      patch.vps_last_error = errorMsg;
    }
    if (status === 'connected') {
      patch.vps_last_error = null;
    }
    state.update(patch);
    this.emit('status', status);
  }

  _scheduleRestart() {
    this._clearRestart();
    console.log(`[vps] Restarting in ${this.backoff}ms...`);
    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      this.start();
    }, this.backoff);
    this.backoff = Math.min(this.backoff * 2, MAX_BACKOFF);
  }

  _clearRestart() {
    if (this.restartTimer) {
      clearTimeout(this.restartTimer);
      this.restartTimer = null;
    }
  }

  _clearStable() {
    if (this.stableTimer) {
      clearTimeout(this.stableTimer);
      this.stableTimer = null;
    }
  }
}

module.exports = new VpsManager();
