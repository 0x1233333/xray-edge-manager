
# Xray Edge Manager

`xray-edge-manager` 是一个单文件 Xray-core 节点部署脚本，用于在个人 VPS 上快速部署多协议节点、Cloudflare DNS、证书、Nginx 伪装站和 base64 订阅。

当前版本：`v0.0.1`

---

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh)
````

如果 `curl` 不可用：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh)
```

---

## 安装成本地命令

```bash
curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh -o /usr/local/bin/xem
chmod +x /usr/local/bin/xem
xem
```

以后直接运行：

```bash
xem
```

更新本地命令：

```bash
curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh -o /usr/local/bin/xem
chmod +x /usr/local/bin/xem
```

---

## 支持功能

* 安装 / 升级 Xray-core
* 更新 `geoip.dat` / `geosite.dat`
* 配置 Cloudflare DNS
* 自动申请 DNS-01 泛域名证书
* 配置 Nginx 伪装站
* 生成 base64 订阅
* IPv4 / IPv6 分栈部署
* Hysteria2 UDP 端口跳跃
* BestCF 优选域名入口
* 卸载 / 清理部署环境

---

## 域名规则

脚本要求使用三段式或以上的母域名，例如：

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
v4.node.example.com    IPv4 直连
v6.node.example.com    IPv6 直连
```

不建议直接使用二段根域名：

```text
example.com
```

---

## 协议说明

脚本支持按 IPv4 / IPv6 分别选择协议组合。

```text
1 = VLESS + XHTTP + REALITY
2 = VLESS + XHTTP + TLS + CDN
3 = Xray Hysteria2
4 = VLESS + REALITY + Vision
5 = VLESS + XHTTP + TLS + CDN 入口扩展
```

常用选择：

```text
123      推荐组合
1234     全部主力和备用协议
12345    包含 CDN 入口扩展
```

说明：

* `1` 是直连主力协议，使用 `v4.` / `v6.` 子域名。
* `2` 是 CDN 协议，使用母域名。
* `3` 是 UDP 协议，可选端口跳跃。
* `4` 是 REALITY + Vision 备用直连协议。
* `5` 是 CDN 入口扩展，可配合 BestCF / 优选域名使用。

---

## Cloudflare API Token

需要创建 Cloudflare Restricted API Token。

建议权限：

```text
Zone:Read
DNS:Edit
```

作用范围建议限制到你的目标 Zone。

中文教程：

```text
https://github.com/0x1233333/xray-edge-manager/blob/main/examples/cloudflare-api-token.md
```

不要使用 Global API Key。

---

## Cloudflare CDN 端口

CDN 协议只能使用 Cloudflare 支持的 HTTPS 代理端口：

```text
443
2053
2083
2087
2096
8443
```

非 CDN 协议端口可以自定义。

常见默认端口：

```text
TCP 443    Nginx / CDN / 伪装站 / 订阅
TCP 2443   VLESS + XHTTP + REALITY
UDP 443    Xray Hysteria2
TCP 3443   VLESS + REALITY + Vision
UDP 20000-20100   Hysteria2 端口跳跃
```

---

## 云安全组放行

请在 VPS 控制台手动放行需要的端口。

常见组合：

```text
TCP 443
TCP 2443 或自定义 XHTTP REALITY 端口
TCP 3443 或自定义 Vision 端口
UDP 443
UDP 20000-20100
```

如果你把 XHTTP REALITY 改成 `2053`，就需要放行：

```text
TCP 2053
```

---

## 使用流程

首次部署直接选择：

```text
1. 首次部署向导
```

大致流程：

```text
1. 安装依赖
2. 安装 / 升级 Xray-core
3. 更新 geodata
4. 输入母域名
5. 配置 Cloudflare API Token
6. 选择 IPv4 / IPv6 协议组合
7. 创建 DNS 记录
8. 申请证书
9. 生成 Xray 配置
10. 配置 Nginx 伪装站
11. 配置 Hysteria2 端口跳跃
12. 生成 base64 订阅
```

---

## 订阅

部署完成后会输出订阅链接：

```text
https://node.example.com/sub/xxxxxxxxxxxxxxxx
```

脚本对外发布的是 base64 订阅。

本地文件位置：

```text
/root/.xray-edge-manager/subscription/local.raw
/root/.xray-edge-manager/subscription/local.b64
/root/.xray-edge-manager/subscription/mihomo-reference.yaml
```

其中：

```text
local.raw              原始分享链接
local.b64              base64 订阅
mihomo-reference.yaml  Mihomo 参考配置
```

---

## BestCF

BestCF 默认关闭。

启用后会生成额外的 CDN 入口节点。

说明：

```text
server/address = BestCF 优选域名
SNI/servername = 你的母域名
Host           = 你的母域名
```

脚本只使用优选域名，不使用优选 IP。

---

## 卸载

运行脚本后选择：

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

Cloudflare DNS 默认不会自动删除，需要用户确认。

---

## 检查脚本

如果脚本无法运行，先检查：

```bash
curl -fsSL -o /root/xem.sh https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh
wc -l /root/xem.sh
head -n 5 /root/xem.sh
bash -n /root/xem.sh
```

运行本地文件：

```bash
bash /root/xem.sh
```

---

## 目录

脚本状态目录：

```text
/root/.xray-edge-manager
```

Nginx 站点配置：

```text
/etc/nginx/conf.d/xray-edge-manager.conf
```

Web 根目录：

```text
/var/www/xray-edge-manager
```

Xray 配置：

```text
/usr/local/etc/xray/config.json
```

---

## 安全提示

* 不要公开 Cloudflare API Token
* 不要提交 `/root/.xray-edge-manager/`
* 不要公开订阅链接
* 不要公开证书私钥
* 建议先在测试 VPS 上验证
* 不同客户端对 XHTTP / Hysteria2 的支持可能不同

---

## License

MIT License

```
```
