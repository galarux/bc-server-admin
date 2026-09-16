/* BC Server Admin - web UI. Vanilla JS, no dependencies, no inline code (strict CSP). */
(function () {
  'use strict';

  const I18N = window.BCSA_I18N;
  const REPO_URL = 'https://github.com/galarux/bc-server-admin';
  const COMPANY = {
    name: 'Galarux',
    url: 'https://galarux.com',
    email: 'info@galarux.com',
    productUrl: 'https://galarux.com/productos/galaruxgantt/'
  };
  const EVENT_LEVELS = { errors: 2, warnings: 3, all: 5 };
  const SESSION_COLUMNS = [
    ['SessionID', 'colSessionId'],
    ['UserID', 'colUser'],
    ['ClientType', 'colClientType'],
    ['ClientComputerName', 'colComputer'],
    ['LoginDatetime', 'colLogin'],
    ['TenantId', 'colTenant'],
    ['DatabaseName', 'colDatabase']
  ];

  const state = {
    token: null,
    lang: 'en',
    info: null,
    meta: null,
    categories: [],
    instances: [],
    instanceFilter: '',
    selected: null,
    view: 'instance',
    tab: 'overview',
    offline: false,
    fatal: false,
    restartHint: {},
    config: null,
    configFor: null,
    configError: null,
    edits: new Map(),
    cfg: { q: '', cat: 'all', onlyChanged: false, showSecrets: false },
    applyToMemory: false,
    exportSecrets: false,
    sessions: { data: null, error: null, q: '' },
    tenants: { data: null, error: null },
    events: { data: null, error: null, source: 'Admin', level: 'all', max: 100, open: new Set() },
    backups: { data: null, error: null },
    compare: { a: null, b: null, onlyDiff: true, q: '', showSecrets: false, data: null, error: null },
    pollTimer: null
  };

  /* ------------------------------------------------------------------ helpers */

  const $ = (selector, root) => (root || document).querySelector(selector);

  function t(key, params) {
    const dict = I18N[state.lang] || I18N.en;
    let text = dict[key];
    if (text === undefined) text = I18N.en[key];
    if (text === undefined) return key;
    if (params) text = text.replace(/\{(\w+)\}/g, (m, p) => (params[p] !== undefined && params[p] !== null ? params[p] : m));
    return text;
  }

  function tOr(key, fallback) {
    const text = t(key);
    return text === key ? fallback : text;
  }

  function h(tag, props) {
    const el = document.createElement(tag);
    if (props) {
      for (const key of Object.keys(props)) {
        const value = props[key];
        if (value === null || value === undefined || value === false) continue;
        if (key === 'class') el.className = value;
        else if (key === 'text') el.textContent = value;
        else if (key === 'dataset') Object.assign(el.dataset, value);
        else if (key.startsWith('on') && typeof value === 'function') el.addEventListener(key.slice(2), value);
        else if (key === 'value') el.value = value;
        else if (key === 'checked' || key === 'disabled' || key === 'selected' || key === 'open') el[key] = true;
        else el.setAttribute(key, value === true ? '' : value);
      }
    }
    for (let i = 2; i < arguments.length; i++) appendChild(el, arguments[i]);
    return el;
  }

  function appendChild(el, child) {
    if (child === null || child === undefined || child === false) return;
    if (Array.isArray(child)) { child.forEach((c) => appendChild(el, c)); return; }
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }

  function store(kind, key, value) {
    try { window[kind].setItem('bcsa.' + key, value); } catch (e) { /* storage unavailable */ }
  }

  function load(kind, key) {
    try { return window[kind].getItem('bcsa.' + key); } catch (e) { return null; }
  }

  const isTrue = (v) => String(v).toLowerCase() === 'true';
  const isBool = (v) => /^(true|false)$/i.test(String(v));
  const enc = encodeURIComponent;

  function fmtDate(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    if (isNaN(d)) return String(iso);
    return d.toLocaleString(state.lang === 'es' ? 'es-ES' : 'en-GB', { dateStyle: 'short', timeStyle: 'medium' });
  }

  function fmtSize(bytes) {
    if (bytes < 1024) return bytes + ' B';
    return (bytes / 1024).toFixed(1) + ' KB';
  }

  function current() {
    return state.instances.find((i) => i.name === state.selected) || null;
  }

  function stateClass(instance) {
    if (instance.pendingAction) return 'pending';
    if (instance.state === 'Running') return 'running';
    if (instance.state === 'Stopped') return 'stopped';
    return 'pending';
  }

  function stateLabel(instance) {
    if (instance.pendingAction === 'restart') return t('stateRestarting');
    return tOr('state' + instance.state, instance.state);
  }

  function isPending(instance) {
    return !!instance.pendingAction || (instance.state !== 'Running' && instance.state !== 'Stopped');
  }

  /* ------------------------------------------------------------------ API */

  class ApiError extends Error {
    constructor(message, code, status) {
      super(message);
      this.code = code;
      this.status = status;
    }
  }

  async function api(path, options) {
    options = options || {};
    const init = { method: options.method || 'GET', headers: { 'X-BCSA-Token': state.token || '' }, cache: 'no-store' };
    if (options.body !== undefined) {
      init.headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(options.body);
    }
    let response;
    try {
      response = await fetch('/api' + path, init);
    } catch (e) {
      setOffline(true);
      throw new ApiError(t('errOffline'), 'offline', 0);
    }
    setOffline(false);
    if (options.raw && response.ok) return response;
    const text = await response.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch (e) { data = { error: text }; }
    if (!response.ok) {
      if (response.status === 401) showFatal(t('tokenInvalid'));
      throw new ApiError((data && data.error) || response.statusText, data && data.code, response.status);
    }
    return data;
  }

  const instancePath = (name, sub) => '/instances/' + enc(name) + (sub || '');

  /* ------------------------------------------------------------------ UI primitives */

  function toast(message, kind) {
    const el = h('div', { class: 'toast ' + (kind || ''), role: 'status' }, message);
    $('#toasts').append(el);
    setTimeout(() => el.remove(), kind === 'error' ? 9000 : 5000);
    return el;
  }

  function spinner(text) {
    return h('div', { class: 'loading' }, h('span', { class: 'spinner' }), text || t('loading'));
  }

  function errorBox(message) {
    return h('div', { class: 'banner danger' }, message);
  }

  let dialogResolve = null;

  function openDialog(opts) {
    const dialog = $('#dialog');
    if (dialogResolve) { const previous = dialogResolve; dialogResolve = null; previous(null); }
    if (dialog.open) dialog.close();
    const buttons = (opts.actions || [{ label: t('close'), value: 'close', kind: 'btn-primary' }]).map((a) =>
      h('button', {
        type: 'button',
        class: 'btn ' + (a.kind || ''),
        onclick: () => {
          if (a.validate && !a.validate()) return;
          const result = a.collect ? a.collect() : a.value;
          dialog.close();
          finish(result);
        }
      }, a.label)
    );
    dialog.replaceChildren(
      h('div', { class: 'dialog-head' }, h('h2', { text: opts.title })),
      h('div', { class: 'dialog-body' }, opts.body),
      h('div', { class: 'dialog-foot' }, buttons)
    );
    function finish(value) {
      const resolve = dialogResolve;
      dialogResolve = null;
      if (resolve) resolve(value);
    }
    return new Promise((resolve) => {
      dialogResolve = resolve;
      // ESC fires 'cancel' synchronously; 'close' is async and could resolve the next dialog.
      dialog.oncancel = () => finish(null);
      dialog.showModal();
      const focusTarget = dialog.querySelector('input, select') || dialog.querySelector('.dialog-foot .btn-primary, .dialog-foot .btn-danger-solid');
      if (focusTarget) focusTarget.focus();
    });
  }

  function confirmDialog(title, message, confirmLabel, danger) {
    return openDialog({
      title,
      body: h('p', null, message),
      actions: [
        { label: t('cancel'), value: false },
        { label: confirmLabel, value: true, kind: danger ? 'btn-danger-solid' : 'btn-primary' }
      ]
    }).then((v) => v === true);
  }

  function setOffline(offline) {
    if (state.offline === offline) return;
    state.offline = offline;
    const existing = $('#offline');
    if (existing) existing.remove();
    if (offline && !state.fatal) {
      document.body.append(h('div', { class: 'offline', id: 'offline' },
        h('div', { class: 'card' }, h('h3', { text: t('offlineTitle') }), h('p', { class: 'muted', text: t('offlineText') }))));
    }
  }

  function showFatal(message) {
    state.fatal = true;
    clearTimeout(state.pollTimer);
    $('#main').replaceChildren(h('div', { class: 'empty' }, h('h2', { text: t('fatalTitle') }), h('p', null, message)));
    $('#instanceList').replaceChildren();
  }

  /* ------------------------------------------------------------------ settings metadata */

  function compileMeta(meta) {
    state.meta = meta;
    state.categories = meta.categories.map((c) => ({
      id: c.id,
      order: c.order,
      label: c.label,
      regex: c.patterns.map((p) => new RegExp(p, 'i'))
    }));
  }

  const categoryCache = new Map();
  function categoryOf(key) {
    if (categoryCache.has(key)) return categoryCache.get(key);
    let found = state.categories.find((c) => c.regex.some((r) => r.test(key)));
    if (!found) found = state.categories.find((c) => c.id === 'other');
    categoryCache.set(key, found);
    return found;
  }

  const categoryLabel = (category) => category.label[state.lang] || category.label.en;

  /* ------------------------------------------------------------------ static text */

  function applyStaticText() {
    document.documentElement.lang = state.lang;
    document.querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = t(el.dataset.i18n); });
    document.querySelectorAll('[data-i18n-title]').forEach((el) => { el.title = t(el.dataset.i18nTitle); el.setAttribute('aria-label', el.title); });
    document.querySelectorAll('[data-i18n-placeholder]').forEach((el) => { el.placeholder = t(el.dataset.i18nPlaceholder); });
    $('#langSelect').value = state.lang;
    $('#btnInstances').classList.toggle('active', state.view === 'instance');
    $('#btnCompare').classList.toggle('active', state.view === 'compare');
  }

  function renderHostInfo() {
    const info = state.info;
    if (!info) return;
    $('#hostInfo').textContent = info.fqdn + ' · ' + info.user;
    $('#sidebarFoot').replaceChildren(h('div', { class: 'company' },
      h('div', null, 'BC Server Admin ' + info.version),
      h('a', { class: 'company-logo', href: COMPANY.url, target: '_blank', rel: 'noopener noreferrer', title: t('madeBy') + ' ' + COMPANY.name },
        companyLogo()),
      h('div', { class: 'company-links' },
        extLink(COMPANY.url, 'galarux.com'),
        extLink(REPO_URL, 'GitHub'),
        h('button', { type: 'button', class: 'link-button', onclick: showAbout }, t('about'))),
      h('div', null, 'PowerShell ' + info.psVersion + (info.pwshAvailable ? ' \u00b7 pwsh \u2713' : ''))));
    const banners = [];
    if (info.demo) banners.push(h('div', { class: 'banner info' }, t('demoBanner')));
    if (!info.isAdmin && !info.demo) banners.push(h('div', { class: 'banner warn' }, t('notAdminBanner')));
    $('#banners').replaceChildren(...banners);
  }

  function extLink(href, text) {
    const external = /^https?:/.test(href);
    return h('a', { href, target: external ? '_blank' : null, rel: external ? 'noopener noreferrer' : null }, text);
  }

  function companyLogo() {
    return [
      h('img', { class: 'logo-on-light', src: 'img/galarux-logo.png', alt: COMPANY.name }),
      h('img', { class: 'logo-on-dark', src: 'img/galarux-logo-white.png', alt: COMPANY.name })
    ];
  }

  function showAbout() {
    const info = state.info || {};
    openDialog({
      title: t('aboutTitle'),
      body: h('div', { class: 'about' },
        h('a', { class: 'about-logo', href: COMPANY.url, target: '_blank', rel: 'noopener noreferrer' }, companyLogo()),
        h('p', null, h('strong', { text: 'BC Server Admin ' + (info.version || '') })),
        h('p', null, t('aboutText')),
        h('p', { class: 'muted' }, t('aboutHelp')),
        h('dl', { class: 'about-links' },
          h('dt', { text: t('aboutWeb') }), h('dd', null, extLink(COMPANY.url, 'galarux.com')),
          h('dt', { text: t('aboutContact') }), h('dd', null, extLink('mailto:' + COMPANY.email, COMPANY.email)),
          h('dt', { text: t('aboutProducts') }), h('dd', null, extLink(COMPANY.productUrl, 'Galarux Gantt')),
          h('dt', { text: t('aboutSource') }), h('dd', null, extLink(REPO_URL, 'github.com/galarux/bc-server-admin')),
          h('dt', { text: t('aboutLicense') }), h('dd', null, extLink(REPO_URL + '/blob/main/LICENSE', 'MIT'))))
    });
  }

  function applyTheme(theme) {
    if (theme === 'light' || theme === 'dark') document.documentElement.dataset.theme = theme;
    else delete document.documentElement.dataset.theme;
  }

  function toggleTheme() {
    const dark = document.documentElement.dataset.theme
      ? document.documentElement.dataset.theme === 'dark'
      : window.matchMedia('(prefers-color-scheme: dark)').matches;
    const next = dark ? 'light' : 'dark';
    applyTheme(next);
    store('localStorage', 'theme', next);
  }

  /* ------------------------------------------------------------------ instances & polling */

  async function refreshInstances() {
    const data = await api('/instances');
    state.instances = data.items || [];
    if (state.selected && !current()) state.selected = null;
    if (!state.selected && state.instances.length) {
      const saved = load('localStorage', 'instance');
      state.selected = state.instances.some((i) => i.name === saved) ? saved : state.instances[0].name;
    }
    for (const instance of state.instances) {
      if (instance.state === 'Stopped' && !instance.pendingAction) delete state.restartHint[instance.name];
    }
    renderInstanceList();
  }

  function schedulePoll() {
    clearTimeout(state.pollTimer);
    if (state.fatal) return;
    const fast = state.instances.some(isPending) || state.instances.some((i) => i.worker && i.worker.state === 'loading');
    state.pollTimer = setTimeout(poll, fast ? 1500 : 10000);
  }

  async function poll() {
    try {
      const before = JSON.stringify(state.instances.map((i) => [i.name, i.state, i.pendingAction, i.processId, i.worker && i.worker.state]));
      await refreshInstances();
      const after = JSON.stringify(state.instances.map((i) => [i.name, i.state, i.pendingAction, i.processId, i.worker && i.worker.state]));
      if (before !== after && state.view === 'instance') {
        updateInstanceHeader();
        if (state.tab === 'overview') renderTab();
      }
    } catch (e) { /* offline overlay handles it */ }
    schedulePoll();
  }

  function renderInstanceList() {
    const filter = state.instanceFilter.toLowerCase();
    const items = state.instances.filter((i) => !filter || i.name.toLowerCase().includes(filter) || String(i.version).includes(filter));
    const list = $('#instanceList');
    if (!state.instances.length) {
      list.replaceChildren(h('li', { class: 'muted small' }, t('noInstancesShort')));
      return;
    }
    list.replaceChildren(...items.map((instance) => h('li', null,
      h('button', {
        type: 'button',
        class: 'inst' + (state.view === 'instance' && instance.name === state.selected ? ' active' : ''),
        title: instance.displayName + ' — ' + stateLabel(instance),
        onclick: () => selectInstance(instance.name)
      },
      h('span', { class: 'dot ' + stateClass(instance) }),
      h('span', { class: 'inst-name', text: instance.name }),
      h('span', { class: 'inst-ver', text: instance.version ? instance.version.split('.').slice(0, 2).join('.') : '?' }))
    )));
  }

  async function selectInstance(name) {
    if (state.view === 'instance' && name === state.selected) return;
    if (!(await confirmDiscardEdits())) return;
    state.view = 'instance';
    state.selected = name;
    store('localStorage', 'instance', name);
    resetInstanceData();
    applyStaticText();
    renderInstanceList();
    renderMain();
  }

  function resetInstanceData() {
    state.config = null;
    state.configFor = null;
    state.configError = null;
    state.edits.clear();
    state.sessions.data = null; state.sessions.error = null;
    state.tenants.data = null; state.tenants.error = null;
    state.events.data = null; state.events.error = null; state.events.open.clear();
    state.backups.data = null; state.backups.error = null;
    const instance = current();
    if (state.tab === 'tenants' && instance && !isTrue(instance.summary.multitenant)) state.tab = 'overview';
  }

  async function confirmDiscardEdits() {
    if (!state.edits.size) return true;
    const ok = await confirmDialog(t('discardTitle'), t('discardText', { n: state.edits.size }), t('discard'), true);
    if (ok) state.edits.clear();
    return ok;
  }

  /* ------------------------------------------------------------------ main view */

  function renderMain() {
    const main = $('#main');
    if (state.fatal) return;
    if (state.view === 'compare') { renderCompare(main); return; }
    const instance = current();
    if (!instance) {
      main.replaceChildren(h('div', { class: 'empty' },
        h('h2', { text: t('noInstancesTitle') }),
        h('p', null, t('noInstancesText'))));
      return;
    }
    main.replaceChildren(renderInstanceHeader(instance), renderTabs(instance), h('div', { id: 'tabBody' }));
    renderTab();
  }

  function updateInstanceHeader() {
    const instance = current();
    const old = $('#instHeader');
    if (!instance || !old) { renderMain(); return; }
    old.replaceWith(renderInstanceHeader(instance));
  }

  function renderInstanceHeader(instance) {
    const running = instance.state === 'Running';
    const stopped = instance.state === 'Stopped';
    const busy = isPending(instance);
    const url = instance.summary && instance.summary.publicWebBaseUrl;
    const head = h('div', { id: 'instHeader' },
      h('div', { class: 'page-head' },
        h('div', null,
          h('div', { class: 'page-title' },
            h('h1', { text: instance.name }),
            h('span', { class: 'badge ' + stateClass(instance) }, h('span', { class: 'dot ' + stateClass(instance) }), stateLabel(instance))),
          h('div', { class: 'page-sub' }, 'Business Central ' + (instance.version || '?') + ' · ' + instance.serviceName)),
        h('div', { class: 'page-actions' },
          url ? h('a', { class: 'btn', href: url, target: '_blank', rel: 'noopener noreferrer' }, t('openWebClient')) : null,
          h('button', { type: 'button', class: 'btn btn-ok', disabled: !stopped || busy, onclick: () => serviceAction(instance, 'start') }, t('start')),
          h('button', { type: 'button', class: 'btn btn-danger', disabled: stopped || busy, onclick: () => serviceAction(instance, 'stop') }, t('stop')),
          h('button', { type: 'button', class: 'btn btn-primary', disabled: busy, onclick: () => serviceAction(instance, 'restart') }, t('restart'))))
    );
    if (state.restartHint[instance.name] && running && !busy) {
      head.append(h('div', { class: 'banner warn' },
        h('span', { class: 'grow' }, t('restartHint')),
        h('button', { type: 'button', class: 'btn btn-sm btn-primary', onclick: () => serviceAction(instance, 'restart', true) }, t('restartNow'))));
    }
    return head;
  }

  async function serviceAction(instance, action, skipConfirm) {
    if (action !== 'start' && !skipConfirm) {
      const ok = await confirmDialog(t(action + 'Title', { name: instance.name }), t(action + 'Text', { name: instance.name }), t(action), action === 'stop');
      if (!ok) return;
    }
    try {
      await api(instancePath(instance.name, '/service'), { method: 'POST', body: { action } });
      if (action !== 'stop') delete state.restartHint[instance.name];
      toast(t(action + 'Requested', { name: instance.name }), 'ok');
      await refreshInstances();
      updateInstanceHeader();
      if (state.tab === 'overview') renderTab();
      schedulePoll();
    } catch (e) {
      toast(e.message, 'error');
    }
  }

  function renderTabs(instance) {
    const tabs = [
      ['overview', t('tabOverview')],
      ['config', t('tabConfig')],
      ['sessions', t('tabSessions')],
      isTrue(instance.summary.multitenant) ? ['tenants', t('tabTenants')] : null,
      ['events', t('tabEvents')],
      ['backups', t('tabBackups')]
    ].filter(Boolean);
    return h('div', { class: 'tabs', role: 'tablist' }, tabs.map(([id, label]) =>
      h('button', {
        type: 'button',
        role: 'tab',
        class: 'tab' + (state.tab === id ? ' active' : ''),
        'aria-selected': state.tab === id ? 'true' : 'false',
        onclick: () => switchTab(id)
      }, label, id === 'config' && state.edits.size ? h('span', { class: 'count', text: '(' + state.edits.size + ')' }) : null)
    ));
  }

  function refreshTabs() {
    const tabs = $('.tabs');
    const instance = current();
    if (tabs && instance) tabs.replaceWith(renderTabs(instance));
  }

  function switchTab(id) {
    state.tab = id;
    refreshTabs();
    renderTab();
  }

  function renderTab() {
    const body = $('#tabBody');
    const instance = current();
    if (!body || !instance) return;
    switch (state.tab) {
      case 'config': renderConfigTab(body, instance); break;
      case 'sessions': renderSessionsTab(body, instance); break;
      case 'tenants': renderTenantsTab(body, instance); break;
      case 'events': renderEventsTab(body, instance); break;
      case 'backups': renderBackupsTab(body, instance); break;
      default: renderOverview(body, instance);
    }
  }

  /* ------------------------------------------------------------------ overview */

  function kv(rows) {
    return h('dl', { class: 'kv' }, rows.filter(Boolean).map(([label, value]) => [
      h('dt', { text: label }),
      h('dd', null, value === null || value === undefined || value === '' ? h('span', { class: 'muted', text: '—' }) : value)
    ]));
  }

  function mono(text) {
    return h('span', { class: 'mono', text: text });
  }

  function renderOverview(body, instance) {
    const s = instance.summary || {};
    const host = state.info.fqdn;
    const endpoint = (enabled, port, ssl, path) => {
      if (!port || port === '0') return null;
      const base = (isTrue(ssl) ? 'https' : 'http') + '://' + host + ':' + port + '/' + instance.name + path;
      return isTrue(enabled) ? base : null;
    };
    const endpoints = [
      [t('epClient'), s.clientServicesPort, s.clientServicesEnabled, null],
      [t('epSoap'), s.soapPort, s.soapEnabled, s.publicSoapBaseUrl || endpoint(s.soapEnabled, s.soapPort, s.soapSsl, '/WS/Services')],
      [t('epOData'), s.odataPort, s.odataEnabled, s.publicODataBaseUrl || endpoint(s.odataEnabled, s.odataPort, s.odataSsl, '/ODataV4/')],
      [t('epApi'), s.odataPort, s.apiEnabled, endpoint(s.apiEnabled, s.odataPort, s.odataSsl, '/api/v2.0/')],
      [t('epDev'), s.developerPort, s.developerEnabled, endpoint(s.developerEnabled, s.developerPort, s.developerSsl, '/dev/')],
      [t('epManagement'), s.managementPort, s.managementEnabled, null],
      [t('epManagementApi'), s.managementApiPort, s.managementApiEnabled, null],
      [t('epSnapshot'), s.snapshotDebuggerPort, s.snapshotDebuggerEnabled, null]
    ].filter((e) => e[1] !== null && e[1] !== undefined);

    const db = (s.databaseServer || '') + (s.databaseInstance ? '\\' + s.databaseInstance : '');
    const worker = instance.worker || {};
    const workerBadge = {
      ready: ['ok', t('workerReady')],
      loading: ['pending', t('workerLoading')],
      failed: ['error', t('workerFailed')],
      stopped: ['error', t('workerStopped')],
      notStarted: ['', t('workerNotStarted')]
    }[worker.state] || ['', worker.state || '—'];

    body.replaceChildren(h('div', { class: 'cards' },
      h('section', { class: 'card' },
        h('h3', { text: t('cardService') }),
        kv([
          [t('status'), h('span', { class: 'badge ' + stateClass(instance) }, stateLabel(instance))],
          [t('startMode'), tOr('startMode' + instance.startMode, instance.startMode)],
          [t('account'), instance.account],
          [t('processId'), instance.processId ? String(instance.processId) : null],
          [t('serviceName'), mono(instance.serviceName)]
        ])),
      h('section', { class: 'card' },
        h('h3', null, t('cardDatabase'),
          h('button', { type: 'button', class: 'btn btn-sm', onclick: () => credentialsDialog(instance) }, t('changeCredentials'))),
        kv([
          [t('dbServer'), db ? mono(db) : null],
          [t('dbName'), s.databaseName ? mono(s.databaseName) : null],
          [t('credentialType'), s.credentialType],
          [t('multitenant'), isTrue(s.multitenant) ? t('yes') : t('no')],
          [t('webClient'), s.publicWebBaseUrl ? h('a', { href: s.publicWebBaseUrl, target: '_blank', rel: 'noopener noreferrer' }, s.publicWebBaseUrl) : null]
        ])),
      h('section', { class: 'card' },
        h('h3', { text: t('cardInstallation') }),
        kv([
          [t('version'), instance.version ? mono(instance.version) : null],
          [t('serviceDir'), instance.serviceDir ? mono(instance.serviceDir) : null],
          [t('configFile'), instance.configPath ? mono(instance.configPath) : h('span', { class: 'badge error', text: t('configMissing') })],
          [t('backupDir'), mono(state.info.backupRoot)]
        ])),
      h('section', { class: 'card' },
        h('h3', { text: t('cardModule') }),
        kv([
          [t('status'), h('span', { class: 'badge ' + workerBadge[0] }, worker.state === 'loading' ? h('span', { class: 'spinner' }) : null, workerBadge[1])],
          [t('psHost'), worker.host ? worker.host + (worker.psVersion ? ' ' + worker.psVersion : '') : null],
          [t('module'), worker.module ? mono(worker.module) : null],
          worker.error ? [t('error'), h('span', { class: 'muted', text: worker.error })] : null
        ])),
      h('section', { class: 'card wide' },
        h('h3', { text: t('cardEndpoints') }),
        h('div', { class: 'table-wrap' },
          h('table', { class: 'grid' },
            h('thead', null, h('tr', null, h('th', { text: t('colService') }), h('th', { class: 'num', text: t('colPort') }), h('th', { text: t('colEnabled') }), h('th', { text: t('colUrl') }))),
            h('tbody', null, endpoints.map(([label, port, enabled, url]) => h('tr', null,
              h('td', { text: label }),
              h('td', { class: 'num mono', text: port }),
              h('td', null, h('span', { class: 'badge ' + (isTrue(enabled) ? 'ok' : ''), text: isTrue(enabled) ? t('yes') : t('no') })),
              h('td', null, url ? mono(url) : h('span', { class: 'muted', text: '—' }))
            ))))))
    ));
  }

  /* ------------------------------------------------------------------ configuration */

  async function loadConfig(instance, force) {
    if (!force && state.configFor === instance.name && state.config) return;
    state.configError = null;
    try {
      state.config = await api(instancePath(instance.name, '/config'));
      state.configFor = instance.name;
    } catch (e) {
      state.config = null;
      state.configError = e.message;
    }
  }

  function originalValue(key) {
    const setting = state.config && state.config.settings.find((s) => s.key === key);
    return setting ? setting.value : '';
  }

  function sameValue(original, value) {
    if (isBool(original) && isBool(value)) return original.toLowerCase() === value.toLowerCase();
    return original === value;
  }

  function setEdit(key, value, row) {
    if (sameValue(originalValue(key), value)) state.edits.delete(key);
    else state.edits.set(key, value);
    if (row) row.classList.toggle('dirty', state.edits.has(key));
    renderSaveBar();
    refreshTabs();
  }

  function revertButton(setting) {
    return h('button', {
      type: 'button', class: 'btn btn-ghost btn-icon', title: t('revert'), 'aria-label': t('revert'),
      onclick: () => {
        state.edits.delete(setting.key);
        renderConfigRows();
        renderSaveBar();
        refreshTabs();
      }
    }, '↺');
  }

  async function renderConfigTab(body, instance) {
    if (!instance.configPath) { body.replaceChildren(errorBox(t('configMissingText'))); return; }
    if (state.configFor !== instance.name || !state.config) {
      body.replaceChildren(spinner());
      await loadConfig(instance);
      if (state.tab !== 'config' || state.selected !== instance.name) return;
    }
    if (state.configError) { body.replaceChildren(errorBox(state.configError)); return; }

    const search = h('input', {
      type: 'search', class: 'input search', placeholder: t('searchSettings'), value: state.cfg.q,
      oninput: (e) => { state.cfg.q = e.target.value; renderConfigRows(); }
    });
    const exportMenu = h('details', { class: 'menu' },
      h('summary', { class: 'btn' }, t('export')),
      h('div', { class: 'menu-pop' },
        h('button', { type: 'button', class: 'btn btn-ghost', onclick: (e) => downloadExport(instance, 'html', e) }, t('exportHtml')),
        h('button', { type: 'button', class: 'btn btn-ghost', onclick: (e) => downloadExport(instance, 'csv', e) }, t('exportCsv')),
        h('button', { type: 'button', class: 'btn btn-ghost', onclick: (e) => downloadExport(instance, 'json', e) }, t('exportJson')),
        h('hr'),
        h('label', { class: 'check small' },
          h('input', { type: 'checkbox', checked: state.exportSecrets, onchange: (e) => { state.exportSecrets = e.target.checked; } }),
          t('exportSecrets'))));

    body.replaceChildren(
      h('div', { class: 'toolbar' },
        search,
        h('label', { class: 'check' },
          h('input', { type: 'checkbox', checked: state.cfg.onlyChanged, onchange: (e) => { state.cfg.onlyChanged = e.target.checked; renderConfigRows(); } }),
          t('onlyChanged')),
        h('label', { class: 'check' },
          h('input', { type: 'checkbox', checked: state.cfg.showSecrets, onchange: (e) => { state.cfg.showSecrets = e.target.checked; renderConfigRows(); } }),
          t('showSecrets')),
        h('span', { class: 'grow' }),
        h('span', { class: 'muted small', id: 'cfgCount' }),
        h('button', { type: 'button', class: 'btn', onclick: () => reloadConfig(instance) }, t('reload')),
        exportMenu),
      h('div', { class: 'chips', id: 'cfgChips' }),
      h('div', { class: 'table-wrap' },
        h('table', { class: 'grid config-table' },
          h('colgroup', null, h('col', { class: 'c-key' }), h('col'), h('col', { class: 'c-act' })),
          h('thead', null, h('tr', null, h('th', { text: t('colSetting') }), h('th', { text: t('colValue') }), h('th'))),
          h('tbody', { id: 'cfgRows' }))),
      h('div', { id: 'saveBarHost' }),
      h('div', { class: 'small muted', text: state.config.path })
    );
    renderDatalists();
    renderConfigRows();
    renderSaveBar();
  }

  function renderDatalists() {
    let host = $('#datalists');
    if (!host) { host = h('div', { id: 'datalists', hidden: true }); document.body.append(host); }
    const suggestions = state.meta.suggestions || {};
    host.replaceChildren(...Object.keys(suggestions).map((key) =>
      h('datalist', { id: 'dl-' + key }, suggestions[key].map((v) => h('option', { value: v })))));
  }

  function renderChips(counts, total) {
    const chips = [['all', t('allCategories'), total]].concat(
      state.categories.slice().sort((a, b) => a.order - b.order)
        .filter((c) => counts[c.id])
        .map((c) => [c.id, categoryLabel(c), counts[c.id]]));
    $('#cfgChips').replaceChildren(...chips.map(([id, label, n]) => h('button', {
      type: 'button',
      class: 'chip' + (state.cfg.cat === id ? ' active' : ''),
      onclick: () => { state.cfg.cat = id; renderConfigRows(); }
    }, label, h('span', { class: 'n', text: n }))));
  }

  function renderConfigRows() {
    const tbody = $('#cfgRows');
    if (!tbody || !state.config) return;
    const q = state.cfg.q.trim().toLowerCase();
    const counts = {};
    const rows = [];
    let total = 0;
    for (const setting of state.config.settings) {
      const value = state.edits.has(setting.key) ? state.edits.get(setting.key) : setting.value;
      const matchesText = !q || setting.key.toLowerCase().includes(q) || String(value).toLowerCase().includes(q) || (setting.description || '').toLowerCase().includes(q);
      if (!matchesText) continue;
      if (state.cfg.onlyChanged && !state.edits.has(setting.key)) continue;
      const category = categoryOf(setting.key);
      counts[category.id] = (counts[category.id] || 0) + 1;
      total++;
      if (state.cfg.cat !== 'all' && category.id !== state.cfg.cat) continue;
      rows.push(renderConfigRow(setting, value, category));
    }
    renderChips(counts, total);
    if (!rows.length) rows.push(h('tr', { class: 'empty-row' }, h('td', { colspan: '3', text: t('noResults') })));
    tbody.replaceChildren(...rows);
    $('#cfgCount').textContent = t('settingsCount', { n: rows.length === 1 && rows[0].classList.contains('empty-row') ? 0 : rows.length });
  }

  function renderConfigRow(setting, value, category) {
    const row = h('tr', { class: state.edits.has(setting.key) ? 'dirty' : '', dataset: { key: setting.key } });
    const readOnly = state.meta.readOnly && state.meta.readOnly[setting.key];
    let editor;
    if (readOnly === 'useCredentials') {
      editor = h('div', { class: 'value-row' },
        h('input', { class: 'input', type: 'password', value: setting.value ? '********' : '', disabled: true, 'aria-label': setting.key }),
        h('button', { type: 'button', class: 'btn btn-sm', onclick: () => credentialsDialog(current()) }, t('changeCredentials')));
    } else if (readOnly) {
      editor = h('input', { class: 'input', type: 'text', value: value, disabled: true, title: t('readOnlyInstanceName'), 'aria-label': setting.key });
    } else if (isBool(setting.value)) {
      const normalized = String(value).toLowerCase();
      editor = h('select', {
        class: 'input', 'aria-label': setting.key,
        onchange: (e) => setEdit(setting.key, e.target.value, row)
      }, ['true', 'false'].map((v) => h('option', { value: v, selected: normalized === v }, v)));
    } else {
      const suggestions = state.meta.suggestions && state.meta.suggestions[setting.key];
      editor = h('input', {
        class: 'input',
        type: setting.secret && !state.cfg.showSecrets ? 'password' : 'text',
        value: value,
        spellcheck: 'false',
        autocomplete: 'off',
        list: suggestions ? 'dl-' + setting.key : null,
        'aria-label': setting.key,
        oninput: (e) => setEdit(setting.key, e.target.value, row)
      });
    }
    row.append(
      h('td', { class: 'k' },
        h('div', { class: 'key', text: setting.key }),
        state.cfg.cat === 'all' ? h('div', { class: 'cat-label', text: categoryLabel(category) }) : null,
        setting.description ? h('div', {
          class: 'desc', text: setting.description, title: t('clickToExpand'),
          onclick: () => row.classList.toggle('expanded')
        }) : null),
      h('td', { class: 'v' }, editor),
      h('td', null, state.edits.has(setting.key) ? revertButton(setting) : null)
    );
    return row;
  }

  function renderSaveBar() {
    const host = $('#saveBarHost');
    if (!host) return;
    if (!state.edits.size) { host.replaceChildren(); return; }
    host.replaceChildren(h('div', { class: 'savebar' },
      h('strong', { text: t('pendingChanges', { n: state.edits.size }) }),
      h('label', { class: 'check', title: t('applyToMemoryHint') },
        h('input', { type: 'checkbox', checked: state.applyToMemory, onchange: (e) => { state.applyToMemory = e.target.checked; } }),
        t('applyToMemory')),
      h('button', { type: 'button', class: 'btn', onclick: discardEdits }, t('discard')),
      h('button', { type: 'button', class: 'btn', onclick: () => { state.cfg.onlyChanged = true; renderConfigTab($('#tabBody'), current()); } }, t('review')),
      h('button', { type: 'button', class: 'btn btn-primary', onclick: () => saveConfig('module') }, t('save'))));
    // Refresh revert buttons without re-rendering the whole table.
    document.querySelectorAll('#cfgRows tr[data-key]').forEach((tr) => {
      const last = tr.lastElementChild;
      if (!last) return;
      const dirty = state.edits.has(tr.dataset.key);
      if (dirty && !last.firstChild) {
        const setting = state.config.settings.find((s) => s.key === tr.dataset.key);
        if (setting) last.append(revertButton(setting));
      } else if (!dirty && last.firstChild) {
        last.replaceChildren();
      }
    });
  }

  function discardEdits() {
    state.edits.clear();
    renderConfigRows();
    renderSaveBar();
    refreshTabs();
  }

  async function reloadConfig(instance) {
    if (!(await confirmDiscardEdits())) return;
    state.config = null;
    renderConfigTab($('#tabBody'), instance);
  }

  const displayValue = (key, value) => {
    const setting = state.config && state.config.settings.find((s) => s.key === key);
    if (setting && setting.secret && value) return '********';
    return value === '' ? t('emptyValue') : value;
  };

  async function saveConfig(mode) {
    const instance = current();
    const changes = Array.from(state.edits, ([key, value]) => ({ key, value }));
    if (!changes.length) return;

    if (mode === 'module') {
      const list = h('ul', { class: 'change-list' }, changes.map((c) => h('li', null,
        h('span', { class: 'key', text: c.key }), h('br'),
        h('span', { class: 'old', text: displayValue(c.key, originalValue(c.key)) }),
        h('span', { class: 'arrow', text: '→' }),
        h('span', { class: 'new', text: displayValue(c.key, c.value) }))));
      const ok = await openDialog({
        title: t('saveTitle', { name: instance.name }),
        body: [h('p', null, t('saveText')), list],
        actions: [{ label: t('cancel'), value: false }, { label: t('save'), value: true, kind: 'btn-primary' }]
      });
      if (!ok) return;
    }

    let result;
    const progress = toast(t('saving'));
    try {
      result = await api(instancePath(instance.name, '/config'), {
        method: 'POST',
        body: { changes, stamp: state.config.stamp, applyToMemory: state.applyToMemory, mode }
      });
    } catch (e) {
      progress.remove();
      if (e.code === 'worker_unavailable' && mode !== 'file') {
        const useFile = await confirmDialog(t('moduleUnavailableTitle'), t('moduleUnavailableText', { error: e.message }), t('saveToFile'), false);
        if (useFile) await saveConfig('file');
        return;
      }
      if (e.code === 'stale') {
        const reload = await confirmDialog(t('staleTitle'), e.message, t('reload'), false);
        if (reload) { state.edits.clear(); state.config = null; renderConfigTab($('#tabBody'), instance); }
        return;
      }
      toast(e.message, 'error');
      return;
    }

    progress.remove();
    let needsRestart = false;
    const items = (result.results || []).map((r) => {
      const change = changes.find((c) => c.key === r.key);
      const notes = [];
      if (r.ok) {
        state.edits.delete(r.key);
        if (r.memory && r.memory.ok) notes.push(h('span', { class: 'note ok', text: t('appliedLive') }));
        else {
          needsRestart = true;
          if (r.memory && !r.memory.ok) notes.push(h('span', { class: 'note warn', text: t('notAppliedLive') + ' ' + (r.memory.error || '') }));
        }
      } else {
        notes.push(h('span', { class: 'note error', text: r.error || t('error') }));
      }
      return h('li', null,
        h('span', { class: r.ok ? 'badge ok' : 'badge error', text: r.ok ? t('saved') : t('failed') }), ' ',
        h('span', { class: 'key', text: r.key }), ' ',
        h('span', { class: 'new', text: change ? displayValue(r.key, change.value) : '' }),
        notes);
    });
    if (needsRestart) state.restartHint[instance.name] = true;
    await loadConfig(instance, true);
    if (state.view === 'instance' && state.selected === instance.name) {
      updateInstanceHeader();
      refreshTabs();
      if (state.tab === 'config') renderTab();
    }
    await openDialog({
      title: t('saveResultTitle'),
      body: [
        h('p', null, t('backupCreated', { name: result.backup })),
        result.mode === 'file' ? h('p', { class: 'muted' }, t('savedToFileNote')) : null,
        h('ul', { class: 'change-list' }, items),
        needsRestart ? h('p', { class: 'banner warn' }, t('restartHint')) : null
      ]
    });
  }

  async function credentialsDialog(instance) {
    await loadConfig(instance);
    const userSetting = state.configFor === instance.name && state.config ? state.config.settings.find((x) => x.key === 'DatabaseUserName') : null;
    const user = h('input', { class: 'input', id: 'credUser', value: userSetting ? userSetting.value : '', autocomplete: 'off' });
    const pass = h('input', { class: 'input', id: 'credPass', type: 'password', autocomplete: 'new-password' });
    const pass2 = h('input', { class: 'input', id: 'credPass2', type: 'password', autocomplete: 'new-password' });
    const message = h('p', { class: 'form-error' });
    const values = await openDialog({
      title: t('credentialsTitle', { name: instance.name }),
      body: [
        h('p', { class: 'muted' }, t('credentialsText')),
        h('div', { class: 'form-row' }, h('label', { for: 'credUser', text: t('dbUser') }), user),
        h('div', { class: 'form-row' }, h('label', { for: 'credPass', text: t('password') }), pass),
        h('div', { class: 'form-row' }, h('label', { for: 'credPass2', text: t('confirmPassword') }), pass2),
        message
      ],
      actions: [
        { label: t('cancel'), value: null },
        {
          label: t('save'), kind: 'btn-primary',
          validate: () => {
            if (!user.value.trim()) { message.textContent = t('userRequired'); return false; }
            if (pass.value !== pass2.value) { message.textContent = t('passwordMismatch'); return false; }
            return true;
          },
          collect: () => ({ user: user.value.trim(), password: pass.value })
        }
      ]
    });
    if (!values) return;
    try {
      const result = await api(instancePath(instance.name, '/credentials'), { method: 'POST', body: values });
      state.restartHint[instance.name] = true;
      state.config = null;
      toast(t('credentialsSaved', { backup: result.backup }), 'ok');
      updateInstanceHeader();
      renderTab();
    } catch (e) {
      toast(e.message, 'error');
    }
  }

  async function downloadExport(instance, format, event) {
    const menu = event && event.target.closest('details');
    if (menu) menu.open = false;
    try {
      const response = await api(instancePath(instance.name, '/export?format=' + format + '&lang=' + state.lang + '&secrets=' + (state.exportSecrets ? '1' : '0')), { raw: true });
      const blob = await response.blob();
      const disposition = response.headers.get('Content-Disposition') || '';
      const match = /filename="([^"]+)"/.exec(disposition);
      const link = h('a', { href: URL.createObjectURL(blob), download: match ? match[1] : instance.name + '.' + format });
      document.body.append(link);
      link.click();
      setTimeout(() => { URL.revokeObjectURL(link.href); link.remove(); }, 1000);
    } catch (e) {
      toast(e.message, 'error');
    }
  }

  /* ------------------------------------------------------------------ sessions */

  async function renderSessionsTab(body, instance, force) {
    if (instance.state !== 'Running') { body.replaceChildren(h('div', { class: 'empty' }, t('notRunningText'))); return; }
    if (force || !state.sessions.data) {
      body.replaceChildren(spinner(t('loadingModule')));
      state.sessions.error = null;
      try {
        state.sessions.data = (await api(instancePath(instance.name, '/sessions'))).items || [];
      } catch (e) {
        state.sessions.data = null;
        state.sessions.error = e.message;
      }
      if (state.tab !== 'sessions' || state.selected !== instance.name) return;
    }
    const toolbar = h('div', { class: 'toolbar' },
      h('input', {
        type: 'search', class: 'input search', placeholder: t('searchSessions'), value: state.sessions.q,
        oninput: (e) => { state.sessions.q = e.target.value; drawSessions(); }
      }),
      h('span', { class: 'grow' }),
      h('span', { class: 'muted small', id: 'sessCount' }),
      h('button', { type: 'button', class: 'btn', onclick: () => renderSessionsTab(body, instance, true) }, t('refresh')));
    if (state.sessions.error) { body.replaceChildren(toolbar, errorBox(state.sessions.error)); return; }

    const sessions = state.sessions.data;
    const available = SESSION_COLUMNS.filter(([key]) => sessions.some((s) => key in s));
    const columns = available.length ? available : Object.keys(sessions[0] || {}).map((k) => [k, null]);
    const summary = {};
    sessions.forEach((s) => { const k = s.ClientType || '?'; summary[k] = (summary[k] || 0) + 1; });
    const tbody = h('tbody');

    function drawSessions() {
      const q = state.sessions.q.trim().toLowerCase();
      const visible = sessions.filter((s) => !q || Object.values(s).some((v) => String(v).toLowerCase().includes(q)));
      tbody.replaceChildren(...(visible.length ? visible.map((s) => h('tr', null,
        columns.map(([key]) => h('td', { class: key === 'SessionID' ? 'num mono' : 'nowrap', text: key === 'LoginDatetime' ? fmtDate(s[key]) : (s[key] === null || s[key] === undefined ? '' : String(s[key])) })),
        h('td', { class: 'num' }, h('button', { type: 'button', class: 'btn btn-sm btn-danger', onclick: () => endSession(instance, s) }, t('endSession')))
      )) : [h('tr', { class: 'empty-row' }, h('td', { colspan: String(columns.length + 1), text: t('noSessions') }))]));
      $('#sessCount').textContent = t('sessionsCount', { n: visible.length });
    }

    body.replaceChildren(
      toolbar,
      h('div', { class: 'chips' }, Object.keys(summary).sort().map((k) => h('span', { class: 'chip' }, k, h('span', { class: 'n', text: summary[k] })))),
      h('div', { class: 'table-wrap' },
        h('table', { class: 'grid' },
          h('thead', null, h('tr', null, columns.map(([key, label]) => h('th', { class: key === 'SessionID' ? 'num' : null, text: label ? t(label) : key })), h('th'))),
          tbody)));
    drawSessions();
  }

  async function endSession(instance, session) {
    const id = session.SessionID !== undefined ? session.SessionID : session.SessionId;
    const ok = await confirmDialog(t('endSessionTitle'), t('endSessionText', { id, user: session.UserID || '' }), t('endSession'), true);
    if (!ok) return;
    try {
      await api(instancePath(instance.name, '/sessions/' + enc(id) + '/remove'), { method: 'POST', body: {} });
      toast(t('sessionEnded', { id }), 'ok');
      renderSessionsTab($('#tabBody'), instance, true);
    } catch (e) {
      toast(e.message, 'error');
    }
  }

  /* ------------------------------------------------------------------ tenants */

  async function renderTenantsTab(body, instance, force) {
    if (instance.state !== 'Running') { body.replaceChildren(h('div', { class: 'empty' }, t('notRunningText'))); return; }
    if (force || !state.tenants.data) {
      body.replaceChildren(spinner(t('loadingModule')));
      state.tenants.error = null;
      try {
        state.tenants.data = (await api(instancePath(instance.name, '/tenants'))).items || [];
      } catch (e) {
        state.tenants.data = null;
        state.tenants.error = e.message;
      }
      if (state.tab !== 'tenants' || state.selected !== instance.name) return;
    }
    const toolbar = h('div', { class: 'toolbar' }, h('span', { class: 'grow' }),
      h('button', { type: 'button', class: 'btn', onclick: () => renderTenantsTab(body, instance, true) }, t('refresh')));
    if (state.tenants.error) { body.replaceChildren(toolbar, errorBox(state.tenants.error)); return; }
    const tenants = state.tenants.data;
    const preferred = ['Id', 'State', 'DatabaseName', 'DatabaseServer', 'DefaultCompany', 'AllowAppDatabaseWrite'];
    const keys = Array.from(new Set(tenants.flatMap((x) => Object.keys(x))));
    const columns = preferred.filter((k) => keys.includes(k)).concat(keys.filter((k) => !preferred.includes(k)).slice(0, 6));
    body.replaceChildren(toolbar, h('div', { class: 'table-wrap' },
      h('table', { class: 'grid' },
        h('thead', null, h('tr', null, columns.map((c) => h('th', { text: c })))),
        h('tbody', null, tenants.length ? tenants.map((row) => h('tr', null, columns.map((c) => h('td', { class: 'nowrap' },
          c === 'State' ? h('span', { class: 'badge ' + (String(row[c]) === 'Operational' ? 'ok' : 'pending'), text: row[c] }) : String(row[c] === null || row[c] === undefined ? '' : row[c]))))) :
          h('tr', { class: 'empty-row' }, h('td', { colspan: String(columns.length || 1), text: t('noTenants') }))))));
  }

  /* ------------------------------------------------------------------ events */

  function eventText(message) {
    // Drop the "Server instance / Tenant / Environment" preamble of BC events for the one-line summary.
    const lines = String(message || '').split(/\r?\n/);
    const rest = lines.filter((l) => !/^(Server instance|Tenant|Environment Name|Environment Type):/i.test(l.trim()) && l.trim());
    return rest.length ? rest : lines;
  }

  async function renderEventsTab(body, instance, force) {
    const ev = state.events;
    const select = (value, options, onchange) => h('select', { class: 'input', onchange },
      options.map(([v, label]) => h('option', { value: v, selected: String(value) === String(v) }, label)));
    const toolbar = h('div', { class: 'toolbar' },
      select(ev.source, [['Admin', t('eventsAdmin')], ['Application', t('eventsApplication')]], (e) => { ev.source = e.target.value; renderEventsTab(body, instance, true); }),
      select(ev.level, [['errors', t('levelErrors')], ['warnings', t('levelWarnings')], ['all', t('levelAll')]], (e) => { ev.level = e.target.value; renderEventsTab(body, instance, true); }),
      select(ev.max, [[50, '50'], [100, '100'], [250, '250'], [500, '500']], (e) => { ev.max = Number(e.target.value); renderEventsTab(body, instance, true); }),
      h('span', { class: 'grow' }),
      h('button', { type: 'button', class: 'btn', onclick: () => renderEventsTab(body, instance, true) }, t('refresh')));

    if (force || !ev.data) {
      body.replaceChildren(toolbar, spinner());
      ev.error = null;
      try {
        ev.data = (await api(instancePath(instance.name, '/events?source=' + ev.source + '&max=' + ev.max + '&level=' + EVENT_LEVELS[ev.level]))).items || [];
      } catch (e) {
        ev.data = null;
        ev.error = e.message;
      }
      if (state.tab !== 'events' || state.selected !== instance.name) return;
    }
    if (ev.error) { body.replaceChildren(toolbar, errorBox(ev.error)); return; }

    const list = h('div', { class: 'events' }, ev.data.length ? ev.data.map((item, index) => {
      const key = item.time + '|' + item.id + '|' + index;
      const lines = eventText(item.message);
      const wrapper = h('div', { class: 'event' });
      const level = String(item.level || '').toLowerCase();
      const head = h('button', {
        type: 'button', class: 'event-head', 'aria-expanded': ev.open.has(key) ? 'true' : 'false',
        onclick: () => {
          if (ev.open.has(key)) ev.open.delete(key); else ev.open.add(key);
          const pre = wrapper.querySelector('pre');
          if (pre) pre.remove(); else wrapper.append(h('pre', { text: item.message }));
          head.setAttribute('aria-expanded', ev.open.has(key) ? 'true' : 'false');
        }
      },
      h('span', { class: 'small mono', text: fmtDate(item.time) }),
      h('span', null, h('span', { class: 'badge ' + level, text: tOr('level' + item.level, item.level) })),
      h('span', { class: 'small muted mono', text: '#' + item.id }),
      h('span', { class: 'msg', text: lines[0] }));
      wrapper.append(head);
      if (ev.open.has(key)) wrapper.append(h('pre', { text: item.message }));
      return wrapper;
    }) : h('div', { class: 'empty' }, t('noEvents')));
    body.replaceChildren(toolbar, list);
  }

  /* ------------------------------------------------------------------ backups */

  async function renderBackupsTab(body, instance, force) {
    if (force || !state.backups.data) {
      body.replaceChildren(spinner());
      state.backups.error = null;
      try {
        state.backups.data = await api(instancePath(instance.name, '/backups'));
      } catch (e) {
        state.backups.data = null;
        state.backups.error = e.message;
      }
      if (state.tab !== 'backups' || state.selected !== instance.name) return;
    }
    const toolbar = h('div', { class: 'toolbar' },
      h('span', { class: 'muted small' }, t('backupFolder'), ' ', h('span', { class: 'mono', text: state.backups.data ? state.backups.data.directory : '' })),
      h('span', { class: 'grow' }),
      h('button', { type: 'button', class: 'btn', onclick: () => renderBackupsTab(body, instance, true) }, t('refresh')),
      h('button', { type: 'button', class: 'btn btn-primary', disabled: !instance.configPath, onclick: () => createBackup(instance) }, t('createBackup')));
    if (state.backups.error) { body.replaceChildren(toolbar, errorBox(state.backups.error)); return; }
    const items = state.backups.data.items || [];
    body.replaceChildren(
      toolbar,
      h('p', { class: 'muted small' }, t('backupsHelp')),
      h('div', { class: 'table-wrap' },
        h('table', { class: 'grid' },
          h('thead', null, h('tr', null, h('th', { text: t('colDate') }), h('th', { text: t('colReason') }), h('th', { text: t('colFile') }), h('th', { class: 'num', text: t('colSize') }), h('th'))),
          h('tbody', null, items.length ? items.map((b) => h('tr', null,
            h('td', { class: 'nowrap', text: fmtDate(b.created) }),
            h('td', null, h('span', { class: 'badge', text: tOr('reason-' + b.reason, b.reason) })),
            h('td', null, mono(b.name)),
            h('td', { class: 'num nowrap', text: fmtSize(b.size) }),
            h('td', { class: 'num' }, h('button', { type: 'button', class: 'btn btn-sm', onclick: () => restoreBackup(instance, b) }, t('restore')))
          )) : h('tr', { class: 'empty-row' }, h('td', { colspan: '5', text: t('noBackups') }))))));
  }

  async function createBackup(instance) {
    try {
      const result = await api(instancePath(instance.name, '/backups'), { method: 'POST', body: {} });
      toast(t('backupCreated', { name: result.name }), 'ok');
      renderBackupsTab($('#tabBody'), instance, true);
    } catch (e) {
      toast(e.message, 'error');
    }
  }

  async function restoreBackup(instance, backup) {
    const ok = await confirmDialog(t('restoreTitle'), t('restoreText', { date: fmtDate(backup.created), name: instance.name }), t('restore'), true);
    if (!ok) return;
    try {
      const result = await api(instancePath(instance.name, '/backups/restore'), { method: 'POST', body: { name: backup.name } });
      state.restartHint[instance.name] = true;
      state.config = null;
      state.edits.clear();
      toast(t('restored', { backup: result.backup }), 'ok');
      updateInstanceHeader();
      renderBackupsTab($('#tabBody'), instance, true);
    } catch (e) {
      toast(e.message, 'error');
    }
  }

  /* ------------------------------------------------------------------ compare */

  async function showCompare() {
    if (state.view === 'compare') return;
    if (!(await confirmDiscardEdits())) return;
    state.view = 'compare';
    resetInstanceData();
    const c = state.compare;
    if (!c.a && state.instances[0]) c.a = state.selected || state.instances[0].name;
    if (!c.b && state.instances.length > 1) c.b = (state.instances.find((i) => i.name !== c.a) || state.instances[0]).name;
    applyStaticText();
    renderInstanceList();
    renderMain();
  }

  function showInstances() {
    if (state.view === 'instance') return;
    state.view = 'instance';
    applyStaticText();
    renderInstanceList();
    renderMain();
  }

  async function renderCompare(main) {
    const c = state.compare;
    const pick = (value, onchange) => h('select', { class: 'input', onchange },
      state.instances.map((i) => h('option', { value: i.name, selected: i.name === value }, i.name + ' (' + (i.version || '?') + ')')));
    const tbody = h('tbody');
    const count = h('span', { class: 'muted small' });
    main.replaceChildren(
      h('div', { class: 'page-head' }, h('div', null,
        h('div', { class: 'page-title' }, h('h1', { text: t('compareTitle') })),
        h('div', { class: 'page-sub', text: t('compareSub') }))),
      h('div', { class: 'toolbar' },
        pick(c.a, (e) => { c.a = e.target.value; c.data = null; renderCompare(main); }),
        h('span', { class: 'muted', text: 'vs' }),
        pick(c.b, (e) => { c.b = e.target.value; c.data = null; renderCompare(main); }),
        h('input', { type: 'search', class: 'input search', placeholder: t('searchSettings'), value: c.q, oninput: (e) => { c.q = e.target.value; draw(); } }),
        h('label', { class: 'check' }, h('input', { type: 'checkbox', checked: c.onlyDiff, onchange: (e) => { c.onlyDiff = e.target.checked; draw(); } }), t('onlyDifferences')),
        h('label', { class: 'check' }, h('input', { type: 'checkbox', checked: c.showSecrets, onchange: (e) => { c.showSecrets = e.target.checked; draw(); } }), t('showSecrets')),
        h('span', { class: 'grow' }),
        count),
      h('div', { id: 'compareBody' }));

    const target = $('#compareBody');
    if (!c.a || !c.b) { target.replaceChildren(h('div', { class: 'empty' }, t('compareNeedTwo'))); return; }
    if (!c.data || c.data.a !== c.a || c.data.b !== c.b) {
      target.replaceChildren(spinner());
      try {
        const [left, right] = await Promise.all([api(instancePath(c.a, '/config')), api(instancePath(c.b, '/config'))]);
        c.data = { a: c.a, b: c.b, left, right };
        c.error = null;
      } catch (e) {
        c.error = e.message;
        c.data = null;
      }
      if (state.view !== 'compare') return;
    }
    if (c.error) { target.replaceChildren(errorBox(c.error)); return; }

    target.replaceChildren(h('div', { class: 'table-wrap' },
      h('table', { class: 'grid diff config-table' },
        h('colgroup', null, h('col', { class: 'c-key' }), h('col'), h('col')),
        h('thead', null, h('tr', null, h('th', { text: t('colSetting') }), h('th', { text: c.a }), h('th', { text: c.b }))),
        tbody)));

    function draw() {
      const left = new Map(c.data.left.settings.map((s) => [s.key, s]));
      const right = new Map(c.data.right.settings.map((s) => [s.key, s]));
      const keys = Array.from(new Set([...left.keys(), ...right.keys()])).sort((x, y) => x.localeCompare(y));
      const q = c.q.trim().toLowerCase();
      let differences = 0;
      const rows = [];
      const cell = (setting, cls) => {
        if (!setting) return h('td', { class: cls }, h('span', { class: 'missing', text: t('notPresent') }));
        const hidden = setting.secret && setting.value && !c.showSecrets;
        return h('td', { class: cls, text: hidden ? '********' : setting.value });
      };
      for (const key of keys) {
        const a = left.get(key);
        const b = right.get(key);
        const same = a && b && sameValue(a.value, b.value);
        // ServerInstance always differs; it is noise in a comparison.
        const differs = !same && key !== 'ServerInstance';
        if (differs) differences++;
        if (c.onlyDiff && !differs) continue;
        if (q && !(key.toLowerCase().includes(q) || (a && a.value.toLowerCase().includes(q)) || (b && b.value.toLowerCase().includes(q)))) continue;
        rows.push(h('tr', { class: !a || !b ? 'only' : (differs ? 'changed' : '') },
          h('td', { class: 'k', text: key }), cell(a, 'a'), cell(b, 'b')));
      }
      tbody.replaceChildren(...(rows.length ? rows : [h('tr', { class: 'empty-row' }, h('td', { colspan: '3', text: c.onlyDiff ? t('noDifferences') : t('noResults') }))]));
      count.textContent = t('differencesCount', { n: differences });
    }
    draw();
  }

  /* ------------------------------------------------------------------ shutdown */

  async function shutdown() {
    const message = state.edits.size ? t('shutdownTextEdits', { n: state.edits.size }) : t('shutdownText');
    const ok = await confirmDialog(t('shutdownTitle'), message, t('shutdown'), true);
    if (!ok) return;
    try { await api('/shutdown', { method: 'POST', body: {} }); } catch (e) { /* server may already be gone */ }
    state.fatal = true;
    clearTimeout(state.pollTimer);
    $('#main').replaceChildren(h('div', { class: 'empty' }, h('h2', { text: t('stoppedTitle') }), h('p', null, t('stoppedText'))));
    $('#instanceList').replaceChildren();
    document.querySelectorAll('.top-actions button').forEach((b) => { b.disabled = true; });
  }

  /* ------------------------------------------------------------------ bootstrap */

  function readToken() {
    const url = new URL(window.location.href);
    const fromUrl = url.searchParams.get('t');
    if (fromUrl) {
      store('sessionStorage', 'token', fromUrl);
      url.searchParams.delete('t');
      window.history.replaceState(null, '', url.pathname + url.search + url.hash);
    }
    state.token = fromUrl || load('sessionStorage', 'token');
  }

  function pickLanguage() {
    const saved = load('localStorage', 'lang');
    if (saved && I18N[saved]) return saved;
    const nav = (navigator.language || 'en').slice(0, 2).toLowerCase();
    return I18N[nav] ? nav : 'en';
  }

  function bindChrome() {
    $('#langSelect').addEventListener('change', (e) => {
      state.lang = e.target.value;
      store('localStorage', 'lang', state.lang);
      categoryCache.clear();
      applyStaticText();
      renderHostInfo();
      renderInstanceList();
      renderMain();
    });
    $('#btnTheme').addEventListener('click', toggleTheme);
    $('#btnShutdown').addEventListener('click', shutdown);
    $('#btnCompare').addEventListener('click', showCompare);
    $('#btnInstances').addEventListener('click', showInstances);
    $('#btnRefresh').addEventListener('click', async () => {
      try {
        await refreshInstances();
        if (state.view === 'instance') { resetInstanceDataKeepEdits(); renderMain(); } else renderMain();
      } catch (e) { toast(e.message, 'error'); }
    });
    $('#instanceFilter').addEventListener('input', (e) => { state.instanceFilter = e.target.value; renderInstanceList(); });
    window.addEventListener('beforeunload', (e) => {
      if (state.edits.size && !state.fatal) { e.preventDefault(); e.returnValue = ''; }
    });
    document.addEventListener('click', (e) => {
      document.querySelectorAll('details.menu[open]').forEach((menu) => { if (!menu.contains(e.target)) menu.open = false; });
    });
  }

  function resetInstanceDataKeepEdits() {
    state.sessions.data = null;
    state.tenants.data = null;
    state.events.data = null;
    state.backups.data = null;
    if (!state.edits.size) { state.config = null; state.configFor = null; }
  }

  async function init() {
    readToken();
    state.lang = pickLanguage();
    applyTheme(load('localStorage', 'theme'));
    applyStaticText();
    bindChrome();
    if (!state.token) { showFatal(t('tokenMissing')); return; }
    $('#main').replaceChildren(spinner());
    try {
      const [info, meta] = await Promise.all([
        api('/info'),
        fetch('data/settings-meta.json', { cache: 'no-store' }).then((r) => r.json())
      ]);
      state.info = info;
      compileMeta(meta);
      renderHostInfo();
      await refreshInstances();
    } catch (e) {
      if (!state.fatal) showFatal(e.message);
      return;
    }
    renderMain();
    schedulePoll();
  }

  document.addEventListener('DOMContentLoaded', init);
})();
