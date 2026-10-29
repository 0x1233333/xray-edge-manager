#!/usr/bin/env bash
# verify-443.sh <ssh别名> <SNI> [端口] [连接地址]
# 从本机(家宽)实打某台机的 REALITY：读服务端入站参数 → 生成临时客户端 → 三发 curl → 打印出口 IP
# 判据：3/3 200 且出口 IP == 该机自己的公网出口 IP（🔴 别拿域名 A 记录当基准，NAT 机型会不同）
#
# 可选环境变量：
#   XEM_JUMP=<跳板别名>     直连 SSH 不通时自动 -J（不设则先试直连）
#   XEM_BASE_DOMAIN=<域名>  第 4 参数缺省时用 v4.<别名>.<域名> 拼连接地址
set -uo pipefail
H="${1:?用法: verify-443.sh <ssh别名> <SNI> [端口=443] [连接地址]}"
SNI="${2:?需要伪装域名 SNI}"
PORT_OUT="${3:-443}"
ADDR="${4:-}"
if [ -z "$ADDR" ]; then
  [ -n "${XEM_BASE_DOMAIN:-}" ] || { echo "✗ 需要第 4 参数连接地址，或设 XEM_BASE_DOMAIN=<域名>"; exit 2; }
  ADDR="v4.$H.$XEM_BASE_DOMAIN"
fi
JUMP="${XEM_JUMP:-}"

XRAY="$(command -v xray || true)"
[ -z "$XRAY" ] && XRAY="$(ls -1 /opt/homebrew/Cellar/xray/*/libexec/xray 2>/dev/null | tail -1)"
[ -n "$XRAY" ] || { echo "✗ 找不到 xray 二进制（brew install xray 或加 PATH）"; exit 2; }

SSHOPTS="-o BatchMode=yes -o ConnectTimeout=12"
ssh $SSHOPTS "$H" true 2>/dev/null || {
  [ -n "$JUMP" ] || { echo "✗ 直连 SSH 不通，且未设 XEM_JUMP=<跳板别名>"; exit 3; }
  SSHOPTS="$SSHOPTS -J $JUMP"
}

WORK="$(mktemp -d -t v443.XXXXXX)"
SPORT=$(( 7900 + RANDOM % 90 ))
PID=""
cleanup(){ [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# 1) 读服务端 443 入站的 uuid / shortId / 公钥（x25519 输出第二段才是 PublicKey）
CRED=$(ssh $SSHOPTS "$H" 'S=$(command -v sudo >/dev/null && echo "sudo -n"); $S python3 - <<PY
import json,re,subprocess
p="/usr/local/etc/xray/config.json"
d=json.load(open(p))
ib=None
for i in d["inbounds"]:
    ss=i.get("streamSettings") or {}
    if str(i.get("port"))=="443" and ss.get("network")!="hysteria":
        ib=i; break
if ib is None:
    for i in d["inbounds"]:
        if i.get("tag")=="in-v4-reality-vision":
            ib=i; break
ss=ib["streamSettings"]; rs=ss["realitySettings"]
out=subprocess.run(["xray","x25519","-i",rs["privateKey"]],capture_output=True,text=True).stdout
keys=re.findall(r"[A-Za-z0-9_-]{43}",out)
print(json.dumps({"uuid":ib["settings"]["clients"][0]["id"],"sid":rs["shortIds"][0],"pub":keys[1],"net":ss["network"]}))
PY' 2>/dev/null)
[ -n "$CRED" ] || { echo "✗ 取不到服务端入站参数（SSH 不通，或配置不在 /usr/local/etc/xray/）"; exit 3; }

# 2) 生成临时客户端
export ADDR PORT_OUT SPORT WORK CRED SNI
python3 - <<'PY'
import json,os
c=json.loads(os.environ["CRED"])
cfg={"log":{"loglevel":"warning"},
 "inbounds":[{"tag":"s","port":int(os.environ["SPORT"]),"listen":"127.0.0.1","protocol":"socks","settings":{"udp":False}}],
 "outbounds":[{"tag":"p","protocol":"vless","settings":{"vnext":[{"address":os.environ["ADDR"],"port":int(os.environ["PORT_OUT"]),
    "users":[{"id":c["uuid"],"encryption":"none","flow":"xtls-rprx-vision"}]}]},
   "streamSettings":{"network":c["net"],"security":"reality","realitySettings":{
     "serverName":os.environ["SNI"],"fingerprint":"chrome","publicKey":c["pub"],"shortId":c["sid"],"spiderX":"/"}}}]}
json.dump(cfg,open(os.path.join(os.environ["WORK"],"c.json"),"w"),ensure_ascii=False,indent=2)
PY

echo "  目标=$ADDR:$PORT_OUT  SNI=$SNI  临时 socks=$SPORT"
nohup "$XRAY" run -config "$WORK/c.json" > "$WORK/log" 2>&1 </dev/null &
PID=$!
disown 2>/dev/null || true
sleep 3

ok=0
for i in 1 2 3; do
  out=$(curl -s -m 15 -x "socks5h://127.0.0.1:$SPORT" -w ' code=%{http_code} t=%{time_total}' https://api.ipify.org 2>&1)
  echo "  run$i: $out"
  case "$out" in *code=200*) ok=$((ok+1));; esac
done
echo "  → 成功 $ok/3（出口 IP 必须等于该机自己的公网出口 IP）"
[ "$ok" -eq 0 ] && { echo "  --- 内核日志 ---"; tail -5 "$WORK/log"; }
[ "$ok" -eq 3 ] || exit 1
