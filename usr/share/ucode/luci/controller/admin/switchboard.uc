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

/* 按前端给出的服务名逐个定向查 rc.list。
   全量 rc.list {} 要扫描所有 init 脚本（3s+），带 name 只查单个（~0.16s）。 */
function rc_service_states(names) {
	const out = {};
	const list = type(names) == 'array' ? names : [];
	for (let i = 0; i < length(list); i++) {
		const name = '' + (list[i] ?? '');
		if (!name) continue;
		const one = safe('rc', 'list', { name: name }, {});
		if (type(one) == 'object' && one != null && one[name] != null)
			out[name] = one[name];
	}
	return out;
}

/* 一次聚合返回面板全部只读数据；原始结构交给前端做业务判定
   （rcAvailable 降级、guess 兜底、buildDevices 合并都留在前端）
   body.services：本页 service 项名字，用来把 rc.list 收窄成定向查询。 */
function action_state(body) {
	const net = safe('network.interface', 'dump', {}, {});
	const ifs = net.interface || [];
	json_out({
		ok: true,
		rc:      rc_service_states(body && body.services),
		procs:   (safe('luci', 'getProcessList', {}, {}).result) || [],
		fw:      (safe('uci', 'get', { config: 'firewall' }, {}).values) || {},
		sysinfo: safe('system', 'info', {}, null),
		board:   safe('system', 'board', {}, null),
		net:     ifs,
		mounts:  (safe('luci', 'getMountPoints', {}, {}).result) || [],
		rate:    wan_rate(ifs),
		leases:  safe('luci-rpc', 'getDHCPLeases', {}, null),
		hints:   safe('luci-rpc', 'getHostHints', {}, null),
	});
}

/* 服务启停：不用 rpcd 的 rc.init / luci.setInitAction（umask 0077 + 同步
   阻塞事件循环 → passwall 的 lua helper 调 ubus 死锁、配置生成假启动），
   改在本控制器所在的 uhttpd CGI 进程（umask 0022）里用 system() 直接执行。
   等价于原自建 /etc/init.d/pswctl 包装：关继承 fd + umask 022 + start 智能映射
   （核心进程在跑就 restart，跳过空转 stop 省 ~2s），但不再需要那个脚本文件。
   action 白名单 start/stop/restart，name 固定 passwall，杜绝命令注入。 */
const SERVICE_INIT = '/etc/init.d/passwall';
const SERVICE_PGREP = '/tmp/etc/passwall/bin/';
function action_service(body) {
	const action = '' + (param(body, 'act', '') ?? '');
	if (action != 'start' && action != 'stop' && action != 'restart') {
		json_err('bad service action');
		return;
	}
	/* start：已在跑就 restart（等价 pswctl），否则 start */
	let act = action;
	if (action == 'start')
		act = system('pgrep -f ' + SERVICE_PGREP + ' >/dev/null 2>&1')
			? 'restart' : 'start';
	/* 关 >2 的继承 fd、umask 022，再后台执行，避免阻塞本 CGI 请求 */
	const cmd = 'for f in /proc/self/fd/*; do n=${f##*/}; '
		+ '[ "$n" -gt 2 ] 2>/dev/null && eval "exec $n<&-" 2>/dev/null; done; '
		+ 'umask 022; ' + SERVICE_INIT + ' ' + act + ' >/dev/null 2>&1 &';
	system(cmd);
	json_out({ ok: true, action: act });
}

/* 单条 ubus 调用代理：供开关操作时的 uci set/apply、rc.init、进程轮询使用 */
function action_call(body) {
	const o = '' + (param(body, 'o', '') ?? '');
	const m = '' + (param(body, 'm', '') ?? '');
	if (!allowed(o, m)) { json_err('not allowed: ' + o + '/' + m); return; }
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
