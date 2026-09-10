---
name: xem-deploy
description: >-
  Use when deploying or debugging xray-edge-manager (xem.sh) on a VPS, fixing
  HY2/REALITY/XHTTP subscription issues, or regenerating Mihomo Alpha client
  configs. Covers hop vs UDP443, clients JSON key, and what must never be
  committed to the public repo.
---

# xray-edge-manager（xem）Agent 手册

面向维护 `xem.sh` / 部署 VPS / 验收订阅的助手。语气对用户用白话；仓库只留公开脚本与文档。

## 仓库边界（硬规矩）

- **可以进 git**：`xem.sh`、`README.md`、`backup/*.sh`、本 `skills/`。
- **禁止进 git**：服务器密码、CF token、订阅 URL/token、测速报告、`/workspace` 运维笔记、私有 recon、含真实密码的 yaml。
- 私有材料放部署机或协作目录（如 `/workspace/...`），不要 push。

## 客户端

- 必须用 **Mihomo 开发板 / Alpha**（要 `xhttp-opts.reuse-settings`）。
- **不要**给节点叠 smux。
- HY2 优先选订阅里的 `*-HY2-HOP`（带 `ports` / URI `mport`）。

## 部署 / 回填要点

1. 从 PR 分支取公开 `xem.sh`（当前线：`v0.0.48-hy2-probe-pad` 起）。
2. 首次部署走脚本完整流程；协议 3（HY2）**默认开端口跳跃**。
3. 云安全组放行：HY2 跳跃 UDP 段（默认 `20000-20499`）以及你设的其它 TCP 口。
4. 改完配置后重生订阅；自检菜单会跑「HY2 连通提示」。
5. 回填/热修：先备份配置与 `state.env`，再改，再 `xray run -test`，再重启。

## HY2 已知坑

| 现象 | 原因 | 处理 |
|------|------|------|
| 客户端 404 / 认证失败（本机官方也 404） | Xray **26.3.27** 只认 JSON **`settings.clients`**，写 `users` 会被忽略 | 用 `clients`；或升到 ≥26.6.1 |
| 外网 HY2 超时，本机却通 | 部分机房 **上游丢掉 UDP 主端口（常见 443）**，包到不了网卡 | 用 **HOP**；不要只测单端口 |
| 双写 `hysteriaSettings.auth` 仍 404（26.3.27） | 该版本 validator 恒非空，不回退 transport auth | 必须填对 `clients` |

脚本默认：跳跃开启；订阅先 `*-HY2-HOP`，再附单端口备用。关闭跳跃：`HY2_DISABLE_HOP=1`（不推荐）。

## 导出字段（Alpha 友好）

- XHTTP / CDN：`packet-encoding: xudp`、`x-padding-bytes: "100-1000"`、`reuse-settings`（连接复用），无 smux。
- HY2-HOP：`ports` + `hop-interval: 20`（整数）、`alpn: h3`；Salamander 默认关。
- Vision：`flow: xtls-rprx-vision` + REALITY + `xudp`。

## 测速 / 验收清单

1. Mihomo Alpha 导入参考 YAML 或订阅。
2. 测 **HY2-HOP**（应通）；单端口 UDP443 外网失败可记为「预期」若已确认上游丢包。
3. 测 Vision、XHTTP-REALITY、CDN-Entry。
4. 看出口 IP 是否为 VPS；记录 delay / generate_204。
5. 报告只写通断与延迟，**不要**把密码、完整订阅链贴进公开 PR。

## 给协作 Bot

- 改脚本：先 `backup/xem-vX.Y.Z-….sh`，再改，再更新 README，只推公开文件。
- 服务器装包 / 防火墙 / 升 Xray：交给有 VPS 权限的测试角色；本 skill 负责脚本与验收口径。
