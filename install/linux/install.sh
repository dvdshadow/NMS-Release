#!/usr/bin/env bash
# =============================================================================
#  NMS Server — Linux installer
#
#  Builds this repository's custom EQEmu-based server, imports the bundled
#  database, installs quests/plugins, downloads maps + Spire, and writes a
#  ready-to-run server folder (Spire-compatible layout).
#
#  Inspired by Akkadius / EQEmu Spire installers, adapted for the NMS release.
#
#  Usage:
#    sudo ./install/linux/install.sh
#    ./install/linux/install.sh --help
#
#  Non-interactive example:
#    sudo NMS_NONINTERACTIVE=1 NMS_DB_ROOT_PASSWORD=secret \
#         NMS_DB_PASSWORD=eqemu NMS_SPIRE_PASSWORD=admin \
#         ./install/linux/install.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_DIR="$(cd "${SCRIPT_DIR}/../common" && pwd)"
SOURCE_DIR="${REPO_ROOT}/Release-NMS-Server"
QUESTS_SRC="${REPO_ROOT}/Release-NMS-Quests"
PLUGINS_SRC="${REPO_ROOT}/Release-NMS-Plugins"

SPIRE_REPO_OWNER="EQEmu"
SPIRE_REPO_NAME="spire"
MAPS_URL="https://github.com/EQEmu/maps/releases/latest/download/maps.zip"

# ---- defaults (overridable by env / prompts / flags) ------------------------
NMS_INSTALL_DIR="${NMS_INSTALL_DIR:-${HOME}/nms-server}"
NMS_SHORT_NAME="${NMS_SHORT_NAME:-NMS}"
NMS_LONG_NAME="${NMS_LONG_NAME:-NMS Community Release}"
NMS_DB_HOST="${NMS_DB_HOST:-127.0.0.1}"
NMS_DB_PORT="${NMS_DB_PORT:-3306}"
NMS_DB_NAME="${NMS_DB_NAME:-nms}"
NMS_DB_USER="${NMS_DB_USER:-nms}"
NMS_DB_PASSWORD="${NMS_DB_PASSWORD:-}"
NMS_DB_ROOT_PASSWORD="${NMS_DB_ROOT_PASSWORD:-}"
NMS_SPIRE_USER="${NMS_SPIRE_USER:-admin}"
NMS_SPIRE_PASSWORD="${NMS_SPIRE_PASSWORD:-}"
NMS_SPIRE_PORT="${NMS_SPIRE_PORT:-3000}"
NMS_PUBLIC_ADDRESS="${NMS_PUBLIC_ADDRESS:-127.0.0.1}"
NMS_LOCAL_ADDRESS="${NMS_LOCAL_ADDRESS:-127.0.0.1}"
NMS_SKIP_DEPS="${NMS_SKIP_DEPS:-0}"
NMS_SKIP_BUILD="${NMS_SKIP_BUILD:-0}"
NMS_SKIP_MAPS="${NMS_SKIP_MAPS:-0}"
NMS_SKIP_DB_IMPORT="${NMS_SKIP_DB_IMPORT:-0}"
NMS_USE_EXISTING_MYSQL="${NMS_USE_EXISTING_MYSQL:-0}"
NMS_NONINTERACTIVE="${NMS_NONINTERACTIVE:-0}"
NMS_INSTALL_CRON="${NMS_INSTALL_CRON:-0}"
NMS_JOBS="${NMS_JOBS:-$(nproc 2>/dev/null || echo 2)}"
NMS_INSTALL_DIR_CLI="${NMS_INSTALL_DIR_CLI:-0}"

# Remembered MariaDB root login (set by discover_root_login).
MYSQL_CLI=""
MYSQL_ROOT_USE_SUDO=0
MYSQL_ROOT_ARGS=()

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

RED=$'\033[0;31m'
GRN=$'\033[0;32m'
YLW=$'\033[0;33m'
CYN=$'\033[0;36m'
BLD=$'\033[1m'
RST=$'\033[0m'

log()  { printf '%s›%s %s\n' "${CYN}${BLD}" "${RST}" "$*"; }
ok()   { printf '%s✓%s %s\n' "${GRN}" "${RST}" "$*"; }
warn() { printf '%s!%s %s\n' "${YLW}" "${RST}" "$*"; }
die()  { printf '%s✗%s %s\n' "${RED}" "${RST}" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
NMS Server Linux installer

Options:
  --install-dir PATH     Runtime server folder (default: ~/nms-server)
  --db-name NAME         MySQL/MariaDB database name (default: nms)
  --db-user USER         Database username (default: nms)
  --db-password PASS     Database password (random if omitted)
  --db-root-password P   MariaDB root password (required when installing MariaDB)
  --spire-user USER      Spire admin username (default: admin)
  --spire-password PASS  Spire admin password (random if omitted)
  --spire-port PORT      Spire HTTP port (default: 3000)
  --short-name NAME      Server short name (default: NMS)
  --long-name NAME       Server long name
  --public-address IP    Public/WAN address written into eqemu_config.json
  --local-address IP     LAN address written into eqemu_config.json
  --jobs N               Parallel build jobs (default: nproc)
  --skip-deps            Do not apt/yum install packages
  --skip-build           Reuse previously built binaries in Release-NMS-Server/build/bin
  --skip-maps            Do not download the ~1 GB maps pack
  --skip-db-import       Create DB/user only; skip sourcing release-peq.sql
  --use-existing-mysql   Assume MariaDB/MySQL is already installed and root can connect
  --install-cron         Install an @reboot Spire keepalive cron entry
  --non-interactive      Never prompt; fail if required values are missing
  -h, --help             Show this help

Environment variables with the same names (NMS_INSTALL_DIR, NMS_DB_PASSWORD, …)
are also accepted.
EOF
}

random_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 | tr -d '/+=' | cut -c1-20
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
  fi
}

prompt_value() {
  local label="$1" default="$2" silent="${3:-0}" value=""
  if [[ "${NMS_NONINTERACTIVE}" == "1" ]]; then
    printf '%s\n' "${default}"
    return 0
  fi
  if [[ "${silent}" == "1" ]]; then
    read -r -s -p "${label} [${default}]: " value || true
    echo >&2
  else
    read -r -p "${label} [${default}]: " value || true
  fi
  if [[ -z "${value}" ]]; then
    printf '%s\n' "${default}"
  else
    printf '%s\n' "${value}"
  fi
}

confirm() {
  local label="$1" default="${2:-Y}" answer=""
  if [[ "${NMS_NONINTERACTIVE}" == "1" ]]; then
    [[ "${default}" =~ ^[Yy] ]]
    return $?
  fi
  read -r -p "${label} [${default}]: " answer || true
  answer="${answer:-${default}}"
  [[ "${answer}" =~ ^[Yy] ]]
}

have_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1
}

run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  elif [[ -f /etc/debian_version ]]; then
    OS_ID="debian"
    OS_LIKE="debian"
  elif [[ -f /etc/redhat-release ]]; then
    OS_ID="rhel"
    OS_LIKE="rhel"
  else
    OS_ID="unknown"
    OS_LIKE=""
  fi
}

detect_primary_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  fi
  if [[ -z "${ip}" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [[ -z "${ip}" ]]; then
    ip="127.0.0.1"
  fi
  printf '%s\n' "${ip}"
}

apply_headless_defaults() {
  if [[ ! -t 0 && "${NMS_NONINTERACTIVE}" != "1" ]]; then
    warn "No TTY detected (typical on a headless/cloud box). Using non-interactive defaults."
    NMS_NONINTERACTIVE=1
  fi

  # sudo ./install.sh would otherwise drop the runtime tree in /root/nms-server.
  if [[ "${NMS_INSTALL_DIR_CLI}" != "1" && "${EUID}" -eq 0 ]]; then
    if [[ "${NMS_INSTALL_DIR}" == "${HOME}/nms-server" || "${NMS_INSTALL_DIR}" == "/root/nms-server" ]]; then
      NMS_INSTALL_DIR="/opt/nms-server"
      warn "Running as root; default install directory is ${NMS_INSTALL_DIR}"
    fi
  fi

  if [[ "${NMS_PUBLIC_ADDRESS}" == "127.0.0.1" || "${NMS_LOCAL_ADDRESS}" == "127.0.0.1" ]]; then
    local detected
    detected="$(detect_primary_ip)"
    if [[ -n "${detected}" && "${detected}" != "127.0.0.1" ]]; then
      if [[ "${NMS_PUBLIC_ADDRESS}" == "127.0.0.1" ]]; then
        NMS_PUBLIC_ADDRESS="${detected}"
      fi
      if [[ "${NMS_LOCAL_ADDRESS}" == "127.0.0.1" ]]; then
        NMS_LOCAL_ADDRESS="${detected}"
      fi
      ok "Detected host address ${detected} (override at the prompt if this is wrong)"
    fi
  fi
}

try_apt_install() {
  local pkg
  for pkg in "$@"; do
    if run_root apt-get install -y --no-install-recommends "${pkg}"; then
      return 0
    fi
    warn "Package ${pkg} was not available; trying the next option"
  done
  return 1
}

try_rpm_install() {
  local pm="$1"
  shift
  local pkg
  for pkg in "$@"; do
    if run_root "${pm}" -y install "${pkg}"; then
      return 0
    fi
    warn "Package ${pkg} was not available; trying the next option"
  done
  return 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir) NMS_INSTALL_DIR="$2"; NMS_INSTALL_DIR_CLI=1; shift 2 ;;
      --db-name) NMS_DB_NAME="$2"; shift 2 ;;
      --db-user) NMS_DB_USER="$2"; shift 2 ;;
      --db-password) NMS_DB_PASSWORD="$2"; shift 2 ;;
      --db-root-password) NMS_DB_ROOT_PASSWORD="$2"; shift 2 ;;
      --spire-user) NMS_SPIRE_USER="$2"; shift 2 ;;
      --spire-password) NMS_SPIRE_PASSWORD="$2"; shift 2 ;;
      --spire-port) NMS_SPIRE_PORT="$2"; shift 2 ;;
      --short-name) NMS_SHORT_NAME="$2"; shift 2 ;;
      --long-name) NMS_LONG_NAME="$2"; shift 2 ;;
      --public-address) NMS_PUBLIC_ADDRESS="$2"; shift 2 ;;
      --local-address) NMS_LOCAL_ADDRESS="$2"; shift 2 ;;
      --jobs) NMS_JOBS="$2"; shift 2 ;;
      --skip-deps) NMS_SKIP_DEPS=1; shift ;;
      --skip-build) NMS_SKIP_BUILD=1; shift ;;
      --skip-maps) NMS_SKIP_MAPS=1; shift ;;
      --skip-db-import) NMS_SKIP_DB_IMPORT=1; shift ;;
      --use-existing-mysql) NMS_USE_EXISTING_MYSQL=1; shift ;;
      --install-cron) NMS_INSTALL_CRON=1; shift ;;
      --non-interactive) NMS_NONINTERACTIVE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1 (see --help)" ;;
    esac
  done
}

banner() {
  cat <<EOF
${BLD}${CYN}
--------------------------------------------------------------------------------
|  NMS Server Linux Installer                                                  |
|  Builds this release + installs Spire for admin / content editing            |
--------------------------------------------------------------------------------
${RST}
Source:   ${SOURCE_DIR}
Quests:   ${QUESTS_SRC}
Plugins:  ${PLUGINS_SRC}
Install:  ${NMS_INSTALL_DIR}

This will:
  • install build/runtime packages (MariaDB, Perl, Lua, CMake, …) unless skipped
  • compile world/zone/ucs/queryserv/loginserver/shared_memory from this tree
  • import database/release-peq.zip into a fresh schema
  • copy quests + plugins into the runtime folder
  • download EQEmu maps (~1 GB) unless skipped
  • download Spire and wire start/stop helpers around it
EOF
}

gather_config() {
  log "Collecting install settings"
  NMS_INSTALL_DIR="$(prompt_value "Server install directory" "${NMS_INSTALL_DIR}")"
  NMS_SHORT_NAME="$(prompt_value "Server short name" "${NMS_SHORT_NAME}")"
  NMS_LONG_NAME="$(prompt_value "Server long name" "${NMS_LONG_NAME}")"
  NMS_PUBLIC_ADDRESS="$(prompt_value "Public address (WAN/LAN IP clients use)" "${NMS_PUBLIC_ADDRESS}")"
  NMS_LOCAL_ADDRESS="$(prompt_value "Local address" "${NMS_LOCAL_ADDRESS}")"
  NMS_DB_NAME="$(prompt_value "Database name" "${NMS_DB_NAME}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')"
  NMS_DB_USER="$(prompt_value "Database username" "${NMS_DB_USER}")"

  if [[ -z "${NMS_DB_PASSWORD}" ]]; then
    NMS_DB_PASSWORD="$(random_password)"
  fi
  NMS_DB_PASSWORD="$(prompt_value "Database password" "${NMS_DB_PASSWORD}" 1)"

  if [[ "${NMS_USE_EXISTING_MYSQL}" != "1" ]]; then
    if confirm "Install/configure local MariaDB via package manager?" "Y"; then
      NMS_USE_EXISTING_MYSQL=0
      if [[ -z "${NMS_DB_ROOT_PASSWORD}" ]]; then
        NMS_DB_ROOT_PASSWORD="$(random_password)"
      fi
      NMS_DB_ROOT_PASSWORD="$(prompt_value "MariaDB root password" "${NMS_DB_ROOT_PASSWORD}" 1)"
    else
      NMS_USE_EXISTING_MYSQL=1
    fi
  fi

  if [[ -z "${NMS_SPIRE_PASSWORD}" ]]; then
    NMS_SPIRE_PASSWORD="$(random_password)"
  fi
  NMS_SPIRE_USER="$(prompt_value "Spire admin username" "${NMS_SPIRE_USER}")"
  NMS_SPIRE_PASSWORD="$(prompt_value "Spire admin password" "${NMS_SPIRE_PASSWORD}" 1)"
  NMS_SPIRE_PORT="$(prompt_value "Spire HTTP port" "${NMS_SPIRE_PORT}")"

  if [[ "${NMS_SKIP_MAPS}" != "1" ]]; then
    if ! confirm "Download EQEmu maps pack (~1 GB)?" "Y"; then
      NMS_SKIP_MAPS=1
    fi
  fi

  WORLD_KEY="$(random_password)$(random_password)"
}

require_repo_layout() {
  [[ -d "${SOURCE_DIR}" ]] || die "Missing ${SOURCE_DIR}"
  [[ -f "${SOURCE_DIR}/CMakeLists.txt" ]] || die "Missing server CMakeLists.txt"
  [[ -f "${SOURCE_DIR}/database/release-peq.zip" ]] || die "Missing database/release-peq.zip"
  [[ -d "${QUESTS_SRC}" ]] || die "Missing ${QUESTS_SRC}"
  [[ -d "${PLUGINS_SRC}" ]] || die "Missing ${PLUGINS_SRC}"
  [[ -f "${COMMON_DIR}/eqemu_config.json.template" ]] || die "Missing config templates"
}

install_deps_debian() {
  log "Installing Debian/Ubuntu packages"
  export DEBIAN_FRONTEND=noninteractive
  run_root apt-get update -y
  # tzdata/locales can prompt on a minimal image; keep it non-interactive.
  run_root apt-get install -y --no-install-recommends tzdata ca-certificates || true
  run_root apt-get install -y --no-install-recommends \
    build-essential g++ make cmake git curl wget unzip \
    pkg-config rsync python3 procps iproute2 hostname \
    mariadb-server mariadb-client \
    perl libperl-dev libio-stringy-perl libjson-perl libdbd-mysql-perl \
    lua5.1 liblua5.1-0-dev \
    libboost-all-dev zlib1g-dev uuid-dev libssl-dev libsodium-dev

  # Do not install libmysqlclient-dev together with MariaDB: they conflict on
  # Debian/Ubuntu and break a fresh apt install. Prefer libmariadb-dev.
  try_apt_install libmariadb-dev default-libmysqlclient-dev \
    || die "Could not install a MariaDB/MySQL C development package (libmariadb-dev)"
  try_apt_install ninja-build || warn "ninja-build not available; will use Unix Makefiles"
  try_apt_install libluajit-5.1-dev || true
}

install_deps_rhel() {
  log "Installing RHEL/Fedora/CentOS packages"
  local pm
  if command -v dnf >/dev/null 2>&1; then
    pm=dnf
  else
    pm=yum
  fi
  run_root "${pm}" -y install epel-release || true
  run_root "${pm}" -y groupinstall "Development Tools" || run_root "${pm}" -y group install development || true
  run_root "${pm}" -y install gcc gcc-c++ make git curl wget unzip rsync python3 \
    || die "Failed to install core build tools"
  run_root "${pm}" -y install procps-ng iproute hostname || true
  run_root "${pm}" -y install mariadb-server mariadb \
    || die "Failed to install MariaDB"
  run_root "${pm}" -y install perl perl-core perl-devel perl-ExtUtils-Embed \
    || die "Failed to install Perl development files (needed to embed Perl in zone)"
  run_root "${pm}" -y install perl-DBD-MySQL perl-JSON || true
  run_root "${pm}" -y install lua-devel boost-devel zlib-devel libuuid-devel \
    openssl-devel libsodium-devel \
    || die "Failed to install Lua/Boost/OpenSSL/libsodium development packages"
  try_rpm_install "${pm}" cmake cmake3 || die "cmake is required"
  try_rpm_install "${pm}" ninja-build ninja || warn "ninja not available; will use Unix Makefiles"
  try_rpm_install "${pm}" mariadb-devel mariadb-connector-c-devel mysql-devel \
    || die "Could not install a MariaDB/MySQL C development package"
  try_rpm_install "${pm}" perl-IO-stringy perl-IO-Stringy || true
  if ! command -v cmake >/dev/null 2>&1 && command -v cmake3 >/dev/null 2>&1; then
    run_root ln -sf "$(command -v cmake3)" /usr/local/bin/cmake
  fi
}

install_deps() {
  if [[ "${NMS_SKIP_DEPS}" == "1" ]]; then
    warn "Skipping dependency installation"
    return 0
  fi
  have_sudo || die "Root/sudo required to install packages (or pass --skip-deps)"
  detect_os
  case "${OS_ID}" in
    debian|ubuntu|linuxmint|pop|raspbian)
      install_deps_debian
      ;;
    fedora|rhel|centos|rocky|almalinux|amzn|ol)
      install_deps_rhel
      ;;
    *)
      if [[ "${OS_LIKE}" == *debian* ]]; then
        install_deps_debian
      elif [[ "${OS_LIKE}" == *rhel* || "${OS_LIKE}" == *fedora* ]]; then
        install_deps_rhel
      else
        die "Unsupported distribution (${OS_ID}). Install build-essential, cmake, g++, MariaDB, Perl, Lua, Boost, OpenSSL, and libsodium, then re-run with --skip-deps."
      fi
      ;;
  esac
  ok "Dependencies installed"
}

find_mysql_cli() {
  if command -v mariadb >/dev/null 2>&1; then
    command -v mariadb
    return 0
  fi
  if command -v mysql >/dev/null 2>&1; then
    command -v mysql
    return 0
  fi
  return 1
}

mysql_port_open() {
  local host="${1:-127.0.0.1}" port="${2:-${NMS_DB_PORT}}"
  if command -v timeout >/dev/null 2>&1; then
    timeout 1 bash -c "echo >/dev/tcp/${host}/${port}" >/dev/null 2>&1
  else
    bash -c "echo >/dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

ensure_mariadb_datadir() {
  if [[ -d /var/lib/mysql/mysql ]]; then
    return 0
  fi
  have_sudo || return 0
  warn "MariaDB data directory looks uninitialized; running mariadb-install-db"
  if command -v mariadb-install-db >/dev/null 2>&1; then
    run_root mariadb-install-db --user=mysql || true
  elif command -v mysql_install_db >/dev/null 2>&1; then
    run_root mysql_install_db --user=mysql || true
  fi
}

start_mariadb() {
  log "Starting MariaDB/MySQL"
  ensure_mariadb_datadir
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    local svc
    for svc in mariadb mysql mysqld; do
      run_root systemctl enable "${svc}" >/dev/null 2>&1 || true
      run_root systemctl start "${svc}" >/dev/null 2>&1 || true
    done
  elif command -v rc-service >/dev/null 2>&1; then
    run_root rc-service mariadb start >/dev/null 2>&1 || run_root rc-service mysql start >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    run_root service mariadb start >/dev/null 2>&1 || run_root service mysql start >/dev/null 2>&1 || true
  else
    warn "No service manager found; if MariaDB is not already running you will need to start it yourself"
  fi

  local i
  log "Waiting for MariaDB to accept connections"
  for i in $(seq 1 45); do
    if [[ -S /run/mysqld/mysqld.sock || -S /var/run/mysqld/mysqld.sock || -S /var/lib/mysql/mysql.sock ]]; then
      local cli
      if cli="$(find_mysql_cli)"; then
        if run_root "${cli}" -e "SELECT 1" >/dev/null 2>&1 || "${cli}" -e "SELECT 1" >/dev/null 2>&1; then
          ok "MariaDB socket is ready"
          return 0
        fi
      fi
    fi
    if mysql_port_open 127.0.0.1 "${NMS_DB_PORT}"; then
      ok "MariaDB is listening on 127.0.0.1:${NMS_DB_PORT}"
      return 0
    fi
    sleep 1
  done
  die "MariaDB did not become ready. Install mariadb-server, start it, and re-run."
}

mysql_root() {
  [[ -n "${MYSQL_CLI}" ]] || MYSQL_CLI="$(find_mysql_cli)" || die "mysql/mariadb client not found"
  if [[ "${MYSQL_ROOT_USE_SUDO}" == "1" ]]; then
    if [[ ${#MYSQL_ROOT_ARGS[@]} -gt 0 ]]; then
      run_root "${MYSQL_CLI}" "${MYSQL_ROOT_ARGS[@]}" "$@"
    else
      run_root "${MYSQL_CLI}" "$@"
    fi
  else
    if [[ ${#MYSQL_ROOT_ARGS[@]} -gt 0 ]]; then
      "${MYSQL_CLI}" "${MYSQL_ROOT_ARGS[@]}" "$@"
    else
      "${MYSQL_CLI}" "$@"
    fi
  fi
}

mysql_app() {
  local cli
  cli="$(find_mysql_cli)" || die "mysql/mariadb client not found"
  "${cli}" -u"${NMS_DB_USER}" -p"${NMS_DB_PASSWORD}" -h"${NMS_DB_HOST}" -P"${NMS_DB_PORT}" "$@"
}

discover_root_login() {
  MYSQL_CLI="$(find_mysql_cli)" || die "mysql/mariadb client not found. Install mariadb-client and re-run."
  ok "Using MariaDB/MySQL client: ${MYSQL_CLI}"
  MYSQL_ROOT_USE_SUDO=0
  MYSQL_ROOT_ARGS=()

  # Debian/Ubuntu package installs use unix_socket: OS root can log in with no password.
  if have_sudo && run_root "${MYSQL_CLI}" -e "SELECT 1" >/dev/null 2>&1; then
    MYSQL_ROOT_USE_SUDO=1
    MYSQL_ROOT_ARGS=()
    ok "Logged in as MariaDB root via local socket (sudo/unix_socket)"
    return 0
  fi
  if "${MYSQL_CLI}" -e "SELECT 1" >/dev/null 2>&1; then
    MYSQL_ROOT_ARGS=()
    ok "Logged in as MariaDB root via local socket"
    return 0
  fi

  local pass host extra
  local passwords=()
  if [[ -n "${NMS_DB_ROOT_PASSWORD}" ]]; then
    passwords+=("${NMS_DB_ROOT_PASSWORD}")
  fi
  passwords+=("")

  for pass in "${passwords[@]}"; do
    extra=(-uroot)
    if [[ -n "${pass}" ]]; then
      extra+=("-p${pass}")
    fi
    if "${MYSQL_CLI}" "${extra[@]}" -e "SELECT 1" >/dev/null 2>&1; then
      MYSQL_ROOT_ARGS=("${extra[@]}")
      ok "Logged in as MariaDB root via socket user root"
      return 0
    fi
    for host in localhost 127.0.0.1; do
      if "${MYSQL_CLI}" "${extra[@]}" -h"${host}" -P"${NMS_DB_PORT}" -e "SELECT 1" >/dev/null 2>&1; then
        MYSQL_ROOT_ARGS=("${extra[@]}" -h"${host}" -P"${NMS_DB_PORT}")
        ok "Logged in as MariaDB root via ${host}"
        return 0
      fi
      if have_sudo && run_root "${MYSQL_CLI}" "${extra[@]}" -h"${host}" -P"${NMS_DB_PORT}" -e "SELECT 1" >/dev/null 2>&1; then
        MYSQL_ROOT_USE_SUDO=1
        MYSQL_ROOT_ARGS=("${extra[@]}" -h"${host}" -P"${NMS_DB_PORT}")
        ok "Logged in as MariaDB root via sudo ${host}"
        return 0
      fi
    done
  done

  die "Could not authenticate to MariaDB as root. On Debian/Ubuntu, run this installer with sudo. If root already has a password, pass --db-root-password."
}

configure_database() {
  log "Configuring database ${NMS_DB_NAME}"
  start_mariadb
  discover_root_login

  # Do not ALTER USER root when unix_socket already works. That was the Windows
  # failure mode: a generated password was written down, then later SQL used it
  # against an account that still had an empty / socket login.
  if [[ "${MYSQL_ROOT_USE_SUDO}" == "1" && ${#MYSQL_ROOT_ARGS[@]} -eq 0 ]]; then
    NMS_DB_ROOT_PASSWORD=""
  fi

  mysql_root <<SQL
CREATE DATABASE IF NOT EXISTS \`${NMS_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL
  mysql_root -e "CREATE USER '${NMS_DB_USER}'@'localhost' IDENTIFIED BY '${NMS_DB_PASSWORD}';" >/dev/null 2>&1 || \
    mysql_root -e "ALTER USER '${NMS_DB_USER}'@'localhost' IDENTIFIED BY '${NMS_DB_PASSWORD}';" >/dev/null 2>&1 || \
    mysql_root -e "SET PASSWORD FOR '${NMS_DB_USER}'@'localhost' = PASSWORD('${NMS_DB_PASSWORD}');" >/dev/null 2>&1 || true
  mysql_root -e "CREATE USER '${NMS_DB_USER}'@'%' IDENTIFIED BY '${NMS_DB_PASSWORD}';" >/dev/null 2>&1 || \
    mysql_root -e "ALTER USER '${NMS_DB_USER}'@'%' IDENTIFIED BY '${NMS_DB_PASSWORD}';" >/dev/null 2>&1 || true
  mysql_root <<SQL
GRANT ALL PRIVILEGES ON \`${NMS_DB_NAME}\`.* TO '${NMS_DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${NMS_DB_NAME}\`.* TO '${NMS_DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

  if [[ "${NMS_SKIP_DB_IMPORT}" == "1" ]]; then
    warn "Skipping database import"
    return 0
  fi

  local table_count
  table_count="$(mysql_app -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${NMS_DB_NAME}';" || echo 0)"
  if [[ "${table_count}" -gt 100 ]]; then
    warn "Database already has ${table_count} tables — skipping import"
    return 0
  fi

  local tmpdir sqlfile
  tmpdir="$(mktemp -d)"
  log "Unpacking release-peq.zip"
  unzip -o -q "${SOURCE_DIR}/database/release-peq.zip" -d "${tmpdir}"
  sqlfile="$(find "${tmpdir}" -type f -name '*.sql' | head -n 1 || true)"
  if [[ -z "${sqlfile}" ]]; then
    rm -rf "${tmpdir}"
    die "No .sql found inside release-peq.zip"
  fi
  log "Importing $(basename "${sqlfile}") (this can take several minutes)"
  mysql_app "${NMS_DB_NAME}" < "${sqlfile}"
  rm -rf "${tmpdir}"
  ok "Database imported"
}

cmake_bin() {
  if command -v cmake >/dev/null 2>&1; then
    command -v cmake
  elif command -v cmake3 >/dev/null 2>&1; then
    command -v cmake3
  else
    return 1
  fi
}

preflight_build() {
  local cmake_exe cxx
  cmake_exe="$(cmake_bin)" || die "cmake not found. Install cmake (3.12+) and re-run."
  local ver
  ver="$("${cmake_exe}" --version | head -n 1 | awk '{print $3}')"
  ok "Using CMake ${ver} at ${cmake_exe}"
  cxx="$(command -v g++ || command -v clang++ || command -v c++ || true)"
  [[ -n "${cxx}" ]] || die "No C++ compiler found. Install g++ (GCC 10+ recommended for C++20) and re-run."
  ok "Using C++ compiler ${cxx}"
}

ensure_submodules() {
  if [[ -f "${SOURCE_DIR}/submodules/fmt/CMakeLists.txt" ]]; then
    return 0
  fi
  if [[ -d "${REPO_ROOT}/.git" ]] && command -v git >/dev/null 2>&1; then
    log "Fetching git submodules required to compile"
    git -C "${SOURCE_DIR}" submodule update --init --recursive \
      || git -C "${REPO_ROOT}" submodule update --init --recursive \
      || die "git submodule update failed"
    return 0
  fi
  die "submodules/ is empty. Clone with git clone --recursive, or copy submodules/ from a complete tree (GitHub zip downloads omit them)."
}

build_server() {
  if [[ "${NMS_SKIP_BUILD}" == "1" ]]; then
    warn "Skipping build"
    [[ -x "${SOURCE_DIR}/build/bin/world" ]] || die "No built world binary at ${SOURCE_DIR}/build/bin/world"
    return 0
  fi
  preflight_build
  ensure_submodules
  log "Building server (jobs=${NMS_JOBS})"
  local cmake_exe gen
  cmake_exe="$(cmake_bin)"
  if command -v ninja >/dev/null 2>&1; then
    gen=Ninja
  else
    gen="Unix Makefiles"
    warn "ninja not found; using Unix Makefiles"
  fi
  (
    cd "${SOURCE_DIR}"
    if [[ -f GNUmakefile ]]; then
      make -j"${NMS_JOBS}" EXTRA_CMAKE_ARGS="-DEQEMU_BUILD_LOGIN=ON"
    else
      "${cmake_exe}" -S . -B build -G "${gen}" -DCMAKE_BUILD_TYPE=Release -DEQEMU_BUILD_LOGIN=ON
      "${cmake_exe}" --build build --parallel "${NMS_JOBS}"
    fi
  )
  [[ -x "${SOURCE_DIR}/build/bin/world" ]] || die "Build finished but world binary is missing"
  ok "Server built"
}

create_runtime_dirs() {
  log "Creating runtime directory ${NMS_INSTALL_DIR}"
  mkdir -p \
    "${NMS_INSTALL_DIR}/bin" \
    "${NMS_INSTALL_DIR}/logs" \
    "${NMS_INSTALL_DIR}/shared" \
    "${NMS_INSTALL_DIR}/maps" \
    "${NMS_INSTALL_DIR}/quests" \
    "${NMS_INSTALL_DIR}/export" \
    "${NMS_INSTALL_DIR}/import" \
    "${NMS_INSTALL_DIR}/backups" \
    "${NMS_INSTALL_DIR}/assets/opcodes" \
    "${NMS_INSTALL_DIR}/assets/patches"
}

install_binaries() {
  log "Installing binaries into ${NMS_INSTALL_DIR}/bin"
  local bin src
  for bin in world zone ucs queryserv loginserver shared_memory eqlaunch export_client_files import_client_files; do
    src="${SOURCE_DIR}/build/bin/${bin}"
    if [[ -x "${src}" ]]; then
      cp -f "${src}" "${NMS_INSTALL_DIR}/bin/${bin}"
      chmod 755 "${NMS_INSTALL_DIR}/bin/${bin}"
    else
      warn "Optional binary not found: ${bin}"
    fi
  done
}

sync_tree() {
  local src="$1" dst="$2"
  mkdir -p "${dst}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude '.git' \
      --exclude 'README.md' \
      --exclude 'LICENSE' \
      "${src}/" "${dst}/"
  else
    find "${dst}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    # shellcheck disable=SC2086
    shopt -s dotglob nullglob
    for item in "${src}"/*; do
      case "$(basename "${item}")" in
        .git|README.md|LICENSE) continue ;;
      esac
      cp -a "${item}" "${dst}/"
    done
    shopt -u dotglob nullglob
  fi
}

install_quests_and_plugins() {
  log "Installing quests and plugins"
  sync_tree "${QUESTS_SRC}" "${NMS_INSTALL_DIR}/quests"
  mkdir -p "${NMS_INSTALL_DIR}/quests/plugins"
  sync_tree "${PLUGINS_SRC}" "${NMS_INSTALL_DIR}/quests/plugins"
  # Compatibility path some older layouts expect
  sync_tree "${NMS_INSTALL_DIR}/quests/plugins" "${NMS_INSTALL_DIR}/plugins"
}

install_assets() {
  log "Installing opcodes and patch files"
  cp -f "${SOURCE_DIR}/utils/patches/"*.conf "${NMS_INSTALL_DIR}/assets/patches/" 2>/dev/null || true
  cp -f "${SOURCE_DIR}/utils/patches/opcodes.conf" "${NMS_INSTALL_DIR}/assets/opcodes/" 2>/dev/null || true
  cp -f "${SOURCE_DIR}/utils/patches/mail_opcodes.conf" "${NMS_INSTALL_DIR}/assets/opcodes/" 2>/dev/null || true
  cp -f "${SOURCE_DIR}/loginserver/login_util/login_opcodes.conf" "${NMS_INSTALL_DIR}/assets/opcodes/" 2>/dev/null || true
  cp -f "${SOURCE_DIR}/loginserver/login_util/login_opcodes_sod.conf" "${NMS_INSTALL_DIR}/assets/opcodes/" 2>/dev/null || true
  # Also place login opcodes next to login.json for older defaults
  cp -f "${NMS_INSTALL_DIR}/assets/opcodes/login_opcodes.conf" "${NMS_INSTALL_DIR}/" 2>/dev/null || true
  cp -f "${NMS_INSTALL_DIR}/assets/opcodes/login_opcodes_sod.conf" "${NMS_INSTALL_DIR}/" 2>/dev/null || true
  ln -sfn maps "${NMS_INSTALL_DIR}/Maps"
}

render_template() {
  local src="$1" dst="$2"
  local content
  content="$(<"${src}")"
  content="${content//\{\{DB_HOST\}\}/${NMS_DB_HOST}}"
  content="${content//\{\{DB_PORT\}\}/${NMS_DB_PORT}}"
  content="${content//\{\{DB_NAME\}\}/${NMS_DB_NAME}}"
  content="${content//\{\{DB_USER\}\}/${NMS_DB_USER}}"
  content="${content//\{\{DB_PASSWORD\}\}/${NMS_DB_PASSWORD}}"
  content="${content//\{\{WORLD_KEY\}\}/${WORLD_KEY}}"
  content="${content//\{\{SHORT_NAME\}\}/${NMS_SHORT_NAME}}"
  content="${content//\{\{LONG_NAME\}\}/${NMS_LONG_NAME}}"
  content="${content//\{\{PUBLIC_ADDRESS\}\}/${NMS_PUBLIC_ADDRESS}}"
  content="${content//\{\{LOCAL_ADDRESS\}\}/${NMS_LOCAL_ADDRESS}}"
  content="${content//\{\{CODE_PATH\}\}/${SOURCE_DIR}}"
  content="${content//\{\{SPIRE_PORT\}\}/${NMS_SPIRE_PORT}}"
  printf '%s\n' "${content}" > "${dst}"
}

write_configs() {
  log "Writing eqemu_config.json and login.json"
  render_template "${COMMON_DIR}/eqemu_config.json.template" "${NMS_INSTALL_DIR}/eqemu_config.json"
  render_template "${COMMON_DIR}/login.json.template" "${NMS_INSTALL_DIR}/login.json"
}

http_get() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --progress-bar -o "${dest}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${dest}" "${url}"
  else
    die "Need curl or wget to download ${url}"
  fi
}

http_get_stdout() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "${url}"
  else
    die "Need curl or wget to download ${url}"
  fi
}

spire_asset_url() {
  local api="$1" asset_name="$2"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "${api}" | python3 -c "import sys,json; r=json.load(sys.stdin); print(next(a['browser_download_url'] for a in r['assets'] if a['name']=='${asset_name}'))"
    return 0
  fi
  printf '%s' "${api}" | tr '{},' '\n' | awk -v name="${asset_name}" '
    $0 ~ /"name":/ && $0 ~ name { found=1 }
    found && /browser_download_url/ {
      gsub(/.*"browser_download_url":[[:space:]]*"/, "");
      gsub(/".*/, "");
      print;
      exit
    }'
}

download_maps() {
  if [[ "${NMS_SKIP_MAPS}" == "1" ]]; then
    warn "Skipping maps download — zones will not path correctly until maps are present"
    return 0
  fi
  if [[ -f "${NMS_INSTALL_DIR}/maps/package.json" ]]; then
    warn "Maps already present — skipping download"
    return 0
  fi
  log "Downloading maps from ${MAPS_URL}"
  local zipfile
  zipfile="$(mktemp /tmp/nms-maps-XXXXXX.zip)"
  http_get "${MAPS_URL}" "${zipfile}"
  log "Extracting maps into ${NMS_INSTALL_DIR}/maps"
  unzip -o -q "${zipfile}" -d "${NMS_INSTALL_DIR}/maps"
  rm -f "${zipfile}"
  ok "Maps installed"
}

download_spire() {
  log "Downloading latest Spire release"
  local api asset_url asset_name tmpdir archive bin_name
  api="$(http_get_stdout "https://api.github.com/repos/${SPIRE_REPO_OWNER}/${SPIRE_REPO_NAME}/releases/latest")"
  asset_name="spire-linux-amd64.zip"
  asset_url="$(spire_asset_url "${api}" "${asset_name}")"
  [[ -n "${asset_url}" ]] || die "Could not locate ${asset_name} on Spire releases"
  tmpdir="$(mktemp -d)"
  archive="${tmpdir}/${asset_name}"
  http_get "${asset_url}" "${archive}"
  unzip -o -q "${archive}" -d "${tmpdir}"
  bin_name="spire-linux-amd64"
  [[ -f "${tmpdir}/${bin_name}" ]] || die "Spire binary missing from release zip"
  cp -f "${tmpdir}/${bin_name}" "${NMS_INSTALL_DIR}/spire"
  chmod 755 "${NMS_INSTALL_DIR}/spire"
  rm -rf "${tmpdir}"
  ok "Spire installed to ${NMS_INSTALL_DIR}/spire"
}

init_spire() {
  log "Initializing Spire admin user (${NMS_SPIRE_USER})"
  (
    cd "${NMS_INSTALL_DIR}"
    ./spire spire:init "${NMS_SPIRE_USER}" "${NMS_SPIRE_PASSWORD}" \
      --compile-server=true \
      --compile-build-location="${SOURCE_DIR}/build" || warn "spire:init returned non-zero (may already be initialized)"
  )
}

write_helper_scripts() {
  log "Writing helper scripts"
  cat > "${NMS_INSTALL_DIR}/start" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
./spire eqemu-server:launcher start && echo "Server started"
EOF
  cat > "${NMS_INSTALL_DIR}/stop" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
./spire eqemu-server:launcher stop
echo "Server stopped"
EOF
  cat > "${NMS_INSTALL_DIR}/restart" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
./spire eqemu-server:launcher restart
echo "Server restarting"
EOF
  cat > "${NMS_INSTALL_DIR}/spire_start" <<EOF
#!/usr/bin/env bash
cd "\$(dirname "\$0")"
mkdir -p logs
if pgrep -f '[.]/spire\$|spire\$' >/dev/null 2>&1; then
  echo "Spire already running"
  exit 0
fi
nohup ./spire > logs/spire.log 2>&1 &
echo "Spire starting on http://127.0.0.1:${NMS_SPIRE_PORT}"
EOF
  cat > "${NMS_INSTALL_DIR}/spire_stop" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
pkill -f "[.]/spire$" 2>/dev/null || pkill -x spire 2>/dev/null || true
echo "Spire stop signal sent"
EOF
  cat > "${NMS_INSTALL_DIR}/spire_web" <<EOF
#!/usr/bin/env bash
url="http://127.0.0.1:${NMS_SPIRE_PORT}"
if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "\$url" >/dev/null 2>&1 || true
fi
echo "\$url"
EOF
  cat > "${NMS_INSTALL_DIR}/spire_web_admin" <<EOF
#!/usr/bin/env bash
url="http://127.0.0.1:${NMS_SPIRE_PORT}/admin"
if command -v xdg-open >/dev/null 2>&1; then
  xdg-open "\$url" >/dev/null 2>&1 || true
fi
echo "\$url"
EOF
  chmod 755 "${NMS_INSTALL_DIR}/"{start,stop,restart,spire_start,spire_stop,spire_web,spire_web_admin}
}

write_install_config() {
  cat > "${NMS_INSTALL_DIR}/install_config.yaml" <<EOF
# Generated by NMS install/linux/install.sh — keep this private.
server_path: "${NMS_INSTALL_DIR}"
code_path: "${SOURCE_DIR}"
mysql_host: "${NMS_DB_HOST}"
mysql_port: "${NMS_DB_PORT}"
mysql_database_name: "${NMS_DB_NAME}"
mysql_username: "${NMS_DB_USER}"
mysql_password: "${NMS_DB_PASSWORD}"
mysql_root_password: "${NMS_DB_ROOT_PASSWORD}"
spire_admin_user: "${NMS_SPIRE_USER}"
spire_admin_password: "${NMS_SPIRE_PASSWORD}"
spire_web_port: "${NMS_SPIRE_PORT}"
short_name: "${NMS_SHORT_NAME}"
long_name: "${NMS_LONG_NAME}"
public_address: "${NMS_PUBLIC_ADDRESS}"
local_address: "${NMS_LOCAL_ADDRESS}"
EOF
  chmod 600 "${NMS_INSTALL_DIR}/install_config.yaml"
}

maybe_install_cron() {
  if [[ "${NMS_INSTALL_CRON}" != "1" ]]; then
    return 0
  fi
  log "Installing @reboot Spire keepalive cron entry"
  local line
  line="@reboot while true; do nohup ${NMS_INSTALL_DIR}/spire > ${NMS_INSTALL_DIR}/logs/spire.log 2>&1; sleep 1; done &"
  (crontab -l 2>/dev/null | grep -vF "${NMS_INSTALL_DIR}/spire"; echo "${line}") | crontab -
}

warn_firewall() {
  warn "This is a headless-friendly install. There is no desktop browser here."
  warn "Game ports clients need: 5999 (login), 9000 (world), 7000-7400 (zones)."
  warn "Spire is an admin UI on port ${NMS_SPIRE_PORT} — do not expose it to the public internet."
}

finish_message() {
  cat <<EOF

${GRN}${BLD}Install complete.${RST}

Runtime folder:  ${NMS_INSTALL_DIR}
Credentials:     ${NMS_INSTALL_DIR}/install_config.yaml

On this machine (no GUI needed):
  cd ${NMS_INSTALL_DIR} && ./spire_start
  ./start

Spire admin (from any machine that can reach this host, or via SSH tunnel):
  ssh -N -L ${NMS_SPIRE_PORT}:127.0.0.1:${NMS_SPIRE_PORT} USER@THIS_HOST
  then open http://127.0.0.1:${NMS_SPIRE_PORT}/admin
  login: ${NMS_SPIRE_USER} / (see install_config.yaml)

  ./stop
  ./restart

Client notes:
  - Point eqhost.txt at your loginserver (port 5999 for RoF2)
  - Copy Release-NMS-Client/ClientFiles overlay onto your RoF2 client
  - After the DB is live, run:  ${NMS_INSTALL_DIR}/bin/export_client_files
    and copy spells_us.txt, dbstr_us.txt, SkillCaps.txt, BaseData.txt into the client

GM tip (after first login):
  UPDATE account SET status = 250 WHERE name = 'yourlogin';
EOF
}

main() {
  parse_args "$@"
  detect_os
  apply_headless_defaults
  require_repo_layout
  banner
  if [[ "${NMS_NONINTERACTIVE}" != "1" ]]; then
    confirm "Continue with installation?" "Y" || die "Aborted"
  fi
  gather_config
  [[ -n "${NMS_DB_PASSWORD}" ]] || die "Database password is required"
  [[ -n "${NMS_SPIRE_PASSWORD}" ]] || die "Spire password is required"

  install_deps
  configure_database
  build_server
  create_runtime_dirs
  install_binaries
  install_quests_and_plugins
  install_assets
  write_configs
  download_maps
  download_spire
  write_helper_scripts
  write_install_config
  init_spire
  maybe_install_cron
  warn_firewall
  finish_message
}

main "$@"
