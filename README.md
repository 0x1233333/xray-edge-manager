# xray-edge-manager

一键在 VPS 上部署 **Xray-core 边缘抗封锁节点**：REALITY 直连 + Cloudflare CDN 中转 + Xray Hysteria2 (HY2) + BestCF 优选入口 + Nginx 伪装站/订阅 + 可选 WARP 出站。

当前脚本版本：`v0.0.36-rc22-production-ready`（仓库入口脚本一般为 `xem.sh`）。

---

## 它做什么

| 能力 | 说明 |
|------|------|
| **REALITY 直连** | 协议 1：VLESS + XHTTP + REALITY（默认 TCP `2443`）；协议 4：VLESS + REALITY + Vision（默认 TCP `3443`） |
| **CDN 中转** | 协议 2：VLESS + XHTTP + TLS，经 Nginx 回源，走 Cloudflare 代理的母域名 |
| **BestCF 优选** | 协议 5：复用 CDN 入站，订阅中生成 BestCF 优选域名/IP 入口节点 |
| **Hysteria2** | 协议 3：Xray 内置 HY2（UDP，默认 `443`，可与 Nginx TCP 443 共存） |
| **伪装 + 订阅** | Nginx 随机博客伪装站；base64 订阅发布到 Web；可选合并远程订阅 |
| **WARP 出站** | 纯 IPv6 / 需要 IPv4 出口时，可用 `warp-reg` 自动生成 WireGuard outbound |
| **运维** | Cloudflare DNS 角色模型、DNS-01 证书、源站仅 CF 回源、HY2 端口跳跃、geodata 定时更新 |

**不是** Docker / sing-box 全家桶；运行时以 **Xray-core + Nginx** 为主，HY2 由 **Xray 的 Hysteria2 入站**提供（不是独立 hysteria2 守护进程）。

---

## 当前技术栈

```
客户端
  ├─ REALITY / Vision  ──DNS-only──► v4./v6.<BASE>  :2443/:3443  ──► Xray
  ├─ CDN / BestCF      ──CF 代理──► <BASE>          :443        ──► Nginx ──► Xray (127.0.0.1)
  └─ HY2               ──DNS-only──► v4./v6.<BASE>  :443/UDP    ──► Xray

证书: certbot + Cloudflare DNS-01  →  /etc/letsencrypt + 同步到 Xray 可读目录
出站: freedom / 可选 WARP (out-warp)
状态: /root/.xray-edge-manager/state.env
```

| 组件 | 路径 / 角色 |
|------|-------------|
| Xray | `/usr/local/etc/xray/config.json`，用户 `xray` |
| Nginx | `/etc/nginx/conf.d/xray-edge-manager.conf` |
| 伪装站 + 订阅 Web 根 | `/var/www/xray-edge-manager/` |
| 订阅文件 | `/var/www/xray-edge-manager/sub/<TOKEN>` |
| 本机订阅源 | `/root/.xray-edge-manager/subscription/` |
| 状态 / BestCF / WARP | `/root/.xray-edge-manager/` |
| 本地命令 | `/usr/local/bin/xem`（首次 curl 运行后会提示固化） |

---

## 域名角色模型（重要）

Cloudflare 只代理 **TCP 80/443**（及少数 HTTPS 备用端口），**不代理 UDP，也不代理 2443 等非标直连端口**。

| 名称 | DNS | 用途 |
|------|-----|------|
| `BASE_DOMAIN`（如 `jparm.example.com`） | A/AAAA，**proxied=true**（小黄云） | 订阅 URL、伪装站、CDN/BestCF 入口 |
| `v4.BASE_DOMAIN` | **仅 A**，proxied=false | IPv4 **直连**节点（REALITY / Vision / HY2） |
| `v6.BASE_DOMAIN` | **仅 AAAA**，proxied=false | IPv6 **直连**节点 |

因此：

- **REALITY / HY2 / Vision** 链接主机名使用 `v4.` / `v6.`（直连解析到机器 IP），**不要**走 CF 代理的母域名。
- **CDN / BestCF** 使用母域名或优选 CF 边缘地址，TLS SNI / host 仍为母域名。

---

## 安装

需要：**root**、公网 IPv4 和/或 IPv6、Cloudflare 托管的域名（zone 级 API Token）、Ubuntu/Debian 类系统。

### 一键（GitHub Raw）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh)
```

进入菜单后选 **`1. 首次部署向导`**。

### 下载后执行（推荐生产）

```bash
curl -fsSL -o /tmp/xem.sh https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh
# 可选：校验 SHA256 后
install -m 755 /tmp/xem.sh /usr/local/bin/xem
xem
```

### 环境变量（可选）

| 变量 | 含义 |
|------|------|
| `XEM_SCRIPT_RAW_URL` | 覆盖自安装 / 定时任务用的脚本 Raw 地址（分支/fork） |
| `XEM_SELF_SHA256` | 安装本地 `xem` 时强制校验脚本 SHA256 |
| `XEM_TRUST_REMOTE_SELF=1` | 跳过“是否从远程固化本地命令”确认 |
| `XEM_WARP_ENDPOINT_IPV4` / `XEM_WARP_ENDPOINT_IPV6` | WARP endpoint 覆盖 |

### 云厂商安全组（必做）

脚本在本机 **仅在 ufw/firewalld 已启用时** 尝试放行端口；**不会**默认用 iptables 全量 `ACCEPT` 入站。Oracle / AWS 等还需在安全组/NSG 放行：

| 方向 | 端口 | 用途 |
|------|------|------|
| TCP | `80` | Nginx HTTP→HTTPS；CF 回源（若开启源站限制也会管 80） |
| TCP | `443`（或你选的 CF HTTPS 端口） | 订阅 / 伪装 / CDN |
| TCP | `2443`（或你设的 REALITY 端口） | XHTTP+REALITY |
| TCP | `3443`（若启用 Vision） | REALITY+Vision |
| UDP | `443`（或你设的 HY2 端口） | Hysteria2 |
| UDP | 跳跃段（若启用，如 `20000-20100`） | HY2 端口跳跃 |

---

## 配置流程（首次部署向导）

1. **安装依赖** + **Xray-core** + geodata  
2. **母域名** `BASE_DOMAIN`（建议 ≥3 段，如 `jparm.0x0000.top`）  
3. **Cloudflare API Token**（Zone DNS Edit + 用于 certbot DNS-01）  
4. **节点显示名**  
5. **ASN/IP 报告**（辅助选 REALITY 伪装目标）  
6. **IPv4 / IPv6 协议栈策略**（每栈独立选 `0/1/2/3/4/5` 或组合如 `123`）  
7. **端口**：CDN/订阅 HTTPS、REALITY、Vision、HY2  
8. **出口策略**：`auto`（推荐）/ `force-v4` / `warp-v4` / `stack` / `none`  
9. **DNS**：按角色写入 BASE / v4 / v6  
10. **证书**：Let’s Encrypt + Cloudflare DNS-01（`BASE` + `*.BASE`）  
11. **REALITY target**（伪装站目标，带黑名单与证书链长度校验）  
12. 生成 Xray / Nginx、可选 HY2 跳跃、防火墙与 CF 源站限制  
13. 重启服务 → 生成订阅 → 生产自检 → 摘要  

之后日常：`xem` 菜单，或：

```bash
xem --healthcheck
xem --bestcf-update
xem --geodata-update
xem --apply-hy2-hopping
xem --apply-cf-origin-firewall
```

---

## 协议说明

| 编号 | 名称 | 传输 | 默认端口 | 主机名 |
|------|------|------|----------|--------|
| **1** | VLESS + XHTTP + REALITY | TCP 直连 | `2443` | `v4.` / `v6.` |
| **2** | VLESS + XHTTP + TLS + CDN | 经 CF → Nginx → 本地 Xray | `443` | `BASE_DOMAIN` |
| **3** | Xray Hysteria2 | UDP | `443` | `v4.` / `v6.` |
| **4** | VLESS + REALITY + Vision | TCP 直连，`flow=xtls-rprx-vision` | `3443` | `v4.` / `v6.` |
| **5** | CDN / BestCF 入口扩展 | 与 2 共用 CDN 入站 | `443` | BestCF 优选或 `BASE` |

推荐组合示例：

- 抗封锁主力：`1` + `5`（REALITY 直连 + BestCF CDN 备用）  
- 完整栈：`1235` 或 `12345`  
- 仅 CDN：`2` 或 `5`

### 协议 5 = BestCF 优化 CDN

- 选择 **5** 时，脚本会 **自动开启 BestCF**（默认 domain 模式，限制少量优选节点，避免订阅爆炸）。  
- 生成订阅前会尝试拉取 [DustinWin/BestCF](https://github.com/DustinWin/BestCF) 发布的列表。  
- 若远端/本地均无可用数据，**回退**为母域名 CDN Entry，避免空节点。  
- 菜单 **11** 可切换模式（域名 / ISP 域名等）、限额与定时刷新。  
- 协议 **2** 也可在手动开启 `BESTCF_ENABLED` 后附加优选节点；**5 的语义就是“入口扩展 + BestCF”**。

---

## REALITY 伪装目标选择

安装时会根据区域/ASN 给出推荐列表（如日本：yahoo.co.jp、amazon.co.jp、rakuten…；美国：ebay、oracle、amazon…），并提供快捷项：

1. `www.ebay.com`  
2. `www.oracle.com`  
3. `www.amazon.com`  
4. 手动输入（强制校验）

原则：选 **大厂、证书链短、本机可 TCP 443 探测** 的目标；避开证书过大或已知不兼容域名。

### `REALITY_BLACKLIST`

Xray REALITY 对目标站点 TLS 证书链有缓冲区上限（约 **8192 字节**）。脚本内置全局黑名单（可按需改脚本内数组）：

```bash
REALITY_BLACKLIST=("www.microsoft.com" "microsoft.com" "login.microsoftonline.com")
```

`validate_reality_target` 行为：

- **大小写不敏感** 匹配黑名单  
- 使用 `openssl s_client -showcerts` 探测完整证书链长度  
- 链长度 **> 7800** 字节则拒绝（留安全余量）  
- 探测失败 / 未装 openssl → **fail-closed**（拒绝该 target，避免装完不能用）  
- 快捷选项与手动输入最终都会过校验  

---

## 订阅

- 本机订阅：`https://<BASE_DOMAIN>/sub/<SUB_TOKEN>`  
- 合并订阅（本机 + 远程列表）：`https://<BASE_DOMAIN>/sub/<MERGED_SUB_TOKEN>`  
- Web 文件目录：`/var/www/xray-edge-manager/sub/`（**不是** `/usr/local/etc/xray/www/sub/`）  
- 原始节点列表：`/root/.xray-edge-manager/subscription/local.raw`  
- Mihomo 参考片段：`.../subscription/mihomo-reference.yaml`（仅参考，对外仍发 base64）

菜单 **14** 管理远程订阅合并、轮换 token、重生成。

---

## Clash Meta / Mihomo 兼容性

对外订阅为 **通用 base64 节点链接**；同时生成 Mihomo 参考 YAML。

| 协议 | 分享链接要点 | 客户端要求 |
|------|----------------|------------|
| XHTTP + REALITY | `type=xhttp`，`security=reality`，`mode=auto` | **Clash Meta / Mihomo 较新 dev 内核**（需支持 xhttp） |
| XHTTP + CDN | `type=xhttp`，`security=tls`，`host`/`sni`=母域名 | 同上 |
| Vision | `type=tcp`，`flow=xtls-rprx-vision`，`security=reality` | Meta 常规 REALITY+Vision 支持 |
| HY2 | `hysteria2://`，`alpn=h3`，可选 `mport` 跳跃 | 客户端需 **Hysteria2** 实现；**旧 Clash 内核不够** |

建议客户端：**Clash Verge Rev / Mihomo（新版 meta 内核）**、v2rayN / sing-box 等已跟进 xhttp 与 HY2 的版本。  
本脚本 **不使用 WebSocket(ws)** 作为主传输；CDN 与直连主力均为 **xhttp**。

---

## 菜单速查

| 项 | 功能 |
|----|------|
| 1 | 首次部署向导 |
| 2–4 | 依赖 / Xray / geodata |
| 5 | BBR / 稳定型 sysctl |
| 6–7 | Cloudflare DNS / 证书 |
| 9 | 重选 v4/v6 协议并刷新全栈 |
| 10 | 只重配 Nginx / 伪装 / 订阅路径 / CDN 回源 |
| 11 | BestCF |
| 12 | HY2 端口跳跃 |
| 13 | 本机防火墙 + 可选「仅 CF 回源」 |
| 14 | 订阅管理 |
| 15–19 | 状态 / 链接 / 重启 / 摘要 / 安装状态 |
| 20 | 卸载 |
| 21 | WARP 出站 |
| 22 | 生产自检 |

---

## 已知限制

1. **HY2 需要支持 Hysteria2 的客户端内核**  
   服务端是 Xray 的 HY2 入站，不是独立 `hysteria` 二进制。老版 Clash Premium / 仅支持 hy1 的客户端连不上。

2. **Cloudflare 不代理 UDP，也不代理非 CF HTTPS 端口上的直连**  
   - HY2（UDP）必须走 `v4.`/`v6.` DNS-only（或直接 IP），不能指望黄云母域名。  
   - REALITY `2443` / Vision `3443` 同理，必须直连。  
   - 只有协议 2/5 的 TCP 443（及 CF 支持的 HTTPS 端口）适合走 CDN。

3. **本机防火墙**  
   未启用 ufw/firewalld 时，脚本**不会**自动用 iptables 开放入站；务必在云安全组放行。开启「仅 CF 回源」后，非 CF IP 访问 TCP 80/443 会被丢弃（**不影响** HY2 UDP 与 REALITY 直连端口）。

4. **证书申请依赖 Cloudflare DNS API**  
   使用 DNS-01，不依赖本机 80 做 HTTP-01；但 Nginx 仍监听 80 做跳转，生产建议安全组放行 80。

5. **REALITY target 必须本机可探测**  
   若出网被墙或目标不可达，校验 fail-closed，需换可访问的大厂域名。

6. **BestCF 数据依赖上游 GitHub Release**  
   拉取失败时协议 5 回退母域名 CDN，优选效果会暂时消失。

7. **curl 管道首次运行**  
   进程来自 `/dev/fd`，固化 `/usr/local/bin/xem` 时可能再拉一次 Raw；生产环境建议先落盘再 `install`，或设置 `XEM_SELF_SHA256`。

8. **Oracle ARM 等**  
   注意安全列表、IPv6 是否完整、以及 UDP 443 是否被运营商/安全组丢掉；HY2 问题优先查 UDP 与客户端内核。

---

## 安全提示

- 使用 **权限最小化** 的 CF API Token，部署后可轮换。  
- 订阅 URL 含长随机 token，勿提交到公开仓库；怀疑泄露时用菜单轮换 token。  
- 状态文件与密钥在 `/root/.xray-edge-manager/`，权限应为 root-only。  
- 开启 CF 源站限制可降低源站 IP 被扫订阅/伪装站的风险。  
- 本项目**不嵌入**任何个人域名、邮箱、IP 或 Token。

---

## 卸载

菜单 **20**：可按范围清理 Xray 配置、Nginx 站点、Web 根、DNS 记录、证书、本机 `xem` 与状态目录。执行前请确认不再需要节点与订阅。

---

## 许可证与致谢

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)  
- [DustinWin/BestCF](https://github.com/DustinWin/BestCF)  
- [badafans/warp-reg](https://github.com/badafans/warp-reg)  
- Cloudflare / Let’s Encrypt / Nginx  

仓库：<https://github.com/0x1233333/xray-edge-manager>

---

## 快速验证清单（部署后）

```bash
xem --healthcheck
# 或菜单 22 / 16

# 本机
ss -lntup | egrep ':(80|443|2443)\s'
curl -fsS "https://<BASE_DOMAIN>/sub/<SUB_TOKEN>" | head -c 40; echo

# 客户端
# - REALITY: 主机 v4.<BASE> 端口 2443
# - CDN/BestCF: 主机为优选或 <BASE> 端口 443
# - HY2: 主机 v4.<BASE> UDP 443，需 Meta/HY2 内核
```
