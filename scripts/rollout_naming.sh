#!/bin/bash
# 批量升级单台代理机到 xem v0.0.61 + 命名层 v2（国家前缀 + 任意命名 + 手工节点保留）
# 用法: bash rollout_naming.sh <ssh别名> <国家码>
# 只做：备份 → 装 xem/脚本/映射/覆盖模板 → 写 NODE_COUNTRY → 菜单 14->1 重生成 → 回读校验
set -u
HOST="${1:?用法: rollout_naming.sh <host> <CC>}"
CC="${2:?缺国家码}"
LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"
TS=$(date +%Y%m%d-%H%M%S)
LOG="$LOCAL_DIR/rollout-$HOST-$TS.txt"

{
  echo "=== $HOST CC=$CC $(date +%T)"
  ssh -o ConnectTimeout=12 -o BatchMode=yes "$HOST" 'bash -s' <<'EOS' 2>&1
set -u
TS=$(date +%Y%m%d-%H%M%S)
SU=""; [ "$(id -u)" != "0" ] && SU="sudo"
# 0) 记录订阅文件名与内容哈希（证明 URL 不变）
echo "--- 升级前订阅文件 ---"
for f in /usr/local/etc/xray/www/sub/*; do
  case "$f" in *.bak.*) continue;; esac
  [ -f "$f" ] || continue
  echo "$(basename "$f") lines=$($SU base64 -d "$f" 2>/dev/null | grep -c '#') sha=$(sha256sum "$f" | cut -c1-12)"
done
$SU cp -a /usr/local/bin/xem "/root/xem.bak.$TS"
$SU mkdir -p "/root/backup-sub-$TS"
$SU cp -a /usr/local/etc/xray/www/sub/. "/root/backup-sub-$TS/" 2>/dev/null
echo "--- 备份完成 /root/backup-sub-$TS ---"
EOS
  # 上传三个文件
  # xem.sh 路径：优先仓库 clone，其次本地副本（用 XEM_SRC 覆盖）
  XEM_SRC="${XEM_SRC:-$HOME/xemrepo/xem.sh}"
  [ -f "$XEM_SRC" ] || { echo "找不到 xem.sh: $XEM_SRC"; exit 1; }
  ssh -o ConnectTimeout=12 -o BatchMode=yes "$HOST" 'cat > /tmp/xem.new' < "$XEM_SRC"
  ssh -o ConnectTimeout=12 -o BatchMode=yes "$HOST" 'cat > /tmp/scp.sh' < "$LOCAL_DIR/sub-country-prefix.sh"
  ssh -o ConnectTimeout=12 -o BatchMode=yes "$HOST" 'cat > /tmp/scp.map' < "$LOCAL_DIR/room_country.map"
  ssh -o ConnectTimeout=30 -o BatchMode=yes "$HOST" bash -s -- "$CC" <<'EOS' 2>&1
set -u
CC="$1"
SU=""; [ "$(id -u)" != "0" ] && SU="sudo"
$SU install -m 755 /tmp/xem.new /usr/local/bin/xem
$SU install -m 755 /tmp/scp.sh /usr/local/bin/sub-country-prefix.sh
$SU install -m 644 /tmp/scp.map /etc/xray-sub-country.map
[ -f /etc/xray-sub-name-override.map ] || printf '# 任意命名：原节点名=想要的新名字（可带空格/emoji）\n# 例: dmitus-CF-XHTTP=🇺🇸 美西-CF 入口\n' | $SU tee /etc/xray-sub-name-override.map >/dev/null
$SU chmod 644 /etc/xray-sub-name-override.map
bash -n /usr/local/bin/xem && echo XEM_SYNTAX_OK
bash -n /usr/local/bin/sub-country-prefix.sh && echo SCRIPT_SYNTAX_OK
$SU grep -m1 '^XEM_VERSION=' /usr/local/bin/xem
ST=/root/.xray-edge-manager/state.env
$SU sed -i '/^NODE_COUNTRY=/d' "$ST"
echo "NODE_COUNTRY=$CC" | $SU tee -a "$ST" >/dev/null
$SU grep -E '^(NODE_NAME|NODE_COUNTRY)=' "$ST"
echo "--- 触发重生成（菜单 14 -> 1）---"
printf '14\n1\n0\n0\n' | $SU /usr/local/bin/xem 2>&1 | grep -aE '保留手工节点|订阅|ERR|WARN' | tail -6
echo "--- 升级后订阅文件 ---"
for f in /usr/local/etc/xray/www/sub/*; do
  case "$f" in *.bak.*) continue;; esac
  [ -f "$f" ] || continue
  echo "$(basename "$f") lines=$($SU base64 -d "$f" 2>/dev/null | grep -c '#') sha=$(sha256sum "$f" | cut -c1-12)"
  $SU base64 -d "$f" 2>/dev/null | sed -n 's/.*#//p' | head -3
done
EOS
} 2>&1 | tee "$LOG"
echo "日志: $LOG"
