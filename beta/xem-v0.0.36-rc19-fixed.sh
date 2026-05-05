已按你的意见生成 **rc19 完整修复版**，并通过：

```bash
bash -n /mnt/data/xem-v0.0.36-rc19-fixed.sh
```

下载完整脚本：
[xem-v0.0.36-rc19-fixed.sh](sandbox:/mnt/data/xem-v0.0.36-rc19-fixed.sh)

对比补丁：
[xem-v0.0.36-rc19-fixed.patch](sandbox:/mnt/data/xem-v0.0.36-rc19-fixed.patch)

SHA256：

```text
9f7c1584b78b6f1a5bb116b432d47904b7ac3e5d6c5049fb81d29a031c801e66  xem-v0.0.36-rc19-fixed.sh
e85e29eb9007e669aad466d4cdb375d32c0228ca84786c9b245b67db131316cb  xem-v0.0.36-rc19-fixed.patch
```

这版处理方式：

* **Cloudflare DNS 同名记录删除逻辑保留**，但新增明确提示：`BASE_DOMAIN / v4.BASE_DOMAIN / v6.BASE_DOMAIN` 必须由本脚本独占，不能被其它网站、邮箱、负载均衡或 DNS 自动化共用。
* **远程订阅协议白名单不扩展**，继续只保留：`vless://`、`vmess://`、`trojan://`、`ss://`、`hysteria2://`、`hy2://`。
* 修复远程订阅 DNS rebinding：先解析并检查 IP，再用 `curl --resolve host:port:ip` 固定到已检查 IP。
* 远程订阅解析不到 IP 时直接拒绝，不再交给 curl 自己解析。
* `valid_remote_url_host()` 改成只接受标准域名，裸 IP 继续拒绝。
* `validate_base_domain()` 增加 253 总长度限制。
* `cf_upsert_record()` 增加 `CF_API_TOKEN + CF_ZONE_ID` 完整检查，并校验 Cloudflare 查询 `.success == true`。
* `node_ready()` 改成读取当前 `$XRAY_CONFIG` 和 `$NGINX_SITE` 实际内容，避免 READY state 与实际配置不一致时发布错误订阅。
