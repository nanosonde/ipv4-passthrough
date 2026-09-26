'use strict';
/* ip4pt status view -- lists every handled host with its DHCP hostname
 * (Name, when the client sent one), IP + MAC, its online/suspended state
 * and the countdowns to both GC tiers, plus a per-row Remove action. All
 * data comes from /usr/libexec/ip4pt-status
 * (JSON), which derives everything from ip4pt's own state files +
 * ebtables listing. The Remove buttons run /usr/libexec/ip4pt-remove
 * (single <ip>, or --suspended for all suspended rows) via rpcd file
 * exec (write ACL) -- the same deprovision_host the GC uses; every
 * removed host is re-learned from its next ARP.
 *
 * The table uses cbi_update_table() -- the same official luci-base binding
 * the core Status -> Routes page uses -- which provides the clickable
 * column-sort headers and remembers the chosen sort across refreshes. */

'require view';
'require fs';
'require ui';
'require dom';
'require poll';

var HELPER = '/usr/libexec/ip4pt-status';
var REMOVER = '/usr/libexec/ip4pt-remove';
/* The GC acts on its own cadence (GC_INTERVAL, 60s by default), so polling
 * faster than that would only re-learn what the helper already reports. */
var POLL_INTERVAL = 30; /* seconds */

/* null -> "never";  900 -> "15m";  3720 -> "1h 2m";  2592000 -> "30d" */
function fmtDur(secs) {
	if (secs == null)
		return _('never');

	secs = Math.max(0, Number(secs) || 0);

	if (secs < 60)
		return '%ds'.format(secs);

	var d = Math.floor(secs / 86400),
	    h = Math.floor((secs % 86400) / 60 / 60),
	    m = Math.floor((secs % 3600) / 60);

	if (d > 0)
		return (h > 0) ? '%dd %dh'.format(d, h) : '%dd'.format(d);

	return (h > 0) ? '%dh %dm'.format(h, m) : '%dm'.format(m);
}

/* Sortable cells need the raw number as the sort key: cbi_update_table()
 * derives it from a `data-value` attribute when present, falling back to
 * the cell text (which would sort "9m" > "1h 2m" > "15m" lexically).
 * L.ui.Table.deriveSortKey() parses data-value as a plain integer, and
 * L.naturalCompare() orders those numerically. */
function durCell(secs) {
	if (secs == null)
		return _('disabled');

	return E('span', { 'data-value': secs }, fmtDur(secs));
}

/* Map the helper's JSON to cbi_update_table() row arrays (column order =
 * the table headings below). The Name cell leads: DHCP hostnames are purely
 * informational, so a client that never sent option 12 (e.g. iOS) shows an
 * em dash; a plain string sorts lexically, which is what one wants for
 * names. The IP cell carries the raw string so the official dotted-quad
 * sort applies; duration cells carry a data-value with the raw seconds so
 * they sort numerically; the trailing Actions cell holds the Remove
 * button, and cbi-section-actions on that column keeps the sort machinery
 * from making it sortable (the official non-sortable-column marker, same as
 * the firewall rules table). */
function toRows(view, data) {
	return (data.hosts || []).map(function(host) {
		var online = (host.online === true);

		return [
			(host.name == null) ? '—' : host.name,
			host.ip,
			host.mac,
			durCell(host.age),
			online ? _('Online') : _('Suspended'),
			/* The suspension countdown is meaningless once the host is
			 * already suspended (it would only ever read "0s"); show a
			 * dash instead. A disabled tier stays "disabled" either way. */
			(host.suspend_in == null) ? _('disabled')
				: (online ? durCell(host.suspend_in) : '—'),
			(host.remove_in == null) ? _('disabled') : durCell(host.remove_in),
			E('button', {
				'class': 'btn cbi-button-remove',
				'click': ui.createHandlerFn(view, 'handleRemove', host.ip, host.mac)
			}, _('Remove'))
		];
	});
}

function renderBody(view, data) {
	var nodes = [];

	if (data.service_running !== true)
		nodes.push(E('p', { 'class': 'alert-message warning' },
			_('The ip4pt discovery daemon does not appear to be running. The Status column below is unreliable until it is restarted.')));

	nodes.push(E('p', {},
		_('Hosts handled by ip4pt. Bindings are learned passively from ARP on the mirror port; a host is marked suspended (the FritzBox then shows it offline) after %s of silence and its binding removed after %s.').format(
			(data.offline_secs > 0) ? fmtDur(data.offline_secs) : _('(tier disabled)'),
			(data.stale_secs > 0) ? fmtDur(data.stale_secs) : _('(tier disabled)'))));

	if (!(data.hosts || []).length) {
		nodes.push(E('p', {},
			_('No hosts handled yet -- waiting for ARP traffic on the mirror port.')));
		return nodes;
	}

	/* The bulk action for the suspended rows below: one click removes
	 * every binding currently shown as Suspended. Always visible, but
	 * greyed out (disabled) while there is nothing to remove. */
	var suspendedCount = (data.hosts || []).filter(function(host) {
		return (host.online !== true);
	}).length;

	nodes.push(E('div', { 'class': 'right' }, [
		E('button', {
			'class': 'btn cbi-button-remove',
			'disabled': (suspendedCount > 0) ? null : '',
			'click': ui.createHandlerFn(view, 'handleRemoveAll', suspendedCount)
		}, _('Remove all suspended (%d)').format(suspendedCount))
		]));

	/* cbi_update_table() wires the sort into this <table> (luci-base's
	 * L.ui.Table): the header row gets the click handler, rows are
	 * re-rendered and re-sorted from our data array on every poll tick
	 * without touching the DOM outside the <table>. The Actions column
	 * gets cbi-section-actions so the official machinery leaves it
	 * unsorted, exactly like the firewall's rules table. */
	var table = E('table', { 'class': 'table', 'id': 'ip4pt-hosts' }, [
		E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Name')),
			E('th', { 'class': 'th' }, _('IP Address')),
			E('th', { 'class': 'th' }, _('MAC Address')),
			E('th', { 'class': 'th' }, _('Silent For')),
			E('th', { 'class': 'th' }, _('Status')),
			E('th', { 'class': 'th' }, _('Suspends In')),
			E('th', { 'class': 'th' }, _('Removed In')),
			E('th', { 'class': 'th cbi-section-actions' }, _('Actions'))
		])
	]);

	cbi_update_table(table, toRows(view, data),
		E('em', _('No hosts handled yet -- waiting for ARP traffic on the mirror port.')));

	nodes.push(table);

	return nodes;
}

function parseStatus(res) {
	if (!res || !res.stdout)
		throw new Error(_('Unable to read the ip4pt status. Is the ip4pt package installed?'));

	try {
		return JSON.parse(res.stdout);
	}
	catch (e) {
		throw new Error(_('The ip4pt status output could not be parsed.'));
	}
}

return view.extend({
	load: function() {
		var self = this;

		poll.add(function() {
			return L.resolveDefault(fs.exec(HELPER), null)
				.then(function(res) {
					dom.content(self.container, renderBody(self, parseStatus(res)));
				})
				.catch(function() {});
		}, POLL_INTERVAL);

		return L.resolveDefault(fs.exec(HELPER), null).then(parseStatus);
	},

	render: function(data) {
		this.container = E('div', {}, renderBody(this, data));
		return this.container;
	},

	/* Deprovision one binding via the ACL'd ip4pt-remove helper: the same
	 * deprovision_host the GC's STALE_SECS tier runs (state file + nft map
	 * element + ebtables rule). The host is re-learned automatically from
	 * its next ARP, so this is safe-by-design; still confirm first. */
	handleRemoveConfirm: function(ip, mac, ev) {
		var self = this;

		return fs.exec(REMOVER, [ ip ])
			.then(function() {
				return L.resolveDefault(fs.exec(HELPER), null).then(function(res) {
					dom.content(self.container, renderBody(self, parseStatus(res)));
				});
			})
			.catch(function(e) {
				ui.addNotification(null, E('p', {},
					_('Failed to remove the binding for %s: %s').format(ip, e.message || e)));
			})
			.finally(L.hideModal);
	},

	handleRemove: function(ip, mac, ev) {
		L.showModal(_('Remove binding'), [
			E('p', {}, _('Do you really want to remove the binding for %s (%s)? It is re-learned automatically from the host\'s next ARP.').format('<strong>%s</strong>'.format(ip), mac)),
			E('div', { 'class': 'right' }, [
				E('div', { 'class': 'btn', 'click': L.hideModal }, _('Cancel')),
				' ',
				E('div', { 'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(this, 'handleRemoveConfirm', ip, mac) },
					_('Remove binding'))
			])
		]);
	},

	/* The Remove-all-suspended counterpart: same helper, bulk mode. The
	 * helper re-checks rule presence per host at run time, so a host
	 * that just came back (rule re-asserted by discovery) is never
	 * caught by the sweep even if the page data was a poll behind. */
	handleRemoveAll: function(count, ev) {
		L.showModal(_('Remove suspended bindings'), [
			E('p', {}, _('Do you really want to remove all %d suspended bindings? Each is re-learned automatically from its host\'s next ARP.').format(count)),
			E('div', { 'class': 'right' }, [
				E('div', { 'class': 'btn', 'click': L.hideModal }, _('Cancel')),
				' ',
				E('div', { 'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(this, 'handleRemoveAllConfirm') },
					_('Remove bindings'))
			])
		]);
	},

	handleRemoveAllConfirm: function(ev) {
		var self = this;

		return fs.exec(REMOVER, [ '--suspended' ])
			.then(function(res) {
				var m = ((res && res.stdout) || '').match(/removed (\d+)/);

				if (m)
					ui.addNotification(null, E('p', {},
						_('Removed %d suspended binding(s).').format(+m[1])), 'info');

				return L.resolveDefault(fs.exec(HELPER), null).then(function(res2) {
					dom.content(self.container, renderBody(self, parseStatus(res2)));
				});
			})
			.catch(function(e) {
				ui.addNotification(null, E('p', {},
					_('Failed to remove the suspended bindings: %s').format(e.message || e)));
			})
			.finally(L.hideModal);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});