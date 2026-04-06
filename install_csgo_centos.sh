#!/usr/bin/env bash
set -euo pipefail

# One-click installer for CS:GO Dedicated Server on CentOS/RHEL
# Usage:
#   sudo bash install_csgo_centos.sh \
#     --gslt YOUR_GSLT \
#     --rcon YOUR_RCON_PASSWORD \
#     --hostname "My CSGO Server"

APP_ID=740
STEAM_USER="steam"
STEAM_HOME="/home/${STEAM_USER}"
STEAMCMD_DIR="/opt/steamcmd"
CSGO_DIR="/opt/csgo"
SERVICE_NAME="csgo"
START_PORT=50000
END_PORT=60000
GAME_PORT=50000
CLIENT_PORT=50001
TV_PORT=50002
MAXPLAYERS=12
MAP="de_dust2"
HOSTNAME="CentOS CSGO Server"
RCON_PASSWORD="ChangeMe_Strong_Rcon_Password"
GSLT=""

usage() {
  cat <<USAGE
Usage:
  sudo bash $0 [options]

Options:
  --gslt <token>           Steam Game Server Login Token (recommended)
  --rcon <password>        RCON password (default: ${RCON_PASSWORD})
  --hostname <name>        Server hostname (default: ${HOSTNAME})
  --map <mapname>          Start map (default: ${MAP})
  --maxplayers <num>       Max players (default: ${MAXPLAYERS})
  --help                   Show this help
USAGE
}

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR ]\033[0m $*"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gslt)
        GSLT="${2:-}"; shift 2 ;;
      --rcon)
        RCON_PASSWORD="${2:-}"; shift 2 ;;
      --hostname)
        HOSTNAME="${2:-}"; shift 2 ;;
      --map)
        MAP="${2:-}"; shift 2 ;;
      --maxplayers)
        MAXPLAYERS="${2:-}"; shift 2 ;;
      --help|-h)
        usage; exit 0 ;;
      *)
        err "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root: sudo bash $0 ..."
    exit 1
  fi
}

pkg_install() {
  local PKG_MGR
  if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    err "Neither dnf nor yum was found. Unsupported system."
    exit 1
  fi

  log "Installing dependencies with ${PKG_MGR} ..."
  "${PKG_MGR}" -y update
  "${PKG_MGR}" -y install epel-release || true

  if [[ "${PKG_MGR}" == "dnf" ]]; then
    "${PKG_MGR}" -y install glibc.i686 libstdc++.i686 libgcc.i686 \
      wget tar curl ca-certificates screen tmux firewalld
  else
    "${PKG_MGR}" -y install glibc.i686 libstdc++.i686 libgcc.i686 \
      wget tar curl ca-certificates screen tmux firewalld
  fi
}

prepare_user_dirs() {
  log "Creating user and directories ..."
  id -u "${STEAM_USER}" >/dev/null 2>&1 || useradd -m -s /bin/bash "${STEAM_USER}"

  mkdir -p "${STEAMCMD_DIR}" "${CSGO_DIR}" "${CSGO_DIR}/logs"
  chown -R "${STEAM_USER}:${STEAM_USER}" "${STEAMCMD_DIR}" "${CSGO_DIR}"
}

install_steamcmd() {
  log "Installing SteamCMD ..."
  su - "${STEAM_USER}" -c "mkdir -p ${STEAMCMD_DIR}"
  su - "${STEAM_USER}" -c "cd ${STEAMCMD_DIR} && wget -q -O steamcmd_linux.tar.gz https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
  su - "${STEAM_USER}" -c "cd ${STEAMCMD_DIR} && tar -xzf steamcmd_linux.tar.gz"
}

install_csgo_server() {
  log "Downloading/updating CS:GO dedicated server (appid ${APP_ID}) ..."
  su - "${STEAM_USER}" -c "${STEAMCMD_DIR}/steamcmd.sh +force_install_dir ${CSGO_DIR} +login anonymous +app_update ${APP_ID} validate +quit"
}

write_server_cfg() {
  log "Writing server configuration ..."
  mkdir -p "${CSGO_DIR}/csgo/cfg"

  cat > "${CSGO_DIR}/csgo/cfg/server.cfg" <<CFG
hostname "${HOSTNAME}"
rcon_password "${RCON_PASSWORD}"
sv_password ""
sv_lan 0
sv_cheats 0

mp_autokick 0
mp_autoteambalance 1
mp_limitteams 2
mp_maxrounds 30
mp_roundtime 1.92
mp_roundtime_defuse 1.92
mp_buytime 0.25

sv_hibernate_when_empty 0
sv_allow_votes 0
sv_region 255
log on
CFG

  chown -R "${STEAM_USER}:${STEAM_USER}" "${CSGO_DIR}/csgo/cfg"
}

write_start_script() {
  log "Creating start script ..."
  local EXTRA=""
  if [[ -n "${GSLT}" ]]; then
    EXTRA="+sv_setsteamaccount ${GSLT}"
  else
    warn "No GSLT provided. Server may not be publicly joinable."
  fi

  cat > "${CSGO_DIR}/start.sh" <<START
#!/usr/bin/env bash
set -euo pipefail
cd "${CSGO_DIR}"

./srcds_run -game csgo -console -usercon \
  -ip 0.0.0.0 -port ${GAME_PORT} +clientport ${CLIENT_PORT} +tv_port ${TV_PORT} \
  +map ${MAP} +maxplayers ${MAXPLAYERS} \
  ${EXTRA} \
  +exec server.cfg
START

  chmod +x "${CSGO_DIR}/start.sh"
  chown "${STEAM_USER}:${STEAM_USER}" "${CSGO_DIR}/start.sh"
}

write_systemd_service() {
  log "Creating systemd service ..."
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<SERVICE
[Unit]
Description=CS:GO Dedicated Server
After=network.target

[Service]
Type=simple
User=${STEAM_USER}
Group=${STEAM_USER}
WorkingDirectory=${CSGO_DIR}
ExecStart=${CSGO_DIR}/start.sh
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=always
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
}

configure_firewall() {
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    warn "firewall-cmd not found; skipping firewall setup."
    return
  fi

  log "Configuring firewalld for port range ${START_PORT}-${END_PORT} ..."
  systemctl enable firewalld >/dev/null 2>&1 || true
  systemctl restart firewalld || true

  firewall-cmd --permanent --add-port=${START_PORT}-${END_PORT}/udp
  firewall-cmd --permanent --add-port=${START_PORT}-${END_PORT}/tcp
  firewall-cmd --reload
}

start_service() {
  log "Starting ${SERVICE_NAME} service ..."
  systemctl restart "${SERVICE_NAME}"
  sleep 2
  systemctl --no-pager --full status "${SERVICE_NAME}" || true
}

post_info() {
  cat <<INFO

==================== DONE ====================
CS:GO server installed in: ${CSGO_DIR}
Systemd service: ${SERVICE_NAME}
Main ports:
  game port   : ${GAME_PORT}/udp
  client port : ${CLIENT_PORT}/udp
  tv port     : ${TV_PORT}/udp
Allowed range : ${START_PORT}-${END_PORT} (tcp/udp)

Useful commands:
  systemctl status ${SERVICE_NAME}
  systemctl restart ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f

If server doesn't show in internet list, check:
1) GSLT is valid and not reused on another server
2) Cloud provider security group allows ${START_PORT}-${END_PORT}/udp
3) Public IP is reachable
==============================================
INFO
}

main() {
  parse_args "$@"
  require_root
  pkg_install
  prepare_user_dirs
  install_steamcmd
  install_csgo_server
  write_server_cfg
  write_start_script
  write_systemd_service
  configure_firewall
  start_service
  post_info
}

main "$@"
