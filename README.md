
# Xray Edge Manager

`xray-edge-manager` 是一个单文件 Xray-core 节点部署与订阅管理脚本，目标是把 Xray-core、Cloudflare DNS、证书、Nginx 伪装站、XHTTP、REALITY、Hysteria2、BestCF 优选域名和 base64 订阅整合到一个交互式脚本里。

> 当前版本仍处于 Alpha 阶段，建议先在全新测试 VPS 上验证，不建议直接用于生产环境。

---

## 一键运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh)
````

如果 `curl` 连接失败，可以用 `wget`：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh)
```

---

## 安装成本地命令

安装后可以直接输入 `xem` 打开菜单。

```bash
curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh -o /usr/local/bin/xem
chmod +x /usr/local/bin/xem
xem
```

更新本地命令：

```bash
curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh -o /usr/local/bin/xem
chmod +x /usr/local/bin/xem
```

---

## 项目定位

`xray-edge-manager` 不是面板，也不是机场系统。它是一个面向个人 VPS 的 Xray-core 自动部署和订阅管理脚本。

它主要用于：

* 安装 / 升级 Xray-core
* 配置 Cloudflare DNS
* 自动管理橙云 / 灰云
* DNS-01 方式申请证书
* 配置 Nginx 伪装站
* 部署 VLESS + XHTTP + REALITY
* 部署 VLESS + XHTTP + TLS + CDN
* 部署 Xray Hysteria2
* 配置 Hysteria2 UDP 端口跳跃
* 生成 base64 订阅
* 整合多台机器的 base64 订阅

---

## 核心设计

每台机器最多使用 3 个域名：

```text
1.example.com       CDN / 伪装站 / 订阅域名
v4.1.example.com    IPv4 灰云直连
v6.1.example.com    IPv6 灰云直连
```

其中：

| 域名                   | 用途              | Cloudflare 状态    |
| -------------------- | --------------- | ---------------- |
| `1.example.com`    | CDN 入口、伪装站、订阅链接 | 启用 CDN 时橙云，否则可灰云 |
| `v4.1.example.com` | IPv4 直连入口       | 灰云               |
| `v6.1.example.com` | IPv6 直连入口       | 灰云               |

这样做的目的是避免 A / AAAA 混用，方便 IPv4 和 IPv6 分开配置策略。

---

## 默认协议组合

默认安装组合是：

```text
123
```

也就是：

```text
1. VLESS + XHTTP + REALITY
2. VLESS + XHTTP + TLS + CDN
3. Xray Hysteria2
```

可选协议：

```text
4. VLESS + REALITY + Vision
5. XHTTP CDN + REALITY 分离实验模式
```

---

## 协议说明

### 1. VLESS + XHTTP + REALITY

默认直连协议。

```text
CDN: no
默认端口: TCP 2443，可自定义
用途: 默认直连、速度和伪装平衡
```

适合优质 IPv4 / IPv6 线路。

---

### 2. VLESS + XHTTP + TLS + CDN

最高隐藏协议。

```text
CDN: yes
默认端口: TCP 443
用途: CDN、伪装站、主力抗封锁
```

结构：

```text
TCP 443 -> Nginx
          ├── 伪装网站
          ├── base64 订阅
          └── 随机 path -> Xray XHTTP 本地端口
```

---

### 3. Xray Hysteria2

UDP 高速备用协议。

```text
CDN: no
默认端口: UDP 443，可自定义
用途: UDP / QUIC 高速备用
```

可选端口跳跃：

```text
UDP 20000-20100 -> UDP 443
```

---

### 4. VLESS + REALITY + Vision

可选备用协议，不默认生成。

```text
CDN: no
默认端口: TCP 3443，可自定义
用途: 测速、排障、低延迟兜底
```

---

### 5. XHTTP CDN + REALITY 分离实验模式

高级实验功能，不默认生成。

```text
用途: 高级上下行分离 / CDN 与 REALITY 混合测试
```

---

## Cloudflare CDN 端口限制

只有 CDN 协议端口会被限制。

`VLESS + XHTTP + TLS + CDN` 只能选择 Cloudflare 支持的 HTTPS 代理端口：

```text
443
2053
2083
2087
2096
8443
```

其他非 CDN 协议端口只是默认推荐，可以自定义：

```text
XHTTP + REALITY 默认 TCP 2443，可自定义
Hysteria2 默认 UDP 443，可自定义
REALITY + Vision 默认 TCP 3443，可自定义
```

---

## 域名要求

脚本要求输入三段式或以上母域名，例如：

```text
1.example.com
us1.node.example.com
kr1.proxy.example.com
```

不建议直接使用二段根域名：

```text
example.com
0x0000.top
```

假设输入：

```text
1.example.com
```

脚本会按需管理：

```text
1.example.com
v4.1.example.com
v6.1.example.com
```

---

## Cloudflare API Token 要求

建议使用 Restricted API Token，不要使用 Global API Key。

推荐权限：

```text
Zone:Read
DNS:Edit
```

作用范围建议限制到目标 Zone。

脚本会把 Cloudflare 配置保存在：

```text
/root/.xray-anti-block/cloudflare.env
```

权限会设置为：

```text
600
```

---

## 证书策略

脚本默认使用 DNS-01 方式申请证书。

默认申请：

```text
1.example.com
*.1.example.com
```

这样可以覆盖：

```text
1.example.com
v4.1.example.com
v6.1.example.com
```

---

## 默认端口规划

```text
TCP 443:
  Nginx + XHTTP/TLS/CDN + 伪装站 + 订阅

TCP 2443:
  VLESS + XHTTP + REALITY

UDP 443:
  Xray Hysteria2

UDP 20000-20100:
  Hysteria2 端口跳跃，可选

TCP 3443:
  VLESS + REALITY + Vision，可选
```

注意：非 CDN 协议的端口不是强制固定，只是默认推荐。

---

## BestCF

BestCF 默认关闭。

启用后：

```text
只使用优选域名
不使用优选 IP
```

用法：

```text
server/address = BestCF 优选域名
serverName/SNI = 你的母域名
Host = 你的母域名
```

示例：

```text
server = bestcf.example
servername = 1.example.com
host = 1.example.com
```

普通 CDN 节点：

```text
server = 1.example.com
servername = 1.example.com
host = 1.example.com
```

BestCF 节点：

```text
server = 优选域名
servername = 1.example.com
host = 1.example.com
```

---

## 订阅

脚本对外只生成 base64 订阅。

本机订阅示例：

```text
https://1.example.com/sub/xxxxxxxxxxxxxxxx
```

本地文件：

```text
/root/.xray-anti-block/subscription/local.raw
/root/.xray-anti-block/subscription/local.b64
/root/.xray-anti-block/subscription/merged.raw
/root/.xray-anti-block/subscription/merged.b64
/root/.xray-anti-block/subscription/mihomo-reference.yaml
```

其中：

```text
local.raw              本机原始分享链接
local.b64              本机 base64 订阅
merged.raw             整合后的原始链接
merged.b64             整合后的 base64 订阅
mihomo-reference.yaml  本地参考片段，不作为默认订阅发布
```

---

## 多机订阅整合

脚本支持添加远程 base64 订阅，然后整合成本机总订阅。

流程：

```text
1. 添加远程 base64 订阅地址
2. 拉取远程订阅
3. 解码远程订阅
4. 合并本机节点
5. 去重
6. 重新生成 merged.b64
```

最终仍然只输出 base64 订阅。

---

## 本机防火墙策略

如果系统原本没有启用本机防火墙，脚本不会主动安装或启用防火墙。

如果检测到已有防火墙：

```text
ufw active       -> 自动 ufw allow 所需端口
firewalld active -> 自动 firewall-cmd 放行所需端口
```

云厂商安全组无法自动处理，需要手动确认放行。

常见需要放行：

```text
TCP 443
TCP 2443
UDP 443
UDP 20000-20100
TCP 3443，可选
```

---

## 使用流程

首次部署建议选择：

```text
1. 首次部署向导
```

大致流程：

```text
1. 安装依赖
2. 安装 / 升级 Xray-core
3. 更新 geoip.dat / geosite.dat
4. 配置 Cloudflare API
5. 输入母域名
6. 查询 IPv4 / IPv6 / ASN
7. 选择协议组合
8. 创建 DNS 记录
9. 申请证书
10. 生成 Xray 配置
11. 配置 Nginx 伪装站
12. 配置 Hysteria2
13. 配置端口跳跃
14. 处理本机防火墙
15. 生成 base64 订阅
16. 输出部署摘要
```

---

## 菜单预览

```text
===== Xray Anti-Block Manager Alpha R3 =====

1. 首次部署向导，推荐
2. 安装/升级基础依赖
3. 安装/升级 Xray-core
4. 更新 geoip.dat / geosite.dat
5. 网络优化 / BBR 状态与稳定优化
6. Cloudflare 域名 / DNS / 小云朵管理
7. 证书申请 / 续签 / 自动部署
8. 查询 IPv4 / IPv6 / ASN 辅助报告
9. 选择协议组合并生成 Xray 配置
10. 配置 CDN / Nginx / 伪装站
11. BestCF 优选域名管理，默认关闭
12. 配置 Hysteria2 端口跳跃
13. 本机防火墙端口处理
14. 订阅管理 / 多机汇总
15. 查看服务状态
16. 查看分享链接 / 订阅链接
17. 重启服务
18. 部署摘要
0. 退出
```

---

## 安全提示

* 不要公开 Cloudflare API Token
* 不建议使用 Cloudflare Global API Key
* 建议使用 Restricted API Token
* 不要提交 `/root/.xray-anti-block/` 目录内容
* 不要提交证书私钥
* 不要公开订阅 token
* 建议先在测试 VPS 上运行
* Hysteria2 属于较新功能，客户端兼容性需要实测
* XHTTP 分享链接在不同客户端上的兼容性可能不同

---

## 检查脚本格式

如果从 GitHub 拉下来的脚本不能运行，先检查：

```bash
wc -l xem.sh
head -n 5 xem.sh
bash -n xem.sh
```

如果脚本只有十几行，或者第一行塞了大量内容，说明上传时换行损坏，需要重新上传。

---

## 仓库建议结构

```text
xray-edge-manager/
├── xem.sh
├── README.md
├── LICENSE
├── SECURITY.md
├── .gitignore
└── examples/
    └── cloudflare-token-permissions.md
```

---

## 建议添加 `.gitignore`

```gitignore
*.env
*.ini
*.log
*.bak
.DS_Store

cloudflare.env
cloudflare.ini
state.env

/root/
.xray-anti-block/
```

---

## License

建议使用 MIT License。

```text
MIT License
```

---

## 状态

当前项目处于 Alpha 阶段。

优先需要实机验证：

```text
1. Xray Hysteria2 配置字段兼容性
2. XHTTP 分享链接客户端兼容性
3. v4/v6 出口绑定行为
4. Cloudflare DNS 自动管理
5. Nginx XHTTP 反代行为
6. Hysteria2 端口跳跃持久化
```

```
```
