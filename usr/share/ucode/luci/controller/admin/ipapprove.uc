// IP 审批接口 — 挂在 admin 下由 LuCI dispatcher 自动会话鉴权
// POST /cgi-bin/luci/admin/ipapprove/run {"action":"approve|deny|unban|unallow","ips":[...]} （批量，写动作仅 POST）
// GET  ?action=list|denylist|allowlist （只读）

'use strict';

import { popen } from 'fs';

const IP_RE = /^[0-9a-fA-F.:/]{1,50}$/;   // 支持纯 IP 与 CIDR 网段（黑名单里有 5.231.242.0/24）
const MAX_IPS = 500;

function shell_quote(s) {
	return "'" + replace(s, "'", "'\\''") + "'";
}

function json_err(msg) {
	http.prepare_content('application/json; charset=UTF-8');
	http.write_json({ ok: false, error: msg });
}

function method_not_allowed() {
	http.status(405, 'Method Not Allowed');
	http.header('Allow', 'POST');
	http.prepare_content('application/json; charset=UTF-8');
	http.write_json({ ok: false, error: 'method-not-allowed' });
}

return {
	action_run: function() {
		let action = http.formvalue('action') ?? 'list';
		let ips = [];

		// POST：直接尝试解析 JSON body（不依赖 Content-Type，
		// uhttpd CGI 环境里它叫 CONTENT_TYPE，且 http.header() 是响应头 setter）
		if ((http.getenv('REQUEST_METHOD') ?? 'GET') == 'POST') {
			const raw = http.content() ?? '';
			if (length(raw) > 0) {
				let body = null;
				try { body = json(raw); } catch (e) { body = null; }
				if (type(body) == 'object' && body.action != null) {
					action = body.action;
					if (type(body.ips) == 'array')
						ips = filter(body.ips, ip => type(ip) == 'string' && match(ip, IP_RE));
				}
			}
		}

		// 非 JSON POST 或解析失败时，回退到表单参数（GET 兼容）
		if (type(ips) != 'array' || length(ips) == 0) {
			const ip = http.formvalue('ip') ?? '';
			if (match(ip, IP_RE))
				ips = [ip];
		}

		if (action != 'list' && action != 'denylist' && action != 'allowlist'
		    && action != 'approve' && action != 'deny' && action != 'unban'
		    && action != 'unallow') {
			json_err('bad action');
			return;
		}
		/* 写动作仅允许 POST；list/denylist 只读可走 GET */
		const method = http.getenv('REQUEST_METHOD') ?? 'GET';
		if ((action == 'approve' || action == 'deny' || action == 'unban'
		    || action == 'unallow') && method != 'POST') {
			method_not_allowed();
			return;
		}
		if (action != 'list' && action != 'denylist' && action != 'allowlist' && length(ips) == 0) {
			json_err('no valid ip');
			return;
		}
		if (length(ips) > MAX_IPS) {
			json_err('too many ips');
			return;
		}

		let args = (action == 'list') ? shell_quote('list') : shell_quote(action);
		for (let i = 0; i < length(ips); i++)
			args += ' ' + shell_quote(ips[i]);

		const p = popen(
			`IPAPPROVE_SELFTEST=1 /bin/sh /www/cgi-bin/ip-approve ${args} | tail -n 1`,
			'r'
		);
		const out = p?.read('all') ?? '';
		p?.close();

		http.prepare_content('application/json; charset=UTF-8');
		http.write(out);
	}
};
