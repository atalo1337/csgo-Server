#!/usr/bin/env bash
set -Eeuo pipefail

# Enterprise-grade one-click installer for CS:GO dedicated server on CentOS/RHEL
# Notes:
# - CS:GO is deprecated upstream, but this script installs appid 740 as requested.
# - Default network policy opens UDP/TCP range 50000-60000 (customizable).

readonly SCRIPT_NAME="$(basename "$0")"
readonly APP_ID="740"
readonly STEAM_USER="steam"
readonly STEAM_GROUP="steam"
readonly STEAMCMD_DIR="/opt/steamcmd"
readonly CSGO_DIR="/opt/csgo"
readonly CONFIG_DIR="/etc/csgo"
readonly ENV_FILE="${CONFIG_DIR}/csgo.env"
readonly SERVICE_NAME="csgo"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly INSTALL_LOG="/var/log/csgo-install.log"
readonly LOCK_FILE="/var/lock/${SERVICE_NAME}-install.lock"

HOSTNAME="Enterprise CSGO Server"
RCON_PASSWORD=""
GSLT=""
MAP="de_dust2"
MAXPLAYERS="12"
IP_ADDR="0.0.0.0"
START_PORT="50000"
END_PORT="60000"
GAME_PORT="50000"
CLIENT_PORT="50001"
TV_PORT="50002"
OPEN_TCP="true"
OPEN_UDP="true"
ENABLE_FIREWALL="true"
START_AFTER_INSTALL="true"
FORCE="false"

PKG_MGR=""

usage() {
  cat <<USAGE
Usage:
  sudo bash ${SCRIPT_NAME} [options]

Required for public internet server:
  --gslt <token>              Steam Game Server Login Token
  --rcon <password>           RCON password (min 12 chars recommended)

Optional:
  --hostname <name>           Server hostname (default: ${HOSTNAME})
  --map <mapname>             Startup map (default: ${MAP})
  --maxplayers <num>          Max players (default: ${MAXPLAYERS})
  --ip <bind_ip>              Bind IP (default: ${IP_ADDR})

Network policy:
  --start-port <port>         Range start (default: ${START_PORT})
  --end-port <port>           Range end (default: ${END_PORT})
  --game-port <port>          Game port (default: ${GAME_PORT})
  --client-port <port>        Client port (default: ${CLIENT_PORT})
  --tv-port <port>            GOTV port (default: ${TV_PORT})
  --tcp <true|false>          Open TCP range in firewalld (default: ${OPEN_TCP})
  --udp <true|false>          Open UDP range in firewalld (default: ${OPEN_UDP})
  --no-firewall               Skip firewalld configuration

Behavior:
  --no-start                  Install only, do not start service
  --force                     Recreate configs/service without prompt
  -h, --help                  Show this help

Examples:
  sudo bash ${SCRIPT_NAME} --gslt XXXX --rcon 'Strong_Rcon_Pass_123' --hostname 'CN CSGO #1'
  sudo bash ${SCRIPT_NAME} --start-port 50000 --end-port 60000 --tcp false --udp true
USAGE
}

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] [INFO] $*" | tee -a "$INSTALL_LOG"; }
warn() { echo "[$(timestamp)] [WARN] $*" | tee -a "$INSTALL_LOG" >&2; }
err() { echo "[$(timestamp)] [ERROR] $*" | tee -a "$INSTALL_LOG" >&2; }

on_error() {
  local exit_code=$?
  err "Install failed at line $1 (exit=${exit_code}). Check log: ${INSTALL_LOG}"
  exit "$exit_code"
}
trap 'on_error ${LINENO}' ERR

acquire_lock() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    err "Another installation process is running (lock: ${LOCK_FILE})."
    exit 1
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root. Example: sudo bash ${SCRIPT_NAME} ..."
    exit 1
  fi
}

parse_bool() {
  local v="${1,,}"
  case "$v" in
    true|false) echo "$v" ;;
    *) err "Invalid boolean value: $1 (use true/false)"; exit 1 ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gslt) GSLT="${2:-}"; shift 2 ;;
      --rcon) RCON_PASSWORD="${2:-}"; shift 2 ;;
      --hostname) HOSTNAME="${2:-}"; shift 2 ;;
      --map) MAP="${2:-}"; shift 2 ;;
      --maxplayers) MAXPLAYERS="${2:-}"; shift 2 ;;
      --ip) IP_ADDR="${2:-}"; shift 2 ;;
      --start-port) START_PORT="${2:-}"; shift 2 ;;
      --end-port) END_PORT="${2:-}"; shift 2 ;;
      --game-port) GAME_PORT="${2:-}"; shift 2 ;;
      --client-port) CLIENT_PORT="${2:-}"; shift 2 ;;
      --tv-port) TV_PORT="${2:-}"; shift 2 ;;
      --tcp) OPEN_TCP="$(parse_bool "${2:-}")"; shift 2 ;;
      --udp) OPEN_UDP="$(parse_bool "${2:-}")"; shift 2 ;;
      --no-firewall) ENABLE_FIREWALL="false"; shift 1 ;;
      --no-start) START_AFTER_INSTALL="false"; shift 1 ;;
      --force) FORCE="true"; shift 1 ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 ))
}

validate_inputs() {
  for p in "$START_PORT" "$END_PORT" "$GAME_PORT" "$CLIENT_PORT" "$TV_PORT"; do
    if ! validate_port "$p"; then
      err "Invalid port: $p"
      exit 1
    fi
  done

  if (( START_PORT > END_PORT )); then
    err "--start-port must be <= --end-port"
    exit 1
  fi

  for p in "$GAME_PORT" "$CLIENT_PORT" "$TV_PORT"; do
    if (( p < START_PORT || p > END_PORT )); then
      err "Port $p is outside allowed range ${START_PORT}-${END_PORT}"
      exit 1
    fi
  done

  if [[ ! "$MAXPLAYERS" =~ ^[0-9]+$ ]] || (( MAXPLAYERS < 1 || MAXPLAYERS > 64 )); then
    err "--maxplayers must be a number in [1,64]"
    exit 1
  fi

  if [[ -n "$RCON_PASSWORD" ]] && (( ${#RCON_PASSWORD} < 12 )); then
    warn "RCON password length < 12. Enterprise best practice is >= 12 characters."
  fi

  if [[ -z "$RCON_PASSWORD" ]]; then
    err "--rcon is required for secure operation."
    exit 1
  fi

  if [[ -z "$GSLT" ]]; then
    warn "No GSLT provided. Internet listing may fail."
  fi
}

detect_pkg_mgr() {
  if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    err "No supported package manager found (dnf/yum)."
    exit 1
  fi
  log "Using package manager: ${PKG_MGR}"
}

install_packages() {
  log "Installing dependencies..."
  "$PKG_MGR" -y makecache
  "$PKG_MGR" -y install epel-release || true
  "$PKG_MGR" -y install \
    glibc.i686 libstdc++.i686 libgcc.i686 \
    wget curl tar gzip ca-certificates \
    util-linux shadow-utils screen tmux firewalld
}

prepare_system_user_and_dirs() {
  log "Preparing system user and directories..."

  if ! getent group "$STEAM_GROUP" >/dev/null 2>&1; then
    groupadd --system "$STEAM_GROUP"
  fi

  if ! id -u "$STEAM_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/home/${STEAM_USER}" \
      --shell /sbin/nologin --gid "$STEAM_GROUP" "$STEAM_USER"
  fi

  mkdir -p "$STEAMCMD_DIR" "$CSGO_DIR" "$CONFIG_DIR"
  chown -R "$STEAM_USER:$STEAM_GROUP" "$STEAMCMD_DIR" "$CSGO_DIR" "$CONFIG_DIR"
  chmod 750 "$CSGO_DIR"
}

backup_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local ts
    ts=$(date +%Y%m%d%H%M%S)
    cp -a "$file" "${file}.bak.${ts}"
    log "Backed up existing file: ${file}.bak.${ts}"
  fi
}

install_steamcmd() {
  log "Installing SteamCMD..."
  su -s /bin/bash - "$STEAM_USER" -c "mkdir -p '$STEAMCMD_DIR'"
  su -s /bin/bash - "$STEAM_USER" -c "cd '$STEAMCMD_DIR' && curl -fsSL -o steamcmd_linux.tar.gz 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz'"
  su -s /bin/bash - "$STEAM_USER" -c "cd '$STEAMCMD_DIR' && tar -xzf steamcmd_linux.tar.gz"
}

install_or_update_csgo() {
  log "Installing/updating CS:GO dedicated server (appid=${APP_ID})..."
  su -s /bin/bash - "$STEAM_USER" -c "'$STEAMCMD_DIR/steamcmd.sh' +force_install_dir '$CSGO_DIR' +login anonymous +app_update ${APP_ID} validate +quit"
}

write_env_file() {
  log "Writing runtime env file: ${ENV_FILE}"
  backup_if_exists "$ENV_FILE"

  cat > "$ENV_FILE" <<ENV
# Managed by ${SCRIPT_NAME}
HOSTNAME='${HOSTNAME}'
RCON_PASSWORD='${RCON_PASSWORD}'
GSLT='${GSLT}'
MAP='${MAP}'
MAXPLAYERS='${MAXPLAYERS}'
IP_ADDR='${IP_ADDR}'
GAME_PORT='${GAME_PORT}'
CLIENT_PORT='${CLIENT_PORT}'
TV_PORT='${TV_PORT}'
ENV

  chmod 640 "$ENV_FILE"
  chown root:"$STEAM_GROUP" "$ENV_FILE"
}

write_server_cfg() {
  local cfg_dir="${CSGO_DIR}/csgo/cfg"
  local cfg_file="${cfg_dir}/server.cfg"

  mkdir -p "$cfg_dir"
  backup_if_exists "$cfg_file"

  cat > "$cfg_file" <<CFG
hostname "${HOSTNAME}"
rcon_password "${RCON_PASSWORD}"
sv_password ""
sv_lan 0
sv_cheats 0

sv_hibernate_when_empty 0
sv_allow_votes 0
sv_region 255

mp_autokick 0
mp_autoteambalance 1
mp_limitteams 2
mp_maxrounds 30
mp_roundtime 1.92
mp_roundtime_defuse 1.92
mp_buytime 0.25

log on
CFG

  chown -R "$STEAM_USER:$STEAM_GROUP" "${CSGO_DIR}/csgo"
}

write_start_script() {
  local start_script="${CSGO_DIR}/start.sh"
  backup_if_exists "$start_script"

  log "Writing launcher script: ${start_script}"
  cat > "$start_script" <<'START'
#!/usr/bin/env bash
set -Eeuo pipefail

readonly CSGO_DIR="/opt/csgo"
readonly ENV_FILE="/etc/csgo/csgo.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] Missing env file: $ENV_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

cd "$CSGO_DIR"

EXTRA_ARGS=()
if [[ -n "${GSLT:-}" ]]; then
  EXTRA_ARGS+=("+sv_setsteamaccount" "$GSLT")
fi

exec ./srcds_run -game csgo -console -usercon \
  -ip "${IP_ADDR}" \
  -port "${GAME_PORT}" \
  +clientport "${CLIENT_PORT}" \
  +tv_port "${TV_PORT}" \
  +map "${MAP}" \
  +maxplayers "${MAXPLAYERS}" \
  "${EXTRA_ARGS[@]}" \
  +exec server.cfg
START

  chmod 750 "$start_script"
  chown "$STEAM_USER:$STEAM_GROUP" "$start_script"
}

write_systemd_service() {
  log "Writing systemd service: ${SERVICE_FILE}"
  backup_if_exists "$SERVICE_FILE"

  cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=CS:GO Dedicated Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${STEAM_USER}
Group=${STEAM_GROUP}
WorkingDirectory=${CSGO_DIR}
ExecStart=${CSGO_DIR}/start.sh
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=always
RestartSec=10
TimeoutStartSec=300
TimeoutStopSec=30
LimitNOFILE=1048576

# Basic hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=false
ReadWritePaths=${CSGO_DIR}

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
}

configure_firewall() {
  [[ "$ENABLE_FIREWALL" == "true" ]] || { log "Skipping firewalld setup"; return; }

  if ! command -v firewall-cmd >/dev/null 2>&1; then
    warn "firewall-cmd not found. Skipping firewall configuration."
    return
  fi

  log "Configuring firewalld range ${START_PORT}-${END_PORT}"
  systemctl enable firewalld >/dev/null 2>&1 || true
  systemctl start firewalld >/dev/null 2>&1 || true

  if [[ "$OPEN_UDP" == "true" ]]; then
    firewall-cmd --permanent --add-port="${START_PORT}-${END_PORT}/udp"
  fi
  if [[ "$OPEN_TCP" == "true" ]]; then
    firewall-cmd --permanent --add-port="${START_PORT}-${END_PORT}/tcp"
  fi

  firewall-cmd --reload
}

verify_installation() {
  log "Verifying installation artifacts..."
  [[ -x "${STEAMCMD_DIR}/steamcmd.sh" ]] || { err "Missing steamcmd.sh"; exit 1; }
  [[ -x "${CSGO_DIR}/srcds_run" ]] || { err "Missing srcds_run"; exit 1; }
  [[ -f "${CSGO_DIR}/csgo/cfg/server.cfg" ]] || { err "Missing server.cfg"; exit 1; }
  [[ -f "$ENV_FILE" ]] || { err "Missing env file"; exit 1; }
}

start_service() {
  [[ "$START_AFTER_INSTALL" == "true" ]] || { log "Skipping service start"; return; }

  log "Starting service: ${SERVICE_NAME}"
  systemctl restart "$SERVICE_NAME"
  sleep 3

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Service ${SERVICE_NAME} is active"
  else
    err "Service ${SERVICE_NAME} failed to start"
    systemctl --no-pager --full status "$SERVICE_NAME" || true
    exit 1
  fi
}

print_summary() {
  cat <<INFO

================== INSTALL COMPLETE ==================
Service name      : ${SERVICE_NAME}
Install dir       : ${CSGO_DIR}
SteamCMD dir      : ${STEAMCMD_DIR}
Config env        : ${ENV_FILE}
Ports             : game=${GAME_PORT}, client=${CLIENT_PORT}, tv=${TV_PORT}
Allowed range     : ${START_PORT}-${END_PORT}
Firewall opened   : udp=${OPEN_UDP}, tcp=${OPEN_TCP}
Started now       : ${START_AFTER_INSTALL}
Log file          : ${INSTALL_LOG}

Useful commands:
  systemctl status ${SERVICE_NAME}
  systemctl restart ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
======================================================
INFO
}

main() {
  require_root
  acquire_lock
  parse_args "$@"
  detect_pkg_mgr
  validate_inputs

  install_packages
  prepare_system_user_and_dirs
  install_steamcmd
  install_or_update_csgo
  write_env_file
  write_server_cfg
  write_start_script
  write_systemd_service
  configure_firewall
  verify_installation
  start_service
  print_summary
}

main "$@"
