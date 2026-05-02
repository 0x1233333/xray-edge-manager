#!/usr/bin/env bash
# Xray Edge Manager / Xray Anti-Block Manager
# v0.0.33-rc11-force-v4-egress — rc10 + optional IPv4-only egress for dual-stack nodes
#
# Features:
# - Xray-core only, no Docker, no sing-box
# - Per-stack protocol selection: IPv4 and IPv6 can independently select 0/1/2/3/4/5 or combinations like 123
# - Domains:
#   BASE_DOMAIN       = CDN / camouflage site / subscription
#   v4.BASE_DOMAIN    = IPv4 direct
#   v6.BASE_DOMAIN    = IPv6 direct
# - Protocols:
#   1 = VLESS + XHTTP + REALITY direct
#   2 = VLESS + XHTTP + TLS + CDN via Nginx
#   3 = Xray Hysteria2 UDP high-speed backup
#   4 = VLESS + REALITY + Vision backup direct
#   5 = VLESS + XHTTP + TLS + CDN extra CDN/BestCF entry using the same CDN inbound
# - NAT-aware: PUBLIC IP is used for DNS; BIND IP is used for Xray listen.
# - Public subscription is copied to /var/www, not read from /root by Nginx.
#
# No personal domains, emails, IPs, or tokens are embedded in this script.

set -Eeuo pipefail
umask 077

# Global temp cleanup registry. Any temp file/dir registered here will be
# removed on normal exit or interruption. Missing paths are ignored.
declare -a GLOBAL_TEMP_FILES=()
cleanup_resources(){
  local tmp
  for tmp in "${GLOBAL_TEMP_FILES[@]:-}"; do
    [[ -n "$tmp" && -e "$tmp" ]] && rm -rf -- "$tmp" 2>/dev/null || true
  done
}
cleanup_and_exit(){
  local code="$1"
  cleanup_resources
  exit "$code"
}
trap cleanup_resources EXIT
trap 'cleanup_and_exit 130' INT HUP QUIT
trap 'cleanup_and_exit 143' TERM

APP_DIR="/root/.xray-edge-manager"
STATE_FILE="$APP_DIR/state.env"
CF_ENV="$APP_DIR/cloudflare.env"
CF_CRED="$APP_DIR/cloudflare.ini"
SUB_DIR="$APP_DIR/subscription"
REMOTES_FILE="$SUB_DIR/remotes.conf"
BESTCF_DIR="$APP_DIR/bestcf"
BACKUP_DIR="$APP_DIR/backups"
DEBUG_DIR="$APP_DIR/debug"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_USER="xray"
XRAY_GROUP="xray"
XRAY_CERT_DIR="/usr/local/etc/xray/certs"
NGINX_SITE="/etc/nginx/conf.d/xray-edge-manager.conf"
WEB_ROOT="/var/www/xray-edge-manager"
SYSCTL_FILE="/etc/sysctl.d/99-xray-edge-manager.conf"
LEGACY_APP_DIR="/root/.xray-anti-block"
LEGACY_NGINX_SITE="/etc/nginx/conf.d/xray-anti-block.conf"
LEGACY_WEB_ROOT="/var/www/xray-anti-block"
FODDER_BASE_URL="https://raw.githubusercontent.com/mack-a/v2ray-agent/master/fodder/blog/unable"
CERT_DEPLOY_HOOK="/usr/local/etc/xray/xem-cert-hook.sh"
LOCK_FILE="/run/xray-edge-manager.lock"

CF_HTTPS_PORTS="443 2053 2083 2087 2096 8443"
CF_IPS_V4_URL="https://www.cloudflare.com/ips-v4"
CF_IPS_V6_URL="https://www.cloudflare.com/ips-v6"
CF_ORIGIN_CHAIN="XEM_CF_ORIGIN"
DEFAULT_HY2_HOP_RANGE="20000:20100"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh"
XRAY_CORE_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases"
XRAY_INSTALL_SCRIPT_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
BESTCF_RELEASE_API="https://api.github.com/repos/DustinWin/BestCF/releases/tags/bestcf"
BESTCF_ASSETS="cmcc-ip.txt cucc-ip.txt ctcc-ip.txt bestcf-ip.txt proxy-ip.txt bestcf-domain.txt"
CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=20
REMOTE_SUB_MAX_BYTES="${XEM_REMOTE_SUB_MAX_BYTES:-2097152}"
# Sanitize: must be a positive integer >= 1024, otherwise reset to default.
[[ "$REMOTE_SUB_MAX_BYTES" =~ ^[0-9]+$ ]] && [[ "$REMOTE_SUB_MAX_BYTES" -ge 1024 ]] || REMOTE_SUB_MAX_BYTES=2097152
SUB_TOKEN_HEX_BYTES="${XEM_SUB_TOKEN_HEX_BYTES:-32}"
# New installs use 64 hex chars by default. Existing 32-char tokens remain valid.
[[ "$SUB_TOKEN_HEX_BYTES" =~ ^[0-9]+$ ]] && [[ "$SUB_TOKEN_HEX_BYTES" -ge 16 ]] && [[ "$SUB_TOKEN_HEX_BYTES" -le 64 ]] || SUB_TOKEN_HEX_BYTES=32

mkdir -p "$APP_DIR" "$APP_DIR/tmp" "$SUB_DIR" "$BESTCF_DIR" "$BACKUP_DIR" "$DEBUG_DIR"
# SECURITY FIX: ensure APP_DIR and its tmp subdir are only accessible by root,
# even if the parent directory permissions are more permissive.
chmod 700 "$APP_DIR" "$APP_DIR/tmp" 2>/dev/null || true

log()  { echo -e "\033[32m[OK]\033[0m $*" >&2; }
info() { echo -e "\033[36m[INFO]\033[0m $*" >&2; }
warn() { echo -e "\033[33m[WARN]\033[0m $*" >&2; }
err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }
die()  { err "$*"; exit 1; }
pause(){ read -r -p "按回车继续..." _ || true; }
need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 运行。"; }

ensure_dir_or_die(){
  local dir="$1"
  [[ -n "$dir" ]] || return 0
  if [[ -e "$dir" && ! -d "$dir" ]]; then
    die "运行路径被同名文件占用，拒绝自动删除：$dir"
  fi
  mkdir -p "$dir" || die "创建运行目录失败：$dir"
}

ensure_runtime_dirs(){
  # Keep runtime directories present even if an earlier failed run, cleanup task,
  # or manual rm removed APP_DIR/tmp while the script is still being used.
  local dir
  for dir in "$APP_DIR" "$APP_DIR/tmp" "$SUB_DIR" "$BESTCF_DIR" "$BACKUP_DIR" "$DEBUG_DIR"; do
    ensure_dir_or_die "$dir"
  done
  chmod 700 "$APP_DIR" "$APP_DIR/tmp" 2>/dev/null || true
}


register_temp_path(){
  local tmp="$1"
  [[ -n "$tmp" ]] && GLOBAL_TEMP_FILES+=("$tmp")
}

mktemp_parent_from_args(){
  local arg
  for arg in "$@"; do
    [[ "$arg" == -* ]] && continue
    dirname "$arg"
    return 0
  done
  echo ""
}

mktemp_file(){
  local tmp parent
  ensure_runtime_dirs
  parent="$(mktemp_parent_from_args "$@")"
  [[ -n "$parent" ]] && ensure_dir_or_die "$parent"
  tmp="$(mktemp "$@")" || die "创建临时文件失败。"
  register_temp_path "$tmp"
  echo "$tmp"
}

mktemp_dir(){
  local tmp parent
  ensure_runtime_dirs
  parent="$(mktemp_parent_from_args "$@")"
  [[ -n "$parent" ]] && ensure_dir_or_die "$parent"
  tmp="$(mktemp -d "$@")" || die "创建临时目录失败。"
  register_temp_path "$tmp"
  echo "$tmp"
}

acquire_lock(){
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    err "检测到另一个 xray-edge-manager 实例正在运行，请稍后再试。"
    exit 1
  fi
}

allowed_state_key(){
  case "$1" in
    BASE_DOMAIN|NODE_NAME|PUBLIC_IPV4|PUBLIC_IPV6|BIND_IPV4|BIND_IPV6)
      return 0
      ;;
    IPV4_PROTOCOLS|IPV6_PROTOCOLS|PROTOCOLS|ENABLE_CDN|CDN_PORT)
      return 0
      ;;
    XHTTP_REALITY_PORT|REALITY_VISION_PORT|HY2_PORT|XHTTP_CDN_LOCAL_PORT)
      return 0
      ;;
    UUID|REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY|SHORT_ID|XHTTP_REALITY_PATH|XHTTP_CDN_PATH|HY2_AUTH)
      return 0
      ;;
    SUB_TOKEN|MERGED_SUB_TOKEN|CERT_EMAIL|REALITY_TARGET|ENABLE_IP_STACK_BINDING|IP_OUTBOUND_MODE)
      return 0
      ;;
    BESTCF_ENABLED|BESTCF_MODE|BESTCF_PER_CATEGORY_LIMIT|BESTCF_TOTAL_LIMIT)
      return 0
      ;;
    HY2_HOP_RANGE|HY2_HOP_TO_PORT|ENABLE_CF_ORIGIN_FIREWALL)
      return 0
      ;;
    LAST_XRAY_BACKUP|LAST_NGINX_BACKUP|LAST_SYSCTL_BACKUP)
      return 0
      ;;
    V4_XHTTP_REALITY_READY|V6_XHTTP_REALITY_READY|V4_HY2_READY|V6_HY2_READY|V4_VISION_READY|V6_VISION_READY|CDN_XHTTP_READY)
      return 0
      ;;
    CF_API_TOKEN|CF_ZONE_NAME|CF_ZONE_ID)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

safe_source_env_file(){
  local file="$1" line key val n=0
  [[ -f "$file" ]] || return 0

  # Do not read symlinks. State files contain credentials and are expected to
  # be regular files under APP_DIR.
  [[ ! -L "$file" ]] || die "拒绝读取符号链接状态文件：$file"
  chmod 600 "$file" 2>/dev/null || true

  # SECURITY FIX: do NOT source the file. Instead parse key=value lines and
  # assign them via declare. This eliminates any possibility of shell injection
  # through crafted state file values (ANSI-C quoting, $'...' escapes, etc.).
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "状态文件格式非法：$file:$n"
    key="${line%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "状态文件键名非法：$file:$n"

    # Extract value: strip the key= prefix
    val="${line#*=}"
    # Remove surrounding single quotes if present (from bash %q output)
    if [[ "$val" =~ ^\$?\'.*\'$ ]]; then
      # $'...' or '...' quoted value — strip to literal content.
      # For safety we reject $'...' (ANSI-C) which can encode arbitrary bytes.
      if [[ "$val" == \$\'* ]]; then
        die "状态文件包含 ANSI-C 引号，拒绝加载：$file:$n"
      fi
      val="${val#\'}"  # remove leading '
      val="${val%\'}"
      # remove trailing '
    fi

    # Final safety check: reject values with shell metacharacters
    case "$val" in
      *'$('*|*'`'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*)
        die "状态文件包含不安全字符，拒绝加载：$file:$n"
        ;;
    esac

    allowed_state_key "$key" || die "状态文件包含未知键，拒绝加载：$file:$n key=$key"

    # Safely assign to global scope via declare -g (bash 4.2+)
    declare -g "$key=$val"
  done < "$file"
}

load_state(){
  safe_source_env_file "$STATE_FILE"
  safe_source_env_file "$CF_ENV"
  return 0
}

save_kv(){
  local file="$1" key="$2" value="$3" tmp
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "非法配置键名：$key"

  # SECURITY/HARDENING: state.env is parsed by our strict loader, not sourced.
  # Keep values single-line and free of control characters / shell metacharacters.
  # This also prevents accidental capture of colored warn/info output into state
  # values from corrupting state.env as ANSI-C quoted multi-line strings.
  if printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    die "配置值包含控制字符，拒绝写入状态文件：$key"
  fi
  case "$value" in
    *'$('|*'`'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*)
      die "配置值包含不安全字符，拒绝写入状态文件：$key"
      ;;
  esac

  mkdir -p "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file" 2>/dev/null || true

  tmp="$(mktemp_file "${file}.tmp.XXXXXX")"
  # Remove the existing exact key line via awk, then append the new value using
  # printf. Do not pass the value through awk -v; awk interprets backslash
  # escapes such as \E, which can corrupt ANSI/control-containing values.
  awk -v k="$key" '
    BEGIN { pat = k "=" }
    substr($0, 1, length(pat)) != pat { print }
  ' "$file" > "$tmp" || { rm -f "$tmp"; die "写入临时状态文件失败：$tmp"; }
  printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; die "追加状态文件失败：$tmp"; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
}

ask(){
  local prompt="$1" default="${2:-}" ans msg
  if [[ -n "$default" ]]; then msg="$prompt [$default]: "; else msg="$prompt: "; fi
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '%s' "$msg" > /dev/tty
    IFS= read -r ans < /dev/tty || true
  else
    printf '%s' "$msg" >&2
    IFS= read -r ans || true
  fi
  if [[ -n "$default" ]]; then echo "${ans:-$default}"; else echo "$ans"; fi
}

confirm(){
  local prompt="$1" default="${2:-N}" ans
  ans=$(ask "$prompt" "$default")
  [[ "$ans" =~ ^[Yy]$ ]]
}

rand_hex(){ openssl rand -hex "${1:-8}"; }
rand_token(){ openssl rand -hex "${1:-$SUB_TOKEN_HEX_BYTES}"; }
rand_path(){ echo "/$(openssl rand -hex 6)/xhttp"; }

# SECURITY FIX: validate that subscription tokens are safe hex strings,
# preventing path traversal if the state file is tampered with.
# Keep old 32-char tokens valid, while new installs default to 64 chars.
# If invalid, auto-regenerate instead of dying — better UX for existing installs.
validate_or_regen_token(){
  local key="$1" current="${!1:-}"
  if [[ ! "$current" =~ ^[a-f0-9]{32,128}$ ]]; then
    if [[ -n "$current" ]]; then
      warn "${key} 格式非法（应为32-128位十六进制），已自动重新生成。"
    fi
    save_kv "$STATE_FILE" "$key" "$(rand_token)"
    load_state
  fi
}

valid_port(){
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]
}

is_cf_https_port(){
  local p="$1" x
  for x in $CF_HTTPS_PORTS; do [[ "$p" == "$x" ]] && return 0; done
  return 1
}

version_ge(){
  local current="$1" minimum="$2" first
  [[ -n "$current" && -n "$minimum" ]] || return 1
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --compare-versions "$current" ge "$minimum"
    return $?
  fi
  if command -v sort >/dev/null 2>&1; then
    first=$(printf '%s\n%s\n' "$minimum" "$current" | sort -V | head -n1)
    [[ "$first" == "$minimum" ]]
    return $?
  fi
  return 1
}

validate_base_domain(){
  local d="$1"
  [[ "$d" == *.*.* ]] || return 1
  [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.){2,}[A-Za-z]{2,}$ ]] || return 1
}

validate_hostname(){
  local d="$1"
  [[ -n "$d" && ${#d} -le 253 ]] || return 1
  [[ "$d" != *..* ]] || return 1
  [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || return 1
}

public_ipv4(){
  curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || \
  curl -4 -fsS --max-time 8 https://ifconfig.co/ip 2>/dev/null || true
}

public_ipv6(){
  curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || \
  curl -6 -fsS --max-time 8 https://ifconfig.co/ip 2>/dev/null || true
}

detect_public_ips(){
  local cur4 cur6 old4="${PUBLIC_IPV4:-}" old6="${PUBLIC_IPV6:-}"
  cur4="$(public_ipv4 || true)"
  cur6="$(public_ipv6 || true)"

  if [[ -n "$cur4" ]]; then
    save_kv "$STATE_FILE" PUBLIC_IPV4 "$cur4"
  elif [[ -n "$old4" ]]; then
    warn "无法重新检测 IPv4，继续使用旧值：$old4"
  fi

  if [[ -n "$cur6" ]]; then
    save_kv "$STATE_FILE" PUBLIC_IPV6 "$cur6"
  elif [[ -n "$old6" ]]; then
    warn "无法重新检测 IPv6，继续使用旧值：$old6"
  fi
  load_state
}

local_ipv4_for_bind(){
  local public_ip="$1" src
  if [[ -n "$public_ip" ]] && ip -4 addr show | grep -qw "$public_ip"; then
    echo "$public_ip"; return 0
  fi
  [[ -n "$public_ip" ]] && warn "公网 IPv4 不在本机网卡上，可能是 NAT 环境：$public_ip"
  src=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  if [[ -n "$src" ]]; then
    warn "IPv4 listen 使用本机实际出口地址：$src"
    echo "$src"
  else
    warn "无法确定本机 IPv4 出口地址，listen 回退 0.0.0.0"
    echo "0.0.0.0"
  fi
}

local_ipv6_for_bind(){
  local public_ip="$1" src
  if [[ -n "$public_ip" ]] && ip -6 addr show scope global | grep -qw "$public_ip"; then
    echo "$public_ip"; return 0
  fi
  [[ -n "$public_ip" ]] && warn "公网 IPv6 不在本机网卡上，可能是 NAT/特殊路由环境：$public_ip"
  src=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  if [[ -n "$src" ]]; then
    warn "IPv6 listen 使用本机实际出口地址：$src"
    echo "$src"
  else
    warn "无法确定本机 IPv6 出口地址，将跳过需要 IPv6 精确监听的入站。"
    echo ""
  fi
}

get_proc_by_port(){
  local proto="$1" port="$2"
  ss -H -lpn "$proto" "sport = :$port" 2>/dev/null | awk '{print $NF}' | head -n1
}

nginx_conf_user_field(){
  local field="$1"
  awk -v f="$field" '
    $1 == "user" {
      gsub(";", "", $2)
      gsub(";", "", $3)
      if (f == "user") print $2
      else if (f == "group") print $3
      exit
    }
  ' /etc/nginx/nginx.conf 2>/dev/null || true
}

detect_nginx_user(){
  local u
  u="$(nginx_conf_user_field user)"
  if [[ -n "$u" ]] && id -u "$u" >/dev/null 2>&1; then
    echo "$u"
    return 0
  fi

  u="$(ps -eo user=,comm= 2>/dev/null | awk '$2 == "nginx" && $1 != "root" {print $1; exit}' || true)"
  if [[ -n "$u" ]] && id -u "$u" >/dev/null 2>&1; then
    echo "$u"
    return 0
  fi

  if id -u www-data >/dev/null 2>&1; then
    echo "www-data"
  elif id -u nginx >/dev/null 2>&1; then
    echo "nginx"
  else
    echo "root"
  fi
}

detect_nginx_group(){
  local g u
  g="$(nginx_conf_user_field group)"
  if [[ -n "$g" ]] && getent group "$g" >/dev/null 2>&1; then
    echo "$g"
    return 0
  fi

  u="$(detect_nginx_user)"
  g="$(id -gn "$u" 2>/dev/null || true)"
  if [[ -n "$g" ]] && getent group "$g" >/dev/null 2>&1; then
    echo "$g"
    return 0
  fi

  if getent group www-data >/dev/null 2>&1; then
    echo "www-data"
  elif getent group nginx >/dev/null 2>&1; then
    echo "nginx"
  else
    echo "root"
  fi
}

ensure_web_subscription_permissions(){
  local ng ngx_user
  ngx_user="$(detect_nginx_user)"
  ng="$(detect_nginx_group)"

  # RC10 HARDENING: umask 077 is correct for secrets, but web path parents
  # must remain searchable by the Nginx worker. If /var/www is first created
  # by this script, explicitly normalize it to the standard web permission.
  mkdir -p /var/www "$WEB_ROOT" "$WEB_ROOT/sub"
  chmod 755 /var/www 2>/dev/null || true
  chmod 755 "$WEB_ROOT" 2>/dev/null || true

  # Keep subscription files non-world-readable. Nginx can read them via group.
  chmod 750 "$WEB_ROOT/sub" 2>/dev/null || true
  chown root:"$ng" "$WEB_ROOT/sub" 2>/dev/null || true
  if find "$WEB_ROOT/sub" -mindepth 1 -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
    find "$WEB_ROOT/sub" -mindepth 1 -maxdepth 1 -type f -exec chown root:"$ng" {} + 2>/dev/null || true
    find "$WEB_ROOT/sub" -mindepth 1 -maxdepth 1 -type f -exec chmod 640 {} + 2>/dev/null || true
  fi
  info "订阅目录权限使用 Nginx worker：user=${ngx_user} group=${ng}"
}


install_deps(){
  need_root
  command -v apt-get >/dev/null 2>&1 || die "当前脚本自动安装依赖仅支持 Debian/Ubuntu apt 系。"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    curl wget jq openssl ca-certificates gnupg lsb-release \
    nginx certbot python3-certbot-dns-cloudflare \
    whois iproute2 iputils-ping iptables nftables tcpdump unzip tar sed grep coreutils perl xxd \
    cron socat util-linux conntrack logrotate
  log "基础依赖安装完成。"
}


install_xray_logrotate(){
  if [[ -d /etc/logrotate.d ]]; then
    cat >/etc/logrotate.d/xray <<'EOF2'
/var/log/xray/*.log {
    daily
    maxsize 20M
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 xray xray
}
EOF2
  else
    warn "未找到 /etc/logrotate.d，跳过 Xray 日志轮转配置。"
  fi
}

ensure_xray_user(){
  if ! getent group "$XRAY_GROUP" >/dev/null 2>&1; then
    groupadd --system "$XRAY_GROUP" 2>/dev/null || true
  fi
  if ! id -u "$XRAY_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin \
      --gid "$XRAY_GROUP" "$XRAY_USER" 2>/dev/null || true
  fi
  id -u "$XRAY_USER" >/dev/null 2>&1 || die "创建 Xray 专用用户失败：$XRAY_USER"
}

install_xray_systemd_restart_policy(){
  mkdir -p /etc/systemd/system/xray.service.d
  cat >/etc/systemd/system/xray.service.d/10-xem-restart.conf <<'EOF2'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=on-failure
RestartSec=5s
EOF2
}

install_xray_systemd_hardening_policy(){
  mkdir -p /etc/systemd/system/xray.service.d
  cat >/etc/systemd/system/xray.service.d/20-xem-hardening.conf <<EOF2
[Service]
User=${XRAY_USER}
Group=${XRAY_GROUP}
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/log/xray /run/xray
EOF2
}

sync_xray_certificate(){
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || return 0
  local live_dir="/etc/letsencrypt/live/${BASE_DOMAIN}" dst="${XRAY_CERT_DIR}/${BASE_DOMAIN}"
  [[ -f "$live_dir/fullchain.pem" && -f "$live_dir/privkey.pem" ]] || return 0
  ensure_xray_user
  install -d -m 750 -o root -g "$XRAY_GROUP" "$dst"
  install -m 640 -o root -g "$XRAY_GROUP" "$live_dir/fullchain.pem" "$dst/fullchain.pem"
  install -m 640 -o root -g "$XRAY_GROUP" "$live_dir/privkey.pem" "$dst/privkey.pem"
  log "已同步 Xray 可读证书副本：$dst"
}

ensure_xray_service(){
  need_root
  command -v xray >/dev/null 2>&1 || die "未找到 xray 二进制文件，请先安装/升级 Xray-core。"
  ensure_xray_user
  install -d -m 755 /usr/local/etc/xray /usr/local/share/xray /etc/systemd/system
  install -d -m 755 -o "$XRAY_USER" -g "$XRAY_GROUP" /var/log/xray
  install -d -m 750 -o root -g "$XRAY_GROUP" "$XRAY_CERT_DIR"

  install_xray_logrotate

  # Some uninstall/reinstall paths can leave the xray binary installed while the
  # systemd unit has been removed. Recreate a minimal service unit if needed.
  if [[ ! -f /etc/systemd/system/xray.service ]] && ! systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx 'xray.service'; then
    warn "未检测到 xray.service，正在自动重建 systemd 服务。"
    cat >/etc/systemd/system/xray.service <<'EOF2'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5s
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF2
  fi

  # Always add a drop-in so official installer generated services also get the
  # anti-crash restart policy without replacing their full unit file.
  install_xray_systemd_restart_policy
  install_xray_systemd_hardening_policy
  sync_xray_certificate

  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
}

xray_test_config(){
  local config="$1" xray_bin
  xray_bin="$(command -v xray 2>/dev/null || true)"
  [[ -n "$xray_bin" ]] || die "未找到 xray 二进制文件。"
  if command -v runuser >/dev/null 2>&1 && id -u "$XRAY_USER" >/dev/null 2>&1; then
    runuser -u "$XRAY_USER" -- "$xray_bin" run -test -config "$config"
  else
    "$xray_bin" run -test -config "$config"
  fi
}

xray_release_asset_name(){
  case "$(uname -m)" in
    x86_64|amd64) echo "Xray-linux-64.zip" ;;
    i386|i686) echo "Xray-linux-32.zip" ;;
    aarch64|arm64|armv8*) echo "Xray-linux-arm64-v8a.zip" ;;
    armv7l|armv7*) echo "Xray-linux-arm32-v7a.zip" ;;
    armv6l|armv6*) echo "Xray-linux-arm32-v6.zip" ;;
    armv5tel|armv5*) echo "Xray-linux-arm32-v5.zip" ;;
    mips64le) echo "Xray-linux-mips64le.zip" ;;
    mips64) echo "Xray-linux-mips64.zip" ;;
    mipsle) echo "Xray-linux-mips32le.zip" ;;
    mips) echo "Xray-linux-mips32.zip" ;;
    ppc64le) echo "Xray-linux-ppc64le.zip" ;;
    ppc64) echo "Xray-linux-ppc64.zip" ;;
    riscv64) echo "Xray-linux-riscv64.zip" ;;
    s390x) echo "Xray-linux-s390x.zip" ;;
    *) return 1 ;;
  esac
}

extract_sha256_from_dgst(){
  local dgst="$1"
  grep -iE 'SHA2-256|SHA256|sha256' "$dgst" 2>/dev/null | grep -Eio '[a-f0-9]{64}' | head -n1
}

install_or_upgrade_xray_release_verified(){
  need_root
  ensure_runtime_dirs
  local asset release_json tag asset_url dgst_url tmp zip dgst expected actual extract_dir xray_bin dat f

  asset="$(xray_release_asset_name)" || die "当前架构暂不支持自动匹配 Xray 官方 Release：$(uname -m)"
  # SECURITY FIX: use APP_DIR instead of /tmp to avoid symlink race in multi-user systems.
  tmp="$(mktemp_dir "$APP_DIR/tmp/xray-release.XXXXXX")"
  zip="$tmp/$asset"
  dgst="$tmp/$asset.dgst"
  extract_dir="$tmp/extract"

  info "从 XTLS/Xray-core 官方 Release 获取资产列表。"
  release_json="$tmp/releases.json"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 60 \
    -H "Accept: application/vnd.github+json" \
    -o "$release_json" "$XRAY_CORE_RELEASE_API?per_page=50" || die "获取 Xray-core 官方 Release 列表失败。"

  tag=$(jq -r --arg asset "$asset" '
    map(select((.draft|not) and (.prerelease|not))) |
    map(select(any(.assets[]?; .name == $asset))) |
    .[0].tag_name // empty
  ' "$release_json")
  asset_url=$(jq -r --arg asset "$asset" '
    map(select((.draft|not) and (.prerelease|not)))[] |
    .assets[]? |
    select(.name == $asset) |
    .browser_download_url
  ' "$release_json" | head -n1)
  dgst_url=$(jq -r --arg asset "$asset" '
    map(select((.draft|not) and (.prerelease|not)))[] |
    .assets[]? |
    select(.name == ($asset + ".dgst")) |
    .browser_download_url
  ' "$release_json" | head -n1)

  [[ -n "$tag" && -n "$asset_url" && -n "$dgst_url" ]] || die "未在 Xray-core 官方 Release 中找到 $asset 及其 .dgst 校验文件。"

  info "准备安装 Xray-core ${tag}：$asset"
  info "下载官方 ZIP 与同 Release digest 文件。"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 180 -o "$zip" "$asset_url" || die "下载 Xray 官方 ZIP 失败。"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 60 -o "$dgst" "$dgst_url" || die "下载 Xray 官方 digest 失败。"

  expected="$(extract_sha256_from_dgst "$dgst")"
  [[ -n "$expected" ]] || die "无法从官方 digest 文件提取 SHA256。"
  actual="$(sha256sum "$zip" | awk '{print $1}')"
  if [[ "${actual,,}" != "${expected,,}" ]]; then
    err "Xray 官方 ZIP SHA256 校验失败。"
    err "expected=$expected"
    err "actual=$actual"
    die "拒绝安装，可能是下载损坏或链路被替换。"
  fi
  log "Xray 官方 ZIP SHA256 校验通过。"

  mkdir -p "$extract_dir"
  unzip -oq "$zip" -d "$extract_dir" || die "解压 Xray ZIP 失败。"
  xray_bin="$(find "$extract_dir" -type f -name xray | head -n1)"
  [[ -n "$xray_bin" && -f "$xray_bin" ]] || die "Xray ZIP 中未找到 xray 二进制。"

  install -d /usr/local/bin /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  install -m 755 "$xray_bin" /usr/local/bin/xray
  for dat in geoip.dat geosite.dat; do
    f="$(find "$extract_dir" -type f -name "$dat" | head -n1 || true)"
    [[ -n "$f" && -f "$f" ]] && install -m 644 "$f" "/usr/local/share/xray/$dat"
  done

  ensure_xray_service
  log "Xray-core $tag 已从官方 Release 安装/升级完成。"
  xray version || true
}

install_or_upgrade_xray_script_fallback(){
  need_root
  local installer expected actual
  if [[ "${XEM_ALLOW_XRAY_SCRIPT_FALLBACK:-0}" != "1" ]]; then
    die "远程 Xray-install 脚本执行模式已默认禁用。请使用 Release ZIP 校验安装；如确需备用模式，请显式设置 XEM_ALLOW_XRAY_SCRIPT_FALLBACK=1。"
  fi
  warn "即将从 XTLS/Xray-install 官方仓库下载并执行 Xray 安装脚本。"
  warn "这是官方脚本备用模式；如需强校验脚本本身，可设置 XEM_XRAY_INSTALL_SHA256。"
  if [[ "${XEM_TRUST_REMOTE_XRAY_INSTALL:-0}" != "1" ]]; then
    confirm "是否继续执行官方 Xray-install 脚本？" "N" || die "已取消远程安装。"
  fi

  # SECURITY FIX: use APP_DIR instead of /tmp to avoid symlink race.
  installer="$(mktemp_file "$APP_DIR/tmp/xray-install.XXXXXX.sh")"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 120 -o "$installer" "$XRAY_INSTALL_SCRIPT_URL" || die "下载 Xray 官方安装脚本失败。"
  bash -n "$installer" || die "下载的 Xray 安装脚本语法检查失败，拒绝执行。"

  if [[ -n "${XEM_XRAY_INSTALL_SHA256:-}" ]]; then
    expected="${XEM_XRAY_INSTALL_SHA256,,}"
    actual="$(sha256sum "$installer" | awk '{print tolower($1)}')"
    [[ "$actual" == "$expected" ]] || die "Xray-install 脚本 SHA256 不匹配，拒绝执行。"
    log "Xray-install 脚本 SHA256 pin 校验通过。"
  fi

  bash "$installer" install -u root
  ensure_xray_service
  log "Xray 官方安装脚本执行完成。"
  xray version || true
}

install_or_upgrade_xray(){
  need_root
  local mode
  mode="${XEM_XRAY_INSTALL_MODE:-}"
  if [[ -z "$mode" ]]; then
    echo "===== Xray-core 安装方式 ====="
    echo "1. 官方 Xray-core Release ZIP + 官方 .dgst SHA256 校验，推荐"
    echo "2. 官方 Xray-install 脚本，默认禁用；仅设置 XEM_ALLOW_XRAY_SCRIPT_FALLBACK=1 后可用"
    mode=$(ask "请选择" "1")
  fi

  case "$mode" in
    1|release|zip) install_or_upgrade_xray_release_verified ;;
    2|script) install_or_upgrade_xray_script_fallback ;;
    *) die "未知 Xray 安装方式：$mode" ;;
  esac
}

update_geodata(){
  need_root
  local tmp status geoip_url geosite_url
  tmp="$(mktemp_dir "$APP_DIR/tmp/geodata.XXXXXX")"
  status=0
  geoip_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
  geosite_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

  info "安全更新 geoip.dat / geosite.dat：只下载数据文件和 sha256，不执行远程脚本。"

  # Use a subshell for cd isolation but rely on global GLOBAL_TEMP_FILES for cleanup.
  # No internal trap needed — mktemp_dir already registered $tmp for cleanup on exit.
  (
    cd "$tmp" &&
    curl -fL --retry 3 --retry-delay 2 --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 120 -o geoip.dat "$geoip_url" &&
    curl -fL --retry 3 --retry-delay 2 --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 120 -o geoip.dat.sha256sum "$geoip_url.sha256sum" &&
    curl -fL --retry 3 --retry-delay 2 --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 120 -o geosite.dat "$geosite_url" &&
    curl -fL --retry 3 --retry-delay 2 --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 120 -o geosite.dat.sha256sum "$geosite_url.sha256sum" &&
    sha256sum -c geoip.dat.sha256sum &&
    sha256sum -c geosite.dat.sha256sum &&
    install -d /usr/local/share/xray &&
    install -m 644 geoip.dat /usr/local/share/xray/geoip.dat.new &&
    install -m 644 geosite.dat /usr/local/share/xray/geosite.dat.new &&
    mv -f /usr/local/share/xray/geoip.dat.new /usr/local/share/xray/geoip.dat &&
    mv -f /usr/local/share/xray/geosite.dat.new /usr/local/share/xray/geosite.dat
  ) || status=$?

  if [[ "$status" -eq 0 ]]; then
    log "geodata 已安全更新。"
  else
    warn "geodata 下载或 sha256 校验失败，已保留原文件。"
  fi
  return 0
}

install_self_to_local_bin(){
  need_root
  mkdir -p /usr/local/bin
  if [[ -f "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != /dev/fd/* && "${BASH_SOURCE[0]}" != /proc/* ]]; then
    install -m 755 "${BASH_SOURCE[0]}" /usr/local/bin/xem
    log "已安装本地命令：/usr/local/bin/xem"
    return 0
  fi
  # SECURITY FIX: do not silently download and install self from remote.
  # Require explicit user confirmation, and support SHA256 pin verification.
  warn "当前可能是 bash <(curl ...) 方式运行，无法可靠复制自身。"
  warn "将从仓库下载一次用于固化本地命令：$SCRIPT_RAW_URL"
  warn "这意味着你信任该远程地址提供的脚本内容。可设置 XEM_SELF_SHA256 进行强校验。"
  if [[ "${XEM_TRUST_REMOTE_SELF:-0}" != "1" ]]; then
    confirm "是否继续从远程下载并安装本脚本？" "N" || die "已取消远程安装。请手动下载脚本后执行 install -m 755 xem.sh /usr/local/bin/xem"
  fi
  local tmp_script
  tmp_script="$(mktemp_file "$APP_DIR/tmp/xem-self.XXXXXX.sh")"
  curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 60 "$SCRIPT_RAW_URL" -o "$tmp_script" || die "下载本地命令失败。"
  if command -v perl >/dev/null 2>&1; then
    perl -C -pi -e 's/\x{00A0}/ /g' "$tmp_script" 2>/dev/null || true
  fi
  bash -n "$tmp_script" || die "下载的脚本语法检查失败，拒绝安装。"
  # SHA256 pin verification if configured
  if [[ -n "${XEM_SELF_SHA256:-}" ]]; then
    local expected_self actual_self
    expected_self="${XEM_SELF_SHA256,,}"
    actual_self="$(sha256sum "$tmp_script" | awk '{print tolower($1)}')"
    [[ "$actual_self" == "$expected_self" ]] || die "脚本 SHA256 校验失败，拒绝安装。expected=$expected_self actual=$actual_self"
    log "脚本 SHA256 pin 校验通过。"
  fi
  mv -f "$tmp_script" /usr/local/bin/xem
  chmod +x /usr/local/bin/xem
  log "已安装本地命令：/usr/local/bin/xem"
}

enable_geodata_timer(){
  install_self_to_local_bin
  cat >/etc/systemd/system/xem-geodata-update.service <<'EOF2'
[Unit]
Description=Safely update Xray geodata via local Xray Edge Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xem --geodata-update
EOF2
  cat >/etc/systemd/system/xem-geodata-update.timer <<'EOF2'
[Unit]
Description=Run safe Xray geodata update weekly during off-peak hours

[Timer]
OnCalendar=Mon *-*-* 04:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF2
  systemctl daemon-reload
  systemctl enable --now xem-geodata-update.timer
  log "geodata 安全自动更新已启用：每周一凌晨 4-5 点期间执行。"
}

disable_geodata_timer(){
  systemctl disable --now xem-geodata-update.timer 2>/dev/null || true
  rm -f /etc/systemd/system/xem-geodata-update.service /etc/systemd/system/xem-geodata-update.timer
  systemctl daemon-reload 2>/dev/null || true
  log "geodata 自动更新已关闭。"
}

configure_base_domain(){
  load_state
  local force="${1:-0}" d
  if [[ "$force" != "1" && -n "${BASE_DOMAIN:-}" ]] && validate_base_domain "$BASE_DOMAIN"; then
    info "已使用当前母域名：$BASE_DOMAIN"; return 0
  fi
  while true; do
    d=$(ask "请输入母域名，必须三段式或以上，例如 node.example.com" "${BASE_DOMAIN:-}")
    d=$(printf '%s' "$d" | tr -d '[:space:]')
    if validate_base_domain "$d"; then
      save_kv "$STATE_FILE" BASE_DOMAIN "$d"
      log "母域名已设置：$d"
      break
    fi
    warn "域名不合格。必须类似 node.example.com，不能是 example.com 这种二段根域。"
  done
}

configure_node_name(){
  load_state
  local default_name name
  if [[ -n "${BASE_DOMAIN:-}" ]]; then
    default_name="${BASE_DOMAIN%%.*}"
  else
    default_name="node"
  fi
  name=$(ask "请输入节点名称，用于订阅中区分机器，例如 jp1/us1/oracle-tokyo" "${NODE_NAME:-$default_name}")
  name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9_.-' | sed 's/^[-_.]*//; s/[-_.]*$//')
  [[ -n "$name" ]] || name="node"
  save_kv "$STATE_FILE" NODE_NAME "$name"
  log "节点名称已设置：$name"
}

prepare_base_domain_for_install(){
  load_state
  if [[ -n "${BASE_DOMAIN:-}" ]] && validate_base_domain "$BASE_DOMAIN"; then
    echo "检测到上次保存的母域名：$BASE_DOMAIN"
    echo "1. 继续使用这个母域名"
    echo "2. 重新输入母域名"
    local c; c=$(ask "请选择" "1")
    case "$c" in
      1) info "继续使用当前母域名：$BASE_DOMAIN" ;;
      2) configure_base_domain 1 ;;
      *) warn "无效选择，继续使用当前母域名：$BASE_DOMAIN" ;;
    esac
  else
    configure_base_domain 1
  fi
}

cloudflare_token_risk_check(){
  local token="$1" ack
  if [[ "$token" =~ ^[a-f0-9]{37}$ ]]; then
    warn "这个 Token 看起来像 Cloudflare Global API Key。强烈不建议使用。"
    ack=$(ask "如坚持继续，请输入 YES_I_KNOW_THE_RISK" "")
    [[ "$ack" == "YES_I_KNOW_THE_RISK" ]] || die "已中止。请使用 Restricted API Token。"
  fi
}

cf_api(){
  local method="$1" endpoint="$2" data="${3:-}" resp ok
  load_state
  [[ -n "${CF_API_TOKEN:-}" ]] || die "未配置 CF_API_TOKEN。"
  if [[ -n "$data" ]]; then
    resp=$(curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
      -X "$method" "https://api.cloudflare.com/client/v4$endpoint" \
      -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "$data") || return 1
  else
    resp=$(curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
      -X "$method" "https://api.cloudflare.com/client/v4$endpoint" \
      -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json") || return 1
  fi
  ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null || true)
  if [[ "$ok" != "true" ]]; then
    err "Cloudflare API 调用失败：$method $endpoint"
    echo "$resp" >&2
    return 1
  fi
  echo "$resp"
}

setup_cloudflare(){
  load_state
  configure_base_domain
  local token zone_name resp ok zone_id
  echo "Cloudflare API Token 创建教程："
  echo "  https://github.com/0x1233333/xray-edge-manager/blob/main/examples/cloudflare-api-token.md"
  echo "请使用 Restricted API Token，不要使用 Global API Key。"
  token=$(ask "请输入 Cloudflare Restricted API Token，需 Zone:Read + DNS:Edit" "${CF_API_TOKEN:-}")
  token=$(printf '%s' "$token" | tr -d '[:space:]')
  [[ -n "$token" ]] || die "API Token 不能为空。"
  cloudflare_token_risk_check "$token"
  save_kv "$CF_ENV" CF_API_TOKEN "$token"
  safe_source_env_file "$CF_ENV"

  zone_name=$(ask "请输入 Cloudflare Zone Name，例如 example.com" "${CF_ZONE_NAME:-}")
  zone_name=$(printf '%s' "$zone_name" | tr -d '[:space:]')
  [[ -n "$zone_name" ]] || die "Zone Name 不能为空。"
  save_kv "$CF_ENV" CF_ZONE_NAME "$zone_name"

  resp=$(curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -G "https://api.cloudflare.com/client/v4/zones" \
    -H "Authorization: Bearer $token" --data-urlencode "name=$zone_name") || die "Cloudflare API 查询失败或超时。"
  ok=$(echo "$resp" | jq -r '.success')
  [[ "$ok" == "true" ]] || die "Cloudflare API 返回失败：$resp"
  zone_id=$(echo "$resp" | jq -r '.result[0].id // empty')
  [[ -n "$zone_id" ]] || die "未查到 Zone ID。请确认 Zone Name 正确，且 Token 的 Zone Resources 包含该域名。"
  save_kv "$CF_ENV" CF_ZONE_ID "$zone_id"
  safe_source_env_file "$CF_ENV"
  cf_api GET "/zones/$zone_id/dns_records?per_page=1" >/dev/null || die "Token 无法读取 DNS 记录。"
  log "Cloudflare 已配置并通过权限测试：zone=$zone_name id=$zone_id"
}

cf_upsert_record(){
  local name="$1" type="$2" content="$3" proxied="$4" list rec_id payload id
  local ids=()
  load_state
  [[ -n "${CF_ZONE_ID:-}" ]] || die "未配置 CF_ZONE_ID。"
  [[ -n "$content" ]] || { warn "$name $type 内容为空，跳过。"; return 0; }
  info "Upsert DNS: $type $name -> $content proxied=$proxied"
  list=$(curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -G "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    --data-urlencode "type=$type" --data-urlencode "name=$name" --data-urlencode "per_page=100") || return 1

  mapfile -t ids < <(echo "$list" | jq -r '.result[]?.id // empty')
  rec_id=$(echo "$list" | jq -r --arg content "$content" '.result[]? | select(.content == $content) | .id' | head -n1)
  [[ -z "$rec_id" && "${#ids[@]}" -gt 0 ]] && rec_id="${ids[0]}"

  payload=$(jq -nc --arg type "$type" --arg name "$name" --arg content "$content" --argjson proxied "$proxied" \
    '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied}')

  if [[ -n "$rec_id" ]]; then
    cf_api PATCH "/zones/$CF_ZONE_ID/dns_records/$rec_id" "$payload" >/dev/null
  else
    cf_api POST "/zones/$CF_ZONE_ID/dns_records" "$payload" >/dev/null
  fi

  # This manager owns one record per name/type. Remove duplicates to avoid old
  # IPs staying in Cloudflare and causing direct-domain drift.
  for id in "${ids[@]}"; do
    [[ -n "$id" && "$id" != "$rec_id" ]] || continue
    warn "删除重复 DNS 记录：$type $name id=$id"
    cf_api DELETE "/zones/$CF_ZONE_ID/dns_records/$id" >/dev/null || warn "删除重复 DNS 记录失败：$id"
  done
}

stack_protocols_has(){ [[ "$1" == *"$2"* ]]; }
stack_has_xhttp_reality(){ [[ "$1" == *"1"* ]]; }
stack_has_cdn(){ [[ "$1" == *"2"* || "$1" == *"5"* ]]; }
stack_has_hy2(){ [[ "$1" == *"3"* ]]; }
stack_has_vision(){ [[ "$1" == *"4"* ]]; }
stack_has_direct_protocol(){ [[ "$1" == *"1"* || "$1" == *"3"* || "$1" == *"4"* ]]; }

normalize_stack_protocols(){
  local p="$1" out=""
  p="${p//,/}"; p="${p// /}"
  [[ "$p" == "0" || -z "$p" ]] && { echo "0"; return 0; }
  [[ "$p" == *1* ]] && out="${out}1"
  [[ "$p" == *2* ]] && out="${out}2"
  [[ "$p" == *3* ]] && out="${out}3"
  [[ "$p" == *4* ]] && out="${out}4"
  [[ "$p" == *5* ]] && out="${out}5"
  [[ -z "$out" ]] && out="0"
  echo "$out"
}

select_one_stack_protocols(){
  local label="$1" current="$2" default_mode="$3" mode normalized
  echo >&2
  echo "===== ${label} 协议组合选择 =====" >&2
  echo "0. 不生成 ${label} 节点" >&2
  echo "1. ${label} VLESS + XHTTP + REALITY，直连，默认主力" >&2
  echo "2. ${label} VLESS + XHTTP + TLS + CDN，CDN 隐藏，使用母域名" >&2
  echo "3. ${label} Xray Hysteria2，UDP 高速备用，实验" >&2
  echo "4. ${label} VLESS + REALITY + Vision，可选直连备用" >&2
  echo "5. ${label} VLESS + XHTTP + TLS + CDN 入口扩展，复用 CDN 入站，可配合 BestCF/优选域名/域名前置" >&2
  echo "可以输入组合，例如 123、13、23、1234；直接回车 = 使用方括号里的默认/当前值。" >&2
  mode=$(ask "请选择 ${label} 协议组合（0/1/2/3/4/5 或组合）" "${current:-$default_mode}")
  normalized=$(normalize_stack_protocols "$mode")
  echo "$normalized"
}

build_default_protocols_from_stack_strategy(){
  load_state
  local p=""
  [[ "${IPV4_PROTOCOLS:-0}" == *1* || "${IPV6_PROTOCOLS:-0}" == *1* ]] && p="${p}1"
  [[ "${IPV4_PROTOCOLS:-0}" == *2* || "${IPV6_PROTOCOLS:-0}" == *2* ]] && p="${p}2"
  [[ "${IPV4_PROTOCOLS:-0}" == *3* || "${IPV6_PROTOCOLS:-0}" == *3* ]] && p="${p}3"
  [[ "${IPV4_PROTOCOLS:-0}" == *4* || "${IPV6_PROTOCOLS:-0}" == *4* ]] && p="${p}4"
  [[ "${IPV4_PROTOCOLS:-0}" == *5* || "${IPV6_PROTOCOLS:-0}" == *5* ]] && p="${p}5"
  [[ -z "$p" ]] && p="0"
  echo "$p"
}

select_ip_stack_strategy(){
  load_state
  local ip4 ip6 v4_protos v6_protos default_p
  detect_public_ips
  ip4="${PUBLIC_IPV4:-}"
  ip6="${PUBLIC_IPV6:-}"

  echo
  echo "===== IPv4 / IPv6 独立协议组合 ====="
  echo "IPv4 和 IPv6 各自输入协议组合，例如 IPv4=123，IPv6=13。"
  echo "0=不生成该栈节点；1=XHTTP+REALITY直连；2=XHTTP+TLS+CDN；3=Hysteria2 UDP；4=REALITY+Vision；5=CDN/BestCF入口扩展。"
  echo "直接按回车会使用方括号里的默认/当前值。"

  if [[ -n "$ip4" ]]; then
    v4_protos=$(select_one_stack_protocols "IPv4" "${IPV4_PROTOCOLS:-}" "123")
    save_kv "$STATE_FILE" IPV4_PROTOCOLS "$v4_protos"
  else
    save_kv "$STATE_FILE" IPV4_PROTOCOLS "0"
    warn "未检测到 IPv4，IPv4 协议组合设为 0。"
  fi
  if [[ -n "$ip6" ]]; then
    v6_protos=$(select_one_stack_protocols "IPv6" "${IPV6_PROTOCOLS:-}" "123")
    save_kv "$STATE_FILE" IPV6_PROTOCOLS "$v6_protos"
  else
    save_kv "$STATE_FILE" IPV6_PROTOCOLS "0"
    warn "未检测到 IPv6，IPv6 协议组合设为 0。"
  fi
  default_p=$(build_default_protocols_from_stack_strategy)
  save_kv "$STATE_FILE" PROTOCOLS "$default_p"
  if [[ "$default_p" == *2* || "$default_p" == *5* ]]; then save_kv "$STATE_FILE" ENABLE_CDN "1"; else save_kv "$STATE_FILE" ENABLE_CDN "0"; fi
  log "协议策略已保存：IPv4=${v4_protos:-0} IPv6=${v6_protos:-0} 实际需要=${default_p}"
}

protocol_enabled(){ [[ "${PROTOCOLS:-0}" == *"$1"* ]]; }

select_protocols(){
  load_state
  local p port
  p=$(build_default_protocols_from_stack_strategy)
  save_kv "$STATE_FILE" PROTOCOLS "$p"
  echo "===== 已根据 v4/v6 选择自动生成协议组合 ====="
  echo "IPv4: ${IPV4_PROTOCOLS:-0}"
  echo "IPv6: ${IPV6_PROTOCOLS:-0}"
  echo "实际需要: $p"

  if [[ "$p" == *2* || "$p" == *5* ]]; then
    save_kv "$STATE_FILE" ENABLE_CDN "1"
    port=$(ask "CDN/订阅/伪装站 HTTPS 端口；直接回车使用默认值；只能是 443/2053/2083/2087/2096/8443" "${CDN_PORT:-443}")
    valid_port "$port" || die "端口无效。"
    is_cf_https_port "$port" || die "端口必须是 Cloudflare HTTPS 可代理端口：$CF_HTTPS_PORTS"
    save_kv "$STATE_FILE" CDN_PORT "$port"
    CDN_PORT="$port"
  else
    save_kv "$STATE_FILE" ENABLE_CDN "0"
    port=$(ask "订阅/伪装站 HTTPS 端口；直连-only 也需要提供 /sub；直接回车使用默认值；只能是 443/2053/2083/2087/2096/8443" "${CDN_PORT:-443}")
    valid_port "$port" || die "端口无效。"
    is_cf_https_port "$port" || die "订阅/伪装站端口必须是 Cloudflare HTTPS 可代理端口：$CF_HTTPS_PORTS"
    save_kv "$STATE_FILE" CDN_PORT "$port"
    CDN_PORT="$port"
  fi

  # 协议 5 的意义是 CDN/BestCF 入口扩展。若用户选择 5，则自动开启 BestCF 域名模式；否则 5 会和普通 CDN 节点重复，没有实际意义。
  if [[ "$p" == *5* ]]; then
    if [[ "${BESTCF_ENABLED:-0}" != "1" ]]; then
      save_kv "$STATE_FILE" BESTCF_ENABLED "1"
      save_kv "$STATE_FILE" BESTCF_MODE "domain"
      save_kv "$STATE_FILE" BESTCF_PER_CATEGORY_LIMIT "1"
      save_kv "$STATE_FILE" BESTCF_TOTAL_LIMIT "1"
      warn "检测到协议 5，已自动开启 BestCF：只生成 1 个优选域名节点；生成订阅前会自动拉取数据。"
    fi
  fi

  if [[ "$p" == *1* ]]; then
    port=$(ask "XHTTP + REALITY 直连 TCP 端口；直接回车使用默认值；推荐 2443，不能等于订阅/伪装站 HTTPS 端口 ${CDN_PORT:-443}" "${XHTTP_REALITY_PORT:-2443}")
    valid_port "$port" || die "端口无效。"
    [[ "$port" != "${CDN_PORT:-443}" ]] || die "TCP ${CDN_PORT:-443} 需要留给 Nginx 订阅/伪装站；请把 XHTTP+REALITY 改成 2443 等非 ${CDN_PORT:-443} 端口。HY2 UDP 443 不受影响。"
    save_kv "$STATE_FILE" XHTTP_REALITY_PORT "$port"
  fi

  if [[ "$p" == *4* ]]; then
    port=$(ask "REALITY + Vision 直连 TCP 端口；直接回车使用默认值；推荐 3443，不能等于订阅/伪装站 HTTPS 端口 ${CDN_PORT:-443}" "${REALITY_VISION_PORT:-3443}")
    valid_port "$port" || die "端口无效。"
    [[ "$port" != "${CDN_PORT:-443}" ]] || die "TCP ${CDN_PORT:-443} 需要留给 Nginx 订阅/伪装站；请把 REALITY+Vision 改成 3443 等非 ${CDN_PORT:-443} 端口。HY2 UDP 443 不受影响。"
    save_kv "$STATE_FILE" REALITY_VISION_PORT "$port"
  fi

  if [[ "$p" == *3* ]]; then
    port=$(ask "Hysteria2 UDP 监听端口；直接回车使用默认值；推荐 443；这是 UDP，可与 Nginx TCP 443 共存" "${HY2_PORT:-443}")
    valid_port "$port" || die "端口无效。"
    save_kv "$STATE_FILE" HY2_PORT "$port"
    warn "Xray Hysteria2 是较新功能。如连接失败，优先检查客户端内核、UDP 放行和 Xray 版本。"
  fi

  if [[ "$p" == *1* || "$p" == *2* || "$p" == *3* || "$p" == *4* || "$p" == *5* ]]; then
    detect_public_ips
    echo
    echo "===== 出口策略 ====="
    echo "1. stack：v4 入站走 IPv4 出口，v6 入站走 IPv6 出口（原逻辑）"
    echo "2. force-v4：v4/v6/CDN 入站全部强制 IPv4 出口，适合解决目标站 IPv6 兼容性问题"
    echo "0. none：不写入站到出站路由，交给 Xray 默认 direct"
    local outbound_choice outbound_default
    outbound_default="${IP_OUTBOUND_MODE:-}"
    if [[ -z "$outbound_default" ]]; then
      if [[ "${ENABLE_IP_STACK_BINDING:-1}" == "1" ]]; then outbound_default="stack"; else outbound_default="none"; fi
    fi
    outbound_choice=$(ask "请选择出口策略（1/2/0 或 stack/force-v4/none）" "$outbound_default")
    case "$outbound_choice" in
      1|stack|normal|same-stack)
        save_kv "$STATE_FILE" IP_OUTBOUND_MODE "stack"
        save_kv "$STATE_FILE" ENABLE_IP_STACK_BINDING "1"
        ;;
      2|force-v4|v4|ipv4|all-v4)
        if [[ -n "${PUBLIC_IPV4:-}" ]]; then
          save_kv "$STATE_FILE" IP_OUTBOUND_MODE "force-v4"
          save_kv "$STATE_FILE" ENABLE_IP_STACK_BINDING "1"
        else
          warn "未检测到 IPv4，不能启用 force-v4；已回退到 stack。"
          save_kv "$STATE_FILE" IP_OUTBOUND_MODE "stack"
          save_kv "$STATE_FILE" ENABLE_IP_STACK_BINDING "1"
        fi
        ;;
      0|none|off|no)
        save_kv "$STATE_FILE" IP_OUTBOUND_MODE "none"
        save_kv "$STATE_FILE" ENABLE_IP_STACK_BINDING "0"
        warn "未写入入站到出站路由；监听仍会按 v4/v6 精确绑定。"
        ;;
      *)
        warn "未知出口策略：$outbound_choice，已使用 stack。"
        save_kv "$STATE_FILE" IP_OUTBOUND_MODE "stack"
        save_kv "$STATE_FILE" ENABLE_IP_STACK_BINDING "1"
        ;;
    esac
  fi
  load_state
  log "协议组合：$p"
}
create_dns_records(){
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || configure_base_domain
  [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE_ID:-}" ]] || setup_cloudflare
  local ip4 ip6
  detect_public_ips
  ip4="${PUBLIC_IPV4:-}"
  ip6="${PUBLIC_IPV6:-}"

  if [[ -n "$ip4" ]]; then
    cf_upsert_record "$BASE_DOMAIN" A "$ip4" true
    if stack_has_direct_protocol "${IPV4_PROTOCOLS:-0}"; then cf_upsert_record "v4.$BASE_DOMAIN" A "$ip4" false; fi
  fi
  if [[ -n "$ip6" ]]; then
    cf_upsert_record "$BASE_DOMAIN" AAAA "$ip6" true
    if stack_has_direct_protocol "${IPV6_PROTOCOLS:-0}"; then cf_upsert_record "v6.$BASE_DOMAIN" AAAA "$ip6" false; fi
  fi
  log "DNS 记录处理完成：BASE_DOMAIN 始终用于订阅/伪装站；v4/v6 子域名按直连协议生成。"
}

install_cert_deploy_hook(){
  need_root
  mkdir -p "$(dirname "$CERT_DEPLOY_HOOK")"
  cat > "$CERT_DEPLOY_HOOK" <<'EOF2'
#!/usr/bin/env bash
# Generated by Xray Edge Manager.
# Certbot deploy hook: sync an Xray-readable cert copy, then reload services after tests.
set -u

XRAY_CERT_BASE="/usr/local/etc/xray/certs"
XRAY_CERT_GROUP="xray"

if [[ -n "${RENEWED_LINEAGE:-}" && -d "${RENEWED_LINEAGE:-}" ]]; then
  cert_name="$(basename "$RENEWED_LINEAGE")"
  if getent group "$XRAY_CERT_GROUP" >/dev/null 2>&1; then
    install -d -m 750 -o root -g "$XRAY_CERT_GROUP" "$XRAY_CERT_BASE/$cert_name" 2>/dev/null || true
    install -m 640 -o root -g "$XRAY_CERT_GROUP" "$RENEWED_LINEAGE/fullchain.pem" "$XRAY_CERT_BASE/$cert_name/fullchain.pem" 2>/dev/null || true
    install -m 640 -o root -g "$XRAY_CERT_GROUP" "$RENEWED_LINEAGE/privkey.pem" "$XRAY_CERT_BASE/$cert_name/privkey.pem" 2>/dev/null || true
  fi
fi

if command -v nginx >/dev/null 2>&1; then
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
  fi
fi

if command -v xray >/dev/null 2>&1 && [[ -f /usr/local/etc/xray/config.json ]]; then
  if command -v runuser >/dev/null 2>&1 && id -u xray >/dev/null 2>&1; then
    runuser -u xray -- "$(command -v xray)" run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1
    ok=$?
  else
    xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1
    ok=$?
  fi
  if [[ "$ok" -eq 0 ]]; then
    systemctl restart xray >/dev/null 2>&1 || true
  fi
fi
exit 0
EOF2
  chmod 755 "$CERT_DEPLOY_HOOK"
}

issue_certificate(){
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || configure_base_domain
  [[ -n "${CF_API_TOKEN:-}" ]] || setup_cloudflare
  mkdir -p "$APP_DIR"
  install_cert_deploy_hook
  # SECURITY FIX: set restrictive permissions BEFORE writing sensitive content,
  # eliminating the brief window where the file was world-readable.
  # Also use printf instead of unquoted heredoc to avoid $-expansion bugs.
  # RC10 HARDENING: refuse symlink credential targets before writing secrets.
  [[ ! -L "$CF_CRED" ]] || die "拒绝写入符号链接凭据文件：$CF_CRED"
  touch "$CF_CRED"
  chmod 600 "$CF_CRED"
  printf '%s\n' "dns_cloudflare_api_token = $CF_API_TOKEN" > "$CF_CRED"
  local email
  email=$(ask "请输入证书邮箱，留空则不绑定邮箱" "${CERT_EMAIL:-}")
  email=$(printf '%s' "$email" | tr -d '[:space:]')
  [[ -n "$email" ]] && save_kv "$STATE_FILE" CERT_EMAIL "$email"
  if [[ -n "$email" ]]; then
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CRED" \
      --dns-cloudflare-propagation-seconds 60 -d "$BASE_DOMAIN" -d "*.$BASE_DOMAIN" \
      --agree-tos --non-interactive --email "$email" \
      --deploy-hook "$CERT_DEPLOY_HOOK" || die "证书申请失败。"
  else
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CRED" \
      --dns-cloudflare-propagation-seconds 60 -d "$BASE_DOMAIN" -d "*.$BASE_DOMAIN" \
      --agree-tos --non-interactive --register-unsafely-without-email \
      --deploy-hook "$CERT_DEPLOY_HOOK" || die "证书申请失败。"
  fi
  sync_xray_certificate
  log "证书申请完成：/etc/letsencrypt/live/$BASE_DOMAIN/"
}

choose_reality_target(){
  load_state
  local c target
  echo "推荐 REALITY target："
  echo "1. www.microsoft.com，通用"
  echo "2. www.oracle.com，Oracle 节点可选"
  echo "3. aws.amazon.com，AWS 节点可选"
  echo "4. 手动输入"
  c=$(ask "请选择" "1")
  case "$c" in
    1) target="www.microsoft.com" ;;
    2) target="www.oracle.com" ;;
    3) target="aws.amazon.com" ;;
    *) target=$(ask "请输入 REALITY target 域名" "${REALITY_TARGET:-www.microsoft.com}") ;;
  esac
  target=$(printf '%s' "$target" | tr -d '[:space:]')

  # HARDENING: REALITY target is later embedded into generated JSON and
  # subscription links. Keep it as a normal hostname to avoid broken configs
  # from quotes, slashes, ports, spaces, or other accidental characters.
  while ! validate_hostname "$target"; do
    warn "REALITY target 域名格式不合格：$target"
    target=$(ask "请重新输入 REALITY target 域名，例如 www.microsoft.com" "www.microsoft.com")
    target=$(printf '%s' "$target" | tr -d '[:space:]')
  done

  save_kv "$STATE_FILE" REALITY_TARGET "$target"
  log "REALITY target: $target"
}

validate_x25519_key(){
  local k="$1"
  [[ "$k" =~ ^[A-Za-z0-9_-]{40,80}$ ]]
}

generate_keys_if_needed(){
  load_state
  command -v xray >/dev/null 2>&1 || die "请先安装 Xray。"
  [[ -n "${UUID:-}" ]] || save_kv "$STATE_FILE" UUID "$(xray uuid)"
  if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
    local raw_output priv pub first_candidate second_candidate
    raw_output=$(NO_COLOR=1 xray x25519 2>&1 | sed -r 's/\x1B\[[0-9;]*[mK]//g' | tr -d '\r' || true)

    # Prefer semantic labels, because xray output wording is more stable than line numbers.
    priv=$(printf '%s\n' "$raw_output" | grep -iE 'Private[ _-]?key|PrivateKey|Seed' | awk -F':' '{print $2}' | tr -d '[:space:]' | head -n1)
    pub=$(printf '%s\n' "$raw_output" | grep -iE 'Public[ _-]?key|PublicKey|Password|Client' | awk -F':' '{print $2}' | tr -d '[:space:]' | head -n1)

    # Fallback: extract the first two base64url-looking tokens if labels change.
    if ! validate_x25519_key "${priv:-}" || ! validate_x25519_key "${pub:-}"; then
      first_candidate=$(printf '%s\n' "$raw_output" | grep -Eo '[A-Za-z0-9_-]{40,80}' | sed -n '1p' || true)
      second_candidate=$(printf '%s\n' "$raw_output" | grep -Eo '[A-Za-z0-9_-]{40,80}' | sed -n '2p' || true)
      priv="${first_candidate:-$priv}"
      pub="${second_candidate:-$pub}"
    fi

    if ! validate_x25519_key "${priv:-}" || ! validate_x25519_key "${pub:-}"; then
      err "xray x25519 输出无法可靠解析或密钥长度异常。脱色后的原始输出如下："
      printf '%s\n' "$raw_output" >&2
      die "REALITY 密钥生成失败。请手动执行：xray x25519，并检查 Xray 版本。"
    fi
    save_kv "$STATE_FILE" REALITY_PRIVATE_KEY "$priv"
    save_kv "$STATE_FILE" REALITY_PUBLIC_KEY "$pub"
  fi
  [[ -n "${SHORT_ID:-}" ]] || save_kv "$STATE_FILE" SHORT_ID "$(rand_hex 8)"
  [[ -n "${XHTTP_REALITY_PATH:-}" ]] || save_kv "$STATE_FILE" XHTTP_REALITY_PATH "$(rand_path)"
  [[ -n "${XHTTP_CDN_PATH:-}" ]] || save_kv "$STATE_FILE" XHTTP_CDN_PATH "$(rand_path)"
  [[ -n "${HY2_AUTH:-}" ]] || save_kv "$STATE_FILE" HY2_AUTH "$(rand_hex 16)"
  [[ -n "${SUB_TOKEN:-}" ]] || save_kv "$STATE_FILE" SUB_TOKEN "$(rand_token)"
  [[ -n "${MERGED_SUB_TOKEN:-}" ]] || save_kv "$STATE_FILE" MERGED_SUB_TOKEN "$(rand_token)"
  [[ -n "${XHTTP_CDN_LOCAL_PORT:-}" ]] || save_kv "$STATE_FILE" XHTTP_CDN_LOCAL_PORT "31301"
  load_state
  # SECURITY FIX: validate tokens; auto-regenerate if format is invalid
  # (32-128 char hex; old installs keep 32, new installs default to 64).
  validate_or_regen_token SUB_TOKEN
  validate_or_regen_token MERGED_SUB_TOKEN
}

backup_configs(){
  mkdir -p "$APP_DIR" "$SUB_DIR" "$BESTCF_DIR" "$BACKUP_DIR"
  local ts; ts=$(date +%F-%H%M%S)
  [[ -f "$XRAY_CONFIG" ]] && cp -a "$XRAY_CONFIG" "$BACKUP_DIR/config.json.$ts.bak" && save_kv "$STATE_FILE" LAST_XRAY_BACKUP "$BACKUP_DIR/config.json.$ts.bak" || true
  [[ -f "$NGINX_SITE" ]] && cp -a "$NGINX_SITE" "$BACKUP_DIR/nginx.$ts.bak" && save_kv "$STATE_FILE" LAST_NGINX_BACKUP "$BACKUP_DIR/nginx.$ts.bak" || true
  [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$BACKUP_DIR/state.env.$ts.bak" || true
  # IMPROVEMENT: rotate old backups, keeping only the most recent 10 of each type.
  local pattern count
  local _bak_files
  for pattern in "config.json.*.bak" "nginx.*.bak" "state.env.*.bak"; do
    mapfile -t _bak_files < <(ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null || true)
    if [[ "${#_bak_files[@]}" -gt 10 ]]; then
      rm -f -- "${_bak_files[@]:10}" 2>/dev/null || true
    fi
  done
}

atomic_copy_into_place(){
  local src="$1" dst="$2" dir base tmp
  [[ -f "$src" ]] || return 1
  dir=$(dirname "$dst")
  base=$(basename "$dst")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp_file "$dir/.${base}.restore.XXXXXX") || return 1
  cp -a "$src" "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dst"
}

atomic_move_into_place(){
  local src="$1" dst="$2" mode="${3:-}" dir src_dir dst_dir
  [[ -f "$src" ]] || die "原子替换源文件不存在：$src"
  dir=$(dirname "$dst")
  mkdir -p "$dir"
  src_dir=$(cd "$(dirname "$src")" && pwd -P)
  dst_dir=$(cd "$dir" && pwd -P)
  [[ "$src_dir" == "$dst_dir" ]] || die "原子替换要求临时文件与目标文件位于同一目录。"
  [[ -n "$mode" ]] && chmod "$mode" "$src" 2>/dev/null || true
  mv -f "$src" "$dst"
}

restore_latest_xray_config(){
  load_state
  local bak="${LAST_XRAY_BACKUP:-}"
  [[ -n "$bak" && -f "$bak" ]] || bak=$(ls -1t "$BACKUP_DIR"/config.json.*.bak 2>/dev/null | head -n1 || true)
  [[ -n "$bak" && -f "$bak" ]] || { warn "未找到可回滚的 Xray 配置备份。"; return 1; }
  atomic_copy_into_place "$bak" "$XRAY_CONFIG" || { warn "Xray 配置回滚失败：$bak -> $XRAY_CONFIG"; return 1; }
  warn "已原子回滚 Xray 配置：$bak -> $XRAY_CONFIG"
}

restore_latest_nginx_config(){
  load_state
  local bak="${LAST_NGINX_BACKUP:-}"
  [[ -n "$bak" && -f "$bak" ]] || bak=$(ls -1t "$BACKUP_DIR"/nginx.*.bak 2>/dev/null | head -n1 || true)
  [[ -n "$bak" && -f "$bak" ]] || { warn "未找到可回滚的 Nginx 配置备份。"; return 1; }
  atomic_copy_into_place "$bak" "$NGINX_SITE" || { warn "Nginx 配置回滚失败：$bak -> $NGINX_SITE"; return 1; }
  warn "已原子回滚 Nginx 配置：$bak -> $NGINX_SITE"
}

get_proc_tcp(){ get_proc_by_port -t "$1" || true; }
get_proc_udp(){ get_proc_by_port -u "$1" || true; }

preflight_ports(){
  load_state
  info "端口预检..."
  local p proc sub_port="${CDN_PORT:-443}"
  p="$sub_port"; proc=$(get_proc_tcp "$p")
  [[ -z "$proc" || "$proc" == *nginx* ]] || die "TCP $p 是订阅/伪装站 HTTPS 端口，但已被非 Nginx 进程占用：$proc"
  if protocol_enabled 1; then
    p="${XHTTP_REALITY_PORT:-2443}"; proc=$(get_proc_tcp "$p")
    [[ "$p" != "$sub_port" ]] || die "TCP $p 冲突：订阅/伪装站由 Nginx 使用；XHTTP+REALITY 请改用 2443 等其它 TCP 端口。HY2 UDP 443 不受影响。"
    [[ -z "$proc" || "$proc" == *xray* ]] || die "TCP $p 被非 Xray 进程占用：$proc"
  fi
  if protocol_enabled 2 || protocol_enabled 5; then
    p="${XHTTP_CDN_LOCAL_PORT:-31301}"; proc=$(get_proc_tcp "$p")
    [[ -z "$proc" || "$proc" == *xray* ]] || die "TCP $p 是 XHTTP CDN 本地回源端口，但已被非 Xray 进程占用：$proc"
  fi
  if protocol_enabled 4; then
    p="${REALITY_VISION_PORT:-3443}"; proc=$(get_proc_tcp "$p")
    [[ "$p" != "$sub_port" ]] || die "TCP $p 冲突：订阅/伪装站由 Nginx 使用；REALITY+Vision 请改用 3443 等其它 TCP 端口。HY2 UDP 443 不受影响。"
    [[ -z "$proc" || "$proc" == *xray* ]] || die "TCP $p 被非 Xray 进程占用：$proc"
  fi
  if protocol_enabled 3; then
    p="${HY2_PORT:-443}"; proc=$(get_proc_udp "$p")
    [[ -z "$proc" || "$proc" == *xray* ]] || die "UDP $p 被非 Xray 进程占用：$proc"
  fi
  log "端口预检通过。"
}

append_json_obj(){
  local file="$1" first_ref="$2"
  if [[ "${!first_ref}" -eq 0 ]]; then echo "," >> "$file"; fi
  cat >> "$file"
  printf -v "$first_ref" 0
}

normalize_ip_outbound_mode(){
  local mode="${1:-}"
  if [[ -z "$mode" ]]; then
    if [[ "${ENABLE_IP_STACK_BINDING:-1}" == "1" ]]; then mode="stack"; else mode="none"; fi
  fi
  case "$mode" in
    1|stack|normal|same-stack) echo "stack" ;;
    2|force-v4|v4|ipv4|all-v4) echo "force-v4" ;;
    0|none|off|no) echo "none" ;;
    *) echo "stack" ;;
  esac
}

outbound_tag_for_stack(){
  local stack="$1" mode="$2"
  case "$mode" in
    force-v4)
      echo "out-v4"
      ;;
    stack)
      case "$stack" in
        v4) echo "out-v4" ;;
        v6) echo "out-v6" ;;
        cdn)
          if [[ -n "${bind_ip4:-}" ]]; then echo "out-v4"; elif [[ -n "${bind_ip6:-}" ]]; then echo "out-v6"; fi
          ;;
      esac
      ;;
    none)
      echo ""
      ;;
  esac
}

append_route_for_inbound(){
  local file="$1" first_ref="$2" inbound="$3" stack="$4" mode="$5" out
  out="$(outbound_tag_for_stack "$stack" "$mode")"
  [[ -n "$out" ]] || return 0
  append_json_obj "$file" "$first_ref" <<EOF2
    {"type":"field","inboundTag":["${inbound}"],"outboundTag":"${out}"}
EOF2
}

generate_xray_config(){
  need_root
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || configure_base_domain
  [[ -n "${REALITY_TARGET:-}" ]] || choose_reality_target
  generate_keys_if_needed
  load_state
  preflight_ports
  backup_configs
  ensure_xray_user
  install -d -m 755 /usr/local/etc/xray
  install -d -m 755 -o "$XRAY_USER" -g "$XRAY_GROUP" /var/log/xray

  local in_tmp out_tmp route_tmp xray_target_tmp first_in=1 first_out=1 first_route=1 ip4 ip6 bind_ip4="" bind_ip6="" bind outbound_mode
  local v4_xhttp_ready=0 v6_xhttp_ready=0 v4_hy2_ready=0 v6_hy2_ready=0 v4_vision_ready=0 v6_vision_ready=0 cdn_xhttp_ready=0
  in_tmp=$(mktemp_file "$APP_DIR/tmp/xray-in.XXXXXX"); out_tmp=$(mktemp_file "$APP_DIR/tmp/xray-out.XXXXXX"); route_tmp=$(mktemp_file "$APP_DIR/tmp/xray-route.XXXXXX")
  detect_public_ips
  ip4="${PUBLIC_IPV4:-}"; ip6="${PUBLIC_IPV6:-}"
  [[ -n "$ip4" ]] && bind_ip4=$(local_ipv4_for_bind "$ip4") && save_kv "$STATE_FILE" BIND_IPV4 "$bind_ip4"
  [[ -n "$ip6" ]] && bind_ip6=$(local_ipv6_for_bind "$ip6") && save_kv "$STATE_FILE" BIND_IPV6 "$bind_ip6"
  outbound_mode="$(normalize_ip_outbound_mode "${IP_OUTBOUND_MODE:-}")"
  if [[ "$outbound_mode" == "force-v4" && -z "$bind_ip4" ]]; then
    warn "已选择 force-v4，但本机未检测到可用 IPv4，自动回退到 stack。"
    outbound_mode="stack"
  fi
  bind="${ENABLE_IP_STACK_BINDING:-1}"
  [[ "$outbound_mode" != "none" ]] && bind="1"
  protocol_enabled 3 && sync_xray_certificate

  if [[ "$outbound_mode" == "force-v4" && -n "$bind_ip4" && "$bind_ip4" != "0.0.0.0" ]]; then
    append_json_obj "$out_tmp" first_out <<EOF2
    {"tag":"direct","protocol":"freedom","sendThrough":"${bind_ip4}","settings":{"domainStrategy":"UseIPv4"}}
EOF2
  elif [[ "$outbound_mode" == "force-v4" ]]; then
    append_json_obj "$out_tmp" first_out <<'EOF2'
    {"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIPv4"}}
EOF2
  else
    append_json_obj "$out_tmp" first_out <<'EOF2'
    {"tag":"direct","protocol":"freedom"}
EOF2
  fi
  append_json_obj "$out_tmp" first_out <<'EOF2'
    {"tag":"block","protocol":"blackhole"}
EOF2
  if [[ "$bind" == "1" && -n "$bind_ip4" && "$bind_ip4" != "0.0.0.0" ]]; then
    append_json_obj "$out_tmp" first_out <<EOF2
    {"tag":"out-v4","protocol":"freedom","sendThrough":"${bind_ip4}","settings":{"domainStrategy":"UseIPv4"}}
EOF2
  else
    append_json_obj "$out_tmp" first_out <<'EOF2'
    {"tag":"out-v4","protocol":"freedom","settings":{"domainStrategy":"UseIPv4"}}
EOF2
  fi
  if [[ "$bind" == "1" && -n "$bind_ip6" ]]; then
    append_json_obj "$out_tmp" first_out <<EOF2
    {"tag":"out-v6","protocol":"freedom","sendThrough":"${bind_ip6}","settings":{"domainStrategy":"UseIPv6"}}
EOF2
  else
    append_json_obj "$out_tmp" first_out <<'EOF2'
    {"tag":"out-v6","protocol":"freedom","settings":{"domainStrategy":"UseIPv6"}}
EOF2
  fi

  # Zero-trust default: block access to private/local networks before per-inbound routing rules.
  append_json_obj "$route_tmp" first_route <<'EOF2'
    {"type":"field","ip":["geoip:private","0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.168.0.0/16","198.18.0.0/15","224.0.0.0/4","::/128","::1/128","fc00::/7","fe80::/10","2001:db8::/32"],"outboundTag":"block"}
EOF2

  if protocol_enabled 1; then
    if [[ -n "$bind_ip4" && "${IPV4_PROTOCOLS:-0}" == *1* ]]; then
      append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-v4-xhttp-reality","listen":"${bind_ip4}","port":${XHTTP_REALITY_PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}","email":"v4-xhttp-reality"}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"reality","xhttpSettings":{"path":"${XHTTP_REALITY_PATH}","mode":"auto"},"realitySettings":{"show":false,"dest":"${REALITY_TARGET}:443","serverNames":["${REALITY_TARGET}"],"privateKey":"${REALITY_PRIVATE_KEY}","shortIds":["${SHORT_ID}"]}}}
EOF2
      v4_xhttp_ready=1
      [[ "$bind" == "1" ]] && append_route_for_inbound "$route_tmp" first_route "in-v4-xhttp-reality" "v4" "$outbound_mode"
    fi
    if [[ -n "$bind_ip6" && "${IPV6_PROTOCOLS:-0}" == *1* ]]; then
      append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-v6-xhttp-reality","listen":"${bind_ip6}","port":${XHTTP_REALITY_PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}","email":"v6-xhttp-reality"}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"reality","xhttpSettings":{"path":"${XHTTP_REALITY_PATH}","mode":"auto"},"realitySettings":{"show":false,"dest":"${REALITY_TARGET}:443","serverNames":["${REALITY_TARGET}"],"privateKey":"${REALITY_PRIVATE_KEY}","shortIds":["${SHORT_ID}"]}}}
EOF2
      v6_xhttp_ready=1
      [[ "$bind" == "1" ]] && append_route_for_inbound "$route_tmp" first_route "in-v6-xhttp-reality" "v6" "$outbound_mode"
    fi
  fi

  if protocol_enabled 2 || protocol_enabled 5; then
    append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-xhttp-cdn-local","listen":"127.0.0.1","port":${XHTTP_CDN_LOCAL_PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}","email":"xhttp-cdn"}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"path":"${XHTTP_CDN_PATH}","mode":"auto"}}}
EOF2
    cdn_xhttp_ready=1
    [[ "$bind" == "1" ]] && append_route_for_inbound "$route_tmp" first_route "in-xhttp-cdn-local" "cdn" "$outbound_mode"
  fi

  if protocol_enabled 3; then
    if [[ -n "$bind_ip4" && "${IPV4_PROTOCOLS:-0}" == *3* ]]; then
      append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-v4-hysteria2-udp","listen":"${bind_ip4}","port":${HY2_PORT},"protocol":"hysteria","settings":{"version":2,"clients":[{"auth":"${HY2_AUTH}","email":"v4-hy2"}]},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"alpn":["h3"],"certificates":[{"certificateFile":"${XRAY_CERT_DIR}/${BASE_DOMAIN}/fullchain.pem","keyFile":"${XRAY_CERT_DIR}/${BASE_DOMAIN}/privkey.pem"}]},"hysteriaSettings":{"version":2,"auth":"${HY2_AUTH}","udpIdleTimeout":60}}}
EOF2
      v4_hy2_ready=1
      [[ "$bind" == "1" ]] && append_route_for_inbound "$route_tmp" first_route "in-v4-hysteria2-udp" "v4" "$outbound_mode"
    fi
    if [[ -n "$bind_ip6" && "${IPV6_PROTOCOLS:-0}" == *3* ]]; then
      append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-v6-hysteria2-udp","listen":"${bind_ip6}","port":${HY2_PORT},"protocol":"hysteria","settings":{"version":2,"clients":[{"auth":"${HY2_AUTH}","email":"v6-hy2"}]},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"alpn":["h3"],"certificates":[{"certificateFile":"${XRAY_CERT_DIR}/${BASE_DOMAIN}/fullchain.pem","keyFile":"${XRAY_CERT_DIR}/${BASE_DOMAIN}/privkey.pem"}]},"hysteriaSettings":{"version":2,"auth":"${HY2_AUTH}","udpIdleTimeout":60}}}
EOF2
      v6_hy2_ready=1
      [[ "$bind" == "1" ]] && append_route_for_inbound "$route_tmp" first_route "in-v6-hysteria2-udp" "v6" "$outbound_mode"
    fi
  fi

  if protocol_enabled 4; then
    if [[ -n "$bind_ip4" && "${IPV4_PROTOCOLS:-0}" == *4* ]]; then
      append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-v4-reality-vision","listen":"${bind_ip4}","port":${REALITY_VISION_PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision","email":"v4-reality-vision"}],"decryption":"none"},"streamSettings":{"network":"raw","security":"reality","realitySettings":{"show":false,"dest":"${REALITY_TARGET}:443","serverNames":["${REALITY_TARGET}"],"privateKey":"${REALITY_PRIVATE_KEY}","shortIds":["${SHORT_ID}"]}}}
EOF2
      v4_vision_ready=1
      [[ "$bind" == "1" ]] && append_route_for_inbound "$route_tmp" first_route "in-v4-reality-vision" "v4" "$outbound_mode"
    fi
    if [[ -n "$bind_ip6" && "${IPV6_PROTOCOLS:-0}" == *4* ]]; then
      append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-v6-reality-vision","listen":"${bind_ip6}","port":${REALITY_VISION_PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision","email":"v6-reality-vision"}],"decryption":"none"},"streamSettings":{"network":"raw","security":"reality","realitySettings":{"show":false,"dest":"${REALITY_TARGET}:443","serverNames":["${REALITY_TARGET}"],"privateKey":"${REALITY_PRIVATE_KEY}","shortIds":["${SHORT_ID}"]}}}
EOF2
      v6_vision_ready=1
      [[ "$bind" == "1" ]] && append_route_for_inbound "$route_tmp" first_route "in-v6-reality-vision" "v6" "$outbound_mode"
    fi
  fi

  xray_target_tmp=$(mktemp_file "$(dirname "$XRAY_CONFIG")/.config.XXXXXX.json")
  cat > "$xray_target_tmp" <<EOF2
{
  "log":{"loglevel":"warning","access":"none","error":"/var/log/xray/error.log"},
  "inbounds":[
$(cat "$in_tmp")
  ],
  "outbounds":[
$(cat "$out_tmp")
  ],
  "routing":{"domainStrategy":"AsIs","rules":[
$(cat "$route_tmp")
  ]}
}
EOF2
  chmod 640 "$xray_target_tmp" 2>/dev/null || true
  chown root:"$XRAY_GROUP" "$xray_target_tmp" 2>/dev/null || true
  rm -f "$in_tmp" "$out_tmp" "$route_tmp"

  # Do not overwrite the live Xray config until the candidate has passed all checks.
  # The temp file is created in the same directory as the target so mv is atomic.
  if ! jq empty "$xray_target_tmp" >/dev/null 2>&1; then
    local ts debug_conf
    ts=$(date +%F-%H%M%S)
    mkdir -p "$DEBUG_DIR"; chmod 700 "$DEBUG_DIR" 2>/dev/null || true
    debug_conf="$DEBUG_DIR/failed-xray-json.$ts.json"
    cp -f "$xray_target_tmp" "$debug_conf" 2>/dev/null || true
    chmod 600 "$debug_conf" 2>/dev/null || true
    err "生成的 Xray JSON 非法，已阻断更新，生产配置未被覆盖。"
    err "失败配置已保存：$debug_conf"
    die "请把该文件中的敏感字段脱敏后再发给别人审查。"
  fi

  local xray_test_log
  xray_test_log=$(mktemp_file "$(dirname "$XRAY_CONFIG")/.xray-test.XXXXXX.log")
  if ! xray_test_config "$xray_target_tmp" >"$xray_test_log" 2>&1; then
    local ts debug_conf debug_log
    ts=$(date +%F-%H%M%S)
    mkdir -p "$DEBUG_DIR"; chmod 700 "$DEBUG_DIR" 2>/dev/null || true
    debug_conf="$DEBUG_DIR/failed-xray-config.$ts.json"
    debug_log="$DEBUG_DIR/failed-xray-test.$ts.log"
    cp -f "$xray_target_tmp" "$debug_conf" 2>/dev/null || true
    cp -f "$xray_test_log" "$debug_log" 2>/dev/null || true
    chmod 600 "$debug_conf" "$debug_log" 2>/dev/null || true
    err "Xray 临时配置测试失败，已阻断更新，生产配置未被覆盖。"
    err "Xray 原始报错如下："
    sed -n '1,160p' "$xray_test_log" >&2 || true
    err "失败配置已保存：$debug_conf"
    err "测试日志已保存：$debug_log"
    die "请优先根据上面的原始报错定位；注意失败配置里含 UUID/REALITY 私钥等敏感信息。"
  fi
  atomic_move_into_place "$xray_target_tmp" "$XRAY_CONFIG" "640"
  chown root:"$XRAY_GROUP" "$XRAY_CONFIG" 2>/dev/null || true
  save_kv "$STATE_FILE" V4_XHTTP_REALITY_READY "$v4_xhttp_ready"
  save_kv "$STATE_FILE" V6_XHTTP_REALITY_READY "$v6_xhttp_ready"
  save_kv "$STATE_FILE" V4_HY2_READY "$v4_hy2_ready"
  save_kv "$STATE_FILE" V6_HY2_READY "$v6_hy2_ready"
  save_kv "$STATE_FILE" V4_VISION_READY "$v4_vision_ready"
  save_kv "$STATE_FILE" V6_VISION_READY "$v6_vision_ready"
  save_kv "$STATE_FILE" CDN_XHTTP_READY "$cdn_xhttp_ready"
  log "Xray 配置生成、测试并原子化应用成功。"
}


disable_nginx_packaged_default_site(){
  mkdir -p "$BACKUP_DIR"
  local f ts backup
  # Debian/Ubuntu nginx packages commonly ship /etc/nginx/sites-enabled/default
  # with "listen 80 default_server". Our generated sinkhole also needs to own
  # the default_server slot; otherwise nginx -t fails with duplicate default.
  for f in /etc/nginx/sites-enabled/default; do
    [[ -e "$f" || -L "$f" ]] || continue
    ts=$(date +%F-%H%M%S)
    backup="$BACKUP_DIR/nginx-packaged-default.$ts.bak"
    cp -a "$f" "$backup" 2>/dev/null || true
    rm -f "$f"
    warn "已备份并禁用 Nginx 包默认站点，避免 default_server 冲突：$f -> $backup"
  done
}

cleanup_legacy_nginx_conf(){
  mkdir -p "$BACKUP_DIR"
  if [[ -f "$LEGACY_NGINX_SITE" ]]; then
    cp -a "$LEGACY_NGINX_SITE" "$BACKUP_DIR/xray-anti-block.conf.legacy.$(date +%F-%H%M%S).bak" 2>/dev/null || true
    rm -f "$LEGACY_NGINX_SITE"
    warn "检测到旧版 Nginx 配置，已备份并移除：$LEGACY_NGINX_SITE"
  fi
}

install_random_camouflage(){
  mkdir -p /var/www "$WEB_ROOT"
  local n zip tmp ok=0
  n=$((RANDOM % 9 + 1))
  zip="html${n}.zip"
  tmp=$(mktemp_dir "$APP_DIR/tmp/camouflage.XXXXXX")
  info "随机下载伪装站模板：v2ray-agent/fodder/blog/unable/${zip}"
  if curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 60 -o "$tmp/$zip" "$FODDER_BASE_URL/$zip" 2>/dev/null; then
    # SECURITY: reject zip entries with absolute paths or path traversal.
    if unzip -Z1 "$tmp/$zip" 2>/dev/null | grep -qE '(^/|(^|/)\.\.(/|$))'; then
      warn "伪装站 zip 包含危险路径，已拒绝解压：${zip}"
    elif unzip -q "$tmp/$zip" -d "$tmp/site" 2>/dev/null; then
      # SECURITY: preserve /sub to avoid breaking live subscription links.
      find "$WEB_ROOT" -mindepth 1 -maxdepth 1 ! -name sub -exec rm -rf -- {} +
      shopt -s dotglob nullglob
      local entries=("$tmp/site"/*)
      if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
        cp -a "${entries[0]}"/* "$WEB_ROOT"/
      else
        cp -a "$tmp/site"/* "$WEB_ROOT"/
      fi
      shopt -u dotglob nullglob
      # SECURITY: remove any symlinks copied from the zip.
      find "$WEB_ROOT" -path "$WEB_ROOT/sub" -prune -o -type l -delete 2>/dev/null || true
      [[ -f "$WEB_ROOT/index.html" ]] || echo '<!doctype html><html><body><h1>Welcome</h1><p>It works.</p></body></html>' > "$WEB_ROOT/index.html"
      log "伪装站模板已安装：${zip}"
      ok=1
    fi
  fi
  if [[ "$ok" -eq 0 ]]; then
    warn "伪装站模板下载或解压失败，使用内置默认页面。"
    cat > "$WEB_ROOT/index.html" <<'EOF2'
<!doctype html><html><head><meta charset="utf-8"><title>Welcome</title></head><body><h1>Welcome</h1><p>It works.</p></body></html>
EOF2
  fi
  rm -rf "$tmp"
  # RC10 HARDENING: publish the camouflage site, but never loosen /sub.
  find "$WEB_ROOT" -path "$WEB_ROOT/sub" -prune -o -type d -exec chmod 755 {} + 2>/dev/null || true
  find "$WEB_ROOT" -path "$WEB_ROOT/sub/*" -prune -o -type f -exec chmod 644 {} + 2>/dev/null || true
  ensure_web_subscription_permissions
}

configure_nginx(){
  need_root
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || configure_base_domain
  [[ -f "/etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem" ]] || issue_certificate
  generate_keys_if_needed
  load_state
  mkdir -p "$APP_DIR" "$SUB_DIR" "$BESTCF_DIR" "$BACKUP_DIR"
  cleanup_legacy_nginx_conf
  disable_nginx_packaged_default_site
  mkdir -p "$WEB_ROOT" "$WEB_ROOT/sub" "$SUB_DIR"
  touch "$WEB_ROOT/sub/${SUB_TOKEN}"
  ensure_web_subscription_permissions

  local nginx_http_v6_listen="" nginx_https_v6_listen="" nginx_https_listen="" nginx_http2_directive="" nginx_version="" nginx_target_tmp=""
  local nginx_default_http_v6_listen="" nginx_default_https_v6_listen="" nginx_default_https_block=""
  local nginx_http_redirect="" xhttp_cdn_location="" cdn_ipv6_enabled=0

  detect_public_ips
  if [[ -n "${PUBLIC_IPV6:-}" ]]; then
    cdn_ipv6_enabled=1
    nginx_http_v6_listen="    listen [::]:80;"
    nginx_default_http_v6_listen="    listen [::]:80 default_server;"
  fi

  if [[ "${CDN_PORT:-443}" == "443" ]]; then
    nginx_http_redirect="https://\$host\$request_uri"
  else
    nginx_http_redirect="https://\$host:${CDN_PORT:-443}\$request_uri"
  fi

  if protocol_enabled 2 || protocol_enabled 5; then
    xhttp_cdn_location=$(cat <<EOF2
    location ^~ ${XHTTP_CDN_PATH} {
        access_log off;
        proxy_pass http://127.0.0.1:${XHTTP_CDN_LOCAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 0;
    }

EOF2
)
  fi

  nginx_version=$(nginx -v 2>&1 | sed -nE 's#.*nginx/([0-9.]+).*#\1#p' | head -n1 || true)
  if version_ge "$nginx_version" "1.25.1"; then
    nginx_https_listen="    listen ${CDN_PORT:-443} ssl;"
    nginx_http2_directive="    http2 on;"
    [[ "$cdn_ipv6_enabled" == "1" ]] && nginx_https_v6_listen="    listen [::]:${CDN_PORT:-443} ssl;"
    [[ "$cdn_ipv6_enabled" == "1" ]] && nginx_default_https_v6_listen="    listen [::]:${CDN_PORT:-443} ssl default_server;"
    info "Nginx ${nginx_version:-unknown}：使用新版 HTTP/2 写法。"
  else
    # Older Nginx does not understand the standalone "http2 on;" directive.
    # If dpkg is unavailable, version_ge falls back to sort -V; if both are unavailable,
    # use the older syntax and let nginx -t be the final gatekeeper.
    nginx_https_listen="    listen ${CDN_PORT:-443} ssl http2;"
    nginx_http2_directive=""
    [[ "$cdn_ipv6_enabled" == "1" ]] && nginx_https_v6_listen="    listen [::]:${CDN_PORT:-443} ssl http2;"
    [[ "$cdn_ipv6_enabled" == "1" ]] && nginx_default_https_v6_listen="    listen [::]:${CDN_PORT:-443} ssl default_server;"
    info "Nginx ${nginx_version:-unknown}：使用兼容旧版的 HTTP/2 写法。"
  fi

  # HARDENING: sinkhole unexpected Host/SNI and direct-IP scans before the real
  # camouflage/server block. On Nginx >= 1.19.4, reject TLS handshakes without
  # presenting the real certificate. Older Nginx falls back to 444 after TLS.
  if version_ge "$nginx_version" "1.19.4"; then
    nginx_default_https_block="server {
    listen ${CDN_PORT:-443} ssl default_server;
${nginx_default_https_v6_listen}
    server_name _;
    ssl_reject_handshake on;
}
"
  else
    nginx_default_https_block="server {
    listen ${CDN_PORT:-443} ssl default_server;
${nginx_default_https_v6_listen}
    server_name _;
    ssl_certificate /etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    return 444;
}
"
  fi

  backup_configs
  install_random_camouflage

  nginx_target_tmp=$(mktemp_file "$(dirname "$NGINX_SITE")/.xray-edge-manager.conf.XXXXXX")
  cat > "$nginx_target_tmp" <<EOF2
server {
    listen 80 default_server;
${nginx_default_http_v6_listen}
    server_name _;
    return 444;
}

${nginx_default_https_block}
server {
    listen 80;
${nginx_http_v6_listen}
    server_name ${BASE_DOMAIN};
    return 301 ${nginx_http_redirect};
}

server {
${nginx_https_listen}
${nginx_http2_directive}
${nginx_https_v6_listen}
    server_name ${BASE_DOMAIN};
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root ${WEB_ROOT};
    index index.html;
    autoindex off;

${xhttp_cdn_location}

    location ^~ /sub/ {
        access_log off;
        default_type text/plain;
        add_header Cache-Control "no-store, no-cache, max-age=0" always;
        add_header Pragma "no-cache" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
        root ${WEB_ROOT};
        limit_except GET {
            deny all;
        }
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF2
  [[ -s "$nginx_target_tmp" ]] || die "生成的 Nginx 临时配置为空，已阻断更新。"
  grep -qF "server_name ${BASE_DOMAIN};" "$nginx_target_tmp" || die "Nginx 临时配置缺少 server_name，已阻断更新。"
  if protocol_enabled 2 || protocol_enabled 5; then
    grep -qF "proxy_pass http://127.0.0.1:${XHTTP_CDN_LOCAL_PORT};" "$nginx_target_tmp" || die "Nginx 临时配置缺少 XHTTP proxy_pass，已阻断更新。"
  fi
  grep -qE "ssl_reject_handshake on;|return 444;" "$nginx_target_tmp" || die "Nginx 临时配置缺少默认黑洞，已阻断更新。"

  # Nginx cannot safely test a non-included *.tmp site file in the live include tree.
  # Apply the fully-written candidate atomically, then immediately run nginx -t and
  # atomically roll back if the whole Nginx config tree rejects it.
  atomic_move_into_place "$nginx_target_tmp" "$NGINX_SITE" "644"
  if ! nginx -t; then
    restore_latest_nginx_config || true
    nginx -t >/dev/null 2>&1 || warn "Nginx 回滚后配置测试仍失败，请人工检查 /etc/nginx 配置。"
    die "Nginx 配置测试失败，已尝试原子回滚。"
  fi
  systemctl enable nginx >/dev/null 2>&1 || true
  if ! systemctl reload nginx && ! systemctl restart nginx; then restore_latest_nginx_config || true; die "Nginx reload/restart 失败，已回滚。"; fi
  log "Nginx / 伪装站 / 订阅路径 / 默认黑洞配置完成。"
}

uri_encode(){
  # SECURITY FIX: use byte-level hex encoding via xxd to correctly handle
  # multi-byte UTF-8 characters (e.g. Chinese node names). The old approach
  # used bash '${c} ASCII trick which only works for single-byte chars.
  local s="$1" out="" byte hex
  while IFS= read -r -d '' -n1 byte || [[ -n "$byte" ]]; do
    case "$byte" in
      [a-zA-Z0-9.~_-]) out+="$byte" ;;
      *)
        # Convert each byte to %XX hex encoding
        hex=$(printf '%s' "$byte" | xxd -p -c1 | tr -d '\n')
        local j
        for ((j=0; j<${#hex}; j+=2)); do
          out+="%${hex:j:2}"
        done
        ;;
    esac
  done <<< "$s"
  # Remove trailing newline percent-encoding added by <<<
  out="${out%"%0a"}"
  echo "$out"
}

format_uri_host(){
  local h="$1"
  if [[ "$h" == *:* && "$h" != \[*\] ]]; then
    echo "[$h]"
  else
    echo "$h"
  fi
}

sub_port_suffix(){
  local p="${CDN_PORT:-443}"
  if [[ "$p" == "443" ]]; then
    echo ""
  else
    echo ":$p"
  fi
}

sub_url(){
  local token="$1"
  echo "https://${BASE_DOMAIN}$(sub_port_suffix)/sub/${token}"
}

add_vless_xhttp_reality_link(){
  local server="$1" name="$2" raw="$3" path_enc server_uri
  server_uri=$(format_uri_host "$server")
  path_enc=$(uri_encode "$XHTTP_REALITY_PATH")
  echo "vless://${UUID}@${server_uri}:${XHTTP_REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_TARGET}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${path_enc}&mode=auto#$(uri_encode "$name")" >> "$raw"
}

add_vless_xhttp_cdn_link(){
  local server="$1" name="$2" raw="$3" port="${4:-443}" path_enc server_uri
  server_uri=$(format_uri_host "$server")
  path_enc=$(uri_encode "$XHTTP_CDN_PATH")
  echo "vless://${UUID}@${server_uri}:${port}?encryption=none&security=tls&sni=${BASE_DOMAIN}&fp=chrome&type=xhttp&host=${BASE_DOMAIN}&path=${path_enc}&mode=auto#$(uri_encode "$name")" >> "$raw"
}

add_reality_vision_link(){
  local server="$1" name="$2" raw="$3" server_uri
  server_uri=$(format_uri_host "$server")
  echo "vless://${UUID}@${server_uri}:${REALITY_VISION_PORT}?encryption=none&security=reality&sni=${REALITY_TARGET}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#$(uri_encode "$name")" >> "$raw"
}

add_hy2_link(){
  local server="$1" name="$2" raw="$3" server_uri mport_param=""
  server_uri=$(format_uri_host "$server")
  if [[ -n "${HY2_HOP_RANGE:-}" ]]; then
    mport_param="&mport=${HY2_HOP_RANGE/:/-}"
  fi
  echo "hysteria2://${HY2_AUTH}@${server_uri}:${HY2_PORT:-443}?sni=${BASE_DOMAIN}&insecure=0&alpn=h3${mport_param}#$(uri_encode "$name")" >> "$raw"
}

node_ready(){
  local key="$1"
  # Missing READY keys mean an older install has not regenerated config yet;
  # keep legacy subscription behavior until the next successful config build.
  [[ "${!key:-1}" == "1" ]]
}

generate_mihomo_reference(){
  load_state
  local f="$SUB_DIR/mihomo-reference.yaml"
  cat > "$f" <<EOF2
# 仅供参考：对外订阅仍只发布 base64。
# 建议使用 Clash Verge Rev / Mihomo 新版内核测试 XHTTP。
proxies:
EOF2
  if protocol_enabled 1; then
    if [[ -n "${PUBLIC_IPV4:-}" && "${IPV4_PROTOCOLS:-0}" == *1* ]] && node_ready V4_XHTTP_REALITY_READY; then
      cat >> "$f" <<EOF2
  - name: ${NODE_NAME:-node}-v4-XHTTP-REALITY
    type: vless
    server: v4.${BASE_DOMAIN}
    port: ${XHTTP_REALITY_PORT}
    uuid: ${UUID}
    udp: true
    tls: true
    servername: ${REALITY_TARGET}
    client-fingerprint: chrome
    alpn:
      - h2
    encryption: ""
    network: xhttp
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}
    xhttp-opts:
      mode: auto
      path: ${XHTTP_REALITY_PATH}
EOF2
    fi
    if [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *1* ]] && node_ready V6_XHTTP_REALITY_READY; then
      cat >> "$f" <<EOF2
  - name: ${NODE_NAME:-node}-v6-XHTTP-REALITY
    type: vless
    server: v6.${BASE_DOMAIN}
    port: ${XHTTP_REALITY_PORT}
    uuid: ${UUID}
    udp: true
    tls: true
    servername: ${REALITY_TARGET}
    client-fingerprint: chrome
    alpn:
      - h2
    encryption: ""
    network: xhttp
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}
    xhttp-opts:
      mode: auto
      path: ${XHTTP_REALITY_PATH}
EOF2
    fi
  fi

  if protocol_enabled 2 && node_ready CDN_XHTTP_READY; then
    cat >> "$f" <<EOF2
  - name: ${NODE_NAME:-node}-CDN-XHTTP-Origin
    type: vless
    server: ${BASE_DOMAIN}
    port: ${CDN_PORT:-443}
    uuid: ${UUID}
    udp: true
    tls: true
    servername: ${BASE_DOMAIN}
    client-fingerprint: chrome
    alpn:
      - h2
    encryption: ""
    network: xhttp
    xhttp-opts:
      host: ${BASE_DOMAIN}
      mode: auto
      path: ${XHTTP_CDN_PATH}
EOF2
  fi

  if protocol_enabled 5 && node_ready CDN_XHTTP_READY; then
    cat >> "$f" <<EOF2
  - name: ${NODE_NAME:-node}-CDN-XHTTP-Entry
    type: vless
    server: ${BASE_DOMAIN}
    port: ${CDN_PORT:-443}
    uuid: ${UUID}
    udp: true
    tls: true
    servername: ${BASE_DOMAIN}
    client-fingerprint: chrome
    alpn:
      - h2
    encryption: ""
    network: xhttp
    xhttp-opts:
      host: ${BASE_DOMAIN}
      mode: auto
      path: ${XHTTP_CDN_PATH}
EOF2
  fi

  if protocol_enabled 3; then
    if [[ -n "${PUBLIC_IPV4:-}" && "${IPV4_PROTOCOLS:-0}" == *3* ]] && node_ready V4_HY2_READY; then
      cat >> "$f" <<EOF2
  - name: ${NODE_NAME:-node}-v4-HY2-UDP${HY2_PORT:-443}
    type: hysteria2
    server: v4.${BASE_DOMAIN}
    port: ${HY2_PORT:-443}
    password: ${HY2_AUTH}
    sni: ${BASE_DOMAIN}
    skip-cert-verify: false
    alpn:
      - h3
EOF2
      [[ -n "${HY2_HOP_RANGE:-}" ]] && cat >> "$f" <<EOF2
    ports: ${HY2_HOP_RANGE/:/-}
    hop-interval: 30
EOF2
    fi
    if [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *3* ]] && node_ready V6_HY2_READY; then
      cat >> "$f" <<EOF2
  - name: ${NODE_NAME:-node}-v6-HY2-UDP${HY2_PORT:-443}
    type: hysteria2
    server: v6.${BASE_DOMAIN}
    port: ${HY2_PORT:-443}
    password: ${HY2_AUTH}
    sni: ${BASE_DOMAIN}
    skip-cert-verify: false
    alpn:
      - h3
EOF2
      [[ -n "${HY2_HOP_RANGE:-}" ]] && cat >> "$f" <<EOF2
    ports: ${HY2_HOP_RANGE/:/-}
    hop-interval: 30
EOF2
    fi
  fi
  log "Mihomo 参考片段已生成：$f"
}

ensure_bestcf_data_if_needed(){
  load_state
  # Protocol 5 is a BestCF/CDN entry extension.
  # On every subscription generation, try to fetch the newest remote BestCF data.
  # If upstream data is unavailable, do not use any hardcoded third-party fallback;
  # protocol 5 will fall back to the user's own BASE_DOMAIN CDN entry.
  # 协议5必须每次刷新BestCF；协议2只有用户显式开启BESTCF_ENABLED才刷新。
  if ! protocol_enabled 5 && [[ "${BESTCF_ENABLED:-0}" != "1" ]]; then
    return 0
  fi

  info "正在拉取最新 BestCF 数据。若远端不可用，协议 5 将退回普通 CDN Entry。"
  fetch_bestcf_all || true
}

generate_subscription(){
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || die "请先设置母域名。"
  generate_keys_if_needed
  load_state
  ensure_bestcf_data_if_needed
  load_state
  mkdir -p "$SUB_DIR" "$WEB_ROOT/sub"
  local raw="$SUB_DIR/local.raw" b64="$SUB_DIR/local.b64"
  : > "$raw"

  if protocol_enabled 1; then
    [[ -n "${PUBLIC_IPV4:-}" && "${IPV4_PROTOCOLS:-0}" == *1* ]] && node_ready V4_XHTTP_REALITY_READY && add_vless_xhttp_reality_link "v4.${BASE_DOMAIN}" "${NODE_NAME:-node}-v4-XHTTP-REALITY" "$raw"
    [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *1* ]] && node_ready V6_XHTTP_REALITY_READY && add_vless_xhttp_reality_link "v6.${BASE_DOMAIN}" "${NODE_NAME:-node}-v6-XHTTP-REALITY" "$raw"
  fi

  if protocol_enabled 2 && node_ready CDN_XHTTP_READY; then
    add_vless_xhttp_cdn_link "$BASE_DOMAIN" "${NODE_NAME:-node}-CDN-XHTTP-Origin" "$raw" "${CDN_PORT:-443}"
  fi

  # 5 = CDN 入口扩展。优先生成 BestCF 节点；若 BestCF 数据还没拉取，则保留一个母域名入口，防止节点为空。
  if protocol_enabled 5 && node_ready CDN_XHTTP_READY; then
    local before_count after_count
    before_count=$(wc -l < "$raw" 2>/dev/null || echo 0)
    generate_bestcf_subscription_nodes "$raw"
    after_count=$(wc -l < "$raw" 2>/dev/null || echo 0)
    if [[ "$after_count" -eq "$before_count" ]]; then
      add_vless_xhttp_cdn_link "$BASE_DOMAIN" "${NODE_NAME:-node}-CDN-XHTTP-Entry" "$raw" "${CDN_PORT:-443}"
      warn "协议 5 未找到可用 BestCF 数据，已自动退回母域名 CDN Entry。"
    fi
  elif protocol_enabled 2 && node_ready CDN_XHTTP_READY; then
    generate_bestcf_subscription_nodes "$raw"
  fi

  if protocol_enabled 3; then
    [[ -n "${PUBLIC_IPV4:-}" && "${IPV4_PROTOCOLS:-0}" == *3* ]] && node_ready V4_HY2_READY && add_hy2_link "v4.${BASE_DOMAIN}" "${NODE_NAME:-node}-v4-HY2-UDP${HY2_PORT:-443}" "$raw"
    [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *3* ]] && node_ready V6_HY2_READY && add_hy2_link "v6.${BASE_DOMAIN}" "${NODE_NAME:-node}-v6-HY2-UDP${HY2_PORT:-443}" "$raw"
  fi

  if protocol_enabled 4; then
    [[ -n "${PUBLIC_IPV4:-}" && "${IPV4_PROTOCOLS:-0}" == *4* ]] && node_ready V4_VISION_READY && add_reality_vision_link "v4.${BASE_DOMAIN}" "${NODE_NAME:-node}-v4-REALITY-Vision" "$raw"
    [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *4* ]] && node_ready V6_VISION_READY && add_reality_vision_link "v6.${BASE_DOMAIN}" "${NODE_NAME:-node}-v6-REALITY-Vision" "$raw"
  fi

  # COMPATIBILITY FIX: avoid GNU-specific sed -i and base64 -w0.
  local raw_cleaned; raw_cleaned=$(mktemp_file "${raw}.clean.XXXXXX")
  sed '/^$/d' "$raw" > "$raw_cleaned" && mv -f "$raw_cleaned" "$raw"
  base64 "$raw" | tr -d '\n' > "$b64"
  local nginx_group
  nginx_group="$(detect_nginx_group)"
  ensure_web_subscription_permissions
  install -m 640 -o root -g "$nginx_group" "$b64" "$WEB_ROOT/sub/$SUB_TOKEN"
  generate_mihomo_reference
  log "本机 b64 订阅已生成：$b64"
  echo "订阅链接： $(sub_url "$SUB_TOKEN")"
}

regenerate_subscriptions_after_change(){
  load_state
  if [[ -z "${BASE_DOMAIN:-}" ]]; then
    warn "未设置母域名，跳过自动刷新订阅。"
    return 0
  fi

  # Always generate both public files:
  #   /sub/$SUB_TOKEN         = local-only subscription
  #   /sub/$MERGED_SUB_TOKEN  = local + remotes; if no remotes exist, it equals local-only
  # This prevents first-install summaries from printing a merged subscription URL
  # that does not exist yet and would return 404.
  generate_subscription || { warn "本机订阅自动刷新失败，请稍后手动执行菜单 14 -> 1。"; return 0; }
  merge_remote_subscriptions || warn "合并订阅自动刷新失败，请稍后手动执行菜单 14 -> 8。"
}
ensure_iptables(){
  command -v iptables >/dev/null 2>&1 && return 0
  warn "未检测到 iptables，端口跳跃需要它。"
  if confirm "是否现在安装 iptables？" "Y"; then
    apt-get update && apt-get install -y iptables
  else
    die "缺少 iptables，无法配置端口跳跃。"
  fi
}

refresh_udp_conntrack_for_hy2(){
  local start="$1" end="$2" to_port="$3" max_flush=500 count p
  if ! command -v conntrack >/dev/null 2>&1; then
    warn "未检测到 conntrack；旧 UDP 流可能需要等待内核超时后才会切换到新的 HY2 跳跃规则。"
    return 0
  fi

  [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || {
    warn "HY2 conntrack 刷新跳过：端口范围无效。"
    return 0
  }

  count=$((end - start + 1))
  if [[ "$count" -gt "$max_flush" ]]; then
    warn "HY2 跳跃端口范围过大（$count > ${max_flush}），为避免 CPU 尖峰和误伤现有 443/UDP 连接，跳过 conntrack 精确清理。旧 UDP 流会等待内核超时。"
    return 0
  fi

  # conntrack 的 --dport/--orig-port-dst 接受单个 PORT，不接受 iptables 风格的 start:end 范围。
  # 因此逐端口精确清理跳跃入口端口，避免粗暴删除真实监听端口（如 443）的其它正常 HY2/UDP 会话。
  for ((p=start; p<=end; p++)); do
    conntrack -D -f ipv4 -p udp --orig-port-dst "$p" 2>/dev/null || true
    conntrack -D -f ipv6 -p udp --orig-port-dst "$p" 2>/dev/null || true
  done
  log "已尝试精准刷新 $count 个 HY2 UDP 跳跃端口的 conntrack 记录。"
}

hy2_range_valid(){
  local range="$1" start end
  [[ -z "$range" ]] && return 1
  start="${range%%:*}"; end="${range##*:}"
  [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -ge 1 && "$end" -le 65535 && "$start" -le "$end" ]]
}

remove_hy2_nat_range(){
  local range="$1" to_port="$2" start end removed=0
  [[ -n "$range" && -n "$to_port" ]] || return 0
  hy2_range_valid "$range" || { warn "跳过无效 HY2 跳跃范围：$range"; return 0; }
  valid_port "$to_port" || { warn "跳过无效 HY2 目标端口：$to_port"; return 0; }
  start="${range%%:*}"; end="${range##*:}"
  if command -v iptables >/dev/null 2>&1; then
    while iptables -t nat -D PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null; do removed=1; done
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -t nat -D PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null; do removed=1; done
  fi
  [[ "$removed" == "1" ]] && info "已清理 HY2 历史 NAT 规则：UDP $start-$end -> $to_port" || true
}

enable_hy2_hopping(){
  load_state
  if [[ "${XEM_INTERNAL_APPLY_HY2:-0}" == "1" ]]; then
    command -v iptables >/dev/null 2>&1 || die "缺少 iptables，无法恢复 HY2 端口跳跃规则。"
  else
    ensure_iptables
  fi
  local range="$1" start end to_port old_range old_to_port
  to_port="${HY2_PORT:-443}"
  hy2_range_valid "$range" || die "端口范围格式错误。"
  valid_port "$to_port" || die "HY2_PORT 无效：$to_port"

  old_range="${HY2_HOP_RANGE:-}"
  old_to_port="${HY2_HOP_TO_PORT:-${HY2_PORT:-443}}"

  # 状态机防漏：切换跳跃范围或真实监听端口前，先删除旧规则，避免 PREROUTING 中残留旧端口段。
  if [[ -n "$old_range" && ( "$old_range" != "$range" || "$old_to_port" != "$to_port" ) ]]; then
    info "检测到 HY2 跳跃规则变更，正在卸载历史规则：$old_range -> $old_to_port"
    remove_hy2_nat_range "$old_range" "$old_to_port"
    # 兼容 v0.0.20 及更早版本：当历史目标端口未单独保存时，额外尝试当前端口和 443。
    [[ "$to_port" != "$old_to_port" ]] && remove_hy2_nat_range "$old_range" "$to_port"
    [[ "443" != "$old_to_port" && "443" != "$to_port" ]] && remove_hy2_nat_range "$old_range" "443"
  fi

  start="${range%%:*}"; end="${range##*:}"
  info "设置 HY2 UDP 端口跳跃：$start-$end -> $to_port"
  remove_hy2_nat_range "$range" "$to_port"
  iptables -t nat -A PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" || die "iptables 端口跳跃规则添加失败。"
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -A PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null || warn "ip6tables 规则添加失败，IPv6 跳跃可能不可用。"
  fi
  refresh_udp_conntrack_for_hy2 "$start" "$end" "$to_port"
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save || warn "netfilter-persistent save 失败。"
  elif [[ "${XEM_INTERNAL_APPLY_HY2:-0}" == "1" ]]; then
    warn "未检测到 netfilter-persistent；本次为开机恢复路径，跳过交互安装。"
  elif confirm "是否安装 netfilter-persistent 持久化规则？" "Y"; then
    apt-get install -y iptables-persistent netfilter-persistent || true
    netfilter-persistent save || true
  fi
  save_kv "$STATE_FILE" HY2_HOP_RANGE "$range"
  save_kv "$STATE_FILE" HY2_HOP_TO_PORT "$to_port"
  if [[ "${XEM_INTERNAL_APPLY_HY2:-0}" != "1" ]]; then
    install_hy2_hopping_service
  fi
  log "端口跳跃规则已设置。请确认云安全组放行 UDP $start-${end}。"
}

install_hy2_hopping_service(){
  install_self_to_local_bin
  cat >/etc/systemd/system/xem-hy2-hopping.service <<'EOF2'
[Unit]
Description=Apply Xray Edge Manager Hysteria2 port hopping rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xem --apply-hy2-hopping
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
  systemctl enable xem-hy2-hopping.service >/dev/null 2>&1 || true
}

configure_hy2_hopping_prompt(){
  load_state
  [[ "${PROTOCOLS:-0}" == *3* ]] || return 0
  if confirm "是否开启 Hysteria2 UDP 端口跳跃？推荐小范围 ${DEFAULT_HY2_HOP_RANGE}" "Y"; then
    local range; range=$(ask "请输入跳跃端口范围，格式 start:end" "${HY2_HOP_RANGE:-$DEFAULT_HY2_HOP_RANGE}")
    enable_hy2_hopping "$range"
  fi
}

cf_fallback_ips_v4(){
  printf '%s\n' \
    173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 \
    141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 \
    197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 \
    104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
}

cf_fallback_ips_v6(){
  printf '%s\n' \
    2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 \
    2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32
}

fetch_cf_ip_list(){
  local family="$1" output="$2" url tmp
  tmp="${output}.tmp"
  if [[ "$family" == "4" ]]; then url="$CF_IPS_V4_URL"; else url="$CF_IPS_V6_URL"; fi

  if curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" "$url" -o "$tmp" 2>/dev/null; then
    if [[ "$family" == "4" ]]; then
      grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' "$tmp" > "$output" || true
    else
      grep -Ei '^[0-9a-f:]+/[0-9]{1,3}$' "$tmp" > "$output" || true
    fi
  fi

  if [[ ! -s "$output" ]]; then
    warn "无法拉取 Cloudflare IPv${family} 段，使用脚本内置备用列表。"
    if [[ "$family" == "4" ]]; then cf_fallback_ips_v4 > "$output"; else cf_fallback_ips_v6 > "$output"; fi
  fi
  rm -f "$tmp"
}

remove_cf_origin_firewall_rules_one(){
  local tool="$1" p
  command -v "$tool" >/dev/null 2>&1 || return 0
  for p in 80 $CF_HTTPS_PORTS; do
    while "$tool" -D INPUT -p tcp --dport "$p" -j "$CF_ORIGIN_CHAIN" 2>/dev/null; do :; done
  done
  "$tool" -F "$CF_ORIGIN_CHAIN" 2>/dev/null || true
  "$tool" -X "$CF_ORIGIN_CHAIN" 2>/dev/null || true
}

remove_cf_origin_firewall_rules(){
  remove_cf_origin_firewall_rules_one iptables
  remove_cf_origin_firewall_rules_one ip6tables
}

apply_cf_origin_firewall_one(){
  local tool="$1" ip_file="$2" port="$3" cidr
  command -v "$tool" >/dev/null 2>&1 || return 0
  "$tool" -N "$CF_ORIGIN_CHAIN" 2>/dev/null || true
  "$tool" -F "$CF_ORIGIN_CHAIN"
  while IFS= read -r cidr; do
    [[ -n "$cidr" ]] || continue
    "$tool" -A "$CF_ORIGIN_CHAIN" -s "$cidr" -j ACCEPT || true
  done < "$ip_file"
  "$tool" -A "$CF_ORIGIN_CHAIN" -j DROP
  "$tool" -I INPUT -p tcp --dport 80 -j "$CF_ORIGIN_CHAIN"
  [[ "$port" != "80" ]] && "$tool" -I INPUT -p tcp --dport "$port" -j "$CF_ORIGIN_CHAIN"
}

apply_cf_origin_firewall(){
  load_state
  command -v iptables >/dev/null 2>&1 || die "缺少 iptables，无法设置 Cloudflare 源站限制。"
  local port="${CDN_PORT:-443}" ips4 ips6
  valid_port "$port" || die "CDN_PORT 无效：$port"
  ips4="$(mktemp_file "$APP_DIR/tmp/cf-ips-v4.XXXXXX")"
  ips6="$(mktemp_file "$APP_DIR/tmp/cf-ips-v6.XXXXXX")"
  fetch_cf_ip_list 4 "$ips4"
  fetch_cf_ip_list 6 "$ips6"
  remove_cf_origin_firewall_rules
  apply_cf_origin_firewall_one iptables "$ips4" "$port"
  if command -v ip6tables >/dev/null 2>&1; then
    apply_cf_origin_firewall_one ip6tables "$ips6" "$port"
  else
    warn "未检测到 ip6tables，IPv6 源站限制未应用。"
  fi
  save_kv "$STATE_FILE" ENABLE_CF_ORIGIN_FIREWALL "1"
  log "已限制订阅/伪装站/CDN 源站入口：仅 Cloudflare IP 可访问 TCP 80/${port}；UDP ${HY2_PORT:-443} 不受影响。"
}

install_cf_origin_firewall_service(){
  install_self_to_local_bin
  cat >/etc/systemd/system/xem-cf-origin-firewall.service <<'EOF2'
[Unit]
Description=Apply Xray Edge Manager Cloudflare origin firewall rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xem --apply-cf-origin-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2
  systemctl daemon-reload
  systemctl enable xem-cf-origin-firewall.service >/dev/null 2>&1 || true
}

enable_cf_origin_firewall(){
  apply_cf_origin_firewall
  install_cf_origin_firewall_service
}

disable_cf_origin_firewall(){
  remove_cf_origin_firewall_rules
  systemctl disable --now xem-cf-origin-firewall.service 2>/dev/null || true
  rm -f /etc/systemd/system/xem-cf-origin-firewall.service
  systemctl daemon-reload 2>/dev/null || true
  save_kv "$STATE_FILE" ENABLE_CF_ORIGIN_FIREWALL "0"
  log "已关闭 Cloudflare 源站入口限制。"
}

configure_cf_origin_firewall_prompt(){
  load_state
  warn "开启后，TCP 80/${CDN_PORT:-443} 的非 Cloudflare 来源会被丢弃；纯节点机推荐开启，有其它直连网站业务请选 N。"
  if confirm "是否限制订阅/伪装站/CDN 源站 TCP 80/${CDN_PORT:-443} 只允许 Cloudflare 回源？直接回车 = Y；不影响 HY2 UDP 443" "Y"; then
    enable_cf_origin_firewall
  else
    save_kv "$STATE_FILE" ENABLE_CF_ORIGIN_FIREWALL "0"
    warn "已跳过 Cloudflare 源站入口限制。"
  fi
}

handle_firewall_ports(){
  load_state
  local tcp_ports=() udp_ports=()
  tcp_ports+=("${CDN_PORT:-443}")
  [[ "${PROTOCOLS:-0}" == *1* ]] && tcp_ports+=("${XHTTP_REALITY_PORT:-2443}")
  [[ "${PROTOCOLS:-0}" == *4* ]] && tcp_ports+=("${REALITY_VISION_PORT:-3443}")
  [[ "${PROTOCOLS:-0}" == *3* ]] && udp_ports+=("${HY2_PORT:-443}")
  [[ -n "${HY2_HOP_RANGE:-}" ]] && udp_ports+=("${HY2_HOP_RANGE/:/-}")
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    for p in "${tcp_ports[@]}"; do ufw allow "${p}/tcp" || true; done
    for p in "${udp_ports[@]}"; do ufw allow "${p}/udp" || true; done
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in "${tcp_ports[@]}"; do firewall-cmd --permanent --add-port="${p}/tcp" || true; done
    for p in "${udp_ports[@]}"; do firewall-cmd --permanent --add-port="${p}/udp" || true; done
    firewall-cmd --reload || true
  else
    warn "未检测到已启用的 ufw/firewalld，本脚本不主动安装或启用防火墙。"
  fi
  echo "请确认云厂商安全组放行：TCP ${tcp_ports[*]:-无} / UDP ${udp_ports[*]:-无}"
  configure_cf_origin_firewall_prompt
}

restart_services(){
  ensure_xray_service
  if ! xray_test_config "$XRAY_CONFIG" >/dev/null 2>&1; then
    restore_latest_xray_config || true
    die "Xray 配置测试失败，已回滚。"
  fi
  if ! systemctl restart xray; then
    restore_latest_xray_config || true
    ensure_xray_service || true
    if xray_test_config "$XRAY_CONFIG" >/dev/null 2>&1; then
      systemctl restart xray || true
    fi
    die "Xray 重启失败，已回滚。"
  fi
  if [[ -f "$NGINX_SITE" ]]; then
    if ! nginx -t >/dev/null 2>&1; then
      restore_latest_nginx_config || true
      die "Nginx 配置测试失败，已回滚。"
    fi
    systemctl reload nginx || systemctl restart nginx || { restore_latest_nginx_config || true; die "Nginx reload/restart 失败，已回滚。"; }
  fi
  log "服务已重启。"
}

asn_query_one(){
  local ip="$1"
  [[ -z "$ip" ]] && return 0
  echo "==== $ip ===="
  timeout 15 whois -h bgp.tools " -v $ip" 2>/dev/null | awk '
    /^[0-9]/ {asn=$1; prefix=$2; registry=$3; cc=$4; $1=$2=$3=$4=""; sub(/^[ \t]+/, "", $0); print "ASN="asn"\nPREFIX="prefix"\nREGISTRY="registry"\nCC="cc"\nORG="$0; exit}' || true
}

asn_report(){
  load_state
  local ip4 ip6
  detect_public_ips
  ip4="${PUBLIC_IPV4:-}"; ip6="${PUBLIC_IPV6:-}"
  echo "===== IPv4 / IPv6 / ASN 辅助报告 ====="
  [[ -n "$ip4" ]] && asn_query_one "$ip4" || warn "未检测到公网 IPv4。"
  echo
  [[ -n "$ip6" ]] && asn_query_one "$ip6" || warn "未检测到公网 IPv6。"
  echo
}

bestcf_asset_url(){
  local asset="$1" url=""
  url=$(curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    -H "Accept: application/vnd.github+json" \
    "$BESTCF_RELEASE_API" 2>/dev/null \
    | jq -r --arg name "$asset" '.assets[]? | select(.name == $name) | .browser_download_url' \
    | head -n1 || true)
  if [[ -z "$url" || "$url" == "null" ]]; then
    url="https://github.com/DustinWin/BestCF/releases/download/bestcf/${asset}"
  fi
  echo "$url"
}

normalize_bestcf_label(){
  local label="$1" fallback="$2"
  label="${label:-$fallback}"
  label="$(printf '%s' "$label" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  label="$(printf '%s' "$label" | tr ' /#:@[]()' '_________' | sed -E 's/[^A-Za-z0-9._-]+/_/g;s/_+/_/g;s/^_//;s/_$//')"
  [[ -n "$label" ]] || label="$fallback"
  printf '%s' "$label"
}

parse_bestcf_ip_file(){
  local input="$1" output="$2" default_port="${3:-443}"
  local line addr label clean port fallback_label

  : > "$output"

  while IFS= read -r line; do
    line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" == *"#"* ]]; then
      addr="${line%%#*}"
      label="${line#*#}"
    else
      addr="$line"
      label="BestCF"
    fi

    addr="$(printf '%s' "$addr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    label="$(printf '%s' "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    port="$default_port"
    clean=""

    if [[ "$addr" =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]{1,5})$ ]]; then
      clean="${BASH_REMATCH[1]}"
      port="${BASH_REMATCH[2]}"
    elif [[ "$addr" =~ ^\[([0-9A-Fa-f:]+)\]$ ]]; then
      clean="${BASH_REMATCH[1]}"
    elif [[ "$addr" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3}):([0-9]{1,5})$ ]]; then
      clean="${BASH_REMATCH[1]}"
      port="${BASH_REMATCH[3]}"
    elif [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      clean="$addr"
    elif [[ "$addr" == *:* && "$addr" =~ ^[0-9A-Fa-f:]+$ ]]; then
      clean="$addr"
    else
      continue
    fi

    if ! is_cf_https_port "$port"; then
      port="$default_port"
    fi

    fallback_label="BestCF"
    if [[ "$clean" == *:* ]]; then fallback_label="BestCF-IPv6"; else fallback_label="BestCF-IPv4"; fi
    label="$(normalize_bestcf_label "$label" "$fallback_label")"

    printf '%s|%s|%s\n' "$clean" "$port" "$label" >> "$output"
  done < "$input"

  awk -F'|' 'NF>=3 && !seen[$1 "|" $2]++' "$output" > "${output}.tmp"
  mv "${output}.tmp" "$output"
}

parse_bestcf_domain_file(){
  local input="$1" output="$2" line label n=1
  : > "$output"

  while IFS= read -r line; do
    line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" == *"#"* ]]; then
      label="${line#*#}"
      line="${line%%#*}"
    else
      label="CFDomain_${n}"
    fi

    line="$(printf '%s' "$line" | sed -E 's/^\*\.//I;s/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ "$line" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] || continue
    case "$line" in
      github.com|githubusercontent.com|raw.githubusercontent.com|cloudflare.com|example.com) continue ;;
    esac
    label="$(normalize_bestcf_label "$label" "CFDomain_${n}")"
    printf '%s|%s|%s\n' "$line" "${CDN_PORT:-443}" "$label" >> "$output"
    n=$((n+1))
  done < "$input"

  awk -F'|' 'NF>=3 && !seen[$1]++' "$output" > "${output}.tmp"
  mv "${output}.tmp" "$output"
}

download_bestcf_asset(){
  local asset="$1" output="$2" kind="${3:-auto}" url tmp raw
  mkdir -p "$BESTCF_DIR"

  # SECURITY FIX: use realpath to resolve symlinks and '..' before checking
  # that the output stays within BESTCF_DIR. The old simple prefix check could
  # be bypassed with '/../' path components.
  local resolved_output resolved_dir
  resolved_dir="$(realpath -m "$BESTCF_DIR" 2>/dev/null || echo "$BESTCF_DIR")"
  resolved_output="$(realpath -m "$output" 2>/dev/null || echo "$output")"
  case "$resolved_output" in
    "$resolved_dir"/*) ;;
    *) warn "BestCF 输出路径不安全，已拒绝：$output (resolved: $resolved_output)"; return 1 ;;
  esac

  tmp="${output}.tmp"
  raw="${output}.raw"
  url=$(bestcf_asset_url "$asset")
  info "下载 BestCF：$asset"

  if ! curl -fL --retry 3 --retry-delay 2 \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    --max-filesize 524288 \
    -A "xray-edge-manager" "$url" -o "$raw" 2>/dev/null; then
    warn "下载失败：$asset"
    rm -f "$raw" "$tmp"
    return 1
  fi

  if [[ "$kind" == "auto" ]]; then
    if [[ "$asset" == *domain* ]]; then kind="domain"; else kind="ip"; fi
  fi

  if [[ "$kind" == "domain" ]]; then
    parse_bestcf_domain_file "$raw" "$tmp"
  else
    parse_bestcf_ip_file "$raw" "$tmp" "${CDN_PORT:-443}"
  fi

  if [[ -s "$tmp" ]]; then
    mv "$tmp" "$output"
    rm -f "$raw"
    return 0
  fi

  rm -f "$tmp" "$raw"
  warn "BestCF 文件为空或格式不可用：$asset"
  return 1
}

fetch_bestcf_all(){
  mkdir -p "$BESTCF_DIR"

  # BestCF is only a CDN acceleration entry, not a basic connectivity dependency.
  # Success: use this round's fresh remote data for CFDomain / ISP IP nodes.
  # Failure: do not use any third-party fallback; clear local BestCF cache so
  # protocol 5 falls back to the user's own BASE_DOMAIN CDN entry.
  local asset ok=0 tmp_dir
  tmp_dir="$(mktemp_dir "$BESTCF_DIR/.fetch.XXXXXX")"

  for asset in $BESTCF_ASSETS; do
    rm -f "$tmp_dir/$asset" "$tmp_dir/$asset.tmp" "$tmp_dir/$asset.raw"
  done

  download_bestcf_asset "cmcc-ip.txt" "$tmp_dir/cmcc-ip.txt" "ip" && ok=1 || true
  download_bestcf_asset "cucc-ip.txt" "$tmp_dir/cucc-ip.txt" "ip" && ok=1 || true
  download_bestcf_asset "ctcc-ip.txt" "$tmp_dir/ctcc-ip.txt" "ip" && ok=1 || true
  download_bestcf_asset "bestcf-ip.txt" "$tmp_dir/bestcf-ip.txt" "ip" && ok=1 || true
  download_bestcf_asset "proxy-ip.txt" "$tmp_dir/proxy-ip.txt" "ip" && ok=1 || true
  download_bestcf_asset "bestcf-domain.txt" "$tmp_dir/bestcf-domain.txt" "domain" && ok=1 || true

  for asset in $BESTCF_ASSETS; do
    rm -f "$BESTCF_DIR/$asset" "$BESTCF_DIR/$asset.tmp" "$BESTCF_DIR/$asset.raw"
    if [[ -s "$tmp_dir/$asset" ]]; then
      mv -f "$tmp_dir/$asset" "$BESTCF_DIR/$asset"
    fi
  done
  rm -rf "$tmp_dir"

  if [[ "$ok" != "1" ]]; then
    warn "BestCF 远端数据不可用，已清空本地 BestCF 缓存。本次订阅会退回普通母域名 CDN Entry。"
  else
    log "BestCF 已使用本轮远端最新数据刷新。"
  fi
  # Warn if domain mode requires bestcf-domain.txt but it is missing.
  if [[ "${BESTCF_ENABLED:-0}" == "1" && "${BESTCF_MODE:-off}" == "domain" ]] && [[ ! -s "$BESTCF_DIR/bestcf-domain.txt" ]]; then
    warn "当前为 domain 模式，但 bestcf-domain.txt 不可用，将退回母域名 CDN Entry。"
  fi

  show_bestcf_count
  return 0
}

fetch_bestcf_domains(){ fetch_bestcf_all; }

bestcf_file_count(){
  local f="$1"
  [[ -s "$f" ]] && wc -l < "$f" | tr -d '[:space:]' || echo 0
}

show_bestcf_count(){
  load_state
  echo "===== BestCF 数据数量 ====="
  local f
  for f in cmcc-ip.txt cucc-ip.txt ctcc-ip.txt bestcf-ip.txt proxy-ip.txt bestcf-domain.txt; do
    echo "$f: $(bestcf_file_count "$BESTCF_DIR/$f")"
  done
  echo "当前模式: enabled=${BESTCF_ENABLED:-0}, mode=${BESTCF_MODE:-off}"
  case "${BESTCF_MODE:-off}" in
    domain) echo "节点策略: 只生成 1 个优选域名节点" ;;
    isp_domain) echo "节点策略: 1 个优选域名 + 三网各 1 个 IP，最多 4 个节点" ;;
    *) echo "节点策略: 关闭" ;;
  esac
}

set_bestcf_limits(){
  echo "===== BestCF 节点数量模式 ====="
  echo "1. 只生成 1 个优选域名节点，节点最少，推荐"
  echo "2. 生成 1 个优选域名 + 三网各 1 个 IP，最多 4 个节点"
  echo "0. 返回"
  local c
  c=$(ask "请选择" "1")
  case "$c" in
    1)
      save_kv "$STATE_FILE" BESTCF_ENABLED "1"
      save_kv "$STATE_FILE" BESTCF_MODE "domain"
      save_kv "$STATE_FILE" BESTCF_PER_CATEGORY_LIMIT "1"
      save_kv "$STATE_FILE" BESTCF_TOTAL_LIMIT "1"
      log "BestCF 数量模式：只生成 1 个优选域名节点。"
      ;;
    2)
      save_kv "$STATE_FILE" BESTCF_ENABLED "1"
      save_kv "$STATE_FILE" BESTCF_MODE "isp_domain"
      save_kv "$STATE_FILE" BESTCF_PER_CATEGORY_LIMIT "1"
      save_kv "$STATE_FILE" BESTCF_TOTAL_LIMIT "4"
      log "BestCF 数量模式：1 个优选域名 + 三网各 1 个 IP，最多 4 个节点。"
      ;;
    0) return 0 ;;
    *) warn "无效选择。" ;;
  esac
  load_state
  regenerate_subscriptions_after_change
}

enable_bestcf_domain_only(){
  fetch_bestcf_all
  save_kv "$STATE_FILE" BESTCF_ENABLED "1"
  save_kv "$STATE_FILE" BESTCF_MODE "domain"
  save_kv "$STATE_FILE" BESTCF_PER_CATEGORY_LIMIT "1"
  save_kv "$STATE_FILE" BESTCF_TOTAL_LIMIT "1"
  load_state
  log "BestCF 已启用：只生成 1 个优选域名节点。"
  regenerate_subscriptions_after_change
}

enable_bestcf_isp_domain(){
  fetch_bestcf_all
  save_kv "$STATE_FILE" BESTCF_ENABLED "1"
  save_kv "$STATE_FILE" BESTCF_MODE "isp_domain"
  save_kv "$STATE_FILE" BESTCF_PER_CATEGORY_LIMIT "1"
  save_kv "$STATE_FILE" BESTCF_TOTAL_LIMIT "4"
  load_state
  log "BestCF 已启用：1 个优选域名 + 三网各 1 个 IP，最多 4 个节点。"
  regenerate_subscriptions_after_change
}

disable_bestcf(){
  save_kv "$STATE_FILE" BESTCF_ENABLED "0"
  save_kv "$STATE_FILE" BESTCF_MODE "off"
  load_state
  log "BestCF 已关闭。"
  regenerate_subscriptions_after_change
}

add_bestcf_nodes_from_file(){
  local file="$1" fallback_label="$2" raw="$3" max_each="$4" total_ref="$5" total_limit="$6"
  local line server port label name n=1
  [[ -s "$file" ]] || return 0

  while IFS='|' read -r server port label _rest; do
    [[ -z "${server:-}" || "$server" =~ ^# ]] && continue
    [[ "${!total_ref}" -ge "$total_limit" ]] && return 0

    if [[ -z "${port:-}" || -z "${label:-}" ]]; then
      port="${CDN_PORT:-443}"
      label="${fallback_label}_${n}"
    fi

    if ! is_cf_https_port "$port"; then
      port="${CDN_PORT:-443}"
    fi

    label="$(normalize_bestcf_label "$label" "${fallback_label}_${n}")"
    name="${NODE_NAME:-node}-${label}"
    add_vless_xhttp_cdn_link "$server" "$name" "$raw" "$port"

    n=$((n+1))
    printf -v "$total_ref" '%s' "$(( ${!total_ref} + 1 ))"
    [[ "$n" -gt "$max_each" ]] && break
  done < "$file"
}

generate_bestcf_subscription_nodes(){
  local raw="$1" mode="${BESTCF_MODE:-domain}" total=0
  [[ "${BESTCF_ENABLED:-0}" == "1" ]] || return 0

  if [[ "$mode" == "domain" ]]; then
    add_bestcf_nodes_from_file "$BESTCF_DIR/bestcf-domain.txt" "CFDomain" "$raw" 1 total 1
    return 0
  fi

  if [[ "$mode" == "isp_domain" ]]; then
    add_bestcf_nodes_from_file "$BESTCF_DIR/cmcc-ip.txt" "CMCC-CFIP" "$raw" 1 total 4
    add_bestcf_nodes_from_file "$BESTCF_DIR/cucc-ip.txt" "CUCC-CFIP" "$raw" 1 total 4
    add_bestcf_nodes_from_file "$BESTCF_DIR/ctcc-ip.txt" "CTCC-CFIP" "$raw" 1 total 4
    add_bestcf_nodes_from_file "$BESTCF_DIR/bestcf-domain.txt" "CFDomain" "$raw" 1 total 4
    return 0
  fi
}

enable_bestcf_timer(){
  install_self_to_local_bin
  cat >/etc/systemd/system/xem-bestcf-update.service <<'EOF2'
[Unit]
Description=Update BestCF data and regenerate Xray Edge Manager subscription
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xem --bestcf-update
EOF2
  cat >/etc/systemd/system/xem-bestcf-update.timer <<'EOF2'
[Unit]
Description=Run BestCF update every 12 hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=12h
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF2
  systemctl daemon-reload
  systemctl enable --now xem-bestcf-update.timer
  log "BestCF 12 小时安全自动更新已启用。"
}

disable_bestcf_timer(){
  systemctl disable --now xem-bestcf-update.timer 2>/dev/null || true
  rm -f /etc/systemd/system/xem-bestcf-update.service /etc/systemd/system/xem-bestcf-update.timer
  systemctl daemon-reload 2>/dev/null || true
  log "BestCF 自动更新已关闭。"
}

network_status(){
  uname -a
  sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || true
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
  sysctl net.core.default_qdisc 2>/dev/null || true
}

backup_sysctl_config(){
  mkdir -p "$BACKUP_DIR"
  local ts; ts=$(date +%F-%H%M%S)
  if [[ -f "$SYSCTL_FILE" ]]; then
    cp -a "$SYSCTL_FILE" "$BACKUP_DIR/sysctl.$ts.bak" 2>/dev/null || true
    save_kv "$STATE_FILE" LAST_SYSCTL_BACKUP "$BACKUP_DIR/sysctl.$ts.bak"
  fi
}

apply_stable_network_tuning(){
  local tmp cc available current
  backup_sysctl_config

  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  cc="bbr"
  if [[ "$available" != *bbr* ]]; then
    cc="${current:-cubic}"
    warn "当前内核未显示支持 BBR：${available:-unknown}，将保持拥塞控制为 ${cc}。"
  fi

  mkdir -p "$(dirname "$SYSCTL_FILE")"
  tmp="$(mktemp_file "${SYSCTL_FILE}.tmp.XXXXXX")"
  cat > "$tmp" <<EOF2
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=$cc
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.ip_local_port_range=1024 65535
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
EOF2
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$SYSCTL_FILE"
  sysctl --system >/dev/null || warn "sysctl --system 返回非零；请用菜单 5 查看当前状态。"
  log "已应用稳定型网络优化。"
}

restore_network_tuning(){
  load_state
  local bak="${LAST_SYSCTL_BACKUP:-}"
  [[ -n "$bak" && -f "$bak" ]] || bak=$(ls -1t "$BACKUP_DIR"/sysctl.*.bak 2>/dev/null | head -n1 || true)
  if [[ -n "$bak" && -f "$bak" ]]; then
    install -m 644 "$bak" "$SYSCTL_FILE"
    sysctl --system >/dev/null || true
    warn "已恢复 sysctl 优化配置备份：$bak"
  else
    rm -f "$SYSCTL_FILE"
    sysctl --system >/dev/null || true
    warn "未找到 sysctl 备份，已删除 $SYSCTL_FILE 并重新加载 sysctl。"
  fi
}

show_status(){
  echo "===== Xray ====="; xray version 2>/dev/null || true; systemctl status xray --no-pager -l 2>/dev/null || true
  echo "===== Nginx ====="; nginx -t 2>&1 || true; systemctl status nginx --no-pager -l 2>/dev/null || true
  echo "===== Listen ====="; ss -tulpen | grep -E ':(443|2053|2083|2087|2096|8443|2443|3443)\b' || true
}

subscription_web_file_exists(){
  local token="${1:-}"
  [[ -n "$token" && -s "$WEB_ROOT/sub/$token" ]]
}

show_links(){
  load_state
  echo "===== 本机订阅 ====="
  if [[ -n "${BASE_DOMAIN:-}" && -n "${SUB_TOKEN:-}" ]]; then
    if subscription_web_file_exists "$SUB_TOKEN"; then
      sub_url "$SUB_TOKEN"
    else
      warn "本机订阅文件尚未发布到 Web 目录；请执行菜单 14 -> 1 或 14 -> 8。"
      echo "预期链接：$(sub_url "$SUB_TOKEN")"
    fi
  else
    echo "https://<BASE_DOMAIN>$(sub_port_suffix)/sub/<TOKEN>"
  fi

  echo "===== 合并订阅 ====="
  if [[ -n "${BASE_DOMAIN:-}" && -n "${MERGED_SUB_TOKEN:-}" ]]; then
    if subscription_web_file_exists "$MERGED_SUB_TOKEN"; then
      sub_url "$MERGED_SUB_TOKEN"
    else
      warn "合并订阅文件尚未生成；请执行菜单 14 -> 8。"
      echo "预期链接：$(sub_url "$MERGED_SUB_TOKEN")"
    fi
  elif [[ -n "${MERGED_SUB_TOKEN:-}" ]]; then
    echo "https://<BASE_DOMAIN>$(sub_port_suffix)/sub/${MERGED_SUB_TOKEN}"
  else
    warn "尚未生成合并订阅 token。"
  fi

  echo
  echo "===== local.raw ====="
  [[ -f "$SUB_DIR/local.raw" ]] && cat "$SUB_DIR/local.raw" || warn "尚未生成 local.raw。"
  echo
  [[ -f "$SUB_DIR/mihomo-reference.yaml" ]] && echo "Mihomo 参考片段：$SUB_DIR/mihomo-reference.yaml" || true
}

rotate_subscription_tokens(){
  load_state
  warn "这会改变本机订阅和合并订阅 URL。只有确认泄露或准备统一更新下游中转时才建议执行。"
  confirm "确认轮换订阅 token？" "N" || { warn "已取消轮换。"; return 0; }
  local old_sub="${SUB_TOKEN:-}" old_merged="${MERGED_SUB_TOKEN:-}"
  save_kv "$STATE_FILE" SUB_TOKEN "$(rand_token)"
  save_kv "$STATE_FILE" MERGED_SUB_TOKEN "$(rand_token)"
  load_state
  [[ -n "$old_sub" ]] && rm -f "$WEB_ROOT/sub/$old_sub" 2>/dev/null || true
  [[ -n "$old_merged" ]] && rm -f "$WEB_ROOT/sub/$old_merged" 2>/dev/null || true
  regenerate_subscriptions_after_change
  log "订阅 token 已轮换。"
  show_links
}

deployment_summary(){
  load_state
  echo
  echo "===== 部署摘要 ====="
  echo "母域名: ${BASE_DOMAIN:-未设置}"
  echo "节点名称: ${NODE_NAME:-node}"
  echo "IPv4 协议: ${IPV4_PROTOCOLS:-0}"
  echo "IPv6 协议: ${IPV6_PROTOCOLS:-0}"
  echo "实际协议组合: ${PROTOCOLS:-0}"
  protocol_enabled 1 && echo "  XHTTP+REALITY: TCP ${XHTTP_REALITY_PORT:-2443}"
  protocol_enabled 2 && echo "  XHTTP+TLS+CDN: TCP ${CDN_PORT:-443} -> 127.0.0.1:${XHTTP_CDN_LOCAL_PORT:-31301}"
  protocol_enabled 3 && echo "  Xray Hysteria2: UDP ${HY2_PORT:-443}，ALPN h3"
  protocol_enabled 4 && echo "  REALITY+Vision: TCP ${REALITY_VISION_PORT:-3443}"
  protocol_enabled 5 && echo "  XHTTP+TLS+CDN 入口扩展: TCP ${CDN_PORT:-443} -> 127.0.0.1:${XHTTP_CDN_LOCAL_PORT:-31301}"
  [[ -n "${HY2_HOP_RANGE:-}" ]] && echo "  HY2 端口跳跃: UDP ${HY2_HOP_RANGE/:/-} -> ${HY2_PORT:-443}"
  echo "Xray 运行用户: ${XRAY_USER}"
  echo "出口策略: $(normalize_ip_outbound_mode "${IP_OUTBOUND_MODE:-}")"
  echo "Cloudflare 源站限制: ${ENABLE_CF_ORIGIN_FIREWALL:-0}"
  echo "BestCF: ${BESTCF_ENABLED:-0} / ${BESTCF_MODE:-off} / 每类${BESTCF_PER_CATEGORY_LIMIT:-2} / 总上限${BESTCF_TOTAL_LIMIT:-10}"
  if [[ -n "${BASE_DOMAIN:-}" && -n "${SUB_TOKEN:-}" ]] && subscription_web_file_exists "$SUB_TOKEN"; then
    echo "订阅: $(sub_url "$SUB_TOKEN")"
  elif [[ -n "${BASE_DOMAIN:-}" && -n "${SUB_TOKEN:-}" ]]; then
    echo "订阅: 未发布到 Web 目录（请执行菜单 14 -> 1 或 14 -> 8）"
  else
    echo "订阅: 未生成"
  fi

  if [[ -n "${BASE_DOMAIN:-}" && -n "${MERGED_SUB_TOKEN:-}" ]] && subscription_web_file_exists "$MERGED_SUB_TOKEN"; then
    echo "合并订阅: $(sub_url "$MERGED_SUB_TOKEN")"
  elif [[ -n "${BASE_DOMAIN:-}" && -n "${MERGED_SUB_TOKEN:-}" ]]; then
    echo "合并订阅: 未生成（请执行菜单 14 -> 8）"
  fi
}

install_full(){
  need_root
  install_deps
  install_or_upgrade_xray
  update_geodata
  prepare_base_domain_for_install
  setup_cloudflare
  configure_node_name
  asn_report
  select_ip_stack_strategy
  select_protocols
  create_dns_records
  issue_certificate
  choose_reality_target
  generate_xray_config
  configure_nginx
  configure_hy2_hopping_prompt
  handle_firewall_ports
  restart_services
  regenerate_subscriptions_after_change
  deployment_summary
  log "首次部署流程完成。"
}

ensure_remotes_file(){
  mkdir -p "$SUB_DIR"
  [[ ! -L "$REMOTES_FILE" ]] || die "拒绝使用符号链接远程订阅文件：$REMOTES_FILE"
  touch "$REMOTES_FILE"
  chmod 600 "$REMOTES_FILE" 2>/dev/null || true
}

list_remote_subscriptions(){
  ensure_remotes_file
  echo "===== 远程订阅列表 ====="
  if [[ ! -s "$REMOTES_FILE" ]]; then
    warn "暂无远程订阅。"
    return 0
  fi
  nl -ba "$REMOTES_FILE" | sed 's/\t/. /'
}

add_remote_subscription(){
  mkdir -p "$SUB_DIR"
  local name url
  name=$(ask "请输入远程订阅名称，方便区分来源" "remote")
  name=$(printf '%s' "$name" | tr -cd 'A-Za-z0-9_.-' | sed 's/^[-_.]*//; s/[-_.]*$//')
  [[ -n "$name" ]] || name="remote"
  url=$(ask "请输入远程 base64 订阅 URL" "")
  [[ -n "$url" ]] || { warn "URL 为空，取消。"; return 0; }
  ensure_remotes_file
  echo "${name}|${url}" >> "$REMOTES_FILE"
  log "已添加远程订阅：$name"
}

delete_remote_subscription(){
  ensure_remotes_file
  list_remote_subscriptions
  local n tmp
  n=$(ask "请输入要删除的编号" "")
  [[ "$n" =~ ^[0-9]+$ ]] || { warn "编号无效。"; return 0; }
  tmp=$(mktemp_file "$SUB_DIR/.remote-del.XXXXXX")
  awk -v n="$n" 'NR!=n' "$REMOTES_FILE" > "$tmp"
  mv "$tmp" "$REMOTES_FILE"
  log "已删除编号：$n"
}

clear_remote_subscriptions(){
  if confirm "确认清空所有远程订阅？" "N"; then
    ensure_remotes_file
    : > "$REMOTES_FILE"
    log "已清空远程订阅。"
  fi
}

# SECURITY: extract hostname from http(s) URL for private-address validation.
extract_url_host(){
  local url="$1"
  url="${url#http://}"; url="${url#https://}"
  url="${url%%/*}"
  # strip optional port
  local host
  if [[ "$url" == \[*\]* ]]; then
    host="${url#[}"; host="${host%%]*}"
  else
    host="${url%:*}"
    # if no colon at all (no port), host == url
    [[ "$url" == *:* ]] || host="$url"
  fi
  printf '%s' "$host"
}

# SECURITY: return 0 (true) if the host is a private/loopback/reserved address.
is_private_host(){
  local h="${1,,}"  # normalise to lowercase for IPv6/host comparisons
  case "$h" in
    localhost|localhost.*|::1|0.0.0.0) return 0 ;;
    127.*|10.*) return 0 ;;
    192.168.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    169.254.*) return 0 ;;
    # CGNAT 100.64/10
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
    198.18.*|198.19.*) return 0 ;;
    0.*) return 0 ;;
    # Multicast / reserved
    22[4-9].*|23[0-9].*|24[0-9].*|25[0-5].*) return 0 ;;
    # IPv4-mapped IPv6 (::ffff:x.x.x.x)
    ::ffff:127.*|::ffff:10.*|::ffff:192.168.*) return 0 ;;
    ::ffff:172.1[6-9].*|::ffff:172.2[0-9].*|::ffff:172.3[01].*) return 0 ;;
    ::ffff:169.254.*) return 0 ;;
    ::ffff:100.6[4-9].*|::ffff:100.[7-9][0-9].*|::ffff:100.1[01][0-9].*|::ffff:100.12[0-7].*) return 0 ;;
    ::ffff:198.18.*|::ffff:198.19.*) return 0 ;;
    ::ffff:0.*) return 0 ;;
    ::ffff:22[4-9].*|::ffff:23[0-9].*|::ffff:24[0-9].*|::ffff:25[0-5].*) return 0 ;;
    # IPv6 ULA / link-local. Match only IPv6-looking literals, not hostnames
    # such as fc-example.com or fdcdn.example.com.
    fc[0-9a-f]*:*|fd[0-9a-f]*:*|fe80:*) return 0 ;;
  esac
  return 1
}

# SECURITY: resolve hostname via getent and check all returned IPs.
# Returns 1 (reject) if any resolved IP is private; 0 if safe.
resolve_and_check_ssrf(){
  local hostname="$1"
  # Bare IP — check directly.
  if [[ "$hostname" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$hostname" =~ ^[0-9A-Fa-f:]+$ ]]; then
    is_private_host "$hostname" && return 1
    return 0
  fi
  if command -v getent >/dev/null 2>&1; then
    local ip
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      if is_private_host "$ip"; then return 1; fi
    done < <(getent ahosts "$hostname" 2>/dev/null | awk '!seen[$1]++{print $1}')
  fi
  return 0
}

merge_remote_subscriptions(){
  load_state
  generate_keys_if_needed
  load_state
  mkdir -p "$SUB_DIR" "$WEB_ROOT/sub"
  [[ -f "$SUB_DIR/local.raw" ]] || generate_subscription
  ensure_remotes_file
  local remote_raw="$SUB_DIR/remote.raw" merged="$SUB_DIR/merged.raw" merged_b64="$SUB_DIR/merged.b64"
  local name url fetch_file decoded_file size decoded_size max_bytes http_code
  max_bytes="${REMOTE_SUB_MAX_BYTES:-2097152}"
  : > "$remote_raw"

  while IFS='|' read -r name url; do
    [[ -z "${url:-}" || "$name" =~ ^# ]] && continue
    case "$url" in
      http://*|https://*) ;;
      *) warn "远程订阅 URL 不是 http/https，已跳过：$name"; continue ;;
    esac

    # SECURITY: reject userinfo in URL authority (e.g. http://x@127.0.0.1/).
    # Only inspect the authority segment, so an @ in the path is not misclassified.
    local _authority
    _authority="${url#http://}"; _authority="${_authority#https://}"; _authority="${_authority%%/*}"
    if [[ "$_authority" == *@* ]]; then
      warn "远程订阅 URL 包含 userinfo (@)，已拒绝：$name"
      continue
    fi

    # SECURITY: reject private/loopback targets (SSRF protection)
    if [[ ${#url} -gt 2048 ]]; then
      warn "远程订阅 URL 过长，已跳过：$name"
      continue
    fi
    local _rhost; _rhost=$(extract_url_host "$url")
    if is_private_host "$_rhost"; then
      warn "远程订阅 URL 指向私有地址（字面量），已拒绝：$name ($_rhost)"
      continue
    fi
    if ! resolve_and_check_ssrf "$_rhost"; then
      warn "远程订阅 URL 域名解析到私有地址，已拒绝：$name ($_rhost)"
      continue
    fi

    info "拉取远程订阅：$name"
    fetch_file="$(mktemp_file "$SUB_DIR/remote-fetch.XXXXXX")"
    decoded_file="$(mktemp_file "$SUB_DIR/remote-decoded.XXXXXX")"

    # SECURITY: do not follow redirects for user-controlled remote subscriptions.
    # --proto/--proto-redir still restrict schemes, but --max-redirs 0 and no -L
    # prevent HTTP(S) redirects from bypassing the SSRF host checks above.
    if ! http_code=$(curl -fsS \
      --max-redirs 0 \
      --proto '=http,https' --proto-redir '=http,https' \
      --retry 2 --retry-delay 1 \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 30 \
      --max-filesize "$max_bytes" \
      -w '%{http_code}' -o "$fetch_file" "$url" 2>/dev/null); then
      warn "拉取失败或超过大小限制：$name"
      continue
    fi
    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      warn "远程订阅返回非 2xx 或发生重定向，已跳过：$name http=$http_code"
      continue
    fi

    size=$(wc -c < "$fetch_file" | tr -d '[:space:]')
    if [[ "$size" -gt "$max_bytes" ]]; then
      warn "远程订阅过大，已跳过：$name size=${size} limit=${max_bytes}"
      continue
    fi

    if ! base64 -d "$fetch_file" > "$decoded_file" 2>/dev/null; then
      warn "解码失败：$name"
      continue
    fi

    decoded_size=$(wc -c < "$decoded_file" | tr -d '[:space:]')
    if [[ "$decoded_size" -gt "$max_bytes" ]]; then
      warn "远程订阅解码后过大，已跳过：$name size=${decoded_size} limit=${max_bytes}"
      continue
    fi

    sed '/^$/d' "$decoded_file" >> "$remote_raw"
    echo >> "$remote_raw"
  done < "$REMOTES_FILE"

  cat "$SUB_DIR/local.raw" "$remote_raw" 2>/dev/null | sed '/^$/d' | awk '!seen[$0]++' > "$merged"
  # COMPATIBILITY FIX: avoid GNU-specific base64 -w0.
  base64 "$merged" | tr -d '\n' > "$merged_b64"
  local nginx_group
  nginx_group="$(detect_nginx_group)"
  ensure_web_subscription_permissions
  install -m 640 -o root -g "$nginx_group" "$merged_b64" "$WEB_ROOT/sub/$MERGED_SUB_TOKEN"
  log "合并订阅已生成：$merged_b64"
  echo "合并订阅链接： $(sub_url "$MERGED_SUB_TOKEN")"
}

subscription_menu(){
  while true; do
    load_state
    echo; echo "===== 订阅管理 ====="
    echo "1. 重新生成本机 b64 订阅"
    echo "2. 查看分享链接 / 订阅链接"
    echo "3. 设置节点名称，并自动刷新订阅"
    echo "4. 添加远程 b64 订阅，并自动刷新合并订阅"
    echo "5. 查看远程订阅列表"
    echo "6. 删除一个远程订阅，并自动刷新合并订阅"
    echo "7. 清空远程订阅，并自动刷新合并订阅"
    echo "8. 拉取并生成合并订阅"
    echo "9. 泄露后手动轮换订阅 token"
    echo "0. 返回"
    local c; c=$(ask "请选择" "0")
    case "$c" in
      1) regenerate_subscriptions_after_change ;;
      2) show_links ;;
      3) configure_node_name; regenerate_subscriptions_after_change ;;
      4) add_remote_subscription; merge_remote_subscriptions ;;
      5) list_remote_subscriptions ;;
      6) delete_remote_subscription; merge_remote_subscriptions ;;
      7) clear_remote_subscriptions; merge_remote_subscriptions ;;
      8) merge_remote_subscriptions ;;
      9) rotate_subscription_tokens ;;
      0) break ;;
      *) warn "无效选择。" ;;
    esac
  done
}
bestcf_menu(){
  while true; do
    load_state
    echo; echo "===== BestCF 管理，默认关闭 ====="
    echo "当前状态: enabled=${BESTCF_ENABLED:-0}, mode=${BESTCF_MODE:-off}"
    echo "1. 启用：只生成 1 个优选域名节点，节点最少"
    echo "2. 启用：1 个优选域名 + 三网各 1 个 IP，最多 4 个节点"
    echo "3. 关闭 BestCF，并自动刷新订阅"
    echo "4. 立即更新 BestCF 数据，并自动刷新订阅"
    echo "5. 查看当前数据数量"
    echo "6. 设置节点数量模式，并自动刷新订阅"
    echo "7. 启用 12 小时自动更新"
    echo "8. 关闭自动更新"
    echo "0. 返回"
    local c; c=$(ask "请选择" "0")
    case "$c" in
      1) enable_bestcf_domain_only ;;
      2) enable_bestcf_isp_domain ;;
      3) disable_bestcf ;;
      4) fetch_bestcf_all; regenerate_subscriptions_after_change ;;
      5) show_bestcf_count ;;
      6) set_bestcf_limits ;;
      7) enable_bestcf_timer ;;
      8) disable_bestcf_timer ;;
      0) break ;;
      *) warn "无效选择。" ;;
    esac
  done
}
show_installation_state(){
  load_state
  echo "APP_DIR: $APP_DIR"
  echo "BASE_DOMAIN: ${BASE_DOMAIN:-未设置}"
  echo "NODE_NAME: ${NODE_NAME:-未设置}"
  echo "IPV4_PROTOCOLS: ${IPV4_PROTOCOLS:-未设置}"
  echo "IPV6_PROTOCOLS: ${IPV6_PROTOCOLS:-未设置}"
  echo "PROTOCOLS: ${PROTOCOLS:-未设置}"
  echo "Xray user: ${XRAY_USER}"
  echo "CF origin firewall: ${ENABLE_CF_ORIGIN_FIREWALL:-0}"
  echo "Xray config: $([[ -f "$XRAY_CONFIG" ]] && echo 存在 || echo 不存在)"
  echo "Nginx site: $([[ -f "$NGINX_SITE" ]] && echo 存在 || echo 不存在)"
  systemctl is-active xray >/dev/null 2>&1 && echo "Xray: active" || echo "Xray: inactive"
  systemctl is-active nginx >/dev/null 2>&1 && echo "Nginx: active" || echo "Nginx: inactive"
}

remove_hy2_hopping_rules(){
  load_state
  local range="${HY2_HOP_RANGE:-}" to_port="${HY2_HOP_TO_PORT:-${HY2_PORT:-443}}" start end
  if [[ -z "$range" ]]; then
    warn "状态文件中没有 HY2_HOP_RANGE，仍会尝试清理默认范围：$DEFAULT_HY2_HOP_RANGE -> $to_port"
    range="$DEFAULT_HY2_HOP_RANGE"
  fi
  if hy2_range_valid "$range"; then
    start="${range%%:*}"; end="${range##*:}"
    remove_hy2_nat_range "$range" "$to_port"
    [[ "$to_port" != "${HY2_PORT:-443}" ]] && remove_hy2_nat_range "$range" "${HY2_PORT:-443}"
    [[ "$to_port" != "443" && "${HY2_PORT:-443}" != "443" ]] && remove_hy2_nat_range "$range" "443"
    refresh_udp_conntrack_for_hy2 "$start" "$end" "$to_port"
  else
    warn "端口范围无效：$range"
  fi

  systemctl disable --now xem-hy2-hopping.service 2>/dev/null || true
  rm -f /etc/systemd/system/xem-hy2-hopping.service
  systemctl daemon-reload 2>/dev/null || true
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true
  save_kv "$STATE_FILE" HY2_HOP_RANGE ""
  save_kv "$STATE_FILE" HY2_HOP_TO_PORT ""
  log "已删除 HY2 端口跳跃规则，并清空持久化状态，开机不会自动恢复旧规则。"
}

cf_get_record_json(){
  local name="$1" type="$2"
  load_state
  [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE_ID:-}" ]] || return 1
  curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -G \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    --data-urlencode "type=$type" \
    --data-urlencode "name=$name"
}

cf_delete_record_by_id(){
  local rec_id="$1"
  [[ -n "$rec_id" ]] || return 1
  cf_api DELETE "/zones/$CF_ZONE_ID/dns_records/$rec_id" >/dev/null
}

cf_delete_record(){
  local name="$1" type="$2" expected="${3:-}" mode="${4:-owned}" resp count i rec_id content
  resp=$(cf_get_record_json "$name" "$type") || { warn "无法读取 $type ${name}，跳过。"; return 0; }
  count=$(echo "$resp" | jq -r '.result | length')
  [[ "$count" -gt 0 ]] || { info "Cloudflare 中不存在 $type ${name}，跳过。"; return 0; }
  for ((i=0;i<count;i++)); do
    rec_id=$(echo "$resp" | jq -r ".result[$i].id // empty")
    content=$(echo "$resp" | jq -r ".result[$i].content // empty")
    [[ -n "$rec_id" ]] || continue
    if [[ "$mode" == "owned" && -n "$expected" && "$content" != "$expected" ]]; then
      warn "跳过 $type ${name}：当前指向 ${content}，不等于本机 IP ${expected}。"
      continue
    fi
    if cf_delete_record_by_id "$rec_id"; then
      log "已删除 Cloudflare DNS：$type $name -> $content"
    else
      warn "删除失败：$type $name -> $content"
    fi
  done
}

delete_cloudflare_records_menu(){
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || { warn "BASE_DOMAIN 未设置，无法清理 DNS。"; return 0; }
  [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE_ID:-}" ]] || { warn "Cloudflare API 未配置，无法清理 DNS。"; return 0; }
  local ip4 ip6 mode
  detect_public_ips
  ip4="${PUBLIC_IPV4:-}"; ip6="${PUBLIC_IPV6:-}"
  echo "将处理这些记录："
  echo "  $BASE_DOMAIN A/AAAA"
  echo "  v4.$BASE_DOMAIN A"
  echo "  v6.$BASE_DOMAIN AAAA"
  echo "1. 只删除仍指向本机 IP 的记录，推荐"
  echo "2. 强制删除这些域名记录，不检查 IP，危险但可彻底清理"
  echo "0. 不删除 DNS"
  mode=$(ask "请选择 DNS 删除模式" "0")
  case "$mode" in
    1)
      cf_delete_record "$BASE_DOMAIN" A "$ip4" owned
      cf_delete_record "v4.$BASE_DOMAIN" A "$ip4" owned
      cf_delete_record "$BASE_DOMAIN" AAAA "$ip6" owned
      cf_delete_record "v6.$BASE_DOMAIN" AAAA "$ip6" owned
      ;;
    2)
      if confirm "最后确认强制删除 Cloudflare 上 BASE/v4/v6 相关 DNS？" "N"; then
        cf_delete_record "$BASE_DOMAIN" A "" force
        cf_delete_record "v4.$BASE_DOMAIN" A "" force
        cf_delete_record "$BASE_DOMAIN" AAAA "" force
        cf_delete_record "v6.$BASE_DOMAIN" AAAA "" force
      fi
      ;;
    *) warn "跳过 DNS 删除。" ;;
  esac
}

full_uninstall_xem(){
  need_root
  load_state
  warn "完整卸载将停止服务、删除 Xray 配置、Nginx 站点、订阅目录、脚本状态、旧版残留和端口跳跃规则。"
  warn "适合纯节点机器。如果还有其他网站业务，不要继续。"
  confirm "确认完整卸载？" "N" || { warn "已取消。"; return 0; }
  confirm "再次确认：允许清理 Nginx/Xray/证书/状态文件？" "N" || { warn "已取消。"; return 0; }

  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  local ts; ts=$(date +%F-%H%M%S)
  [[ -f "$XRAY_CONFIG" ]] && cp -a "$XRAY_CONFIG" "$BACKUP_DIR/config.json.before-uninstall.$ts.bak" 2>/dev/null || true
  [[ -f "$NGINX_SITE" ]] && cp -a "$NGINX_SITE" "$BACKUP_DIR/nginx.before-uninstall.$ts.bak" 2>/dev/null || true
  [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$BACKUP_DIR/state.env.before-uninstall.$ts.bak" 2>/dev/null || true

  if confirm "是否删除 Cloudflare DNS？默认不删" "N"; then
    delete_cloudflare_records_menu || true
  fi

  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  systemctl stop nginx 2>/dev/null || true
  systemctl disable --now xem-bestcf-update.timer xem-geodata-update.timer 2>/dev/null || true
  systemctl disable --now xem-hy2-hopping.service xem-cf-origin-firewall.service 2>/dev/null || true
  rm -f /etc/systemd/system/xem-bestcf-update.service /etc/systemd/system/xem-bestcf-update.timer
  rm -f /etc/systemd/system/xem-geodata-update.service /etc/systemd/system/xem-geodata-update.timer
  rm -f /etc/systemd/system/xem-hy2-hopping.service /etc/systemd/system/xem-cf-origin-firewall.service
  rm -f "$CERT_DEPLOY_HOOK" /etc/logrotate.d/xray 2>/dev/null || true
  remove_hy2_hopping_rules || true
  disable_cf_origin_firewall || true

  # Do not fetch and execute the remote Xray installer during uninstall.
  # Local cleanup below removes the common files created by the official installer and this script.
  rm -f /usr/local/bin/xray /usr/local/bin/xray_old 2>/dev/null || true

  rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray \
    /etc/systemd/system/xray.service /etc/systemd/system/xray@.service \
    /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d 2>/dev/null || true

  rm -f "$NGINX_SITE" "$LEGACY_NGINX_SITE" "$SYSCTL_FILE" 2>/dev/null || true
  rm -rf "$WEB_ROOT" "$LEGACY_WEB_ROOT" 2>/dev/null || true

  if [[ -n "${BASE_DOMAIN:-}" ]] && command -v certbot >/dev/null 2>&1; then
    if confirm "是否删除 Certbot 证书 ${BASE_DOMAIN}？" "Y"; then
      certbot delete --cert-name "$BASE_DOMAIN" --non-interactive 2>/dev/null || warn "Certbot 删除证书失败或证书不存在。"
    fi
  fi

  if confirm "是否移除 Nginx / Certbot 软件包？纯节点机器可选 Y" "N"; then
    echo "1. apt remove，保留部分全局配置"
    echo "2. apt purge，彻底删除软件包配置"
    local mode; mode=$(ask "请选择" "1")
    if command -v apt-get >/dev/null 2>&1; then
      if [[ "$mode" == "2" ]]; then
        confirm "最后确认 apt purge Nginx/Certbot？" "N" && apt-get purge -y nginx nginx-common nginx-core certbot python3-certbot-dns-cloudflare 2>/dev/null || true
      else
        apt-get remove -y nginx nginx-common nginx-core certbot python3-certbot-dns-cloudflare 2>/dev/null || true
      fi
      apt-get autoremove -y 2>/dev/null || true
    fi
  fi

  rm -rf "$APP_DIR" "$LEGACY_APP_DIR" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true
  log "完整卸载完成。"
}

uninstall_menu(){
  while true; do
    echo; echo "===== 卸载 / 清理 ====="
    echo "1. 完整卸载本脚本环境，纯节点机器可用"
    echo "2. 仅停止并禁用 Xray"
    echo "3. 仅删除 HY2 端口跳跃规则"
    echo "4. 仅清理脚本状态目录"
    echo "5. 删除 Cloudflare DNS 记录，可选择归属权校验或强制删除"
    echo "6. 仅关闭 Cloudflare 源站入口限制"
    echo "0. 返回"
    local c; c=$(ask "请选择" "0")
    case "$c" in
      1) full_uninstall_xem; pause ;;
      2) systemctl stop xray 2>/dev/null || true; systemctl disable xray 2>/dev/null || true; pause ;;
      3) remove_hy2_hopping_rules; pause ;;
      4) if confirm "确认删除 $APP_DIR 和旧目录 ${LEGACY_APP_DIR}？" "N"; then rm -rf "$APP_DIR" "$LEGACY_APP_DIR"; fi; pause ;;
      5) delete_cloudflare_records_menu; pause ;;
      6) disable_cf_origin_firewall; pause ;;
      0) break ;;
      *) warn "无效选择。" ;;
    esac
  done
}

main_menu(){
  need_root
  load_state
  while true; do
    echo
    echo "===== Xray Edge Manager v0.0.33-rc11-force-v4-egress ====="
    echo "1. 首次部署向导，推荐"
    echo "2. 安装/升级基础依赖"
    echo "3. 安装/升级 Xray-core"
    echo "4. 更新 geoip.dat / geosite.dat"
    echo "5. 网络优化 / BBR 状态与稳定优化"
    echo "6. Cloudflare 域名 / DNS / 小云朵管理"
    echo "7. 证书申请 / 续签 / 自动部署"
    echo "8. 查询 IPv4 / IPv6 / ASN 辅助报告"
    echo "9. 重新选择 IPv4/IPv6 协议，并刷新 DNS、Xray、Nginx、订阅"
    echo "10. 只重配 Nginx / 伪装站 / 订阅服务 / CDN 回源"
    echo "11. BestCF 优选域名管理，默认关闭"
    echo "12. 配置 Hysteria2 端口跳跃"
    echo "13. 本机防火墙端口处理，并可限制源站只允许 Cloudflare 回源"
    echo "14. 订阅管理"
    echo "15. 查看服务状态"
    echo "16. 查看分享链接 / 订阅链接"
    echo "17. 重启服务"
    echo "18. 部署摘要"
    echo "19. 安装状态"
    echo "20. 卸载 / 清理"
    echo "0. 退出"
    local c; c=$(ask "请选择" "0")
    case "$c" in
      1) install_full; pause ;;
      2) install_deps; pause ;;
      3) install_or_upgrade_xray; pause ;;
      4) update_geodata; if confirm "是否启用每周一凌晨 4-5 点安全自动更新 geodata？" "N"; then enable_geodata_timer; fi; pause ;;
      5)
        network_status
        echo "1. 应用稳定型网络优化"
        echo "2. 恢复/删除本脚本 sysctl 优化配置"
        echo "0. 返回"
        nc=$(ask "请选择" "0")
        case "$nc" in
          1) apply_stable_network_tuning ;;
          2) restore_network_tuning ;;
          *) ;;
        esac
        pause
        ;;
      6) setup_cloudflare; create_dns_records; pause ;;
      7) issue_certificate; pause ;;
      8) asn_report; pause ;;
      9) asn_report; select_ip_stack_strategy; select_protocols; create_dns_records; choose_reality_target; generate_xray_config; configure_nginx; regenerate_subscriptions_after_change; pause ;;
      10) configure_nginx; pause ;;
      11) bestcf_menu ;;
      12) configure_hy2_hopping_prompt; pause ;;
      13) handle_firewall_ports; pause ;;
      14) subscription_menu ;;
      15) show_status; pause ;;
      16) show_links; pause ;;
      17) restart_services; pause ;;
      18) deployment_summary; pause ;;
      19) show_installation_state; pause ;;
      20) uninstall_menu ;;
      0) exit 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

case "${1:-}" in
  --bestcf-update)
    need_root
    acquire_lock
    load_state
    fetch_bestcf_all
    regenerate_subscriptions_after_change
    exit 0
    ;;
  --geodata-update)
    need_root
    acquire_lock
    update_geodata
    # SAFETY FIX: verify config before restarting, for consistency.
    if [[ -f "$XRAY_CONFIG" ]] && xray_test_config "$XRAY_CONFIG" >/dev/null 2>&1; then
      systemctl restart xray 2>/dev/null || true
    else
      warn "Xray 配置测试未通过或配置文件不存在，跳过重启。"
    fi
    exit 0
    ;;
  --apply-hy2-hopping)
    need_root
    acquire_lock
    load_state
    if [[ -n "${HY2_HOP_RANGE:-}" ]]; then
      XEM_INTERNAL_APPLY_HY2=1 enable_hy2_hopping "$HY2_HOP_RANGE"
    fi
    exit 0
    ;;
  --apply-cf-origin-firewall)
    need_root
    acquire_lock
    load_state
    if [[ "${ENABLE_CF_ORIGIN_FIREWALL:-0}" == "1" ]]; then
      apply_cf_origin_firewall
    fi
    exit 0
    ;;
esac

need_root
acquire_lock
main_menu "$@"
