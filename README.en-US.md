# xray-edge-manager

One-click deployment of **Xray-core Edge Anti-Blocking Nodes** on VPS: REALITY Direct + Cloudflare CDN Relay + Xray Hysteria2 (HY2) + BestCF Optimized Entry + Nginx Camouflage Site/Subscription + Optional WARP Outbound.

Current script version: `v0.0.36-rc22-production-ready` (The repository entry script is generally `xem.sh`).

---

## What it does

| Capability | Description |
|------|------|
| **REALITY Direct** | Protocol 1: VLESS + XHTTP + REALITY (Default TCP `2443`); Protocol 4: VLESS + REALITY + Vision (Default TCP `3443`) |
| **CDN Relay** | Protocol 2: VLESS + XHTTP + TLS, routed through Nginx origin, using the Cloudflare proxied base domain |
| **BestCF Optimization** | Protocol 5: Reuses CDN inbound, generates BestCF optimized domain/IP entry nodes in the subscription |
| **Hysteria2** | Protocol 3: Xray built-in HY2 (UDP, default `443`, can coexist with Nginx TCP 443) |
| **Camouflage + Subscription** | Nginx random blog camouflage site; base64 subscriptions published to Web; optional remote subscription merging |
| **WARP Outbound** | For pure IPv6 / when IPv4 egress is needed, use `warp-reg` to automatically generate WireGuard outbound |
| **Operations** | Cloudflare DNS role model, DNS-01 certificates, origin-only CF relay, HY2 port hopping, scheduled geodata updates |

This is **not** a Docker / sing-box all-in-one suite; the runtime is primarily based on **Xray-core + Nginx**, and HY2 is provided by **Xray's Hysteria2 inbound** (not a standalone hysteria2 daemon).

---

## Current Technology Stack

```
Client
  ├─ REALITY / Vision  ──DNS-only──► v4./v6.<BASE>  :2443/:3443  ──► Xray
  ├─ CDN / BestCF      ──CF Proxy──► <BASE>          :443        ──► Nginx ──► Xray (127.0.0.1)
  └─ HY2               ──DNS-only──► v4./v6.<BASE>  :443/UDP    ──► Xray

Certificates: certbot + Cloudflare DNS-01  →  /etc/letsencrypt + synchronized to Xray readable directory
Outbound: freedom / Optional WARP (out-warp)
State: /root/.xray-edge-manager/state.env
```

| Component | Path / Role |
|------|-------------|
| Xray | `/usr/local/etc/xray/config.json`, user `xray` |
| Nginx | `/etc/nginx/conf.d/xray-edge-manager.conf` |
| Camouflage Site + Subscription Web Root | `/var/www/xray-edge-manager/` |
| Subscription Files | `/var/www/xray-edge-manager/sub/<TOKEN>` |
| Local Subscription Source | `/root/.xray-edge-manager/subscription/` |
| State / BestCF / WARP | `/root/.xray-edge-manager/` |
| Local Command | `/usr/local/bin/xem` (will prompt to solidify after first curl run) |

---

## Domain Role Model (Important)

Cloudflare only proxies **TCP 80/443** (and a few alternative HTTPS ports). It **does not proxy UDP, nor does it proxy non-standard direct ports like 2443**.

| Name | DNS | Purpose |
|------|-----|------|
| `BASE_DOMAIN` (e.g., `jparm.example.com`) | A/AAAA, **proxied=true** (Orange Cloud) | Subscription URL, Camouflage site, CDN/BestCF entry |
| `v4.BASE_DOMAIN` | **A only**, proxied=false | IPv4 **Direct** nodes (REALITY / Vision / HY2) |
| `v6.BASE_DOMAIN` | **AAAA only**, proxied=false | IPv6 **Direct** nodes |

Therefore:

- **REALITY / HY2 / Vision** link hostnames use `v4.` / `v6.` (resolved directly to machine IP); **do not** use the CF proxied base domain.
- **CDN / BestCF** uses the base domain or optimized CF edge addresses; the TLS SNI / host remains the base domain.

---

## Installation

Requirements: **root** access, public IPv4 and/or IPv6, a Cloudflare-managed domain (zone-level API Token), and an Ubuntu/Debian-based system.

### One-Click (GitHub Raw)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh)
```

After entering the menu, select **`1. First-time Deployment Wizard`**.

### Download and Execute (Recommended for Production)

```bash
curl -fsSL -o /tmp/xem.sh https://raw.githubusercontent.com/0x1233333/xray-edge-manager/main/xem.sh
# Optional: Verify SHA256
install -m 755 /tmp/xem.sh /usr/local/bin/xem
xem
```

### Environment Variables (Optional)

| Variable | Meaning |
|------|------|
| `XEM_SCRIPT_RAW_URL` | Override the script Raw URL used for self-installation / cron tasks (branch/fork) |
| `XEM_SELF_SHA256` | Force SHA256 validation when installing local `xem` |
| `XEM_TRUST_REMOTE_SELF=1` | Skip confirmation for "solidifying local command from remote" |
| `XEM_WARP_ENDPOINT_IPV4` / `XEM_WARP_ENDPOINT_IPV6` | Override WARP endpoints |

### Cloud Provider Security Groups (Required)

The script only attempts to open ports on the local machine **if ufw/firewalld is enabled**; it **will not** default to a blanket `ACCEPT` for all inbound traffic via iptables. For Oracle / AWS etc., you must also open these in the Security Group/NSG:

| Direction | Port | Purpose |
|------|------|------|
| TCP | `80` | Nginx HTTP→HTTPS; CF Origin (if origin restriction is enabled, 80 is also used) |
| TCP | `443` (or your chosen CF HTTPS port) | Subscription / Camouflage / CDN |
| TCP | `2443` (or your REALITY port) | XHTTP+REALITY |
| TCP | `3443` (if Vision is enabled) | REALITY+Vision |
| UDP | `443` (or your HY2 port) | Hysteria2 |
| UDP | Hopping range (if enabled, e.g., `20000-20100`) | HY2 Port Hopping |

---

## Configuration Flow (First-time Deployment Wizard)

1. **Install Dependencies** + **Xray-core** + geodata  
2. **Base Domain** `BASE_DOMAIN` (Recommended $\ge 3$ segments, e.g., `jparm.0x0000.top`)  
3. **Cloudflare API Token** (Zone DNS Edit + used for certbot DNS-01)  
4. **Node Display Name**  
5. **ASN/IP Report** (Assists in choosing REALITY camouflage target)  
6. **IPv4 / IPv6 Protocol Stack Strategy** (Choose `0/1/2/3/4/5` per stack or combinations like `123`)  
7. **Ports**: CDN/Subscription HTTPS, REALITY, Vision, HY2  
8. **Outbound Strategy**: `auto` (Recommended) / `force-v4` / `warp-v4` / `stack` / `none`  
9. **DNS**: Write roles for BASE / v4 / v6  
10. **Certificates**: Let’s Encrypt + Cloudflare DNS-01 (`BASE` + `*.BASE`)  
11. **REALITY Target** (Camouflage site target, with blacklist and cert chain length validation)  
12. Generate Xray / Nginx, optional HY2 hopping, firewall, and CF origin restrictions  
13. Restart services $\rightarrow$ Generate subscription $\rightarrow$ Production self-check $\rightarrow$ Summary  

Daily maintenance: use `xem` menu, or:

```bash
xem --healthcheck
xem --bestcf-update
xem --geodata-update
xem --apply-hy2-hopping
xem --apply-cf-origin-firewall
```

---

## Protocol Description

| No. | Name | Transport | Default Port | Hostname |
|------|------|------|----------|--------|
| **1** | VLESS + XHTTP + REALITY | TCP Direct | `2443` | `v4.` / `v6.` |
| **2** | VLESS + XHTTP + TLS + CDN | CF $\rightarrow$ Nginx $\rightarrow$ Local Xray | `443` | `BASE_DOMAIN` |
| **3** | Xray Hysteria2 | UDP | `443` | `v4.` / `v6.` |
| **4** | VLESS + REALITY + Vision | TCP Direct, `flow=xtls-rprx-vision` | `3443` | `v4.` / `v6.` |
| **5** | CDN / BestCF Entry Extension | Shares CDN inbound with Protocol 2 | `443` | BestCF optimized or `BASE` |

Recommended combinations:

- Anti-blocking main: `1` + `5` (REALITY Direct + BestCF CDN Backup)  
- Full stack: `1235` or `12345`  
- CDN only: `2` or `5`

### Protocol 5 = BestCF Optimized CDN

- When **5** is selected, the script **automatically enables BestCF** (default domain mode, limited to a few optimized nodes to avoid subscription bloat).  
- Before generating the subscription, it attempts to pull the list published by [DustinWin/BestCF](https://github.com/DustinWin/BestCF).  
- If no usable data is found remotely or locally, it **falls back** to the base domain CDN Entry to avoid empty nodes.  
- Menu **11** allows switching modes (domain / ISP domain etc.), limits, and scheduled refreshes.  
- Protocol **2** can also include optimized nodes after manually enabling `BESTCF_ENABLED`; the semantics of **5** specifically mean "Entry Extension + BestCF".

---

## REALITY Camouflage Target Selection

During installation, a recommended list will be provided based on region/ASN (e.g., Japan: yahoo.co.jp, amazon.co.jp, rakuten...; USA: ebay, oracle, amazon...), along with quick-select options:

1. `www.ebay.com`  
2. `www.oracle.com`  
3. `www.amazon.com`  
4. Manual input (forced validation)

Principle: Choose a target from a **large company, with a short certificate chain, and that the local machine can probe via TCP 443**. Avoid domains with excessively large certificates or known incompatibilities.

### `REALITY_BLACKLIST`

Xray REALITY has a buffer limit for the target site's TLS certificate chain (approximately **8192 bytes**). The script includes a global blacklist (modifiable in the script array):

```bash
REALITY_BLACKLIST=("www.microsoft.com" "microsoft.com" "login.microsoftonline.com")
```

`validate_reality_target` behavior:

- **Case-insensitive** match against the blacklist.  
- Uses `openssl s_client -showcerts` to probe the full certificate chain length.  
- Rejects if chain length is **> 7800** bytes (leaving a safety margin).  
- If probing fails / openssl is not installed $\rightarrow$ **fail-closed** (rejects the target to avoid non-functional setups).  
- Quick-select options and manual inputs are both subject to this validation.

---

## Subscriptions

- Local subscription: `https://<BASE_DOMAIN>/sub/<SUB_TOKEN>`  
- Merged subscription (local + remote list): `https://<BASE_DOMAIN>/sub/<MERGED_SUB_TOKEN>`  
- Web file directory: `/var/www/xray-edge-manager/sub/` (**not** `/usr/local/etc/xray/www/sub/`)  
- Original node list: `/root/.xray-edge-manager/subscription/local.raw`  
- Mihomo reference snippet: `.../subscription/mihomo-reference.yaml` (for reference only; base64 is still used for distribution)

Menu **14** manages remote subscription merging, token rotation, and regeneration.

---

## Clash Meta / Mihomo Compatibility

External subscriptions are provided as **universal base64 node links**, and a Mihomo reference YAML is generated simultaneously.

| Protocol | Share Link Key Points | Client Requirement |
|------|----------------|------------|
| XHTTP + REALITY | `type=xhttp`, `security=reality`, `mode=auto` | **Clash Meta / Mihomo recent dev kernels** (must support xhttp) |
| XHTTP + CDN | `type=xhttp`, `security=tls`, `host`/`sni`=base domain | Same as above |
| Vision | `type=tcp`, `flow=xtls-rprx-vision`, `security=reality` | Standard Meta REALITY+Vision support |
| HY2 | `hysteria2://`, `alpn=h3`, optional `mport` hopping | Client must have **Hysteria2** implementation; **old Clash kernels are insufficient** |

Recommended clients: **Clash Verge Rev / Mihomo (new meta kernels)**, v2rayN / sing-box etc., that have implemented xhttp and HY2.  
This script **does not use WebSocket (ws)** as the main transport; both CDN and direct modes primarily use **xhttp**.

---

## Menu Quick Reference

| Item | Function |
|----|------|
| 1 | First-time Deployment Wizard |
| 2–4 | Dependencies / Xray / geodata |
| 5 | BBR / Stable sysctl |
| 6–7 | Cloudflare DNS / Certificates |
| 9 | Re-select v4/v6 protocols and refresh full stack |
| 10 | Reconfigure Nginx / Camouflage / Subscription path / CDN origin only |
| 11 | BestCF |
| 12 | HY2 Port Hopping |
| 13 | Local firewall + optional "CF Origin Only" |
| 14 | Subscription Management |
| 15–19 | Status / Links / Restart / Summary / Installation Status |
| 20 | Uninstall |
| 21 | WARP Outbound |
| 22 | Production Self-check |

---

## Known Limitations

1. **HY2 requires a client kernel that supports Hysteria2**  
   The server-side is Xray's HY2 inbound, not a standalone `hysteria` binary. Old Clash Premium or clients supporting only hy1 will not connect.

2. **Cloudflare does not proxy UDP, nor direct connections on non-CF HTTPS ports**  
   - HY2 (UDP) must use `v4.`/`v6.` DNS-only (or direct IP); do not rely on the proxied base domain.  
   - REALITY `2443` / Vision `3443` are the same; they must be direct connections.  
   - Only Protocol 2/5 on TCP 443 (and CF-supported HTTPS ports) are suitable for CDN.

3. **Local Firewall**  
   If ufw/firewalld is not enabled, the script **will not** automatically open inbound ports via iptables; ensure you open them in your cloud security group. After enabling "CF Origin Only", non-CF IP access to TCP 80/443 will be dropped (**this does not affect** HY2 UDP and REALITY direct ports).

4. **Certificate application depends on Cloudflare DNS API**  
   Uses DNS-01, not relying on local port 80 for HTTP-01; however, Nginx still listens on 80 for redirects, so it is recommended to open port 80 in the security group for production.

5. **REALITY target must be probe-able by the local machine**  
   If outgoing traffic is blocked or the target is unreachable, validation will fail-closed; you must choose a reachable large-company domain.

6. **BestCF data depends on upstream GitHub Releases**  
   If the pull fails, Protocol 5 falls back to the base domain CDN, and the optimization effect will temporarily disappear.

7. **First run via curl pipe**  
   The process runs from `/dev/fd`. When solidifying `/usr/local/bin/xem`, it may pull the Raw script again; for production, it is recommended to save the file first and then `install`, or set `XEM_SELF_SHA256`.

8. **Oracle ARM etc.**  
   Pay attention to security lists, complete IPv6 connectivity, and whether UDP 443 is dropped by the ISP/Security Group; for HY2 issues, check UDP and client kernels first.

---

## Security Tips

- Use a **least-privilege** CF API Token; rotate it after deployment.  
- Subscription URLs contain long random tokens; do not submit them to public repositories. Use the menu to rotate tokens if a leak is suspected.  
- State files and keys are in `/root/.xray-edge-manager/` and should be root-only.  
- Enabling CF origin restriction reduces the risk of the origin IP being scanned for subscriptions or the camouflage site.  
- This project **does not embed** any personal domains, emails, IPs, or Tokens.

---

## Uninstallation

Menu **20**: Cleans Xray configurations, Nginx sites, web root, DNS records, certificates, the local `xem` binary, and the state directory. Please confirm you no longer need the nodes and subscriptions before executing.

---

## License & Acknowledgments

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)  
- [DustinWin/BestCF](https://github.com/DustinWin/BestCF)  
- [badafans/warp-reg](https://github.com/badafans/warp-reg)  
- Cloudflare / Let’s Encrypt / Nginx  

Repository: <https://github.com/0x1233333/xray-edge-manager>

---

## Quick Validation Checklist (Post-Deployment)

```bash
xem --healthcheck
# or menu 22 / 16

# Local machine
ss -lntup | egrep ':(80|443|2443)\s'
curl -fsS "https://<BASE_DOMAIN>/sub/<SUB_TOKEN>" | head -c 40; echo

# Client
# - REALITY: Host v4.<BASE>, Port 2443
# - CDN/BestCF: Host as optimized or <BASE>, Port 443
# - HY2: Host v4.<BASE>, UDP 443, requires Meta/HY2 kernel
```
