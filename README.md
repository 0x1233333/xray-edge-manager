- **v0.0.51-cfdomain-sni-fix**: 修复 **BestCF / CFDomain 节点全部不可用**。`add_bestcf_nodes_from_file` 不再把优选域名本身当作 SNI/Host（那样 CF 会按**那个域名的 zone** 回源 → `HTTP 403 DNS points to prohibited IP`，根本到不了本机源站），改为始终使用本机母域名 `$BASE_DOMAIN`；优选域名/优选 IP 只作为**连接入口**（借其 Cloudflare 边缘 IP）。该缺陷自 v0.0.40 引入，v0.0.40–v0.0.50 全部受影响（`xem20260629正式版` 行为正确，本次恢复一致）。复现与修法对照见下。

  ```bash
  # 缺陷（v0.0.40–v0.0.50）：优选域名条目把域名自己当 SNI/Host
  add_vless_xhttp_cdn_link "$server" "$name" "$raw" "$port" "$server"   # ❌ CF 403
  # 修复：SNI/Host 回落本机母域名（优选域名仍作 target/入口）
  add_vless_xhttp_cdn_link "$server" "$name" "$raw" "$port"             # ✅
  ```
- **v0.0.50-bugfix**: 七项修复——① 禁止静默降级 Xray（`xray_version_ge` / 安装前跳过）；② `XEM_XRAY_PIN_VERSION` 精确钉版（允许该标签 prerelease）；③ `XEM_XRAY_ALLOW_PRERELEASE=1` 时按最高 semver 选取而非 API `.[0]`；④ `select_protocols` 非交互早退前 `reconcile_bestcf_state_if_needed`；⑤ HY2 跳跃按 live iptables 清理/同步（`purge_stale_hy2_redirect_rules` / `hy2_live_redirect_matches`）；⑥ 去掉 `configure_nginx` 对订阅文件的空 `touch`，生成后拒绝发布空 b64；⑦ `XEM_VERSION` 横幅与 `allowed_state_key` 去重 `CF_ZONE_NAME`。
- **v0.0.49-net-default**: 首次部署 `install_full` 默认应用稳定型网络优化（有 BBR 则开 BBR + `fq`；无则保留现有拥塞控制；可 `XEM_SKIP_NET_TUNING=1` 跳过 / `XEM_QDISC=cake` 选用 cake）。`skills/xem-deploy` 同步干净重装与验收清单。
- **v0.0.48-hy2-probe-pad**: Mihomo 参考 YAML 为 XHTTP 补上与服务端一致的 `x-padding-bytes: "100-1000"`；部署自检增加 HY2 监听/跳跃确认，并明文提示优先用 `*-HY2-HOP`；仓库增加 `skills/xem-deploy/SKILL.md` 供 Agent 使用。
- **v0.0.47-hy2-hop-default**: 默认开启 HY2 UDP 端口跳跃；订阅/Mihomo 参考 YAML **优先** `*-HY2-HOP`（`ports`/`mport`），其后附单端口节点；文档注明部分机房外网 UDP 443 在到达网卡前被丢。关闭跳跃：`HY2_DISABLE_HOP=1` 或交互确认关闭。
- **v0.0.46-hy2-clients**: HY2 inbound JSON key `clients` (Xray 26.3.27 only unmarshals `clients`, not `users`; empty validator caused HTTP/3 404).

# xray-edge-manager

一键在 VPS 上部署 **Xray-core 边缘抗封锁节点**：REALITY 直连 + Cloudflare CDN 中转 + Xray Hysteria2 (HY2) + BestCF 优选入口 + Nginx 伪装站/订阅 + 可选 WARP 出站。

当前脚本版本：`v0.0.50-bugfix`（仓库入口脚本一般为 `xem.sh`）。

---

## 它做什么

| 能力 | 说明 |
|------|------|
| **REALITY 直连** | 协议 1：VLESS + XHTTP + REALITY（默认 TCP `2443`）；协议 4：VLESS + REALITY + Vision（默认 TCP `3443`） |
| **CDN 中转** | 协议 2：VLESS + XHTTP + TLS，经 Nginx 回源，走 Cloudflare 代理的母域名 |
| **BestCF 优选** | 协议 5：复用 CDN 入站，订阅中生成 BestCF 优选域名/IP 入口节点 |
| **Hysteria2** | 协议 3：Xray 内置 HY2（UDP 监听默认 `443`，可与 Nginx TCP 443 共存；**默认开启端口跳跃**，订阅优先 hop） |
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
| Xray | `/usr/local/etc/xray/config.json`，用户 `xray`；geodata 在 `/usr/local/share/xray`，`XRAY_LOCATION_ASSET`（systemd drop-in `15-xem-asset.conf`） |
| Nginx | `/etc/nginx/conf.d/xray-edge-manager.conf` |
| 伪装站 + 订阅 Web 根 | `/usr/local/etc/xray/www/` |
| 订阅文件 | `/usr/local/etc/xray/www/sub/<TOKEN>` |
| 本机订阅源 | `/root/.xray-edge-manager/subscription/` |
| 状态 / BestCF / WARP | `/root/.xray-edge-manager/` |
| 本地命令 | `/usr/local/bin/xem`（首次 curl 运行后会提示固化） |

---

## 域名角色模型（重要）

Cloudflare 只代理 **TCP 80/443**（及少数 HTTPS 备用端口），**不代理 UDP，也不代理 2443 等非标直连端口**。

| 名称 | DNS | 用途 |
|------|-----|------|
| `BASE_DOMAIN`（如 `node.example.com`） | A/AAAA，**proxied=true**（小黄云） | 订阅 URL、伪装站、CDN/BestCF 入口 |
| `v4.BASE_DOMAIN` | **仅 A**，proxied=false | IPv4 **直连**节点（REALITY / Vision / HY2） |
| `v6.BASE_DOMAIN` | **仅 AAAA**，proxied=false | IPv6 **直连**节点 |

因此：

- **REALITY / HY2 / Vision** 链接主机名使用 `v4.` / `v6.`（直连解析到机器 IP），**不要**走 CF 代理的母域名。
- **CDN / BestCF**：IP 入口的 TLS SNI/host 用母域名；优选 **域名** 入口的 SNI/host 用该 FQDN。

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
| `XEM_XRAY_ALLOW_PRERELEASE=1` | 安装 Xray-core 时包含官方 prerelease；默认只装最新稳定版 |
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
| UDP | 跳跃段（若启用，默认 `20000-20499`） | HY2 端口跳跃 |

---

## 配置流程（首次部署向导）

1. **安装依赖** + **Xray-core** + geodata  
2. **母域名** `BASE_DOMAIN`（建议 ≥3 段，如 `node.example.com`）  
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
REALITY_BLACKLIST=("www.microsoft.com" "microsoft.com" "login.microsoftonline.com" "www.apple.com" "apple.com" "icloud.com" "www.icloud.com")
```

`validate_reality_target` 行为：

- **大小写不敏感** 匹配黑名单  
- 使用 `openssl s_client -showcerts` 探测完整证书链长度  
- 链长度 **> 7800** 字节则拒绝（留安全余量）  
- 探测失败 / 未装 openssl → **fail-closed**（拒绝该 target，避免装完不能用）  
- 快捷选项与手动输入最终都会过校验。

额外校验（对齐 Xray-core 26.x 启动警告）：域名包含 `apple` / `icloud` / `microsoft`，或后缀 `.cn` / `.ru` / `.ir` 会被拒绝。

生成的 Xray JSON 同时写 `streamSettings.method` 与兼容字段 `network`；Hysteria2 入站使用 `settings.clients`（Xray 26.3.27 仅认此 JSON 键；≥26.6.1 亦兼容 `users`）；REALITY 同时写 `dest` 与 `target`。安装 Xray 默认取**最新稳定 Release**（当前官方 latest 为 `v26.3.27`），需要跟进 prerelease 时设置 `XEM_XRAY_ALLOW_PRERELEASE=1`。

---

## 订阅

- 本机订阅：`https://<BASE_DOMAIN>/sub/<SUB_TOKEN>`  
- 合并订阅（本机 + 远程列表）：`https://<BASE_DOMAIN>/sub/<MERGED_SUB_TOKEN>`  
- Web 文件目录：`/usr/local/etc/xray/www/sub/`（Nginx 读这里，不读 `/root`）  
- 原始节点列表：`/root/.xray-edge-manager/subscription/local.raw`  
- Mihomo 参考片段：`.../subscription/mihomo-reference.yaml`（仅参考，对外仍发 base64）

菜单 **14** 管理远程订阅合并、轮换 token、重生成。

---

## Clash Meta / Mihomo 兼容性

对外订阅为 **通用 base64 节点链接**；同时生成 Mihomo 参考 YAML。

| 协议 | 分享链接要点 | 客户端要求 |
|------|----------------|------------|
| XHTTP + REALITY | `type=xhttp`，`security=reality`，`mode=auto` | **Clash Meta / Mihomo 较新 dev 内核**（需支持 xhttp） |
| XHTTP + CDN | `type=xhttp`，`security=tls`，`host`/`sni`=母域名或优选 FQDN | 同上 |
| Vision | `type=tcp`，`flow=xtls-rprx-vision`，`security=reality` | Meta 常规 REALITY+Vision 支持 |
| HY2 | `hysteria2://`，`alpn=h3`，可选 `mport` 跳跃 | 客户端需 **Hysteria2** 实现；**旧 Clash 内核不够** |

建议客户端：**Mihomo 开发板/Alpha**（xhttp `reuse-settings` / XMUX；HY2 参考 YAML 含 `ports` + `hop-interval: 20`）。Clash Verge Rev 选开发板内核。不要给 XHTTP 节点叠 smux。v2rayN / sing-box 仍可用通用订阅，但 XMUX 字段以 Mihomo 参考 YAML 为准。  
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
   - **默认开启**端口跳跃（段 `20000-20499`）：Xray **只听一个** HY2 UDP 口；本机用 iptables/ip6tables `REDIRECT` 把跳跃段转到该口（开机由 `xem-hy2-hopping.service` / `xem --apply-hy2-hopping` 恢复）。跳跃范围**不能包含**真实监听口，否则会自环。  
   - 变更 `HY2_PORT` 或开关协议 3 后，脚本会尝试同步/清理跳跃 NAT；同步失败**不会**回滚已写入的 Xray 配置（会告警，可稍后菜单 12 重跑）。  
   - 开机 `--apply-hy2-hopping` / 内部恢复路径对非法范围、缺 iptables、跳跃段包含监听口等改为**告警并跳过**，避免 oneshot 每次开机失败；交互菜单仍会直接报错退出。  
   - 防火墙放行跳跃 UDP 段仅在协议 3 启用且已配置 `HY2_HOP_RANGE` 时添加。  
   - 客户端：订阅 `mport` / Mihomo `ports` + `hop-interval: 20`（随机间隔换端口）。
   - 部署自检会打印「HY2 连通提示」：确认本机 UDP 监听与跳跃规则，并提醒客户端优先 `*-HY2-HOP`（本机通 ≠ 外网 UDP 主端口通）。
   - **部分机房外网 UDP 443 不可达**：包在到达 VPS 网卡前被上游丢弃（本机 `tcpdump` 0 包），本机环回/同机官方客户端仍可能 HyOK。生产请用 **HY2-HOP**；云安全组需放行跳跃 UDP 段（默认 `20000-20499`）。单端口节点仅作同机/可达路径备用。  
   - 未认证探测走 REALITY 目标站反向代理伪装；Salamander 混淆（有 `HY2_OBFS` 时订阅才带 `obfs=salamander`，客户端需支持）。  
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
   注意安全列表、IPv6 是否完整、以及 UDP 443 是否被运营商/安全组掉掉；HY2 问题优先查 UDP 与客户端内核。

9. **Xray 26.x REALITY 默认 minClientVer**  
   若服务端未显式设置 `minClientVer`，Xray-core 26.3.27+ 会默认要求客户端也是 v26.3.27+；旧客户端/第三方内核可能被拒。

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

## 版本记录（脚本 / README 同步更新）

每次改 `xem.sh` 都会同步改本 README 的版本号与说明。

**历史备份**：每次发版前把上一版可运行的 `xem.sh` 拷到仓库 `backup/`（命名如 `backup/xem-v0.0.43-ops.sh`），改坏时可直接回滚，不必翻 git bisect。

| 版本 | 要点 |
|------|------|
| **v0.0.50-bugfix** | 不降级 Xray + PIN/最高 semver；BESTCF 早退前 reconcile；HOP 按 live iptables 清理同步；拒绝空订阅 touch/发布；版本常量横幅 |
| **v0.0.44-pipefix** | 管道下 `ask` 只读 stdin；已保存 CF 防火墙状态可跳过确认；僵尸锁 `rm` 重建；CDN `trustedXForwardedFor`+`X-Xem-Cdn-Trusted`；BestCF 无数据重试且有协议2时不重复 Entry；非交互跳过节点名/REALITY/HY2 跳跃提问 |
| **v0.0.43-ops** | 开机/内部 HY2 跳跃恢复 soft-fail；`restart_services` 轮询 active 避免误回滚；备份选取避开 `ls\|head` pipefail；防火墙跳跃段仅协议 3；菜单 4 可关闭 geodata 定时器；清理未使用 stack/SSRF 包装函数 |
| **v0.0.42-harden** | Xray 配置已原子写入后，HY2 跳跃同步在子 shell 执行：`die`/`exit` 不会把整次 `generate_xray_config` 判失败 |
| **v0.0.41-hy2hop-sync** | 监听口变更后同步 iptables `REDIRECT` 目标；拒绝跳跃段包含监听口；开机只恢复 NAT；Mihomo HY2 `obfs` 仅在设置了混淆时写入 |
| **v0.0.40-geodata** | `XRAY_LOCATION_ASSET=/usr/local/share/xray`，避免首次 `xray -test` 找不到 `geoip.dat` |
| **v0.0.39-mihomo** | Mihomo Alpha：XHTTP `reuse-settings`/XMUX、padding、`packet-encoding: xudp`；HY2 `hop-interval: "10-30"` |
| **v0.0.38-antigfw** | HY2 Salamander、masquerade、默认端口跳跃、额外 REALITY shortIds |

合入 `main` 后请在 VPS 上重新生成 Xray 配置与订阅（菜单 9 或等价流程）。

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
