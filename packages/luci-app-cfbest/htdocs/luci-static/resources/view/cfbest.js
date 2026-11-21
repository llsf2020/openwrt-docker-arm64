'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require poll';

const BIN = '/usr/bin/cfbest';

function callStatus() {
	return fs.exec_direct(BIN, ['status'], 'json').catch(function(e) {
		return { error: e.message };
	});
}

function fmtScore(v) {
	if (v == null)
		return '-';
	return v >= 99999 ? _('unreachable') : v + ' ms';
}

function renderStatus(st) {
	if (st.error)
		return E('div', { 'class': 'alert-message warning' }, st.error);

	const apps = Object.keys(st.apps || {}).map(function(k) {
		const a = st.apps[k];
		return E('span', { 'style': 'margin-right:1.5em' }, [
			a.name, ': ',
			E('strong', { 'style': 'color:' + (a.running ? 'green' : 'gray') }, a.running ? _('running') : _('stopped'))
		]);
	});

	const rows = [E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, _('Domain')),
		E('th', { 'class': 'th' }, _('Current IP')),
		E('th', { 'class': 'th' }, _('Colo')),
		E('th', { 'class': 'th' }, _('Score')),
		E('th', { 'class': 'th' }, _('Speed')),
		E('th', { 'class': 'th' }, _('Slow limit')),
		E('th', { 'class': 'th' }, _('Slow in a row')),
		E('th', { 'class': 'th' }, _('Last selection'))
	])];
	Object.keys(st.hosts || {}).forEach(function(h) {
		const x = st.hosts[h];
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, h),
			E('td', { 'class': 'td' }, x.ip || '-'),
			E('td', { 'class': 'td' }, x.colo || '-'),
			E('td', { 'class': 'td' }, fmtScore(x.score)),
			E('td', { 'class': 'td' }, x.speed != null ? (x.speed / 1000).toFixed(1) + ' MB/s' : '-'),
			E('td', { 'class': 'td' }, x.limit ? x.limit + ' ms' : '-'),
			E('td', { 'class': 'td' }, (x.fails || 0) + ' / ' + st.fail_limit),
			E('td', { 'class': 'td' }, x.last_run ? new Date(x.last_run * 1000).toLocaleString() : '-')
		]));
	});
	if (rows.length == 1)
		rows.push(E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', 'colspan': 8 }, _('No selection yet.'))));

	return E('div', {}, [
		E('p', {}, apps.length ? apps : _('No supported proxy app is installed.')),
		E('p', {}, [
			_('State'), ': ',
			E('strong', {}, st.running ? _('selecting…') : _('idle')),
			' · ', _('Automatic'), ': ', st.auto ? _('on') : _('off'),
			' · ', _('Automatic selections today'), ': ', st.today + ' / ' + (st.daily_max > 0 ? st.daily_max : _('no limit')),
			' · ', _('Minimum speed'), ': ', st.min_speed > 0 ? (st.min_speed / 1000).toFixed(1) + ' MB/s' : _('off'),
			' · ', _('Last selection'), ': ', st.last_run || '-',
			' · ', _('Bypass mark'), ': ', st.bypass_mark || _('none'),
			st.cfst ? '' : E('span', { 'style': 'color:red' }, ' · ' + _('cfst is missing'))
		]),
		E('table', { 'class': 'table' }, rows)
	]);
}

function runCmd(args, msg) {
	return fs.exec(BIN, args).then(function(res) {
		ui.addNotification(null, E('p', (res.stdout || '').trim() || msg), 'info');
	}).catch(function(e) {
		ui.addNotification(null, E('p', e.message), 'danger');
	});
}

return view.extend({
	load: function() {
		return Promise.all([callStatus(), uci.load('cfbest')]);
	},

	render: function(data) {
		const st = data[0];
		const nodes = st.nodes || [];
		let m, s, o;

		m = new form.Map('cfbest', _('Cloudflare IP selection'),
			_('Finds the fastest Cloudflare IP for proxy nodes behind the Cloudflare CDN and writes it into the selected nodes. The original domain stays as SNI/Host. Every few minutes the current IP is checked; only when it gets slow is a new IP selected.'));

		/* status and actions */
		s = m.section(form.NamedSection, 'main', 'cfbest', _('Status'));
		o = s.option(form.DummyValue, '_status');
		o.rawhtml = true;
		o.cfgvalue = function() {
			return E('div', { 'id': 'cfbest-status' }, renderStatus(st));
		};
		o = s.option(form.DummyValue, '_actions');
		o.rawhtml = true;
		o.cfgvalue = function() {
			return E('div', {}, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, function() {
						return runCmd(['start'], _('Selection started, see the log below.'));
					})
				}, _('Select now')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function() {
						return runCmd(['start-test'], _('Test started, nothing will be changed.'));
					})
				}, _('Test only')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function() {
						return runCmd(['sources'], _('Sources refreshed.'));
					})
				}, _('Refresh IP sources')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-reset',
					'click': ui.createHandlerFn(this, function() {
						if (!confirm(_('Put the original domains back into the selected nodes?')))
							return;
						return runCmd(['restore'], _('Restored.'));
					})
				}, _('Restore domains'))
			]);
		};

		/* nodes */
		s = m.section(form.NamedSection, 'main', 'cfbest', _('Nodes'),
			_('Nodes behind the Cloudflare CDN (TLS, a domain as SNI/Host, WebSocket/gRPC/HTTPUpgrade/XHTTP transport, a Cloudflare HTTPS port). Nodes with the same domain share one IP. Only apps that are running are restarted after a change.'));
		o = s.option(form.MultiValue, 'node', _('Nodes to replace'));
		o.widget = 'checkbox';
		o.display_size = 20;
		nodes.filter(function(n) { return n.eligible; }).forEach(function(n) {
			o.value(n.key, '[' + n.app_name + '] ' + n.label + ' — ' + n.host + ':' + n.port +
				' (' + _('now') + ' ' + n.address + ')');
		});
		const skipped = nodes.filter(function(n) { return !n.eligible; });
		if (skipped.length) {
			o = s.option(form.DummyValue, '_skipped', _('Not usable'));
			o.rawhtml = true;
			o.cfgvalue = function() {
				return E('ul', {}, skipped.map(function(n) {
					return E('li', {}, '[' + n.app_name + '] ' + n.label + ': ' + n.reason);
				}));
			};
		}

		/* automatic */
		s = m.section(form.NamedSection, 'main', 'cfbest', _('Automatic'));
		o = s.option(form.Flag, 'only_running', _('Only for running apps'),
			_('Nodes of an app that is not running are neither changed nor selected for, also when selecting by hand.'));
		o.default = '1';
		o = s.option(form.Flag, 'auto', _('Check automatically'),
			_('Checks the current IP of every domain. Only checks while the app of the node is running.'));
		o = s.option(form.Value, 'interval', _('Check every (minutes)'));
		o.datatype = 'range(1,59)';
		o.placeholder = '5';
		o = s.option(form.Value, 'slow_ms', _('Slow above (ms)'),
			_('Time to first byte through the CDN to the origin. The limit is the larger of this and the score of the last selection × the factor below.'));
		o.datatype = 'uinteger';
		o.placeholder = '1500';
		o = s.option(form.Value, 'slow_factor', _('Or score × factor'));
		o.datatype = 'uinteger';
		o.placeholder = '3';
		o = s.option(form.Value, 'fail_limit', _('Select again after slow checks in a row'));
		o.datatype = 'range(1,100)';
		o.placeholder = '3';
		o = s.option(form.Value, 'cooldown', _('At least between two selections (minutes)'));
		o.datatype = 'uinteger';
		o.placeholder = '60';
		o = s.option(form.Value, 'daily_max', _('Automatic selections per day at most'), _('0: no limit.'));
		o.datatype = 'uinteger';
		o.placeholder = '3';
		o = s.option(form.Value, 'min_speed', _('Select again below (MB/s)'),
			_('Download speed from Cloudflare through the current IP. Measured at most every interval below; selects again after slow measurements in a row. During a selection, candidates must reach it too. 0: no speed check.'));
		o.datatype = 'ufloat';
		o.placeholder = '2';
		o = s.option(form.Value, 'speed_interval', _('Measure the speed every (minutes)'));
		o.datatype = 'range(5,1440)';
		o.placeholder = '30';
		o = s.option(form.Value, 'speed_bytes', _('Download size (MB)'),
			_('Each measurement downloads this much: 5 MB every 30 minutes is about 240 MB a day.'));
		o.datatype = 'range(1,100)';
		o.placeholder = '5';
		o = s.option(form.Value, 'speed_fail_limit', _('Select again after slow speed measurements in a row'));
		o.datatype = 'range(1,20)';
		o.placeholder = '2';

		/* sources */
		s = m.section(form.NamedSection, 'main', 'cfbest', _('IP sources'),
			_('All sources are merged and measured in one cfst run. A source that cannot be downloaded falls back to its last copy.'));
		o = s.option(form.Flag, 'official', _('Cloudflare ranges'), 'https://www.cloudflare.com/ips-v4');
		o.default = '1';
		o = s.option(form.DynamicList, 'source_url', _('Other lists (URL)'),
			_('Text lists of IPs or ranges, one per line. Lines such as "1.2.3.4:443#HKG" or CSV are accepted, only the address at the start of the line is used.'));
		o.datatype = 'string';
		o = s.option(form.Flag, 'restrict_cf', _('Only keep IPs in the Cloudflare ranges'),
			_('Applies to the other lists.'));
		o = s.option(form.Value, 'max_entries', _('At most entries per list'));
		o.datatype = 'uinteger';
		o.placeholder = '5000';
		o = s.option(form.Flag, 'history', _('Measure the fastest IPs of earlier selections again'));
		o.default = '1';
		o = s.option(form.Flag, 'bundled', _('Always add the list that comes with cfst'),
			_('Used anyway when no other source gives anything.'));
		o = s.option(form.Flag, 'exclude_special', _('Leave out unusable ranges'));
		o.default = '1';
		o = s.option(form.DynamicList, 'exclude', _('Ranges left out'),
			_('Cloudflare ranges that are special-purpose or do not serve proxied sites.'));
		o.datatype = 'cidr4';
		o.depends('exclude_special', '1');

		/* measuring */
		s = m.section(form.NamedSection, 'main', 'cfbest', _('Measuring'));
		o = s.option(form.Value, 'threads', _('cfst threads'));
		o.datatype = 'range(1,1000)';
		o.placeholder = '50';
		o = s.option(form.Value, 'max_latency', _('cfst latency limit (ms)'));
		o.datatype = 'uinteger';
		o.placeholder = '400';
		o = s.option(form.Value, 'per_colo', _('Candidates per colo'));
		o.datatype = 'range(1,20)';
		o.placeholder = '2';
		o = s.option(form.Value, 'speed_candidates', _('Speed-test at most this many candidates'));
		o.datatype = 'range(1,20)';
		o.placeholder = '5';
		o = s.option(form.Value, 'candidates', _('Candidates at most'));
		o.datatype = 'range(1,100)';
		o.placeholder = '20';
		o = s.option(form.Value, 'probes', _('Requests per candidate'));
		o.datatype = 'range(1,10)';
		o.placeholder = '3';
		o = s.option(form.Value, 'improve', _('Replace only when faster by (%)'));
		o.datatype = 'range(0,99)';
		o.placeholder = '20';
		o = s.option(form.Value, 'bypass_mark', _('Bypass mark'),
			_('Firewall mark that lets the measuring traffic past the transparent proxy. auto: 0xff for PassWall/PassWall2, the self mark of HomeProxy; OpenClash needs none. none: no mark.'));
		o.placeholder = 'auto';

		/* log */
		s = m.section(form.NamedSection, 'main', 'cfbest', _('Log'));
		o = s.option(form.DummyValue, '_log');
		o.rawhtml = true;
		o.cfgvalue = function() {
			return E('textarea', {
				'id': 'cfbest-log', 'readonly': 'readonly', 'wrap': 'off', 'rows': 20,
				'style': 'width:100%;font-family:monospace;font-size:12px'
			}, '');
		};

		poll.add(function() {
			return Promise.all([callStatus(), fs.exec_direct(BIN, ['log', '300']).catch(function() { return ''; })])
				.then(function(r) {
					const box = document.getElementById('cfbest-status');
					if (box)
						box.replaceChildren(renderStatus(r[0]));
					const log = document.getElementById('cfbest-log');
					if (log && log.value != r[1]) {
						const atEnd = log.scrollTop + log.clientHeight >= log.scrollHeight - 5;
						log.value = r[1];
						if (atEnd)
							log.scrollTop = log.scrollHeight;
					}
				});
		}, 5);

		return m.render();
	}
});
