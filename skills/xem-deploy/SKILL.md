---
name: xem-deploy
description: >-
  Use when deploying or debugging xray-edge-manager (xem.sh) on a VPS, fixing
  HY2/REALITY/XHTTP subscription issues, regenerating Mihomo client
  configs, or doing a clean reinstall after OS wipe. Covers BBR/sysctl defaults,
  hop vs UDP443, clients JSON key, and what must never be committed publicly.
---

# xray-edge-manager（xem）Agent 手册

面向维护 `xem.sh` / 部署 VPS / 验收订阅的助手。对用户用白话；仓库只留公开文件。

## 仓库边界（硬规矩）

- **可以进 git**：`xem.sh`、`README.md`、`backup/*.sh`、本 `skills/`。
- **禁止进 git**：密码、CF token、订阅 URL/token、测速私报、`/workspace` 运维笔记、recon、含真实密码的 yaml。
- 私有材料放部署机或协作目录，不要 push。

## 客户端

- 客户端 **Mihomo 稳定版 1.19.28+ 或 Alpha 均可**：`reuse-settings` / `x-padding-bytes`、
  HY2 的 `ports` / `hop-interval` 自稳定版 1.19.28 起已支持（实测 `mihomo -t` 通过 + 跑通流量）。
  **过时说法**：旧文档写「必须用开发版/Alpha」—— 已不成立，不必让用户特意换内核。
- **不要**叠 smux。
- HY2 优先 `*-HY2-HOP`（`ports` / URI `mport`）。单端口 UDP443 外网可能不通。

## 系统重装后：干净安装步骤

1. 新系统装好基础工具（curl、jq、systemd 等；脚本 `install_deps` 也会装）。
2. 取 PR 公开 `xem.sh`（当前线：**v0.0.58-mlkem-origin-443** 起）。
3. root 跑首次部署（`install_full` / 菜单完整安装）：
   - **默认**会跑稳定型网络优化（BBR+`fq`，见下）。
   - 配 CF / 域名 / 协议；HY2 **默认开端口跳跃**。
4. 云面板放行：TCP 业务口 + **UDP 跳跃段**（默认 `20000-20499`）；UDP 主端口（如 443）也建议放，但部分机房上游仍可能丢。
5. 部署自检通过后重生订阅；客户端导入（**稳定版 1.19.28+ 或 Alpha 均可**）。
6. 全量验收（见文末表）。

回填/热修：先备份 `state.env` 与 Xray/Nginx 配置，再改，再 `xray run -test`，再重启。

## 网络优化清单（默认路径）

`install_full` 开头调用 `apply_stable_network_tuning`（不再只藏在菜单 5）：

| 项 | 行为 |
|----|------|
| BBR | 内核支持则 `tcp_congestion_control=bbr`（必要时 `modprobe tcp_bbr`） |
| 队列 | 默认 `fq`（与 BBR 搭配）；`XEM_QDISC=cake` 且模块可用时才用 cake |
| 其它 | TFO、mtu probing、关闭 idle slow start、提高 somaxconn/backlog、放大 rmem/wmem（脚本既有稳妥值） |
| 跳过 | `XEM_SKIP_NET_TUNING=1` |
| 查看/重跑 | 菜单 5 |

不做危险激进参数（不改路由策略、不关安全模块、不乱调 conntrack 全局超时）。

## HY2 已知坑

| 现象 | 原因 | 处理 |
|------|------|------|
| 本机也 404 | Xray **26.3.27** 只认 **`settings.clients`** | 写 `clients` 或升 ≥26.6.1 |
| 外网超时、本机通 | 上游丢掉 UDP 主端口（常见 443） | 用 **HOP**；自检会提示 |
| 26.3.27 双写 transport auth 仍 404 | validator 恒非空不回退 | 必须 `clients` |

默认开跳跃；订阅先 HOP 再单端口备用。关跳跃：`HY2_DISABLE_HOP=1`（不推荐）。

## 导出字段（Alpha）

- XHTTP/CDN：`xudp`、`x-padding-bytes: "100-1000"`、`reuse-settings`，无 smux。
- HY2-HOP：`ports` + `hop-interval: 20`，`h3`；Salamander 默认关。
- Vision：`xtls-rprx-vision` + REALITY + `xudp`。

## 全量验收表（重装后必测）

| 节点 | 期望 |
|------|------|
| HY2-HOP | **通**（生产入口） |
| HY2-UDP443（或单端口） | 外网可能 **断**（记清是否上游丢包） |
| REALITY Vision | **通** |
| XHTTP-REALITY | **通** |
| CDN-Entry | **通** |

每条记录：delay、generate_204、egress IP。报告勿含密钥/完整订阅链。


## v0.0.50-bugfix 运维要点

- **Xray 不降级**：`install_or_upgrade_xray_release_verified` 会读 `/usr/local/bin/xray version`；若当前 ≥ 候选则跳过覆盖。钉版：`XEM_XRAY_PIN_VERSION=v26.6.1`（允许该标签 prerelease）。跟新协议：`XEM_XRAY_ALLOW_PRERELEASE=1` 时在候选里取 **最高 semver**，不是 GitHub API 顺序的 `.[0]`。
- **HY2 HOP live iptables**：启用/同步时 `purge_stale_hy2_redirect_rules` 按 `iptables/ip6tables -t nat -S PREROUTING` 清理非期望的 UDP 范围 REDIRECT；`sync_hy2_hopping_if_needed` 在状态一致但 live 规则缺失时也会重应用。跳跃段仍不可包含真实监听口。
- **BESTCF reconcile**：协议含 5 时，`select_protocols` 在非交互早退前就会把 `BESTCF_ENABLED/MODE/PER/TOTAL` 对齐；订阅 WARN 会区分「开关未开」与「数据不可用」。
- **空订阅守卫**：`configure_nginx` 不再 `touch` 空订阅文件；`generate_subscription` / 合并订阅在 b64 为空时 `warn`、删除空文件并 `return 1`。

## 443 REALITY 布局（v0.0.58 起有专用命令）

REALITY 占 TCP 443，nginx 让位 **2096**；三处必须同步，缺一处就是「服务端通、站点 525、订阅里没有」。

```bash
# 单台：nginx 443→2096 / xray 增 443 入站 / iptables 放行
ssh <host> 'bash -s' -- <SNI> < scripts/migrate-one-443.sh

# CF 回源端口（逐台列名，遇 wildcard 会拒绝改写）
xem --cf-origin-port 2096            # 或 XEM_CF_ORIGIN_DRY_RUN=1 先看 payload

# 实打验收（家宽三发 + 出口 IP 比对）
XEM_JUMP=<跳板> XEM_BASE_DOMAIN=<域名> scripts/verify-443.sh <host> <SNI>

# 🔴 改完写回 state.env，否则菜单 9 按旧端口重建 → 443 静默消失
xem --check-port-drift               # config.json ↔ state.env ↔ nginx，非零=会回退
```

- **iptables 口径**：443 用 `ACCEPT`（任意来源）；2096 也用 `ACCEPT` —— 不要挂 `XEM_CF_ORIGIN`（那张链只有 CF 段，新边缘 IP 不在表里 → 站点 000）。
- **Origin Rule 禁通配**：`(http.host wildcard "*.BASE")` 会把未迁移子域一起搬到 2096 → 521。脚本只接受 `(http.host in {"a" "b"})` 形状。
- **发布三层**：面板节点数 / 订阅 `/c/` 该端口条数 / 各机 `sub` 文件条数，三数相等才算交付完（`scripts/publish-links-to-xem-sub.sh`）。
- **出口 IP 基准**：拿「ssh 上去在机器上 curl 出口」，别拿域名 A 记录（NAT 机型入站 ≠ 出口）。

## xray ≥ 26.10 与 mihomo：MLKEM（必读）

Xray ≥26.10 的 REALITY 默认协商 X25519MLKEM768；Mihomo 系客户端默认 `support-x25519mlkem768: false`，主动删掉 MLKEM → `REALITY authentication failed`。

- 误判特征：HY2 通、第三方机场 REALITY 通、xray 内核客户端通，**只有连本脚本服务端的 mihomo 客户端全灭**。别去重发 pbk / 换密钥。
- 修法在客户端：`reality-opts` 加 `support-x25519mlkem768: true`（v0.0.58 起 `mihomo-reference.yaml` 默认带，`mihomo -t` 实测通过）。
- 纯 base64 订阅没有这个参数位；要稳定就用参考 YAML，或在订阅转换层补字段。
- 手机/桌面客户端能力清单：`scripts/` 不带客户端实现，Xray 官方客户端不吃这个字段（它本来就支持 MLKEM），只有 Clash 系需要。

## 给协作 Bot

- 改脚本：`backup/xem-vX.Y.Z-….sh` → 改 → README → 只推公开文件。
- `scripts/` 是运维件，不是脚本本体：`migrate-one-443.sh` / `verify-443.sh` / `publish-links-to-xem-sub.sh`，一律用 `<host>`、`<SNI>`、`<域名>` 占位，**不许写真实主机名、域名、zone id、token、订阅 URL**。
- VPS 装包/防火墙/升 Xray：有权限的测试角色做；本 skill 管脚本口径与验收。
- 用户重装系统期间：先改仓库，等材料重导后再 Alpha，不要盲连旧机大改。
