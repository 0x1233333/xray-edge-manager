#!/usr/bin/env bash
# Generate Xray Edge Manager v0.0.33-runtime-fixes from v0.0.32-subscription-path-fix.
# v2: cleaner input discovery, whitespace-tolerant function matching, safer atomic write.
# Usage:
#   bash make_xem_v0.0.33_runtime_fixes.sh /path/to/xem-v0.0.32.sh /path/to/xem-v0.0.33-runtime-fixes.sh
# If the output path is omitted, it writes ./xem-v0.0.33-runtime-fixes.sh.
set -Eeuo pipefail

infile="${1:-}"
outfile="${2:-xem-v0.0.33-runtime-fixes.sh}"

if [[ -z "$infile" ]]; then
  for cand in ./xem-v0.0.32-subscription-path-fix.sh ./xem.sh /usr/local/bin/xem; do
    if [[ -f "$cand" ]]; then infile="$cand"; break; fi
  done
fi

if [[ -z "$infile" || ! -f "$infile" ]]; then
  echo "用法：bash $0 /path/to/xem-v0.0.32.sh [输出文件]" >&2
  echo "错误：未找到输入脚本。" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "错误：需要 python3。" >&2; exit 1; }

python3 - "$infile" "$outfile" <<'PY'
from __future__ import annotations
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
text = src.read_text(encoding="utf-8")
original = text
changes: list[str] = []


def exact(old: str, new: str, label: str, *, count: int | None = None) -> None:
    global text
    n = text.count(old)
    if count is not None and n != count:
        if new in text:
            return
        raise SystemExit(f"补丁失败：{label}，期望 {count} 处，实际 {n} 处")
    if n == 0:
        if new in text:
            return
        raise SystemExit(f"补丁失败：{label}，未找到目标片段")
    text = text.replace(old, new, count if count is not None else -1)
    changes.append(label)


def regex(pattern: str, repl: str, label: str, *, flags: int = re.S, count: int = 1) -> None:
    global text
    new_text, n = re.subn(pattern, repl, text, count=count, flags=flags)
    if n != count:
        if repl in text:
            return
        raise SystemExit(f"补丁失败：{label}，期望 {count} 处，实际 {n} 处")
    text = new_text
    changes.append(label)

# 1) Version markers.
exact(
    "# v0.0.32-subscription-path-fix — subscription reachability + origin hardening",
    "# v0.0.33-runtime-fixes — preserve subscription path + firewall/DNS/cert hardening",
    "version header",
    count=1,
)
exact(
    "echo \"===== Xray Edge Manager v0.0.32-subscription-path-fix =====\"",
    "echo \"===== Xray Edge Manager v0.0.33-runtime-fixes =====\"",
    "menu version",
    count=1,
)

# 2) iptables/ip6tables xtables lock waiting wrappers.
exact(
    'CURL_MAX_TIME=20\nREMOTE_SUB_MAX_BYTES=',
    '''CURL_MAX_TIME=20\nXTABLES_WAIT="${XEM_XTABLES_WAIT:-5}"\n# Use iptables -w to avoid failing when Docker/ufw/firewalld temporarily holds the xtables lock.\n[[ "$XTABLES_WAIT" =~ ^[0-9]+$ ]] && [[ "$XTABLES_WAIT" -ge 0 ]] || XTABLES_WAIT=5\n\nipt(){ command iptables -w "$XTABLES_WAIT" "$@"; }\nip6t(){ command ip6tables -w "$XTABLES_WAIT" "$@"; }\n\nREMOTE_SUB_MAX_BYTES=''',
    "add xtables wait wrappers",
    count=1,
)

# 3) Exact IP-on-interface checks, not regex grep.
exact(
    'if [[ -n "$public_ip" ]] && ip -4 addr show | grep -qw "$public_ip"; then',
    'if [[ -n "$public_ip" ]] && ip -o -4 addr show | awk \'{print $4}\' | cut -d/ -f1 | grep -Fxq "$public_ip"; then',
    "IPv4 bind detection uses grep -F",
    count=1,
)
exact(
    'if [[ -n "$public_ip" ]] && ip -6 addr show scope global | grep -qw "$public_ip"; then',
    'if [[ -n "$public_ip" ]] && ip -o -6 addr show scope global | awk \'{print $4}\' | cut -d/ -f1 | grep -Fxq "$public_ip"; then',
    "IPv6 bind detection uses grep -F",
    count=1,
)

# 4) Certbot: stable cert name + avoid needless re-issuance/rate-limit risk.
exact(
    '''certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CRED" \\
      --dns-cloudflare-propagation-seconds 60 -d "$BASE_DOMAIN" -d "*.$BASE_DOMAIN" \\
      --agree-tos --non-interactive --email "$email" \\
      --deploy-hook "$CERT_DEPLOY_HOOK" || die "证书申请失败。"''',
    '''certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CRED" \\
      --dns-cloudflare-propagation-seconds 60 \\
      --cert-name "$BASE_DOMAIN" \\
      -d "$BASE_DOMAIN" -d "*.$BASE_DOMAIN" \\
      --agree-tos --non-interactive --keep-until-expiring --email "$email" \\
      --deploy-hook "$CERT_DEPLOY_HOOK" || die "证书申请失败。"''',
    "certbot email branch keep-until-expiring",
    count=1,
)
exact(
    '''certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CRED" \\
      --dns-cloudflare-propagation-seconds 60 -d "$BASE_DOMAIN" -d "*.$BASE_DOMAIN" \\
      --agree-tos --non-interactive --register-unsafely-without-email \\
      --deploy-hook "$CERT_DEPLOY_HOOK" || die "证书申请失败。"''',
    '''certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CRED" \\
      --dns-cloudflare-propagation-seconds 60 \\
      --cert-name "$BASE_DOMAIN" \\
      -d "$BASE_DOMAIN" -d "*.$BASE_DOMAIN" \\
      --agree-tos --non-interactive --keep-until-expiring --register-unsafely-without-email \\
      --deploy-hook "$CERT_DEPLOY_HOOK" || die "证书申请失败。"''',
    "certbot no-email branch keep-until-expiring",
    count=1,
)

# 5) Disable extra distro default nginx site if present.
exact(
    'for f in /etc/nginx/sites-enabled/default; do',
    'for f in /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf; do',
    "disable nginx conf.d/default.conf too",
    count=1,
)

# 6) Keep /var/www/.../sub while refreshing camouflage, and sanitize extracted zip entries.
exact(
    '''if curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 60 -o "$tmp/$zip" "$FODDER_BASE_URL/$zip" && unzip -q "$tmp/$zip" -d "$tmp/site"; then
    rm -rf "$WEB_ROOT"/*''',
    '''if curl -fsSL --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time 60 -o "$tmp/$zip" "$FODDER_BASE_URL/$zip" && unzip -q "$tmp/$zip" -d "$tmp/site"; then
    # HARDENING: do not allow downloaded camouflage templates to install symlinks or special files.
    find "$tmp/site" -type l -delete 2>/dev/null || true
    find "$tmp/site" \\( -type b -o -type c -o -type p -o -type s \\) -delete 2>/dev/null || true

    # RUNTIME FIX: preserve /sub subscription files when refreshing the camouflage site.
    find "$WEB_ROOT" -mindepth 1 -maxdepth 1 ! -name sub -exec rm -rf -- {} +
    mkdir -p "$WEB_ROOT/sub"
    chmod 755 "$WEB_ROOT" "$WEB_ROOT/sub" 2>/dev/null || true''',
    "preserve subscription directory during camouflage refresh",
    count=1,
)

# 7) Clean stale direct DNS records when corresponding stack direct protocols are disabled.
exact(
    '''  log "DNS 记录处理完成：BASE_DOMAIN 始终用于订阅/伪装站；v4/v6 子域名按直连协议生成。"''',
    '''  # Runtime hardening: if direct protocols are disabled for a stack, remove stale direct DNS records
  # so old v4./v6. records do not keep exposing the origin IP after a strategy change.
  if ! stack_has_direct_protocol "${IPV4_PROTOCOLS:-0}"; then
    cf_delete_record "v4.$BASE_DOMAIN" A "" force
  fi
  if ! stack_has_direct_protocol "${IPV6_PROTOCOLS:-0}"; then
    cf_delete_record "v6.$BASE_DOMAIN" AAAA "" force
  fi
  if [[ -n "$ip4" && -n "$ip6" ]]; then
    warn "BASE_DOMAIN 是订阅/伪装站/CDN 公共入口，当前存在 A + AAAA 双栈回源；v4/v6 直连仍由 v4./v6. 子域名单独控制。"
  fi
  log "DNS 记录处理完成：BASE_DOMAIN 始终用于订阅/伪装站；v4/v6 子域名按直连协议生成。"''',
    "cleanup stale v4/v6 direct DNS records",
    count=1,
)

# 8) iptables commands use wrappers with -w.
exact(
    'while iptables -t nat -D PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null; do removed=1; done',
    'while ipt -t nat -D PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null; do removed=1; done',
    "HY2 remove iptables uses -w",
    count=1,
)
exact(
    'while ip6tables -t nat -D PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null; do removed=1; done',
    'while ip6t -t nat -D PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null; do removed=1; done',
    "HY2 remove ip6tables uses -w",
    count=1,
)
exact(
    'iptables -t nat -A PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" || die "iptables 端口跳跃规则添加失败。"',
    'ipt -t nat -A PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" || die "iptables 端口跳跃规则添加失败。"',
    "HY2 add iptables uses -w",
    count=1,
)
exact(
    'ip6tables -t nat -A PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null || warn "ip6tables 规则添加失败，IPv6 跳跃可能不可用。"',
    'ip6t -t nat -A PREROUTING -p udp --dport "$start:$end" -j REDIRECT --to-ports "$to_port" 2>/dev/null || warn "ip6tables 规则添加失败，IPv6 跳跃可能不可用。"',
    "HY2 add ip6tables uses -w",
    count=1,
)

# 9) Replace CF origin firewall functions to use wrappers with -w.
regex(
    r'''remove_cf_origin_firewall_rules_one\(\)\{.*?\n\}\s*remove_cf_origin_firewall_rules\(\)\{''',
    '''remove_cf_origin_firewall_rules_one(){
  local tool="$1" p runner
  command -v "$tool" >/dev/null 2>&1 || return 0
  if [[ "$tool" == "iptables" ]]; then runner=ipt; else runner=ip6t; fi
  for p in 80 $CF_HTTPS_PORTS; do
    while "$runner" -D INPUT -p tcp --dport "$p" -j "$CF_ORIGIN_CHAIN" 2>/dev/null; do :; done
  done
  "$runner" -F "$CF_ORIGIN_CHAIN" 2>/dev/null || true
  "$runner" -X "$CF_ORIGIN_CHAIN" 2>/dev/null || true
}

remove_cf_origin_firewall_rules(){''',
    "CF origin firewall remove uses -w",
)
regex(
    r'''apply_cf_origin_firewall_one\(\)\{.*?\n\}\s*apply_cf_origin_firewall\(\)\{''',
    '''apply_cf_origin_firewall_one(){
  local tool="$1" ip_file="$2" port="$3" cidr runner
  command -v "$tool" >/dev/null 2>&1 || return 0
  if [[ "$tool" == "iptables" ]]; then runner=ipt; else runner=ip6t; fi
  "$runner" -N "$CF_ORIGIN_CHAIN" 2>/dev/null || true
  "$runner" -F "$CF_ORIGIN_CHAIN"
  while IFS= read -r cidr; do
    [[ -n "$cidr" ]] || continue
    "$runner" -A "$CF_ORIGIN_CHAIN" -s "$cidr" -j ACCEPT || true
  done < "$ip_file"
  "$runner" -A "$CF_ORIGIN_CHAIN" -j DROP
  "$runner" -I INPUT -p tcp --dport 80 -j "$CF_ORIGIN_CHAIN"
  [[ "$port" != "80" ]] && "$runner" -I INPUT -p tcp --dport "$port" -j "$CF_ORIGIN_CHAIN"
}

apply_cf_origin_firewall(){''',
    "CF origin firewall apply uses -w",
)

# 10) Replace firewall port handling to use ufw ':' range and firewalld '-' range.
regex(
    r'''handle_firewall_ports\(\)\{.*?\n\}\s*restart_services\(\)\{''',
    '''handle_firewall_ports(){
  load_state
  local tcp_ports=() udp_ports=()
  local hy2_hop_ufw="" hy2_hop_firewalld=""
  tcp_ports+=("${CDN_PORT:-443}")
  [[ "${PROTOCOLS:-0}" == *1* ]] && tcp_ports+=("${XHTTP_REALITY_PORT:-2443}")
  [[ "${PROTOCOLS:-0}" == *4* ]] && tcp_ports+=("${REALITY_VISION_PORT:-3443}")
  [[ "${PROTOCOLS:-0}" == *3* ]] && udp_ports+=("${HY2_PORT:-443}")

  if [[ -n "${HY2_HOP_RANGE:-}" ]]; then
    hy2_hop_ufw="${HY2_HOP_RANGE}"             # ufw expects start:end
    hy2_hop_firewalld="${HY2_HOP_RANGE/:/-}"  # firewalld expects start-end
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    for p in "${tcp_ports[@]}"; do ufw allow "${p}/tcp" || true; done
    for p in "${udp_ports[@]}"; do ufw allow "${p}/udp" || true; done
    [[ -n "$hy2_hop_ufw" ]] && ufw allow "${hy2_hop_ufw}/udp" || true
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in "${tcp_ports[@]}"; do firewall-cmd --permanent --add-port="${p}/tcp" || true; done
    for p in "${udp_ports[@]}"; do firewall-cmd --permanent --add-port="${p}/udp" || true; done
    [[ -n "$hy2_hop_firewalld" ]] && firewall-cmd --permanent --add-port="${hy2_hop_firewalld}/udp" || true
    firewall-cmd --reload || true
  else
    warn "未检测到已启用的 ufw/firewalld，本脚本不主动安装或启用防火墙。"
  fi
  echo "请确认云厂商安全组放行：TCP ${tcp_ports[*]:-无} / UDP ${udp_ports[*]:-无}${hy2_hop_firewalld:+ / HY2跳跃UDP $hy2_hop_firewalld}"
  configure_cf_origin_firewall_prompt
}

restart_services(){''',
    "fix ufw/firewalld HY2 port range formats",
)

# 11) Menu option 10 must regenerate subscription after nginx/camouflage reconfiguration.
exact(
    '10) configure_nginx; pause ;;',
    '10) configure_nginx; regenerate_subscriptions_after_change; pause ;;',
    "menu 10 regenerates subscription",
    count=1,
)

# Sanity checks for key fixes.
required = [
    'v0.0.33-runtime-fixes',
    'XTABLES_WAIT="${XEM_XTABLES_WAIT:-5}"',
    'find "$WEB_ROOT" -mindepth 1 -maxdepth 1 ! -name sub',
    '--keep-until-expiring --email "$email"',
    'for f in /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf; do',
    'cf_delete_record "v4.$BASE_DOMAIN" A "" force',
    'ufw allow "${hy2_hop_ufw}/udp"',
    '10) configure_nginx; regenerate_subscriptions_after_change; pause ;;',
]
missing = [s for s in required if s not in text]
if missing:
    raise SystemExit("补丁结果自检失败，缺少：\n" + "\n".join(missing))

# Write atomically. Create the temporary file with final permissions from the start.
dst.parent.mkdir(parents=True, exist_ok=True)
tmp = dst.with_name(f".{dst.name}.tmp")
try:
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o755)
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, dst)
except Exception:
    try:
        if tmp.exists():
            tmp.unlink()
    finally:
        raise

# Optional syntax check. It is okay if bash is not available on the patching host.
try:
    subprocess.run(["bash", "-n", str(dst)], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    syntax = "bash -n 通过"
except FileNotFoundError:
    syntax = "未检测到 bash，跳过语法检查"
except subprocess.CalledProcessError as e:
    print(e.stderr, file=sys.stderr)
    raise SystemExit("生成后的脚本 bash -n 失败，已写入文件但不建议使用。")

print(f"已生成：{dst}")
print(f"输入文件：{src}")
print(f"输出文件权限：755")
print(f"语法检查：{syntax}")
print("应用修复项：")
for c in changes:
    print(f"- {c}")
PY
