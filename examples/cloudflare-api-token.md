
这版是**中文 Cloudflare 界面版**，并且完全脱敏，只使用 `example.com` / `node.example.com`。Cloudflare 官方文档说明，API Token 可以通过模板或自定义方式创建；`Edit Zone DNS / 编辑区域 DNS` 模板用于给指定 Zone 的 DNS 写入权限，Token secret 创建后只显示一次，需要妥善保存。([Cloudflare Docs][1])

````markdown
# Cloudflare API 令牌申请与脚本使用教程

本文说明如何在 Cloudflare 中文界面中创建 `xray-edge-manager` 所需的 API 令牌，以及在脚本中应该如何填写。

> 推荐使用 **API 令牌 / API Token**。  
> 不推荐使用 **Global API Key / 全局 API 密钥**。  
> 不要把 API Token、订阅 Token、证书私钥提交到 GitHub。

---

## 1. 这个 API 令牌用来做什么？

`xray-edge-manager` 需要 Cloudflare API Token 来完成这些操作：

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

是脚本里的：

```text
母域名 / BASE_DOMAIN
```

而：

```text
example.com
```

是 Cloudflare 里托管的：

```text
区域名称 / Zone Name
```

这两个不要填反。

---

## 2. 你需要准备什么？

你需要提前准备：

```text
1. 一个已经托管到 Cloudflare 的域名
2. 一个三段式或以上的节点母域名
3. 一个 Cloudflare API 令牌
```

示例：

```text
Cloudflare 区域名称 / Zone Name:
example.com

脚本母域名 / BASE_DOMAIN:
node.example.com
```

不要直接把根域名当作节点母域名使用：

```text
example.com       不推荐
node.example.com  推荐
```

---

## 3. 进入 API 令牌页面

登录 Cloudflare 后台后，进入：

```text
右上角头像
  -> 我的个人资料
  -> 访问管理
  -> API 令牌
```

然后点击：

```text
创建令牌
```

你会看到类似页面：

```text
创建 API 令牌
选择模板以开始或从头创建自定义令牌

自定义令牌
创建自定义令牌

API 令牌模板
编辑区域 DNS
读取账单信息
读取分析数据和日志
...
```

这里推荐选择模板：

```text
编辑区域 DNS
```

不要选择：

```text
创建自定义令牌
```

除非你很清楚每一项权限该怎么配。

---

## 4. 选择“编辑区域 DNS”模板

在模板列表中找到：

```text
编辑区域 DNS
```

点击它右侧的按钮进入创建页面。

进入后，你会看到类似内容：

```text
创建令牌

令牌名称: 编辑区域 DNS

权限
资源: 区域
权限: DNS
编辑

区域资源
包括
特定区域
Select...

客户端 IP 地址筛选

TTL
```

---

## 5. 令牌名称怎么填？

可以保持默认：

```text
编辑区域 DNS
```

也可以改成通用名称，例如：

```text
xray-edge-manager
```

不要写真实节点名、真实服务器名或任何个人信息。

推荐：

```text
xray-edge-manager
```

---

## 6. 权限怎么设置？

你现在通常会看到默认权限：

```text
资源: 区域
权限: DNS
编辑
```

这条保留。

然后建议点击：

```text
添加更多
```

再添加一条权限：

```text
资源: 区域
权限: 区域
读取
```

最终建议权限是两条：

```text
区域 / DNS  / 编辑
区域 / 区域 / 读取
```

含义：

| 中文界面          | 英文概念               | 用途                 |
| ------------- | ------------------ | ------------------ |
| 区域 / DNS / 编辑 | Zone / DNS / Edit  | 创建、更新、删除 DNS 记录    |
| 区域 / 区域 / 读取  | Zone / Zone / Read | 让脚本查询目标域名的 Zone ID |

---

## 7. 区域资源怎么选？

这里非常重要。

找到：

```text
区域资源
```

设置成：

```text
包括
特定区域
Select...
```

然后在 `Select...` 里选择你的 Cloudflare 托管根域名。

示例：

```text
example.com
```

注意：

这里选择的是 Cloudflare 托管的根域名：

```text
example.com
```

不是脚本母域名：

```text
node.example.com
```

正确理解：

```text
Cloudflare 区域资源 / Zone:
example.com

脚本母域名 / BASE_DOMAIN:
node.example.com
```

如果这里选错，脚本会提示找不到 Zone ID 或没有权限操作 DNS。

---

## 8. 客户端 IP 地址筛选怎么填？

这个区域可以先不填。

也就是保持默认空白。

原因：

```text
如果你填错 IP，VPS 可能无法使用这个 Token 调用 Cloudflare API。
```

第一次使用建议不要设置 IP 筛选。

等你完全确认 VPS IP 固定、脚本工作正常之后，再考虑限制 IP。

---

## 9. TTL 怎么填？

`TTL` 可以先不填。

也就是保持默认。

如果你设置过期时间，到期后脚本将无法继续使用这个 Token 更新 DNS 或申请证书。

---

## 10. 创建令牌

配置完成后，点击：

```text
继续以显示摘要
```

或者：

```text
继续到摘要
```

在摘要页面确认：

```text
权限:
区域 / DNS  / 编辑
区域 / 区域 / 读取

区域资源:
包括 / 特定区域 / example.com
```

确认无误后点击：

```text
创建令牌
```

---

## 11. 复制 API Token

创建成功后，Cloudflare 会显示一串很长的 Token。

这个才是脚本要你输入的：

```text
Cloudflare API Token
```

注意：

```text
API Token 通常只完整显示一次。
不要发给别人。
不要提交到 GitHub。
不要写进 README。
不要写进 Issue。
不要截图公开。
```

---

## 12. 哪些东西不是 API Token？

不要把这些填到脚本的 Token 输入框：

```text
区域 ID
帐户 ID
Global API Key
域名
邮箱
```

Cloudflare 页面里可能会显示：

```text
区域 ID
帐户 ID
获取您的 API 令牌
API 文档
```

其中：

```text
区域 ID 不是 API Token
帐户 ID 不是 API Token
```

脚本要的是你在 **API 令牌页面创建出来的 Token**。

---

## 13. 脚本里怎么填写？

运行脚本后，会看到：

```text
请输入 Cloudflare Restricted API Token，需 Zone:Read + DNS:Edit:
```

这里粘贴刚才生成的 API Token。

然后脚本会问：

```text
请输入 Cloudflare Zone Name，例如 example.com:
```

这里填 Cloudflare 托管的根域名：

```text
example.com
```

不要填：

```text
node.example.com
```

---

## 14. BASE_DOMAIN 和 Zone Name 的区别

这两个概念最容易混淆。

### BASE_DOMAIN

脚本里的母域名，例如：

```text
node.example.com
```

脚本会基于它管理：

```text
node.example.com
v4.node.example.com
v6.node.example.com
```

### Zone Name

Cloudflare 里托管的区域名称，例如：

```text
example.com
```

脚本会用它去 Cloudflare 查询 Zone ID。

---

## 15. 正确填写示例

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
粘贴你刚创建的 API Token

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

## 16. 脚本会把 Token 保存在哪里？

脚本会把 Cloudflare 配置保存到：

```text
/root/.xray-anti-block/cloudflare.env
```

文件权限会设置为：

```text
600
```

也就是只有 root 可以读写。

不要把这个文件提交到 GitHub。

建议 `.gitignore` 包含：

```gitignore
cloudflare.env
cloudflare.ini
state.env
/root/
.xray-anti-block/
```

---

## 17. 常见错误

### 错误 1：把 Zone ID 当成 API Token

错误做法：

```text
请输入 Cloudflare Restricted API Token:
这里填了 Zone ID
```

结果通常是：

```text
Cloudflare API 查询失败
```

正确做法：

```text
去 API 令牌页面创建 Token，然后复制 Token。
```

---

### 错误 2：把 Account ID 当成 API Token

错误做法：

```text
请输入 Cloudflare Restricted API Token:
这里填了 Account ID
```

正确做法：

```text
Account ID 不是 Token。
请创建 API Token。
```

---

### 错误 3：Zone Name 填成了母域名

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

---

### 错误 4：区域资源选错了域名

如果脚本提示：

```text
未查到 Zone ID
```

请检查创建 Token 时：

```text
区域资源
```

是否选择了正确的 Cloudflare Zone。

正确示例：

```text
包括 -> 特定区域 -> example.com
```

---

### 错误 5：复制 Token 时带了空格或换行

脚本会自动清理 Token 里的隐藏空白字符。

但如果仍然失败，请重新复制 Token，确认没有复制到多余内容。

---

### 错误 6：用了 Global API Key

不推荐使用 Global API Key。

如果脚本检测到疑似 Global API Key，会提示风险，并要求你手动确认。

推荐重新创建 Restricted API Token。

---

## 18. 如何验证 Token 是否可用？

脚本会自动验证：

```text
1. 是否能查询目标 Zone
2. 是否能读取 DNS 记录
3. 后续是否能创建 / 更新 DNS 记录
```

如果权限不足，脚本会中止，不会继续修改 DNS。

---

## 19. 安全建议

* 使用 Restricted API Token
* 只授权目标 Zone
* 权限只给 `区域 / DNS / 编辑` 和 `区域 / 区域 / 读取`
* 不要使用 Global API Key
* 不要公开 API Token
* 不要把 Token 写进仓库
* 不要把 `/root/.xray-anti-block/` 上传到 GitHub
* 如果 Token 泄露，立刻在 Cloudflare 后台删除并重新创建

---

## 20. 最小权限总结

推荐最终配置：

```text
令牌类型:
API Token

权限:
区域 / DNS  / 编辑
区域 / 区域 / 读取

区域资源:
包括 -> 特定区域 -> example.com

客户端 IP 地址筛选:
留空

TTL:
留空
```

脚本填写：

```text
BASE_DOMAIN:
node.example.com

Cloudflare API Token:
你的 API Token

Cloudflare Zone Name:
example.com
```

```
::contentReference[oaicite:1]{index=1}
```

[1]: https://developers.cloudflare.com/fundamentals/api/get-started/create-token/?utm_source=chatgpt.com "Create API token - Cloudflare Fundamentals"
