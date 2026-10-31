#!/bin/bash
# 订阅文件「节点命名层」—— 幂等；只改 base64 订阅里的 #节点名，不碰 xray 配置、不重启服务
#   1) 自动国家前缀：/etc/xray-sub-country.map  格式: <机房前缀> <国家码>
#   2) 任意命名覆盖：/etc/xray-sub-name-override.map  格式: <原节点名>=<想要的新名字>
#      （用 = 分隔，新名字里可以带空格/emoji；命中覆盖就不再自动加前缀）
# 用法: sub-country-prefix.sh [--dry] [--apply-only-override]
set -u
MAP=${MAP:-/etc/xray-sub-country.map}
OVR=${OVR:-/etc/xray-sub-name-override.map}
DRY=0; ONLY_OVR=0
for a in "$@"; do
  case "$a" in
    --dry) DRY=1 ;;
    --apply-only-override) ONLY_OVR=1 ;;
  esac
done
DIRS=${DIRS:-"/usr/local/etc/xray/www/sub"}
STAMP=$(date +%Y%m%d-%H%M%S)
total=0; changed=0

for d in $DIRS; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.bak.*|*.tmp) continue;; esac
    total=$((total+1))
    dec=$(mktemp); new=$(mktemp)
    base64 -d "$f" > "$dec" 2>/dev/null || { rm -f "$dec" "$new"; continue; }
    # 只处理真正的订阅文件：解码后首行必须是 <scheme>:// ，否则跳过（防止误伤同目录的非订阅文件）
    grep -qE '^[A-Za-z0-9]+://' "$dec" || { rm -f "$dec" "$new"; continue; }
    awk -v map="$MAP" -v ovr="$OVR" -v onlyovr="$ONLY_OVR" '
      BEGIN{
        if (map != "") while ((getline l < map) > 0) {
          if (l ~ /^[ \t]*#/ || l ~ /^[ \t]*$/) continue
          n=split(l,a,/[ \t]+/); if (n>=2) M[a[1]]=a[2]
        }
        if (ovr != "") while ((getline l < ovr) > 0) {
          if (l ~ /^[ \t]*#/ || l ~ /^[ \t]*$/) continue
          eq=index(l,"="); if (eq<2) continue
          o=substr(l,1,eq-1); t=substr(l,eq+1)
          gsub(/^[ \t]+|[ \t]+$/,"",o); gsub(/^[ \t]+|[ \t]+$/,"",t)
          if (o!="" && t!="") { O[o]=t; T[t]=1 }
        }
      }
      {
        i=index($0,"#")
        if (i>0) {
          head=substr($0,1,i); name=substr($0,i+1)
          if (name in T) { print head name; next }             # 已经改成目标名，幂等
          if (name in O) { name=O[name] }                      # 任意命名优先
          else if (onlyovr != 1) {
            n=split(name,p,"-"); cc=((n>=1) && (p[1] in M)) ? M[p[1]] : ""
            if (cc != "" && name !~ ("^" cc "-")) name = cc "-" name
          }
          print head name
        } else print
      }' "$dec" > "$new"
    if cmp -s "$dec" "$new"; then rm -f "$dec" "$new"; continue; fi
    changed=$((changed+1))
    if [ "$DRY" = 1 ]; then
      echo "[dry] $f"
      paste <(sed -n 's/.*#//p' "$dec") <(sed -n 's/.*#//p' "$new") | awk -F'\t' '$1!=$2{print "   "$1" -> "$2}' | head -8
    else
      [ -f "$f.bak.$STAMP" ] || cp -p "$f" "$f.bak.$STAMP"
      base64 -w0 < "$new" > "$f.tmp" && mv "$f.tmp" "$f"
      chown root:www-data "$f" 2>/dev/null; chmod 640 "$f"
      echo "[ok] $f  names=$(grep -c '#' "$new")"
    fi
    rm -f "$dec" "$new"
  done
done
echo "files=$total changed=$changed dry=$DRY"
