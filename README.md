# /etc/ip-approve — IP 审批防火墙体系

对配置端口（APPROVE_PORT / APPROVE_PORT6，见 approved.conf，当前含 50000/56680/30080 与 56666/56667/30080）做「先探测进 pending → 钉钉推送 → 手机一键批准/拒绝」的动态放行体系。

## 前置条件

| 依赖 | 用途 | 必需性 |
|------|------|--------|
| OpenWrt/iStoreOS（fw4 + nftables） | 防火墙规则与 ipset 集合 | 必需 |
| LuCI + rpcd | 审批面板（ipapprove.uc 控制器 + menu.d 菜单）、switch.html 走 /ubus 调用 | 必需（面板部分） |
| `/www/cgi-bin/ip-approve` | 实际执行批准/拒绝（写 nft + 名单文件）的 CGI，LuCI 与钉钉链路共用 | 必需 |
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
| approved.conf | 配置：钉钉 webhook/加签密钥、APPROVE_PORT、QUICK_SECRET、QUICK_URL |
| pending.list | 待审批 IP 队列（IP + 时间） |
| ip-allow.list / ip-allow6.list | 批准名单（写入 nft ip_allow / ip_allow6） |
| ip-deny.list / ip-deny6.list | 拒绝名单（写入 nft ip_deny / ip_deny6） |
| approved-ip-watch.sh | 监听服务本体：解析探测日志 → nft pending 集合 + pending.list → 推钉钉 |
| sync-approve-firewall.sh | 同步/重建防火墙：端口集合同步 + 缺失 ipset/规则自动重建（改 APPROVE_PORT 后运行） |
| quick/cgi-bin/ip-approve-quick | 钉钉按钮的免登录签名 CGI（HMAC + 30 分钟时效 + pending 校验） |
| README.md | 本文件 |

cn 白名单相关文件在 /etc/cn-ipset/，与本目录无关。

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
探测 4 端口 → approved-ip-watch 写 pending + 推 actionCard（IP+时间+批准/拒绝按钮）
→ 公网 https://istoreos.tailaf168e.ts.net (Tailscale Funnel 443)
→ 127.0.0.1:50080 (uhttpd -f，procd 管理)
→ quick/cgi-bin/ip-approve-quick 验签 → 执行 → 即时生效
```

- Funnel 在路由器上用 `tailscale funnel --bg 50080` 设置，重启后应仍在，失效时重跑该命令
- 按钮链接域名取自 QUICK_URL；清空 QUICK_URL 或 QUICK_SECRET 自动退回纯文本推送
- 已处理 IP 再点旧按钮会显示「已于本次推送之前已被批准/拒绝」

## probe-log 规则（新探测源发现）

ip4-probe-log / ip6-probe-log：无集合匹配的兜底 log+reject 规则，排在各 family 审批规则最后。作用：对 3 个审批端口的全新来源写内核日志（前缀 ip4-probe-log: / ip6-probe-log:），watch 监听该日志把源 IP 加入 pending 并推钉钉。拦截动作与 zone 默认拒绝相同，纯粹为发现探测源；不重开 wan zone 全量日志（避免 pending 污染）。

## fnOS 转发审批组（IPv6）

sync-approve-firewall.sh 会维护一组 forward 规则（随 APPROVE_PORT6 启停）：非 cn 来源经 IPv6 访问 fnOS Web（5666/5667）时由 fnos-ip6-probe-log 记录探测源进 pending（组内命名：fnos-ip6-deny-drop / fnos-ip6-allow-accept / fnos-ip6-pending-reject / fnos-ip6-probe-log），推送钉钉审批；批准后经 ip_allow6 放行。cn 白名单规则 Allow-fnos-Web6 已移除（所有来源统一走审批）。

## 端口配置（input / forward 分开管理）

approved.conf 里 4 个端口变量，各自独立、均可留空（留空 = 该组不创建审批规则，已存在的自动移除，流量走 wan 兜底拒绝）：

| 变量 | 作用 | 规则组 |
|------|------|--------|
| INPUT_APPROVE_PORT4 | 外网→路由器本机 (v4) | ip4-deny-drop / ip4-allow-accept / ip4-pending-reject / ip4-probe-log |
| INPUT_APPROVE_PORT6 | 外网→路由器本机 (v6) | ip6-* 同构 4 条 |
| FORWARD_APPROVE_PORT4 | 外网→lan 转发 (v4) | fnos-ip4-* 同构 4 条 |
| FORWARD_APPROVE_PORT6 | 外网→lan 转发 (v6，fnOS Web) | fnos-ip6-* 同构 4 条 |

改完运行 /etc/ip-approve/sync-approve-firewall.sh（各组分别同步 + 重建缺失的 ipset/规则 + 重启防火墙）。注意 forward 规则只按端口匹配、不限定目标主机，转发端口应只给单一目标服务使用。

## 升级保留

保留清单 /etc/sysupgrade.conf 的 #approve-ip 段已含：两个 init 脚本、/etc/ip-approve/、审批 CGI、LuCI 面板、/etc/rc.d/ 下的 3 条服务软链（S99 两条自启 + K10 停机，自启状态随升级保留）。若升级后发现服务未自启，手动执行：

```sh
/etc/init.d/approved-ip-watch enable
/etc/init.d/ipapprove-http enable
```
