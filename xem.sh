#!/usr/bin/env bash
# Xray Edge Manager / Xray Anti-Block Manager
# v0.0.21 HY2 NAT lifecycle and off-peak geodata timer
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

# Global temp cleanup registry. Any temp file/dir registered here will be
# removed on normal exit or interruption. Missing paths are ignored.
declare -a GLOBAL_TEMP_FILES=()
cleanup_resources(){
  local tmp
  for tmp in "${GLOBAL_TEMP_FILES[@]:-}"; do
    [[ -n "$tmp" && -e "$tmp" ]] && rm -rf -- "$tmp" 2>/dev/null || true
  done
}
trap cleanup_resources EXIT INT TERM HUP QUIT

APP_DIR="/root/.xray-edge-manager"
STATE_FILE="$APP_DIR/state.env"
CF_ENV="$APP_DIR/cloudflare.env"
CF_CRED="$APP_DIR/cloudflare.ini"
SUB_DIR="$APP_DIR/subscription"
REMOTES_FILE="$SUB_DIR/remotes.conf"
BESTCF_DIR="$APP_DIR/bestcf"
BACKUP_DIR="$APP_DIR/backups"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
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
DEFAULT_HY2_HOP_RANGE="20000:20100"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh"
BESTCF_RELEASE_API="https://api.github.com/repos/DustinWin/BestCF/releases/tags/bestcf"
BESTCF_ASSETS="cmcc-ip.txt cucc-ip.txt ctcc-ip.txt bestcf-ip.txt proxy-ip.txt bestcf-domain.txt"
CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=20

mkdir -p "$APP_DIR" "$SUB_DIR" "$BESTCF_DIR" "$BACKUP_DIR"

log()  { echo -e "\033[32m[OK]\033[0m $*"; }
info() { echo -e "\033[36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*"; }
die()  { err "$*"; exit 1; }
pause(){ read -r -p "按回车继续..." _ || true; }
need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 运行。"; }

register_temp_path(){
  local tmp="$1"
  [[ -n "$tmp" ]] && GLOBAL_TEMP_FILES+=("$tmp")
}

mktemp_file(){
  local tmp
  tmp="$(mktemp "$@")" || die "创建临时文件失败。"
  register_temp_path "$tmp"
  echo "$tmp"
}

mktemp_dir(){
  local tmp
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

safe_source_env_file(){
  local file="$1" line key n=0
  [[ -f "$file" ]] || return 0

  # Do not source symlinks. State files contain credentials and are expected to
  # be regular files under APP_DIR.
  [[ ! -L "$file" ]] || die "拒绝读取符号链接状态文件：$file"
  chmod 600 "$file" 2>/dev/null || true

  # Keep compatibility with save_kv bash %q format, but reject lines that can
  # perform shell execution when sourced. This avoids a risky state migration.
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "状态文件格式非法：$file:$n"
    key="${line%%=*}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "状态文件键名非法：$file:$n"

    case "$line" in
      *'$('*|*'`'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*)
        die "状态文件包含不安全字符，拒绝 source：$file:$n"
        ;;
    esac
  done < "$file"

  # shellcheck disable=SC1090
  source "$file"
}

load_state(){
  safe_source_env_file "$STATE_FILE"
  safe_source_env_file "$CF_ENV"
  return 0
}

save_kv(){
  local file="$1" key="$2" value="$3" q tmp
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "非法配置键名：$key"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file" 2>/dev/null || true
  printf -v q '%q' "$value"

  tmp="$(mktemp_file "${file}.tmp.XXXXXX")"
  awk -v k="$key" -v v="$q" '
    BEGIN { found = 0 }
    index($0, k "=") == 1 {
      print k "=" v
      found = 1
      next
    }
    { print }
    END {
      if (!found) print k "=" v
    }
  ' "$file" > "$tmp" || { rm -f "$tmp"; die "写入临时状态文件失败：$tmp"; }
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
rand_token(){ openssl rand -hex 16; }
rand_path(){ echo "/$(openssl rand -hex 6)/xhttp"; }

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

public_ipv4(){
  curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || \
  curl -4 -fsS --max-time 8 https://ifconfig.co/ip 2>/dev/null || true
}

public_ipv6(){
  curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || \
  curl -6 -fsS --max-time 8 https://ifconfig.co/ip 2>/dev/null || true
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

install_deps(){
  need_root
  command -v apt-get >/dev/null 2>&1 || die "当前脚本自动安装依赖仅支持 Debian/Ubuntu apt 系。"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    curl wget jq openssl ca-certificates gnupg lsb-release \
    nginx certbot python3-certbot-dns-cloudflare \
    whois iproute2 iputils-ping iptables nftables tcpdump unzip tar sed grep coreutils perl \
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
    create 0640 root root
}
EOF2
  else
    warn "未找到 /etc/logrotate.d，跳过 Xray 日志轮转配置。"
  fi
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

ensure_xray_service(){
  need_root
  command -v xray >/dev/null 2>&1 || die "未找到 xray 二进制文件，请先安装/升级 Xray-core。"
  mkdir -p /usr/local/etc/xray /var/log/xray /etc/systemd/system

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
User=root
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

  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
}

install_or_upgrade_xray(){
  need_root
  local installer installer_url
  installer_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

  warn "即将从 XTLS/Xray-install 官方仓库下载并执行 Xray 安装脚本。"
  warn "这仍然属于远程脚本信任模型；脚本会先下载到临时文件并做 bash -n 语法检查，不再使用 curl | bash 直通执行。"
  if [[ "${XEM_TRUST_REMOTE_XRAY_INSTALL:-0}" != "1" ]]; then
    confirm "是否继续安装/升级 Xray-core？" "N" || die "已取消远程安装。你也可以先手动安装 xray，再回到脚本生成配置。"
  fi

  info "安装/升级 Xray-core..."
  installer="$(mktemp_file /tmp/xray-install.XXXXXX.sh)"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 120 -o "$installer" "$installer_url" || die "下载 Xray 官方安装脚本失败。"
  bash -n "$installer" || die "下载的 Xray 安装脚本语法检查失败，拒绝执行。"
  bash "$installer" install -u root
  ensure_xray_service
  log "Xray 安装/升级完成。"
  xray version || true
}

update_geodata(){
  need_root
  local tmp status geoip_url geosite_url
  tmp="$(mktemp_dir)"
  status=0
  geoip_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
  geosite_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

  info "安全更新 geoip.dat / geosite.dat：只下载数据文件和 sha256，不执行远程脚本。"

  (
    trap 'rm -rf "$tmp"' EXIT INT TERM
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
  warn "当前可能是 bash <(curl ...) 方式运行，无法可靠复制自身；将从仓库下载一次用于固化本地命令。"
  curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 60 "$SCRIPT_RAW_URL" -o /usr/local/bin/xem.tmp || die "下载本地命令失败。"
  if command -v perl >/dev/null 2>&1; then
    perl -C -pi -e 's/\x{00A0}/ /g' /usr/local/bin/xem.tmp 2>/dev/null || true
  fi
  bash -n /usr/local/bin/xem.tmp || die "下载的脚本语法检查失败，拒绝安装。"
  mv -f /usr/local/bin/xem.tmp /usr/local/bin/xem
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
  local name="$1" type="$2" content="$3" proxied="$4" list rec_id payload
  load_state
  [[ -n "${CF_ZONE_ID:-}" ]] || die "未配置 CF_ZONE_ID。"
  [[ -n "$content" ]] || { warn "$name $type 内容为空，跳过。"; return 0; }
  info "Upsert DNS: $type $name -> $content proxied=$proxied"
  list=$(curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -G "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" --data-urlencode "type=$type" --data-urlencode "name=$name") || return 1
  rec_id=$(echo "$list" | jq -r '.result[0].id // empty')
  payload=$(jq -nc --arg type "$type" --arg name "$name" --arg content "$content" --argjson proxied "$proxied" \
    '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied}')
  if [[ -n "$rec_id" ]]; then
    cf_api PATCH "/zones/$CF_ZONE_ID/dns_records/$rec_id" "$payload" >/dev/null
  else
    cf_api POST "/zones/$CF_ZONE_ID/dns_records" "$payload" >/dev/null
  fi
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
  echo "可以输入组合，例如：123、13、23、1234。" >&2
  mode=$(ask "请选择 ${label} 协议组合" "${current:-$default_mode}")
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
  ip4="${PUBLIC_IPV4:-$(public_ipv4)}"
  ip6="${PUBLIC_IPV6:-$(public_ipv6)}"
  [[ -n "$ip4" ]] && save_kv "$STATE_FILE" PUBLIC_IPV4 "$ip4"
  [[ -n "$ip6" ]] && save_kv "$STATE_FILE" PUBLIC_IPV6 "$ip6"

  echo
  echo "===== IPv4 / IPv6 独立协议组合 ====="
  echo "IPv4 和 IPv6 各自输入协议组合，例如 IPv4=123，IPv6=13。"
  echo "1/4 用 v4/v6 子域名直连；2 用母域名 CDN；3 是 HY2 UDP。"

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
  if [[ "$default_p" == *2* ]]; then save_kv "$STATE_FILE" ENABLE_CDN "1"; else save_kv "$STATE_FILE" ENABLE_CDN "0"; fi
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
    port=$(ask "CDN 公网端口，只能是 443/2053/2083/2087/2096/8443" "${CDN_PORT:-443}")
    valid_port "$port" || die "端口无效。"
    is_cf_https_port "$port" || die "CDN 模式端口必须是 Cloudflare HTTPS 可代理端口：$CF_HTTPS_PORTS"
    save_kv "$STATE_FILE" CDN_PORT "$port"
  else
    save_kv "$STATE_FILE" ENABLE_CDN "0"
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
    port=$(ask "XHTTP + REALITY 直连端口，默认推荐 2443，可自定义" "${XHTTP_REALITY_PORT:-2443}")
    valid_port "$port" || die "端口无效。"
    save_kv "$STATE_FILE" XHTTP_REALITY_PORT "$port"
  fi

  if [[ "$p" == *4* ]]; then
    port=$(ask "REALITY + Vision 端口，默认推荐 3443，可自定义" "${REALITY_VISION_PORT:-3443}")
    valid_port "$port" || die "端口无效。"
    save_kv "$STATE_FILE" REALITY_VISION_PORT "$port"
  fi

  if [[ "$p" == *3* ]]; then
    port=$(ask "Hysteria2 UDP 监听端口，默认推荐 443，可自定义" "${HY2_PORT:-443}")
    valid_port "$port" || die "端口无效。"
    save_kv "$STATE_FILE" HY2_PORT "$port"
    warn "Xray Hysteria2 是较新功能。如连接失败，优先检查客户端内核、UDP 放行和 Xray 版本。"
  fi

  if [[ "$p" == *1* || "$p" == *3* || "$p" == *4* ]]; then
    if confirm "是否启用 v4/v6 出口绑定？v4 入站走 IPv4 出口，v6 入站走 IPv6 出口" "Y"; then
      save_kv "$STATE_FILE" ENABLE_IP_STACK_BINDING "1"
    else
      warn "未启用出口绑定时，仅不强制 v4 入站走 IPv4 出口、v6 入站走 IPv6 出口；监听仍会按 v4/v6 精确绑定。"
      save_kv "$STATE_FILE" ENABLE_IP_STACK_BINDING "0"
    fi
  fi
  load_state
  log "协议组合：$p"
}
create_dns_records(){
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || configure_base_domain
  [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE_ID:-}" ]] || setup_cloudflare
  local ip4 ip6
  ip4="${PUBLIC_IPV4:-$(public_ipv4)}"
  ip6="${PUBLIC_IPV6:-$(public_ipv6)}"
  [[ -n "$ip4" ]] && save_kv "$STATE_FILE" PUBLIC_IPV4 "$ip4"
  [[ -n "$ip6" ]] && save_kv "$STATE_FILE" PUBLIC_IPV6 "$ip6"

  if [[ -n "$ip4" ]]; then
    if stack_has_cdn "${IPV4_PROTOCOLS:-0}"; then cf_upsert_record "$BASE_DOMAIN" A "$ip4" true; fi
    if stack_has_direct_protocol "${IPV4_PROTOCOLS:-0}"; then cf_upsert_record "v4.$BASE_DOMAIN" A "$ip4" false; fi
  fi
  if [[ -n "$ip6" ]]; then
    if stack_has_cdn "${IPV6_PROTOCOLS:-0}"; then cf_upsert_record "$BASE_DOMAIN" AAAA "$ip6" true; fi
    if stack_has_direct_protocol "${IPV6_PROTOCOLS:-0}"; then cf_upsert_record "v6.$BASE_DOMAIN" AAAA "$ip6" false; fi
  fi
  log "DNS 记录处理完成。最多 3 个域名：BASE、v4.BASE、v6.BASE。"
}

install_cert_deploy_hook(){
  need_root
  mkdir -p "$(dirname "$CERT_DEPLOY_HOOK")"
  cat > "$CERT_DEPLOY_HOOK" <<'EOF2'
#!/usr/bin/env bash
# Generated by Xray Edge Manager.
# Certbot deploy hook: reload Nginx only after nginx -t; restart Xray only after xray -test.
set -u

if command -v nginx >/dev/null 2>&1; then
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
  fi
fi

if command -v xray >/dev/null 2>&1 && [[ -f /usr/local/etc/xray/config.json ]]; then
  if xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
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
  cat > "$CF_CRED" <<EOF2
dns_cloudflare_api_token = $CF_API_TOKEN
EOF2
  chmod 600 "$CF_CRED"
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
}

backup_configs(){
  mkdir -p "$APP_DIR" "$SUB_DIR" "$BESTCF_DIR" "$BACKUP_DIR"
  local ts; ts=$(date +%F-%H%M%S)
  [[ -f "$XRAY_CONFIG" ]] && cp -a "$XRAY_CONFIG" "$BACKUP_DIR/config.json.$ts.bak" && save_kv "$STATE_FILE" LAST_XRAY_BACKUP "$BACKUP_DIR/config.json.$ts.bak" || true
  [[ -f "$NGINX_SITE" ]] && cp -a "$NGINX_SITE" "$BACKUP_DIR/nginx.$ts.bak" && save_kv "$STATE_FILE" LAST_NGINX_BACKUP "$BACKUP_DIR/nginx.$ts.bak" || true
  [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$BACKUP_DIR/state.env.$ts.bak" || true
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
  local p proc
  if protocol_enabled 2; then
    p="${CDN_PORT:-443}"; proc=$(get_proc_tcp "$p")
    [[ -z "$proc" || "$proc" == *nginx* ]] || die "TCP $p 被非 Nginx 进程占用：$proc"
  fi
  if protocol_enabled 1; then
    p="${XHTTP_REALITY_PORT:-2443}"; proc=$(get_proc_tcp "$p")
    [[ -z "$proc" || "$proc" == *xray* ]] || die "TCP $p 被非 Xray 进程占用：$proc"
  fi
  if protocol_enabled 4; then
    p="${REALITY_VISION_PORT:-3443}"; proc=$(get_proc_tcp "$p")
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

generate_xray_config(){
  need_root
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || configure_base_domain
  [[ -n "${REALITY_TARGET:-}" ]] || choose_reality_target
  generate_keys_if_needed
  load_state
  preflight_ports
  backup_configs
  mkdir -p /usr/local/etc/xray /var/log/xray

  local in_tmp out_tmp route_tmp xray_target_tmp first_in=1 first_out=1 first_route=1 ip4 ip6 bind_ip4="" bind_ip6="" bind
  in_tmp=$(mktemp_file); out_tmp=$(mktemp_file); route_tmp=$(mktemp_file)
  ip4="${PUBLIC_IPV4:-$(public_ipv4)}"; ip6="${PUBLIC_IPV6:-$(public_ipv6)}"
  [[ -n "$ip4" ]] && save_kv "$STATE_FILE" PUBLIC_IPV4 "$ip4" && bind_ip4=$(local_ipv4_for_bind "$ip4") && save_kv "$STATE_FILE" BIND_IPV4 "$bind_ip4"
  [[ -n "$ip6" ]] && save_kv "$STATE_FILE" PUBLIC_IPV6 "$ip6" && bind_ip6=$(local_ipv6_for_bind "$ip6") && save_kv "$STATE_FILE" BIND_IPV6 "$bind_ip6"
  bind="${ENABLE_IP_STACK_BINDING:-1}"

  append_json_obj "$out_tmp" first_out <<'EOF2'
    {"tag":"direct","protocol":"freedom"}
EOF2
  append_json_obj "$out_tmp" first_out <<'EOF2'
    {"tag":"block","protocol":"blackhole"}
EOF2
  append_json_obj "$out_tmp" first_out <<'EOF2'
    {"tag":"out-v4","protocol":"freedom","settings":{"domainStrategy":"UseIPv4"}}
EOF2
  append_json_obj "$out_tmp" first_out <<'EOF2'
    {"tag":"out-v6","protocol":"freedom","settings":{"domainStrategy":"UseIPv6"}}
EOF2

  # Zero-trust default: block access to private/local networks before per-inbound routing rules.
  append_json_obj "$route_tmp" first_route <<'EOF2'
    {"type":"field","ip":["geoip:private","127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","::1/128","fc00::/7","fe80::/10"],"outboundTag":"block"}
EOF2

  if protocol_enabled 1; then
    if [[ -n "$bind_ip4" && "${IPV4_PROTOCOLS:-0}" == *1* ]]; then
      append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-v4-xhttp-reality","listen":"${bind_ip4}","port":${XHTTP_REALITY_PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}","email":"v4-xhttp-reality"}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"reality","xhttpSettings":{"path":"${XHTTP_REALITY_PATH}","mode":"auto"},"realitySettings":{"show":false,"dest":"${REALITY_TARGET}:443","serverNames":["${REALITY_TARGET}"],"privateKey":"${REALITY_PRIVATE_KEY}","shortIds":["${SHORT_ID}"]}}}
EOF2
      [[ "$bind" == "1" ]] && append_json_obj "$route_tmp" first_route <<'EOF2'
    {"type":"field","inboundTag":["in-v4-xhttp-reality"],"outboundTag":"out-v4"}
EOF2
    fi
    if [[ -n "$bind_ip6" && "${IPV6_PROTOCOLS:-0}" == *1* ]]; then
      append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-v6-xhttp-reality","listen":"${bind_ip6}","port":${XHTTP_REALITY_PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}","email":"v6-xhttp-reality"}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"reality","xhttpSettings":{"path":"${XHTTP_REALITY_PATH}","mode":"auto"},"realitySettings":{"show":false,"dest":"${REALITY_TARGET}:443","serverNames":["${REALITY_TARGET}"],"privateKey":"${REALITY_PRIVATE_KEY}","shortIds":["${SHORT_ID}"]}}}
EOF2
      [[ "$bind" == "1" ]] && append_json_obj "$route_tmp" first_route <<'EOF2'
    {"type":"field","inboundTag":["in-v6-xhttp-reality"],"outboundTag":"out-v6"}
EOF2
    fi
  fi

  if protocol_enabled 2 || protocol_enabled 5; then
    append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-xhttp-cdn-local","listen":"127.0.0.1","port":${XHTTP_CDN_LOCAL_PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}","email":"xhttp-cdn"}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"path":"${XHTTP_CDN_PATH}","mode":"auto"}}}
EOF2
  fi

  if protocol_enabled 3; then
    if [[ -n "$bind_ip4" && "${IPV4_PROTOCOLS:-0}" == *3* ]]; then
      append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-v4-hysteria2-udp","listen":"${bind_ip4}","port":${HY2_PORT},"protocol":"hysteria","settings":{"version":2,"clients":[{"auth":"${HY2_AUTH}","email":"v4-hy2"}]},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"alpn":["h3"],"certificates":[{"certificateFile":"/etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem","keyFile":"/etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem"}]},"hysteriaSettings":{"version":2,"auth":"${HY2_AUTH}","udpIdleTimeout":60}}}
EOF2
      [[ "$bind" == "1" ]] && append_json_obj "$route_tmp" first_route <<'EOF2'
    {"type":"field","inboundTag":["in-v4-hysteria2-udp"],"outboundTag":"out-v4"}
EOF2
    fi
    if [[ -n "$bind_ip6" && "${IPV6_PROTOCOLS:-0}" == *3* ]]; then
      append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-v6-hysteria2-udp","listen":"${bind_ip6}","port":${HY2_PORT},"protocol":"hysteria","settings":{"version":2,"clients":[{"auth":"${HY2_AUTH}","email":"v6-hy2"}]},"streamSettings":{"network":"hysteria","security":"tls","tlsSettings":{"alpn":["h3"],"certificates":[{"certificateFile":"/etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem","keyFile":"/etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem"}]},"hysteriaSettings":{"version":2,"auth":"${HY2_AUTH}","udpIdleTimeout":60}}}
EOF2
      [[ "$bind" == "1" ]] && append_json_obj "$route_tmp" first_route <<'EOF2'
    {"type":"field","inboundTag":["in-v6-hysteria2-udp"],"outboundTag":"out-v6"}
EOF2
    fi
  fi

  if protocol_enabled 4; then
    if [[ -n "$bind_ip4" && "${IPV4_PROTOCOLS:-0}" == *4* ]]; then
      append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-v4-reality-vision","listen":"${bind_ip4}","port":${REALITY_VISION_PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision","email":"v4-reality-vision"}],"decryption":"none"},"streamSettings":{"network":"raw","security":"reality","realitySettings":{"show":false,"dest":"${REALITY_TARGET}:443","serverNames":["${REALITY_TARGET}"],"privateKey":"${REALITY_PRIVATE_KEY}","shortIds":["${SHORT_ID}"]}}}
EOF2
      [[ "$bind" == "1" ]] && append_json_obj "$route_tmp" first_route <<'EOF2'
    {"type":"field","inboundTag":["in-v4-reality-vision"],"outboundTag":"out-v4"}
EOF2
    fi
    if [[ -n "$bind_ip6" && "${IPV6_PROTOCOLS:-0}" == *4* ]]; then
      append_json_obj "$in_tmp" first_in <<EOF2
    {"tag":"in-v6-reality-vision","listen":"${bind_ip6}","port":${REALITY_VISION_PORT},"protocol":"vless","settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision","email":"v6-reality-vision"}],"decryption":"none"},"streamSettings":{"network":"raw","security":"reality","realitySettings":{"show":false,"dest":"${REALITY_TARGET}:443","serverNames":["${REALITY_TARGET}"],"privateKey":"${REALITY_PRIVATE_KEY}","shortIds":["${SHORT_ID}"]}}}
EOF2
      [[ "$bind" == "1" ]] && append_json_obj "$route_tmp" first_route <<'EOF2'
    {"type":"field","inboundTag":["in-v6-reality-vision"],"outboundTag":"out-v6"}
EOF2
    fi
  fi

  xray_target_tmp=$(mktemp_file "$(dirname "$XRAY_CONFIG")/.config.json.XXXXXX")
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
  rm -f "$in_tmp" "$out_tmp" "$route_tmp"

  # Do not overwrite the live Xray config until the candidate has passed all checks.
  # The temp file is created in the same directory as the target so mv is atomic.
  if ! jq empty "$xray_target_tmp" >/dev/null 2>&1; then die "生成的 Xray JSON 非法，已阻断更新，生产配置未被覆盖。"; fi
  if ! xray run -test -config "$xray_target_tmp" >/dev/null 2>&1; then die "Xray 临时配置测试失败，已阻断更新，生产配置未被覆盖。"; fi
  atomic_move_into_place "$xray_target_tmp" "$XRAY_CONFIG" "644"
  log "Xray 配置生成、测试并原子化应用成功。"
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
  mkdir -p "$WEB_ROOT"
  local n zip tmp
  n=$((RANDOM % 9 + 1))
  zip="html${n}.zip"
  tmp=$(mktemp_dir)
  info "随机下载伪装站模板：v2ray-agent/fodder/blog/unable/${zip}"
  if curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 60 -o "$tmp/$zip" "$FODDER_BASE_URL/$zip" && unzip -q "$tmp/$zip" -d "$tmp/site"; then
    rm -rf "$WEB_ROOT"/*
    shopt -s dotglob nullglob
    local entries=("$tmp/site"/*)
    if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
      cp -a "${entries[0]}"/* "$WEB_ROOT"/
    else
      cp -a "$tmp/site"/* "$WEB_ROOT"/
    fi
    shopt -u dotglob nullglob
    [[ -f "$WEB_ROOT/index.html" ]] || echo '<!doctype html><html><body><h1>Welcome</h1><p>It works.</p></body></html>' > "$WEB_ROOT/index.html"
    log "伪装站模板已安装：${zip}"
  else
    warn "伪装站模板下载或解压失败，使用内置默认页面。"
    cat > "$WEB_ROOT/index.html" <<'EOF2'
<!doctype html><html><head><meta charset="utf-8"><title>Welcome</title></head><body><h1>Welcome</h1><p>It works.</p></body></html>
EOF2
  fi
  rm -rf "$tmp"
  chmod -R a+rX "$WEB_ROOT" 2>/dev/null || true
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
  mkdir -p "$WEB_ROOT" "$WEB_ROOT/sub" "$SUB_DIR"
  chmod 755 "$WEB_ROOT" "$WEB_ROOT/sub" 2>/dev/null || true
  touch "$WEB_ROOT/sub/${SUB_TOKEN}"
  chmod 644 "$WEB_ROOT/sub/${SUB_TOKEN}" 2>/dev/null || true

  local nginx_http_v6_listen="" nginx_https_v6_listen="" nginx_https_listen="" nginx_http2_directive="" nginx_version="" nginx_target_tmp=""
  nginx_version=$(nginx -v 2>&1 | sed -nE 's#.*nginx/([0-9.]+).*#\1#p' | head -n1 || true)
  if version_ge "$nginx_version" "1.25.1"; then
    nginx_https_listen="    listen ${CDN_PORT:-443} ssl;"
    nginx_http2_directive="    http2 on;"
    [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *2* ]] && nginx_https_v6_listen="    listen [::]:${CDN_PORT:-443} ssl;"
    info "Nginx ${nginx_version:-unknown}：使用新版 HTTP/2 写法。"
  else
    # Older Nginx does not understand the standalone "http2 on;" directive.
    # If dpkg is unavailable, version_ge falls back to sort -V; if both are unavailable,
    # use the older syntax and let nginx -t be the final gatekeeper.
    nginx_https_listen="    listen ${CDN_PORT:-443} ssl http2;"
    nginx_http2_directive=""
    [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *2* ]] && nginx_https_v6_listen="    listen [::]:${CDN_PORT:-443} ssl http2;"
    info "Nginx ${nginx_version:-unknown}：使用兼容旧版的 HTTP/2 写法。"
  fi
  if [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *2* ]]; then
    nginx_http_v6_listen="    listen [::]:80;"
  fi

  backup_configs
  install_random_camouflage

  nginx_target_tmp=$(mktemp_file "$(dirname "$NGINX_SITE")/.xray-edge-manager.conf.XXXXXX")
  cat > "$nginx_target_tmp" <<EOF2
server {
    listen 80;
${nginx_http_v6_listen}
    server_name ${BASE_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
${nginx_https_listen}
${nginx_http2_directive}
${nginx_https_v6_listen}
    server_name ${BASE_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root ${WEB_ROOT};
    index index.html;

    location ^~ ${XHTTP_CDN_PATH} {
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

    location ^~ /sub/ {
        default_type text/plain;
        root ${WEB_ROOT};
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF2
  [[ -s "$nginx_target_tmp" ]] || die "生成的 Nginx 临时配置为空，已阻断更新。"
  grep -q "server_name ${BASE_DOMAIN};" "$nginx_target_tmp" || die "Nginx 临时配置缺少 server_name，已阻断更新。"
  grep -q "proxy_pass http://127.0.0.1:${XHTTP_CDN_LOCAL_PORT};" "$nginx_target_tmp" || die "Nginx 临时配置缺少 XHTTP proxy_pass，已阻断更新。"

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
  log "Nginx / 伪装站 / 订阅路径配置完成。"
}

uri_encode(){
  local s="$1" out="" i c
  for ((i=0;i<${#s};i++)); do
    c=${s:i:1}
    case "$c" in [a-zA-Z0-9.~_-]) out+="$c" ;; *) printf -v out '%s%%%02X' "$out" "'${c}" ;; esac
  done
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

generate_mihomo_reference(){
  load_state
  local f="$SUB_DIR/mihomo-reference.yaml"
  cat > "$f" <<EOF2
# 仅供参考：对外订阅仍只发布 base64。
# 建议使用 Clash Verge Rev / Mihomo 新版内核测试 XHTTP。
proxies:
EOF2
  if protocol_enabled 1; then
    if [[ -n "${PUBLIC_IPV4:-}" && "${IPV4_PROTOCOLS:-0}" == *1* ]]; then
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
    if [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *1* ]]; then
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

  if protocol_enabled 2; then
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

  if protocol_enabled 5; then
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
    if [[ -n "${PUBLIC_IPV4:-}" && "${IPV4_PROTOCOLS:-0}" == *3* ]]; then
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
    if [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *3* ]]; then
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
    [[ -n "${PUBLIC_IPV4:-}" && "${IPV4_PROTOCOLS:-0}" == *1* ]] && add_vless_xhttp_reality_link "v4.${BASE_DOMAIN}" "${NODE_NAME:-node}-v4-XHTTP-REALITY" "$raw"
    [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *1* ]] && add_vless_xhttp_reality_link "v6.${BASE_DOMAIN}" "${NODE_NAME:-node}-v6-XHTTP-REALITY" "$raw"
  fi

  if protocol_enabled 2; then
    add_vless_xhttp_cdn_link "$BASE_DOMAIN" "${NODE_NAME:-node}-CDN-XHTTP-Origin" "$raw" "${CDN_PORT:-443}"
  fi

  # 5 = CDN 入口扩展。优先生成 BestCF 节点；若 BestCF 数据还没拉取，则保留一个母域名入口，防止节点为空。
  if protocol_enabled 5; then
    local before_count after_count
    before_count=$(wc -l < "$raw" 2>/dev/null || echo 0)
    generate_bestcf_subscription_nodes "$raw"
    after_count=$(wc -l < "$raw" 2>/dev/null || echo 0)
    if [[ "$after_count" -eq "$before_count" ]]; then
      add_vless_xhttp_cdn_link "$BASE_DOMAIN" "${NODE_NAME:-node}-CDN-XHTTP-Entry" "$raw" "${CDN_PORT:-443}"
      warn "协议 5 未找到可用 BestCF 数据，已自动退回母域名 CDN Entry。"
    fi
  elif protocol_enabled 2; then
    generate_bestcf_subscription_nodes "$raw"
  fi

  if protocol_enabled 3; then
    [[ -n "${PUBLIC_IPV4:-}" && "${IPV4_PROTOCOLS:-0}" == *3* ]] && add_hy2_link "v4.${BASE_DOMAIN}" "${NODE_NAME:-node}-v4-HY2-UDP${HY2_PORT:-443}" "$raw"
    [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *3* ]] && add_hy2_link "v6.${BASE_DOMAIN}" "${NODE_NAME:-node}-v6-HY2-UDP${HY2_PORT:-443}" "$raw"
  fi

  if protocol_enabled 4; then
    [[ -n "${PUBLIC_IPV4:-}" && "${IPV4_PROTOCOLS:-0}" == *4* ]] && add_reality_vision_link "v4.${BASE_DOMAIN}" "${NODE_NAME:-node}-v4-REALITY-Vision" "$raw"
    [[ -n "${PUBLIC_IPV6:-}" && "${IPV6_PROTOCOLS:-0}" == *4* ]] && add_reality_vision_link "v6.${BASE_DOMAIN}" "${NODE_NAME:-node}-v6-REALITY-Vision" "$raw"
  fi

  sed -i '/^$/d' "$raw"
  base64 -w0 "$raw" > "$b64"
  cp -f "$b64" "$WEB_ROOT/sub/$SUB_TOKEN"
  chmod 755 "$WEB_ROOT" "$WEB_ROOT/sub" 2>/dev/null || true
  chmod 644 "$WEB_ROOT/sub/$SUB_TOKEN" 2>/dev/null || true
  generate_mihomo_reference
  log "本机 b64 订阅已生成：$b64"
  echo "订阅链接： https://${BASE_DOMAIN}/sub/${SUB_TOKEN}"
}

regenerate_subscriptions_after_change(){
  load_state
  if [[ -z "${BASE_DOMAIN:-}" ]]; then
    warn "未设置母域名，跳过自动刷新订阅。"
    return 0
  fi
  generate_subscription || { warn "本机订阅自动刷新失败，请稍后手动执行菜单 14 -> 1。"; return 0; }
  if [[ -s "${REMOTES_FILE:-$SUB_DIR/remotes.conf}" ]]; then
    merge_remote_subscriptions || warn "合并订阅自动刷新失败，请稍后手动执行菜单 14 -> 8。"
  fi
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
    warn "HY2 跳跃端口范围过大（$count > $max_flush），为避免 CPU 尖峰和误伤现有 443/UDP 连接，跳过 conntrack 精确清理。旧 UDP 流会等待内核超时。"
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
  ensure_iptables
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
  elif confirm "是否安装 netfilter-persistent 持久化规则？" "Y"; then
    apt-get install -y iptables-persistent netfilter-persistent || true
    netfilter-persistent save || true
  fi
  save_kv "$STATE_FILE" HY2_HOP_RANGE "$range"
  save_kv "$STATE_FILE" HY2_HOP_TO_PORT "$to_port"
  if [[ "${XEM_INTERNAL_APPLY_HY2:-0}" != "1" ]]; then
    install_hy2_hopping_service
  fi
  log "端口跳跃规则已设置。请确认云安全组放行 UDP $start-$end。"
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

handle_firewall_ports(){
  load_state
  local tcp_ports=() udp_ports=()
  [[ "${PROTOCOLS:-0}" == *2* || "${PROTOCOLS:-0}" == *5* ]] && tcp_ports+=("${CDN_PORT:-443}")
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
}

restart_services(){
  ensure_xray_service
  if ! xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
    restore_latest_xray_config || true
    die "Xray 配置测试失败，已回滚。"
  fi
  if ! systemctl restart xray; then
    restore_latest_xray_config || true
    ensure_xray_service || true
    if xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
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
  ip4="${PUBLIC_IPV4:-$(public_ipv4)}"; ip6="${PUBLIC_IPV6:-$(public_ipv6)}"
  [[ -n "$ip4" ]] && save_kv "$STATE_FILE" PUBLIC_IPV4 "$ip4"
  [[ -n "$ip6" ]] && save_kv "$STATE_FILE" PUBLIC_IPV6 "$ip6"
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

  # Safety guard: BestCF downloader must never write outside BESTCF_DIR.
  case "$output" in
    "$BESTCF_DIR"/*) ;;
    *) warn "BestCF 输出路径不安全，已拒绝：$output"; return 1 ;;
  esac

  tmp="${output}.tmp"
  raw="${output}.raw"
  url=$(bestcf_asset_url "$asset")
  info "下载 BestCF：$asset"

  if ! curl -fL --retry 3 --retry-delay 2 \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
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

apply_stable_network_tuning(){
  cat > "$SYSCTL_FILE" <<'EOF2'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
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
  sysctl --system >/dev/null || true
  log "已应用稳定型网络优化。"
}

show_status(){
  echo "===== Xray ====="; xray version 2>/dev/null || true; systemctl status xray --no-pager -l 2>/dev/null || true
  echo "===== Nginx ====="; nginx -t 2>&1 || true; systemctl status nginx --no-pager -l 2>/dev/null || true
  echo "===== Listen ====="; ss -tulpen | grep -E ':(443|2053|2083|2087|2096|8443|2443|3443)\b' || true
}

show_links(){
  load_state
  echo "===== 本机订阅 ====="
  echo "https://${BASE_DOMAIN:-<BASE_DOMAIN>}/sub/${SUB_TOKEN:-<TOKEN>}"
  if [[ -n "${MERGED_SUB_TOKEN:-}" ]]; then
    echo "===== 合并订阅 ====="
    echo "https://${BASE_DOMAIN:-<BASE_DOMAIN>}/sub/${MERGED_SUB_TOKEN}"
  fi
  echo
  echo "===== local.raw ====="
  [[ -f "$SUB_DIR/local.raw" ]] && cat "$SUB_DIR/local.raw" || warn "尚未生成 local.raw。"
  echo
  [[ -f "$SUB_DIR/mihomo-reference.yaml" ]] && echo "Mihomo 参考片段：$SUB_DIR/mihomo-reference.yaml" || true
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
  echo "BestCF: ${BESTCF_ENABLED:-0} / ${BESTCF_MODE:-off} / 每类${BESTCF_PER_CATEGORY_LIMIT:-2} / 总上限${BESTCF_TOTAL_LIMIT:-10}"
  echo "订阅: https://${BASE_DOMAIN:-BASE}/sub/${SUB_TOKEN:-TOKEN}"
  [[ -n "${MERGED_SUB_TOKEN:-}" ]] && echo "合并订阅: https://${BASE_DOMAIN:-BASE}/sub/${MERGED_SUB_TOKEN}"
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
  (protocol_enabled 2 || protocol_enabled 5) && configure_nginx
  configure_hy2_hopping_prompt
  handle_firewall_ports
  restart_services
  generate_subscription
  deployment_summary
  log "首次部署流程完成。"
}

list_remote_subscriptions(){
  touch "$REMOTES_FILE"
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
  touch "$REMOTES_FILE"
  echo "${name}|${url}" >> "$REMOTES_FILE"
  log "已添加远程订阅：$name"
}

delete_remote_subscription(){
  touch "$REMOTES_FILE"
  list_remote_subscriptions
  local n tmp
  n=$(ask "请输入要删除的编号" "")
  [[ "$n" =~ ^[0-9]+$ ]] || { warn "编号无效。"; return 0; }
  tmp=$(mktemp_file)
  awk -v n="$n" 'NR!=n' "$REMOTES_FILE" > "$tmp"
  mv "$tmp" "$REMOTES_FILE"
  log "已删除编号：$n"
}

clear_remote_subscriptions(){
  if confirm "确认清空所有远程订阅？" "N"; then
    : > "$REMOTES_FILE"
    log "已清空远程订阅。"
  fi
}

merge_remote_subscriptions(){
  load_state
  generate_keys_if_needed
  load_state
  mkdir -p "$SUB_DIR" "$WEB_ROOT/sub"
  [[ -f "$SUB_DIR/local.raw" ]] || generate_subscription
  touch "$REMOTES_FILE"
  local remote_raw="$SUB_DIR/remote.raw" merged="$SUB_DIR/merged.raw" merged_b64="$SUB_DIR/merged.b64"
  local name url data
  : > "$remote_raw"
  while IFS='|' read -r name url; do
    [[ -z "${url:-}" || "$name" =~ ^# ]] && continue
    info "拉取远程订阅：$name"
    data=$(curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 30 "$url" 2>/dev/null || true)
    [[ -z "$data" ]] && { warn "拉取失败：$name"; continue; }
    if printf '%s' "$data" | base64 -d >> "$remote_raw" 2>/dev/null; then
      echo >> "$remote_raw"
    else
      warn "解码失败：$name"
    fi
  done < "$REMOTES_FILE"
  cat "$SUB_DIR/local.raw" "$remote_raw" 2>/dev/null | sed '/^$/d' | awk '!seen[$0]++' > "$merged"
  base64 -w0 "$merged" > "$merged_b64"
  cp -f "$merged_b64" "$WEB_ROOT/sub/$MERGED_SUB_TOKEN"
  chmod 755 "$WEB_ROOT" "$WEB_ROOT/sub" 2>/dev/null || true
  chmod 644 "$WEB_ROOT/sub/$MERGED_SUB_TOKEN" 2>/dev/null || true
  log "合并订阅已生成：$merged_b64"
  echo "合并订阅链接： https://${BASE_DOMAIN}/sub/${MERGED_SUB_TOKEN}"
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
  resp=$(cf_get_record_json "$name" "$type") || { warn "无法读取 $type $name，跳过。"; return 0; }
  count=$(echo "$resp" | jq -r '.result | length')
  [[ "$count" -gt 0 ]] || { info "Cloudflare 中不存在 $type $name，跳过。"; return 0; }
  for ((i=0;i<count;i++)); do
    rec_id=$(echo "$resp" | jq -r ".result[$i].id // empty")
    content=$(echo "$resp" | jq -r ".result[$i].content // empty")
    [[ -n "$rec_id" ]] || continue
    if [[ "$mode" == "owned" && -n "$expected" && "$content" != "$expected" ]]; then
      warn "跳过 $type $name：当前指向 $content，不等于本机 IP $expected。"
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
  ip4="${PUBLIC_IPV4:-$(public_ipv4)}"; ip6="${PUBLIC_IPV6:-$(public_ipv6)}"
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
  systemctl disable --now xem-hy2-hopping.service 2>/dev/null || true
  rm -f /etc/systemd/system/xem-bestcf-update.service /etc/systemd/system/xem-bestcf-update.timer
  rm -f /etc/systemd/system/xem-geodata-update.service /etc/systemd/system/xem-geodata-update.timer
  rm -f /etc/systemd/system/xem-hy2-hopping.service
  rm -f "$CERT_DEPLOY_HOOK" /etc/logrotate.d/xray 2>/dev/null || true
  remove_hy2_hopping_rules || true

  # Do not fetch and execute the remote Xray installer during uninstall.
  # Local cleanup below removes the common files created by the official installer and this script.
  rm -f /usr/local/bin/xray /usr/local/bin/xray_old 2>/dev/null || true

  rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray \
    /etc/systemd/system/xray.service /etc/systemd/system/xray@.service \
    /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d 2>/dev/null || true

  rm -f "$NGINX_SITE" "$LEGACY_NGINX_SITE" 2>/dev/null || true
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
    echo "0. 返回"
    local c; c=$(ask "请选择" "0")
    case "$c" in
      1) full_uninstall_xem; pause ;;
      2) systemctl stop xray 2>/dev/null || true; systemctl disable xray 2>/dev/null || true; pause ;;
      3) remove_hy2_hopping_rules; pause ;;
      4) if confirm "确认删除 $APP_DIR 和旧目录 $LEGACY_APP_DIR？" "N"; then rm -rf "$APP_DIR" "$LEGACY_APP_DIR"; fi; pause ;;
      5) delete_cloudflare_records_menu; pause ;;
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
    echo "===== Xray Edge Manager v0.0.21 ====="
    echo "1. 首次部署向导，推荐"
    echo "2. 安装/升级基础依赖"
    echo "3. 安装/升级 Xray-core"
    echo "4. 更新 geoip.dat / geosite.dat"
    echo "5. 网络优化 / BBR 状态与稳定优化"
    echo "6. Cloudflare 域名 / DNS / 小云朵管理"
    echo "7. 证书申请 / 续签 / 自动部署"
    echo "8. 查询 IPv4 / IPv6 / ASN 辅助报告"
    echo "9. IPv4 / IPv6 分协议部署 + 生成 Xray 配置"
    echo "10. 配置 CDN / Nginx / 伪装站"
    echo "11. BestCF 优选域名管理，默认关闭"
    echo "12. 配置 Hysteria2 端口跳跃"
    echo "13. 本机防火墙端口处理"
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
      5) network_status; if confirm "是否应用稳定型网络优化？" "N"; then apply_stable_network_tuning; fi; pause ;;
      6) setup_cloudflare; create_dns_records; pause ;;
      7) issue_certificate; pause ;;
      8) asn_report; pause ;;
      9) asn_report; select_ip_stack_strategy; select_protocols; choose_reality_target; generate_xray_config; regenerate_subscriptions_after_change; pause ;;
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
    systemctl restart xray 2>/dev/null || true
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
esac

acquire_lock
main_menu "$@"
