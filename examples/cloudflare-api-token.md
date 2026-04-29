可以把下面这份保存为：

```text
examples/cloudflare-api-token.md
```

Cloudflare 官方文档说明 API Token 可以从 Dashboard 的 **My Profile > API Tokens > Create Token** 创建，并且 Token 权限可以按 Zone / Account / User 分类限制；Certbot 的 Cloudflare DNS 插件也推荐使用受限 API Token，并要求对应 Zone 的 DNS Edit 权限。([Cloudflare Docs][1])

````markdown
# Cloudflare API Token 申请与脚本使用教程

本文说明如何为 `xray-edge-manager` 创建 Cloudflare API Token，以及在脚本中应该如何填写。

> 不要使用 Global API Key。  
> 推荐使用 Restricted API Token，并且只授权到需要管理的单个域名 Zone。

---

## 1. 这个 Token 用来做什么？

脚本需要 Cloudflare API Token 来完成这些操作：

- 查询 Cloudflare Zone
- 创建 / 更新 DNS 记录
- 设置 DNS 记录为橙云或灰云
- 配合 DNS-01 方式申请证书

脚本会管理类似下面的域名结构：

```text
node.example.com       CDN / 伪装站 / 订阅域名
v4.node.example.com    IPv4 灰云直连
v6.node.example.com    IPv6 灰云直连
````

其中：

```text
node.example.com
```

是脚本里的 **母域名 / BASE_DOMAIN**。

而：

```text
example.com
```

是 Cloudflare 里托管的 **Zone Name**。

这两个不要填反。

---

## 2. 你需要准备什么？

你需要提前准备：

```text
1. 一个已经托管到 Cloudflare 的域名
2. 一个三段式或以上的节点母域名
3. 一个 Cloudflare Restricted API Token
```

示例：

```text
Cloudflare Zone Name:
example.com

脚本母域名 / BASE_DOMAIN:
node.example.com
```

不要直接把根域名当作节点母域名使用：

```text
example.com      不推荐
node.example.com 推荐
```

---

## 3. 创建 Cloudflare API Token

### 第一步：进入 API Token 页面

登录 Cloudflare 后台，然后进入：

```text
右上角头像 / My Profile
  -> API Tokens
  -> Create Token
```

也可以在某个域名页面右侧的 API 区域点击：

```text
Get your API token
```

注意：

```text
Zone ID 不是 API Token
Account ID 也不是 API Token
```

脚本要你输入的是 **API Token**。

---

## 4. 推荐创建方式：使用 Edit zone DNS 模板

进入 Create Token 后，可以选择模板：

```text
Edit zone DNS
```

然后继续编辑权限和资源范围。

---

## 5. 权限应该怎么设置？

推荐权限：

```text
Zone / Zone / Read
Zone / DNS  / Edit
```

含义：

| 权限          | 用途                 |
| ----------- | ------------------ |
| `Zone:Read` | 让脚本查询目标域名的 Zone ID |
| `DNS:Edit`  | 让脚本创建 / 修改 DNS 记录  |

不要给多余权限。

---

## 6. Zone Resources 应该怎么选？

这里非常重要。

建议选择：

```text
Include -> Specific zone -> example.com
```

不要选择：

```text
All zones
```

除非你明确知道自己在做什么。

示例：

```text
Zone Resources:
Include
Specific zone
example.com
```

如果这里选错域名，脚本后面会提示找不到 Zone ID 或无法管理 DNS。

---

## 7. 创建并复制 Token

确认权限后，点击：

```text
Continue to summary
Create Token
```

Cloudflare 会显示一串 Token。

请立刻复制保存。

注意：

```text
Token 通常只完整显示一次。
不要发给别人。
不要提交到 GitHub。
不要写进 README。
不要写进 Issue。
不要写进截图。
```

---

## 8. 在脚本里怎么填写？

运行脚本后，会看到类似提示：

```text
请输入 Cloudflare Restricted API Token，需 Zone:Read + DNS:Edit:
```

这里填：

```text
你刚刚创建的 API Token
```

不要填：

```text
Zone ID
Account ID
Global API Key
```

之后脚本会问：

```text
请输入 Cloudflare Zone Name，例如 example.com:
```

这里填 Cloudflare 托管的根域名，例如：

```text
example.com
```

不是：

```text
node.example.com
```

---

## 9. BASE_DOMAIN 和 Zone Name 的区别

这两个概念很容易混淆。

### BASE_DOMAIN

脚本里的母域名，例如：

```text
node.example.com
```

脚本会基于它生成：

```text
node.example.com
v4.node.example.com
v6.node.example.com
```

### Zone Name

Cloudflare 里托管的域名，例如：

```text
example.com
```

脚本会用 Zone Name 去 Cloudflare 查询 Zone ID。

---

## 10. 正确填写示例

假设你准备使用：

```text
node.example.com
```

作为这台服务器的母域名。

那么脚本里应该这样填：

```text
母域名 / BASE_DOMAIN:
node.example.com

Cloudflare API Token:
粘贴你创建的 Restricted API Token

Cloudflare Zone Name:
example.com
```

脚本会自动创建或更新：

```text
node.example.com
v4.node.example.com
v6.node.example.com
```

---

## 11. 脚本会把 Token 保存在哪里？

脚本会保存到：

```text
/root/.xray-anti-block/cloudflare.env
```

权限会设置为：

```text
600
```

也就是只有 root 可读写。

不要把这个文件提交到 GitHub。

建议 `.gitignore` 里包含：

```gitignore
cloudflare.env
cloudflare.ini
state.env
/root/
.xray-anti-block/
```

---

## 12. 常见错误

### 错误 1：把 Zone ID 当成 Token 填进去

错误示例：

```text
请输入 Cloudflare Restricted API Token:
这里填了 Zone ID
```

结果：

```text
Cloudflare API 查询失败
```

解决：

```text
重新创建或复制 API Token，不要填 Zone ID。
```

---

### 错误 2：Zone Name 填成了母域名

错误示例：

```text
Cloudflare Zone Name:
node.example.com
```

如果 Cloudflare 托管的是：

```text
example.com
```

那么这里应该填：

```text
example.com
```

不是：

```text
node.example.com
```

---

### 错误 3：Token 的 Zone Resources 选错了域名

如果脚本提示：

```text
未查到 Zone ID
```

请检查创建 Token 时：

```text
Zone Resources
```

是否包含了正确的 Zone。

正确示例：

```text
Include -> Specific zone -> example.com
```

---

### 错误 4：复制 Token 时带了空格或换行

脚本已经会自动清理 Token 前后的隐藏空白字符。

但如果仍然失败，可以重新复制 Token，确认没有复制多余内容。

---

### 错误 5：用了 Global API Key

不推荐使用 Global API Key。

如果脚本检测到疑似 Global API Key，会提示风险，并要求你手动确认。

推荐重新创建 Restricted API Token。

---

## 13. 如何验证 Token 是否可用？

脚本会自动验证：

```text
1. 是否能查询目标 Zone
2. 是否能读取 DNS 记录
3. 后续是否能创建 / 更新 DNS 记录
```

如果权限不足，脚本会中止，不会继续乱改 DNS。

---

## 14. 安全建议

* 使用 Restricted API Token
* 只授权目标 Zone
* 只给 `Zone:Read` 和 `DNS:Edit`
* 不要使用 Global API Key
* 不要公开 API Token
* 不要把 Token 写进仓库
* 不要把 `/root/.xray-anti-block/` 上传到 GitHub
* 如果 Token 泄露，立刻在 Cloudflare 后台删除并重新创建

---

## 15. 最小权限总结

推荐最终配置：

```text
Token type:
Restricted API Token

Permissions:
Zone / Zone / Read
Zone / DNS  / Edit

Zone Resources:
Include -> Specific zone -> example.com
```

脚本填写：

```text
BASE_DOMAIN:
node.example.com

Cloudflare API Token:
你的 Restricted API Token

Cloudflare Zone Name:
example.com
```

```
::contentReference[oaicite:1]{index=1}
```

[1]: https://developers.cloudflare.com/fundamentals/api/get-started/create-token/?utm_source=chatgpt.com "Create API token - Cloudflare Fundamentals"
