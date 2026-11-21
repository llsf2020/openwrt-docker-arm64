#!/usr/bin/ucode
// cfbest: pick the fastest Cloudflare IP for CDN-fronted proxy nodes and write
// it into the selected nodes of PassWall, PassWall2, HomeProxy, SSR-Plus,
// OpenClash and momo.
//
//   cfbest status    JSON status for LuCI
//   cfbest nodes     JSON list of the nodes of all installed proxy apps
//   cfbest run       select now (foreground)
//   cfbest start     select now (background)
//   cfbest test      measure only, change nothing (start-test: in the background)
//   cfbest cron      re-apply, check the current IPs, select again if slow
//   cfbest restore   put the original addresses back
//   cfbest sources   refresh the IP sources
//   cfbest log       last lines of the log

'use strict';

import { cursor } from 'uci';
import * as fs from 'fs';

const CFG = 'cfbest';
const DIR = '/etc/cfbest';
const STATE = DIR + '/state.json';
const CACHE = DIR + '/sources';
const WORK = '/tmp/cfbest';
const LOG = '/tmp/log/cfbest.log';
const PIDF = '/var/run/cfbest.pid';
const RUBY_HELPER = '/usr/share/cfbest/yaml.rb';
const NFT_TABLE = 'cfbest';
const OFFICIAL_URL = 'https://www.cloudflare.com/ips-v4';
// probes run as nobody:nogroup; OpenClash already lets gid 65534 through
const RUN_AS = 'nobody:nogroup';
const RUN_GID = 65534;
const CDN_TRANSPORTS = { ws: true, grpc: true, httpupgrade: true, xhttp: true, splithttp: true };
// HTTPS ports Cloudflare proxies
const CF_PORTS = { '443': true, '2053': true, '2083': true, '2087': true, '2096': true, '8443': true };
const FAIL = 99999;

let uci = cursor();

/* ---------- helpers ---------- */

function opt(name, def) {
	let v = uci.get(CFG, 'main', name);
	return (v == null || v === '') ? def : v;
}

function num(name, def) {
	let v = int(opt(name, def));
	return (v == null || v != v) ? def : v;
}

function q(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function sh(cmd) {
	let p = fs.popen(cmd, 'r');
	if (!p)
		return '';
	let out = p.read('all') ?? '';
	p.close();
	return out;
}

function ts(t) {
	let l = localtime(t ?? time());
	return sprintf('%04d-%02d-%02d %02d:%02d:%02d', l.year, l.mon, l.mday, l.hour, l.min, l.sec);
}

function today() {
	return substr(ts(), 0, 10);
}

function log(msg) {
	fs.mkdir('/tmp/log');
	let f = fs.open(LOG, 'a');
	if (f) {
		f.write(sprintf('[%s] %s\n', ts(), msg));
		f.close();
	}
	print(msg, '\n');
	let st = fs.stat(LOG);
	if (st && st.size > 200000) {
		let lines = split(trim(fs.readfile(LOG)), '\n');
		fs.writefile(LOG, join('\n', slice(lines, -500)) + '\n');
	}
}

function is_ip(s) {
	return !!match(s ?? '', /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/);
}

function median(vals) {
	vals = sort(vals, (a, b) => a - b);
	return vals[int((length(vals) - 1) / 2)];
}

function svc_exists(name) {
	return !!fs.access('/etc/init.d/' + name, 'x');
}

function procd_running(name) {
	return svc_exists(name) && system(['/etc/init.d/' + name, 'running']) == 0;
}

function first_global(conf, type, option) {
	if (!fs.access('/etc/config/' + conf))
		return null;
	uci.load(conf);
	return uci.get_first(conf, type, option);
}

/* ---------- lock (pid file, no inherited descriptors) ---------- */

function mypid() {
	return fs.readlink('/proc/self');
}

function busy_pid() {
	let pid = trim(fs.readfile(PIDF) ?? '');
	if (pid && pid != mypid() && fs.access('/proc/' + pid) &&
	    index(fs.readfile('/proc/' + pid + '/cmdline') ?? '', 'cfbest') >= 0)
		return pid;
	return null;
}

function lock() {
	if (busy_pid())
		return false;
	fs.writefile(PIDF, mypid());
	return true;
}

function unlock() {
	if (trim(fs.readfile(PIDF) ?? '') == mypid())
		fs.unlink(PIDF);
}

/* ---------- state ---------- */

function load_state() {
	let s = json(fs.readfile(STATE) ?? 'null') ?? {};
	s.hosts ??= {};
	s.orig ??= {};
	s.last_run ??= 0;
	s.day ??= '';
	s.day_count ??= 0;
	return s;
}

function save_state(s) {
	fs.mkdir(DIR);
	fs.writefile(STATE + '.tmp', sprintf('%.J\n', s));
	fs.rename(STATE + '.tmp', STATE);
}

/* ---------- backends ---------- */

// UCI based apps: one entry each
const UCI_APPS = {
	passwall: {
		name: 'PassWall', conf: 'passwall', type: 'nodes', addr: 'address', port: 'port', label: 'remarks',
		host: s => s.tls_serverName || s.ws_host || s.httpupgrade_host || s.xhttp_host || s.splithttp_host,
		path: s => s.ws_path || s.httpupgrade_path || s.xhttp_path || s.splithttp_path ||
			(s.grpc_serviceName ? '/' + s.grpc_serviceName + '/Tun' : null),
		tls: s => s.tls == '1',
		transport: s => s.transport,
		sni: 'tls_serverName', hosthdr: { ws: 'ws_host', httpupgrade: 'httpupgrade_host', xhttp: 'xhttp_host', splithttp: 'splithttp_host' },
		running: () => first_global('passwall', 'global', 'enabled') == '1',
		service: 'passwall', mark: () => '0xff'
	},
	passwall2: {
		name: 'PassWall2', conf: 'passwall2', type: 'nodes', addr: 'address', port: 'port', label: 'remarks',
		host: s => s.tls_serverName || s.ws_host || s.httpupgrade_host || s.xhttp_host || s.splithttp_host,
		path: s => s.ws_path || s.httpupgrade_path || s.xhttp_path || s.splithttp_path ||
			(s.grpc_serviceName ? '/' + s.grpc_serviceName + '/Tun' : null),
		tls: s => s.tls == '1',
		transport: s => s.transport,
		sni: 'tls_serverName', hosthdr: { ws: 'ws_host', httpupgrade: 'httpupgrade_host', xhttp: 'xhttp_host', splithttp: 'splithttp_host' },
		running: () => first_global('passwall2', 'global', 'enabled') == '1',
		service: 'passwall2', mark: () => '0xff'
	},
	homeproxy: {
		name: 'HomeProxy', conf: 'homeproxy', type: 'node', addr: 'address', port: 'port', label: 'label',
		host: s => s.tls_sni || s.ws_host || s.httpupgrade_host,
		path: s => s.ws_path || s.httpupgrade_path ||
			(s.grpc_servicename ? '/' + s.grpc_servicename + '/Tun' : null),
		tls: s => s.tls == '1',
		transport: s => s.transport,
		sni: 'tls_sni', hosthdr: { ws: 'ws_host', httpupgrade: 'httpupgrade_host' },
		running: () => procd_running('homeproxy'),
		service: 'homeproxy',
		mark: () => { uci.load('homeproxy'); return '' + (uci.get('homeproxy', 'infra', 'self_mark') || '100'); }
	},
	ssrplus: {
		name: 'SSR-Plus', conf: 'shadowsocksr', type: 'servers', addr: 'server', port: 'server_port', label: 'alias',
		host: s => s.tls_host || s.ws_host || s.httpupgrade_host || s.xhttp_host,
		path: s => s.ws_path || s.httpupgrade_path || s.xhttp_path ||
			(s.serviceName ? '/' + s.serviceName + '/Tun' : null),
		tls: s => s.tls == '1',
		transport: s => s.transport,
		sni: 'tls_host', hosthdr: { ws: 'ws_host', httpupgrade: 'httpupgrade_host', xhttp: 'xhttp_host' },
		running: () => (first_global('shadowsocksr', 'global', 'global_server') ?? 'nil') != 'nil',
		service: 'shadowsocksr', mark: () => null
	}
};

function mknode(app, id, label, address, port, host, path, transport, tls) {
	let n = {
		key: app + ':' + id, app: app, id: id, label: label ?? id,
		address: address ?? '', port: '' + (port || 443), host: host ?? '',
		path: path || '/', transport: transport || 'tcp', eligible: true, reason: ''
	};
	if (!n.host && n.address && !is_ip(n.address))
		n.host = n.address;   // SNI/Host default to the address
	if (!tls)
		n.reason = 'no TLS';
	else if (!n.host)
		n.reason = 'no SNI/Host';
	else if (!CDN_TRANSPORTS[n.transport])
		n.reason = 'transport ' + n.transport + ' cannot pass a CDN';
	else if (!CF_PORTS[n.port])
		n.reason = 'port ' + n.port + ' is not proxied by Cloudflare';
	if (n.reason)
		n.eligible = false;
	return n;
}

function uci_nodes(app) {
	let b = UCI_APPS[app], out = [];
	if (!fs.access('/etc/config/' + b.conf))
		return out;
	uci.load(b.conf);
	uci.foreach(b.conf, b.type, s => {
		if (!s[b.addr])
			return;
		push(out, mknode(app, s['.name'], s[b.label], s[b.addr], s[b.port], b.host(s), b.path(s),
			b.transport(s), b.tls(s)));
	});
	return out;
}

function uci_set(app, id, ip, host) {
	let b = UCI_APPS[app];
	uci.load(b.conf);
	if (uci.get(b.conf, id, b.addr) == ip)
		return false;
	// SNI and Host default to the address: keep the domain before the address becomes an IP
	if (host && is_ip(ip)) {
		if (!uci.get(b.conf, id, b.sni))
			uci.set(b.conf, id, b.sni, host);
		let hf = b.hosthdr[uci.get(b.conf, id, 'transport') ?? ''];
		if (hf && !uci.get(b.conf, id, hf))
			uci.set(b.conf, id, hf, host);
	}
	uci.set(b.conf, id, b.addr, ip);
	uci.commit(b.conf);
	return true;
}

// OpenClash: proxies in /etc/openclash/config/*.yaml, edited with ruby (OpenClash depends on ruby-yaml)
function openclash_files() {
	let d = '/etc/openclash/config';
	return filter(fs.lsdir(d) ?? [], f => match(f, /\.ya?ml$/)) ;
}

function openclash_nodes() {
	let out = [];
	if (!svc_exists('openclash') || !fs.access('/usr/bin/ruby', 'x'))
		return out;
	for (let f in openclash_files()) {
		let txt = sh('ruby ' + RUBY_HELPER + ' list ' + q('/etc/openclash/config/' + f) + ' 2>/dev/null');
		for (let line in split(txt, '\n')) {
			let c = split(line, '\t');
			if (length(c) < 7)
				continue;
			// name server port tls host path network
			push(out, mknode('openclash', f + '#' + c[0], f + ' / ' + c[0], c[1], c[2], c[4], c[5],
				c[6] == 'tcp' ? 'tcp' : c[6], c[3] == '1'));
		}
	}
	return out;
}

function openclash_set(id, ip) {
	let i = index(id, '#');
	let file = '/etc/openclash/config/' + substr(id, 0, i), name = substr(id, i + 1);
	let rc = system('ruby ' + RUBY_HELPER + ' set ' + q(file) + ' ' + q(name) + ' ' + q(ip) + ' >/dev/null 2>&1');
	return rc == 10;   // 10 = changed, 0 = already set
}

// momo (sing-box): outbounds in /etc/momo/profiles/*.json and /etc/momo/subscriptions/*.json
function momo_files() {
	let out = [];
	for (let d in ['profiles', 'subscriptions'])
		for (let f in fs.lsdir('/etc/momo/' + d) ?? [])
			if (match(f, /\.json$/))
				push(out, d + '/' + f);
	return out;
}

function momo_nodes() {
	let out = [];
	if (!svc_exists('momo'))
		return out;
	for (let f in momo_files()) {
		let j = json(fs.readfile('/etc/momo/' + f) ?? 'null');
		for (let o in (j?.outbounds ?? [])) {
			if (type(o) != 'object' || !o.server)
				continue;
			let t = o.transport ?? {};
			let host = o.tls?.server_name || t.headers?.Host || t.headers?.host || t.host;
			let path = t.path || (t.service_name ? '/' + t.service_name + '/Tun' : null);
			push(out, mknode('momo', f + '#' + o.tag, f + ' / ' + o.tag, o.server, o.server_port, host, path,
				t.type ?? 'tcp', !!o.tls?.enabled));
		}
	}
	return out;
}

function momo_set(id, ip, host) {
	let i = index(id, '#');
	let file = '/etc/momo/' + substr(id, 0, i), tag = substr(id, i + 1);
	let j = json(fs.readfile(file) ?? 'null');
	let changed = false;
	for (let o in (j?.outbounds ?? []))
		if (type(o) == 'object' && o.tag == tag && o.server != ip) {
			if (host && is_ip(ip)) {
				if (o.tls && !o.tls.server_name)
					o.tls.server_name = host;
				let t = o.transport;
				if (t?.type == 'ws' && !t.headers?.Host && !t.headers?.host) {
					t.headers ??= {};
					t.headers.Host = host;
				}
				if (t?.type == 'httpupgrade' && !t.host)
					t.host = host;
			}
			o.server = ip;
			changed = true;
		}
	if (changed) {
		fs.writefile(file + '.cfbest.tmp', sprintf('%.J\n', j));
		fs.rename(file + '.cfbest.tmp', file);
	}
	return changed;
}

const APPS = {
	passwall: UCI_APPS.passwall, passwall2: UCI_APPS.passwall2,
	homeproxy: UCI_APPS.homeproxy, ssrplus: UCI_APPS.ssrplus,
	openclash: {
		name: 'OpenClash', service: 'openclash', mark: () => null,
		running: () => first_global('openclash', 'openclash', 'enable') == '1'
	},
	momo: {
		name: 'momo', service: 'momo', mark: () => null,
		running: () => first_global('momo', 'momo', 'enabled') == '1' || procd_running('momo')
	}
};

function all_nodes() {
	let out = [];
	for (let app in ['passwall', 'passwall2', 'homeproxy', 'ssrplus'])
		for (let n in uci_nodes(app))
			push(out, n);
	for (let n in openclash_nodes())
		push(out, n);
	for (let n in momo_nodes())
		push(out, n);
	return out;
}

function set_address(node, ip) {
	if (UCI_APPS[node.app])
		return uci_set(node.app, node.id, ip, node.host);
	if (node.app == 'openclash')
		return openclash_set(node.id, ip);
	if (node.app == 'momo')
		return momo_set(node.id, ip, node.host);
	return false;
}

function restart_apps(apps) {
	for (let app in keys(apps)) {
		let a = APPS[app];
		if (!a.running()) {
			log(sprintf('%s is not running, not restarted', a.name));
			continue;
		}
		log(sprintf('restarting %s', a.name));
		system('/etc/init.d/' + a.service + ' restart >/dev/null 2>&1 </dev/null');
	}
}

function selected_nodes() {
	uci.load(CFG);
	let want = {};
	for (let k in (uci.get(CFG, 'main', 'node') ?? []))
		want[k] = true;
	let nodes = filter(all_nodes(), n => want[n.key] && n.eligible);
	if (opt('only_running', '1') == '1') {
		let up = {};
		for (let n in nodes)
			up[n.app] ??= APPS[n.app].running();
		let skipped = filter(nodes, n => !up[n.app]);
		if (length(skipped))
			log(sprintf('skipped (app not running): %s', join(', ', uniq(map(skipped, n => APPS[n.app].name)))));
		nodes = filter(nodes, n => up[n.app]);
	}
	return nodes;
}

// nodes grouped by SNI host: nodes of one host share the best IP
function groups(nodes) {
	let g = {};
	for (let n in nodes) {
		g[n.host] ??= { host: n.host, port: n.port, path: n.path, nodes: [] };
		push(g[n.host].nodes, n);
	}
	return g;
}

/* ---------- probing ---------- */

function bypass_mark() {
	let m = opt('bypass_mark', 'auto');
	if (m != 'auto')
		return (m == 'none') ? null : m;
	let marks = {};
	for (let app in keys(APPS)) {
		let a = APPS[app];
		if (!a.running())
			continue;
		let mk = a.mark();
		if (mk != null)
			marks[mk] = a.name;
	}
	let list = keys(marks);
	if (length(list) > 1)
		log(sprintf('several proxy apps with different bypass marks are running (%s), using %s',
			join(', ', map(list, k => marks[k] + '=' + k)), list[0]));
	return list[0];
}

function cf_ranges_file() {
	let f = CACHE + '/official.txt';
	if (fs.access(f))
		return f;
	for (let b in ['/usr/share/cfst/ip.txt', '/root/cfst/ip.txt'])
		if (fs.access(b))
			return b;
	return null;
}

function bypass_off() {
	system('nft delete table inet ' + NFT_TABLE + ' >/dev/null 2>&1');
}

function bypass_on() {
	bypass_off();
	let mark = bypass_mark();
	if (!mark)
		return true;
	let f = cf_ranges_file();
	if (!f)
		return false;
	let nets = filter(map(split(fs.readfile(f) ?? '', '\n'), l => trim(l)), l => match(l, /^[0-9.]+(\/[0-9]+)?$/));
	if (!length(nets))
		return false;
	let rules = sprintf('table inet %s {\n' +
		'  set cf { type ipv4_addr; flags interval; auto-merge; elements = { %s } }\n' +
		'  chain out { type route hook output priority -160; meta skgid %d ip daddr @cf tcp dport 443 meta mark set %s; }\n' +
		'}\n', NFT_TABLE, join(', ', nets), RUN_GID, mark);
	fs.mkdir(WORK);
	fs.writefile(WORK + '/bypass.nft', rules);
	return system('nft -f ' + WORK + '/bypass.nft >/dev/null 2>&1') == 0;
}


function run_as(bin, args) {
	return 'start-stop-daemon -S -p /var/run/cfbest-probe.pid -c ' + RUN_AS + ' -x ' + bin + ' -- ' + args;
}

// HTTP codes Cloudflare itself answers with when an IP does not serve the domain or the origin is down
const BAD_CODES = { '000': true, '403': true, '409': true, '530': true };

// time to first byte of "local -> CF colo -> origin" in ms (median of n) and the HTTP code;
// FAIL if unreachable, or if the code differs from what the working IP returned (expect)
function e2e(g, ip, n, expect) {
	let vals = [], codes = {};
	for (let i = 0; i < n; i++) {
		let r = trim(sh(run_as('/usr/bin/curl', sprintf("-s -m 8 -o /dev/null --resolve %s -w '%%{http_code} %%{time_starttransfer}' %s",
			q(g.host + ':' + g.port + ':' + ip), q('https://' + g.host + ':' + g.port + g.path))) + ' 2>/dev/null'));
		if (getenv('CFBEST_DEBUG'))
			warn(sprintf('probe %s %s -> [%s]\n', g.host, ip, r));
		let c = split(r, ' ');
		let code = c[0] || '000';
		codes[code] = true;
		if (BAD_CODES[code] || match(code, /^52/) || (expect && code != expect))
			push(vals, FAIL);
		else
			push(vals, int(+c[1] * 1000));
	}
	let ms = median(vals);
	let code = keys(codes)[0];
	return [ ms, code ];
}

// download speed from Cloudflare's speed test through this IP, in KB/s (0 if it fails)
function speed(ip) {
	let bytes = num('speed_bytes', 5) * 1000000;
	let r = trim(sh(run_as('/usr/bin/curl', sprintf("-s -m 20 -o /dev/null --resolve %s -w '%%{http_code} %%{speed_download}' %s",
		q('speed.cloudflare.com:443:' + ip), q('https://speed.cloudflare.com/__down?bytes=' + bytes))) + ' 2>/dev/null'));
	let c = split(r, ' ');
	return (c[0] == '200') ? int(+c[1] / 1000) : 0;
}

function min_speed() {
	// MB/s in the config, KB/s inside
	return int(+(opt('min_speed', '2')) * 1000);
}

/* ---------- IP sources ---------- */

function cache_name(url) {
	return CACHE + '/' + substr(replace(url, /[^A-Za-z0-9]+/g, '_'), 0, 120) + '.txt';
}

// IPv4 addresses and CIDRs at the start of each line ("1.2.3.4", "1.2.3.0/24", "1.2.3.4:443#HKG", "1.2.3.4,..." ...)
function parse_ips(txt) {
	let out = [];
	for (let line in split(txt, '\n')) {
		let m = match(line, /^[ \t"']*([0-9]{1,3}(\.[0-9]{1,3}){3})(\/[0-9]{1,2})?/);
		if (m)
			push(out, m[1] + (m[3] ?? ''));
	}
	return out;
}

// download a source; on failure fall back to the last good copy
function fetch(url, cachefile) {
	fs.mkdir(DIR);
	fs.mkdir(CACHE);
	let tmp = cachefile + '.tmp';
	let ok = system('curl -fsSL -m 30 -o ' + q(tmp) + ' ' + q(url) + ' >/dev/null 2>&1') == 0 &&
		length(parse_ips(fs.readfile(tmp) ?? '')) > 0;
	if (ok) {
		fs.rename(tmp, cachefile);
		return { url: url, ok: true, file: cachefile };
	}
	fs.unlink(tmp);
	return { url: url, ok: false, file: fs.access(cachefile) ? cachefile : null };
}


function ip2int(ip) {
	let a = iptoarr(ip);
	return a ? ((a[0] << 24) | (a[1] << 16) | (a[2] << 8) | a[3]) & 0xffffffff : null;
}

function in_ranges(entry, ranges) {
	let p = split(entry, '/');
	let ip = ip2int(p[0]);
	let bits = (p[1] != null) ? int(p[1]) : 32;
	if (ip == null)
		return false;
	for (let r in ranges)
		if (bits >= r.bits && ((ip ^ r.net) & r.mask) == 0)
			return true;
	return false;
}

function to_ranges(list) {
	let out = [];
	for (let e in list) {
		let p = split(e, '/');
		let bits = (p[1] != null) ? int(p[1]) : 32;
		let mask = bits == 0 ? 0 : (0xffffffff << (32 - bits)) & 0xffffffff;
		let net = ip2int(p[0]);
		if (net != null)
			push(out, { net: net & mask, mask: mask, bits: bits });
	}
	return out;
}

function refresh_sources() {
	uci.load(CFG);
	let report = [];
	push(report, fetch(OFFICIAL_URL, CACHE + '/official.txt'));
	for (let url in (uci.get(CFG, 'main', 'source_url') ?? []))
		push(report, fetch(url, cache_name(url)));
	return report;
}

function bundled_file() {
	for (let b in ['/usr/share/cfst/ip.txt', '/root/cfst/ip.txt'])
		if (fs.access(b))
			return b;
	return null;
}

// write the cfst input file; returns the number of entries
function build_ip_file() {
	let report = refresh_sources();
	let entries = [], seen = {};
	let add = (list, from) => {
		let before = length(entries);
		for (let e in list)
			if (!seen[e]) {
				seen[e] = true;
				push(entries, e);
			}
		log(sprintf('  source %s: %d entries (%d new)', from, length(list), length(entries) - before));
	};
	let official = report[0].file ? parse_ips(fs.readfile(report[0].file)) : [];
	if (opt('official', '1') == '1') {
		if (!report[0].ok)
			log('  could not download the Cloudflare ranges' + (report[0].file ? ', using the cached copy' : ''));
		add(official, 'Cloudflare');
	}
	for (let i = 1; i < length(report); i++) {
		let r = report[i];
		if (!r.ok)
			log(sprintf('  could not download %s%s', r.url, r.file ? ', using the cached copy' : ', skipped'));
		if (!r.file)
			continue;
		let list = parse_ips(fs.readfile(r.file));
		if (opt('restrict_cf', '0') == '1') {
			let ranges = to_ranges(length(official) ? official : parse_ips(fs.readfile(bundled_file() ?? '/dev/null') ?? ''));
			let n = length(list);
			list = filter(list, e => in_ranges(e, ranges));
			if (length(list) < n)
				log(sprintf('  %s: dropped %d entries outside the Cloudflare ranges', r.url, n - length(list)));
		}
		let max = num('max_entries', 5000);
		if (length(list) > max) {
			log(sprintf('  %s: using the first %d of %d entries', r.url, max, length(list)));
			list = slice(list, 0, max);
		}
		add(list, r.url);
	}
	if (opt('bundled', '0') == '1' || !length(entries)) {
		let b = bundled_file();
		if (b)
			add(parse_ips(fs.readfile(b)), 'bundled list');
	}

	// cfst samples one address per /24 anyway: split larger ranges into /24s so
	// that unusable /24s can be left out
	let expanded = [], limit = num('max_ranges', 20000);
	for (let e in entries) {
		let r = to_ranges([e])[0];
		if (!r)
			continue;
		if (r.bits >= 24) {
			push(expanded, e);
			continue;
		}
		let count = 1 << (24 - r.bits);
		for (let i = 0; i < count && length(expanded) < limit; i++) {
			let x = (r.net + (i << 8)) & 0xffffffff;
			push(expanded, arrtoip([ (x >> 24) & 255, (x >> 16) & 255, (x >> 8) & 255, 0 ]) + '/24');
		}
	}
	if (opt('exclude_special', '1') == '1') {
		let ex = to_ranges(uci.get(CFG, 'main', 'exclude') ?? []);
		let n = length(expanded);
		expanded = filter(expanded, e => !in_ranges(e, ex));
		log(sprintf('  left out %d ranges/IPs in the exclusion list', n - length(expanded)));
	}

	// IPs that were fast last time go first, so they are always measured again
	let st = load_state(), hist = [];
	if (opt('history', '1') == '1')
		for (let h in (st.good ?? []))
			if (!seen[h.ip + '/32'])
				push(hist, h.ip);
	if (length(hist))
		log(sprintf('  %d IPs from earlier selections', length(hist)));

	let all = [ ...hist, ...expanded ];
	fs.mkdir(WORK);
	system('chmod 0777 ' + WORK);
	fs.writefile(WORK + '/ips.txt', join('\n', all) + '\n');
	log(sprintf('  %d entries for cfst', length(all)));
	return length(all);
}

function cfst_bin() {
	for (let b in ['/usr/bin/cfst', '/root/cfst/cfst'])
		if (fs.access(b, 'x'))
			return b;
	return null;
}

/* ---------- selection ---------- */

function resolve(host) {
	let out = sh('nslookup ' + q(host) + ' 127.0.0.1 2>/dev/null');
	for (let line in split(out, '\n')) {
		let m = match(line, /^Address[^:]*: *([0-9.]+)$/);
		if (m && m[1] != '127.0.0.1')
			return m[1];
	}
	return null;
}

function optimize(st, nodes, dry) {
	let bin = cfst_bin();
	if (!bin) {
		log('cfst not found, nothing done');
		return false;
	}
	let g = groups(nodes);
	if (!length(g)) {
		log('no nodes selected');
		return false;
	}
	log(sprintf('selecting for %d domain(s): %s', length(g), join(', ', keys(g))));
	let n = build_ip_file();
	if (!n) {
		log('no IPs from any source, nothing done');
		return false;
	}
	if (!bypass_on()) {
		log('could not create the nft bypass table, nothing done');
		return false;
	}
	let csv = WORK + '/result.csv';
	fs.unlink(csv);
	system(sprintf('cd %s && %s >%s/cfst.out 2>&1', WORK,
		run_as(bin, sprintf('-f %s/ips.txt -httping -tp 443 -dd -tl %d -n %d -p 0 -o %s',
			WORK, num('max_latency', 400), num('threads', 50), csv)), WORK));
	let rows = slice(split(trim(fs.readfile(csv) ?? ''), '\n'), 1);
	if (!dry)
		st.last_run = time();
	if (!length(rows)) {
		bypass_off();
		if (!dry)
			save_state(st);
		log('cfst found nothing: ' + replace(trim(substr(fs.readfile(WORK + '/cfst.out') ?? '', -200)), /\n/g, ' '));
		return false;
	}
	// the lowest-latency IPs of each colo
	let per = num('per_colo', 2), maxc = num('candidates', 20), cnt = {}, cands = [];
	for (let r in rows) {
		let c = split(r, ',');
		let colo = c[length(c) - 1];
		cnt[colo] ??= 0;
		if (cnt[colo] < per && length(cands) < maxc) {
			cnt[colo]++;
			push(cands, { ip: c[0], colo: colo });
		}
	}
	log(sprintf('cfst: %d IPs, %d candidates from %d colos', length(rows), length(cands), length(cnt)));

	let probes = num('probes', 3), improve = num('improve', 20), changed_apps = {}, good = {};
	for (let h in (st.good ?? []))
		good[h.ip] = h;
	for (let host in keys(g)) {
		let gr = g[host];
		let addr = gr.nodes[0].address;
		let cur_ip = is_ip(addr) ? addr : resolve(host);
		let h0 = st.hosts[host] ?? {};
		let cr = cur_ip ? e2e(gr, cur_ip, probes, null) : [ FAIL, '000' ];
		let cur = cr[0];
		// the code the working IP gets from the origin; a candidate must get the same
		let expect = (cur < FAIL) ? cr[1] : h0.code;
		if (expect)
			log(sprintf('%s: origin answers %s', host, expect));
		let ok = [];
		for (let c in cands) {
			let r = e2e(gr, c.ip, probes, expect), s = r[0];
			log(sprintf('  %s  %s (%s) %s', host, c.ip, c.colo, s >= FAIL ? 'unusable (' + r[1] + ')' : s + 'ms'));
			if (s < FAIL) {
				push(ok, { ip: c.ip, colo: c.colo, score: s });
				if (!good[c.ip] || s < good[c.ip].score)
					good[c.ip] = { ip: c.ip, colo: c.colo, score: s, time: st.last_run };
			}
		}
		ok = sort(ok, (a, b) => a.score - b.score);
		let best = ok[0];
		let want_speed = min_speed();
		if (best && want_speed > 0) {
			// fastest response first, but it has to reach the minimum speed
			let fastest = null;
			for (let c in slice(ok, 0, num('speed_candidates', 5))) {
				c.speed = speed(c.ip);
				log(sprintf('  %s  %s download %.1f MB/s', host, c.ip, c.speed / 1000.0));
				if (!fastest || c.speed > fastest.speed)
					fastest = c;
				if (c.speed >= want_speed) {
					best = c;
					break;
				}
			}
			if (best.speed == null || best.speed < want_speed) {
				log(sprintf('%s: no candidate reaches %.1f MB/s, taking the fastest download', host, want_speed / 1000.0));
				best = fastest;
			}
		}
		if (dry) {
			if (best)
				log(sprintf('%s: current %s %s, best %s (%s) %dms (test only, nothing changed)', host, cur_ip ?? '?',
					cur >= FAIL ? 'unreachable' : cur + 'ms', best.ip, best.colo, best.score));
			else
				log(sprintf('%s: no candidate reachable (test only)', host));
			continue;
		}
		let h = st.hosts[host] ?? {};
		h.last_run = st.last_run;
		if (!best) {
			log(sprintf('%s: no candidate reachable, keeping %s', host, addr));
			st.hosts[host] = h;
			continue;
		}
		log(sprintf('%s: current %s %s, best %s (%s) %dms', host, cur_ip ?? '?', cur >= FAIL ? 'unreachable' : cur + 'ms',
			best.ip, best.colo, best.score));
		let keep = is_ip(addr) && (best.ip == addr || best.score * 100 >= cur * (100 - improve));
		if (keep && want_speed > 0 && best.ip != addr) {
			let cs = speed(addr);
			if (cs < want_speed && (best.speed ?? 0) > cs) {
				log(sprintf('%s: current %s only %.1f MB/s, replacing', host, addr, cs / 1000.0));
				keep = false;
			}
		}
		if (keep) {
			log(sprintf('%s: less than %d%% faster, keeping %s', host, improve, addr));
			h.ip = addr;
			h.score = cur;
			h.colo ??= '';
		}
		else {
			h.ip = best.ip;
			h.colo = best.colo;
			h.score = best.score;
			h.speed = best.speed;
		}
		if (expect)
			h.code = expect;
		h.fails = 0;
		h.speed_fails = 0;
		st.hosts[host] = h;
		for (let nd in gr.nodes) {
			st.orig[nd.key] ??= is_ip(nd.address) ? nd.host : nd.address;
			if (set_address(nd, h.ip)) {
				log(sprintf('  %s %s: %s -> %s', APPS[nd.app].name, nd.label, nd.address, h.ip));
				changed_apps[nd.app] = true;
			}
		}
	}
	if (dry) {
		bypass_off();
		return true;
	}
	// keep the 20 fastest of the last week
	let week = st.last_run - 7 * 86400;
	st.good = slice(sort(filter(values(good), x => x.time >= week), (a, b) => a.score - b.score), 0, num('history_size', 20));
	bypass_off();
	save_state(st);
	restart_apps(changed_apps);
	return true;
}

/* ---------- commands ---------- */

// write the stored IP back into nodes that lost it (subscription update, manual edit)
function reapply(st, nodes) {
	let changed_apps = {};
	for (let nd in nodes) {
		let h = st.hosts[nd.host];
		if (!h?.ip || nd.address == h.ip)
			continue;
		st.orig[nd.key] ??= is_ip(nd.address) ? nd.host : nd.address;
		if (set_address(nd, h.ip)) {
			log(sprintf('%s %s: address was %s, set back to %s', APPS[nd.app].name, nd.label, nd.address, h.ip));
			changed_apps[nd.app] = true;
		}
	}
	if (length(changed_apps)) {
		save_state(st);
		restart_apps(changed_apps);
	}
}

function slow_limit(h) {
	let lim = num('slow_ms', 1500);
	if (h.score && h.score < FAIL && h.score * num('slow_factor', 3) > lim)
		lim = h.score * num('slow_factor', 3);
	return lim;
}

function cmd_cron() {
	let st = load_state();
	let nodes = selected_nodes();
	if (!length(nodes))
		return;
	reapply(st, nodes);

	let running = filter(nodes, n => APPS[n.app].running());
	if (!length(running))
		return;   // nothing in use: no checks, no selection
	if (opt('only_running', '1') != '1')
		running = nodes;
	let g = groups(running), need = false, fail_limit = num('fail_limit', 3);
	if (!bypass_on())
		log('could not create the nft bypass table, checking without it');
	for (let host in keys(g)) {
		let h = st.hosts[host];
		if (!h?.ip) {
			log(sprintf('%s: no IP selected yet', host));
			need = true;
			continue;
		}
		let s = e2e(g[host], h.ip, 1, h.code)[0], lim = slow_limit(h);
		let want_speed = min_speed();
		if (want_speed > 0 && s < FAIL && time() - (h.speed_time ?? 0) >= num('speed_interval', 30) * 60) {
			h.speed_time = time();
			h.speed = speed(h.ip);
			if (h.speed < want_speed) {
				h.speed_fails = (h.speed_fails ?? 0) + 1;
				log(sprintf('%s: %s download %.1f MB/s, below %.1f MB/s (%d in a row)', host, h.ip, h.speed / 1000.0,
					want_speed / 1000.0, h.speed_fails));
				if (h.speed_fails >= num('speed_fail_limit', 2))
					need = true;
			}
			else
				h.speed_fails = 0;
		}
		if (s <= lim) {
			if (h.fails) {
				log(sprintf('%s: %s back to normal (%dms)', host, h.ip, s));
				h.fails = 0;
			}
			continue;
		}
		h.fails = (h.fails ?? 0) + 1;
		log(sprintf('%s: %s %s, limit %dms (%d in a row)', host, h.ip, s >= FAIL ? 'unreachable' : 'slow: ' + s + 'ms', lim, h.fails));
		if (h.fails >= fail_limit)
			need = true;
	}
	bypass_off();
	save_state(st);
	if (!need)
		return;
	if (time() - st.last_run < num('cooldown', 60) * 60) {
		log(sprintf('last selection less than %d minutes ago, waiting', num('cooldown', 60)));
		return;
	}
	if (st.day != today()) {
		st.day = today();
		st.day_count = 0;
	}
	let daily_max = num('daily_max', 3);   // 0 = no limit
	if (daily_max > 0 && st.day_count >= daily_max) {
		log(sprintf('already selected %d times today, waiting for tomorrow', st.day_count));
		save_state(st);
		return;
	}
	st.day_count++;
	save_state(st);
	log(sprintf('automatic selection (%d today)', st.day_count));
	optimize(st, nodes);
}

function cmd_restore() {
	let st = load_state();
	let changed_apps = {};
	uci.load(CFG);
	let want = {};
	for (let k in (uci.get(CFG, 'main', 'node') ?? []))
		want[k] = true;
	for (let nd in all_nodes()) {
		let o = st.orig[nd.key];
		if (!o || !want[nd.key] || nd.address == o)
			continue;
		if (set_address(nd, o)) {
			log(sprintf('%s %s: address restored to %s (was %s)', APPS[nd.app].name, nd.label, o, nd.address));
			changed_apps[nd.app] = true;
		}
	}
	st.hosts = {};
	save_state(st);
	restart_apps(changed_apps);
	if (!length(changed_apps))
		log('nothing to restore');
}

function cmd_status() {
	let st = load_state();
	let nodes = all_nodes();
	uci.load(CFG);
	let want = {};
	for (let k in (uci.get(CFG, 'main', 'node') ?? []))
		want[k] = true;
	let apps = {};
	for (let app in keys(APPS)) {
		let a = APPS[app];
		let installed = (app == 'openclash' || app == 'momo') ? svc_exists(a.service) : fs.access('/etc/config/' + a.conf);
		if (installed)
			apps[app] = { name: a.name, running: a.running() };
	}
	for (let n in nodes) {
		n.selected = !!want[n.key];
		n.app_name = APPS[n.app].name;
		n.best = st.hosts[n.host]?.ip ?? null;
	}
	let hosts = {};
	for (let host in keys(st.hosts)) {
		hosts[host] = st.hosts[host];
		hosts[host].limit = slow_limit(st.hosts[host]);
	}
	let sources = [];
	for (let f in fs.lsdir(CACHE) ?? []) {
		let s = fs.stat(CACHE + '/' + f);
		push(sources, { file: f, mtime: s ? ts(s.mtime) : null, entries: length(parse_ips(fs.readfile(CACHE + '/' + f) ?? '')) });
	}
	printf('%.J\n', {
		running: !!busy_pid(),
		cfst: cfst_bin(),
		apps: apps,
		nodes: nodes,
		hosts: hosts,
		last_run: st.last_run ? ts(st.last_run) : null,
		today: (st.day == today()) ? st.day_count : 0,
		daily_max: num('daily_max', 3),
		min_speed: min_speed(),
		only_running: opt('only_running', '1') == '1',
		fail_limit: num('fail_limit', 3),
		auto: opt('auto', '0') == '1',
		bypass_mark: bypass_mark() ?? null,
		sources: sources
	});
}

let cmd = ARGV[0] ?? 'status';

if (cmd == 'status') {
	cmd_status();
}
else if (cmd == 'nodes') {
	printf('%.J\n', all_nodes());
}
else if (cmd == 'log') {
	print(join('\n', slice(split(trim(fs.readfile(LOG) ?? ''), '\n'), -int(ARGV[1] ?? 200))), '\n');
}
else if (cmd == 'start') {
	if (busy_pid()) {
		print('already running\n');
		exit(1);
	}
	system('/usr/bin/cfbest run >/dev/null 2>&1 </dev/null &');
	print('started\n');
}
else if (cmd == 'sources') {
	fs.mkdir(DIR);
	for (let r in refresh_sources())
		printf('%s %s %s\n', r.ok ? 'ok    ' : 'failed', r.url, r.file ? sprintf('(%d entries)', length(parse_ips(fs.readfile(r.file)))) : '');
}
else if (cmd == 'probe') {
	// cfbest probe <host> <port> <path> <ip> [n]
	let g = { host: ARGV[1], port: ARGV[2] ?? '443', path: ARGV[3] ?? '/' };
	let r = e2e(g, ARGV[4], int(ARGV[5] ?? 3), null);
	print(r[0] >= FAIL ? 'unusable (' + r[1] + ')\n' : r[0] + 'ms (' + r[1] + ')\n');
	if (ARGV[6] == 'speed')
		printf('%.1f MB/s\n', speed(ARGV[4]) / 1000.0);
}
else if (cmd == 'start-test') {
	if (busy_pid()) {
		print('already running\n');
		exit(1);
	}
	system('/usr/bin/cfbest test >/dev/null 2>&1 </dev/null &');
	print('started\n');
}
else if (cmd == 'run' || cmd == 'test' || cmd == 'cron' || cmd == 'restore') {
	if (!lock()) {
		if (cmd != 'cron')
			print('already running\n');
		exit(cmd == 'cron' ? 0 : 1);
	}
	let rc = 0;
	try {
		if (cmd == 'run' || cmd == 'test') {
			let st = load_state();
			let nodes = selected_nodes();
			if (!length(nodes)) {
				log('no nodes selected');
				rc = 1;
			}
			else {
				log(cmd == 'test' ? 'test run, no node will be changed' : 'manual selection');
				rc = optimize(st, nodes, cmd == 'test') ? 0 : 1;
			}
		}
		else if (cmd == 'cron')
			cmd_cron();
		else
			cmd_restore();
	}
	catch (e) {
		log('error: ' + e);
		rc = 1;
	}
	bypass_off();
	unlock();
	exit(rc);
}
else {
	print('usage: cfbest [status|nodes|run|start|test|start-test|cron|restore|sources|log]\n');
	exit(1);
}
