#!/usr/bin/env bash
set -euo pipefail

# Nowhere 2.x VPS installer / manager
# Based on the V2-specific logic of chikacya/nowhere-sh.
# Old Nowhere V1 compatibility has intentionally been removed.

REPO="NodePassProject/Nowhere"
SERVICE_NAME="nowhere"
BIN_PATH="/usr/local/bin/nowhere"
CONFIG_DIR="/etc/nowhere"
CONFIG_FILE="${CONFIG_DIR}/nowhere.env"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

DEFAULT_VERSION="v2.0.0"
DEFAULT_PORT="2077"
DEFAULT_NET="mix"
DEFAULT_TLS="1"
DEFAULT_LOG="info"
DEFAULT_CLIENT="anywhere"
DEFAULT_TRANSPORT_MEMORY_PROFILE="throughput"
DEFAULT_MORPH="0"
DEFAULT_MIX_FALLBACK_TIMEOUT="1s"
DEFAULT_SOCKS="none"
DEFAULT_RATE="0"
DEFAULT_ETAR="0"
DEFAULT_DIAL="auto"
DEFAULT_TELEMETRY_INTERVAL="1s"
DEFAULT_VECTOR_MUX="0"
DEFAULT_VECTOR_SOCKS="127.0.0.1:1080"
DEFAULT_VECTOR_SNI="none"
DEFAULT_VECTOR_PIN="none"
DEFAULT_CRT_PATH="/etc/nowhere/tls/server.crt"
DEFAULT_TLS_KEY_PATH="/etc/nowhere/tls/server.key"

ASSUME_YES=0
VERSION_EXPLICIT=0
ACTION="${1:-menu}"
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    --port)
      NOWHERE_PORT="${2:?missing --port value}"
      shift 2
      ;;
    --tcp-port)
      NOWHERE_TCP_PORT="${2:?missing --tcp-port value}"
      shift 2
      ;;
    --udp-port)
      NOWHERE_UDP_PORT="${2:?missing --udp-port value}"
      shift 2
      ;;
    --key)
      NOWHERE_KEY="${2:?missing --key value}"
      shift 2
      ;;
    --client)
      NOWHERE_CLIENT="${2:?missing --client value}"
      shift 2
      ;;
    --version)
      NOWHERE_VERSION="${2:?missing --version value}"
      VERSION_EXPLICIT=1
      shift 2
      ;;
    --net)
      NOWHERE_NET="${2:?missing --net value}"
      shift 2
      ;;
    --tls)
      NOWHERE_TLS="${2:?missing --tls value}"
      shift 2
      ;;
    --crt|--cert)
      NOWHERE_CRT="${2:?missing --crt value}"
      shift 2
      ;;
    --tls-key)
      NOWHERE_TLS_KEY="${2:?missing --tls-key value}"
      shift 2
      ;;
    --public-host)
      NOWHERE_PUBLIC_HOST="${2:?missing --public-host value}"
      shift 2
      ;;
    --listen-host)
      NOWHERE_LISTEN_HOST="${2:?missing --listen-host value}"
      shift 2
      ;;
    --rate)
      NOWHERE_RATE="${2:?missing --rate value}"
      shift 2
      ;;
    --etar)
      NOWHERE_ETAR="${2:?missing --etar value}"
      shift 2
      ;;
    --dial)
      NOWHERE_DIAL="${2:?missing --dial value}"
      shift 2
      ;;
    --socks)
      NOWHERE_SOCKS="${2:?missing --socks value}"
      shift 2
      ;;
    --log)
      NOWHERE_LOG="${2:?missing --log value}"
      shift 2
      ;;
    --transport-memory-profile)
      NOWHERE_TRANSPORT_MEMORY_PROFILE="${2:?missing --transport-memory-profile value}"
      shift 2
      ;;
    --morph)
      NOWHERE_MORPH="${2:?missing --morph value}"
      shift 2
      ;;
    --mix-fallback-timeout)
      NOWHERE_MIX_FALLBACK_TIMEOUT="${2:?missing --mix-fallback-timeout value}"
      shift 2
      ;;
    --telemetry-interval)
      NOWHERE_TELEMETRY_INTERVAL="${2:?missing --telemetry-interval value}"
      shift 2
      ;;
    --mux)
      NOWHERE_VECTOR_MUX="${2:?missing --mux value}"
      shift 2
      ;;
    --vector-socks)
      NOWHERE_VECTOR_SOCKS="${2:?missing --vector-socks value}"
      shift 2
      ;;
    --sni)
      NOWHERE_VECTOR_SNI="${2:?missing --sni value}"
      shift 2
      ;;
    --pin)
      NOWHERE_VECTOR_PIN="${2:?missing --pin value}"
      shift 2
      ;;
    -h|--help)
      ACTION="help"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

info() { printf '\033[1;34m[Nowhere]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[Warn]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[Error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Nowhere 2.x VPS 一键部署与管理脚本。

Usage:
  sudo bash nowhere-vps-2.sh
  sudo bash nowhere-vps-2.sh install [--yes] [options]
  sudo bash nowhere-vps-2.sh configure [options]
  sudo bash nowhere-vps-2.sh update [--version v2.x.x]
  sudo bash nowhere-vps-2.sh versions
  sudo bash nowhere-vps-2.sh start|stop|restart|status|tui|logs|link
  sudo bash nowhere-vps-2.sh fingerprint
  sudo bash nowhere-vps-2.sh cert
  sudo bash nowhere-vps-2.sh uninstall

V2-only options:
  --version v2.0.0
  --port 2077
  --tcp-port 2077       Empty disables TCP carrier
  --udp-port 2077       Empty disables UDP carrier
  --key secret
  --client anywhere|vector|both
  --net mix|tcp|udp        V2 carrier selection convenience; not emitted as net= query
  --tls 1|2
  --crt /path/cert.pem   tls=2 已有 PEM 证书路径；留空则由 tls=2 流程申请正式证书
  --tls-key /path/key.pem
  --public-host host
  --listen-host host
  --rate 0
  --etar 0
  --dial auto
  --socks none|host:port|user:pass@host:port
  --log info
  --transport-memory-profile memory|balanced|throughput
  --morph 0|1
  --mix-fallback-timeout none|1s|...
  --telemetry-interval 1s
  --mux 0|1              Vector/Anywhere TLS Mux setting
  --vector-socks 127.0.0.1:1080
  --sni name|none
  --pin sha256|none

No V1 options are supported.
EOF
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行，例如：sudo bash $0 ${ACTION}"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "当前系统缺少 systemctl。"
  [[ -d /run/systemd/system ]] || warn "systemd 看起来未运行，服务管理命令可能失败。"
}

env_quote() {
  local value="${1//$'\n'/}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

urlencode() {
  local input="${1:-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$input"
  elif command -v python >/dev/null 2>&1; then
    python -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$input"
  elif [[ "$input" =~ ^[A-Za-z0-9._~-]*$ ]]; then
    printf '%s\n' "$input"
  else
    die "python3 is required to percent-encode reserved URL characters."
  fi
}

format_host_for_url() {
  local host="${1:-}"
  if [[ -z "$host" ]]; then
    printf ''
  elif [[ "$host" == \[*\] ]]; then
    printf '%s' "$host"
  elif [[ "$host" == *:* ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

strip_brackets() {
  local host="${1:-}"
  host="${host#[}"
  host="${host%]}"
  printf '%s' "$host"
}

display_empty() {
  local value="${1:-}"
  local fallback="${2:-<空>}"
  [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "$fallback"
}

display_socks() {
  local socks="${1:-none}"
  if [[ -z "$socks" || "$socks" == "none" ]]; then
    printf 'none'
  elif [[ "$socks" == *@* ]]; then
    printf '***@%s' "${socks##*@}"
  else
    printf '%s' "$socks"
  fi
}

mask_secret() {
  local value="${1:-}"
  local length="${#value}"
  if (( length <= 8 )); then
    printf '***'
  else
    printf '%s...%s' "${value:0:4}" "${value: -4}"
  fi
}

confirm_default_yes() {
  local prompt="$1" answer
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "${prompt} [Y/n]: " answer
  [[ -z "$answer" || "$answer" == "y" || "$answer" == "Y" ||
     "$answer" == "yes" || "$answer" == "YES" ]]
}

random_token() {
  local bytes="${1:-24}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 "$bytes" | tr '+/' '-_' | tr -d '='
  else
    LC_ALL=C tr -dc 'A-Za-z0-9._~-' </dev/urandom | head -c $((bytes * 2))
    printf '\n'
  fi
}

detect_public_host() {
  local detected=""
  if command -v curl >/dev/null 2>&1; then
    detected="$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "$detected" ]]; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s' "$detected"
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

read_value() {
  local prompt="$1" default="$2" var
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    printf '%s' "$default"
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " var
    printf '%s' "${var:-$default}"
  else
    read -r -p "${prompt}: " var
    printf '%s' "$var"
  fi
}

normalize_client() {
  case "${1:-}" in
    anywhere|vector|both) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

client_label() {
  case "${1:-anywhere}" in
    anywhere) printf 'Anywhere 2.0' ;;
    vector) printf 'Native Vector 2.0' ;;
    both) printf 'Anywhere 2.0 + Native Vector 2.0' ;;
    *) printf 'Unknown' ;;
  esac
}

validate_release_version() {
  [[ "${1:-}" =~ ^v2\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]]
}

require_supported_version() {
  validate_release_version "$1" || die "只允许安装 Nowhere 2.x Release：$1"
}

validate_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

validate_nonnegative_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

validate_morph() {
  [[ "${1:-}" == "0" || "${1:-}" == "1" ]]
}

validate_vector_mux() {
  [[ "${1:-}" == "0" || "${1:-}" == "1" ]]
}

validate_memory_profile() {
  [[ "${1:-}" == "memory" || "${1:-}" == "balanced" || "${1:-}" == "throughput" ]]
}

validate_duration_or_none() {
  [[ "${1:-}" == "none" || "${1:-}" =~ ^[0-9]+(ms|s|m|h)$ ]]
}

validate_telemetry_interval() {
  local value="${1:-}" amount
  if [[ "$value" =~ ^([0-9]+)ms$ ]]; then
    amount="${BASH_REMATCH[1]}"
    (( 10#$amount >= 250 && 10#$amount <= 60000 ))
  elif [[ "$value" =~ ^([0-9]+)s$ ]]; then
    amount="${BASH_REMATCH[1]}"
    (( 10#$amount >= 1 && 10#$amount <= 60 ))
  else
    return 1
  fi
}

validate_socks() {
  local socks="${1:-}" endpoint userinfo host port
  [[ -z "$socks" || "$socks" == "none" ]] && return 0
  [[ "$socks" != *[[:space:]]* ]] || return 1
  endpoint="$socks"
  if [[ "$endpoint" == *@* ]]; then
    userinfo="${endpoint%@*}"
    endpoint="${endpoint##*@}"
    [[ "$userinfo" == *:* ]] || return 1
    [[ -n "${userinfo%%:*}" && -n "${userinfo#*:}" ]] || return 1
    [[ "${#userinfo}" -le 511 ]] || return 1
  fi
  if [[ "$endpoint" == \[*\]:* ]]; then
    host="${endpoint#\[}"
    host="${host%%\]:*}"
    port="${endpoint##*\]:}"
  else
    [[ "$endpoint" != *:*:* ]] || return 1
    host="${endpoint%:*}"
    port="${endpoint##*:}"
  fi
  [[ -n "$host" ]] || return 1
  validate_port "$port"
}

validate_vector_socks() {
  local socks="${1:-}" endpoint host port
  [[ -n "$socks" && "$socks" != "none" ]] || return 1
  [[ "$socks" != *[[:space:]]* ]] || return 1
  endpoint="${socks##*@}"
  if [[ "$endpoint" == \[*\]:* ]]; then
    host="${endpoint#\[}"
    host="${host%%\]:*}"
    port="${endpoint##*\]:}"
    [[ -n "$host" ]] || return 1
  else
    [[ "$endpoint" != *:*:* ]] || return 1
    host="${endpoint%:*}"
    port="${endpoint##*:}"
  fi
  validate_port "$port"
}


acme_sh_path() {
  local candidate
  candidate="/root/.acme.sh/acme.sh"
  if [[ -x "$candidate" ]]; then
    printf '%s' "$candidate"
    return 0
  fi

  candidate="$(command -v acme.sh 2>/dev/null || true)"
  [[ -x "$candidate" ]] || return 1
  printf '%s' "$candidate"
}

install_acme_sh() {
  local acme_bin tmp_installer

  if acme_bin="$(acme_sh_path)"; then
    printf '%s' "$acme_bin"
    return 0
  fi

  command -v curl >/dev/null 2>&1 || die "申请 tls=2 正式证书需要 curl。"

  tmp_installer="$(mktemp)"
  trap 'rm -f "${tmp_installer:-}"' RETURN

  info "系统未检测到 acme.sh，正在安装（不设置邮箱）..."
  curl -fsSL --retry 3 --connect-timeout 10 \
    -o "$tmp_installer" https://get.acme.sh
  sh "$tmp_installer" >/dev/null

  rm -f "$tmp_installer"
  trap - RETURN

  acme_bin="$(acme_sh_path)" || die "acme.sh 安装失败。"
  printf '%s' "$acme_bin"
}

validate_certificate_domain() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || die "tls=2 必须提供证书域名。"
  [[ "$domain" != *[[:space:]]* ]] || die "证书域名不能包含空格。"
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die "证书域名格式无效：$domain"
  [[ "$domain" == *.* ]] || die "证书域名必须是完整域名，例如 nowhere.example.com。"
  [[ "$domain" != .* && "$domain" != *. ]] || die "证书域名格式无效：$domain"
}

find_existing_acme_certificate() {
  local domain="${1:-}"
  local acme_home="/root/.acme.sh"
  local cert dir base main_domain key_path

  [[ -d "$acme_home" ]] || return 1
  command -v openssl >/dev/null 2>&1 || return 1

  while IFS= read -r cert; do
    [[ -f "$cert" ]] || continue
    dir="$(dirname "$cert")"
    base="$(basename "$dir")"
    main_domain="${base%_ecc}"
    [[ -n "$main_domain" ]] || continue

    # 必须同时满足：证书当前未过期，且 SAN/CN 实际包含目标域名。
    if ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then
      continue
    fi
    if ! openssl x509 -in "$cert" -noout -checkhost "$domain" 2>/dev/null | grep -q 'does match'; then
      continue
    fi

    key_path="$dir/${main_domain}.key"
    [[ -f "$key_path" ]] || continue

    printf '%s\n' "$main_domain" "$cert" "$key_path"
    return 0
  done < <(find "$acme_home" -mindepth 2 -maxdepth 2 -type f -name 'fullchain.cer' -print 2>/dev/null)

  return 1
}

install_acme_certificate() {
  local acme_bin="$1"
  local main_domain="$2"
  local cert_path="$3"
  local key_path="$4"

  install -d -m 700 "$(dirname "$cert_path")"

  if ! "$acme_bin" --install-cert -d "$main_domain" \
      --key-file "$key_path" \
      --fullchain-file "$cert_path" \
      --reloadcmd "systemctl restart $SERVICE_NAME 2>/dev/null || true"; then
    die "证书已存在/申请成功，但安装到 Nowhere 证书路径失败。"
  fi

  chmod 644 "$cert_path"
  chmod 600 "$key_path"
}

issue_letsencrypt_cert() {
  local domain="${1:-}"
  local cert_path="${2:-$DEFAULT_CRT_PATH}"
  local key_path="${3:-$DEFAULT_TLS_KEY_PATH}"
  local acme_bin tls_dir found main_domain existing_cert

  require_root
  validate_certificate_domain "$domain"
  tls_dir="$(dirname "$cert_path")"
  install -d -m 700 "$tls_dir"

  if ! acme_bin="$(install_acme_sh)"; then
    die "无法安装或找到 acme.sh。"
  fi

  info "设置 Let's Encrypt 为 ACME CA..."
  if ! "$acme_bin" --set-default-ca --server letsencrypt >/dev/null 2>&1; then
    die "无法将 acme.sh 的默认 ACME CA 设置为 Let's Encrypt。"
  fi

  # 优先复用 acme.sh 已经为该域名保存的、当前有效的正式证书。
  if found="$(find_existing_acme_certificate "$domain")"; then
    main_domain="$(printf '%s\n' "$found" | sed -n '1p')"
    existing_cert="$(printf '%s\n' "$found" | sed -n '2p')"
    info "检测到该域名已有有效的 ACME 正式证书，直接复用。"
    info "证书：$existing_cert"
    info "主域名：$main_domain"
    install_acme_certificate "$acme_bin" "$main_domain" "$cert_path" "$key_path"
  else
    if command -v ss >/dev/null 2>&1 && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)80$'; then
      die "未找到可复用的有效证书，且 TCP 80 端口已被占用。Let's Encrypt 的 HTTP-01 验证需要使用 80 端口，请先释放该端口。"
    fi

    info "未检测到该域名的有效 ACME 证书，开始申请 Let's Encrypt 正式证书：$domain"
    if ! "$acme_bin" --issue \
        --server letsencrypt \
        --standalone \
        --keylength 2048 \
        -d "$domain"; then
      die "Let's Encrypt 证书申请失败。请确认域名 A/AAAA 记录已指向本机，并且公网 TCP 80 可访问。"
    fi

    main_domain="$domain"
    install_acme_certificate "$acme_bin" "$main_domain" "$cert_path" "$key_path"
  fi

  NOWHERE_CRT="$cert_path"
  NOWHERE_TLS_KEY="$key_path"
  NOWHERE_CRT_VALUE="$cert_path"
  NOWHERE_TLS_KEY_VALUE="$key_path"
  NOWHERE_TLS=2
  NOWHERE_TLS_VALUE=2

  info "Let's Encrypt 正式证书已安装：$cert_path"
  info "私钥已安装：$key_path"
}

validate_config_values() {
  [[ -n "${NOWHERE_KEY:-}" ]] || die "Shared Key 不能为空。"
  [[ "${#NOWHERE_KEY}" -le 255 ]] || die "Shared Key 长度不能超过 255。"

  require_supported_version "$NOWHERE_VERSION"

  [[ "${NOWHERE_NET:-}" == "mix" || "${NOWHERE_NET:-}" == "tcp" || "${NOWHERE_NET:-}" == "udp" ]] ||
    die "NOWHERE_NET 必须为 mix、tcp 或 udp。"

  [[ -n "${NOWHERE_TCP_PORT:-}" || -n "${NOWHERE_UDP_PORT:-}" ]] ||
    die "至少需要启用 TCP 或 UDP carrier。"

  [[ -z "${NOWHERE_TCP_PORT:-}" ]] || validate_port "$NOWHERE_TCP_PORT" ||
    die "V2 TCP 端口无效：${NOWHERE_TCP_PORT:-}"
  [[ -z "${NOWHERE_UDP_PORT:-}" ]] || validate_port "$NOWHERE_UDP_PORT" ||
    die "V2 UDP 端口无效：${NOWHERE_UDP_PORT:-}"

  [[ "${NOWHERE_TLS:-}" == "1" || "${NOWHERE_TLS:-}" == "2" ]] ||
    die "TLS 必须为 1 或 2。"

  validate_morph "${NOWHERE_MORPH:-}" ||
    die "Morph 必须为 0 或 1。"

  validate_memory_profile "${NOWHERE_TRANSPORT_MEMORY_PROFILE:-}" ||
    die "Transport Memory Profile 必须为 memory、balanced 或 throughput。"

  validate_duration_or_none "${NOWHERE_MIX_FALLBACK_TIMEOUT:-}" ||
    die "Mix Fallback Timeout 无效。"

  validate_nonnegative_int "${NOWHERE_RATE:-}" ||
    die "Rate 必须为非负整数。"
  validate_nonnegative_int "${NOWHERE_ETAR:-}" ||
    die "Etar 必须为非负整数。"

  validate_socks "${NOWHERE_SOCKS:-}" ||
    die "SOCKS5 出站配置无效。"

  [[ "${NOWHERE_LOG:-}" == "none" || "${NOWHERE_LOG:-}" == "debug" ||
     "${NOWHERE_LOG:-}" == "info" || "${NOWHERE_LOG:-}" == "warn" ||
     "${NOWHERE_LOG:-}" == "error" || "${NOWHERE_LOG:-}" == "event" ]] ||
    die "日志级别无效。"

  validate_telemetry_interval "${NOWHERE_TELEMETRY_INTERVAL:-}" ||
    die "TUI 遥测间隔必须为 250ms..60000ms 或 1s..60s。"

  NOWHERE_CLIENT="$(normalize_client "$NOWHERE_CLIENT")" ||
    die "客户端必须为 anywhere、vector 或 both。"

  validate_vector_mux "${NOWHERE_VECTOR_MUX:-}" ||
    die "Mux 必须为 0 或 1。"

  if [[ "$NOWHERE_CLIENT" == "vector" || "$NOWHERE_CLIENT" == "both" ]]; then
    validate_vector_socks "${NOWHERE_VECTOR_SOCKS:-}" ||
      die "Vector SOCKS5 地址无效。"
    [[ "${NOWHERE_VECTOR_SNI:-}" == "none" ||
       "${NOWHERE_VECTOR_SNI:-}" =~ ^[A-Za-z0-9.-]+$ ]] ||
      die "Vector SNI 无效。"
    [[ "${NOWHERE_VECTOR_PIN:-}" == "none" ||
       "${NOWHERE_VECTOR_PIN:-}" =~ ^[0-9a-f]{64}$ ]] ||
      die "Vector Pin 必须为 none 或 64 位小写十六进制。"
  fi

  if [[ "$NOWHERE_TLS" == "2" ]]; then
    [[ -n "${NOWHERE_CRT:-}" && -n "${NOWHERE_TLS_KEY:-}" ]] ||
      die "tls=2 需要 Let's Encrypt 正式证书，或通过 --crt/--tls-key 提供已有 PEM 证书。"
    [[ -f "$NOWHERE_CRT" ]] || die "证书文件不存在：$NOWHERE_CRT"
    [[ -f "$NOWHERE_TLS_KEY" ]] || die "私钥文件不存在：$NOWHERE_TLS_KEY"
  fi
}

build_endpoint() {
  local host="$1" tcp_port="${2:-}" udp_port="${3:-}"
  if [[ -n "$tcp_port" && -n "$udp_port" && "$tcp_port" == "$udp_port" ]]; then
    printf '%s:%s' "$host" "$tcp_port"
  elif [[ -n "$tcp_port" && -n "$udp_port" ]]; then
    printf '%s/tcp:%s/udp:%s' "$host" "$tcp_port" "$udp_port"
  elif [[ -n "$tcp_port" ]]; then
    printf '%s/tcp:%s' "$host" "$tcp_port"
  else
    printf '%s/udp:%s' "$host" "$udp_port"
  fi
}

build_portal_url() {
  local encoded_key host_part query
  encoded_key="$(urlencode "$NOWHERE_KEY")"
  host_part="$(format_host_for_url "${NOWHERE_LISTEN_HOST:-}")"
  [[ -n "$host_part" ]] || host_part="*"

  query="tls=${NOWHERE_TLS}&morph=${NOWHERE_MORPH}"

  if [[ -n "$NOWHERE_DIAL" && "$NOWHERE_DIAL" != "auto" ]]; then
    query="${query}&dial=$(urlencode "$NOWHERE_DIAL")"
  fi
  if [[ -n "$NOWHERE_SOCKS" && "$NOWHERE_SOCKS" != "$DEFAULT_SOCKS" ]]; then
    query="${query}&socks=$(urlencode "$NOWHERE_SOCKS")"
  fi
  if [[ "$NOWHERE_RATE" != "0" ]]; then
    query="${query}&rate=${NOWHERE_RATE}"
  fi
  if [[ "$NOWHERE_ETAR" != "0" ]]; then
    query="${query}&etar=${NOWHERE_ETAR}"
  fi
  if [[ "$NOWHERE_TLS" == "2" ]]; then
    query="${query}&crt=$(urlencode "$NOWHERE_CRT")&key=$(urlencode "$NOWHERE_TLS_KEY")"
  fi
  if [[ "$NOWHERE_LOG" != "$DEFAULT_LOG" ]]; then
    query="${query}&log=${NOWHERE_LOG}"
  fi

  printf 'portal://%s@%s?%s' "$encoded_key" \
    "$(build_endpoint "$host_part" "${NOWHERE_TCP_PORT:-}" "${NOWHERE_UDP_PORT:-}")" \
    "$query"
}

build_anywhere_client_query() {
  local up="$1" down="$2"
  printf 'up=%s&down=%s&morph=%s&mux=%s' \
    "$up" "$down" "$NOWHERE_MORPH" "$NOWHERE_VECTOR_MUX"
}

build_vector_query() {
  local up="$1" down="$2"
  local query="up=${up}&down=${down}"
  query="${query}&morph=${NOWHERE_MORPH}"
  query="${query}&mux=${NOWHERE_VECTOR_MUX}"
  query="${query}&sni=$(urlencode "${NOWHERE_VECTOR_SNI:-none}")"
  query="${query}&pin=$(urlencode "${NOWHERE_VECTOR_PIN:-none}")"
  query="${query}&socks=$(urlencode "${NOWHERE_VECTOR_SOCKS:-127.0.0.1:1080}")"
  printf '%s' "$query"
}

print_config_summary() {
  echo
  echo "配置确认："
  echo "  客户端输出:          $(client_label "${NOWHERE_CLIENT:-anywhere}")"
  echo "  Release:             ${NOWHERE_VERSION:-}"
  echo "  公网域名/IP:         $(display_empty "${NOWHERE_PUBLIC_HOST:-}" "<自动探测失败>")"
  echo "  监听地址:            $(display_empty "${NOWHERE_LISTEN_HOST:-}" "<空，IPv4/IPv6 wildcard>")"
  echo "  V2 Carrier 模式:     ${NOWHERE_NET:-mix}"
  echo "  V2 TCP / UDP 端口:   ${NOWHERE_TCP_PORT:-<关闭>} / ${NOWHERE_UDP_PORT:-<关闭>}"
  echo "  Shared Key:          $(mask_secret "${NOWHERE_KEY:-}")"
  echo "  TLS:                 ${NOWHERE_TLS:-1}"
  if [[ "${NOWHERE_TLS:-1}" == "2" ]]; then
    echo "  证书链:              ${NOWHERE_CRT:-}"
    echo "  私钥:                ${NOWHERE_TLS_KEY:-}"
  fi
  echo "  Morph:               ${NOWHERE_MORPH:-$DEFAULT_MORPH}"
  echo "  Transport Memory:    ${NOWHERE_TRANSPORT_MEMORY_PROFILE:-$DEFAULT_TRANSPORT_MEMORY_PROFILE}"
  echo "  Mix Fallback:        ${NOWHERE_MIX_FALLBACK_TIMEOUT:-$DEFAULT_MIX_FALLBACK_TIMEOUT}"
  echo "  Rate / Etar:         ${NOWHERE_RATE:-0} / ${NOWHERE_ETAR:-0} Mbps"
  echo "  Dial:                ${NOWHERE_DIAL:-auto}"
  echo "  SOCKS5 出站:         $(display_socks "${NOWHERE_SOCKS:-none}")"
  echo "  Log:                 ${NOWHERE_LOG:-info}"
  echo "  TUI 遥测间隔:        ${NOWHERE_TELEMETRY_INTERVAL:-1s}"
  echo "  Vector Mux:          ${NOWHERE_VECTOR_MUX:-0}"
  if [[ "${NOWHERE_CLIENT:-anywhere}" == "vector" || "${NOWHERE_CLIENT:-anywhere}" == "both" ]]; then
    echo "  Vector SOCKS5:       ${NOWHERE_VECTOR_SOCKS:-}"
    echo "  Vector SNI:          ${NOWHERE_VECTOR_SNI:-none}"
    echo "  Vector Pin:          ${NOWHERE_VECTOR_PIN:-none}"
  fi
}

configure_values() {
  load_config

  local generated_key detected_host default_tls saved_client
  generated_key="$(random_token 24)"
  detected_host="$(detect_public_host)"

  NOWHERE_VERSION="${NOWHERE_VERSION:-${NOWHERE_VERSION_VALUE:-$DEFAULT_VERSION}}"
  require_supported_version "$NOWHERE_VERSION"

  saved_client="${NOWHERE_CLIENT_VALUE:-$DEFAULT_CLIENT}"
  NOWHERE_CLIENT="$(normalize_client "${NOWHERE_CLIENT:-$saved_client}")" ||
    die "NOWHERE_CLIENT 无效。"

  NOWHERE_PORT="${NOWHERE_PORT:-${NOWHERE_PORT_VALUE:-$DEFAULT_PORT}}"
  NOWHERE_TCP_PORT="${NOWHERE_TCP_PORT:-${NOWHERE_TCP_PORT_VALUE:-}}"
  NOWHERE_UDP_PORT="${NOWHERE_UDP_PORT:-${NOWHERE_UDP_PORT_VALUE:-}}"
  NOWHERE_KEY="${NOWHERE_KEY:-${NOWHERE_KEY_VALUE:-$generated_key}}"
  NOWHERE_NET="${NOWHERE_NET:-${NOWHERE_NET_VALUE:-$DEFAULT_NET}}"
  NOWHERE_RATE="${NOWHERE_RATE:-${NOWHERE_RATE_VALUE:-$DEFAULT_RATE}}"
  NOWHERE_ETAR="${NOWHERE_ETAR:-${NOWHERE_ETAR_VALUE:-$DEFAULT_ETAR}}"
  NOWHERE_DIAL="${NOWHERE_DIAL:-${NOWHERE_DIAL_VALUE:-$DEFAULT_DIAL}}"
  NOWHERE_SOCKS="${NOWHERE_SOCKS:-${NOWHERE_SOCKS_VALUE:-$DEFAULT_SOCKS}}"
  NOWHERE_LOG="${NOWHERE_LOG:-${NOWHERE_LOG_VALUE:-$DEFAULT_LOG}}"
  NOWHERE_TELEMETRY_INTERVAL="${NOWHERE_TELEMETRY_INTERVAL:-${NOWHERE_TELEMETRY_INTERVAL_VALUE:-$DEFAULT_TELEMETRY_INTERVAL}}"
  NOWHERE_VECTOR_MUX="${NOWHERE_VECTOR_MUX:-${NOWHERE_VECTOR_MUX_VALUE:-$DEFAULT_VECTOR_MUX}}"
  NOWHERE_VECTOR_SOCKS="${NOWHERE_VECTOR_SOCKS:-${NOWHERE_VECTOR_SOCKS_VALUE:-$DEFAULT_VECTOR_SOCKS}}"
  NOWHERE_VECTOR_SNI="${NOWHERE_VECTOR_SNI:-${NOWHERE_VECTOR_SNI_VALUE:-$DEFAULT_VECTOR_SNI}}"
  NOWHERE_VECTOR_PIN="${NOWHERE_VECTOR_PIN:-${NOWHERE_VECTOR_PIN_VALUE:-$DEFAULT_VECTOR_PIN}}"
  NOWHERE_TRANSPORT_MEMORY_PROFILE="${NOWHERE_TRANSPORT_MEMORY_PROFILE:-${NOWHERE_TRANSPORT_MEMORY_PROFILE_VALUE:-$DEFAULT_TRANSPORT_MEMORY_PROFILE}}"
  NOWHERE_MORPH="${NOWHERE_MORPH:-${NOWHERE_MORPH_VALUE:-$DEFAULT_MORPH}}"
  NOWHERE_MIX_FALLBACK_TIMEOUT="${NOWHERE_MIX_FALLBACK_TIMEOUT:-${NOWHERE_MIX_FALLBACK_TIMEOUT_VALUE:-$DEFAULT_MIX_FALLBACK_TIMEOUT}}"
  NOWHERE_PUBLIC_HOST="${NOWHERE_PUBLIC_HOST:-${NOWHERE_PUBLIC_HOST_VALUE:-$detected_host}}"
  NOWHERE_LISTEN_HOST="${NOWHERE_LISTEN_HOST:-${NOWHERE_LISTEN_HOST_VALUE:-}}"
  NOWHERE_CRT="${NOWHERE_CRT:-${NOWHERE_CRT_VALUE:-}}"
  NOWHERE_TLS_KEY="${NOWHERE_TLS_KEY:-${NOWHERE_TLS_KEY_VALUE:-}}"

  default_tls="$DEFAULT_TLS"
  if [[ -n "$NOWHERE_CRT" || -n "$NOWHERE_TLS_KEY" ]]; then
    default_tls="2"
  fi
  NOWHERE_TLS="${NOWHERE_TLS:-${NOWHERE_TLS_VALUE:-$default_tls}}"

  case "$NOWHERE_NET" in
    mix)
      NOWHERE_TCP_PORT="${NOWHERE_TCP_PORT:-$NOWHERE_PORT}"
      NOWHERE_UDP_PORT="${NOWHERE_UDP_PORT:-$NOWHERE_PORT}"
      ;;
    tcp)
      NOWHERE_TCP_PORT="${NOWHERE_TCP_PORT:-$NOWHERE_PORT}"
      NOWHERE_UDP_PORT=""
      ;;
    udp)
      NOWHERE_TCP_PORT=""
      NOWHERE_UDP_PORT="${NOWHERE_UDP_PORT:-$NOWHERE_PORT}"
      ;;
  esac

  if [[ "$ASSUME_YES" -eq 0 ]]; then
    info "进入 Nowhere 2.x 配置向导：一路回车即可使用默认值。"
    NOWHERE_CLIENT="$(read_value "客户端 anywhere/vector/both" "$NOWHERE_CLIENT")"
    NOWHERE_PUBLIC_HOST="$(read_value "公网域名/IP" "$NOWHERE_PUBLIC_HOST")"
    NOWHERE_LISTEN_HOST="$(read_value "监听地址，留空表示 wildcard" "$NOWHERE_LISTEN_HOST")"
    NOWHERE_PORT="$(read_value "默认 carrier 端口" "$NOWHERE_PORT")"
    NOWHERE_KEY="$(read_value "Shared Key" "$NOWHERE_KEY")"
    NOWHERE_NET="$(read_value "监听模式 mix/tcp/udp" "$NOWHERE_NET")"

    case "$NOWHERE_NET" in
      mix)
        NOWHERE_TCP_PORT="$(read_value "V2 TCP carrier 端口" "${NOWHERE_TCP_PORT:-$NOWHERE_PORT}")"
        NOWHERE_UDP_PORT="$(read_value "V2 UDP carrier 端口" "${NOWHERE_UDP_PORT:-$NOWHERE_PORT}")"
        ;;
      tcp)
        NOWHERE_TCP_PORT="$(read_value "V2 TCP carrier 端口" "${NOWHERE_TCP_PORT:-$NOWHERE_PORT}")"
        NOWHERE_UDP_PORT=""
        ;;
      udp)
        NOWHERE_TCP_PORT=""
        NOWHERE_UDP_PORT="$(read_value "V2 UDP carrier 端口" "${NOWHERE_UDP_PORT:-$NOWHERE_PORT}")"
        ;;
    esac

    NOWHERE_MORPH="$(read_value "V2 Morph 0=关闭，1=开启" "$NOWHERE_MORPH")"
    NOWHERE_TRANSPORT_MEMORY_PROFILE="$(read_value "V2 传输内存策略 memory/balanced/throughput" "$NOWHERE_TRANSPORT_MEMORY_PROFILE")"
    NOWHERE_MIX_FALLBACK_TIMEOUT="$(read_value "V2 mix 回退延迟，none=使用官方默认 1s" "$NOWHERE_MIX_FALLBACK_TIMEOUT")"
    NOWHERE_TLS="$(read_value "TLS 模式 1=Nowhere 自签，2=Let's Encrypt 正式证书" "$NOWHERE_TLS")"

    if [[ "$NOWHERE_TLS" == "2" ]]; then
      if [[ -z "$NOWHERE_CRT" && -z "$NOWHERE_TLS_KEY" ]]; then
        NOWHERE_CRT="$DEFAULT_CRT_PATH"
        NOWHERE_TLS_KEY="$DEFAULT_TLS_KEY_PATH"
        NOWHERE_PUBLIC_HOST="$(read_value "证书域名" "$NOWHERE_PUBLIC_HOST")"
        issue_letsencrypt_cert "$NOWHERE_PUBLIC_HOST" "$NOWHERE_CRT" "$NOWHERE_TLS_KEY"
      else
        NOWHERE_CRT="$(read_value "证书链路径" "$NOWHERE_CRT")"
        NOWHERE_TLS_KEY="$(read_value "私钥路径" "$NOWHERE_TLS_KEY")"
      fi
    fi

    NOWHERE_RATE="$(read_value "上行限速 Mbps，0=不限" "$NOWHERE_RATE")"
    NOWHERE_ETAR="$(read_value "下行限速 Mbps，0=不限" "$NOWHERE_ETAR")"
    NOWHERE_DIAL="$(read_value "出站源 IP，auto=系统默认" "$NOWHERE_DIAL")"
    NOWHERE_SOCKS="$(read_value "SOCKS5 出站，none=关闭" "$NOWHERE_SOCKS")"
    NOWHERE_LOG="$(read_value "日志级别 none/debug/info/warn/error/event" "$NOWHERE_LOG")"
    NOWHERE_TELEMETRY_INTERVAL="$(read_value "TUI 遥测刷新间隔" "$NOWHERE_TELEMETRY_INTERVAL")"

    if [[ "$NOWHERE_CLIENT" == "vector" || "$NOWHERE_CLIENT" == "both" ]]; then
      NOWHERE_VECTOR_MUX="$(read_value "Vector Mux 0=专用连接，1=共享 Mux" "$NOWHERE_VECTOR_MUX")"
      NOWHERE_VECTOR_SOCKS="$(read_value "Vector 本地 SOCKS5 监听地址" "$NOWHERE_VECTOR_SOCKS")"
      NOWHERE_VECTOR_SNI="$(read_value "Vector SNI，none=不校验证书" "$NOWHERE_VECTOR_SNI")"
      NOWHERE_VECTOR_PIN="$(read_value "Vector 证书 SHA-256 pin，none=不固定" "$NOWHERE_VECTOR_PIN")"
    fi
  fi

  if [[ "$NOWHERE_TLS" == "2" && -z "${NOWHERE_CRT:-}" && -z "${NOWHERE_TLS_KEY:-}" ]]; then
    NOWHERE_CRT="$DEFAULT_CRT_PATH"
    NOWHERE_TLS_KEY="$DEFAULT_TLS_KEY_PATH"
    issue_letsencrypt_cert "$NOWHERE_PUBLIC_HOST" "$NOWHERE_CRT" "$NOWHERE_TLS_KEY"
  fi

  validate_config_values
  NOWHERE_PORTAL="$(build_portal_url)"

  if [[ "$ASSUME_YES" -eq 0 ]]; then
    print_config_summary
    confirm_default_yes "确认保存并应用以上配置吗？" || die "已取消配置。"
  fi
}

save_config() {
  install -d -m 700 "$CONFIG_DIR"

  cat >"$CONFIG_FILE" <<EOF
NOWHERE_PORTAL=$(env_quote "$NOWHERE_PORTAL")
NOWHERE_CLIENT_VALUE=$(env_quote "$NOWHERE_CLIENT")
NOWHERE_VERSION_VALUE=$(env_quote "$NOWHERE_VERSION")
NOWHERE_PUBLIC_HOST_VALUE=$(env_quote "$NOWHERE_PUBLIC_HOST")
NOWHERE_LISTEN_HOST_VALUE=$(env_quote "$NOWHERE_LISTEN_HOST")
NOWHERE_PORT_VALUE=$(env_quote "$NOWHERE_PORT")
NOWHERE_TCP_PORT_VALUE=$(env_quote "${NOWHERE_TCP_PORT:-}")
NOWHERE_UDP_PORT_VALUE=$(env_quote "${NOWHERE_UDP_PORT:-}")
NOWHERE_KEY_VALUE=$(env_quote "$NOWHERE_KEY")
NOWHERE_NET_VALUE=$(env_quote "$NOWHERE_NET")
NOWHERE_TLS_VALUE=$(env_quote "$NOWHERE_TLS")
NOWHERE_CRT_VALUE=$(env_quote "$NOWHERE_CRT")
NOWHERE_TLS_KEY_VALUE=$(env_quote "$NOWHERE_TLS_KEY")
NOWHERE_RATE_VALUE=$(env_quote "$NOWHERE_RATE")
NOWHERE_ETAR_VALUE=$(env_quote "$NOWHERE_ETAR")
NOWHERE_DIAL_VALUE=$(env_quote "$NOWHERE_DIAL")
NOWHERE_SOCKS_VALUE=$(env_quote "$NOWHERE_SOCKS")
NOWHERE_LOG_VALUE=$(env_quote "$NOWHERE_LOG")
NOWHERE_TELEMETRY_INTERVAL_VALUE=$(env_quote "$NOWHERE_TELEMETRY_INTERVAL")
NOWHERE_TRANSPORT_MEMORY_PROFILE_VALUE=$(env_quote "$NOWHERE_TRANSPORT_MEMORY_PROFILE")
NOW_TRANSPORT_MEMORY_PROFILE=$(env_quote "$NOWHERE_TRANSPORT_MEMORY_PROFILE")
NOWHERE_MORPH_VALUE=$(env_quote "$NOWHERE_MORPH")
NOWHERE_VECTOR_MUX_VALUE=$(env_quote "$NOWHERE_VECTOR_MUX")
NOWHERE_VECTOR_SOCKS_VALUE=$(env_quote "$NOWHERE_VECTOR_SOCKS")
NOWHERE_VECTOR_SNI_VALUE=$(env_quote "$NOWHERE_VECTOR_SNI")
NOWHERE_VECTOR_PIN_VALUE=$(env_quote "$NOWHERE_VECTOR_PIN")
EOF

  if [[ "$NOWHERE_MIX_FALLBACK_TIMEOUT" != "none" ]]; then
    printf 'NOWHERE_MIX_FALLBACK_TIMEOUT_VALUE=%s\n' \
      "$(env_quote "$NOWHERE_MIX_FALLBACK_TIMEOUT")" >>"$CONFIG_FILE"
    printf 'NOW_MIX_FALLBACK_TIMEOUT=%s\n' \
      "$(env_quote "$NOWHERE_MIX_FALLBACK_TIMEOUT")" >>"$CONFIG_FILE"
  else
    printf 'unset NOWHERE_MIX_FALLBACK_TIMEOUT_VALUE NOW_MIX_FALLBACK_TIMEOUT\n' >>"$CONFIG_FILE"
  fi

  chmod 600 "$CONFIG_FILE"
  info "Config saved to ${CONFIG_FILE}"
}

detect_asset() {
  local arch libc
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac

  local target
  libc="gnu"
  if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
    libc="musl"
  fi

  target="${arch}-unknown-linux-${libc}"
  printf 'nowhere-%s.tar.gz' "$target"
}

install_binary() {
  command -v curl >/dev/null 2>&1 || die "curl is required."
  command -v tar >/dev/null 2>&1 || die "tar is required."

  local version="${1:-${NOWHERE_VERSION:-}}"
  local asset url tmpdir binary

  require_supported_version "$version"
  asset="$(detect_asset)"
  url="https://github.com/${REPO}/releases/download/${version}/${asset}"
  tmpdir="$(mktemp -d)"

  trap 'rm -rf "${tmpdir:-}"' RETURN

  info "Downloading ${asset} from ${REPO} ${version}..."
  curl -fL --retry 3 --connect-timeout 10 \
    -o "${tmpdir}/${asset}" "$url"

  [[ -s "${tmpdir}/${asset}" ]] || die "Downloaded archive is empty."
  tar -xzf "${tmpdir}/${asset}" -C "$tmpdir"

  binary="$(find "$tmpdir" -type f -name nowhere -perm -u+x | head -n 1)"
  [[ -n "$binary" ]] || binary="$(find "$tmpdir" -type f -name nowhere | head -n 1)"
  [[ -n "$binary" ]] || die "Could not find nowhere binary in release archive."

  install -m 755 "$binary" "$BIN_PATH"
  rm -rf "$tmpdir"
  trap - RETURN

  info "Installed ${BIN_PATH} (${version})"
}

write_service() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Nowhere 2.x Portal
Documentation=https://github.com/${REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CONFIG_FILE}
ExecStart=${BIN_PATH} \${NOWHERE_PORTAL}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "$SERVICE_FILE"
  systemctl daemon-reload
  info "systemd service written to ${SERVICE_FILE}"
}


local_tls_probe_host() {
  local host="${NOWHERE_LISTEN_HOST_VALUE:-}"
  if [[ -z "$host" || "$host" == "0.0.0.0" || "$host" == "::" || "$host" == "[::]" ]]; then
    printf '127.0.0.1'
  else
    strip_brackets "$host"
  fi
}

print_tls_fingerprint_from_tcp() {
  command -v openssl >/dev/null 2>&1 || return 1
  command -v timeout >/dev/null 2>&1 || return 1
  [[ -n "${NOWHERE_TCP_PORT_VALUE:-}" ]] || return 1

  local connect_host sni output fingerprint
  connect_host="$(local_tls_probe_host)"
  sni="${NOWHERE_PUBLIC_HOST_VALUE:-localhost}"

  for _ in 1 2 3 4 5; do
    output="$(
      timeout 8 openssl s_client \
        -connect "${connect_host}:${NOWHERE_TCP_PORT_VALUE}" \
        -servername "$sni" \
        -showcerts </dev/null 2>/dev/null |
        openssl x509 -noout -fingerprint -sha256 2>/dev/null || true
    )"
    fingerprint="${output#*=}"
    if [[ -n "$fingerprint" && "$fingerprint" != "$output" ]]; then
      printf '%s\n' "$fingerprint"
      return 0
    fi
    sleep 1
  done
  return 1
}

print_tls_fingerprint_from_logs() {
  command -v journalctl >/dev/null 2>&1 || return 1
  local line fingerprint

  line="$(
    journalctl -u "$SERVICE_NAME" -n 300 --no-pager 2>/dev/null |
      grep -Eai 'CERT_SHA256\|' |
      tail -n 1 || true
  )"

  if [[ -n "$line" ]]; then
    fingerprint="$(
      printf '%s\n' "$line" |
        sed -nE 's/.*CERT_SHA256\|([A-Fa-f0-9]{64}).*/\1/p' |
        tail -n 1
    )"
    [[ -n "$fingerprint" ]] && {
      printf '%s\n' "$fingerprint"
      return 0
    }
  fi

  return 1
}


issue_cert_menu() {
  require_root
  require_systemd
  load_config

  local domain
  domain="${NOWHERE_PUBLIC_HOST_VALUE:-}"
  if [[ "$ASSUME_YES" -eq 0 ]]; then
    domain="$(read_value "Let's Encrypt 证书域名" "$domain")"
  fi

  validate_certificate_domain "$domain"
  issue_letsencrypt_cert "$domain" "$DEFAULT_CRT_PATH" "$DEFAULT_TLS_KEY_PATH"

  NOWHERE_PUBLIC_HOST="$domain"
  NOWHERE_PUBLIC_HOST_VALUE="$domain"
  NOWHERE_TLS=2
  NOWHERE_TLS_VALUE=2
  NOWHERE_CRT="$DEFAULT_CRT_PATH"
  NOWHERE_TLS_KEY="$DEFAULT_TLS_KEY_PATH"
  NOWHERE_CRT_VALUE="$DEFAULT_CRT_PATH"
  NOWHERE_TLS_KEY_VALUE="$DEFAULT_TLS_KEY_PATH"

  save_config
  write_service

  systemctl restart "$SERVICE_NAME"
  info "已切换到 tls=2，并重新启动 Nowhere。"
  print_tls_certificate_info
}

print_tls_certificate_info() {
  local fingerprint
  [[ -f "${NOWHERE_CRT_VALUE:-}" ]] || return 0
  command -v openssl >/dev/null 2>&1 || return 0

  fingerprint="$(openssl x509 -in "$NOWHERE_CRT_VALUE" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')" || true
  if [[ -n "$fingerprint" ]]; then
    echo
    echo "当前证书 SHA-256 fingerprint："
    echo "  $fingerprint"
  fi
}

print_tls_fingerprint() {
  require_root
  load_config

  if [[ "${NOWHERE_TLS_VALUE:-1}" == "2" && -f "${NOWHERE_CRT_VALUE:-}" ]]; then
    NOWHERE_CRT_VALUE="${NOWHERE_CRT_VALUE}"
    print_tls_certificate_info
    return 0
  fi

  echo
  echo "当前 tls=1 自签证书 SHA-256 fingerprint："
  local fingerprint

  if fingerprint="$(print_tls_fingerprint_from_logs)"; then
    echo "  ${fingerprint}"
  elif fingerprint="$(print_tls_fingerprint_from_tcp)"; then
    echo "  ${fingerprint}"
  else
    warn "暂时没有获取到 fingerprint。请确认服务已启动。"
    return 0
  fi

  echo
  echo "提示：tls=1 证书存在内存中，Nowhere 每次重启后 fingerprint 都会变化。"
}

service_cmd() {
  require_root
  require_systemd
  systemctl "$1" "$SERVICE_NAME"
}

start_service() {
  service_cmd start
  print_tls_fingerprint
}

restart_service() {
  service_cmd restart
  print_tls_fingerprint
}

open_tui() {
  require_root
  [[ -x "$BIN_PATH" ]] || die "Nowhere 未安装。"
  [[ -t 0 && -t 1 ]] || die "TUI 需要交互式终端。"
  "$BIN_PATH" tui
}

print_v2_links() {
  load_config
  local client="${NOWHERE_CLIENT_VALUE:-anywhere}"
  local host="${NOWHERE_PUBLIC_HOST_VALUE:-}"
  local host_part encoded_key encoded_name endpoint base tcp_link udp_link

  [[ -n "$host" ]] || host="$(detect_public_host)"
  [[ -n "$host" ]] || die "公网域名/IP为空，请重新配置。"

  host_part="$(format_host_for_url "$host")"
  encoded_key="$(urlencode "$NOWHERE_KEY_VALUE")"
  encoded_name="$(urlencode "Nowhere VPS")"
  endpoint="$(build_endpoint "$host_part" "${NOWHERE_TCP_PORT_VALUE:-}" "${NOWHERE_UDP_PORT_VALUE:-}")"

  echo
  echo "Client output: $(client_label "$client")"
  echo "Release: ${NOWHERE_VERSION_VALUE:-$DEFAULT_VERSION}"
  echo
  echo "Portal URL:"
  echo "  ${NOWHERE_PORTAL:-}"
  echo

  if [[ "$client" == "vector" || "$client" == "both" ]]; then
    base="vector://${encoded_key}@${endpoint}"
    if [[ -n "${NOWHERE_TCP_PORT_VALUE:-}" ]]; then
      tcp_link="${base}?$(build_vector_query tcp tcp)"
      echo "Native Vector 2.0 URL (TLS/TCP):"
      echo "  ${tcp_link}"
    fi
    if [[ -n "${NOWHERE_UDP_PORT_VALUE:-}" ]]; then
      udp_link="${base}?$(build_vector_query udp udp)"
      [[ -n "$tcp_link" ]] && echo
      echo "Native Vector 2.0 URL (QUIC/UDP):"
      echo "  ${udp_link}"
    fi
    [[ "$client" == "both" ]] && echo
  fi

  if [[ "$client" == "anywhere" || "$client" == "both" ]]; then
    base="nowhere://${encoded_key}@${endpoint}"

    if [[ -n "${NOWHERE_TCP_PORT_VALUE:-}" ]]; then
      tcp_link="${base}?$(build_anywhere_client_query tcp tcp)#${encoded_name}"
      echo "Anywhere 2.0 import link (TCP):"
      echo "  ${tcp_link}"
    fi

    if [[ -n "${NOWHERE_UDP_PORT_VALUE:-}" ]]; then
      udp_link="${base}?$(build_anywhere_client_query udp udp)#${encoded_name}"
      [[ -n "$tcp_link" ]] && echo
      echo "Anywhere 2.0 import link (UDP):"
      echo "  ${udp_link}"
    fi
  fi

  echo
  echo "Firewall reminder:"
  [[ -z "${NOWHERE_TCP_PORT_VALUE:-}" ]] || echo "  Open TCP ${NOWHERE_TCP_PORT_VALUE}"
  [[ -z "${NOWHERE_UDP_PORT_VALUE:-}" ]] || echo "  Open UDP ${NOWHERE_UDP_PORT_VALUE}"

  if [[ "${NOWHERE_TLS_VALUE:-1}" == "1" ]]; then
    echo
    echo "TLS note:"
    echo "  tls=1 使用临时自签证书；服务每次重启后 SHA-256 fingerprint 会变化。"
  fi

  if [[ -n "${NOWHERE_SOCKS_VALUE:-}" && "${NOWHERE_SOCKS_VALUE}" != "$DEFAULT_SOCKS" ]]; then
    echo
    echo "Outbound SOCKS5:"
    echo "  $(display_socks "$NOWHERE_SOCKS_VALUE")"
  fi
}

print_links() {
  require_root
  load_config
  [[ -n "${NOWHERE_KEY_VALUE:-}" ]] || die "没有配置，请先 install 或 configure。"
  print_v2_links
}

install_all() {
  require_root
  require_systemd
  configure_values
  install_binary "$NOWHERE_VERSION"
  save_config
  write_service
  systemctl enable --now "$SERVICE_NAME"
  info "Nowhere 2.x service enabled and started."
  print_links
  print_tls_fingerprint
}

choose_release_version() {
  command -v curl >/dev/null 2>&1 || die "curl is required."
  local api="https://api.github.com/repos/${REPO}/releases?per_page=20"
  local releases=() release choice index

  while IFS= read -r release; do
    [[ "$release" =~ ^v2\. ]] && releases+=("$release")
  done < <(
    curl -fsSL -H 'Accept: application/vnd.github+json' "$api" |
      sed -nE 's/^[[:space:]]*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' |
      head -n 20
  )

  [[ "${#releases[@]}" -gt 0 ]] || die "无法从 GitHub 获取 Nowhere 2.x Release。"

  echo
  echo "最近可用的 Nowhere 2.x Release："
  for index in "${!releases[@]}"; do
    printf ' %2d) %s\n' "$((index + 1))" "${releases[$index]}"
  done
  echo "  0) 取消"

  while true; do
    read -r -p "请选择版本: " choice
    [[ "$choice" == "0" ]] && return 1
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      local n=$((10#$choice))
      if (( n >= 1 && n <= ${#releases[@]} )); then
        SELECTED_VERSION="${releases[$((n - 1))]}"
        return 0
      fi
    fi
    warn "请输入有效编号。"
  done
}

update_saved_version() {
  local version="$1" replacement tmp
  replacement="NOWHERE_VERSION_VALUE=$(env_quote "$version")"
  tmp="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"

  awk -v replacement="$replacement" '
    BEGIN { updated=0 }
    /^NOWHERE_VERSION_VALUE=/ { print replacement; updated=1; next }
    { print }
    END { if (!updated) print replacement }
  ' "$CONFIG_FILE" >"$tmp"

  chmod 600 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

update_all() {
  require_root
  require_systemd
  load_config
  [[ -n "${NOWHERE_VERSION_VALUE:-}" ]] || die "没有已安装的 Nowhere 配置。"

  require_supported_version "$NOWHERE_VERSION_VALUE"

  local selected
  if [[ "$VERSION_EXPLICIT" -eq 1 ]]; then
    selected="$NOWHERE_VERSION"
  else
    choose_release_version || {
      info "已取消更新。"
      return 0
    }
    selected="$SELECTED_VERSION"
  fi

  require_supported_version "$selected"

  install_binary "$selected"
  update_saved_version "$selected"

  if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
    systemctl restart "$SERVICE_NAME"
    info "Nowhere binary updated to ${selected}; service restarted."
  else
    info "Nowhere binary updated to ${selected}; service is not running."
  fi

  print_links
  print_tls_fingerprint
}

configure_all() {
  require_root
  require_systemd
  load_config
  NOWHERE_VERSION="${NOWHERE_VERSION_VALUE:-$DEFAULT_VERSION}"
  require_supported_version "$NOWHERE_VERSION"

  configure_values
  save_config
  write_service

  if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    systemctl restart "$SERVICE_NAME"
    info "Nowhere service restarted."
    print_tls_fingerprint
  else
    warn "服务已写入配置，但当前未 enable。可执行：systemctl enable --now ${SERVICE_NAME}"
  fi

  print_links
}

uninstall_all() {
  require_root
  require_systemd

  echo
  warn "此操作将彻底卸载 Nowhere 2.x，并删除 ${CONFIG_DIR} 中的配置、Shared Key 和 TLS 证书。"
  warn "不会卸载、删除或修改 acme.sh，也不会删除其他程序使用的证书和续期任务。"

  if [[ "$ASSUME_YES" -eq 0 ]]; then
    read -r -p "确认彻底卸载 Nowhere 2.x？[y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { info "已取消卸载。"; return 0; }
  fi

  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$BIN_PATH"
  systemctl daemon-reload
  rm -rf "$CONFIG_DIR"

  info "Nowhere 2.x 已彻底卸载。"
  info "已删除：${BIN_PATH}、${SERVICE_FILE}、${CONFIG_DIR}"
  if acme_sh_path >/dev/null 2>&1; then
    info "acme.sh 已保留，不影响 3x-ui 及其他证书的申请/续期。"
  fi
}

menu() {
  require_root
  require_systemd

  while true; do
    cat <<'EOF'
==============================
 Nowhere 2.x VPS 管理脚本
==============================
  1) 安装/重装 Nowhere 2.x
  2) 修改配置
  3) 指定 Release 安装/重装
  4) 更新 Nowhere 2.x 二进制
  5) 启动服务
  6) 停止服务
  7) 重启服务
  8) 查看状态
  9) 打开 Terminal UI
 10) 查看日志
 11) 打印客户端链接
 12) 查看 TLS 证书 SHA-256
 13) 申请/更新 tls=2 正式证书
 14) 卸载服务
  0) 退出
EOF

    read -r -p "请输入数字: " choice
    case "$choice" in
      1) install_all ;;
      2) configure_all ;;
      3)
        if choose_release_version; then
          NOWHERE_VERSION="$SELECTED_VERSION"
          install_all
        fi
        ;;
      4) update_all ;;
      5) start_service ;;
      6) service_cmd stop ;;
      7) restart_service ;;
      8) service_cmd status ;;
      9) open_tui ;;
      10) require_root; journalctl -u "$SERVICE_NAME" -f ;;
      11) print_links ;;
      12) print_tls_fingerprint ;;
      13) issue_cert_menu ;;
      14) uninstall_all ;;
      0) exit 0 ;;
      *) warn "未知选项：${choice}" ;;
    esac
  done
}

case "$ACTION" in
  install|install-v2|v2) install_all ;;
  configure|config) configure_all ;;
  update) update_all ;;
  versions|version|releases|release)
    require_root
    require_systemd
    choose_release_version
    ;;
  start) start_service ;;
  restart) restart_service ;;
  stop|status) service_cmd "$ACTION" ;;
  tui|dashboard|monitor) open_tui ;;
  fingerprint|sha256|sha-256) print_tls_fingerprint ;;
  cert|generate-cert) issue_cert_menu ;;
  logs|log) require_root; journalctl -u "$SERVICE_NAME" -f ;;
  link|links) print_links ;;
  uninstall|remove) uninstall_all ;;
  menu) menu ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
