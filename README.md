# Xray Edge Manager

`xray-edge-manager` 是一个面向个人 VPS 的 Xray-core 单文件部署与管理脚本。它把 Xray-core、Cloudflare DNS、DNS-01 泛域名证书、Nginx 伪装站、VLESS + XHTTP、REALITY、Hysteria2、BestCF 优选入口、WARP 出站和 base64 订阅管理整合到一个交互式菜单里。

当前版本：`v0.0.36-rc22-production-ready`

> 建议先在全新 Debian / Ubuntu VPS 上测试。脚本会修改 Xray、Nginx、Certbot、Cloudflare DNS、防火墙规则、systemd timer 和订阅文件。不要直接在承载复杂网站业务的生产服务器上无脑运行。

---

## 重要提醒

这是一个个人节点部署脚本，不是机场面板，也不是多用户管理系统。

脚本的目标是：

- 用尽量少的外部组件部署 Xray-core；
- 支持 IPv4 / IPv6 分栈生成节点；
- 支持较新的 Xray 组合协议；
- 自动处理 Cloudflare DNS、证书、Nginx、订阅文件；
- 在纯 IPv6 机器上可选使用 WARP outbound 作为 IPv4 出口；
- 尽量减少误删 DNS、状态污染、坏配置覆盖正式配置等问题。

脚本不是：

- Web 面板；
- Docker 编排项目；
- 多用户机场系统；
- 通用 Linux 发行版安装器；
- 适合混跑很多网站业务的 Nginx 生产服务器管理器。

---

## 支持环境

推荐环境：

```text
Debian 12 / Debian 13
Ubuntu 22.04 / Ubuntu 24.04
root 用户
systemd
apt 软件源
Nginx
Cloudflare 托管域名
```

不推荐环境：

```text
Alpine
CentOS / Rocky / Alma
非 systemd 系统
已经有复杂 Nginx 站点配置的服务器
无法放行端口的 NAT 小鸡
```

脚本会自动安装或使用这些基础组件：

```text
curl wget jq openssl nginx certbot python3-certbot-dns-cloudflare
iproute2 iptables nftables conntrack logrotate cron socat unzip tar
```

---

## 一键运行

主分支脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/refs/heads/main/xem.sh)
```

如果使用 beta 文件，例如：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/refs/heads/main/beta/xem-v0.0.36-rc22-fixed.sh)
```

如果 `curl` 不可用：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/0x1233333/xray-edge-manager/refs/heads/main/xem.sh)
```

更推荐先下载再运行，方便排错：

```bash
curl -fsSL -o /root/xem.sh https://raw.githubusercontent.com/0x1233333/xray-edge-manager/refs/heads/main/xem.sh
bash -n /root/xem.sh
bash /root/xem.sh
```

如果你从 beta 路径下载：

```bash
curl -fsSL -o /root/xem.sh https://raw.githubusercontent.com/0x1233333/xray-edge-manager/refs/heads/main/beta/xem-v0.0.36-rc22-fixed.sh
bash -n /root/xem.sh
bash /root/xem.sh
```

---

## 安装成本地命令

```bash
curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/refs/heads/main/xem.sh -o /usr/local/bin/xem
chmod +x /usr/local/bin/xem
xem
```

以后直接输入：

```bash
xem
```

更新本地命令：

```bash
curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/refs/heads/main/xem.sh -o /usr/local/bin/xem
chmod +x /usr/local/bin/xem
```

如果你使用 `bash <(curl ...)` 方式首次运行，脚本在配置定时任务、BestCF、HY2 跳跃等功能时可能会尝试把自己固化到 `/usr/local/bin/xem`。测试分支或 fork 可以用环境变量覆盖脚本来源：

```bash
export XEM_SCRIPT_RAW_URL="https://raw.githubusercontent.com/你的仓库/你的分支/xem.sh"
```

生产环境如需校验脚本本身，可设置：

```bash
export XEM_SELF_SHA256="64位sha256"
```

---

## 适合谁用

适合：

- 自己有 VPS，想部署个人 Xray 节点；
- 想同时生成 IPv4 / IPv6 节点；
- 想同时保留直连、CDN、HY2、REALITY Vision 备用节点；
- 想用 Cloudflare 自动管理 DNS 和 DNS-01 证书；
- 想要一个稳定的 base64 订阅链接；
- 想在纯 IPv6 VPS 上通过 WARP outbound 获得 IPv4 出口。

不适合：

- 多用户机场；
- 图形化 Web 面板；
- 不想让脚本改动 Nginx / Xray / 防火墙的机器；
- 已经承载多个网站的生产服务器；
- 对 Cloudflare、DNS、证书、端口放行完全不了解的环境。

---

## 核心设计

### 1. 单文件脚本

脚本本体是一个 Bash 文件，不依赖 Docker，也不部署 sing-box。核心运行组件是：

```text
Xray-core
Nginx
Certbot
Cloudflare DNS API
systemd
```

### 2. 分栈协议

IPv4 和 IPv6 可以独立选择协议组合。

例如：

```text
IPv4 = 123
IPv6 = 13
```

表示：

```text
IPv4 生成 XHTTP+REALITY、XHTTP+TLS+CDN、Hysteria2
IPv6 生成 XHTTP+REALITY、Hysteria2
```

### 3. NAT-aware

脚本区分：

```text
PUBLIC IP = 写入 DNS 的公网 IP
BIND IP   = Xray 在本机监听使用的 IP
```

这对 NAT VPS、内网网卡、公网映射环境很重要。

### 4. 订阅文件不从 /root 直接发布

脚本状态保存在：

```text
/root/.xray-edge-manager
```

但公开订阅文件会复制到：

```text
/var/www/xray-edge-manager/sub
```

Nginx 只读取 `/var/www` 下的文件，不直接读取 `/root`。

### 5. 状态文件不直接 source

脚本不会直接 `source state.env`，而是使用白名单 key 和安全字符检查读取状态，降低状态文件污染导致命令注入的风险。

### 6. 配置写入前校验

Xray 配置生成后会先做：

```text
jq JSON 校验
自定义配置审计
xray run -test
```

通过后才替换正式配置。

Nginx 配置写入后会执行：

```bash
nginx -t
```

失败会回滚备份配置。

---

## 域名规则

脚本要求输入三段式或以上的母域名，例如：

```text
node.example.com
jp1.proxy.example.com
us1.edge.example.com
```

不建议直接使用二段根域名：

```text
example.com
```

假设输入：

```text
node.example.com
```

脚本的固定域名角色是：

```text
node.example.com       BASE：订阅链接 / 伪装站 / CDN 中转入口
v4.node.example.com    IPv4 直连节点，只使用 A 记录，灰云
v6.node.example.com    IPv6 直连节点，只使用 AAAA 记录，灰云
```

Cloudflare DNS 管理边界：

```text
只管理 BASE / v4 / v6 三个名称
只管理 A / AAAA 记录
不管理 CNAME / TXT / CAA / MX / NS / HTTPS / SVCB
不管理其它子域名
```

这意味着：

- `BASE_DOMAIN` 负责订阅、伪装站和 CDN 入口；
- `v4.BASE_DOMAIN` 只负责 IPv4 直连节点；
- `v6.BASE_DOMAIN` 只负责 IPv6 直连节点；
- 脚本不会扩大 DNS 删除范围。

---

## Cloudflare API Token

脚本需要 Cloudflare API Token 来自动创建 DNS 记录和申请 DNS-01 泛域名证书。

推荐权限：

```text
Zone:Read
DNS:Edit
```

作用范围建议限制到目标 Zone。

不要使用 Global API Key。脚本会对疑似 Global API Key 的输入做风险提示。

教程：

```text
https://github.com/0x1233333/xray-edge-manager/blob/main/examples/cloudflare-api-token.md
```

---

## 首次部署流程

运行脚本后选择：

```text
1. 首次部署向导，推荐
```

大致流程：

```text
1. 安装基础依赖
2. 安装 / 升级 Xray-core
3. 更新 geoip.dat / geosite.dat
4. 输入或复用母域名
5. 配置 Cloudflare API Token
6. 输入节点名称
7. 检测 IPv4 / IPv6 / ASN
8. 分别选择 IPv4 和 IPv6 协议组合
9. 部署前检查公网 IP 与协议栈是否匹配
10. 创建 Cloudflare DNS 记录
11. 申请或复用泛域名证书
12. 选择 REALITY 伪装目标
13. 生成 Xray 配置
14. 配置 Nginx 伪装站、订阅路径、CDN 回源
15. 可选配置 Hysteria2 UDP 端口跳跃
16. 处理本机防火墙端口
17. 重启 Xray / Nginx
18. 生成本机 base64 订阅
19. 执行部署后生产自检
20. 输出部署摘要
```

部署完成后会输出订阅链接，例如：

```text
https://node.example.com/sub/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

---

## 菜单说明

```text
1. 首次部署向导，推荐
2. 安装/升级基础依赖
3. 安装/升级 Xray-core
4. 更新 geoip.dat / geosite.dat
5. 网络优化 / BBR 状态与稳定优化
6. Cloudflare 域名 / DNS / 小云朵管理
7. 证书申请 / 续签 / 自动部署
8. 查询 IPv4 / IPv6 / ASN 辅助报告
9. 重新选择 IPv4/IPv6 协议，并刷新 DNS、Xray、Nginx、订阅
10. 只重配 Nginx / 伪装站 / 订阅服务 / CDN 回源
11. BestCF 优选域名管理，默认关闭
12. 配置 Hysteria2 端口跳跃
13. 本机防火墙端口处理，并可限制源站只允许 Cloudflare 回源
14. 订阅管理
15. 查看服务状态
16. 查看分享链接 / 订阅链接
17. 重启服务
18. 部署摘要
19. 安装状态
20. 卸载 / 清理
21. WARP 出站管理 / 自动生成 warp-outbound.json
22. 部署后生产自检
0. 退出
```

---

## Xray-core 安装方式

脚本优先使用：

```text
官方 XTLS/Xray-core Release ZIP + 官方 .dgst SHA256 校验
```

这比直接执行远程安装脚本更稳。

备用方式是官方 Xray-install 脚本，但默认禁用。确实要用时需要显式开启：

```bash
export XEM_ALLOW_XRAY_SCRIPT_FALLBACK=1
```

如果需要对远程安装脚本本身做强校验：

```bash
export XEM_XRAY_INSTALL_SHA256="64位sha256"
```

默认情况下，脚本允许安装 Xray-core 官方 prerelease，以跟进较新的 Xray 协议能力。如果你只想使用 stable release，可以在运行前设置：

```bash
export XEM_XRAY_ALLOW_PRERELEASE=0
```

---

## 协议选择说明

IPv4 和 IPv6 可以分别选择协议组合。

```text
0 = 不生成该 IP 栈节点
1 = VLESS + XHTTP + REALITY，直连
2 = VLESS + XHTTP + TLS + CDN，经 Nginx / Cloudflare
3 = Xray Hysteria2，UDP 高速备用
4 = VLESS + REALITY + Vision，直连备用
5 = VLESS + XHTTP + TLS + CDN 入口扩展 / BestCF 入口
```

常用选择：

```text
123      基础组合：直连 + CDN + HY2
1234     增加 REALITY Vision 备用
12345    增加 CDN 扩展 / BestCF 入口
13       只要直连 XHTTP+REALITY 和 HY2
0        当前 IP 栈不生成节点
```

简单理解：

| 编号 | 协议 | 入口 | 用途 |
| --- | --- | --- | --- |
| 1 | VLESS + XHTTP + REALITY | v4/v6 灰云直连 | 主力直连 |
| 2 | VLESS + XHTTP + TLS + CDN | BASE 域名橙云 | CDN 隐藏源站 |
| 3 | Xray Hysteria2 | UDP 直连 | UDP 高速备用 |
| 4 | VLESS + REALITY + Vision | v4/v6 灰云直连 | 传统 REALITY 备用 |
| 5 | XHTTP + TLS + CDN 扩展 | BestCF / 优选入口 | CDN 入口增强 |

---

## 出站策略与 WARP

脚本支持为 Xray 配置不同出站策略。

常见模式：

```text
auto      自动判断；有 IPv4 时优先 force-v4，纯 IPv6 时倾向 warp-v4
force-v4  尽量强制走 IPv4 出口
warp-v4   使用 WARP outbound 提供 IPv4 出口
stack     按原始 IP 栈出站
```

WARP 功能用途：

- 适合纯 IPv6 VPS 需要访问 IPv4 网站；
- 不修改系统默认路由；
- 只作为 Xray 的 outbound；
- 生成的 outbound tag 固定为 `out-warp`；
- 会设置 `domainStrategy=ForceIPv4` 和 `noKernelTun=true`。

菜单入口：

```text
21. WARP 出站管理 / 自动生成 warp-outbound.json
```

默认生成位置：

```text
/root/.xray-edge-manager/warp-outbound.json
```

脚本可使用第三方 `warp-reg` 自动生成 WireGuard 参数，也兼容手动放入其它工具生成的 Xray WireGuard outbound JSON。

生产环境建议固定 `warp-reg` 二进制 SHA256：

```bash
export XEM_WARP_REG_SHA256="64位sha256"
```

如果未设置 SHA256，交互环境会要求你明确确认；非交互环境默认拒绝使用未 pin 的第三方二进制。临时测试可以使用：

```bash
export XEM_TRUST_WARP_REG=1
```

生产环境不建议长期使用 `XEM_TRUST_WARP_REG=1`。

---

## BestCF 说明

BestCF 默认关闭。

如果选择协议 `5`，脚本会使用和 CDN 入站相同的 XHTTP + TLS + CDN 配置，额外生成优选入口节点。

菜单入口：

```text
11. BestCF 优选域名管理，默认关闭
```

BestCF 逻辑：

```text
server/address = BestCF 优选 IP 或优选域名
SNI/servername = 你的 BASE_DOMAIN
Host           = 你的 BASE_DOMAIN
```

BestCF 适合作为增强入口，不建议把它当作唯一主链路。GitHub 或 BestCF 资产拉取失败时，主部署不应该依赖它成功。

---

## Hysteria2 端口跳跃

菜单入口：

```text
12. 配置 Hysteria2 端口跳跃
```

默认跳跃范围：

```text
UDP 20000-20100 -> UDP 443
```

常见用途：

- 降低单一 UDP 443 被干扰时的影响；
- 给客户端提供多个 UDP 入口端口；
- 实际仍转发到本机 HY2 监听端口。

注意：

- 云厂商安全组需要放行跳跃 UDP 端口范围；
- 本机防火墙也要允许；
- 某些 VPS 商家、运营商或 NAT 环境可能限制 UDP；
- HY2 是否稳定取决于线路和 UDP 可达性。

---

## 本机防火墙与 Cloudflare 源站限制

菜单入口：

```text
13. 本机防火墙端口处理，并可限制源站只允许 Cloudflare 回源
```

脚本可以处理常见端口放行，也可以限制 Nginx / CDN 回源入口只允许 Cloudflare IP。

重要边界：

```text
Cloudflare 源站限制主要保护 Nginx / CDN / 订阅 / 伪装站端口。
它不会保护 v4/v6 直连协议端口。
```

原因是直连协议本来就需要客户端直接访问：

```text
v4.BASE_DOMAIN:2443
v6.BASE_DOMAIN:2443
v4.BASE_DOMAIN:3443
v6.BASE_DOMAIN:3443
UDP 443 / UDP 跳跃端口
```

如果你希望隐藏源站，不要只依赖脚本防火墙。直连协议本身就会暴露源站 IP。

---

## 常见端口

请在 VPS 云厂商安全组里手动放行你实际使用的端口。

常见默认端口：

```text
TCP 80              Certbot HTTP/Nginx 可用性/跳转
TCP 443             Nginx / CDN / 伪装站 / 订阅
TCP 2443            VLESS + XHTTP + REALITY
TCP 3443            VLESS + REALITY + Vision
UDP 443             Xray Hysteria2
UDP 20000-20100     Hysteria2 端口跳跃
```

Cloudflare CDN HTTPS 代理端口只能使用：

```text
443
2053
2083
2087
2096
8443
```

非 CDN 直连协议端口可以自定义。

---

## 证书说明

脚本使用 Certbot + Cloudflare DNS 插件申请 DNS-01 泛域名证书。

证书覆盖：

```text
BASE_DOMAIN
*.BASE_DOMAIN
```

证书目录：

```text
/etc/letsencrypt/live/<你的母域名>/
```

脚本会同步一份 Xray 可读证书副本到：

```text
/usr/local/etc/xray/certs/<你的母域名>/
```

这样 Xray 可以在非 root 用户下读取证书。

如果部署时检测到已有证书，可以选择复用，不必每次重新申请。

查看证书：

```bash
certbot certificates
```

如果看到类似下面的 warning：

```text
PendingDeprecationWarning: cloudflare 2.20.*
```

但证书申请成功，一般可以忽略。真正需要处理的是证书申请失败、Cloudflare 鉴权失败、Zone ID 查询失败、DNS-01 验证失败等 error。

---

## 订阅管理

菜单入口：

```text
14. 订阅管理
```

支持：

```text
1. 重新生成本机 b64 订阅
2. 查看分享链接 / 订阅链接
3. 设置节点名称
4. 添加远程 b64 订阅
5. 查看远程订阅列表
6. 删除远程订阅
7. 清空远程订阅
8. 拉取并生成合并订阅
```

本地状态目录：

```text
/root/.xray-edge-manager/subscription/local.raw
/root/.xray-edge-manager/subscription/local.b64
/root/.xray-edge-manager/subscription/merged.raw
/root/.xray-edge-manager/subscription/merged.b64
/root/.xray-edge-manager/subscription/mihomo-reference.yaml
```

Web 发布目录：

```text
/var/www/xray-edge-manager/sub/
```

订阅 URL 示例：

```text
https://node.example.com/sub/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

合并订阅 URL 示例：

```text
https://node.example.com/sub/merged-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

远程订阅聚合限制：

- 只接受 HTTPS URL；
- 有最大下载大小限制；
- 会做基础 SSRF 风险检查；
- 主要面向 base64 订阅；
- 不建议聚合来源不可信的订阅。

---

## 节点名称

首次部署时会询问节点名称，例如：

```text
jp1
hkg2
oracle-tokyo
```

生成节点名称类似：

```text
hkg2-v4-XHTTP-REALITY
hkg2-v6-XHTTP-REALITY
hkg2-CDN-XHTTP-Origin
hkg2-CFDomain_1
```

后续可以在订阅管理里修改：

```text
14. 订阅管理
3. 设置节点名称
```

修改后重新生成订阅即可生效。

---

## 部署后检查

菜单入口：

```text
22. 部署后生产自检
```

它会检查：

```text
Xray 配置是否存在
Xray 配置是否通过 xray run -test
Xray 服务状态
Nginx 配置状态
订阅文件是否发布到 Web 目录
WARP outbound 是否存在并通过基础校验
```

也可以手动检查：

```bash
systemctl status xray --no-pager -l
systemctl status nginx --no-pager -l
nginx -t
xray run -test -config /usr/local/etc/xray/config.json
ss -tulpen | grep -E ':(80|443|2443|3443)\b'
ss -uapn | grep -E ':(443|20000|20100)\b'
```

测试订阅：

```bash
curl -I https://node.example.com/sub/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

正常应返回：

```text
HTTP/2 200
```

或：

```text
HTTP/1.1 200 OK
```

---

## 重新选择协议

菜单入口：

```text
9. 重新选择 IPv4/IPv6 协议，并刷新 DNS、Xray、Nginx、订阅
```

适合这些场景：

- 原来只部署 IPv4，现在想加 IPv6；
- 原来启用了 HY2，现在想关闭；
- 想从 `123` 改成 `1234`；
- VPS 新增或丢失 IPv6；
- 想重新刷新 DNS、Xray、Nginx、订阅。

脚本会重新检测 IP，并在协议栈与公网 IP 不匹配时拒绝继续，避免生成假成功配置。

---

## 卸载 / 清理

菜单入口：

```text
20. 卸载 / 清理
```

支持：

```text
1. 完整卸载本脚本环境
2. 停止并禁用 Xray
3. 删除 Hysteria2 端口跳跃规则
4. 清理脚本状态目录
5. 删除 Cloudflare DNS 记录
```

重要提醒：

```text
完整卸载适合专用节点机。
如果本机还有其它 Xray / Nginx / Certbot / 网站业务，不建议使用完整卸载。
```

Cloudflare DNS 默认不会无提示删除。删除范围仍限制在：

```text
BASE_DOMAIN
v4.BASE_DOMAIN
v6.BASE_DOMAIN
```

且仅限：

```text
A
AAAA
```

不会删除其它 DNS 类型。

---

## 目录说明

脚本状态目录：

```text
/root/.xray-edge-manager
```

主要状态文件：

```text
/root/.xray-edge-manager/state.env
/root/.xray-edge-manager/cloudflare.env
/root/.xray-edge-manager/cloudflare.ini
```

订阅目录：

```text
/root/.xray-edge-manager/subscription
```

Web 发布目录：

```text
/var/www/xray-edge-manager
```

Xray 配置：

```text
/usr/local/etc/xray/config.json
```

Xray 证书副本：

```text
/usr/local/etc/xray/certs/<你的母域名>/
```

Nginx 配置：

```text
/etc/nginx/conf.d/xray-edge-manager.conf
```

sysctl 优化配置：

```text
/etc/sysctl.d/99-xray-edge-manager.conf
```

调试与备份目录：

```text
/root/.xray-edge-manager/debug
/root/.xray-edge-manager/backups
```

WARP outbound 默认文件：

```text
/root/.xray-edge-manager/warp-outbound.json
```

---

## 常见排错

### 1. 脚本运行后很快退出

先下载到本地检查语法：

```bash
curl -fsSL -o /root/xem.sh https://raw.githubusercontent.com/0x1233333/xray-edge-manager/refs/heads/main/xem.sh
wc -l /root/xem.sh
head -n 5 /root/xem.sh
bash -n /root/xem.sh
bash /root/xem.sh
```

如果 `bash -n` 报错，通常是文件没有完整下载、复制粘贴损坏、CRLF 换行问题，或 GitHub 上的脚本本身有语法错误。

### 2. Xray 安装阶段获取 Release 后直接退出

如果看到类似：

```text
[INFO] 从 XTLS/Xray-core 官方 Release 获取资产列表。
[WARN] Xray-core 安装允许官方 prerelease...
```

然后直接退回 shell，说明你可能使用了旧版 rc22 文件。请更新到已经修复 silent exit 的版本。

### 3. 订阅显示 Welcome / It works

通常是 Nginx 默认站点或旧站点配置冲突。

检查：

```bash
grep -Rni "server_name" /etc/nginx/conf.d/ /etc/nginx/sites-enabled/ 2>/dev/null
nginx -t
systemctl reload nginx
```

### 4. 订阅 403 / 404

检查订阅文件是否发布：

```bash
ls -lah /var/www/xray-edge-manager/sub/
```

重新生成订阅：

```text
14. 订阅管理
1. 重新生成本机 b64 订阅
```

### 5. 节点导入了但不能连

Windows PowerShell：

```powershell
Test-NetConnection v4.node.example.com -Port 2443
Test-NetConnection node.example.com -Port 443
```

Linux / macOS：

```bash
nc -vz v4.node.example.com 2443
nc -vz node.example.com 443
```

检查 DNS：

```bash
dig +short node.example.com A
dig +short node.example.com AAAA
dig +short v4.node.example.com A
dig +short v6.node.example.com AAAA
```

### 6. HY2 不通

检查 UDP 包是否到达：

```bash
tcpdump -ni any 'udp port 443 or portrange 20000-20100'
```

如果没有包，多半是：

```text
云厂商安全组没放行 UDP
本机防火墙没放行 UDP
运营商阻断 UDP
客户端没有使用正确端口
```

### 7. Certbot Cloudflare warning

如果出现：

```text
PendingDeprecationWarning: cloudflare 2.20.*
```

但证书成功签发，一般可以忽略。这是 Python Cloudflare 库版本提示，不是证书失败。

真正需要处理的是：

```text
Cloudflare API 鉴权失败
Zone ID 查询失败
DNS-01 验证失败
证书未生成
```

检查证书：

```bash
certbot certificates
```

### 8. Cloudflare DNS 没生效

检查：

```bash
dig +short node.example.com A
dig +short node.example.com AAAA
dig +short v4.node.example.com A
dig +short v6.node.example.com AAAA
```

确认 Cloudflare Token 权限：

```text
Zone:Read
DNS:Edit
```

确认 Zone Name 输入的是根 Zone，例如：

```text
example.com
```

不是：

```text
node.example.com
```

### 9. WARP outbound 校验失败

检查文件：

```bash
ls -lah /root/.xray-edge-manager/warp-outbound.json
jq . /root/.xray-edge-manager/warp-outbound.json
```

重新进入菜单：

```text
21. WARP 出站管理 / 自动生成 warp-outbound.json
```

生产环境建议设置：

```bash
export XEM_WARP_REG_SHA256="64位sha256"
```

---

## 安全边界

脚本已经尽量降低常见误操作风险，但它仍然是 root 脚本。

你应该理解以下边界：

- 脚本会修改系统文件；
- 脚本会安装软件包；
- 脚本会管理 Nginx 配置；
- 脚本会管理 Xray systemd 服务；
- 脚本会管理指定范围内的 Cloudflare DNS；
- 脚本会写入防火墙规则；
- 脚本会创建和使用 Certbot 证书；
- WARP 自动生成功能依赖第三方 `warp-reg` 二进制。

生产建议：

```text
1. 先在全新测试 VPS 跑通
2. 使用专用子域名，不要和其它业务混用
3. Cloudflare Token 只给目标 Zone 的 Zone:Read + DNS:Edit
4. 云安全组只放行实际需要的端口
5. WARP 第三方二进制用 XEM_WARP_REG_SHA256 固定
6. 大规模部署前先手动跑菜单 22 自检
```

---

## 更新建议

如果你用的是本地命令：

```bash
curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/refs/heads/main/xem.sh -o /usr/local/bin/xem
chmod +x /usr/local/bin/xem
xem
```

如果你用的是 beta 文件：

```bash
curl -fsSL -o /usr/local/bin/xem https://raw.githubusercontent.com/0x1233333/xray-edge-manager/refs/heads/main/beta/xem-v0.0.36-rc22-production-ready.sh
chmod +x /usr/local/bin/xem
xem
```

更新前建议：

```bash
cp -a /root/.xray-edge-manager /root/.xray-edge-manager.backup.$(date +%Y%m%d-%H%M%S)
cp -a /usr/local/etc/xray/config.json /root/xray-config.backup.$(date +%Y%m%d-%H%M%S).json 2>/dev/null || true
cp -a /etc/nginx/conf.d/xray-edge-manager.conf /root/nginx-xem.backup.$(date +%Y%m%d-%H%M%S).conf 2>/dev/null || true
```

---

## 致谢

本项目使用或参考了以下开源项目 / 公共资料：

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)  
  核心代理程序，提供 VLESS、REALITY、XHTTP、Hysteria2 等能力。

- [XTLS/Xray-install](https://github.com/XTLS/Xray-install)  
  官方安装脚本备用方案。

- [XTLS/Xray-examples](https://github.com/XTLS/Xray-examples)  
  Xray 配置示例参考。

- [DustinWin/BestCF](https://github.com/DustinWin/BestCF)  
  Cloudflare 优选 IP / 优选域名数据来源。

- [badafans/warp-reg](https://github.com/badafans/warp-reg)  
  用于自动注册 Cloudflare WARP 免费账户并生成 WireGuard 参数。

- [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent)  
  本项目参考其一键脚本思路，并使用其公开伪装站素材目录作为随机伪装站模板来源。

- [Certbot](https://certbot.eff.org/) / [Let’s Encrypt](https://letsencrypt.org/)  
  用于自动申请和续签 TLS 证书。

- [Cloudflare](https://www.cloudflare.com/)  
  用于 DNS 管理、CDN 代理和 DNS-01 验证。

- [Nginx](https://nginx.org/)  
  用于伪装站、订阅文件发布和 XHTTP CDN 反向代理。

感谢以上项目和社区维护者。

---

## 许可协议

建议使用 MIT License。

你可以在仓库根目录添加 `LICENSE` 文件：

```text
MIT License

Copyright (c) 2026 0x1233333

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files, to deal in the Software
without restriction, including without limitation the rights to use, copy,
modify, merge, publish, distribute, sublicense, and/or sell copies of the
Software, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
```

第三方项目遵循其各自原始许可证。
