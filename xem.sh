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
  local msg
  if [[ -n "$default" ]]; then
    msg="$prompt [$default]: "
  else
    msg="$prompt: "
  fi

  # Use /dev/tty for interactive input when possible. This prevents command
  # substitution or piped execution from swallowing menu prompts or breaking input.
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '%s' "$msg" > /dev/tty
    IFS= read -r ans < /dev/tty || true
  else
    printf '%s' "$msg" >&2
    IFS= read -r ans || true
  fi

  if [[ -n "$default" ]]; then
    echo "${ans:-$default}"
  else
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
  local d force="${1:-0}"
  if [[ "$force" != "1" && -n "${BASE_DOMAIN:-}" ]] && validate_base_domain "$BASE_DOMAIN"; then
    info "已使用当前母域名：$BASE_DOMAIN"
    return 0
  fi
  while true; do
    d=$(ask "请输入母域名，必须三段式或以上，例如 node.example.com" "${BASE_DOMAIN:-}")
    d=$(printf '%s' "$d" | tr -d '[:space:]')
    if validate_base_domain "$d"; then
      save_kv "$STATE_FILE" BASE_DOMAIN "$d"
      log "母域名已设置：$d"
      break
    else
      warn "域名不合格。必须类似 node.example.com，不能是 example.com 这种二段根域。"
    fi
  done
}

prepare_base_domain_for_install() {
  load_state
  if [[ -n "${BASE_DOMAIN:-}" ]] && validate_base_domain "$BASE_DOMAIN"; then
    echo "检测到上次保存的母域名：$BASE_DOMAIN"
    echo "1. 继续使用这个母域名"
    echo "2. 重新输入母域名"
    local c
    c=$(ask "请选择" "1")
    case "$c" in
      1) info "继续使用当前母域名：$BASE_DOMAIN" ;;
      2) configure_base_domain 1 ;;
      *) warn "无效选择，继续使用当前母域名：$BASE_DOMAIN" ;;
    esac
  else
    configure_base_domain 1
  fi
}

reset_base_domain() {
  load_state
  if [[ -n "${BASE_DOMAIN:-}" ]]; then
    warn "当前母域名：$BASE_DOMAIN"
  else
    warn "当前未保存母域名。"
  fi
  if confirm "是否重新设置母域名？这不会自动删除旧 DNS 记录" "N"; then
    configure_base_domain 1
    log "母域名已重置。后续请重新运行 DNS / 证书 / Nginx / 订阅相关菜单。"
  fi
}

show_installation_state() {
  load_state
  echo "===== 安装状态检测 ====="
  echo "APP_DIR: $APP_DIR"
  echo "BASE_DOMAIN: ${BASE_DOMAIN:-未设置}"
  echo "PROTOCOLS: ${PROTOCOLS:-未设置}"
  echo "ENABLE_CDN: ${ENABLE_CDN:-未设置}"
  echo "BESTCF_ENABLED: ${BESTCF_ENABLED:-0}"
  echo "Xray config: $([[ -f "$XRAY_CONFIG" ]] && echo 存在 || echo 不存在)"
  echo "Nginx site: $([[ -f "$NGINX_SITE" ]] && echo 存在 || echo 不存在)"
  echo "Cloudflare env: $([[ -f "$CF_ENV" ]] && echo 存在 || echo 不存在)"
  echo "Certificate: $([[ -n "${BASE_DOMAIN:-}" && -d "/etc/letsencrypt/live/${BASE_DOMAIN}" ]] && echo 存在 || echo 不存在或未检测)"
  echo "Subscription: $([[ -f "$SUB_DIR/local.b64" ]] && echo 存在 || echo 不存在)"
  echo
  systemctl is-active xray >/dev/null 2>&1 && echo "Xray service: active" || echo "Xray service: inactive/unknown"
  systemctl is-active nginx >/dev/null 2>&1 && echo "Nginx service: active" || echo "Nginx service: inactive/unknown"
}

installation_state_menu() {
  while true; do
    echo
    echo "===== 安装状态 / 母域名管理 ====="
    echo "1. 查看当前安装状态"
    echo "2. 重新设置母域名"
    echo "3. 清理脚本状态文件，保留系统服务与配置"
    echo "0. 返回"
    local c
    c=$(ask "请选择" "0")
    case "$c" in
      1) show_installation_state; pause ;;
      2) reset_base_domain; pause ;;
      3)
        if confirm "确认清理 $STATE_FILE？这会让脚本忘记上次输入，但不会删除 Xray/Nginx/证书" "N"; then
          cp -a "$STATE_FILE" "$BACKUP_DIR/state.env.manual-clear.$(date +%F-%H%M%S).bak" 2>/dev/null || true
          rm -f "$STATE_FILE"
          log "已清理脚本状态文件。"
        fi
        pause
        ;;
      0) break ;;
      *) warn "无效选择。" ;;
    esac
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
  echo "Cloudflare API Token 创建教程："
echo "  https://github.com/0x1233333/xray-edge-manager/blob/main/examples/cloudflare-api-token.md"
echo "请使用 Restricted API Token，不要使用 Global API Key。"
token=$(ask "请输入 Cloudflare Restricted API Token，需 Zone:Read + DNS:Edit" "${CF_API_TOKEN:-}")
  token=$(printf '%s' "$token" | tr -d '[:space:]')
  [[ -n "$token" ]] || die "API Token 不能为空。"
  cloudflare_token_risk_check "$token"
  save_kv "$CF_ENV" CF_API_TOKEN "$token"
  source "$CF_ENV"

  zone_name=$(ask "请输入 Cloudflare Zone Name，例如 example.com" "${CF_ZONE_NAME:-}")
  zone_name=$(printf '%s' "$zone_name" | tr -d '[:space:]')
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
  [[ -n "$zone_id" ]] || die "未查到 Zone ID。请确认 Zone Name 拼写无误，并确认创建 Token 时 Zone Resources 已包含该域名，未错选成其他域名。"
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
    if stack_has_direct_protocol "${IPV4_PROTOCOLS:-1}"; then
      cf_upsert_record "v4.$BASE_DOMAIN" A "$ip4" false
    else
      info "IPv4 策略未启用直连，跳过 v4.$BASE_DOMAIN DNS 记录创建。"
    fi
  fi
  if [[ -n "$ip6" ]]; then
    cf_upsert_record "$BASE_DOMAIN" AAAA "$ip6" "$proxied_base"
    if stack_has_direct_protocol "${IPV6_PROTOCOLS:-1}"; then
      cf_upsert_record "v6.$BASE_DOMAIN" AAAA "$ip6" false
    else
      info "IPv6 策略未启用直连，跳过 v6.$BASE_DOMAIN DNS 记录创建。"
    fi
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
    local raw_output priv pub

    # Execute xray x25519 and normalize its output before parsing.
    # Some versions or terminal environments may emit ANSI color codes.
    raw_output=$(xray x25519 2>&1 | sed -r 's/\[[0-9;]*[mK]//g' || true)

    # Xray x25519 output changed across versions. Known variants include:
    #   Private key: xxx
    #   Public key: xxx
    #   PrivateKey: xxx
    #   Password: xxx
    #   Password (PublicKey): xxx
    # Keep parsing tolerant and strip all whitespace from extracted keys.
    priv=$(printf '%s
' "$raw_output" \
      | grep -iE 'Private[ _-]?key|PrivateKey|Seed' \
      | awk -F':' '{print $2}' \
      | tr -d '[:space:]' \
      | head -n1)

    pub=$(printf '%s
' "$raw_output" \
      | grep -iE 'Public[ _-]?key|PublicKey|Password|Client' \
      | awk -F':' '{print $2}' \
      | tr -d '[:space:]' \
      | head -n1)

    if [[ -z "$priv" || -z "$pub" ]]; then
      err "xray x25519 输出无法解析。脱色后的原始输出如下："
      err "==== xray x25519 output begin ===="
      printf '%s
' "$raw_output" >&2
      err "==== xray x25519 output end ===="
      die "REALITY 密钥生成失败。请确认 Xray 版本支持 x25519，或手动执行：xray x25519"
    fi

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
  local default_protocols
  default_protocols="${PROTOCOLS:-$(build_default_protocols_from_stack_strategy)}"
  p=$(ask "默认安装" "$default_protocols")
  [[ "$p" =~ ^[1-5]+$ ]] || die "协议组合只能由 1-5 数字组成。"
  if [[ "$p" == *1* && "${NEED_DIRECT_PROTOCOL:-1}" == "0" ]]; then
    warn "当前 IPv4/IPv6 都没有选择 XHTTP+REALITY 直连，但协议组合包含 1。"
    if confirm "是否移除协议 1，避免生成无效直连入站？" "Y"; then
      p="${p//1/}"
      [[ -z "$p" ]] && p="3"
    fi
  fi
  if [[ "$p" == *2* && "${NEED_CDN_PROTOCOL:-1}" == "0" ]]; then
    warn "你前面选择不生成 CDN 节点，但协议组合包含 2。"
    if confirm "是否移除协议 2？" "Y"; then
      p="${p//2/}"
      [[ -z "$p" ]] && p="3"
    fi
  fi
  if [[ "$p" == *3* && "${NEED_HY2_PROTOCOL:-1}" == "0" ]]; then
    warn "你前面选择不生成 Hysteria2，但协议组合包含 3。"
    if confirm "是否移除协议 3？" "Y"; then
      p="${p//3/}"
      [[ -z "$p" ]] && p="1"
    fi
  fi
  if [[ "$p" == *4* && "${IPV4_PROTOCOLS:-0}" != *4* && "${IPV6_PROTOCOLS:-0}" != *4* ]]; then
    warn "当前 IPv4/IPv6 都没有选择 REALITY+Vision，但协议组合包含 4。"
    if confirm "是否移除协议 4？" "Y"; then
      p="${p//4/}"
      [[ -z "$p" ]] && p="3"
    fi
  fi
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
  if [[ -f "$XRAY_CONFIG" ]]; then
    cp -a "$XRAY_CONFIG" "$BACKUP_DIR/config.json.$ts.bak"
    save_kv "$STATE_FILE" LAST_XRAY_BACKUP "$BACKUP_DIR/config.json.$ts.bak"
  fi
  if [[ -f "$NGINX_SITE" ]]; then
    cp -a "$NGINX_SITE" "$BACKUP_DIR/nginx.$ts.bak"
    save_kv "$STATE_FILE" LAST_NGINX_BACKUP "$BACKUP_DIR/nginx.$ts.bak"
  fi
  [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$BACKUP_DIR/state.env.$ts.bak"
}

restore_latest_xray_config() {
  load_state
  local bak="${LAST_XRAY_BACKUP:-}"
  if [[ -z "$bak" || ! -f "$bak" ]]; then
    bak=$(ls -1t "$BACKUP_DIR"/config.json.*.bak 2>/dev/null | head -n1 || true)
  fi
  if [[ -n "$bak" && -f "$bak" ]]; then
    cp -a "$bak" "$XRAY_CONFIG"
    warn "已自动回滚 Xray 配置：$bak -> $XRAY_CONFIG"
    return 0
  fi
  warn "未找到可回滚的 Xray 配置备份。"
  return 1
}

restore_latest_nginx_config() {
  load_state
  local bak="${LAST_NGINX_BACKUP:-}"
  if [[ -z "$bak" || ! -f "$bak" ]]; then
    bak=$(ls -1t "$BACKUP_DIR"/nginx.*.bak 2>/dev/null | head -n1 || true)
  fi
  if [[ -n "$bak" && -f "$bak" ]]; then
    cp -a "$bak" "$NGINX_SITE"
    warn "已自动回滚 Nginx 配置：$bak -> $NGINX_SITE"
    return 0
  fi
  warn "未找到可回滚的 Nginx 配置备份。"
  return 1
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

  if protocol_enabled 1 && [[ "$direct_needed" == "1" ]]; then
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

  local in_tmp out_tmp route_tmp first_in=1 first_out=1 first_route=1 ip4 ip6 bind direct_needed
  in_tmp=$(mktemp); out_tmp=$(mktemp); route_tmp=$(mktemp)
  ip4="${PUBLIC_IPV4:-$(public_ipv4)}"; ip6="${PUBLIC_IPV6:-$(public_ipv6)}"
  [[ -n "$ip4" ]] && save_kv "$STATE_FILE" PUBLIC_IPV4 "$ip4"
  [[ -n "$ip6" ]] && save_kv "$STATE_FILE" PUBLIC_IPV6 "$ip6"
  bind="${ENABLE_IP_STACK_BINDING:-1}"
  if mode_has_direct "${IPV4_STRATEGY:-3}" || mode_has_direct "${IPV6_STRATEGY:-3}"; then
    direct_needed="1"
  else
    direct_needed="0"
  fi

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
    if [[ "$bind" == "1" && -n "$ip4" && ( "${IPV4_STRATEGY:-3}" == "1" || "${IPV4_STRATEGY:-3}" == "3" ) ]]; then
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

    if [[ "$bind" == "1" && -n "$ip6" && ( "${IPV6_STRATEGY:-3}" == "1" || "${IPV6_STRATEGY:-3}" == "3" ) ]]; then
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

    if [[ "$bind" != "1" && "$direct_needed" == "1" ]]; then
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
  elif protocol_enabled 1 && [[ "$direct_needed" != "1" ]]; then
    warn "协议 1 已选择，但分栈策略没有启用任何直连栈，已跳过 XHTTP+REALITY 入站生成。"
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
  if ! jq empty "$XRAY_CONFIG" >/dev/null 2>&1; then
    restore_latest_xray_config || true
    die "生成的 Xray JSON 不是合法 JSON，已自动尝试回滚上一版本配置。"
  fi
  if ! xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
    restore_latest_xray_config || true
    die "Xray 配置测试失败，已自动尝试回滚上一版本配置。"
  fi
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
  if ! nginx -t; then
    restore_latest_nginx_config || true
    die "Nginx 配置测试失败，已自动尝试回滚上一版本配置。"
  fi
  systemctl enable nginx >/dev/null 2>&1 || true
  if ! systemctl reload nginx && ! systemctl restart nginx; then
    restore_latest_nginx_config || true
    nginx -t >/dev/null 2>&1 && (systemctl reload nginx || systemctl restart nginx) || true
    die "Nginx reload/restart 失败，已自动尝试回滚上一版本配置。"
  fi
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
  info "建议：优质 v4/v6 可选 XHTTP+REALITY；普通/绕路线路可选 CDN 节点兜底。"
}

stack_protocols_has() {
  local protos="$1" proto="$2"
  [[ "$protos" == *"$proto"* ]]
}

stack_has_direct_protocol() {
  local protos="$1"
  [[ "$protos" == *"1"* || "$protos" == *"4"* ]]
}

normalize_stack_protocols() {
  local p="$1" out=""
  p="${p//,/}"
  p="${p// /}"
  [[ "$p" == "0" || -z "$p" ]] && { echo "0"; return 0; }
  [[ "$p" == *1* ]] && out="${out}1"
  [[ "$p" == *4* ]] && out="${out}4"
  [[ -z "$out" ]] && out="0"
  echo "$out"
}

select_one_stack_protocols() {
  local label="$1" current="$2" default_mode="$3" mode normalized
  echo >&2
  echo "===== ${label} 直连协议选择 =====" >&2
  echo "0. 不生成 ${label} 直连节点" >&2
  echo "1. 生成 ${label} VLESS + XHTTP + REALITY" >&2
  echo "4. 生成 ${label} VLESS + REALITY + Vision，可选备用" >&2
  echo "14. 同时生成 ${label} 的 XHTTP+REALITY 和 REALITY+Vision" >&2
  echo "说明：CDN 节点使用母域名 node.example.com，是全局节点，不在这里按 v4/v6 拆分。" >&2
  mode=$(ask "请选择 ${label} 直连协议" "${current:-$default_mode}")
  normalized=$(normalize_stack_protocols "$mode")
  echo "$normalized"
}

select_ip_stack_strategy() {
  load_state
  local ip4 ip6 v4_protos v6_protos enable_cdn enable_hy2 default_p
  ip4="${PUBLIC_IPV4:-$(public_ipv4)}"
  ip6="${PUBLIC_IPV6:-$(public_ipv6)}"
  [[ -n "$ip4" ]] && save_kv "$STATE_FILE" PUBLIC_IPV4 "$ip4"
  [[ -n "$ip6" ]] && save_kv "$STATE_FILE" PUBLIC_IPV6 "$ip6"

  echo
  echo "===== IPv4 / IPv6 分协议部署 ====="
  echo "说明："
  echo "  v4.node.example.com / v6.node.example.com 用于直连协议。"
  echo "  node.example.com 用于 CDN、伪装站和订阅。"
  echo "  CDN 节点是母域名全局节点，不严格区分 v4/v6。"

  if [[ -n "$ip4" ]]; then
    v4_protos=$(select_one_stack_protocols "IPv4" "${IPV4_PROTOCOLS:-}" "1")
    save_kv "$STATE_FILE" IPV4_PROTOCOLS "$v4_protos"
  else
    save_kv "$STATE_FILE" IPV4_PROTOCOLS "0"
    warn "未检测到 IPv4，IPv4 直连协议设为 0。"
  fi

  if [[ -n "$ip6" ]]; then
    v6_protos=$(select_one_stack_protocols "IPv6" "${IPV6_PROTOCOLS:-}" "1")
    save_kv "$STATE_FILE" IPV6_PROTOCOLS "$v6_protos"
  else
    save_kv "$STATE_FILE" IPV6_PROTOCOLS "0"
    warn "未检测到 IPv6，IPv6 直连协议设为 0。"
  fi

  load_state
  if stack_has_direct_protocol "${IPV4_PROTOCOLS:-0}" || stack_has_direct_protocol "${IPV6_PROTOCOLS:-0}"; then
    save_kv "$STATE_FILE" NEED_DIRECT_PROTOCOL "1"
  else
    save_kv "$STATE_FILE" NEED_DIRECT_PROTOCOL "0"
  fi

  if confirm "是否生成全局 CDN 节点：VLESS + XHTTP + TLS + CDN？" "Y"; then
    save_kv "$STATE_FILE" NEED_CDN_PROTOCOL "1"
    save_kv "$STATE_FILE" ENABLE_CDN "1"
  else
    save_kv "$STATE_FILE" NEED_CDN_PROTOCOL "0"
    save_kv "$STATE_FILE" ENABLE_CDN "0"
  fi

  if confirm "是否生成全局 Hysteria2 UDP 节点？" "Y"; then
    save_kv "$STATE_FILE" NEED_HY2_PROTOCOL "1"
  else
    save_kv "$STATE_FILE" NEED_HY2_PROTOCOL "0"
  fi

  default_p=$(build_default_protocols_from_stack_strategy)
  save_kv "$STATE_FILE" PROTOCOLS "$default_p"
  log "分协议策略已保存：IPv4=${IPV4_PROTOCOLS:-0} IPv6=${IPV6_PROTOCOLS:-0} 全局协议=${default_p}"
}

build_default_protocols_from_stack_strategy() {
  load_state
  local p=""
  if [[ "${IPV4_PROTOCOLS:-0}" == *1* || "${IPV6_PROTOCOLS:-0}" == *1* ]]; then p="${p}1"; fi
  if [[ "${NEED_CDN_PROTOCOL:-1}" == "1" ]]; then p="${p}2"; fi
  if [[ "${NEED_HY2_PROTOCOL:-1}" == "1" ]]; then p="${p}3"; fi
  if [[ "${IPV4_PROTOCOLS:-0}" == *4* || "${IPV6_PROTOCOLS:-0}" == *4* ]]; then p="${p}4"; fi
  [[ -z "$p" ]] && p="3"
  echo "$p"
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
    [[ -n "${PUBLIC_IPV4:-}" && ( "${IPV4_STRATEGY:-3}" == "1" || "${IPV4_STRATEGY:-3}" == "3" ) ]] && add_vless_xhttp_reality_link "v4.${BASE_DOMAIN}" "${NODE_NAME:-node}-v4-XHTTP-REALITY" "$raw"
    [[ -n "${PUBLIC_IPV6:-}" && ( "${IPV6_STRATEGY:-3}" == "1" || "${IPV6_STRATEGY:-3}" == "3" ) ]] && add_vless_xhttp_reality_link "v6.${BASE_DOMAIN}" "${NODE_NAME:-node}-v6-XHTTP-REALITY" "$raw"
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
  if ! xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
    restore_latest_xray_config || true
    die "Xray 配置测试失败，已自动尝试回滚。"
  fi
  if ! systemctl restart xray; then
    restore_latest_xray_config || true
    if xray run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
      systemctl restart xray || true
    fi
    die "Xray 重启失败，已自动尝试回滚上一版本配置。"
  fi

  if [[ -f "$NGINX_SITE" ]]; then
    if ! nginx -t >/dev/null 2>&1; then
      restore_latest_nginx_config || true
      die "Nginx 配置测试失败，已自动尝试回滚。"
    fi
    if ! systemctl reload nginx && ! systemctl restart nginx; then
      restore_latest_nginx_config || true
      nginx -t >/dev/null 2>&1 && (systemctl reload nginx || systemctl restart nginx) || true
      die "Nginx reload/restart 失败，已自动尝试回滚上一版本配置。"
    fi
  fi
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
  prepare_base_domain_for_install
  setup_cloudflare
  asn_report
  select_ip_stack_strategy
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

cf_get_record_json() {
  local name="$1" type="$2"
  load_state
  [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE_ID:-}" ]] || return 1
  curl -fsS --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" -G \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    --data-urlencode "type=$type" \
    --data-urlencode "name=$name"
}

cf_delete_record_by_id() {
  local rec_id="$1"
  [[ -n "$rec_id" ]] || return 1
  cf_api DELETE "/zones/$CF_ZONE_ID/dns_records/$rec_id" >/dev/null
}

cf_delete_owned_record() {
  local name="$1" type="$2" expected="$3" resp rec_id content
  [[ -n "$expected" ]] || { warn "跳过 $type $name：本机对应 IP 为空。"; return 0; }
  resp=$(cf_get_record_json "$name" "$type") || { warn "无法读取 $type $name，跳过。"; return 0; }
  rec_id=$(echo "$resp" | jq -r '.result[0].id // empty')
  content=$(echo "$resp" | jq -r '.result[0].content // empty')
  if [[ -z "$rec_id" ]]; then
    info "Cloudflare 中不存在 $type $name，跳过。"
    return 0
  fi
  if [[ "$content" != "$expected" ]]; then
    warn "跳过删除 $type $name：当前记录指向 $content，不等于本机 IP $expected。"
    warn "这可能已经被迁移到其他机器，为防止误伤不会删除。"
    return 0
  fi
  if cf_delete_record_by_id "$rec_id"; then
    log "已删除 Cloudflare DNS 记录：$type $name -> $content"
  else
    warn "删除失败：$type $name"
  fi
}

delete_cloudflare_records_with_ownership_check() {
  load_state
  [[ -n "${BASE_DOMAIN:-}" ]] || { warn "BASE_DOMAIN 未设置，无法清理 DNS。"; return 0; }
  [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ZONE_ID:-}" ]] || { warn "Cloudflare API 未配置，无法清理 DNS。"; return 0; }
  local ip4 ip6
  ip4="${PUBLIC_IPV4:-$(public_ipv4)}"
  ip6="${PUBLIC_IPV6:-$(public_ipv6)}"
  warn "即将尝试删除 Cloudflare DNS 记录，但只删除仍指向本机 IP 的记录。"
  echo "目标记录："
  echo "  $BASE_DOMAIN A/AAAA"
  echo "  v4.$BASE_DOMAIN A"
  echo "  v6.$BASE_DOMAIN AAAA"
  echo "本机 IP："
  echo "  IPv4: ${ip4:-无}"
  echo "  IPv6: ${ip6:-无}"
  if ! confirm "确认执行 DNS 归属权校验删除？" "N"; then
    warn "已取消 DNS 清理。"
    return 0
  fi
  cf_delete_owned_record "$BASE_DOMAIN" A "$ip4"
  cf_delete_owned_record "v4.$BASE_DOMAIN" A "$ip4"
  cf_delete_owned_record "$BASE_DOMAIN" AAAA "$ip6"
  cf_delete_owned_record "v6.$BASE_DOMAIN" AAAA "$ip6"
}

remove_hy2_hopping_rules() {
  load_state
  local range="${HY2_HOP_RANGE:-$DEFAULT_HY2_HOP_RANGE}" start end to_port
  start="${range%%:*}"; end="${range##*:}"; to_port="${HY2_PORT:-443}"
  if [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]]; then
    while iptables -t nat -D PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null; do :; done
    if command -v ip6tables >/dev/null 2>&1; then
      while ip6tables -t nat -D PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null; do :; done
    fi
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true
    log "已尝试删除端口跳跃规则：UDP $start-$end -> $to_port。"
  else
    warn "端口跳跃范围无效，跳过规则删除：$range"
  fi
}

full_uninstall_xem() {
  need_root
  load_state
  echo "===== 完整卸载 Xray Edge Manager ====="
  warn "这会清理本脚本部署的 Xray、Nginx 站点、订阅、状态目录和端口跳跃规则。"
  warn "适合纯节点机器；如果这台机器还有其他网站或服务，请不要继续。"
  if ! confirm "确认完整卸载？" "N"; then
    warn "已取消。"
    return 0
  fi

  if ! confirm "请再次确认：这台机器只用于当前节点，允许清理相关服务和配置" "N"; then
    warn "已取消。"
    return 0
  fi

  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  local ts="$(date +%F-%H%M%S)"
  [[ -f "$XRAY_CONFIG" ]] && cp -a "$XRAY_CONFIG" "$BACKUP_DIR/config.json.before-uninstall.$ts.bak" 2>/dev/null || true
  [[ -f "$NGINX_SITE" ]] && cp -a "$NGINX_SITE" "$BACKUP_DIR/nginx.before-uninstall.$ts.bak" 2>/dev/null || true
  [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$BACKUP_DIR/state.env.before-uninstall.$ts.bak" 2>/dev/null || true

  info "停止服务..."
  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  systemctl stop nginx 2>/dev/null || true

  info "删除 Hysteria2 端口跳跃规则..."
  remove_hy2_hopping_rules || true

  info "调用 Xray 官方卸载脚本 remove..."
  bash -c "$(curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove || warn "Xray 官方 remove 执行失败或已不存在，继续清理残留。"

  info "清理 Xray 残留文件..."
  rm -rf \
    /usr/local/etc/xray \
    /usr/local/share/xray \
    /var/log/xray \
    /etc/systemd/system/xray.service \
    /etc/systemd/system/xray@.service \
    /etc/systemd/system/xray.service.d \
    /etc/systemd/system/xray@.service.d 2>/dev/null || true

  info "清理 Nginx 站点与伪装目录..."
  rm -f "$NGINX_SITE" 2>/dev/null || true
  rm -rf "$WEB_ROOT" 2>/dev/null || true

  if [[ -n "${BASE_DOMAIN:-}" ]]; then
    info "尝试通过 Certbot 原生命令删除证书：$BASE_DOMAIN"
    if command -v certbot >/dev/null 2>&1; then
      certbot delete --cert-name "$BASE_DOMAIN" --non-interactive 2>/dev/null || warn "Certbot 未能删除证书，可能证书不存在或名称不同。为避免破坏 Certbot 状态，脚本不手动 rm letsencrypt 内部目录。"
    fi
  fi

  if confirm "是否同时移除 Nginx / Certbot / Cloudflare DNS 插件包？纯节点机器可选 Y" "Y"; then
    warn "该操作会移除 Nginx / Certbot 相关软件包。若此机器还有其他网站业务，请立刻取消。"
    local mode
    echo "1. apt remove，保留部分全局配置，较稳妥"
    echo "2. apt purge，彻底清理软件包配置，纯节点机器可选"
    mode=$(ask "请选择软件包移除方式" "1")
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      if [[ "$mode" == "2" ]]; then
        if confirm "最后确认 apt purge？这会清理 Nginx/Certbot 全局配置" "N"; then
          apt-get purge -y nginx nginx-common nginx-core certbot python3-certbot-dns-cloudflare 2>/dev/null || true
        fi
      else
        apt-get remove -y nginx nginx-common nginx-core certbot python3-certbot-dns-cloudflare 2>/dev/null || true
      fi
      apt-get autoremove -y 2>/dev/null || true
    else
      warn "未检测到 apt-get，跳过软件包移除。"
    fi
  fi

  info "清理脚本状态目录..."
  if confirm "是否尝试删除 Cloudflare DNS 记录？仅删除仍指向本机 IP 的记录，默认不删" "N"; then
    delete_cloudflare_records_with_ownership_check || true
  fi

  rm -rf "$APP_DIR" 2>/dev/null || true

  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true

  log "完整卸载完成。"
  warn "Cloudflare DNS 记录不会自动删除。你可以在 Cloudflare 后台手动删除 node/v4/v6 相关记录，或后续再加 DNS 清理功能。"
}

uninstall_menu() {
  while true; do
    echo
    echo "===== 卸载 / 清理 ====="
    echo "1. 完整卸载本脚本环境，推荐纯节点机器使用"
    echo "2. 仅停止并禁用 Xray 服务"
    echo "3. 仅删除 Hysteria2 端口跳跃规则"
    echo "4. 仅清理脚本状态目录 $APP_DIR"
    echo "5. 删除 Cloudflare DNS 记录，带归属权校验，默认不删"
    echo "0. 返回"
    local c
    c=$(ask "请选择" "0")
    case "$c" in
      1) full_uninstall_xem; pause ;;
      2)
        if confirm "确认停止并禁用 xray 服务？" "N"; then
          systemctl stop xray 2>/dev/null || true
          systemctl disable xray 2>/dev/null || true
          log "已停止并禁用 xray。"
        fi
        pause
        ;;
      3) remove_hy2_hopping_rules; pause ;;
      4)
        if confirm "确认删除 $APP_DIR？这会删除脚本状态、订阅、本地缓存和备份" "N"; then
          rm -rf "$APP_DIR"
          log "已删除脚本状态目录。"
        fi
        pause
        ;;
      5) delete_cloudflare_records_with_ownership_check; pause ;;
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
    echo "9. IPv4 / IPv6 分栈策略 + 协议组合并生成 Xray 配置"
    echo "10. 配置 CDN / Nginx / 伪装站"
    echo "11. BestCF 优选域名管理，默认关闭"
    echo "12. 配置 Hysteria2 端口跳跃"
    echo "13. 本机防火墙端口处理"
    echo "14. 订阅管理 / 多机汇总"
    echo "15. 查看服务状态"
    echo "16. 查看分享链接 / 订阅链接"
    echo "17. 重启服务"
    echo "18. 部署摘要"
    echo "19. 安装状态 / 母域名管理"
    echo "20. 卸载 / 清理"
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
      9) asn_report; select_ip_stack_strategy; select_protocols; choose_reality_target; generate_xray_config; pause ;;
      10) configure_nginx; pause ;;
      11) bestcf_menu ;;
      12) configure_hy2_hopping_prompt; pause ;;
      13) handle_firewall_ports; pause ;;
      14) subscription_menu ;;
      15) show_status; pause ;;
      16) show_links; pause ;;
      17) restart_services; pause ;;
      18) deployment_summary; pause ;;
      19) installation_state_menu ;;
      20) uninstall_menu ;;
      0) exit 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

main_menu "$@"
