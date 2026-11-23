// 开关面板接口 — 挂在 admin 下由 LuCI dispatcher 自动会话鉴权
// POST /cgi-bin/luci/admin/switchboard/run {"action":"state|call", ...}
// GET  ?action=state|call&o=<ubus对象>&m=<方法>&p=<JSON参数>
// 前端不再持有 sid：dispatcher 注入 ctx.authsession，由 ucode 直接调 ubus。

'use strict';

/* 白名单：面板实际用到的 ubus 对象/方法。
   通用代理只放这些组合，避免把已登录会话变成任意 ubus 调用面。 */
const ALLOW = {
	rc:                  [ 'list', 'init' ],
	uci:                 [ 'get', 'set', 'apply' ],
	system:              [ 'info', 'board' ],
	'network.interface': [ 'dump' ],
	luci:                [ 'getProcessList', 'getMountPoints', 'getRealtimeStats' ],
	'luci-rpc':          [ 'getDHCPLeases', 'getHostHints' ],
};

function json_out(o) {
	http.prepare_content('application/json; charset=UTF-8');
	http.write_json(o);
}
function json_err(msg) { json_out({ ok: false, error: msg }); }

function method_not_allowed() {
	http.status(405, 'Method Not Allowed');
	http.header('Allow', 'POST');
	json_out({ ok: false, error: 'method-not-allowed' });
}

/* 参数：优先 POST JSON body，GET/非 JSON 回退到 formvalue */
function param(body, key, def) {
	if (type(body) == 'object' && body != null && body[key] != null)
		return body[key];
	return http.formvalue(key) ?? def;
}

/* 原生 ubus 调用：显式带 LuCI 会话 sid（uci/rc/luci 等要过 ACL） */
function call(o, m, args) {
	const a = (type(args) == 'object' && args != null) ? args : {};
	a.ubus_rpc_session = ctx.authsession;
	ubus.error();                 // 清掉上一次的错误码
	const res = ubus.call(o, m, a);
	ubus.error(true);             // 取走并清空本次错误码
	return res;
}

/* 只读字段取不到时给兜底值，不让单个接口失败拖垮整页 */
function safe(o, m, args, fallback) {
	try { return call(o, m, args) ?? fallback; }
	catch (e) { return fallback; }
}

function allowed(o, m) {
	const list = ALLOW[o];
	if (type(list) != 'array') return false;
	for (let i = 0; i < length(list); i++)
		if (list[i] == m) return true;
	return false;
}

/* WAN 速率：最后两个采样点差分算 rx/tx（B/s），前端不再自己做。
   与前端原逻辑一致：默认路由所在接口，字节回绕则放弃本次。 */
function wan_rate(ifs) {
	let dev = null;
	for (let i = 0; i < length(ifs); i++) {
		const it = ifs[i];
		if (!it.up) continue;
		const routes = it.route || [];
		for (let j = 0; j < length(routes); j++)
			if (routes[j].target == '0.0.0.0') { dev = it.device; break; }
		if (dev) break;
	}
	if (!dev) return null;
	const r = safe('luci', 'getRealtimeStats', { mode: 'interface', device: dev }, null);
	const s = (r && r.result) || [];
	if (length(s) < 2) return null;
	const a = s[length(s) - 2], b = s[length(s) - 1];
	const dt = b[0] - a[0], rx = b[1] - a[1], tx = b[3] - a[3];
	return (dt > 0 && rx >= 0 && tx >= 0) ? { rx: rx / dt, tx: tx / dt } : null;
}

/* WAN 地址：直接算好 v4/v6/dev 三个值下发，前端不再收接口结构、不再自己解析。
   与 wan_rate() 同口径：默认路由所在接口；v6 取 2/3 开头的全局单播地址。 */
function wan_addrs(ifs) {
	let v4if = null, v6if = null;
	for (let i = 0; i < length(ifs); i++) {
		const it = ifs[i];
		if (!it.up) continue;
		const routes = it.route || [];
		for (let j = 0; j < length(routes); j++) {
			const target = '' + (routes[j].target ?? '');
			if (target == '0.0.0.0' && !v4if) v4if = it;
			if (target == '::' && !v6if) v6if = it;
		}
	}
	if (!v4if) { /* 兜底：无默认 v4 路由但有 wan 接口 */
		for (let i = 0; i < length(ifs); i++) {
			const it = ifs[i];
			if (it.up && substr('' + (it.interface ?? ''), 0, 3) == 'wan') { v4if = it; break; }
		}
	}
	const v4a = v4if ? (v4if['ipv4-address'] || []) : [];
	const v4 = (length(v4a) > 0 && v4a[0] && v4a[0].address != null)
		? '' + v4a[0].address : null;
	const v6name = v6if ? ('' + (v6if.interface ?? '')) : '';
	let v6 = null;
	/* 先扫带 :: 默认路由的接口，再扫其余 up 接口兜底 */
	for (let pass = 0; pass < 2 && !v6; pass++) {
		for (let i = 0; i < length(ifs); i++) {
			const it = ifs[i];
			if (!it.up) continue;
			const name = '' + (it.interface ?? '');
			if (pass == 0 && name != v6name) continue;
			if (pass == 1 && name == v6name) continue;
			const a = it['ipv6-address'] || [];
			for (let j = 0; j < length(a); j++) {
				const addr = '' + ((a[j] && a[j].address) ?? '');
				const c = substr(addr, 0, 1);
				if (c == '2' || c == '3') { v6 = addr; break; }
			}
			if (v6) break;
		}
	}
	return {
		v4: v4,
		v6: v6,
		dev: v4if ? ('' + (v4if.device ?? '')) : null,
	};
}

/* 进程态判定：按前端给出的 pgrep 前缀在 getProcessList 里匹配，只回布尔值，
   不把整份进程表（30KB+）塞进 state 响应。列表空则回 null 让前端走 guess 降级。
   pats: [{ name, pattern }, ...]（前端 ITEMS 里带 pgrep 的 service 项）。 */
function proc_states(pats) {
	const out = {};
	const list = type(pats) == 'array' ? pats : [];
	const all = safe('luci', 'getProcessList', {}, {});
	const rows = (all && all.result) || [];
	for (let i = 0; i < length(list); i++) {
		const e = list[i];
		if (type(e) != 'object' || e == null) continue;
		const name = '' + (e.name ?? '');
		const pat = '' + (e.pattern ?? '');
		if (!name || !pat) continue;
		let hit = false;
		for (let j = 0; j < length(rows); j++) {
			const cmd = '' + ((rows[j] && rows[j].COMMAND) ?? '');
			if (substr(cmd, 0, length(pat)) == pat) { hit = true; break; }
		}
		out[name] = hit ? true : (length(rows) ? false : null);
	}
	return out;
}

/* 按前端给出的服务名逐个定向查 rc.list。
   全量 rc.list {} 要扫描所有 init 脚本（3s+），带 name 只查单个（~0.16s）。
   只回前端读的 enabled/running（start/stop 优先级前端不用）。 */
function rc_service_states(names) {
	const out = {};
	const list = type(names) == 'array' ? names : [];
	for (let i = 0; i < length(list); i++) {
		const name = '' + (list[i] ?? '');
		if (!name) continue;
		const one = safe('rc', 'list', { name: name }, {});
		if (type(one) == 'object' && one != null && one[name] != null) {
			const entry = one[name];
			if (type(entry) == 'object' && entry != null) {
				const e = {};
				if (entry.enabled != null) e.enabled = entry.enabled;
				if (entry.running != null) e.running = entry.running;
				out[name] = e;
			} else {
				out[name] = entry;
			}
		}
	}
	return out;
}

/* 通用字段裁剪：只回前端真正读的键，避免把 ubus 原始大结构（进程表/接口详情/
   租约全字段）透传。实测 state 响应从 ~52KB 降到几 KB。 */
function pick(o, keys) {
	const out = {};
	if (type(o) != 'object' || o == null) return out;
	for (let i = 0; i < length(keys); i++) {
		const k = keys[i];
		if (o[k] != null) out[k] = o[k];
	}
	return out;
}
function pick_list(arr, keys) {
	const out = [];
	if (type(arr) != 'array') return out;
	for (let i = 0; i < length(arr); i++)
		out[length(out)] = pick(arr[i], keys);
	return out;
}
/* 磁盘只回面板会展示的：系统盘（/overlay 或 /，跳过 overlayfs:/overlay 重复项）
   + 实体盘 /dev/sdX（sda1/sdb1）。tmpfs/rom/boot 等前端不用，不回。 */
function pick_mounts(ms) {
	const out = [];
	if (type(ms) != 'array') return out;
	for (let i = 0; i < length(ms); i++) {
		const m = ms[i];
		if (type(m) != 'object' || m == null) continue;
		const mount = '' + (m.mount ?? '');
		const dev = '' + (m.device ?? '');
		const is_sys = (mount == '/overlay' || mount == '/') && dev != 'overlayfs:/overlay';
		const is_disk = substr(dev, 0, 7) == '/dev/sd';
		if (!is_sys && !is_disk) continue;
		out[length(out)] = pick(m, [ 'device', 'mount', 'size', 'free' ]);
	}
	return out;
}
/* hints 是以 MAC 为键的对象，逐个值只留 name/ipaddrs/ip6addrs。
   路由器自己（iStoreOS）也保留，作为一台普通设备显示。 */
function pick_hints(h) {
	const out = {};
	if (type(h) != 'object' || h == null) return out;
	for (let k in h)
		out[k] = pick(h[k], [ 'name', 'ipaddrs', 'ip6addrs' ]);
	return out;
}

/* 一次聚合返回面板全部只读数据；只回原始结构里前端实际使用的字段，
   业务判定（rcAvailable 降级、guess 兜底、buildDevices 合并）仍在前端。
   body.services：service 项名字，把 rc.list 收窄成定向查询。
   body.pgrep：[{name, pattern}]，后端据此判定进程态，前端不再接收进程表。 */
function action_state(body) {
	const b = (body != null && type(body) == 'object') ? body : {};
	const net = safe('network.interface', 'dump', {}, {});
	const ifs = net.interface || [];
	const si = safe('system', 'info', {}, null);
	const bd = safe('system', 'board', {}, null);
	const mounts = (safe('luci', 'getMountPoints', {}, {}).result) || [];
	const leases = safe('luci-rpc', 'getDHCPLeases', {}, null);
	const hints = safe('luci-rpc', 'getHostHints', {}, null);
	const sys = (si != null && type(si) == 'object') ? {
		uptime: si.uptime,
		load:   si.load,
		memory: pick(si.memory, [ 'total', 'available', 'free', 'buffered', 'cached' ]),
	} : null;
	const le = (leases != null && type(leases) == 'object') ? {
		dhcp_leases:  pick_list(leases.dhcp_leases || [],
			[ 'expires', 'macaddr', 'hostname', 'ipaddr' ]),
		dhcp6_leases: pick_list(leases.dhcp6_leases || [],
			[ 'expires', 'macaddr', 'duid', 'hostname', 'ip6addrs', 'ip6addr' ]),
	} : null;
	json_out({
		ok: true,
		rc:      rc_service_states(b.services),
		proc:    proc_states(b.pgrep),
		sysinfo: sys,
		board:   (bd != null && type(bd) == 'object') ? pick(bd, [ 'model' ]) : null,
		net:     wan_addrs(ifs),
		mounts:  pick_mounts(mounts),
		rate:    wan_rate(ifs),
		leases:  le,
		hints:   pick_hints(hints),
	});
}

/* 服务启停：不用 rpcd 的 rc.init / luci.setInitAction（umask 0077 + 同步
   阻塞事件循环 → passwall 的 lua helper 调 ubus 死锁、配置生成假启动），
   改在本控制器所在的 uhttpd CGI 进程（umask 0022）里用 system() 直接执行。
   一次请求内同步做完：在跑则 start 映射 restart → 执行 → 探活 → 失败补一次
   restart → 回最终 running；前端因此不再需要忙等轮询。
   action 白名单 start/stop/restart，name 固定 passwall，杜绝命令注入。 */
const SERVICE_INIT = '/etc/init.d/passwall';
/* 核心进程前缀拆两段在 shell 里拼：若把完整字面量写进 system() 命令行，
   pgrep -f 会匹配到 sh -c 包装自身（其命令行含该字符串）而恒判"在跑"。
   system() 返回退出码：0=匹配到，非0=没匹配到。 */
function svc_alive() {
	return system('P="/tmp/etc/passwall/b"; P="${P}in/"; '
		+ 'pgrep -f "$P" >/dev/null 2>&1') == 0;
}
/* 同步执行 init：system() 等到脚本跑完才返回，天然避开"上一轮 stop 的
   kill -9 还没收尾就 restart、打断 gen_config 产出 0 字节 json → xray EOF
   假启动"的竞态。关 >2 的继承 fd + umask 022 沿用原 pswctl 包装的做法。 */
function svc_exec(act) {
	system('for f in /proc/self/fd/*; do n=${f##*/}; '
		+ '[ "$n" -gt 2 ] 2>/dev/null && eval "exec $n<&-" 2>/dev/null; done; '
		+ 'umask 022; ' + SERVICE_INIT + ' ' + act + ' >/dev/null 2>&1');
}
function action_service(body) {
	/* 服务启停是写动作，仅允许 POST */
	if ((http.getenv('REQUEST_METHOD') ?? 'GET') != 'POST') {
		method_not_allowed();
		return;
	}
	const action = '' + (param(body, 'act', '') ?? '');
	if (action != 'start' && action != 'stop' && action != 'restart') {
		json_err('bad service action');
		return;
	}
	/* start：已在跑就 restart（跳过空转 stop 省 ~2s），否则 start */
	let act = action;
	if (action == 'start')
		act = svc_alive() ? 'restart' : 'start';
	svc_exec(act);
	system('sleep 1');   /* 给核心进程拉起留一点时间 */
	let running = svc_alive();
	/* 开启后核心进程没起来（偶发 gen 被打断）：补一次 restart */
	if (act != 'stop' && !running) {
		svc_exec('restart');
		system('sleep 1');
		running = svc_alive();
	}
	json_out({ ok: true, action: act, running: running });
}

/* 单条 ubus 调用代理：供开关操作时的 uci set/apply、rc.init、进程轮询使用 */
function action_call(body) {
	const o = '' + (param(body, 'o', '') ?? '');
	const m = '' + (param(body, 'm', '') ?? '');
	if (!allowed(o, m)) { json_err('not allowed: ' + o + '/' + m); return; }
	/* 写类 ubus 调用（uci set/apply、rc init）仅允许 POST；只读方法可走 GET */
	const method = http.getenv('REQUEST_METHOD') ?? 'GET';
	const write_call = (o == 'uci' && (m == 'set' || m == 'apply'))
		|| (o == 'rc' && m == 'init');
	if (write_call && method != 'POST') { method_not_allowed(); return; }
	let p = param(body, 'p', {});
	if (type(p) == 'string') {
		try { p = json(p); } catch (e) { p = {}; }
	}
	if (type(p) != 'object' || p == null) p = {};
	json_out({ ok: true, data: call(o, m, p) ?? null });
}

return {
	action_run: function() {
		let body = null;
		if ((http.getenv('REQUEST_METHOD') ?? 'GET') == 'POST') {
			const raw = http.content() ?? '';
			if (length(raw) > 0) {
				try { body = json(raw); } catch (e) { body = null; }
			}
		}
		const action = '' + (param(body, 'action', 'state') ?? '');
		if (action == 'state') action_state(body);
		else if (action == 'call') action_call(body);
		else if (action == 'service') action_service(body);
		else json_err('bad action');
	}
};
