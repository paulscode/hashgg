#!/usr/bin/env bash
#
# install-datum-gateway.sh — Datum Gateway helper for Debian/Ubuntu/Mint users.
#
# Designed for two workflows:
#
#   1. On-demand (primary): user runs `bitcoin-qt` by hand when they want to
#      mine. They launch Datum the same way — `./install-datum-gateway.sh run`
#      — and ctrl-C it when they're done. Nothing runs in the background.
#      Config and binary live under $HOME; no sudo needed after the initial
#      build-deps install.
#
#   2. Daemon (optional): user with bitcoind-as-a-service can promote the
#      user-local setup to a systemd service via `install-daemon`.
#
# Commands:
#   check-knots       Parse bitcoin.conf, flag missing settings Datum needs.
#   build             Fetch source, build/rebuild (no root needed).
#   configure         Create / update datum_gateway.json via prompts.
#   run               Launch Datum in the foreground using the user's config.
#   open-firewall     One-time ufw rule so HashGG-in-Docker can reach Datum.
#   install-daemon    Promote to a systemd service (requires sudo).
#   uninstall-daemon  Remove systemd service + system files (requires sudo).
#                     User-local files are left alone.
#   uninstall         Remove everything this script created (user + system).
#   status            Report what's installed and whether Knots is reachable.
#   help              Show help.
#
# No command → interactive menu.
#
# The script uses `sudo` only for the commands that genuinely need root
# (apt-get, systemctl, writing under /usr/local, /etc, or /etc/systemd).
# Run it as your *normal* user — it will prompt for sudo when needed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants (override via env)
# ---------------------------------------------------------------------------

DATUM_REPO="${DATUM_REPO:-https://github.com/ocean-xyz/datum_gateway.git}"
# Pinned to the tagged release we've validated end-to-end. Override with
# DATUM_REF=master if you want to track the tip of upstream.
DATUM_REF="${DATUM_REF:-v0.4.1beta}"

# User-local layout (default for everything except daemon install)
USER_SRC_DIR="${USER_SRC_DIR:-$HOME/.local/src/datum_gateway}"
USER_BIN_DIR="${USER_BIN_DIR:-$HOME/.local/bin}"
USER_BIN="${USER_BIN_DIR}/datum_gateway"
USER_CONF_DIR="${USER_CONF_DIR:-$HOME/.config/datum_gateway}"
USER_CONF_FILE="${USER_CONF_DIR}/datum_gateway.json"
USER_LOG_DIR="${USER_LOG_DIR:-$HOME/.cache/datum_gateway}"
USER_LOG_FILE="${USER_LOG_DIR}/install.log"

# System-wide layout (only used by install-daemon / uninstall-daemon)
SYS_PREFIX="${SYS_PREFIX:-/usr/local}"
SYS_BIN="${SYS_PREFIX}/bin/datum_gateway"
SYS_CONF_DIR="${SYS_CONF_DIR:-/etc/datum_gateway}"
SYS_CONF_FILE="${SYS_CONF_DIR}/datum_gateway.json"
SERVICE_NAME="${SERVICE_NAME:-datum-gateway}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
DATUM_USER="${DATUM_USER:-datum}"
DATUM_GROUP="${DATUM_GROUP:-datum}"

# Prompt defaults
DEFAULT_STRATUM_PORT=23335
DEFAULT_STRATUM_ADDR="0.0.0.0"
DEFAULT_BITCOIN_CONF_CANDIDATES=(
  "$HOME/.bitcoin/bitcoin.conf"
  "/home/bitcoin/.bitcoin/bitcoin.conf"
  "/var/lib/bitcoind/bitcoin.conf"
  "/etc/bitcoin/bitcoin.conf"
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

say()   { printf '%s\n' "$*"; }
info()  { printf '%s[info]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()    { printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()   { printf '%s[err ]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
step()  { printf '\n%s==> %s%s\n' "$C_BLU" "$*" "$C_OFF"; }

confirm() {
  local prompt="$1" def="${2:-default-no}" reply hint="[y/N]"
  [[ "$def" == "default-yes" ]] && hint="[Y/n]"
  read -r -p "$(printf '%s %s ' "$prompt" "$hint")" reply || true
  if [[ -z "$reply" ]]; then
    [[ "$def" == "default-yes" ]] && return 0 || return 1
  fi
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

ask() {
  local prompt="$1" def="${2:-}" reply
  if [[ -n "$def" ]]; then
    read -r -p "$(printf '%s [%s]: ' "$prompt" "$def")" reply || true
    printf '%s' "${reply:-$def}"
  else
    read -r -p "$(printf '%s: ' "$prompt")" reply || true
    printf '%s' "$reply"
  fi
}

ask_secret() {
  local prompt="$1" reply
  read -r -s -p "$(printf '%s: ' "$prompt")" reply || true
  printf '\n' >&2
  printf '%s' "$reply"
}

die() { err "$*"; exit 1; }

on_error() {
  local code=$? line=${1:-?}
  err "Aborted on line $line (exit $code). See $USER_LOG_FILE for full output."
  exit "$code"
}
trap 'on_error $LINENO' ERR

require_not_root() {
  if [[ $EUID -eq 0 ]]; then
    die "Run this command as your normal user, not as root. It will sudo specific commands when needed."
  fi
}

require_debian_family() {
  [[ -f /etc/os-release ]] || die "Cannot detect OS (no /etc/os-release)."
  # shellcheck disable=SC1091
  . /etc/os-release
  local family="${ID_LIKE:-} ${ID:-}"
  if ! echo "$family" | grep -qiE 'debian|ubuntu'; then
    warn "This script is Debian-only — it uses apt-get and dpkg-query."
    warn "Detected distro: ${PRETTY_NAME:-${ID:-unknown}}."
    warn "On non-Debian distros you'll need to install Datum Gateway using"
    warn "your distro's package manager and adapt the configure/run steps."
    confirm "Continue anyway? (most steps will fail)" default-no || die "Aborted."
  fi
}

start_logging() {
  mkdir -p "$USER_LOG_DIR"
  exec > >(tee -a "$USER_LOG_FILE") 2>&1
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Find the datum_gateway binary to use at runtime. Prefers user-local (fresh
# builds), falls back to system-wide install.
find_datum_binary() {
  if [[ -x "$USER_BIN" ]]; then
    printf '%s' "$USER_BIN"
  elif [[ -x "$SYS_BIN" ]]; then
    printf '%s' "$SYS_BIN"
  elif command -v datum_gateway >/dev/null 2>&1; then
    command -v datum_gateway
  fi
}

# Find the datum_gateway config to use at runtime. User config wins.
find_datum_config() {
  if [[ -r "$USER_CONF_FILE" ]]; then
    printf '%s' "$USER_CONF_FILE"
  elif [[ -r "$SYS_CONF_FILE" ]]; then
    printf '%s' "$SYS_CONF_FILE"
  fi
}

parse_conf_value() {
  local file="$1" key="$2"
  [[ -r "$file" ]] || return 1
  awk -F= -v k="$key" '$1==k { sub(/^[ \t]+|[ \t]+$/, "", $2); val=$2 } END{ if(val!="") print val }' "$file"
}

detect_bitcoin_conf() {
  local candidate
  for candidate in "${DEFAULT_BITCOIN_CONF_CANDIDATES[@]}"; do
    [[ -r "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

# Read an existing user config (JSON) into shell vars, if present. Used to
# preselect sensible defaults when re-configuring.
load_existing_config_defaults() {
  local f="$USER_CONF_FILE"
  [[ -r "$f" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then return 0; fi
  # All lookups are best-effort; missing keys just leave the var empty.
  EX_RPC_URL=$(jq -r '.bitcoind.rpcurl // ""' "$f" 2>/dev/null || true)
  EX_RPC_USER=$(jq -r '.bitcoind.rpcuser // ""' "$f" 2>/dev/null || true)
  EX_RPC_PASS=$(jq -r '.bitcoind.rpcpassword // ""' "$f" 2>/dev/null || true)
  EX_RPC_COOKIE=$(jq -r '.bitcoind.rpccookiefile // ""' "$f" 2>/dev/null || true)
  EX_STRATUM_ADDR=$(jq -r '.stratum.listen_addr // ""' "$f" 2>/dev/null || true)
  EX_STRATUM_PORT=$(jq -r '.stratum.listen_port // ""' "$f" 2>/dev/null || true)
  EX_PAYOUT=$(jq -r '.mining.pool_address // ""' "$f" 2>/dev/null || true)
  EX_CB_PRIMARY=$(jq -r '.mining.coinbase_tag_primary // ""' "$f" 2>/dev/null || true)
  EX_CB_SECONDARY=$(jq -r '.mining.coinbase_tag_secondary // ""' "$f" 2>/dev/null || true)
}

probe_knots_rpc() {
  # $1=url $2=user $3=pass $4=cookie-path
  # Returns 0 if getblockchaininfo succeeded. Writes a note to stderr either way.
  local url="$1" user="$2" pass="$3" cookie="$4"
  command -v curl >/dev/null 2>&1 || { info "curl not installed yet; skipping RPC probe."; return 0; }

  local auth_arg=""
  if [[ -n "$user" && -n "$pass" ]]; then
    auth_arg="--user $user:$pass"
  elif [[ -n "$cookie" && -r "$cookie" ]]; then
    auth_arg="--user $(cat "$cookie")"
  else
    info "No RPC credentials readable yet; skipping probe."
    return 0
  fi

  local body='{"jsonrpc":"1.0","id":"datum-install","method":"getblockchaininfo","params":[]}'
  # shellcheck disable=SC2086
  if curl -sS --max-time 5 $auth_arg -H 'content-type: text/plain;' --data "$body" "$url" \
      | grep -q '"chain"'; then
    ok "Bitcoin Knots RPC reachable at $url"
    return 0
  else
    warn "Could not reach Knots RPC at $url with the given credentials."
    warn "That's fine if Knots isn't running right now — Datum will retry when you launch it."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Action: check-knots
# ---------------------------------------------------------------------------
#
# Parses bitcoin.conf and reports which of the settings Datum Gateway needs
# are present, missing, or look off. Prints a ready-to-paste block for
# whatever's missing, then does a live RPC probe.

action_check_knots() {
  require_not_root
  step "Bitcoin Knots config check"

  local bc_path=""
  bc_path="$(detect_bitcoin_conf || true)"
  if [[ -z "$bc_path" ]]; then
    warn "Could not auto-detect bitcoin.conf in common locations."
    bc_path="$(ask "Path to bitcoin.conf" "")"
    if [[ -z "$bc_path" || ! -r "$bc_path" ]]; then
      die "Cannot read bitcoin.conf — aborting."
    fi
  fi
  ok "Using $bc_path"

  # Read the settings we care about
  local v_server v_rpcbind v_rpcallowip v_rpcuser v_rpcpassword v_rpcauth
  local v_blocknotify v_disablewallet v_testnet v_signet v_rpcport
  v_server=$(parse_conf_value "$bc_path" server || true)
  v_rpcbind=$(parse_conf_value "$bc_path" rpcbind || true)
  v_rpcallowip=$(parse_conf_value "$bc_path" rpcallowip || true)
  v_rpcuser=$(parse_conf_value "$bc_path" rpcuser || true)
  v_rpcpassword=$(parse_conf_value "$bc_path" rpcpassword || true)
  v_rpcauth=$(parse_conf_value "$bc_path" rpcauth || true)
  v_blocknotify=$(parse_conf_value "$bc_path" blocknotify || true)
  v_disablewallet=$(parse_conf_value "$bc_path" disablewallet || true)
  v_testnet=$(parse_conf_value "$bc_path" testnet || true)
  v_signet=$(parse_conf_value "$bc_path" signet || true)
  v_rpcport=$(parse_conf_value "$bc_path" rpcport || true)

  local network="mainnet"
  [[ "$v_testnet" == "1" ]] && network="testnet"
  [[ "$v_signet"  == "1" ]] && network="signet"
  info "Detected Bitcoin network: $network"

  local -a missing=()

  say ""
  say "Required (RPC — without these Datum cannot connect):"
  if [[ "$v_server" == "1" ]]; then
    ok "  server=1"
  else
    err "  server= (missing or not 1)"
    missing+=("server=1")
  fi
  if [[ -n "$v_rpcbind" ]]; then
    ok "  rpcbind=$v_rpcbind"
    if [[ "$v_rpcbind" != "127.0.0.1" && "$v_rpcbind" != "::1" ]]; then
      warn "  rpcbind is not loopback — see security §9.1. Datum runs on the same host; loopback is safer."
    fi
  else
    warn "  rpcbind= (missing — Knots' default is loopback, but explicit is better)"
    missing+=("rpcbind=127.0.0.1")
  fi
  if [[ -n "$v_rpcallowip" ]]; then
    ok "  rpcallowip=$v_rpcallowip"
  else
    info "  rpcallowip= (missing — default covers loopback, so usually fine)"
  fi

  say ""
  say "Authentication (pick one):"
  if [[ -n "$v_rpcuser" && -n "$v_rpcpassword" ]]; then
    ok "  Explicit rpcuser='$v_rpcuser' + rpcpassword=<set>"
  elif [[ -n "$v_rpcauth" ]]; then
    ok "  rpcauth= found (hashed form) — Datum will need the matching plaintext pair"
  elif [[ -n "$v_rpcuser" ]]; then
    err "  rpcuser set but no rpcpassword / rpcauth — Knots won't start. Fix before continuing."
  else
    ok "  No explicit creds — cookie auth (default) will be used"
    local datadir; datadir="$(dirname "$bc_path")"
    local cookie="$datadir/.cookie"
    [[ "$network" == "testnet" ]] && cookie="$datadir/testnet3/.cookie"
    [[ "$network" == "signet"  ]] && cookie="$datadir/signet/.cookie"
    if [[ -r "$cookie" ]]; then
      ok "  Cookie file present: $cookie"
    else
      info "  Cookie file not present yet ($cookie) — it appears when Knots starts."
    fi
  fi

  say ""
  say "Recommended (block notifications — Datum listens on API port 7152):"
  if [[ -n "$v_blocknotify" ]]; then
    ok "  blocknotify=$v_blocknotify"
    if ! echo "$v_blocknotify" | grep -qE '7152|datum_gateway'; then
      warn "  blocknotify is set but doesn't look like a Datum notification."
      warn "  Expected something like: wget -q -O /dev/null http://127.0.0.1:7152/NOTIFY"
    fi
  else
    warn "  blocknotify= (missing — Datum will fall back to polling, templates may lag)"
    missing+=('blocknotify=wget -q -O /dev/null http://127.0.0.1:7152/NOTIFY')
  fi

  say ""
  say "Recommended (security):"
  if [[ "$v_disablewallet" == "1" ]]; then
    ok "  disablewallet=1 (wallet-less mining node)"
  else
    warn "  disablewallet= (missing — Datum will have RPC access to any loaded wallet)"
    warn "                 See internal_docs/docker-image-plan.md §9.1 before proceeding if this Knots has a wallet."
    missing+=("disablewallet=1")
  fi

  if (( ${#missing[@]} > 0 )); then
    say ""
    step "Paste these lines into $bc_path, then restart Bitcoin Knots"
    say ""
    say "# --- Datum Gateway / HashGG ---"
    local line
    for line in "${missing[@]}"; do
      say "$line"
    done
    say ""
  else
    say ""
    ok "Bitcoin Knots config looks good for Datum Gateway."
  fi

  say ""
  step "Live RPC probe"
  local default_rpcport="8332"
  [[ "$network" == "testnet" ]] && default_rpcport="18332"
  [[ "$network" == "signet"  ]] && default_rpcport="38332"
  [[ -n "$v_rpcport" ]] && default_rpcport="$v_rpcport"
  local url="http://127.0.0.1:${default_rpcport}"
  local cookie=""
  if [[ -z "$v_rpcuser" ]]; then
    local datadir; datadir="$(dirname "$bc_path")"
    cookie="$datadir/.cookie"
    [[ "$network" == "testnet" ]] && cookie="$datadir/testnet3/.cookie"
    [[ "$network" == "signet"  ]] && cookie="$datadir/signet/.cookie"
  fi
  probe_knots_rpc "$url" "$v_rpcuser" "$v_rpcpassword" "$cookie" || true
}

# ---------------------------------------------------------------------------
# Action: build
# ---------------------------------------------------------------------------

action_build() {
  require_not_root
  require_debian_family
  step "Build Datum Gateway (user-local)"

  # Ensure apt build deps (this is the only part that needs sudo).
  ensure_build_deps

  # Clone or update
  if [[ -d "$USER_SRC_DIR/.git" ]]; then
    info "Updating existing clone at $USER_SRC_DIR"
    git -C "$USER_SRC_DIR" fetch --all --tags --prune
    git -C "$USER_SRC_DIR" checkout "$DATUM_REF"
    git -C "$USER_SRC_DIR" pull --ff-only || warn "git pull --ff-only failed; source may be on a detached ref."
  else
    mkdir -p "$(dirname "$USER_SRC_DIR")"
    git clone --branch "$DATUM_REF" "$DATUM_REPO" "$USER_SRC_DIR"
  fi

  # Build
  mkdir -p "$USER_BIN_DIR"
  if [[ -f "$USER_SRC_DIR/CMakeLists.txt" ]]; then
    local build_dir="$USER_SRC_DIR/build"
    mkdir -p "$build_dir"
    ( cd "$build_dir" && cmake -DCMAKE_BUILD_TYPE=Release .. )
    cmake --build "$build_dir" -j"$(nproc)"
    # Find the produced binary — name is usually datum_gateway
    local built=""
    for candidate in "$build_dir/datum_gateway" "$build_dir/src/datum_gateway"; do
      [[ -x "$candidate" ]] && { built="$candidate"; break; }
    done
    [[ -z "$built" ]] && die "Build finished but no datum_gateway binary found under $build_dir"
    install -m 0755 "$built" "$USER_BIN"
  elif [[ -f "$USER_SRC_DIR/Makefile" ]]; then
    make -C "$USER_SRC_DIR" -j"$(nproc)"
    local built=""
    for candidate in "$USER_SRC_DIR/datum_gateway" "$USER_SRC_DIR/src/datum_gateway"; do
      [[ -x "$candidate" ]] && { built="$candidate"; break; }
    done
    [[ -z "$built" ]] && die "Build finished but no datum_gateway binary found under $USER_SRC_DIR"
    install -m 0755 "$built" "$USER_BIN"
  else
    die "Neither CMakeLists.txt nor Makefile in $USER_SRC_DIR — upstream layout changed?"
  fi

  ok "Installed $USER_BIN"
  "$USER_BIN" --version 2>/dev/null || "$USER_BIN" -v 2>/dev/null || true

  # Nudge PATH if ~/.local/bin isn't on it
  if ! echo ":$PATH:" | grep -q ":$USER_BIN_DIR:"; then
    info "$USER_BIN_DIR is not on your PATH. Either add it to your shell RC, or invoke it directly:"
    info "  $USER_BIN"
  fi
}

ensure_build_deps() {
  # Check each package individually with dpkg-query. "Tool on PATH" is not the
  # same as "dev headers installed" — libcurl4-openssl-dev may be missing even
  # when curl is present. Check the actual packages.
  local pkgs=(
    build-essential cmake git pkg-config ca-certificates
    libcurl4-openssl-dev libjansson-dev libmicrohttpd-dev
    libsodium-dev libssl-dev
    netcat-openbsd jq curl
  )
  local missing=()
  local p
  for p in "${pkgs[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed$'; then
      missing+=("$p")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    info "All apt build dependencies already installed."
    return 0
  fi

  info "Installing missing apt build dependencies (you'll be prompted for sudo):"
  info "  ${missing[*]}"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
}

# ---------------------------------------------------------------------------
# Action: configure
# ---------------------------------------------------------------------------

action_configure() {
  require_not_root
  step "Configure Datum Gateway"

  load_existing_config_defaults

  # Bitcoin config discovery
  local bc_path=""
  bc_path="$(detect_bitcoin_conf || true)"
  if [[ -n "$bc_path" ]]; then
    ok "Found Bitcoin config: $bc_path"
  else
    warn "Could not auto-detect bitcoin.conf."
    bc_path="$(ask "Path to bitcoin.conf (blank to skip)" "")"
    if [[ -n "$bc_path" && ! -r "$bc_path" ]]; then
      die "Cannot read $bc_path"
    fi
  fi

  local conf_rpcport="" conf_rpcuser="" conf_rpcpass="" conf_testnet="" conf_signet=""
  if [[ -n "$bc_path" ]]; then
    conf_rpcport=$(parse_conf_value "$bc_path" rpcport || true)
    conf_rpcuser=$(parse_conf_value "$bc_path" rpcuser || true)
    conf_rpcpass=$(parse_conf_value "$bc_path" rpcpassword || true)
    conf_testnet=$(parse_conf_value "$bc_path" testnet || true)
    conf_signet=$(parse_conf_value "$bc_path" signet || true)
  fi

  local network="mainnet" default_rpcport="8332"
  if   [[ "$conf_testnet" == "1" ]]; then network="testnet"; default_rpcport="18332"
  elif [[ "$conf_signet"  == "1" ]]; then network="signet";  default_rpcport="38332"; fi
  [[ -n "$conf_rpcport" ]] && default_rpcport="$conf_rpcport"
  info "Detected Bitcoin network: $network"

  local default_url="${EX_RPC_URL:-http://127.0.0.1:${default_rpcport}}"
  local rpc_url; rpc_url="$(ask "Bitcoin Knots RPC URL" "$default_url")"

  # Auth mode
  say ""
  say "How should Datum authenticate to Bitcoin Knots?"
  say "  1) Cookie file (the default for bitcoin-qt users — ~/.bitcoin/.cookie)"
  say "  2) rpcuser / rpcpassword from bitcoin.conf"
  local default_choice="1"; [[ -n "${EX_RPC_USER:-}" ]] && default_choice="2"
  local choice; choice="$(ask "Choose [1/2]" "$default_choice")"

  local rpc_cookie="" rpc_user="" rpc_pass=""
  if [[ "$choice" == "1" ]]; then
    local default_cookie="${EX_RPC_COOKIE:-$HOME/.bitcoin/.cookie}"
    if [[ -n "$bc_path" ]]; then
      local datadir; datadir="$(dirname "$bc_path")"
      default_cookie="$datadir/.cookie"
      [[ "$network" == "testnet" ]] && default_cookie="$datadir/testnet3/.cookie"
      [[ "$network" == "signet"  ]] && default_cookie="$datadir/signet/.cookie"
    fi
    rpc_cookie="$(ask "Path to Knots cookie file" "$default_cookie")"
    if [[ ! -r "$rpc_cookie" && ! -e "$rpc_cookie" ]]; then
      warn "Cookie file $rpc_cookie doesn't exist yet. That's fine if Knots isn't running — it'll appear once you launch bitcoin-qt."
    fi
  elif [[ "$choice" == "2" ]]; then
    rpc_user="$(ask "RPC username" "${EX_RPC_USER:-$conf_rpcuser}")"
    if [[ -n "$conf_rpcpass" ]]; then
      rpc_pass="$conf_rpcpass"
      info "Using rpcpassword from $bc_path"
    elif [[ -n "${EX_RPC_PASS:-}" ]] && confirm "Keep existing stored RPC password?" default-yes; then
      rpc_pass="$EX_RPC_PASS"
    else
      rpc_pass="$(ask_secret "RPC password (input hidden)")"
    fi
    [[ -z "$rpc_user" || -z "$rpc_pass" ]] && die "RPC user/pass cannot be empty."
  else
    die "Invalid choice."
  fi

  # Stratum
  local stratum_addr; stratum_addr="$(ask "Stratum listen address (0.0.0.0 lets the Docker bridge reach us)" "${EX_STRATUM_ADDR:-$DEFAULT_STRATUM_ADDR}")"
  local stratum_port; stratum_port="$(ask "Stratum listen port" "${EX_STRATUM_PORT:-$DEFAULT_STRATUM_PORT}")"
  [[ "$stratum_port" =~ ^[0-9]+$ ]] || die "Port must be numeric."
  (( stratum_port >= 1 && stratum_port <= 65535 )) || die "Port out of range."

  # Payout
  say ""
  say "Datum submits blocks to OCEAN for non-custodial payout."
  local payout; payout="$(ask "Payout Bitcoin address" "${EX_PAYOUT:-}")"
  [[ -z "$payout" ]] && die "Payout address is required."
  if [[ ! "$payout" =~ ^(bc1|tb1|bcrt1|1|3|m|n|2)[A-Za-z0-9]+$ ]]; then
    warn "Payout address doesn't look like a typical Bitcoin address."
    confirm "Use it anyway?" default-no || die "Aborted."
  fi

  # Coinbase tags. Upstream allows up to 60 bytes per tag and 88 bytes combined.
  # The primary tag is overridden by OCEAN when pooled_mining_only=true (the
  # default), so in practice the secondary is the one that shows up in blocks
  # you solve. Both are prompted for so users can set them up front.
  say ""
  say "Coinbase tags — embedded in the coinbase of blocks you solve."
  say "  - Primary is overridden by OCEAN when pool-connected (default config)."
  say "  - Secondary is your short identifier; stays yours."
  say "  - Max 60 bytes each, 88 bytes combined."
  local cb_primary; cb_primary="$(ask "Primary coinbase tag" "${EX_CB_PRIMARY:-DATUM Gateway}")"
  local cb_secondary; cb_secondary="$(ask "Secondary coinbase tag" "${EX_CB_SECONDARY:-DATUM User}")"

  # Byte-count validation (use wc -c so multi-byte UTF-8 is counted correctly)
  local cb_p_bytes cb_s_bytes
  cb_p_bytes=$(printf '%s' "$cb_primary"   | wc -c)
  cb_s_bytes=$(printf '%s' "$cb_secondary" | wc -c)
  (( cb_p_bytes <= 60 )) || die "Primary coinbase tag is $cb_p_bytes bytes; max 60."
  (( cb_s_bytes <= 60 )) || die "Secondary coinbase tag is $cb_s_bytes bytes; max 60."
  (( cb_p_bytes + cb_s_bytes <= 88 )) || die "Combined coinbase tag length is $((cb_p_bytes+cb_s_bytes)) bytes; max 88."
  # Reject characters that would break the JSON or the coinbase (control chars, newlines)
  if printf '%s%s' "$cb_primary" "$cb_secondary" | LC_ALL=C grep -q '[^[:print:]]'; then
    die "Coinbase tags contain non-printable characters. Use printable ASCII/UTF-8 only."
  fi

  # Probe (best-effort)
  probe_knots_rpc "$rpc_url" "$rpc_user" "$rpc_pass" "$rpc_cookie" || true

  # Compose config. Prefer upstream example as base if we have one.
  local base=""
  if [[ -d "$USER_SRC_DIR" ]]; then
    local example
    for example in \
        "$USER_SRC_DIR/doc/example_datum_gateway_config.json" \
        "$USER_SRC_DIR/example.datum_gateway.json" \
        "$USER_SRC_DIR/datum_gateway.example.json" \
        "$USER_SRC_DIR/examples/datum_gateway.json" \
        "$USER_SRC_DIR/doc/datum_gateway.example.json"; do
      if [[ -f "$example" ]]; then
        # Strip JSONC line-comments only — lines that are (optional whitespace)
        # followed by "//". A bare `s@//.*$@@` also eats "http://..." inside
        # string values, which is a common thing to hit in example configs.
        base="$(sed -e 's@^[[:space:]]*//.*$@@' "$example")"
        if printf '%s' "$base" | jq . >/dev/null 2>&1; then
          info "Using upstream example config as base: $example"
        else
          warn "Found example config at $example but it didn't parse as JSON after comment-strip. Falling back to built-in skeleton."
          base=""
        fi
        break
      fi
    done
  fi
  if [[ -z "$base" ]]; then
    warn "No upstream example config available; writing a built-in skeleton. Field names reflect our current best guess and may need adjustment."
    base='{
  "bitcoind": {
    "rpcurl": "http://127.0.0.1:8332",
    "rpcuser": "",
    "rpcpassword": "",
    "rpccookiefile": ""
  },
  "stratum": {
    "listen_addr": "0.0.0.0",
    "listen_port": 23335
  },
  "mining": {
    "pool_address": ""
  }
}'
  fi

  local patched
  patched="$(printf '%s' "$base" | jq \
    --arg rpcurl "$rpc_url" \
    --arg rpcuser "$rpc_user" \
    --arg rpcpass "$rpc_pass" \
    --arg cookie "$rpc_cookie" \
    --arg saddr "$stratum_addr" \
    --argjson sport "$stratum_port" \
    --arg payout "$payout" \
    --arg cbprimary "$cb_primary" \
    --arg cbsecondary "$cb_secondary" '
      (.bitcoind //= {}) |
      (.bitcoind.rpcurl       = $rpcurl) |
      (.bitcoind.rpcuser      = $rpcuser) |
      (.bitcoind.rpcpassword  = $rpcpass) |
      (.bitcoind.rpccookiefile = $cookie) |
      (.stratum //= {}) |
      (.stratum.listen_addr = $saddr) |
      (.stratum.listen_port = $sport) |
      (.mining //= {}) |
      (.mining.pool_address = $payout) |
      (.mining.coinbase_tag_primary   = $cbprimary) |
      (.mining.coinbase_tag_secondary = $cbsecondary) |
      # Bind the admin API to loopback. Upstream default is empty string,
      # which Datum interprets as "any" (0.0.0.0) — exposes the admin API
      # to the whole LAN with no password by default. 127.0.0.1 keeps it
      # reachable to HashGG-in-Docker (via extra_hosts host-gateway) and
      # to curl on the host, and nothing else.
      (.api //= {}) |
      (.api.listen_addr = "127.0.0.1")
    ')"

  mkdir -p "$USER_CONF_DIR"
  chmod 700 "$USER_CONF_DIR"
  printf '%s\n' "$patched" > "$USER_CONF_FILE"
  chmod 600 "$USER_CONF_FILE"

  say ""
  info "Wrote $USER_CONF_FILE:"
  say "---8<---"
  if [[ -n "$rpc_pass" ]]; then
    sed "s@$(printf '%s' "$rpc_pass" | sed 's/[]\/$*.^[]/\\&/g')@<rpcpassword>@g" "$USER_CONF_FILE"
  else
    cat "$USER_CONF_FILE"
  fi
  say "--->8---"
  ok "Config saved."
  info "If any field name looks wrong for your version of Datum, edit $USER_CONF_FILE directly."
}

# ---------------------------------------------------------------------------
# Action: run (foreground)
# ---------------------------------------------------------------------------

action_run() {
  require_not_root
  step "Run Datum Gateway (foreground)"

  local bin conf
  bin="$(find_datum_binary)"
  [[ -z "$bin" ]] && die "datum_gateway not found. Run '$0 build' first."

  conf="$(find_datum_config)"
  [[ -z "$conf" ]] && die "No Datum config found at $USER_CONF_FILE. Run '$0 configure' first."

  # Quick RPC reachability check
  if command -v jq >/dev/null 2>&1; then
    local url user pass cookie
    url=$(jq -r '.bitcoind.rpcurl // ""' "$conf")
    user=$(jq -r '.bitcoind.rpcuser // ""' "$conf")
    pass=$(jq -r '.bitcoind.rpcpassword // ""' "$conf")
    cookie=$(jq -r '.bitcoind.rpccookiefile // ""' "$conf")
    if ! probe_knots_rpc "$url" "$user" "$pass" "$cookie"; then
      warn "Bitcoin Knots may not be running yet."
      warn "Start bitcoin-qt now, wait for it to finish loading, then come back here."
      confirm "Launch Datum anyway?" default-no || die "Aborted."
    fi
  fi

  say ""
  info "Binary: $bin"
  info "Config: $conf"
  info "Press Ctrl-C to stop. Datum will shut down cleanly."
  say ""

  # Exec so Ctrl-C goes straight to datum_gateway and our trap doesn't fire.
  exec "$bin" -c "$conf"
}

# ---------------------------------------------------------------------------
# Action: open-firewall
# ---------------------------------------------------------------------------
#
# Opens the host firewall so HashGG-in-Docker can reach Datum's stratum port.
# One-time per host for users on the foreground `run` workflow — the
# `install-daemon` flow calls this automatically as its last setup step.
#
# We allow from 172.16.0.0/12 (the full range Docker allocates bridge
# networks from) rather than just docker0's 172.17.0.0/16, because
# docker-compose creates its own bridges on adjacent /16s (172.18, 172.19, ...)
# and the HashGG container needs to reach Datum regardless of which one it
# lands on.

action_open_firewall() {
  require_not_root
  step "Open firewall for HashGG-in-Docker"

  if ! command -v ufw >/dev/null 2>&1; then
    info "ufw is not installed — nothing to do."
    info "If you run a different firewall, open the Docker bridge (172.16.0.0/12) to your stratum port manually."
    return 0
  fi

  # Check ufw state without sudo so we don't conflate "sudo not cached" with
  # "ufw inactive". systemctl is-active is unprivileged on systemd distros.
  if ! systemctl is-active --quiet ufw 2>/dev/null; then
    info "ufw is installed but inactive — no rule needed right now."
    info "Re-run this action if you enable ufw later."
    return 0
  fi

  # Figure out the stratum port from the user config if present, else default.
  local port="$DEFAULT_STRATUM_PORT"
  if [[ -r "$USER_CONF_FILE" ]] && command -v jq >/dev/null 2>&1; then
    local cfg_port
    cfg_port=$(jq -r '.stratum.listen_port // empty' "$USER_CONF_FILE" 2>/dev/null)
    [[ -n "$cfg_port" && "$cfg_port" != "null" ]] && port="$cfg_port"
  fi

  info "Allowing 172.16.0.0/12 -> ${port}/tcp (Docker bridge -> Datum stratum)"
  # No `|| true` here — ufw returns 0 when a matching rule already exists
  # ("Skipping adding existing rule"), so a non-zero exit means a real problem
  # (sudo auth failure, invalid rule, etc.) and set -e will surface it.
  sudo ufw allow from 172.16.0.0/12 to any port "$port" proto tcp \
    comment "HashGG Docker -> Datum stratum"
  ok "ufw rule in place."
}

# ---------------------------------------------------------------------------
# Action: install-daemon
# ---------------------------------------------------------------------------

action_install_daemon() {
  require_not_root
  step "Install Datum Gateway as a systemd service"

  warn "Daemon mode assumes Bitcoin Knots is also running as a service (bitcoind)."
  warn "If you only run bitcoin-qt interactively, daemon mode will constantly fail to"
  warn "reach Knots when you don't have the app open. Consider sticking with 'run' instead."
  confirm "Proceed with systemd install?" default-no || { info "Aborted."; return 0; }

  local src_bin="$USER_BIN"
  if [[ ! -x "$src_bin" ]]; then
    die "User-local binary missing ($USER_BIN). Run '$0 build' first."
  fi
  if [[ ! -r "$USER_CONF_FILE" ]]; then
    die "User-local config missing ($USER_CONF_FILE). Run '$0 configure' first."
  fi

  # 1. Copy binary to system prefix
  info "Installing binary to $SYS_BIN"
  sudo install -m 0755 "$src_bin" "$SYS_BIN"

  # 2. System user
  if id "$DATUM_USER" &>/dev/null; then
    info "User '$DATUM_USER' already exists."
  else
    info "Creating system user '$DATUM_USER'."
    sudo useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin "$DATUM_USER"
  fi

  # 3. Cookie access if the user is using cookie auth
  local cookie; cookie=$(jq -r '.bitcoind.rpccookiefile // ""' "$USER_CONF_FILE" 2>/dev/null || true)
  if [[ -n "$cookie" ]]; then
    if [[ -r "$cookie" ]]; then
      local cookie_group; cookie_group=$(stat -c '%G' "$cookie" || true)
      if [[ -n "$cookie_group" && "$cookie_group" != "UNKNOWN" ]]; then
        info "Adding '$DATUM_USER' to group '$cookie_group' so it can read $cookie"
        sudo usermod -aG "$cookie_group" "$DATUM_USER"
      fi
    else
      warn "Cookie file $cookie not readable right now; '$DATUM_USER' may not be able to read it either."
      warn "If Datum fails to auth against Knots, add '$DATUM_USER' to the group owning the data dir."
    fi
  fi

  # 4. System config
  info "Copying config to $SYS_CONF_FILE"
  sudo mkdir -p "$SYS_CONF_DIR"
  sudo install -m 0640 -o root -g "$DATUM_GROUP" "$USER_CONF_FILE" "$SYS_CONF_FILE" 2>/dev/null \
    || sudo install -m 0640 "$USER_CONF_FILE" "$SYS_CONF_FILE"

  # 5. Systemd unit
  info "Writing $SERVICE_FILE"
  sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Datum Gateway
Documentation=https://github.com/ocean-xyz/datum_gateway
After=network-online.target bitcoind.service
Wants=network-online.target

[Service]
Type=simple
User=${DATUM_USER}
Group=${DATUM_GROUP}
ExecStart=${SYS_BIN} -c ${SYS_CONF_FILE}
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
EOF
  sudo chmod 644 "$SERVICE_FILE"
  sudo systemctl daemon-reload

  # 6. Firewall (Docker bridge only) — shared with the standalone open-firewall action
  action_open_firewall

  # 7. Enable + start
  sudo systemctl enable "$SERVICE_NAME"
  sudo systemctl restart "$SERVICE_NAME"

  info "Waiting for service to come up..."
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if ! sudo systemctl is-active --quiet "$SERVICE_NAME"; then
      err "Service is not active. Recent logs:"
      sudo journalctl -u "$SERVICE_NAME" -n 40 --no-pager || true
      die "Daemon failed to start."
    fi
    local port; port=$(jq -r '.stratum.listen_port // 23335' "$USER_CONF_FILE")
    if nc -z -w1 127.0.0.1 "$port" 2>/dev/null; then
      ok "Stratum port $port accepting connections."
      break
    fi
  done

  say ""
  sudo systemctl status "$SERVICE_NAME" --no-pager -l || true
  ok "Daemon installed and running. Tail logs with: sudo journalctl -u $SERVICE_NAME -f"
}

# ---------------------------------------------------------------------------
# Action: uninstall-daemon
# ---------------------------------------------------------------------------

action_uninstall_daemon() {
  require_not_root
  step "Uninstall Datum Gateway daemon (system files only)"

  if sudo systemctl list-unit-files 2>/dev/null | grep -q "^${SERVICE_NAME}.service"; then
    info "Stopping + disabling $SERVICE_NAME"
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  fi

  sudo rm -f "$SERVICE_FILE"
  sudo systemctl daemon-reload
  sudo rm -f "$SYS_BIN"

  if confirm "Remove $SYS_CONF_DIR?" default-no; then
    sudo rm -rf "$SYS_CONF_DIR"
  fi
  if id "$DATUM_USER" &>/dev/null && confirm "Remove system user '$DATUM_USER'?" default-no; then
    sudo userdel "$DATUM_USER" 2>/dev/null || true
  fi
  ok "Daemon uninstalled. User-local files under $HOME/.local and $HOME/.config untouched."
}

# ---------------------------------------------------------------------------
# Action: uninstall (everything)
# ---------------------------------------------------------------------------

action_uninstall_all() {
  require_not_root
  step "Uninstall Datum Gateway (everything)"
  if ! confirm "This removes user-local binary, config, source tree, AND the systemd daemon if installed. Continue?" default-no; then
    die "Aborted."
  fi

  # Daemon side (best effort)
  if sudo -n true 2>/dev/null || [[ -f "$SERVICE_FILE" ]]; then
    action_uninstall_daemon || true
  fi

  # User side
  [[ -e "$USER_BIN" ]] && { rm -f "$USER_BIN"; ok "Removed $USER_BIN"; }
  if [[ -d "$USER_SRC_DIR" ]] && confirm "Remove source tree $USER_SRC_DIR?" default-no; then
    rm -rf "$USER_SRC_DIR"
  fi
  if [[ -d "$USER_CONF_DIR" ]] && confirm "Remove config $USER_CONF_DIR?" default-no; then
    rm -rf "$USER_CONF_DIR"
  fi

  ok "Uninstall complete."
}

# ---------------------------------------------------------------------------
# Action: status
# ---------------------------------------------------------------------------

action_status() {
  require_not_root
  step "Datum Gateway status"

  say "Binary:"
  if [[ -x "$USER_BIN" ]]; then
    say "  user-local:   $USER_BIN"
  else
    say "  user-local:   (not installed)"
  fi
  if [[ -x "$SYS_BIN" ]]; then
    say "  system-wide:  $SYS_BIN"
  else
    say "  system-wide:  (not installed)"
  fi

  say ""
  say "Config:"
  if [[ -r "$USER_CONF_FILE" ]]; then
    say "  user-local:   $USER_CONF_FILE"
  else
    say "  user-local:   (not present)"
  fi
  if [[ -r "$SYS_CONF_FILE" ]]; then
    say "  system-wide:  $SYS_CONF_FILE"
  elif [[ -e "$SYS_CONF_FILE" ]]; then
    say "  system-wide:  $SYS_CONF_FILE (exists but not readable without sudo)"
  else
    say "  system-wide:  (not present)"
  fi

  say ""
  say "Systemd service:"
  if [[ -f "$SERVICE_FILE" ]]; then
    local state
    state=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown")
    say "  $SERVICE_NAME: $state"
  else
    say "  $SERVICE_NAME: not installed"
  fi

  say ""
  local conf; conf="$(find_datum_config)"
  if [[ -n "$conf" ]] && command -v jq >/dev/null 2>&1; then
    local url user pass cookie
    url=$(jq -r '.bitcoind.rpcurl // ""' "$conf")
    user=$(jq -r '.bitcoind.rpcuser // ""' "$conf")
    pass=$(jq -r '.bitcoind.rpcpassword // ""' "$conf")
    cookie=$(jq -r '.bitcoind.rpccookiefile // ""' "$conf")
    say "Bitcoin Knots RPC probe:"
    probe_knots_rpc "$url" "$user" "$pass" "$cookie" || true
  fi
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------

print_menu() {
  local bin conf svc
  bin=$([[ -x "$USER_BIN" ]] && echo "user-local" || ([[ -x "$SYS_BIN" ]] && echo "system-wide" || echo "not installed"))
  conf=$([[ -r "$USER_CONF_FILE" ]] && echo "present" || echo "not configured")
  svc=$([[ -f "$SERVICE_FILE" ]] && echo "installed" || echo "not installed")

  cat <<EOF

  Datum Gateway setup

  Binary:   $bin
  Config:   $conf
  Service:  $svc

  1) Check Bitcoin Knots config (do this first)
  2) Build (or rebuild from latest source)
  3) Configure Datum (edit datum_gateway.json)
  4) Run in foreground  ← for bitcoin-qt users
  5) Open firewall for HashGG-in-Docker (requires sudo)
  6) Install as daemon  (requires sudo; for bitcoind users)
  7) Status
  8) Uninstall daemon only
  9) Uninstall everything
  q) Quit

EOF
}

interactive_menu() {
  while true; do
    print_menu
    local choice; choice="$(ask "Choose" "")"
    case "$choice" in
      1) action_check_knots ;;
      2) action_build ;;
      3) action_configure ;;
      4) action_run ;;
      5) action_open_firewall ;;
      6) action_install_daemon ;;
      7) action_status ;;
      8) action_uninstall_daemon ;;
      9) action_uninstall_all ;;
      q|Q|"") say "Bye."; exit 0 ;;
      *) warn "Unknown choice: $choice" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

print_help() {
  cat <<EOF
Datum Gateway helper for Debian/Ubuntu/Mint users.

Usage: $0 [COMMAND]

Commands:
  check-knots       Parse bitcoin.conf, flag missing settings Datum needs.
  build             Clone/update source and build (user-local, no root).
  configure         Prompt for settings, write ~/.config/datum_gateway/datum_gateway.json.
  run               Run Datum in the foreground. Ctrl-C to stop.
  open-firewall     One-time: allow HashGG-in-Docker to reach Datum via ufw (uses sudo).
  install-daemon    Promote the user-local install to a systemd service (uses sudo).
  uninstall-daemon  Remove the systemd service + system files (leaves user files).
  uninstall         Remove everything (user + system).
  status            Show what's installed and whether Knots RPC is reachable.
  help              Show this message.

Run with no command to get an interactive menu.

Typical bitcoin-qt workflow (Datum on demand, HashGG in Docker):
  $0 check-knots     # first: make sure bitcoin.conf is ready (see plan §4.1)
  $0 build           # once
  $0 configure       # once (or re-run to change settings)
  $0 open-firewall   # once per host, if ufw is active
  $0 run             # every time you want to mine; Ctrl-C when done

Typical bitcoind-as-service workflow:
  $0 check-knots
  $0 build
  $0 configure
  $0 install-daemon  # handles the firewall rule for you
EOF
}

main() {
  mkdir -p "$USER_LOG_DIR"
  start_logging

  local cmd="${1:-menu}"
  case "$cmd" in
    check-knots)      action_check_knots ;;
    build)            action_build ;;
    configure)        action_configure ;;
    run)              action_run ;;
    open-firewall)    action_open_firewall ;;
    install-daemon)   action_install_daemon ;;
    uninstall-daemon) action_uninstall_daemon ;;
    uninstall)        action_uninstall_all ;;
    status)           action_status ;;
    menu)             interactive_menu ;;
    -h|--help|help)   print_help ;;
    *) err "Unknown command: $cmd"; print_help; exit 1 ;;
  esac
}

main "$@"
