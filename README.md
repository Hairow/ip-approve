# /etc/ip-approve — IP 审批防火墙体系

对 4 组审批端口（见 approved.conf 的 INPUT_APPROVE_PORT4/6、FORWARD_APPROVE_PORT4/6）做「先探测进 pending → 钉钉推送 → 手机一键批准/拒绝」的动态放行体系。**每种情况（input/forward × v4/v6）固定 5 条防火墙规则**（allow → deny → cn-gate → pending → probe-log），见下文「防火墙规则结构」。

## 前置条件

| 依赖 | 用途 | 必需性 |
|------|------|--------|
| OpenWrt/iStoreOS（fw4 + nftables） | 防火墙规则与 ipset 集合 | 必需 |
| LuCI + rpcd | 审批面板（ipapprove.uc 控制器 + menu.d 菜单）、switch.html 走自建 switchboard 控制器 | 必需（面板部分） |
| `/www/cgi-bin/ip-approve` | 实际执行批准/拒绝/黑名单移除（写 nft + 名单文件）的 CGI，LuCI 与钉钉链路共用 | 必需 |
| ucode（luci.controller 框架） | ipapprove.uc 面板接口 | 必需（面板部分） |
| openssl | HMAC-SHA256 签名/验签（钉钉加签 + 快捷链接） | 必需 |
| busybox curl | 推送钉钉 | 必需 |
| busybox logread -f | watch 服务监听内核防火墙日志抓探测源 | 必需 |
| Tailscale（tailscaled，已开 MagicDNS + HTTPS 证书） | Funnel 公网入口 `https://<域名>:443 → 127.0.0.1:50080` | 可选（钉钉一键审批需要） |
| 钉钉群机器人（自定义 webhook + 加签密钥） | 待审批通知与 actionCard 按钮 | 可选（推送通道） |

注：无 QUICK_URL/QUICK_SECRET 或无 Tailscale 时，核心审批链（探测→pending→面板手动批准/拒绝）不受影响，仅失去钉钉一键审批。

## 目录结构

| 文件/目录 | 作用 |
|-----------|------|
| approved.conf | 配置：钉钉 webhook/加签密钥、4 个端口变量（INPUT/FORWARD_APPROVE_PORT4/6）、QUICK_SECRET、QUICK_URL |
| pending.list | 待审批 IP 队列（IP + 时间 + 端口） |
| switch.html | 面板：设备/WAN/磁盘/服务开关 + IP 审批弹层 + IP 黑名单弹层（移除黑名单走 unban action） |
| ip-allow.list / ip-allow6.list | 批准名单（写入 nft ip_allow / ip_allow6） |
| ip-deny.list / ip-deny6.list | 拒绝名单（写入 nft ip_deny / ip_deny6） |
| cgi-bin/ip-approve | 审批执行核心（路由器上位于 /www/cgi-bin/ip-approve）：flock 原子更新 pending/allow/deny 底账与 nft 集合，面板/钉钉/CLI 三入口共用 |
| approved-ip-watch.sh | 监听服务本体：解析探测日志 → nft pending 集合 + pending.list → 推钉钉 |
| sync-approve-firewall.sh | 同步/重建防火墙：各组端口同步 + 缺失 ipset/规则自动重建（改端口变量后运行） |
| cn-ipset/refresh-cn-ipset.sh | 大陆集合刷新脚本：从 PassWall 规则同步 chnroute{,6} 副本 → `fw4 reload-sets`；副本为空则不刷新，避免集合被刷空导致全挡 |
| cn-ipset/chnroute / chnroute6 | 大陆 IPv4/IPv6 路由表副本（运行时数据，不入库；远端位于 /etc/cn-ipset/） |
| quick/cgi-bin/ip-approve-quick | 钉钉按钮的免登录签名 CGI（HMAC + 30 分钟时效 + pending 校验） |
| README.md | 本文件 |

cn 集合在路由器上位于 `/etc/cn-ipset/`，本地仓库仅保留刷新脚本，路由表数据由脚本定时拉取、不入库。

## 服务操作（用 init 脚本，不要裸跑脚本本体）

```
/etc/init.d/approved-ip-watch start|stop|restart|enable|disable   # 监听推送服务
/etc/init.d/ipapprove-http    start|stop|restart|enable|disable   # 50080 签名 CGI 服务（uhttpd）
```

两个服务均已 enable 开机自启（S99）。裸跑 approved-ip-watch.sh（不带参数）会进前台主循环并和 procd 实例打架，禁止。

## 手动维护命令（脚本本体）

```
/etc/ip-approve/approved-ip-watch.sh test <IP>     # 注入测试 IP：进 pending 并推钉钉（用 RFC5737 段，如 203.0.113.50）
/etc/ip-approve/approved-ip-watch.sh backfill      # 把 nft pending 集合已有 IP 回填 pending.list（不推送）
```

## 钉钉推送链路

```
探测审批端口 → approved-ip-watch 写 pending + 推 actionCard（IP+时间+批准/拒绝按钮）
→ 公网 https://istoreos.tailaf168e.ts.net (Tailscale Funnel 443)
→ 127.0.0.1:50080 (uhttpd -f，procd 管理)
→ quick/cgi-bin/ip-approve-quick 验签 → 执行 → 即时生效
```

- Funnel 在路由器上用 `tailscale funnel --bg 50080` 设置，重启后应仍在，失效时重跑该命令
- 按钮链接域名取自 QUICK_URL；清空 QUICK_URL 或 QUICK_SECRET 自动退回纯文本推送
- 已处理 IP 再点旧按钮会显示「已被批准/拒绝」

## 防火墙规则结构（每组固定 5 条）

4 组规则（input v4 / input v6 / forward v4 / forward v6）结构完全同构，每条只差名字前缀（ip4- / ip6- / forward-ip4- / forward-ip6-）和引用的 ipset（v4 组用 ip_allow/ip_deny/ip_pending/cn_ipv4，v6 组用 *6 后缀）。fw4 按 UCI 段顺序进链，链内顺序固定：

| 顺序 | 规则 | 匹配 | 动作 | 作用 |
|------|------|------|------|------|
| 1 | `<前缀>-allow-accept` | 源 ∈ ip_allow 集合 | accept | 已批准名单放行（allow 优先于 deny） |
| 2 | `<前缀>-deny-drop` | 源 ∈ ip_deny 集合 | drop | 已拒绝名单拦截，静默丢弃 |
| 3 | `cn-gate-<前缀>` | 源 ∉ cn_ipv4/cn_ipv6 集合 | drop | 未列名的国外源直接丢弃，不进审核、不记日志 |
| 4 | `<前缀>-pending-reject` | 源 ∈ ip_pending 集合 | reject | 审批中的重复探测，静默拒绝（watch 去重，不重复推送） |
| 5 | `<前缀>-probe-log` | 其余国内来源（无集合匹配） | log + reject | **新探测源发现**：写内核日志（前缀如 `ip4-probe-log: `），watch 抓取 → 进 pending → 推钉钉 |

要点：

- **allow 优先于 deny**：名单冲突（同一 IP 同时在 allow 与 deny）时按 allow 放行；cn-gate 排在白/黑名单之后，allow 里的海外地址可豁免国籍校验，deny 里的海外地址仍被第 2 条拦截
- **cn-gate 只兜底未列名的国外新源**：大陆集合 `cn_ipv4`/`cn_ipv6` 由 `/etc/cn-ipset/refresh-cn-ipset.sh` 维护并保证非空；gate 静默 DROP，不写日志、不进 pending、不推钉钉
- 第 5 条的拦截动作与 zone 默认拒绝相同，纯粹为写日志；不重开 wan zone 全量日志（历史上曾因此产生 pending 污染）
- **probe-log 是全系统唯一的日志源**：allow/deny/gate/pending 规则均静默（allow/deny 无需记录，gate 不保留海外痕迹，pending 的重复探测由 watch 去重，日志无用途）
- input 组规则只匹配目标=路由器本机（input_wan 链）；forward 组匹配 wan→lan 转发流量（forward_wan 链）；tailscale 是独立 zone（`input_tailscale`/`forward_tailscale`），与 wan 审批链互不到达
- **回程与已建连不会被审批组误匹配**：fw4 基础链在跳进 zone 链（input_wan/forward_wan）之前，已对 established/related 报文先行放行，回程包到不了审批规则；且回程报文的 dport 是对端分配的临时端口，也与审批端口对不上。已知缝隙：invalid/untracked 状态报文仍可能落到 zone 链被评估
- 日志前缀由 fw4 取自规则名，watch 用泛匹配 `*pending-reject*` / `*probe-log*` 兜住所有前缀
- 组随对应端口变量启停：留空 = 整组移除，流量走 zone 默认拒绝且不可审批

## fnOS 转发审批组

fnOS Web（5666/5667）是 forward 组的当前使用者，随 FORWARD_APPROVE_PORT6 启停；cn 白名单规则 Allow-fnos-Web6 已移除（所有来源统一走审批）。批准后来源进入 ip_allow6，后续访问由第 2 条规则直接放行。

## 端口配置（input / forward 分开管理）

approved.conf 里 4 个端口变量，各自独立、均可留空（留空 = 该组不创建审批规则，已存在的自动移除，流量走 wan 兜底拒绝）：

| 变量 | 作用 | 规则组 |
|------|------|--------|
| INPUT_APPROVE_PORT4 | 外网→路由器本机 (v4) | ip4-allow-accept / ip4-deny-drop / cn-gate-ip4 / ip4-pending-reject / ip4-probe-log |
| INPUT_APPROVE_PORT6 | 外网→路由器本机 (v6) | ip6-* 同构 5 条 |
| FORWARD_APPROVE_PORT4 | 外网→lan 转发 (v4) | forward-ip4-* 同构 5 条 |
| FORWARD_APPROVE_PORT6 | 外网→lan 转发 (v6，fnOS Web) | forward-ip6-* 同构 5 条 |

每组固定 5 条规则（见「防火墙规则结构」）。改完运行 /etc/ip-approve/sync-approve-firewall.sh（各组分别同步 + 重建缺失的 ipset/规则 + 重启防火墙）。注意 forward 规则只按端口匹配、不限定目标主机，转发端口应只给单一目标服务使用。

## 升级保留

保留清单 /etc/sysupgrade.conf 的 #approve-ip 段已含：两个 init 脚本、/etc/ip-approve/、审批 CGI、LuCI 面板、/etc/rc.d/ 下的 3 条服务软链（S99 两条自启 + K10 停机，自启状态随升级保留）。若升级后发现服务未自启，手动执行：

```sh
/etc/init.d/approved-ip-watch enable
/etc/init.d/ipapprove-http enable
```
