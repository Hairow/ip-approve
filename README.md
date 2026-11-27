# ip-approve — 路由器 IP 审批防火墙体系

对暴露在公网的审批端口做「探测进 pending → 钉钉推送 → 一键批准 / 拒绝」的动态放行体系。未列名的新来源先进入待审批队列，批准后写入白名单永久放行，拒绝则进入黑名单静默丢弃；未列名的境外来源在国籍网关直接丢弃，不进审核。

- 运行环境：OpenWrt / iStoreOS（fw4 + nftables），设备架构 aarch64
- 规则规模：input / forward × IPv4 / IPv6 共 **4 组**，每组固定 **5 条**规则（allow → deny → cn-gate → pending → probe-log）
- 三条入口共用同一套审批核心：LuCI 面板、钉钉按钮免登 CGI、CLI / 脚本

## 工作链路

```
公网探测审批端口
  → fw4 probe-log 写内核日志
  → approved-ip-watch 抓取日志 → 写入 nft pending 集合 + pending.list → 推钉钉 actionCard
  → 手机点「批准 / 拒绝」
      → Tailscale Funnel 443 → 127.0.0.1:50080（uhttpd）
      → ip-approve-quick 验签（HMAC + 30 分钟时效 + pending 校验）
      → 写 allow / deny 名单与 nft 集合，即时生效
```

未配置快捷审批（缺少 `QUICK_SECRET` 或 `QUICK_URL`）时，改发无按钮的 Markdown 通知，并提供指向 `https://192.168.100.1/switch.html` 的审批链接；核心审批链（探测 → pending → 面板手动批准 / 拒绝）不受影响。

快捷审批卡片标题为「IP审批」，正文首行显示 IP 地址；时间、端口与归属地随后展示，归属地不含空格，底部提供「✅ 批准 / 🚫 拒绝」按钮；快捷链接 30 分钟内有效。

## 前置依赖

| 依赖 | 用途 | 必需性 |
|------|------|--------|
| OpenWrt / iStoreOS（fw4 + nftables） | 防火墙规则与集合 | 必需 |
| LuCI + rpcd + ucode | 面板控制器与开关接口会话鉴权 | 必需（面板部分） |
| `www/cgi-bin/ip-approve` | 批准 / 拒绝 / 移除黑白名单，写 nft + 名单文件；提供 pending / 黑白名单只读查询 | 必需 |
| openssl | HMAC-SHA256 签名 / 验签（钉钉加签 + 快捷链接） | 必需 |
| busybox curl | 推送钉钉 | 必需 |
| busybox `logread -f` | watch 服务跟踪内核防火墙日志 | 必需 |
| Tailscale（tailscaled，MagicDNS + HTTPS 证书） | Funnel 公网入口 `https://<域名>:443 → 127.0.0.1:50080` | 可选（一键审批需要） |
| 钉钉群机器人（webhook + 加签密钥） | 待审批通知与 actionCard 按钮 | 可选（推送通道） |

## 仓库结构与设备路径

仓库目录按设备路径组织：仓库内相对路径即设备绝对路径去掉前导 `/`（如 `etc/ip-approve/` → `/etc/ip-approve/`，`www/` → `/www/`，`usr/share/` → `/usr/share/`）。仓库保留脚本、配置模板、控制器、前端与 nali 二进制快照；名单、归属地库等运行时产物不入库。

| 仓库路径（即设备相对路径） | 作用 |
|---------|------|
| `etc/ip-approve/approved.conf.example` | 配置模板：钉钉 webhook / 加签、4 个端口变量、QUICK_SECRET / QUICK_URL；复制为 `approved.conf`，权限 600 |
| `etc/ip-approve/approved-ip-watch.sh` | 监听服务本体：解析探测日志 → pending 集合 + pending.list → 推钉钉 |
| `etc/ip-approve/sync-approve-firewall.sh` | 各组端口同步 + 缺失集合 / 规则自动重建 |
| `etc/init.d/approved-ip-watch` | watch 服务 procd 定义（START=99）；注入 `APPROVE_WATCH_SVC=1` 供脚本入口闸门校验 |
| `etc/init.d/ipapprove-http` | quick 签名 CGI 的 uhttpd 服务定义（127.0.0.1:50080，docroot 为 `etc/ip-approve/quick`） |
| `www/switch.html` | 面板前端：设备 / 服务开关 + IP 审批 / 黑名单 / 白名单弹层 |
| `www/cgi-bin/ip-approve` | 审批执行核心 CGI（flock 原子更新底账与 nft 集合） |
| `usr/share/ucode/luci/controller/admin/ipapprove.uc` | IP 审批接口：POST 写动作、GET 只读列表 |
| `usr/share/ucode/luci/controller/admin/switchboard.uc` | 开关面板 ubus 代理（白名单对象 / 方法，不开放任意 ubus 调用） |
| `usr/share/luci/menu.d/luci-app-ipapprove.json` | 审批面板菜单 |
| `usr/share/luci/menu.d/luci-app-switchboard.json` | 开关面板菜单 |
| `etc/ip-approve/quick/cgi-bin/ip-approve-quick` | 钉钉按钮免登录验签 CGI（quick 服务 uhttpd docroot 下的 cgi-bin） |
| `etc/ip-approve/quick/index.html` | quick 服务存活占位页 |
| `etc/cn-ipset/config.yaml` | nali 运行配置（相对路径库条目） |
| `etc/cn-ipset/config.yaml.default` | nali 空目录首次运行落盘的上游默认稿，仅作对照基线，不部署 |
| `etc/cn-ipset/nali-linux-armv8-<ver>.gz`（+ `.sha256`） | nali 二进制快照；部署时解压为 `etc/cn-ipset/nali` |
| `etc/cn-ipset/refresh-cn-ipset.sh` | 大陆集合刷新：同步 chnroute{,6} 副本 → `fw4 reload-sets`；副本为空不刷新 |
| `etc/cn-ipset/refresh-nali-db.sh` | 归属地 / CDN 库刷新：备份 → `nali update` → 非空校验、异常回滚 → 保留 3 份备份 |

运行时数据（不入库，落在设备）：`pending.list`、`ip-allow{,6}.list`、`ip-deny{,6}.list`、四库（`qqwry.dat` / `ip2region_v4.xdb` / `zxipv6wry.db` / `cdn.yml`）、`chnroute{,6}`、解压后的 nali 二进制。

## 配置：`approved.conf`

由 `approved.conf.example` 复制后按实际填写，权限 600（含密钥）。

| 变量 | 作用 |
|------|------|
| `DING_WEBHOOK` | 钉钉机器人 webhook（含 access_token）；留空或只有前缀则不推送 |
| `DING_SECRET` | 钉钉加签密钥（`SEC` 开头） |
| `INPUT_APPROVE_PORT4` | 外网 → 路由器本机（v4）审批端口，空格分隔；留空 = 不创建该组规则 |
| `INPUT_APPROVE_PORT6` | 外网 → 路由器本机（v6）审批端口 |
| `FORWARD_APPROVE_PORT4` | 外网 → lan 转发（v4）审批端口 |
| `FORWARD_APPROVE_PORT6` | 外网 → lan 转发（v6，fnOS Web）审批端口 |
| `QUICK_SECRET` | 32 位 hex，watch 签名与 CGI 验签必须一致 |
| `QUICK_URL` | 公网入口域名（Tailscale Funnel）；留空则退回无按钮的 Markdown 通知 |

forward 规则只按端口匹配、不限定目标主机，转发端口应只给单一目标服务使用。

## 服务运维

用 init 脚本管理，不要裸跑脚本本体：

```sh
/etc/init.d/approved-ip-watch start|stop|restart|enable|disable   # 监听推送服务
/etc/init.d/ipapprove-http    start|stop|restart|enable|disable   # 50080 签名 CGI 服务（uhttpd）
```

两个服务均已 enable 开机自启（S99）。watch 脚本入口带服务闸门：仅 procd 托管进程可进入前台主循环——主判据为 init 注入的 `APPROVE_WATCH_SVC=1` 标记，兜底认父进程为 PID 1（procd 收养）；在终端直接裸跑（父进程为 ash / sshd）会被拒绝并提示改用 init 脚本，不会再起第二个循环。`test` / `backfill` 子命令在闸门之前，不受限制。

### 手动维护命令

```sh
/etc/ip-approve/approved-ip-watch.sh test <IP>   # 注入测试 IP：进 pending 并推钉钉（用 RFC5737 段，如 203.0.113.50）
/etc/ip-approve/approved-ip-watch.sh backfill    # 把 nft pending 集合已有 IP 回填 pending.list（不推送）
```

### watch 进程模型

单实例由 pidfile + `kill_tree` 保证。运行时进程树：

```
主 shell（pidfile 所有者，procd 拉起）
└─ 后台子 shell（日志跟踪循环）
    ├─ logread -f        # 管道左端，跟随内核日志
    └─ while-read 子 shell # 管道右端，解析日志、调 by_type → new_ip
```

重启时旧进程树（主 → 子 shell → 管道孙进程）被整棵清理；三个 sh 合计 RSS 约 3MB，无常驻 nali（查询进程用完即退）。

## 防火墙规则结构

4 组（input v4 / input v6 / forward v4 / forward v6）结构完全同构，仅名字前缀（`ip4-` / `ip6-` / `forward-ip4-` / `forward-ip6-`）和集合后缀不同。fw4 按 UCI 段顺序进链，链内顺序固定：

| 顺序 | 规则 | 匹配 | 动作 | 作用 |
|------|------|------|------|------|
| 1 | `<前缀>-allow-accept` | 源 ∈ ip_allow 集合 | accept | 已批准名单放行（allow 优先于 deny） |
| 2 | `<前缀>-deny-drop` | 源 ∈ ip_deny 集合 | drop | 已拒绝名单拦截，静默丢弃 |
| 3 | `cn-gate-<前缀>` | 源 ∉ cn_ipv4 / cn_ipv6 集合 | drop | 未列名的境外源直接丢弃，不进审核、不记日志 |
| 4 | `<前缀>-pending-reject` | 源 ∈ ip_pending 集合 | reject | 审批中的重复探测，静默拒绝（watch 去重，不重复推送） |
| 5 | `<前缀>-probe-log` | 其余国内来源（无集合匹配） | log + reject | **新探测源发现**：写内核日志（前缀如 `ip4-probe-log: `），watch 抓取 → pending → 推钉钉 |

要点：

- **allow 优先于 deny**：同一 IP 同时在 allow 与 deny 时按 allow 放行；cn-gate 在白 / 黑名单之后，allow 里的海外地址可豁免国籍校验，deny 里的海外地址仍被第 2 条拦截。
- **cn-gate 只兜底未列名的境外新源**：大陆集合由 `refresh-cn-ipset.sh` 维护并保证非空；gate 静默 DROP，不写日志、不进 pending、不推钉钉。
- 第 5 条的拦截动作与 zone 默认拒绝相同，纯粹为写日志；不重开 wan zone 全量日志（历史上曾因此产生 pending 污染）。
- **probe-log 是全系统唯一日志源**：allow / deny / gate / pending 规则均静默。
- input 组只匹配目标为路由器本机（input_wan 链）；forward 组匹配 wan→lan 转发（forward_wan 链）；tailscale 是独立 zone，与 wan 审批链互不到达。
- **回程与已建连不会被误匹配**：fw4 在跳进 zone 链前已先行放行 established/related，回程包到不了审批规则；回程 dport 是临时端口，也与审批端口对不上。已知缝隙：invalid / untracked 报文仍可能落到 zone 链被评估。
- 日志前缀取自规则名，watch 用泛匹配 `*pending-reject*` / `*probe-log*` 兜住所有前缀。
- 端口变量留空 = 整组移除，流量走 zone 默认拒绝且不可审批；改完端口运行 `sync-approve-firewall.sh`。
- **IPv6 白名单按 /64 聚合**：批准一个 v6 单地址时，自动截断为前 64 位 `prefix::/64` 写入 `ip_allow6` 与内核集合，规避 IPv6 临时隐私地址定期轮换后重复进待审批；拒绝（deny）名单仍保持单地址，不做 /64 聚合，避免拉黑整条子网误杀同网段其他设备。v4 维持单地址，网段仅手工写入。

### fnOS 转发审批组

fnOS Web（5666 / 5667）是 forward 组当前使用者，随 `FORWARD_APPROVE_PORT6` 启停；cn 白名单规则已移除，所有来源统一走审批。批准后来源进入 ip_allow6，后续访问由第 2 条规则直接放行。

## nali 归属地查询

`nali` 是离线 IP 归属地查询命令行工具（Go 编写），在钉钉推送 / 审批列表显示来源 IP 的省市与运营商。查询完全离线，不依赖在线接口。

### 版本与编译

当前设备运行本地交叉编译的 master 版本 **`v0.8.1-13-g1651b7a`**（源码 `github.com/zu1k/nali`，commit `1651b7a`）；仓库内随附其 gz 包与 `.sha256`，旧 release `v0.8.1` 包同目录留档可回退。

- 设备为 aarch64（arm64 / armv8）；纯 Go、`CGO_ENABLED=0` 静态链接，无运行库依赖，musl / glibc 均可运行，不需要目标机 gcc。
- 编译需 Go ≥ 1.26：

```sh
cd nali-src
VERSION=$(git describe --tags --always)
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 GOPROXY=https://goproxy.cn,direct \
  go build -trimpath -ldflags "-s -w \
  -X github.com/zu1k/nali/internal/constant.Version=$VERSION" \
  -o nali-linux-arm64 .
gzip -N nali-linux-arm64        # 得到 .gz，再对 .gz 生成 .sha256
```

### 部署到设备（aarch64）

```sh
uname -m                                                        # 应为 aarch64
# 取仓库内 gz 包到 /etc/cn-ipset/nali.gz（备选 release 资产见 etc/cn-ipset/ 目录旧包）
sha256sum /etc/cn-ipset/nali.gz                                 # 可选，对照 .sha256
gunzip -c /etc/cn-ipset/nali.gz > /etc/cn-ipset/nali
chmod 755 /etc/cn-ipset/nali
rm -f /etc/cn-ipset/nali.gz
# 首次拉取四库（之后由 cron 自动更新）
NALI_HOME=/etc/cn-ipset /etc/cn-ipset/nali update --db qqwry,zxipv6wry,ip2region,cdn
ls -l /etc/cn-ipset/ip2region_v4.xdb /etc/cn-ipset/qqwry.dat /etc/cn-ipset/zxipv6wry.db /etc/cn-ipset/cdn.yml
```

磁盘占用：gz 包约 3.8MB，解压后二进制约 9.3MB；四库合计约 41MB（`cdn.yml` 仅约 26KB）。

### 配置与查询优先级

通过环境变量指定目录，配置与库都落在二进制同目录 `/etc/cn-ipset/`：

- `NALI_HOME=/etc/cn-ipset`：配置目录与数据目录都指向该目录（本项目采用）；
- 或分开指定 `NALI_CONFIG_HOME`、`NALI_DB_HOME`。

`config.yaml` 保留上游 default 全量条目，库文件均为相对路径（相对 `NALI_HOME` 解析）。两处偏离：qqwry 下载源换为 metowolf；ip2region 回退库文件名随拆分改为 `ip2region_v4.xdb`，下载源换为可达的 v4 拆分双源。

查询优先级：

- **IPv4**：先用 qqwry，未命中再由脚本切到 ip2region 回退；
- **IPv6**：只用 zxipv6wry；
- 回退由 watch 脚本在 shell 层用 `NALI_DB_IP4=ip2region` 切库实现。

> 新版 nali 支持逗号并列多库（如 `NALI_DB_IP4=qqwry,ip2region`），单进程内遍历；但并列 JSON 会多出 `results` 数组，现有 sed 提取顶层 `text` 的逻辑需同步改造，故现网仍维持「主库未命中再二次调用回退库」的方式。

### 验证

```sh
# 必须带 NALI_HOME；脚本调用固定带 --color never，避免 ANSI 色码混入 JSON / 文本
# IPv4（默认 qqwry）：text 形如 中国–山东–烟台 电信
NALI_HOME=/etc/cn-ipset /etc/cn-ipset/nali --color never -j 113.124.101.115

# IPv4 回退库 ip2region（切库）：text 形如 中国|山东省|烟台市|电信|CN
NALI_HOME=/etc/cn-ipset NALI_DB_IP4=ip2region /etc/cn-ipset/nali --color never -j 113.124.101.115

# IPv6（zxipv6wry）
NALI_HOME=/etc/cn-ipset /etc/cn-ipset/nali --color never -j 2001:4860:4860::8888
```

`-j` 输出 JSON，一行一条；关键字段 `info.country`（国家 / 省 / 市）、`info.area`（运营商 / 网段）。支持一次传多个 IP 批量查询，每行一条 JSON。

### 注意事项

- **调用必须带 `NALI_HOME=/etc/cn-ipset`**：不带时 nali 回退 XDG 默认目录（`~/.config/nali`、`~/.local/share/nali`），找不到 config 与库会尝试联网下载并超时。watch / CGI 封装命令需固定该变量。
- 库缺失时 nali 会按 `download-urls` 联网补下；部署时确保四库就位，运行期查询保持离线。
- Linux 下库文件 mmap 按需缺页载入，不整库读入堆；单次查询进程驻留约 12MB，退出即释放。
- IPv6 库（ZX）粒度只到运营商 / 大区，比 IPv4 纯真库粗，属预期。
- 二进制与库均为运行时产物，默认不入库；随仓库分发的是 gz 包 + `.sha256` + `config.yaml`。

### 地址库刷新（cron）

nali 本身不是守护进程，没有内置定时任务；库刷新由外部 cron 调用 `etc/cn-ipset/refresh-nali-db.sh`，脚本内部再调 `nali update`。设备 crontab：

```cron
30 4 * * * /etc/cn-ipset/refresh-nali-db.sh
```

脚本流程：先备份现有四库 → `nali update` 刷新 → 逐库校验（存在且非空）→ 缺失 / 空文件自动从本次备份回滚 → 清理旧备份。

- 备份目录 `/etc/cn-ipset/backup/<YYYYmmdd-HHMMSS>/`，`latest` 软链指向最近一次；仅保留最近 3 份。
- `--db` 按 config 条目名更新：`qqwry` 读 metowolf 源；`ip2region` 读 v4 拆分双源（jsDelivr → raw）；`zxipv6wry` 未配源，走内置 `https://ip.zxinc.org/ip.7z`；`cdn` 读三源。
- 新版写库为临时文件 + rename 原子替换，下载做内容校验（mmdb / xdb / yml），非 200 视为错误，未变更的库不重复写入；大库（ip2region-v6 / ipinfo）普通 `update` 仅在已选或已下载时才拉取。
- 仍存的短板：HTTP 无自动重试；全局超时 300s、TLS 握手 5s；包装脚本以「非空 + 备份回滚」兜底，非空但内容损坏仍需人工核对，下次 cron 重试即可。

## 升级保留

保留清单 `/etc/sysupgrade.conf` 的 `#approve-ip` 段已含：两个 init 脚本、`/etc/ip-approve/`、审批 CGI、LuCI 面板、`/etc/rc.d/` 下 3 条服务软链（S99 两条自启 + K10 停机，自启状态随升级保留）。升级后若服务未自启：

```sh
/etc/init.d/approved-ip-watch enable
/etc/init.d/ipapprove-http enable
```
