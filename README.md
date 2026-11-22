# /etc/ip-approve — IP 审批防火墙体系

对 4 个端口（APPROVE_PORT，见 approved.conf）做「先探测进 pending → 钉钉推送 → 手机一键批准/拒绝」的动态放行体系。

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

## 改端口

编辑 approved.conf 的 APPROVE_PORT（空格分隔），然后运行 /etc/ip-approve/sync-approve-firewall.sh（同步端口 + 重建缺失的 ipset/规则 + 重启防火墙）。

## 升级保留

保留清单 /etc/sysupgrade.conf 的 #approve-ip 段已含：两个 init 脚本、/etc/ip-approve/、审批 CGI、LuCI 面板、/etc/rc.d/ 下的 3 条服务软链（S99 两条自启 + K10 停机，自启状态随升级保留）。若升级后发现服务未自启，手动执行：

```sh
/etc/init.d/approved-ip-watch enable
/etc/init.d/ipapprove-http enable
```
