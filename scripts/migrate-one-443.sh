#!/usr/bin/env bash
# 单台迁到 443 REALITY（nginx 让位 2096 + xray 增 443 入站 + iptables），可重复执行
# 用法: ssh <host> 'bash -s' -- <伪装域名> < scripts/migrate-one-443.sh
#   （直连 SSH 不通时用跳板: ssh -J <jump> <host> ...）
# 前置: 已按 SKILL 里「伪装域名五条硬指标」选好 SNI；ssh 通
# 之后: ①xem --cf-origin-port  ②发布节点（见 SKILL 坑 9b）③verify-443.sh 实打
# 🔴 迁完必须把 state.env 的 REALITY_VISION_PORT/CDN_PORT 改成现值，
#    否则下次菜单 9 会按旧端口重建 → 443 被静默丢掉。用 xem --check-port-drift 核对。
set -uo pipefail
SNI="${1:?需要 SNI，例如 www.example.org}"
S=""; command -v sudo >/dev/null && S="sudo -n"    # root 直登机型没有 sudo，必须自适应
XJ=/usr/local/etc/xray/config.json
NG=/etc/nginx/conf.d/xray-edge-manager.conf
TS=$(date +%Y%m%d%H%M%S)

echo "== 1) 备份"
$S cp "$XJ" "$XJ.bak.$TS" && echo "  xray .bak.$TS"
$S cp "$NG" "$NG.bak.$TS" && echo "  nginx .bak.$TS"

echo "== 2) nginx 让位 2096（按行正则，覆盖 ssl / ssl http2 / [::] / default_server 四种写法）"
$S python3 - "$NG" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read(); out = []; n = 0
for line in s.splitlines(True):
    if re.match(r'\s*listen\s', line) and re.search(r'(^|[:\s])443\b', line):
        new = re.sub(r'(?<=listen )(?:\[::\]:)?443\b', '2096', line, count=1)
        if '[::]' in line:
            new = re.sub(r'(?<=listen )2096', '[::]:2096', new, count=1)
        out.append(new); n += 1
    else:
        out.append(line)
open(p, 'w').write(''.join(out)); print('  改写 listen 行:', n)
PY
$S grep -cE 'listen[^;]*[^0-9]443' "$NG" | sed 's/^/  剩余 443 listen: /'   # 必须为 0
$S nginx -t 2>&1 | tail -1
$S systemctl reload nginx && echo "  nginx reloaded"

echo "== 3) iptables：443 放行任意来源，2096 用 ACCEPT（不要 XEM_CF_ORIGIN）"
$S iptables -D INPUT -p tcp -m tcp --dport 443 -j XEM_CF_ORIGIN 2>/dev/null
$S iptables -I INPUT 1 -p tcp -m tcp --dport 443 -j ACCEPT
$S iptables -D INPUT -p tcp -m tcp --dport 2096 -j XEM_CF_ORIGIN 2>/dev/null
$S iptables -I INPUT 1 -p tcp -m tcp --dport 2096 -j ACCEPT
$S iptables -S INPUT | grep -E 'dport (443|2096)' | head -2

echo "== 4) xray 增 443 入站（复制 3443 的 REALITY，保持 network=raw，复用同一 privateKey/shortIds）"
$S python3 - "$SNI" <<'PY'
import json, sys
sni = sys.argv[1]; p = '/usr/local/etc/xray/config.json'
d = json.load(open(p))
for i in d['inbounds']:
    if i.get('tag') == 'in-v4-reality-443':
        rs = i['streamSettings']['realitySettings']
        rs['dest'] = sni + ':443'; rs['target'] = sni + ':443'; rs['serverNames'] = [sni]
        json.dump(d, open(p, 'w'), ensure_ascii=False, indent=2)
        print('  已存在，改 SNI 为', sni); raise SystemExit(0)
src = [i for i in d['inbounds'] if i.get('tag') == 'in-v4-reality-vision'][0]
nb = json.loads(json.dumps(src)); nb['tag'] = 'in-v4-reality-443'; nb['port'] = 443
rs = nb['streamSettings']['realitySettings']
rs['dest'] = sni + ':443'; rs['target'] = sni + ':443'; rs['serverNames'] = [sni]
d['inbounds'].append(nb); json.dump(d, open(p, 'w'), ensure_ascii=False, indent=2)
print('  ADDED listen=%s net=%s' % (nb.get('listen'), nb['streamSettings']['network']))
PY
$S xray -test -config "$XJ" 2>&1 | tail -1
$S systemctl restart xray && sleep 2

echo "== 5) 落点核对"
ss -lntp | grep -E ':(443|2096|3443) ' | awk '{print "  "$4}'
echo "  xray=$($S systemctl is-active xray) nginx=$($S systemctl is-active nginx)"
echo "  下一步: ①xem --cf-origin-port 2096 ②发布节点(见 SKILL 坑 9b) ③verify-443.sh 实打"
echo "  ⚠️ 最后把 state.env 的 REALITY_VISION_PORT=443 / CDN_PORT=2096 写回，再跑 xem --check-port-drift"
