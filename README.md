
# Xray Edge Manager

`xray-edge-manager` 是一个面向个人 VPS 的 Xray-core 单文件部署脚本。它把 Xray-core、Cloudflare DNS、泛域名证书、Nginx 伪装站、XHTTP、REALITY、Hysteria2、BestCF 优选入口和 base64 订阅管理整合到一个交互式菜单里。

当前版本：`v0.0.6`

> 建议先在全新 Debian 12 / Ubuntu VPS 上测试。脚本会修改 Xray、Nginx、证书、防火墙规则和订阅文件。

---

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh)
````

如果 `curl` 不可用：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh)
```

更推荐先下载再运行，方便排错：

```bash
curl -fsSL -o /root/xem.sh https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh
bash -n /root/xem.sh
bash /root/xem.sh
```

---

## 安装成本地命令

```bash
curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh -o /usr/local/bin/xem
chmod +x /usr/local/bin/xem
xem
```

以后直接输入：

```bash
xem
```

更新本地命令：

```bash
curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh -o /usr/local/bin/xem
chmod +x /usr/local/bin/xem
```

---

## 适合谁用

适合：

* 自己有 VPS，想快速部署 Xray 节点
* 想同时生成 IPv4 / IPv6 节点
* 想同时保留直连、CDN、HY2、REALITY Vision 备用节点
* 想用 Cloudflare 自动管理 DNS 和证书
* 想要一个简单的 base64 订阅链接

不适合：

* 多用户机场系统
* 图形化 Web 面板
* 不想让脚本改动 Nginx / Xray / 防火墙规则的机器
* 已经跑了很多网站业务的生产服务器

---

## 域名规则

脚本要求输入三段式或以上的母域名，例如：

```text
node.example.com
jp1.proxy.example.com
us1.edge.example.com
```

假设输入：

```text
node.example.com
```

脚本会按需创建：

```text
node.example.com       CDN / 伪装站 / 订阅
v4.node.example.com    IPv4 灰云直连
v6.node.example.com    IPv6 灰云直连
```

不建议直接使用二段根域名：

```text
example.com
```

---

## 准备 Cloudflare API Token

脚本需要 Cloudflare API Token 来自动创建 DNS 记录和申请 DNS-01 证书。

推荐权限：

```text
Zone:Read
DNS:Edit
```

作用范围建议限制到你的目标 Zone，不建议使用 Global API Key。

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

大致会依次执行：

```text
1. 安装基础依赖
2. 安装 / 升级 Xray-core
3. 更新 geoip.dat / geosite.dat
4. 输入母域名
5. 配置 Cloudflare API Token
6. 输入节点名称
7. 检测 IPv4 / IPv6 / ASN
8. 分别选择 IPv4 和 IPv6 协议组合
9. 创建 Cloudflare DNS 记录
10. 申请泛域名证书
11. 生成 Xray 配置
12. 配置 Nginx 伪装站和订阅路径
13. 配置 Hysteria2 UDP 端口跳跃
14. 生成 base64 订阅
```

部署完成后会输出订阅链接，例如：

```text
https://node.example.com/sub/xxxxxxxxxxxxxxxx
```

---

## 协议选择说明

IPv4 和 IPv6 可以分别选择协议组合。

```text
1 = VLESS + XHTTP + REALITY
2 = VLESS + XHTTP + TLS + CDN
3 = Xray Hysteria2
4 = VLESS + REALITY + Vision
5 = VLESS + XHTTP + TLS + CDN 入口扩展 / BestCF 入口
```

常用选择：

```text
123      推荐基础组合
1234     增加 REALITY Vision 备用
12345    增加 BestCF / CDN 入口扩展
```

简单理解：

| 编号 | 协议                | 用途                   |
| -- | ----------------- | -------------------- |
| 1  | XHTTP + REALITY   | v4 / v6 直连主力         |
| 2  | XHTTP + TLS + CDN | Cloudflare CDN 入口    |
| 3  | Hysteria2         | UDP 高速备用             |
| 4  | REALITY + Vision  | 传统 REALITY 备用        |
| 5  | CDN 入口扩展          | BestCF / 优选域名 / 三网入口 |

---

## BestCF 说明

BestCF 默认关闭。

如果选择协议 `5`，脚本会自动开启 BestCF 的最小模式。

BestCF 有两种模式：

```text
1. 只生成 1 个优选域名节点
2. 生成 1 个优选域名 + 移动/联通/电信各 1 个 IP
```

最多只额外生成 4 个 BestCF 节点，避免节点数量暴增。

BestCF 节点的逻辑：

```text
server/address = BestCF 优选 IP 或优选域名
SNI/servername = 你的母域名
Host           = 你的母域名
```

菜单入口：

```text
11. BestCF 优选域名管理
```

如果启用 12 小时自动更新，脚本会定期拉取 BestCF 数据并重新生成订阅。

---

## 常见端口

请在 VPS 云厂商安全组里手动放行你实际使用的端口。

常见默认端口：

```text
TCP 443             Nginx / CDN / 伪装站 / 订阅
TCP 2443            VLESS + XHTTP + REALITY
TCP 3443            VLESS + REALITY + Vision
UDP 443             Xray Hysteria2
UDP 20000-20100     Hysteria2 端口跳跃
```

Cloudflare CDN 协议只能使用 Cloudflare 支持的 HTTPS 代理端口：

```text
443
2053
2083
2087
2096
8443
```

非 CDN 协议端口可以自定义。

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

本地文件位置：

```text
/root/.xray-edge-manager/subscription/local.raw
/root/.xray-edge-manager/subscription/local.b64
/root/.xray-edge-manager/subscription/merged.raw
/root/.xray-edge-manager/subscription/merged.b64
/root/.xray-edge-manager/subscription/mihomo-reference.yaml
```

---

## 节点名称

首次部署时会询问节点名称，例如：

```text
jp1
hkg2
oracle-tokyo
```

生成的节点会类似：

```text
jp1-v4-XHTTP-REALITY
jp1-v6-XHTTP-REALITY
jp1-CDN-XHTTP-Origin
jp1-CFDomain_1
```

后续可以在订阅管理里修改：

```text
14. 订阅管理
3. 设置节点名称
```

修改后会自动重新生成订阅。

---

## 查看状态

运行脚本后选择：

```text
15. 查看服务状态
```

或者手动执行：

```bash
systemctl status xray --no-pager -l
systemctl status nginx --no-pager -l
ss -tulpen | grep -E ':(443|2443|3443)\b'
```

测试订阅：

```bash
curl -I https://node.example.com/sub/xxxxxxxxxxxxxxxx
```

正常应返回 `200`。

---

## 卸载

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

Cloudflare DNS 默认不会自动删除，必须用户确认。

如果你选择删除 DNS，脚本会优先做归属权校验：只有记录仍指向本机 IP 时才删除，避免误删已经迁移到其他机器的记录。

---

## 常见排错

### 1. 脚本没反应

```bash
curl -fsSL -o /root/xem.sh https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh
wc -l /root/xem.sh
head -n 5 /root/xem.sh
bash -n /root/xem.sh
bash /root/xem.sh
```

### 2. 订阅显示 Welcome / It works

通常是旧 Nginx 配置冲突。检查：

```bash
grep -Rni "server_name" /etc/nginx/conf.d/
nginx -t
```

### 3. 节点导入了但不能连

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

### 4. HY2 不通

```bash
tcpdump -ni any 'udp port 443 or portrange 20000-20100'
```

如果没有包，多半是安全组或运营商 UDP 问题。

---

## 目录说明

脚本状态目录：

```text
/root/.xray-edge-manager
```

Xray 配置：

```text
/usr/local/etc/xray/config.json
```

Nginx 配置：

```text
/etc/nginx/conf.d/xray-edge-manager.conf
```

Web 根目录：

```text
/var/www/xray-edge-manager
```

证书目录：

```text
/etc/letsencrypt/live/<你的母域名>/
```

---

## 致谢

本项目使用或参考了以下开源项目 / 公共资料：

* [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
  核心代理程序，提供 VLESS、REALITY、XHTTP、Hysteria2 等能力。

* [XTLS/Xray-install](https://github.com/XTLS/Xray-install)
  用于安装、升级 Xray-core 和 geodata。

* [XTLS/Xray-examples](https://github.com/XTLS/Xray-examples)
  Xray 配置示例参考。

* [DustinWin/BestCF](https://github.com/DustinWin/BestCF)
  Cloudflare 优选 IP / 优选域名数据来源。

* [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent)
  本项目参考其一键脚本思路，并使用其公开伪装站素材目录作为随机伪装站模板来源。

* [Certbot](https://certbot.eff.org/) / [Let’s Encrypt](https://letsencrypt.org/)
  用于自动申请和续签 TLS 证书。

* [Cloudflare](https://www.cloudflare.com/)
  用于 DNS 管理、CDN 代理和 DNS-01 验证。

* [Nginx](https://nginx.org/)
  用于伪装站、订阅文件发布和 XHTTP CDN 反向代理。

感谢以上项目和社区维护者。

---

## 许可协议

本项目建议使用 MIT License。

你可以在仓库根目录添加 `LICENSE` 文件：

```text
MIT License

Copyright (c) 2026 0x1233333

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files, to deal in the Software
without restriction, including without limitation the rights to use, copy,
modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
```

第三方项目遵循其各自原始许可证。

```
::contentReference[oaicite:1]{index=1}
```

[1]: https://github.com/xtls/xray-core?utm_source=chatgpt.com "XTLS/Xray-core: Xray, Penetrates Everything. Also the best ..."
