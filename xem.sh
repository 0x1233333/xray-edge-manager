#!/usr/bin/env bash
# xray-anti-block-manager-r2.sh
# Alpha R3：单文件 Xray 抗封锁部署 / 域名 / 证书 / 订阅管理脚本
#
# 当前设计：
# - 只使用 Xray-core，不使用 Docker / sing-box / 独立 hysteria 服务端
# - 每台机器最多 3 个域名：BASE_DOMAIN、v4.BASE_DOMAIN、v6.BASE_DOMAIN
# - BASE_DOMAIN = CDN / 伪装站 / 订阅域名
# - v4.BASE_DOMAIN = IPv4 灰云直连
# - v6.BASE_DOMAIN = IPv6 灰云直连
# - CDN 协议端口只能选择 Cloudflare HTTPS 可代理端口
# - 非 CDN 协议端口只是默认推荐，允许自定义
# - BestCF 默认关闭；启用后只使用优选域名，不使用优选 IP
# - 订阅对外只输出 base64；本地额外生成 raw 和 mihomo 参考片段
#
# 重要：R3 仍是 Alpha。建议先在全新测试 VPS 上跑，不要直接上生产机。

set -uo pipefail

APP_DIR="/root/.xray-anti-block"
STATE_FILE="$APP_DIR/state.env"
CF_ENV="$APP_DIR/cloudflare.env"
CF_CRED="$APP_DIR/cloudflare.ini"
SUB_DIR="$APP_DIR/subscription"
BESTCF_DIR="$APP_DIR/bestcf"
BACKUP_DIR="$APP_DIR/backups"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
NGINX_SITE="/etc/nginx/conf.d/xray-anti-block.conf"
WEB_ROOT="/var/www/xray-anti-block"
SYSCTL_FILE="/etc/sysctl.d/99-xray-anti-block.conf"

CF_HTTPS_PORTS="443 2053 2083 2087 2096 8443"
BESTCF_DOMAIN_URL="https://raw.githubusercontent.com/DustinWin/BestCF/main/bestcf-domain.txt"
DEFAULT_HY2_HOP_RANGE="20000:20100"
CURL_CONNECT_TIMEOUT=5
CURL_MAX_TIME=20

mkdir -p "$APP_DIR" "$SUB_DIR" "$BESTCF_DIR" "$BACKUP_DIR"

log()  { echo -e "\033[32m[OK]\033[0m $*"; }
info() { echo -e "\033[36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR]\033[0m $*"; }
die()  { err "$*"; exit 1; }
pause(){ read -r -p "按回车继续..." _ || true; }

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 运行。"; }

load_state() {
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
  [[ -f "$CF_ENV" ]] && source "$CF_ENV"
}

save_kv() {
  local file="$1" key="$2" value="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file" 2>/dev/null || true
  if grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=\"${value//"/\\"}\"|" "$file"
  else
    echo "${key}=\"${value//"/\\"}\"" >> "$file"
  fi
}

ask() {
  local prompt="$1" default="${2:-}" ans
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " ans || true
    echo "${ans:-$default}"
  else
    read -r -p "$prompt: " ans || true
    echo "$ans"
  fi
}

confirm() {
  local prompt="$1" default="${2:-N}" ans
  read -r -p "$prompt [$default]: " ans || true
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

rand_hex() { openssl rand -hex "${1:-8}"; }
rand_path() { echo "/$(openssl rand -hex 6)/xhttp"; }
rand_token() { openssl rand -hex 16; }

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]]
}

validate_base_domain() {
  local d="$1"
  [[ "$d" == *.*.* ]] || return 1
  [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.){2,}[A-Za-z]{2,}$ ]] || return 1
}

is_cf_https_port() {
  local p="$1" x
  for x in $CF_HTTPS_PORTS; do [[ "$p" == "$x" ]] && return 0; done
  return 1
}

public_ipv4() {
  curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || \
  curl -4 -fsS --max-time 8 https://ifconfig.co/ip 2>/dev/null || true
}

public_ipv6() {
  curl -6 -fsS --max-time 8 https://api64.ipify.org 2>/dev/null || \
  curl -6 -fsS --max-time 8 https://ifconfig.co/ip 2>/dev/null || true
}

get_proc_by_port() {
  local proto="$1" port="$2"
  ss -H -lpn "$proto" "sport = :$port" 2>/dev/null | awk '{print $NF}' | head -n1
}

install_deps() {
  need_root
  info "安装基础依赖..."
  if ! command -v apt-get >/dev/null 2>&1; then
    die "Alpha R2 暂只自动支持 Debian/Ubuntu apt 系。"
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    curl wget jq openssl ca-certificates gnupg lsb-release \
    nginx certbot python3-certbot-dns-cloudflare \
    whois iproute2 iputils-ping unzip tar sed grep coreutils \
    cron socat
  log "依赖安装完成。"
}

install_or_upgrade_xray() {
  need_root
  info "安装/升级 Xray-core..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
  systemctl enable xray >/dev/null 2>&1 || true
  log "Xray 安装/升级完成。"
  /usr/local/bin/xray version || true
}

update_geodata() {
  need_root
  info "更新 geoip.dat / geosite.dat..."
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata
  log "geodata 更新完成。"
}

enable_geodata_timer() {
  cat >/etc/systemd/system/xray-geodata-update.service <<EOF
[Unit]
Description=Update Xray geodata
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'bash -c "\$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata && systemctl restart xray'
EOF

  cat >/etc/systemd/system/xray-geodata-update.timer <<EOF
[Unit]
Description=Run Xray geodata update every 3 days

[Timer]
OnBootSec=10min
OnUnitActiveSec=3d
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now xray-geodata-update.timer
  log "已启用 geodata 每 3 天自动更新。"
}

network_status() {
  echo "===== Kernel ====="
  uname -a
  echo
  echo "===== TCP congestion ====="
  sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || true
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
  sysctl net.core.default_qdisc 2>/dev/null || true
  echo
  echo "===== bbr modules ====="
  lsmod | grep -i bbr || true
}

apply_stable_network_tuning() {
  need_root
  cp -a "$SYSCTL_FILE" "$BACKUP_DIR/sysctl.$(date +%F-%H%M%S).bak" 2>/dev/null || true
  cat >"$SYSCTL_FILE" <<'EOF'
# Generated by xray-anti-block-manager
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
EOF
  sysctl --system >/dev/null || true
  log "已应用稳定型网络优化：BBR + fq + 保守 sysctl。"
}

configure_base_domain() {
  load_state
  local d
  while true; do
    d=$(ask "请输入母域名，必须三段式或以上，例如 jp1.0x0000.top" "${BASE_DOMAIN:-}")
    if validate_base_domain "$d"; then
      save_kv "$STATE_FILE" BASE_DOMAIN "$d"
      log "母域名已设置：$d"
      break
    else
      warn "域名不合格。必须类似 jp1.0x0000.top，不能是 0x0000.top 这种二段根域。"
    fi
  done
}

cf_api() {
  local method="$1" endpoint="$2" data="${3:-}" resp ok
  load_state
  [[ -n "${CF_API_TOKEN:-}" ]] || die "未配置 CF_API_TOKEN。"

  if [[ -n "$data" ]]; then
    resp=$(curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
      -X "$method" "https://api.cloudflare.com/client/v4$endpoint" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$data") || return 1
  else
    resp=$(curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
      -X "$method" "https://api.cloudflare.com/client/v4$endpoint" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json") || return 1
  fi

  ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null || true)
  if [[ "$ok" != "true" ]]; then
    err "Cloudflare API 调用失败：$method $endpoint"
    echo "$resp" >&2
    return 1
  fi
  echo "$resp"
}

cloudflare_token_risk_check() {
  local token="$1" ack
  if [[ "$token" =~ ^[a-f0-9]{37}$ ]]; then
    warn "这个 Token 看起来像 Cloudflare Global API Key。强烈不建议使用。"
    warn "推荐使用 Restricted API Token，仅授予目标 Zone 的 Zone:Read + DNS:Edit。"
    read -r -p "如坚持继续，请输入 YES_I_KNOW_THE_RISK: " ack || true
    [[ "$ack" == "YES_I_KNOW_THE_RISK" ]] || die "已中止。请重新创建 Restricted API Token。"
  fi
}

setup_cloudflare() {
  load_state
  configure_base_domain
  local token zone_name zone_id ok
  token=$(ask "请输入 Cloudflare Restricted API Token，需 Zone:Read + DNS:Edit" "${CF_API_TOKEN:-}")
  [[ -n "$token" ]] || die "API Token 不能为空。"
  cloudflare_token_risk_check "$token"
  save_kv "$CF_ENV" CF_API_TOKEN "$token"
  source "$CF_ENV"

  zone_name=$(ask "请输入 Cloudflare Zone Name，例如 0x0000.top" "${CF_ZONE_NAME:-}")
  [[ -n "$zone_name" ]] || die "Zone Name 不能为空。"
  save_kv "$CF_ENV" CF_ZONE_NAME "$zone_name"

  info "查询 Zone ID，并验证 Token 权限..."
  local resp
  resp=$(curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -G "https://api.cloudflare.com/client/v4/zones" \
    -H "Authorization: Bearer $token" \
    --data-urlencode "name=$zone_name") || die "Cloudflare API 查询失败或超时。"
  ok=$(echo "$resp" | jq -r '.success')
  [[ "$ok" == "true" ]] || die "Cloudflare API 返回失败：$resp"
  zone_id=$(echo "$resp" | jq -r '.result[0].id // empty')
  [[ -n "$zone_id" ]] || die "未查到 Zone ID，请确认 token 权限和 zone name。"
  save_kv "$CF_ENV" CF_ZONE_ID "$zone_id"

  # DNS record list API probe: verifies DNS read permission.
  cf_api GET "/zones/$zone_id/dns_records?per_page=1" >/dev/null || die "Token 无法读取 DNS 记录。请确认 DNS:Read/Edit 权限。"
  log "Cloudflare 已配置并通过权限测试：zone=$zone_name id=$zone_id"
}

cf_upsert_record() {
  local name="$1" type="$2" content="$3" proxied="$4"
  load_state
  [[ -n "${CF_ZONE_ID:-}" ]] || die "未配置 CF_ZONE_ID。"
  [[ -n "$content" ]] || { warn "$name $type 内容为空，跳过。"; return 0; }

  info "Upsert DNS: $type $name -> $content proxied=$proxied"
  local rec_id payload list
  list=$(curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -G "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    --data-urlencode "type=$type" \
    --data-urlencode "name=$name") || return 1
  rec_id=$(echo "$list" | jq -r '.result[0].id // empty')
  payload=$(jq -nc --arg type "$type" --arg name "$name" --arg content "$content" --argjson proxied "$proxied" '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied}')

  if [[ -n "$rec_id" ]]; then
    cf_api PATCH "/zones/$CF_ZONE_ID/dns_records/$rec_id" "$payload" >/dev/null
  else
    cf_api POST "/zones/$CF_ZONE_ID/dns_records" "$payload" >/dev/null
  fi
}

create_dns_records() {
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || configure_base_domain
  [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE_ID:-}" ]] || setup_cloudflare

  local ip4 ip6 enable_cdn proxied_base
  ip4="${PUBLIC_IPV4:-$(public_ipv4)}"
  ip6="${PUBLIC_IPV6:-$(public_ipv6)}"
  [[ -n "$ip4" ]] && save_kv "$STATE_FILE" PUBLIC_IPV4 "$ip4"
  [[ -n "$ip6" ]] && save_kv "$STATE_FILE" PUBLIC_IPV6 "$ip6"

  enable_cdn="${ENABLE_CDN:-}"
  if [[ -z "$enable_cdn" ]]; then
    if confirm "是否启用 CDN 模式？启用则母域名 $BASE_DOMAIN 设为橙云" "Y"; then
      enable_cdn="1"
    else
      enable_cdn="0"
    fi
    save_kv "$STATE_FILE" ENABLE_CDN "$enable_cdn"
  fi
  [[ "$enable_cdn" == "1" ]] && proxied_base=true || proxied_base=false

  if [[ -n "$ip4" ]]; then
    cf_upsert_record "$BASE_DOMAIN" A "$ip4" "$proxied_base"
    cf_upsert_record "v4.$BASE_DOMAIN" A "$ip4" false
  fi
  if [[ -n "$ip6" ]]; then
    cf_upsert_record "$BASE_DOMAIN" AAAA "$ip6" "$proxied_base"
    cf_upsert_record "v6.$BASE_DOMAIN" AAAA "$ip6" false
  fi
  log "DNS 记录处理完成。最多 3 个域名：BASE、v4.BASE、v6.BASE。"
}

issue_certificate() {
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || configure_base_domain
  [[ -n "${CF_API_TOKEN:-}" ]] || setup_cloudflare

  mkdir -p "$APP_DIR"
  cat >"$CF_CRED" <<EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
  chmod 600 "$CF_CRED"

  local email
  email=$(ask "请输入证书邮箱，留空则不绑定邮箱" "${CERT_EMAIL:-}")
  [[ -n "$email" ]] && save_kv "$STATE_FILE" CERT_EMAIL "$email"

  if [[ -n "$email" ]]; then
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CRED" \
      --dns-cloudflare-propagation-seconds 60 \
      -d "$BASE_DOMAIN" -d "*.$BASE_DOMAIN" \
      --agree-tos --non-interactive --email "$email" || die "证书申请失败。"
  else
    certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CRED" \
      --dns-cloudflare-propagation-seconds 60 \
      -d "$BASE_DOMAIN" -d "*.$BASE_DOMAIN" \
      --agree-tos --non-interactive --register-unsafely-without-email || die "证书申请失败。"
  fi
  log "证书申请完成：/etc/letsencrypt/live/$BASE_DOMAIN/"
}

choose_reality_target() {
  load_state
  local target c
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
  save_kv "$STATE_FILE" REALITY_TARGET "$target"
  log "REALITY target: $target"
}

generate_keys_if_needed() {
  load_state
  command -v xray >/dev/null 2>&1 || die "请先安装 Xray。"
  [[ -n "${UUID:-}" ]] || save_kv "$STATE_FILE" UUID "$(xray uuid)"
  if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
    local k priv pub
    k=$(xray x25519)
    priv=$(echo "$k" | awk -F': ' '/Private key/ {print $2}')
    pub=$(echo "$k" | awk -F': ' '/Public key/ {print $2}')
    [[ -n "$priv" && -n "$pub" ]] || die "xray x25519 生成失败。"
    save_kv "$STATE_FILE" REALITY_PRIVATE_KEY "$priv"
    save_kv "$STATE_FILE" REALITY_PUBLIC_KEY "$pub"
  fi
  [[ -n "${SHORT_ID:-}" ]] || save_kv "$STATE_FILE" SHORT_ID "$(rand_hex 8)"
  [[ -n "${XHTTP_REALITY_PATH:-}" ]] || save_kv "$STATE_FILE" XHTTP_REALITY_PATH "$(rand_path)"
  [[ -n "${XHTTP_CDN_PATH:-}" ]] || save_kv "$STATE_FILE" XHTTP_CDN_PATH "$(rand_path)"
  [[ -n "${HY2_AUTH:-}" ]] || save_kv "$STATE_FILE" HY2_AUTH "$(rand_hex 16)"
  [[ -n "${SUB_TOKEN:-}" ]] || save_kv "$STATE_FILE" SUB_TOKEN "$(rand_token)"
  [[ -n "${XHTTP_CDN_LOCAL_PORT:-}" ]] || save_kv "$STATE_FILE" XHTTP_CDN_LOCAL_PORT "31301"
  load_state
}

select_protocols() {
  echo "请选择要安装的协议组合，可输入多个数字，例如 123、1234、12345："
  echo "1. [默认直连] VLESS + XHTTP + REALITY        CDN: no，端口默认 2443，可自定义"
  echo "2. [最高隐藏] VLESS + XHTTP + TLS + CDN     CDN: yes，端口只能 CF HTTPS 白名单"
  echo "3. [UDP 高速] Xray Hysteria2                CDN: no，UDP 默认 443，可自定义"
  echo "4. [可选备用] VLESS + REALITY + Vision      CDN: no，端口默认 3443，可自定义"
  echo "5. [高级实验] XHTTP CDN + REALITY 分离      Alpha 暂只占位"
  local p
  p=$(ask "默认安装" "${PROTOCOLS:-123}")
  [[ "$p" =~ ^[1-5]+$ ]] || die "协议组合只能由 1-5 数字组成。"
  save_kv "$STATE_FILE" PROTOCOLS "$p"

  if [[ "$p" == *2* ]]; then
    save_kv "$STATE_FILE" ENABLE_CDN "1"
    local port
    port=$(ask "CDN 公网端口，只能是 443/2053/2083/2087/2096/8443" "${CDN_PORT:-443}")
    valid_port "$port" || die "端口无效。"
    is_cf_https_port "$port" || die "CDN 模式端口必须是 Cloudflare HTTPS 可代理端口：$CF_HTTPS_PORTS"
    save_kv "$STATE_FILE" CDN_PORT "$port"
  fi

  if [[ "$p" == *1* ]]; then
    local port
    port=$(ask "XHTTP + REALITY 直连端口，默认推荐 2443，可自定义" "${XHTTP_REALITY_PORT:-2443}")
    valid_port "$port" || die "端口无效。"
    save_kv "$STATE_FILE" XHTTP_REALITY_PORT "$port"
  fi

  if [[ "$p" == *3* ]]; then
    local port
    port=$(ask "Hysteria2 UDP 监听端口，默认推荐 443，可自定义" "${HY2_PORT:-443}")
    valid_port "$port" || die "端口无效。"
    save_kv "$STATE_FILE" HY2_PORT "$port"
    warn "Xray Hysteria2 是较新功能。如连接失败，优先检查客户端内核、UDP 放行和 Xray 版本。"
  fi

  if [[ "$p" == *4* ]]; then
    local port
    port=$(ask "REALITY + Vision 端口，默认推荐 3443，可自定义" "${REALITY_VISION_PORT:-3443}")
    valid_port "$port" || die "端口无效。"
    save_kv "$STATE_FILE" REALITY_VISION_PORT "$port"
  fi

  if confirm "是否启用 v4/v6 出口绑定？v4 入站走 IPv4 出口，v6 入站走 IPv6 出口" "Y"; then
    save_kv "$STATE_FILE" ENABLE_IP_STACK_BINDING "1"
  else
    save_kv "$STATE_FILE" ENABLE_IP_STACK_BINDING "0"
  fi

  log "协议组合：$p"
}

protocol_enabled() { [[ "${PROTOCOLS:-123}" == *"$1"* ]]; }

backup_configs() {
  local ts="$(date +%F-%H%M%S)"
  [[ -f "$XRAY_CONFIG" ]] && cp -a "$XRAY_CONFIG" "$BACKUP_DIR/config.json.$ts.bak"
  [[ -f "$NGINX_SITE" ]] && cp -a "$NGINX_SITE" "$BACKUP_DIR/nginx.$ts.bak"
  [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$BACKUP_DIR/state.env.$ts.bak"
}

preflight_ports() {
  load_state
  info "端口预检..."
  local p proc

  if protocol_enabled 2; then
    p="${CDN_PORT:-443}"
    proc=$(get_proc_by_port -t "$p" || true)
    if [[ -n "$proc" && "$proc" != *nginx* ]]; then
      die "TCP $p 被非 Nginx 进程占用：$proc。CDN/Nginx 模式不能继续。"
    fi
  fi

  if protocol_enabled 1; then
    p="${XHTTP_REALITY_PORT:-2443}"
    proc=$(get_proc_by_port -t "$p" || true)
    if [[ -n "$proc" && "$proc" != *xray* ]]; then
      die "TCP $p 被非 Xray 进程占用：$proc。XHTTP+REALITY 不能继续。"
    fi
  fi

  if protocol_enabled 4; then
    p="${REALITY_VISION_PORT:-3443}"
    proc=$(get_proc_by_port -t "$p" || true)
    if [[ -n "$proc" && "$proc" != *xray* ]]; then
      die "TCP $p 被非 Xray 进程占用：$proc。REALITY+Vision 不能继续。"
    fi
  fi

  if protocol_enabled 3; then
    p="${HY2_PORT:-443}"
    proc=$(get_proc_by_port -u "$p" || true)
    if [[ -n "$proc" && "$proc" != *xray* ]]; then
      die "UDP $p 被非 Xray 进程占用：$proc。Hysteria2 不能继续。"
    fi
  fi
  log "端口预检通过。"
}

append_json_obj() {
  local file="$1" first_ref="$2"
  if [[ "${!first_ref}" -eq 0 ]]; then echo "," >>"$file"; fi
  cat >>"$file"
  printf -v "$first_ref" 0
}

generate_xray_config() {
  need_root
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || configure_base_domain
  [[ -n "${REALITY_TARGET:-}" ]] || choose_reality_target
  generate_keys_if_needed
  load_state
  preflight_ports
  backup_configs
  mkdir -p /usr/local/etc/xray

  local in_tmp out_tmp route_tmp first_in=1 first_out=1 first_route=1 ip4 ip6 bind
  in_tmp=$(mktemp); out_tmp=$(mktemp); route_tmp=$(mktemp)
  ip4="${PUBLIC_IPV4:-$(public_ipv4)}"; ip6="${PUBLIC_IPV6:-$(public_ipv6)}"
  [[ -n "$ip4" ]] && save_kv "$STATE_FILE" PUBLIC_IPV4 "$ip4"
  [[ -n "$ip6" ]] && save_kv "$STATE_FILE" PUBLIC_IPV6 "$ip6"
  bind="${ENABLE_IP_STACK_BINDING:-1}"

  # Outbounds
  append_json_obj "$out_tmp" first_out <<'EOF'
    {"tag": "direct", "protocol": "freedom"}
EOF
  append_json_obj "$out_tmp" first_out <<'EOF'
    {"tag": "block", "protocol": "blackhole"}
EOF
  append_json_obj "$out_tmp" first_out <<'EOF'
    {"tag": "out-v4", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}}
EOF
  append_json_obj "$out_tmp" first_out <<'EOF'
    {"tag": "out-v6", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv6"}}
EOF

  if protocol_enabled 1; then
    if [[ "$bind" == "1" && -n "$ip4" ]]; then
      append_json_obj "$in_tmp" first_in <<EOF
    {
      "tag": "in-v4-xhttp-reality",
      "listen": "${ip4}",
      "port": ${XHTTP_REALITY_PORT},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID}", "email": "v4-xhttp-reality"}], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {"path": "${XHTTP_REALITY_PATH}", "mode": "auto"},
        "realitySettings": {"show": false, "dest": "${REALITY_TARGET}:443", "serverNames": ["${REALITY_TARGET}"], "privateKey": "${REALITY_PRIVATE_KEY}", "shortIds": ["${SHORT_ID}"]}
      }
    }
EOF
      append_json_obj "$route_tmp" first_route <<'EOF'
    {"type": "field", "inboundTag": ["in-v4-xhttp-reality"], "outboundTag": "out-v4"}
EOF
    fi

    if [[ "$bind" == "1" && -n "$ip6" ]]; then
      append_json_obj "$in_tmp" first_in <<EOF
    {
      "tag": "in-v6-xhttp-reality",
      "listen": "${ip6}",
      "port": ${XHTTP_REALITY_PORT},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID}", "email": "v6-xhttp-reality"}], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {"path": "${XHTTP_REALITY_PATH}", "mode": "auto"},
        "realitySettings": {"show": false, "dest": "${REALITY_TARGET}:443", "serverNames": ["${REALITY_TARGET}"], "privateKey": "${REALITY_PRIVATE_KEY}", "shortIds": ["${SHORT_ID}"]}
      }
    }
EOF
      append_json_obj "$route_tmp" first_route <<'EOF'
    {"type": "field", "inboundTag": ["in-v6-xhttp-reality"], "outboundTag": "out-v6"}
EOF
    fi

    if [[ "$bind" != "1" || ( -z "$ip4" && -z "$ip6" ) ]]; then
      append_json_obj "$in_tmp" first_in <<EOF
    {
      "tag": "in-xhttp-reality",
      "listen": "0.0.0.0",
      "port": ${XHTTP_REALITY_PORT},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID}", "email": "xhttp-reality"}], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {"path": "${XHTTP_REALITY_PATH}", "mode": "auto"},
        "realitySettings": {"show": false, "dest": "${REALITY_TARGET}:443", "serverNames": ["${REALITY_TARGET}"], "privateKey": "${REALITY_PRIVATE_KEY}", "shortIds": ["${SHORT_ID}"]}
      }
    }
EOF
    fi
  fi

  if protocol_enabled 2; then
    append_json_obj "$in_tmp" first_in <<EOF
    {
      "tag": "in-xhttp-cdn-local",
      "listen": "127.0.0.1",
      "port": ${XHTTP_CDN_LOCAL_PORT},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID}", "email": "xhttp-cdn"}], "decryption": "none"},
      "streamSettings": {"network": "xhttp", "security": "none", "xhttpSettings": {"path": "${XHTTP_CDN_PATH}", "mode": "auto"}}
    }
EOF
  fi

  if protocol_enabled 3; then
    append_json_obj "$in_tmp" first_in <<EOF
    {
      "tag": "in-hysteria2-udp",
      "listen": "0.0.0.0",
      "port": ${HY2_PORT},
      "protocol": "hysteria",
      "settings": {"version": 2, "clients": [{"auth": "${HY2_AUTH}", "email": "hy2"}]},
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {"certificates": [{"certificateFile": "/etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem", "keyFile": "/etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem"}]},
        "hysteriaSettings": {"version": 2, "auth": "${HY2_AUTH}", "udpIdleTimeout": 60}
      }
    }
EOF
  fi

  if protocol_enabled 4; then
    append_json_obj "$in_tmp" first_in <<EOF
    {
      "tag": "in-reality-vision",
      "listen": "0.0.0.0",
      "port": ${REALITY_VISION_PORT},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision", "email": "reality-vision"}], "decryption": "none"},
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {"show": false, "dest": "${REALITY_TARGET}:443", "serverNames": ["${REALITY_TARGET}"], "privateKey": "${REALITY_PRIVATE_KEY}", "shortIds": ["${SHORT_ID}"]}
      }
    }
EOF
  fi

  cat >"$XRAY_CONFIG" <<EOF
{
  "log": {"loglevel": "warning", "access": "none", "error": "/var/log/xray/error.log"},
  "inbounds": [
$(cat "$in_tmp")
  ],
  "outbounds": [
$(cat "$out_tmp")
  ],
  "routing": {"domainStrategy": "AsIs", "rules": [
$(cat "$route_tmp")
  ]}
}
EOF
  rm -f "$in_tmp" "$out_tmp" "$route_tmp"
  jq empty "$XRAY_CONFIG" || die "生成的 Xray JSON 不是合法 JSON，已保留备份。"
  xray run -test -config "$XRAY_CONFIG" || die "Xray 配置测试失败，已保留备份。"
  log "Xray 配置生成并测试通过。"
}

configure_nginx() {
  need_root
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || configure_base_domain
  [[ -f "/etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem" ]] || issue_certificate
  generate_keys_if_needed
  load_state
  mkdir -p "$WEB_ROOT" "$SUB_DIR"
  cat >"$WEB_ROOT/index.html" <<EOF
<!doctype html><html><head><meta charset="utf-8"><title>Welcome</title></head><body><h1>Welcome</h1><p>It works.</p></body></html>
EOF
  touch "$SUB_DIR/local.b64"
  cat >"$NGINX_SITE" <<EOF
server {
    listen 80;
    server_name ${BASE_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${CDN_PORT:-443} ssl http2;
    server_name ${BASE_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root ${WEB_ROOT};
    index index.html;

    location = ${XHTTP_CDN_PATH} {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:${XHTTP_CDN_LOCAL_PORT};
    }

    location = /sub/${SUB_TOKEN} {
        default_type text/plain;
        alias ${SUB_DIR}/local.b64;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
  nginx -t || die "Nginx 配置测试失败。"
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx || systemctl restart nginx
  log "Nginx / 伪装站 / 订阅路径配置完成。"
}

asn_query_one() {
  local ip="$1"
  [[ -z "$ip" ]] && return 0
  echo "==== $ip ===="
  timeout 15 whois -h bgp.tools " -v $ip" 2>/dev/null | awk '
    /^[0-9]/ {asn=$1; prefix=$2; registry=$3; cc=$4; $1=$2=$3=$4=""; sub(/^[ \t]+/, "", $0); print "ASN="asn"\nPREFIX="prefix"\nREGISTRY="registry"\nCC="cc"\nORG="$0; exit}' || true
}

asn_report() {
  load_state
  local ip4 ip6
  ip4="${PUBLIC_IPV4:-$(public_ipv4)}"
  ip6="${PUBLIC_IPV6:-$(public_ipv6)}"
  [[ -n "$ip4" ]] && save_kv "$STATE_FILE" PUBLIC_IPV4 "$ip4"
  [[ -n "$ip6" ]] && save_kv "$STATE_FILE" PUBLIC_IPV6 "$ip6"
  echo "===== IPv4 / IPv6 / ASN 辅助报告 ====="
  [[ -n "$ip4" ]] && asn_query_one "$ip4" || warn "未检测到公网 IPv4。"
  echo
  [[ -n "$ip6" ]] && asn_query_one "$ip6" || warn "未检测到公网 IPv6。"
  echo
  info "建议：优质 v4/v6 可选 XHTTP+REALITY；普通/绕路线路可选 XHTTP+TLS+CDN。"
}

uri_encode() {
  local s="$1" out="" i c
  for ((i=0; i<${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v out '%s%%%02X' "$out" "'${c}" ;;
    esac
  done
  echo "$out"
}

add_vless_xhttp_reality_link() {
  local server="$1" name="$2" raw="$3" path_enc
  path_enc=$(uri_encode "$XHTTP_REALITY_PATH")
  echo "vless://${UUID}@${server}:${XHTTP_REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_TARGET}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${path_enc}&mode=auto#$(uri_encode "$name")" >>"$raw"
}

add_vless_xhttp_cdn_link() {
  local server="$1" name="$2" raw="$3" port="${4:-443}" path_enc
  path_enc=$(uri_encode "$XHTTP_CDN_PATH")
  echo "vless://${UUID}@${server}:${port}?encryption=none&security=tls&sni=${BASE_DOMAIN}&fp=chrome&type=xhttp&host=${BASE_DOMAIN}&path=${path_enc}&mode=auto#$(uri_encode "$name")" >>"$raw"
}

add_reality_vision_link() {
  local server="$1" name="$2" raw="$3"
  echo "vless://${UUID}@${server}:${REALITY_VISION_PORT}?encryption=none&security=reality&sni=${REALITY_TARGET}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#$(uri_encode "$name")" >>"$raw"
}

add_hy2_link() {
  local server="$1" name="$2" raw="$3"
  echo "hysteria2://${HY2_AUTH}@${server}:${HY2_PORT:-443}?sni=${BASE_DOMAIN}&insecure=0#$(uri_encode "$name")" >>"$raw"
}

generate_mihomo_reference() {
  load_state
  local f="$SUB_DIR/mihomo-reference.yaml"
  cat >"$f" <<EOF
# 仅供参考：对外订阅仍只发布 base64。
# XHTTP / Xray Hysteria2 属于较新能力，不同客户端字段兼容性可能不同。
# 请按你的 Mihomo 版本实际调整。
proxies:
EOF
  if protocol_enabled 1; then
    [[ -n "${PUBLIC_IPV4:-}" ]] && cat >>"$f" <<EOF
  - name: ${NODE_NAME:-node}-v4-XHTTP-REALITY
    type: vless
    server: v4.${BASE_DOMAIN}
    port: ${XHTTP_REALITY_PORT}
    uuid: ${UUID}
    tls: true
    servername: ${REALITY_TARGET}
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}
    network: xhttp
    xhttp-opts:
      path: ${XHTTP_REALITY_PATH}
EOF
    [[ -n "${PUBLIC_IPV6:-}" ]] && cat >>"$f" <<EOF
  - name: ${NODE_NAME:-node}-v6-XHTTP-REALITY
    type: vless
    server: v6.${BASE_DOMAIN}
    port: ${XHTTP_REALITY_PORT}
    uuid: ${UUID}
    tls: true
    servername: ${REALITY_TARGET}
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}
    network: xhttp
    xhttp-opts:
      path: ${XHTTP_REALITY_PATH}
EOF
  fi
  if protocol_enabled 2; then
    cat >>"$f" <<EOF
  - name: ${NODE_NAME:-node}-CDN-XHTTP-Origin
    type: vless
    server: ${BASE_DOMAIN}
    port: ${CDN_PORT:-443}
    uuid: ${UUID}
    tls: true
    servername: ${BASE_DOMAIN}
    network: xhttp
    xhttp-opts:
      path: ${XHTTP_CDN_PATH}
    headers:
      Host: ${BASE_DOMAIN}
EOF
  fi
  if protocol_enabled 3; then
    cat >>"$f" <<EOF
  - name: ${NODE_NAME:-node}-HY2-UDP
    type: hysteria2
    server: ${BASE_DOMAIN}
    port: ${HY2_PORT:-443}
    password: ${HY2_AUTH}
    sni: ${BASE_DOMAIN}
    # 如果启用了端口跳跃，可尝试把 port 改为跳跃范围内端口，例如 20000-20100。
EOF
  fi
  log "Mihomo 参考片段已生成：$f"
}

generate_subscription() {
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || die "请先设置母域名。"
  generate_keys_if_needed
  load_state
  mkdir -p "$SUB_DIR"
  local raw="$SUB_DIR/local.raw" b64="$SUB_DIR/local.b64" d n
  : >"$raw"

  if protocol_enabled 1; then
    [[ -n "${PUBLIC_IPV4:-}" ]] && add_vless_xhttp_reality_link "v4.${BASE_DOMAIN}" "${NODE_NAME:-node}-v4-XHTTP-REALITY" "$raw"
    [[ -n "${PUBLIC_IPV6:-}" ]] && add_vless_xhttp_reality_link "v6.${BASE_DOMAIN}" "${NODE_NAME:-node}-v6-XHTTP-REALITY" "$raw"
  fi

  if protocol_enabled 2; then
    add_vless_xhttp_cdn_link "$BASE_DOMAIN" "${NODE_NAME:-node}-CDN-XHTTP-Origin" "$raw" "${CDN_PORT:-443}"
    if [[ "${BESTCF_ENABLED:-0}" == "1" && -s "$BESTCF_DIR/bestcf-domain.txt" ]]; then
      n=1
      while read -r d; do
        [[ -z "$d" || "$d" =~ ^# ]] && continue
        add_vless_xhttp_cdn_link "$d" "${NODE_NAME:-node}-CDN-BestCF-${n}" "$raw" "${CDN_PORT:-443}"
        n=$((n+1))
        [[ "$n" -gt "${BESTCF_NODE_LIMIT:-10}" ]] && break
      done <"$BESTCF_DIR/bestcf-domain.txt"
    fi
  fi

  protocol_enabled 3 && add_hy2_link "$BASE_DOMAIN" "${NODE_NAME:-node}-HY2-UDP${HY2_PORT:-443}" "$raw"

  if protocol_enabled 4; then
    [[ -n "${PUBLIC_IPV4:-}" ]] && add_reality_vision_link "v4.${BASE_DOMAIN}" "${NODE_NAME:-node}-v4-REALITY-Vision" "$raw"
    [[ -n "${PUBLIC_IPV6:-}" ]] && add_reality_vision_link "v6.${BASE_DOMAIN}" "${NODE_NAME:-node}-v6-REALITY-Vision" "$raw"
  fi

  sed -i '/^$/d' "$raw"
  base64 -w0 "$raw" >"$b64"
  generate_mihomo_reference
  log "本机 b64 订阅已生成：$b64"
  echo "订阅链接： https://${BASE_DOMAIN}/sub/${SUB_TOKEN}"
}

fetch_bestcf_domains() {
  mkdir -p "$BESTCF_DIR"
  info "拉取 BestCF 优选域名，仅使用域名，不使用 IP..."
  curl -fsSL "$BESTCF_DOMAIN_URL" \
    | sed 's/\r$//' \
    | grep -E '^[A-Za-z0-9*_.-]+\.[A-Za-z0-9_.-]+$' \
    | sed 's/^\*\.//g' \
    | awk '!seen[$0]++' \
    >"$BESTCF_DIR/bestcf-domain.txt.tmp" || die "BestCF 拉取失败。"
  mv "$BESTCF_DIR/bestcf-domain.txt.tmp" "$BESTCF_DIR/bestcf-domain.txt"
  log "BestCF 域名数量：$(wc -l <"$BESTCF_DIR/bestcf-domain.txt")"
}

enable_bestcf() {
  fetch_bestcf_domains
  save_kv "$STATE_FILE" BESTCF_ENABLED "1"
  local limit
  limit=$(ask "每个节点最多生成多少个 BestCF 域名入口" "${BESTCF_NODE_LIMIT:-10}")
  save_kv "$STATE_FILE" BESTCF_NODE_LIMIT "$limit"
  log "BestCF 已启用。重新生成订阅后生效。"
}

disable_bestcf() {
  save_kv "$STATE_FILE" BESTCF_ENABLED "0"
  log "BestCF 已关闭。重新生成订阅后生效。"
}

enable_hy2_hopping() {
  load_state
  local range="$1" start end to_port
  to_port="${HY2_PORT:-443}"
  start="${range%%:*}"; end="${range##*:}"
  [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" -le "$end" ]] || die "端口范围格式错误。"
  info "设置 Hysteria2 UDP 端口跳跃：$start-$end -> $to_port"

  # 幂等：先删旧规则，再添加，避免重复运行导致规则堆叠。
  while iptables -t nat -D PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null; do :; done
  iptables -t nat -A PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" || die "iptables 端口跳跃规则添加失败。"
  iptables -t nat -C PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null || die "iptables 端口跳跃规则验证失败。"

  if command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -t nat -D PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null; do :; done
    if ip6tables -t nat -A PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null; then
      ip6tables -t nat -C PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null || warn "ip6tables 端口跳跃规则验证失败，IPv6 跳跃可能不可用。"
    else
      warn "ip6tables 规则添加失败，IPv6 跳跃可能不可用。"
    fi
  fi

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save || warn "netfilter-persistent save 失败，重启后端口跳跃可能失效。"
  elif confirm "未检测到 netfilter-persistent。是否安装以持久化端口跳跃规则？" "Y"; then
    apt-get install -y iptables-persistent netfilter-persistent || true
    netfilter-persistent save || warn "持久化失败，重启后端口跳跃可能失效。"
  else
    warn "你选择不持久化。服务器重启后端口跳跃规则会失效。"
  fi
  save_kv "$STATE_FILE" HY2_HOP_RANGE "$range"
  log "端口跳跃规则已设置。请确认云安全组放行 UDP $start-$end。"
}

configure_hy2_hopping_prompt() {
  load_state
  [[ "${PROTOCOLS:-123}" == *3* ]] || return 0
  if confirm "是否开启 Hysteria2 UDP 端口跳跃？推荐小范围 ${DEFAULT_HY2_HOP_RANGE}" "Y"; then
    local range
    range=$(ask "请输入跳跃端口范围，格式 start:end" "${HY2_HOP_RANGE:-$DEFAULT_HY2_HOP_RANGE}")
    enable_hy2_hopping "$range"
  fi
}

handle_firewall_ports() {
  load_state
  local tcp_ports=() udp_ports=()
  [[ "${PROTOCOLS:-123}" == *2* ]] && tcp_ports+=("${CDN_PORT:-443}")
  [[ "${PROTOCOLS:-123}" == *1* ]] && tcp_ports+=("${XHTTP_REALITY_PORT:-2443}")
  [[ "${PROTOCOLS:-123}" == *4* ]] && tcp_ports+=("${REALITY_VISION_PORT:-3443}")
  [[ "${PROTOCOLS:-123}" == *3* ]] && udp_ports+=("${HY2_PORT:-443}")
  [[ -n "${HY2_HOP_RANGE:-}" ]] && udp_ports+=("${HY2_HOP_RANGE/:/-}")

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    info "检测到 ufw active，自动放行端口。"
    for p in "${tcp_ports[@]}"; do ufw allow "${p}/tcp" || true; done
    for p in "${udp_ports[@]}"; do ufw allow "${p}/udp" || true; done
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    info "检测到 firewalld active，自动放行端口。"
    for p in "${tcp_ports[@]}"; do firewall-cmd --permanent --add-port="${p}/tcp" || true; done
    for p in "${udp_ports[@]}"; do firewall-cmd --permanent --add-port="${p}/udp" || true; done
    firewall-cmd --reload || true
  else
    warn "未检测到已启用的 ufw/firewalld，本脚本不主动安装或启用防火墙。"
  fi
  echo "请确认云厂商安全组放行：TCP ${tcp_ports[*]:-无} / UDP ${udp_ports[*]:-无}"
}

restart_services() {
  xray run -test -config "$XRAY_CONFIG" || die "Xray 配置测试失败。"
  systemctl restart xray || die "Xray 重启失败。"
  [[ -f "$NGINX_SITE" ]] && nginx -t && (systemctl reload nginx || systemctl restart nginx)
  log "服务已重启。"
}

merge_remote_subscriptions() {
  mkdir -p "$SUB_DIR"
  local remotes="$SUB_DIR/remotes.conf" remote_raw="$SUB_DIR/remote.raw" merged="$SUB_DIR/merged.raw" merged_b64="$SUB_DIR/merged.b64"
  touch "$remotes"
  : >"$remote_raw"
  while read -r url; do
    [[ -z "$url" || "$url" =~ ^# ]] && continue
    info "拉取远程订阅：$url"
    local data
    data=$(curl -fsSL --max-time 20 "$url" 2>/dev/null || true)
    [[ -z "$data" ]] && { warn "拉取失败：$url"; continue; }
    echo "$data" | base64 -d 2>/dev/null >>"$remote_raw" || warn "解码失败：$url"
    echo >>"$remote_raw"
  done <"$remotes"
  cat "$SUB_DIR/local.raw" "$remote_raw" 2>/dev/null | sed '/^$/d' | awk '!seen[$0]++' >"$merged"
  base64 -w0 "$merged" >"$merged_b64"
  log "总订阅已生成：$merged_b64"
}

show_status() {
  echo "===== Xray ====="
  xray version 2>/dev/null || true
  systemctl status xray --no-pager -l 2>/dev/null || true
  echo
  echo "===== Nginx ====="
  nginx -t 2>&1 || true
  systemctl status nginx --no-pager -l 2>/dev/null || true
}

show_links() {
  load_state
  echo "===== 本机订阅 ====="
  echo "https://${BASE_DOMAIN:-<BASE_DOMAIN>}/sub/${SUB_TOKEN:-<TOKEN>}"
  echo
  echo "===== local.raw ====="
  [[ -f "$SUB_DIR/local.raw" ]] && cat "$SUB_DIR/local.raw" || warn "尚未生成。"
  echo
  echo "===== Mihomo 参考片段 ====="
  [[ -f "$SUB_DIR/mihomo-reference.yaml" ]] && echo "$SUB_DIR/mihomo-reference.yaml" || warn "尚未生成。"
}

deployment_summary() {
  load_state
  echo
  echo "===== 部署摘要 ====="
  echo "母域名: ${BASE_DOMAIN:-未设置}"
  echo "DNS:"
  echo "  ${BASE_DOMAIN:-BASE}              CDN/订阅/伪装站，按 CDN 状态橙云/灰云"
  [[ -n "${PUBLIC_IPV4:-}" ]] && echo "  v4.${BASE_DOMAIN}           IPv4 直连，灰云 -> ${PUBLIC_IPV4}"
  [[ -n "${PUBLIC_IPV6:-}" ]] && echo "  v6.${BASE_DOMAIN}           IPv6 直连，灰云 -> ${PUBLIC_IPV6}"
  echo "协议组合: ${PROTOCOLS:-123}"
  protocol_enabled 1 && echo "  XHTTP+REALITY: TCP ${XHTTP_REALITY_PORT:-2443}"
  protocol_enabled 2 && echo "  XHTTP+TLS+CDN: TCP ${CDN_PORT:-443}"
  protocol_enabled 3 && echo "  Xray Hysteria2: UDP ${HY2_PORT:-443}"
  protocol_enabled 4 && echo "  REALITY+Vision: TCP ${REALITY_VISION_PORT:-3443}"
  [[ -n "${HY2_HOP_RANGE:-}" ]] && echo "  HY2 端口跳跃: UDP ${HY2_HOP_RANGE/:/-} -> ${HY2_PORT:-443}"
  echo "BestCF: ${BESTCF_ENABLED:-0}"
  echo "订阅: https://${BASE_DOMAIN:-BASE}/sub/${SUB_TOKEN:-TOKEN}"
}

install_full() {
  need_root
  install_deps
  install_or_upgrade_xray
  update_geodata
  configure_base_domain
  setup_cloudflare
  asn_report
  select_protocols
  create_dns_records
  issue_certificate
  choose_reality_target
  generate_xray_config
  if [[ "${PROTOCOLS:-123}" == *2* ]]; then configure_nginx; fi
  configure_hy2_hopping_prompt
  handle_firewall_ports
  restart_services
  generate_subscription
  deployment_summary
  log "首次部署流程完成。"
}

bestcf_menu() {
  while true; do
    echo
    echo "===== BestCF 优选域名管理，默认关闭 ====="
    echo "1. 启用 BestCF 并立即拉取优选域名"
    echo "2. 关闭 BestCF"
    echo "3. 立即拉取 BestCF 优选域名"
    echo "4. 查看当前优选域名数量"
    echo "0. 返回"
    local c; c=$(ask "请选择" "0")
    case "$c" in
      1) enable_bestcf ;;
      2) disable_bestcf ;;
      3) fetch_bestcf_domains ;;
      4) [[ -f "$BESTCF_DIR/bestcf-domain.txt" ]] && wc -l "$BESTCF_DIR/bestcf-domain.txt" || warn "暂无数据。" ;;
      0) break ;;
      *) warn "无效选择。" ;;
    esac
  done
}

subscription_menu() {
  while true; do
    echo
    echo "===== 订阅管理 ====="
    echo "1. 重新生成本机 b64 订阅"
    echo "2. 查看本机分享链接 / 订阅链接"
    echo "3. 添加远程 b64 订阅"
    echo "4. 拉取并整合远程订阅"
    echo "0. 返回"
    local c; c=$(ask "请选择" "0")
    case "$c" in
      1) generate_subscription ;;
      2) show_links ;;
      3) echo "请输入远程 b64 订阅 URL："; read -r url; [[ -n "$url" ]] && echo "$url" >>"$SUB_DIR/remotes.conf" ;;
      4) merge_remote_subscriptions ;;
      0) break ;;
      *) warn "无效选择。" ;;
    esac
  done
}

main_menu() {
  need_root
  load_state
  while true; do
    echo
    echo "===== Xray Anti-Block Manager Alpha R3 ====="
    echo "1. 首次部署向导，推荐"
    echo "2. 安装/升级基础依赖"
    echo "3. 安装/升级 Xray-core"
    echo "4. 更新 geoip.dat / geosite.dat"
    echo "5. 网络优化 / BBR 状态与稳定优化"
    echo "6. Cloudflare 域名 / DNS / 小云朵管理"
    echo "7. 证书申请 / 续签 / 自动部署"
    echo "8. 查询 IPv4 / IPv6 / ASN 辅助报告"
    echo "9. 选择协议组合并生成 Xray 配置"
    echo "10. 配置 CDN / Nginx / 伪装站"
    echo "11. BestCF 优选域名管理，默认关闭"
    echo "12. 配置 Hysteria2 端口跳跃"
    echo "13. 本机防火墙端口处理"
    echo "14. 订阅管理 / 多机汇总"
    echo "15. 查看服务状态"
    echo "16. 查看分享链接 / 订阅链接"
    echo "17. 重启服务"
    echo "18. 部署摘要"
    echo "0. 退出"
    local c; c=$(ask "请选择" "0")
    case "$c" in
      1) install_full; pause ;;
      2) install_deps; pause ;;
      3) install_or_upgrade_xray; pause ;;
      4) update_geodata; if confirm "是否启用每 3 天自动更新 geodata？" "Y"; then enable_geodata_timer; fi; pause ;;
      5) network_status; if confirm "是否应用稳定型网络优化？" "N"; then apply_stable_network_tuning; fi; pause ;;
      6) setup_cloudflare; create_dns_records; pause ;;
      7) issue_certificate; pause ;;
      8) asn_report; pause ;;
      9) select_protocols; choose_reality_target; generate_xray_config; pause ;;
      10) configure_nginx; pause ;;
      11) bestcf_menu ;;
      12) configure_hy2_hopping_prompt; pause ;;
      13) handle_firewall_ports; pause ;;
      14) subscription_menu ;;
      15) show_status; pause ;;
      16) show_links; pause ;;
      17) restart_services; pause ;;
      18) deployment_summary; pause ;;
      0) exit 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

main_menu "$@"
