#!/usr/bin/env bash
# 把一批 vless 链接发布进 xem 的 base64 订阅文件（幂等）
#
# 用法（在每台机上跑同一份链接清单，脚本自己判断哪条跟这台机有关）：
#   ssh <host> 'sudo -n tee /tmp/all_links.txt >/dev/null' < links.txt
#   ssh <host> 'bash -s' < scripts/publish-links-to-xem-sub.sh
#
# links.txt = 每行一条完整 vless 链接（自带 #节点名）。
# 行为：对 /usr/local/etc/xray/www/sub/* 每个文件——
#   * 文件内容不含该链接的 hosttag  → 跳过（这条不是这个文件的机器）
#   * 已含 `vless://<uuid>@<host>:<port>?` → 跳过（幂等）
#   * 否则追加一行，并按原格式重新 base64 编码，属主权限复原 640
# 因此同一份 links.txt 在单机文件上只加本机那条，在聚合机的「合订本」上会把整组都加进去。
# ⚠️ 这些文件由 xem 生成，下次菜单 9/16 会被重建 —— 长期做法是让端口本身进 state.env。
set -uo pipefail
S=""; command -v sudo >/dev/null && S="sudo -n"
$S python3 - <<'PY'
import glob, base64, os, re, sys

LINKS_FILE = os.environ.get('XEM_LINKS_FILE', '/tmp/all_links.txt')
links = [l.strip() for l in open(LINKS_FILE) if l.strip().startswith('vless://')]
if not links:
    sys.exit('ERR: %s 里没有 vless 链接' % LINKS_FILE)

res = []
for f in sorted(glob.glob('/usr/local/etc/xray/www/sub/*')):
    raw = open(f, 'rb').read()
    try:
        txt = base64.b64decode(raw).decode('utf-8', 'ignore'); b64 = True
    except Exception:
        txt = raw.decode('utf-8', 'ignore'); b64 = False
    before = txt.count('vless://')
    added = 0
    for link in links:
        m_host = re.search(r'@([^:]+):\d+', link)
        m_uuid = re.search(r'vless://([^@]+)@', link)
        m_port = re.search(r'@[^:]+:(\d+)', link)
        if not (m_host and m_uuid and m_port):
            continue
        host, uuid, port = m_host.group(1), m_uuid.group(1), m_port.group(1)
        if host not in txt:                       # 这份订阅不涉及这台机
            continue
        # 🔴 幂等判据必须带 uuid：hysteria2 节点也占 host:443，只判 '@host:443?' 会
        #    把 hy2 当成「已发布」，于是全队静默跳过、一条也不加。
        if f'vless://{uuid}@{host}:{port}?' in txt:
            continue
        if not txt.endswith('\n'):
            txt += '\n'
        txt += link + '\n'
        added += 1
    if added:
        out = base64.b64encode(txt.encode()).decode() if b64 else txt
        with open(f, 'w') as fh:
            fh.write(out)
        os.chmod(f, 0o640)
        res.append('%s +%d (%d -> %d)' % (os.path.basename(f)[:8], added, before, txt.count('vless://')))
print('  ' + ('; '.join(res) if res else '无改动（没有命中本机文件，或全部已存在）'))
PY
