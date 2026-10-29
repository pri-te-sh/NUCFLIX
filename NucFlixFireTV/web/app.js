'use strict';
// ============================================================================
// NucFlix for Fire TV — 10-foot UI controller & D-pad spatial focus engine
// Netflix TV-style interface (Home / Shows / Movies / Live TV / My List / Search /
// Account / Player) on top of the native SurfaceView player.
// ============================================================================
(function () {
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const stage = $('#stage');
  const navEl = $('#nav');
  const modalLayer = $('#modal-layer');
  const Native = window.NucFlixNative || null;

  // ------------------------------------------------------------------ Utilities

  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  // Artwork goes through the native proxy, which also downsizes it to the width actually displayed.
  const imgURL = (u, w = 0) => {
    const s = String(u || '').trim();
    if (!/^https?:\/\//i.test(s)) return '';
    return Native ? '/api/img?url=' + encodeURIComponent(s) + (w ? '&w=' + w : '') : s;
  };
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const pad2 = n => String(n).padStart(2, '0');
  const fmtTime = sec => {
    const s = Math.max(0, Math.floor(sec || 0));
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
    return h ? `${h}:${pad2(m)}:${pad2(x)}` : `${m}:${pad2(x)}`;
  };
  const debounce = (fn, ms) => {
    let t = null;
    return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
  };
  const nLogo = (size = '') => `<span class="n-mark ${size}" aria-hidden="true">N</span>`;
  // NUCFLIX wordmark: letters grow towards the ends for the curved look (static transforms, no filters).
  const WORD_SCALE = [1.17, 1.075, 1.02, 1, 1.02, 1.075, 1.17];
  const wordmark = (cls = '') => `<div class="nf-wordmark ${cls}" aria-label="NUCFLIX">${'NUCFLIX'.split('').map((c, i) => `<span style="transform:scaleY(${WORD_SCALE[i]})">${c}</span>`).join('')}</div>`;
  // Images load eagerly by default: rows and grids already mount in pages, and hundreds of loading="lazy"
  // images cost ~200 ms of IntersectionObserver work per frame. Rows defer their off-screen posters themselves.
  const imgTag = (url, cls = '', w = 360, lazy = false) => {
    const src = imgURL(url, w);
    return src ? `<img class="${cls}"${lazy ? ' loading="lazy"' : ''} decoding="async" src="${esc(src)}" onerror="this.remove()">` : '';
  };

  const ICON = {
    play: '<svg viewBox="0 0 24 24" class="ico fill"><path d="M7 4.5v15l13-7.5z"/></svg>',
    pause: '<svg viewBox="0 0 24 24" class="ico fill"><path d="M6 4h4v16H6zM14 4h4v16h-4z"/></svg>',
    plus: '<svg viewBox="0 0 24 24" class="ico"><path d="M12 5v14M5 12h14"/></svg>',
    check: '<svg viewBox="0 0 24 24" class="ico"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
    info: '<svg viewBox="0 0 24 24" class="ico"><circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.5"/></svg>',
    restart: '<svg viewBox="0 0 24 24" class="ico"><path d="M4 12a8 8 0 1 0 2.5-5.8M4 4v5h5"/></svg>',
    fwd: '<svg viewBox="0 0 24 24" class="ico"><path d="M20 12a8 8 0 1 1-2.5-5.8M20 4v5h-5"/></svg>',
    star: '<svg viewBox="0 0 24 24" class="ico"><path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.8z"/></svg>',
    starFill: '<svg viewBox="0 0 24 24" class="ico fill gold"><path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8-4.3-4.1 5.9-.8z"/></svg>',
    vlc: '<svg viewBox="0 0 24 24" class="ico"><path d="M9.5 4h5l4 15h-13z"/><path d="M3 20h18M8 12h8"/></svg>',
    epg: '<svg viewBox="0 0 24 24" class="ico"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M9 9v11"/></svg>',
    subs: '<svg viewBox="0 0 24 24" class="ico"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 13h4M13 13h4M7 16h10"/></svg>',
    next: '<svg viewBox="0 0 24 24" class="ico fill"><path d="M5 4.5v15L15 12zM17 5h2.5v14H17z"/></svg>',
    up: '<svg viewBox="0 0 24 24" class="ico"><path d="M6 15l6-6 6 6"/></svg>',
    down: '<svg viewBox="0 0 24 24" class="ico"><path d="M6 9l6 6 6-6"/></svg>',
    speed: '<svg viewBox="0 0 24 24" class="ico"><path d="M12 13l4-4"/><path d="M4 18a9 9 0 1 1 16 0"/></svg>',
    aspect: '<svg viewBox="0 0 24 24" class="ico"><rect x="3" y="6" width="18" height="12" rx="2"/><path d="M7 10v4M17 10v4"/></svg>',
    format: '<svg viewBox="0 0 24 24" class="ico"><path d="M4 7h16M4 12h10M4 17h6"/></svg>',
    keyboard: '<svg viewBox="0 0 24 24" class="ico"><rect x="2" y="6" width="20" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"/></svg>',
    tv: '<svg viewBox="0 0 24 24" class="ico"><rect x="3" y="5" width="18" height="12" rx="2"/><path d="M8 21h8M12 17v4"/></svg>'
  };

  // ------------------------------------------------------------------ Persistent Store

  const Store = {
    get(k, d) {
      try {
        const v = localStorage.getItem('nucflix.' + k);
        return v == null ? d : JSON.parse(v);
      } catch (e) { return d; }
    },
    set(k, v) {
      try { localStorage.setItem('nucflix.' + k, JSON.stringify(v)); } catch (e) { /* quota */ }
    },
    remove(k) {
      try { localStorage.removeItem('nucflix.' + k); } catch (e) { /* ignore */ }
    }
  };

  const S = {
    scale: 1,
    screen: null,
    screenArgs: {},
    splashActive: true,
    // The active Xtream line. Comes from the paired NucFlix account (cloud.js) and lives only in memory.
    creds: null,
    // Per-profile data, synced live from Firestore for the chosen profile + line.
    favorites: new Set(),
    history: [],
    episodeProgress: {},
    taste: [],
    cloud: { profiles: [], lines: [], profile: null, line: null },
    prefs: Object.assign({
      liveFormat: 'ts',
      autoplayNext: true,
      showAdult: false
    }, Store.get('prefs', {})),
    account: null,
    helperUrl: '', // http://<tv-ip>:8765, filled in from /api/session
    deviceModel: 'Fire TV',
    epgCache: new Map(),
    rev: 0, // bumped whenever favorites / history / catalog change (rendered tabs compare against it)
    raw: null,
    cat: emptyCatalog()
  };

  function emptyCatalog() {
    return {
      loaded: false, version: 0,
      liveCats: [], live: [], vodCats: [], movies: [], seriesCats: [], series: [],
      liveById: new Map(), movieById: new Map(), seriesById: new Map(),
      catName: { live: {}, vod: {}, series: {} },
      index: new CatalogSearchIndex()
    };
  }

  function markDirty() {
    Home.dirty = true;
    S.rev++;
  }

  const savePrefs = () => Store.set('prefs', S.prefs);
  const tasteKey = () => 'tasteEvents.' + (S.cloud.profile ? S.cloud.profile.id : 'local');

  // ------------------------------------------------------------------ Stage scaling (1920x1080 -> screen)

  function fitStage() {
    const de = document.documentElement;
    const w = de.clientWidth || window.innerWidth || 1920;
    const h = de.clientHeight || window.innerHeight || 1080;
    S.scale = Math.min(w / 1920, h / 1080);
    stage.style.transform = `scale(${S.scale})`;
    stage.style.left = Math.round((w - 1920 * S.scale) / 2) + 'px';
    stage.style.top = Math.round((h - 1080 * S.scale) / 2) + 'px';
  }
  window.addEventListener('resize', fitStage);

  // ------------------------------------------------------------------ Template action binding

  const pendingActs = new Map();
  let actSeq = 0;
  function act(fn) {
    const id = 'a' + (++actSeq);
    pendingActs.set(id, fn);
    return `data-act="${id}"`;
  }
  function onF(fn) {
    const id = 'f' + (++actSeq);
    pendingActs.set(id, fn);
    return `data-onfocus="${id}"`;
  }
  function bindActs(root) {
    root.querySelectorAll('[data-act],[data-onfocus]').forEach(el => {
      const a = el.getAttribute('data-act');
      if (a && pendingActs.has(a)) { el._act = pendingActs.get(a); pendingActs.delete(a); }
      const f = el.getAttribute('data-onfocus');
      if (f && pendingActs.has(f)) { el._focus = pendingActs.get(f); pendingActs.delete(f); }
    });
    if (pendingActs.size > 8000) pendingActs.clear();
  }
  function mount(container, html) {
    container.innerHTML = html;
    bindActs(container);
    return container;
  }

  // ------------------------------------------------------------------ D-pad Spatial Focus Engine

  const Focus = {
    cur: null,
    memory: {},

    roots() {
      if (Modal.stack.length) return [Modal.stack[Modal.stack.length - 1].wrap];
      const arr = [];
      const scr = S.screen && document.getElementById(S.screen + '-screen');
      if (scr) arr.push(scr);
      if (!navEl.hidden) arr.push(navEl);
      return arr;
    },

    // Candidates for geometric moves. Grid tiles ([data-grid] children) are excluded and stand in as one
    // entry per grid, so a 600-channel grid doesn't cost 600 layout reads on every key press.
    all() {
      const out = [];
      for (const r of this.roots()) {
        r.querySelectorAll('.focusable').forEach(el => {
          if (el.parentElement.hasAttribute('data-grid')) return;
          if (el.getClientRects().length && !el.classList.contains('disabled')) out.push(el);
        });
        r.querySelectorAll('[data-grid]').forEach(grid => {
          const el = this.gridEntry(grid);
          if (el && el.getClientRects().length) out.push(el);
        });
      }
      return out;
    },

    gridEntry(grid) {
      const g = grid.closest('[data-group]');
      const m = g && this.memory[g.getAttribute('data-group')];
      if (m && m.isConnected && m.parentElement === grid) return m;
      return grid.firstElementChild;
    },

    // Grids move by index: columns come from the CSS grid, so no geometry is needed.
    gridMove(cur, dir) {
      const grid = cur.parentElement;
      const items = grid.children;
      const cols = grid._cols || (grid._cols = getComputedStyle(grid).gridTemplateColumns.split(' ').length || 1);
      const idx = Array.prototype.indexOf.call(items, cur);
      let next = -1;
      if (dir === 'LEFT') next = idx % cols ? idx - 1 : -1;
      else if (dir === 'RIGHT') next = (idx % cols < cols - 1 && idx + 1 < items.length) ? idx + 1 : -1;
      else if (dir === 'UP') next = idx - cols;
      else if (idx + cols < items.length) next = idx + cols;
      else if (Math.floor(idx / cols) < Math.floor((items.length - 1) / cols)) next = items.length - 1;
      if (next >= 0) { this.set(items[next]); return true; }
      return dir === 'UP' ? null : false; // null: leave the grid upwards via the geometric search
    },

    set(el) {
      if (!el) return;
      if (this.cur && this.cur !== el) this.cur.classList.remove('focused');
      this.cur = el;
      el.classList.add('focused');
      const g = el.closest('[data-group]');
      if (g) this.memory[g.getAttribute('data-group')] = el;
      ensureVisible(el);
      if (el._focus) {
        try { el._focus(el); } catch (e) { console.error(e); }
      }
    },

    first(root) {
      if (!root) return null;
      const list = Array.from(root.querySelectorAll('.focusable'));
      return list.find(el => el.getClientRects().length) || null;
    },

    move(dir) {
      const cur = this.cur;
      const inRoots = cur && cur.isConnected && this.roots().some(r => r.contains(cur));
      if (!inRoots) {
        this.set(defaultFocusFor(S.screen) || this.all()[0]);
        return false;
      }
      const vertical = dir === 'UP' || dir === 'DOWN';
      // Fast paths (no layout reads): rows move by index, grids by index and column count.
      const row = cur.parentElement && cur.parentElement.classList.contains('row-track') ? cur.closest('[data-row]') : null;
      if (row) {
        if (!vertical) {
          const next = dir === 'RIGHT' ? cur.nextElementSibling : cur.previousElementSibling;
          if (next) this.set(next);
          return !!next;
        }
        const rows = this.roots().flatMap(r => Array.from(r.querySelectorAll('[data-row]')));
        const target = rows[rows.indexOf(row) + (dir === 'DOWN' ? 1 : -1)];
        if (target) { this.set(this.rowEntry(target)); return true; }
      } else if (cur.parentElement && cur.parentElement.hasAttribute('data-grid')) {
        const moved = this.gridMove(cur, dir);
        if (moved !== null) return moved;
      }
      const list = this.all();
      let best = this.pick(list, cur, dir, true);
      if (!best && !(vertical && cur.closest('[data-trap]'))) best = this.pick(list, cur, dir, false);
      if (!best) return false;

      // Netflix-style per-row memory: re-enter a row / list where you left it.
      const g = best.closest('[data-group]');
      const cg = cur.closest('[data-group]');
      if (g && g !== cg) {
        if (g.hasAttribute('data-row') && best.parentElement.classList.contains('row-track')) {
          best = this.rowEntry(g);
        } else if (g === navEl) {
          const active = navEl.querySelector('.focusable.active');
          if (active) best = active;
        } else {
          const m = this.memory[g.getAttribute('data-group')];
          if (m && m !== best && m.isConnected && g.contains(m) && m.getClientRects().length) best = m;
        }
      }
      this.set(best);
      return true;
    },

    rowEntry(row) {
      const m = this.memory[row.getAttribute('data-group')];
      if (m && m.isConnected && row.contains(m)) return m;
      return row.querySelector('.row-track > .focusable');
    },

    pick(list, cur, dir, requireOverlap) {
      const cr = cur.getBoundingClientRect();
      const ccx = (cr.left + cr.right) / 2, ccy = (cr.top + cr.bottom) / 2;
      let best = null, bestScore = Infinity;
      for (const el of list) {
        if (el === cur || el.contains(cur) || cur.contains(el)) continue;
        const r = el.getBoundingClientRect();
        const cx = (r.left + r.right) / 2, cy = (r.top + r.bottom) / 2;
        let primary, secondary, overlap;
        if (dir === 'RIGHT') {
          if (cx <= ccx + 2 || r.left < cr.left + 2) continue;
          primary = Math.max(0, r.left - cr.right);
          secondary = Math.abs(cy - ccy);
          overlap = r.bottom > cr.top + 4 && r.top < cr.bottom - 4;
        } else if (dir === 'LEFT') {
          if (cx >= ccx - 2 || r.right > cr.right - 2) continue;
          primary = Math.max(0, cr.left - r.right);
          secondary = Math.abs(cy - ccy);
          overlap = r.bottom > cr.top + 4 && r.top < cr.bottom - 4;
        } else if (dir === 'DOWN') {
          if (cy <= ccy + 2 || r.top < cr.top + 2) continue;
          primary = Math.max(0, r.top - cr.bottom);
          secondary = Math.abs(cx - ccx);
          overlap = r.right > cr.left + 4 && r.left < cr.right - 4;
        } else {
          if (cy >= ccy - 2 || r.bottom > cr.bottom - 2) continue;
          primary = Math.max(0, cr.top - r.bottom);
          secondary = Math.abs(cx - ccx);
          overlap = r.right > cr.left + 4 && r.left < cr.right - 4;
        }
        if (requireOverlap && !overlap) continue;
        const score = (dir === 'LEFT' || dir === 'RIGHT')
          ? primary + secondary * 3
          : primary * 2 + secondary;
        if (score < bestScore) { bestScore = score; best = el; }
      }
      return best;
    }
  };

  function ensureVisible(el) {
    const s = S.scale || 1;
    let p = el.parentElement;
    while (p && p !== stage && p !== document.body) {
      const mode = p.getAttribute && p.getAttribute('data-scroll');
      if (mode) {
        const pr = p.getBoundingClientRect();
        const er = el.getBoundingClientRect();
        const m = Number(p.getAttribute('data-margin') || 40) * s;
        if (mode.includes('y')) {
          const anchor = p.getAttribute('data-align') === 'anchor' ? el.closest('[data-anchor]') : null;
          if (anchor && p.contains(anchor)) {
            if (anchor.getAttribute('data-anchor') === 'top') p.scrollTop = 0;
            else p.scrollTop += (anchor.getBoundingClientRect().top - pr.top - m) / s;
          } else if (er.top < pr.top + m) {
            p.scrollTop -= (pr.top + m - er.top) / s;
          } else if (er.bottom > pr.bottom - m) {
            p.scrollTop += (er.bottom - (pr.bottom - m)) / s;
          }
        }
        if (mode.includes('x')) {
          if (er.left < pr.left + m) p.scrollLeft -= (pr.left + m - er.left) / s;
          else if (er.right > pr.right - m) p.scrollLeft += (er.right - (pr.right - m)) / s;
        }
      }
      p = p.parentElement;
    }
  }

  // Re-render a region while keeping focus on the element with the same data-fk key.
  function refocusAfter(root, fn) {
    const key = Focus.cur && Focus.cur.isConnected && root.contains(Focus.cur)
      ? Focus.cur.getAttribute('data-fk') : null;
    const hadFocus = Focus.cur && root.contains(Focus.cur);
    fn();
    if (!hadFocus && Focus.cur && Focus.cur.isConnected) return;
    let el = null;
    if (key) el = root.querySelector(`[data-fk="${CSS.escape(key)}"]`);
    Focus.set(el || defaultFocusFor(S.screen) || Focus.first(root));
  }

  // ------------------------------------------------------------------ Modal Stack

  const Modal = {
    stack: [],
    open(html, opts = {}) {
      const prevFocus = Focus.cur;
      if (this.stack.length) this.stack[this.stack.length - 1].wrap.style.display = 'none';
      const wrap = document.createElement('div');
      wrap.className = 'modal-wrap';
      mount(wrap, html);
      modalLayer.appendChild(wrap);
      modalLayer.hidden = false;
      this.stack.push({ wrap, prevFocus, onClose: opts.onClose || null });
      const f = opts.focus ? wrap.querySelector(opts.focus) : null;
      Focus.set(f || Focus.first(wrap));
      return wrap;
    },
    close() {
      const top = this.stack.pop();
      if (!top) return;
      top.wrap.remove();
      if (this.stack.length) this.stack[this.stack.length - 1].wrap.style.display = '';
      else modalLayer.hidden = true;
      if (top.prevFocus && top.prevFocus.isConnected) Focus.set(top.prevFocus);
      else Focus.set(defaultFocusFor(S.screen));
      if (top.onClose) top.onClose();
    },
    closeAll() { while (this.stack.length) this.close(); }
  };

  function confirmModal({ title, message, okLabel = 'OK', cancelLabel = 'Cancel', danger = false, onOk }) {
    Modal.open(`
      <div class="modal-sheet narrow">
        <h2 class="modal-title">${esc(title)}</h2>
        ${message ? `<p class="modal-sub">${esc(message)}</p>` : ''}
        <div class="modal-actions">
          <div class="tv-btn ${danger ? 'danger' : ''} focusable" ${act(() => { Modal.close(); onOk && onOk(); })}>${esc(okLabel)}</div>
          <div class="tv-btn focusable" ${act(() => Modal.close())}>${esc(cancelLabel)}</div>
        </div>
      </div>`);
  }

  function listModal({ title, subtitle, rows, focusIndex = 0 }) {
    // rows: [{ label, value?, selected?, onSelect }]
    const wrap = Modal.open(`
      <div class="modal-sheet">
        <h2 class="modal-title">${esc(title)}</h2>
        ${subtitle ? `<p class="modal-sub">${esc(subtitle)}</p>` : ''}
        <div class="modal-list" data-scroll="y" data-margin="30" data-trap="1">
          ${rows.map((r, i) => `
            <div class="modal-row focusable ${r.selected ? 'selected' : ''}" data-idx="${i}" ${act(() => r.onSelect && r.onSelect())}>
              <span class="modal-row-label">${r.selected ? '✓ ' : ''}${esc(r.label)}</span>
              ${r.value != null ? `<span class="modal-row-value">${esc(r.value)}</span>` : ''}
            </div>`).join('')}
        </div>
      </div>`);
    const el = wrap.querySelector(`.modal-row[data-idx="${focusIndex}"]`);
    if (el) Focus.set(el);
    return wrap;
  }

  // ------------------------------------------------------------------ Toast

  let toastTimer = null;
  function toast(msg, ms = 2800) {
    const t = $('#toast');
    t.textContent = msg;
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.hidden = true; }, ms);
  }

  // ------------------------------------------------------------------ Splash
  // The intro is CSS keyframes (transform/opacity) that start with the page, so the compositor keeps it smooth
  // while the main thread parses the ~40 MB catalog. JS only plays the ta-dum and ends it once the app is ready.

  const splashStart = performance.now();
  try { Native && Native.playTudum(); } catch (e) { /* ignore */ }

  function endSplash() {
    return new Promise(resolve => {
      const splash = $('#splash');
      const wait = Math.max(0, 1900 - (performance.now() - splashStart));
      setTimeout(() => {
        splash.classList.add('exit');
        setTimeout(() => {
          splash.style.display = 'none';
          S.splashActive = false;
          resolve();
        }, 900);
      }, wait);
    });
  }

  // ------------------------------------------------------------------ Router

  const Screens = {};

  function defaultFocusFor(name) {
    const scr = Screens[name];
    let el = scr && scr.defaultFocus ? scr.defaultFocus() : null;
    if (!el) el = Focus.first(document.getElementById(name + '-screen'));
    if (!el && !navEl.hidden) el = navEl.querySelector('.focusable.active') || Focus.first(navEl);
    return el;
  }

  function updateNavActive() {
    const tabFor = { home: 'home', live: 'live', movies: 'movies', series: 'series', search: 'search', mylist: 'mylist', account: 'account' };
    let tab = tabFor[S.screen];
    if (!tab) {
      for (let i = Router.stack.length - 1; i >= 0 && !tab; i--) tab = tabFor[Router.stack[i].name];
    }
    $$('[data-nav]', navEl).forEach(el => el.classList.toggle('active', el.getAttribute('data-nav') === tab));
  }

  function activate(name, args, doRender) {
    const prev = S.screen;
    if (prev && prev !== name) {
      const p = Screens[prev];
      if (p && p.onHide) p.onHide();
      const pe = document.getElementById(prev + '-screen');
      if (pe) pe.classList.remove('active');
    }
    S.screen = name;
    S.screenArgs = args || {};
    document.getElementById(name + '-screen').classList.add('active');
    navEl.hidden = (name === 'pair' || name === 'player' || name === 'who');
    if (!navEl.hidden) updateNavProfile();
    if (name !== 'player') stage.classList.remove('video-passthrough');
    const scr = Screens[name];
    if (doRender && scr.render) scr.render(args || {});
    if (scr.onShow) scr.onShow(args || {}, !!doRender);
    updateNavActive();
  }

  const Router = {
    stack: [],
    go(name, args = {}, opts = {}) {
      if (opts.tab) {
        this.stack = name === 'home' ? [] : [{ name: 'home', args: {}, focus: null }];
      } else if (S.screen && S.screen !== 'pair' && S.screen !== 'player' && !opts.replace) {
        this.stack.push({ name: S.screen, args: S.screenArgs, focus: Focus.cur });
        if (this.stack.length > 30) this.stack.shift();
      }
      activate(name, args, opts.render !== false);
      if (!opts.noFocus) Focus.set(opts.focus || defaultFocusFor(name));
    },
    back() {
      const prev = this.stack.pop();
      if (!prev) return false;
      const el = document.getElementById(prev.name + '-screen');
      const rerender = prev.name === S.screen || !el.childElementCount;
      activate(prev.name, prev.args, rerender);
      let f = (prev.focus && prev.focus.isConnected && el.contains(prev.focus)) ? prev.focus : null;
      if (!f && prev.focus && prev.focus.getAttribute) {
        const key = prev.focus.getAttribute('data-fk');
        if (key) f = el.querySelector(`[data-fk="${CSS.escape(key)}"]`);
      }
      if (!f) f = defaultFocusFor(prev.name);
      Focus.set(f);
      return true;
    }
  };

  function goTab(name, args = {}) {
    Router.go(name, args, { tab: true });
  }

  function bindNav() {
    navEl.setAttribute('data-group', 'nav');
    $$('[data-nav]', navEl).forEach(el => {
      el.classList.add('focusable');
      const name = el.getAttribute('data-nav');
      el.setAttribute('data-fk', 'nav-' + name);
      el._act = () => goTab(name);
    });
  }

  function updateNavProfile() {
    const av = $('#nav-avatar');
    if (av) av.textContent = initial(S.cloud.profile ? S.cloud.profile.name : '');
  }

  // ------------------------------------------------------------------ Catalog loading & adult filter

  const ADULT_RE = /\b(adult|xxx|18\+|porn|erotic|for adults)\b/i;

  async function loadCatalog() {
    const c = S.creds;
    const [liveCats, live, vodCats, movies, seriesCats, series] = await Promise.all([
      XtreamAPI.fetchLiveCategories(c),
      XtreamAPI.fetchLiveStreams(c),
      XtreamAPI.fetchVODCategories(c),
      XtreamAPI.fetchVODStreams(c),
      XtreamAPI.fetchSeriesCategories(c),
      XtreamAPI.fetchSeries(c)
    ]);
    // A failed refresh returns empty lists; never let it wipe a catalog that's already showing.
    if (!(live.length + movies.length + series.length) && S.cat.loaded) throw new Error('The provider returned an empty catalog');
    S.raw = { liveCats, live, vodCats, movies, seriesCats, series };
    applyCatalogFilter();
    if (S.cat.live.length + S.cat.movies.length + S.cat.series.length) CatalogCache.save(c, S.raw);
  }

  // ------------------------------------------------------------------ Catalog cache
  // The provider's catalog is ~40 MB of JSON (~80k titles) and took 8-10 s to download and process on every
  // launch. A compact copy (one key list + value rows per list, ~1/3 the size, already cleaned up) is kept in
  // IndexedDB, so start-up shows Home from it in ~2 s and refreshes from the provider in the background.

  const CACHE_VERSION = 1;
  const CACHE_TTL = 12 * 60 * 60 * 1000;
  const CACHE_LISTS = ['liveCats', 'live', 'vodCats', 'movies', 'seriesCats', 'series'];
  const CACHE_ROWS = 8000; // rows per JSON chunk, so (de)serializing never blocks for long

  const CatalogCache = {
    db: null,
    saveTimer: null,

    open() {
      if (!this.db) {
        this.db = new Promise((resolve, reject) => {
          const req = indexedDB.open('nucflix', 1);
          req.onupgradeneeded = () => req.result.createObjectStore('kv');
          req.onsuccess = () => resolve(req.result);
          req.onerror = () => reject(req.error);
        });
      }
      return this.db;
    },

    async get(key) {
      try {
        const db = await this.open();
        return await new Promise(resolve => {
          const q = db.transaction('kv').objectStore('kv').get(key);
          q.onsuccess = () => resolve(q.result || null);
          q.onerror = () => resolve(null);
        });
      } catch (e) { return null; }
    },

    async put(key, value) {
      try {
        const db = await this.open();
        await new Promise(resolve => {
          const t = db.transaction('kv', 'readwrite');
          t.objectStore('kv').put(value, key);
          t.oncomplete = t.onerror = t.onabort = resolve;
        });
      } catch (e) { /* storage full or unavailable: just run without a cache */ }
    },

    key(creds) { return 'catalog:' + creds.id; },

    async removeWhere(test) {
      try {
        const db = await this.open();
        await new Promise(resolve => {
          const t = db.transaction('kv', 'readwrite');
          const q = t.objectStore('kv').openCursor();
          q.onsuccess = () => {
            const c = q.result;
            if (!c) return;
            if (test(String(c.key))) c.delete();
            c.continue();
          };
          t.oncomplete = t.onerror = t.onabort = resolve;
        });
      } catch (e) { /* ignore */ }
    },

    /** Serializes in chunks during idle time a few seconds after the catalog loads. */
    save(creds, raw) {
      clearTimeout(this.saveTimer);
      this.saveTimer = setTimeout(async () => {
        const parts = {};
        for (const name of CACHE_LISTS) {
          const list = raw[name] || [];
          const keys = list.length ? Object.keys(list[0]) : [];
          const chunks = [];
          for (let i = 0; i < list.length; i += CACHE_ROWS) {
            chunks.push(JSON.stringify(list.slice(i, i + CACHE_ROWS).map(o => keys.map(k => o[k]))));
            await new Promise(r => setTimeout(r, 0));
          }
          parts[name] = { keys, chunks };
        }
        await this.put(this.key(creds), { v: CACHE_VERSION, at: Date.now(), parts });
      }, 6000);
    },

    async load(creds) {
      const rec = await this.get(this.key(creds));
      if (!rec || rec.v !== CACHE_VERSION || !rec.parts) return null;
      const raw = {};
      for (const name of CACHE_LISTS) {
        const part = rec.parts[name] || { keys: [], chunks: [] };
        const keys = part.keys;
        const out = [];
        for (const chunk of part.chunks) {
          for (const row of JSON.parse(chunk)) {
            const o = {};
            for (let i = 0; i < keys.length; i++) o[keys[i]] = row[i];
            out.push(o);
          }
        }
        raw[name] = out;
      }
      return { raw, at: rec.at };
    }
  };

  async function loadCachedCatalog(creds) {
    const hit = await CatalogCache.load(creds).catch(() => null);
    if (!hit || !(hit.raw.live.length + hit.raw.movies.length + hit.raw.series.length)) return null;
    S.creds = creds;
    S.raw = hit.raw;
    applyCatalogFilter();
    return hit.at;
  }

  // Background refresh after starting from the cache: account status always, catalog when the copy is stale.
  function refreshInBackground(cachedAt) {
    const creds = S.creds;
    setTimeout(async () => {
      try {
        const data = await XtreamAPI.authenticate(creds);
        if (S.creds !== creds) return;
        S.account = data.user_info || null;
        if (Date.now() - cachedAt > CACHE_TTL) await loadCatalog();
      } catch (e) {
        toast(`Couldn’t reach your IPTV server: ${e.message}. Showing your saved catalog.`, 5000);
      }
    }, 5000);
  }

  function applyCatalogFilter() {
    const r = S.raw;
    if (!r) return;
    const showAdult = S.prefs.showAdult;
    const cat = emptyCatalog();
    cat.version = S.cat.version + 1;
    // Adult categories: by name, plus the AI tags (Smart.Tags). Kids profiles also drop every category the
    // AI judged unsuitable for young children.
    const kids = isKids();
    const hidden = (kind, x) => {
      const tag = Smart.Tags.get(kind, x.categoryId);
      if (!showAdult && (ADULT_RE.test(x.categoryName) || (tag && tag.adult > 0.7))) return true;
      return kids && !!tag && tag.kids < 0.5;
    };
    const blocked = { live: new Set(), movie: new Set(), series: new Set() };
    const filterCats = (kind, list) => list.filter(x => {
      if (!hidden(kind, x)) return true;
      blocked[kind].add(x.categoryId);
      return false;
    });
    cat.liveCats = filterCats('live', r.liveCats);
    cat.vodCats = filterCats('movie', r.vodCats);
    cat.seriesCats = filterCats('series', r.seriesCats);
    const ok = kind => x => (showAdult && !kids) || (!(x.isAdult && !showAdult) && !blocked[kind].has(x.categoryId));
    cat.live = r.live.filter(x => !x.isSectionDivider && ok('live')(x));
    cat.movies = r.movies.filter(ok('movie'));
    cat.series = r.series.filter(ok('series'));
    cat.live.forEach(x => cat.liveById.set(x.streamId, x));
    cat.movies.forEach(x => cat.movieById.set(x.streamId, x));
    cat.series.forEach(x => cat.seriesById.set(x.seriesId, x));
    r.liveCats.forEach(x => { cat.catName.live[x.categoryId] = x.cleanName; });
    r.vodCats.forEach(x => { cat.catName.vod[x.categoryId] = x.cleanName; });
    r.seriesCats.forEach(x => { cat.catName.series[x.categoryId] = x.cleanName; });
    const searchItems = [];
    cat.live.forEach(d => searchItems.push({ name: d.name, cleanName: d.cleanName, kind: 'live', data: d }));
    cat.movies.forEach(d => searchItems.push({ name: d.name, cleanName: d.cleanName, kind: 'movie', data: d }));
    cat.series.forEach(d => searchItems.push({ name: d.name, cleanName: d.cleanName, kind: 'series', data: d }));
    cat.index.buildAsync(searchItems);
    cat.loaded = true;
    S.cat = cat;
    markDirty();
  }

  // ------------------------------------------------------------------ Profiles, history, favorites, taste

  const favKey = (kind, data) => kind === 'live' ? `live-${data.streamId}`
    : kind === 'movie' ? `movie-${data.streamId}` : `series-${data.seriesId}`;

  function isFav(kind, data) { return S.favorites.has(favKey(kind, data)); }

  function toggleFav(kind, data) {
    const k = favKey(kind, data);
    if (S.favorites.has(k)) {
      S.favorites.delete(k);
      toast(`Removed from ${kind === 'live' ? 'Favorites' : 'My List'}`);
    } else {
      S.favorites.add(k);
      logTaste(kind, data, 'favorite', 2.5);
      toast(`Added to ${kind === 'live' ? 'Favorites' : 'My List'}`);
    }
    Cloud.setFavorite(S.favorites.has(k), cloudFavorite(kind, data));
    markDirty();
    return S.favorites.has(k);
  }

  function favoriteEntries(kinds = ['movie', 'series']) {
    const out = [];
    for (const k of S.favorites) {
      const [kind, idStr] = k.split('-');
      const id = Number(idStr);
      if (!kinds.includes(kind)) continue;
      const d = kind === 'live' ? S.cat.liveById.get(id)
        : kind === 'movie' ? S.cat.movieById.get(id) : S.cat.seriesById.get(id);
      if (d) out.push({ kind, data: d });
    }
    return out.reverse();
  }

  function logTaste(kind, data, evKind, weight) {
    const content = kind === 'episode' ? 'series' : kind;
    S.taste.push({
      content,
      kind: evKind,
      categoryID: data.categoryId || '',
      title: data.cleanName || data.name || '',
      genres: RecommendationEngine.genres(data.genre || ''),
      weight,
      date: Date.now()
    });
    if (S.taste.length > 300) S.taste = S.taste.slice(-300);
    Store.set(tasteKey(), S.taste);
  }

  function historyEntry(key) { return S.history.find(h => h.key === key) || null; }

  function recordProgress(item, pos, dur) {
    if (!item) return;
    const now = Date.now();
    let entry;
    if (item.kind === 'live') {
      entry = {
        key: `live-${item.streamId}`, contentType: 'live', title: item.title,
        artwork: item.artwork, streamID: item.streamId, categoryID: item.categoryId, updatedAt: now
      };
    } else if (item.kind === 'movie') {
      entry = {
        key: `movie-${item.streamId}`, contentType: 'movie', title: item.title, artwork: item.artwork,
        streamID: item.streamId, ext: item.ext, categoryID: item.categoryId,
        position: pos, duration: dur, updatedAt: now
      };
    } else {
      const ep = item.episode;
      entry = {
        key: `series-${item.seriesId}`, contentType: 'series', title: item.seriesTitle, artwork: item.artwork,
        seriesID: item.seriesId, episodeID: ep.episodeId, season: ep.season, episodeNum: ep.episodeNum,
        episodeTitle: ep.cleanTitle, ext: ep.containerExtension, categoryID: item.categoryId,
        position: pos, duration: dur, updatedAt: now
      };
      S.episodeProgress[ep.episodeId] = { p: pos, d: dur, at: now };
    }
    S.history = [entry].concat(S.history.filter(h => h.key !== entry.key)).slice(0, 80);
    Cloud.saveProgress(cloudProgress(entry));
    markDirty();
  }

  /** Finished: 92% through or into the last 90 s (people stop during the credits). Same rule as the iPhone app. */
  function isWatched(position, duration) {
    if (!duration || duration < 60) return false;
    return position / duration >= 0.92 || duration - position <= 90;
  }

  function resumeFor(h) {
    if (!h || !h.duration || h.duration < 60) return 0;
    return (h.position > 20 && !isWatched(h.position, h.duration)) ? h.position : 0;
  }

  // Next episode for series whose latest episode is finished, keyed by series ID ({ forUpdate, entry }).
  const upNext = new Map();

  /** Continue Watching: titles in progress, plus "Up next" for series whose latest episode is finished. */
  function continueWatching() {
    const rows = [];
    for (const h of S.history) {
      if (h.contentType === 'live') continue;
      if (resumeFor(h) > 0) { rows.push(h); continue; }
      if (h.contentType === 'series' && isWatched(h.position, h.duration)) {
        const next = upNext.get(String(h.seriesID));
        if (next && next.forUpdate === h.updatedAt && next.entry) rows.push(next.entry);
      }
    }
    return rows.slice(0, 20);
  }

  /** Looks up the episode after each finished one (needs the series' episode list), then redraws Home. */
  async function refreshUpNext() {
    let changed = false;
    for (const h of S.history) {
      if (h.contentType !== 'series' || !isWatched(h.position, h.duration)) continue;
      const known = upNext.get(String(h.seriesID));
      if (known && known.forUpdate === h.updatedAt) continue;
      const creds = S.creds;
      const sInfo = await XtreamAPI.fetchSeriesInfo(creds, h.seriesID).catch(() => null);
      if (S.creds !== creds || !sInfo) return;
      const all = flattenEpisodes(sInfo);
      const idx = all.findIndex(e => e.episodeId === String(h.episodeID));
      const ep = idx >= 0 ? all[idx + 1] : null;
      upNext.set(String(h.seriesID), {
        forUpdate: h.updatedAt,
        entry: ep && Object.assign({}, h, {
          key: `upnext-${h.seriesID}`, episodeID: ep.episodeId, season: ep.season, episodeNum: ep.episodeNum,
          episodeTitle: ep.cleanTitle, ext: ep.containerExtension, position: 0, duration: 0, upNext: true
        })
      });
      changed = true;
    }
    if (changed) refreshVisible();
  }

  // ------------------------------------------------------------------ EPG cache

  async function getEPG(streamId) {
    const hit = S.epgCache.get(streamId);
    if (hit && Date.now() - hit.at < 5 * 60 * 1000) return hit.list;
    const list = await XtreamAPI.fetchShortEPG(S.creds, streamId, 10);
    S.epgCache.set(streamId, { at: Date.now(), list });
    return list;
  }

  function nowPlaying(list) {
    const now = Date.now() / 1000;
    return (list || []).find(e => e.startTimestamp <= now && e.stopTimestamp > now) || (list || [])[0] || null;
  }

  async function fillEPGLines(root, ids) {
    let i = 0;
    const worker = async () => {
      while (i < ids.length) {
        const id = ids[i++];
        try {
          const np = nowPlaying(await getEPG(id));
          root.querySelectorAll(`[data-epg-for="${id}"]`).forEach(el => {
            el.textContent = np ? np.title : 'Live broadcast';
          });
        } catch (e) { /* ignore */ }
      }
    };
    await Promise.all([worker(), worker(), worker()]);
  }

  // ------------------------------------------------------------------ Playback helpers

  function playLive(ch, list) {
    const channels = (list && list.length ? list : S.cat.live);
    const idx = Math.max(0, channels.findIndex(x => x.streamId === ch.streamId));
    Player.play({
      kind: 'live',
      key: `live-${ch.streamId}`,
      uid: `live-${ch.streamId}`,
      streamId: ch.streamId,
      title: ch.cleanName,
      subtitle: S.cat.catName.live[ch.categoryId] || 'Live TV',
      artwork: ch.streamIcon,
      categoryId: ch.categoryId,
      url: XtreamCredentials.liveStreamURL(S.creds, ch.streamId, S.prefs.liveFormat),
      channel: ch,
      channelList: channels,
      channelIndex: idx,
      resume: 0
    });
  }

  function playMovie(m, resume = 0, ext = null) {
    const extension = ext || m.containerExtension || 'mp4';
    Player.play({
      kind: 'movie',
      key: `movie-${m.streamId}`,
      uid: `movie-${m.streamId}`,
      streamId: m.streamId,
      title: m.cleanName,
      subtitle: [S.cat.catName.vod[m.categoryId], m.rating ? `★ ${m.rating}` : ''].filter(Boolean).join(' • '),
      artwork: m.streamIcon,
      categoryId: m.categoryId,
      ext: extension,
      data: m,
      url: XtreamCredentials.vodStreamURL(S.creds, m.streamId, extension),
      resume
    });
  }

  function flattenEpisodes(sInfo) {
    const out = [];
    for (const sn of (sInfo.sortedSeasonNumbers || [])) out.push(...(sInfo.episodesBySeason[sn] || []));
    return out;
  }

  function playEpisode(series, sInfo, ep, resume = 0) {
    const all = flattenEpisodes(sInfo);
    Player.play({
      kind: 'episode',
      key: `series-${series.seriesId}`,
      uid: `episode-${ep.episodeId}`,
      seriesId: series.seriesId,
      seriesTitle: series.cleanName,
      title: series.cleanName,
      subtitle: `S${ep.season}:E${ep.episodeNum} • ${ep.cleanTitle}`,
      artwork: series.cover,
      categoryId: series.categoryId,
      ext: ep.containerExtension,
      episode: ep,
      series,
      sInfo,
      episodes: all,
      episodeIndex: Math.max(0, all.findIndex(e => e.episodeId === ep.episodeId)),
      url: XtreamCredentials.seriesEpisodeURL(S.creds, ep.episodeId, ep.containerExtension),
      resume
    });
  }

  function seriesResumeTarget(series, sInfo) {
    const h = historyEntry(`series-${series.seriesId}`);
    const all = flattenEpisodes(sInfo);
    if (!all.length) return null;
    if (h) {
      const idx = all.findIndex(e => e.episodeId === String(h.episodeID));
      if (idx >= 0) {
        const r = resumeFor(h);
        if (r > 0) return { ep: all[idx], resume: r, label: `Resume S${all[idx].season}:E${all[idx].episodeNum}` };
        if (idx + 1 < all.length) return { ep: all[idx + 1], resume: 0, label: `Play S${all[idx + 1].season}:E${all[idx + 1].episodeNum}` };
      }
    }
    return { ep: all[0], resume: 0, label: `Play S${all[0].season}:E${all[0].episodeNum}` };
  }

  async function quickPlay(entry) {
    if (entry.kind === 'live') return playLive(entry.data);
    if (entry.kind === 'movie') {
      const h = historyEntry(`movie-${entry.data.streamId}`);
      return playMovie(entry.data, resumeFor(h));
    }
    toast('Loading episodes…', 1500);
    const sInfo = await XtreamAPI.fetchSeriesInfo(S.creds, entry.data.seriesId);
    const t = seriesResumeTarget(entry.data, sInfo);
    if (!t) { openDetail('series', entry.data); return; }
    playEpisode(entry.data, sInfo, t.ep, t.resume);
  }

  function openDetail(kind, data) {
    if (kind === 'live') { playLive(data); return; }
    Router.go('detail', { kind, data });
  }

  function openInVlc(url, title) {
    if (Native) Native.openInVlc(url, title || 'NucFlix');
    else window.open(url, '_blank');
  }

  // ------------------------------------------------------------------ Netflix TV row system
  // A row is a horizontal track: the focused title expands into a wide 16:9 card and slides to the left
  // edge, its details appear beneath the row, and the other rows dim (Netflix 2024 TV interface).

  const GAP = 16;
  const ROW_EAGER = 8; // posters per row loaded up front; the rest load as the row scrolls
  const ROW_TOP = 118; // rows align just below the top navigation

  const Rows = {
    // row = { id, title, style: 'poster' | 'landscape' | 'top10', items: [{ fk, html, act, info, more, cls }] }
    html(row) {
      if (!row.items.length) return '';
      return `
        <section class="row ${row.style}" data-row data-group="row-${esc(row.id)}">
          ${row.header || `<h3 class="row-title">${esc(row.title)}</h3>`}
          <div class="row-viewport"><div class="row-track">${row.items.map((it, i) => `
            <div class="ri focusable ${it.cls || ''}" data-idx="${i}" data-fk="${esc(it.fk)}"
              ${act(it.act)} ${onF(el => Rows.focus(el, it))}>${i < ROW_EAGER ? it.html : it.html.replace(' src="', ' data-src="')}</div>`).join('')}
          </div></div>
          <div class="row-info"></div>
        </section>`;
    },

    collapsedWidth(row, item) {
      if (row.classList.contains('landscape')) return 448;
      if (row.classList.contains('top10')) return item.classList.contains('wide') ? 470 : 400;
      return 240;
    },

    focus(el, item) {
      const row = el.closest('[data-row]');
      if (!row) return;
      const content = row.closest('.rows-content');
      if (content) {
        content.classList.add('row-mode');
        let above = true;
        content.querySelectorAll('.row').forEach(r => {
          if (r === row) above = false;
          r.classList.toggle('above', above && r !== row);
          if (r !== row) r.classList.remove('active');
        });
      }
      row.classList.add('active');
      const items = Array.from(row.querySelectorAll('.row-track > .ri'));
      const idx = Number(el.getAttribute('data-idx'));
      let x = 0;
      items.forEach((it, i) => {
        it.classList.toggle('past', i < idx);
        if (i < idx) x += this.collapsedWidth(row, it) + GAP;
      });
      row.querySelector('.row-track').style.transform = `translateX(${-x}px)`;
      for (let i = idx; i < Math.min(items.length, idx + ROW_EAGER); i++) {
        const img = items[i].querySelector('img[data-src]');
        if (img) { img.src = img.getAttribute('data-src'); img.removeAttribute('data-src'); }
      }
      if (content) content.style.transform = `translateY(${-Math.max(0, row.offsetTop - ROW_TOP)}px)`;
      this.showInfo(row, item);
    },

    // Focus inside the billboard / header area: scroll back to the top and undim every row.
    top(el) {
      const content = el.closest('.rows-content');
      if (!content) return;
      content.classList.remove('row-mode');
      content.querySelectorAll('.row.active, .row.above').forEach(r => r.classList.remove('active', 'above'));
      content.style.transform = 'translateY(0)';
    },

    infoHTML(info) {
      const meta = (info.meta || []).filter(Boolean).map(m => `<span>${esc(m)}</span>`).join('<span class="sep">•</span>');
      return `${meta ? `<div class="ri-meta">${meta}</div>` : ''}${info.text ? `<p class="ri-text">${esc(info.text)}</p>` : ''}`;
    },

    showInfo(row, item) {
      const box = row.querySelector('.row-info');
      const tk = box._tk = (box._tk || 0) + 1;
      if (!item.info) { box.innerHTML = ''; return; }
      const info = item.info();
      box.innerHTML = this.infoHTML(info);
      if (!info.text && item.more) {
        setTimeout(async () => {
          if (box._tk !== tk) return;
          const text = await item.more();
          if (text && box._tk === tk) box.innerHTML = this.infoHTML(Object.assign({}, info, { text }));
        }, 350);
      }
    }
  };

  // Rows pages mount the billboard and the first rows at once and stream the rest in over the next frames,
  // so a tab switch paints in one go instead of laying out ~200 posters before anything appears.
  const FIRST_ROWS = 3;
  function mountRows(root, head, rows, cls = '') {
    const tk = root._rowsTk = (root._rowsTk || 0) + 1;
    mount(root, `<div class="rows-page"><div class="rows-content ${cls}">${head}${rows.slice(0, FIRST_ROWS).join('')}</div></div>`);
    const content = root.querySelector('.rows-content');
    let i = FIRST_ROWS;
    const step = () => {
      if (root._rowsTk !== tk || i >= rows.length || !content.isConnected) return;
      const tmp = document.createElement('div');
      tmp.innerHTML = rows.slice(i, i + 2).join('');
      i += 2;
      bindActs(tmp);
      while (tmp.firstElementChild) content.appendChild(tmp.firstElementChild);
      setTimeout(step, 60);
    };
    setTimeout(step, 120);
  }

  // ------------------------------------------------------------------ Artwork, metadata & row items

  function entryArt(entry) {
    return entry.kind === 'series' ? (entry.data.cover || entry.data.backdrop) : entry.data.streamIcon;
  }

  function entryFk(prefix, entry) {
    return `${prefix}-${entry.kind}-${entry.kind === 'series' ? entry.data.seriesId : entry.data.streamId}`;
  }

  // Placeholder (dark gradient + N + title) with the artwork layered on top once it loads.
  function artwork(url, title, { fit = false, w = fit ? 240 : 360, lazy = false } = {}) {
    return `<div class="ph"><span>${esc(title || '')}</span></div>${imgTag(url, fit ? 'fit' : '', w, lazy)}`;
  }

  const plotCache = new Map();
  async function moviePlot(m) {
    if (plotCache.has(m.streamId)) return plotCache.get(m.streamId);
    const res = await XtreamAPI.fetchVODInfo(S.creds, m.streamId);
    const info = (res && res.info) || {};
    const plot = info.plot || info.description || '';
    plotCache.set(m.streamId, plot);
    return plot;
  }

  function entryMeta(entry) {
    const d = entry.data;
    const genres = RecommendationEngine.genres(d.genre || '').slice(0, 2).join(', ');
    const catName = (entry.kind === 'movie' ? S.cat.catName.vod : S.cat.catName.series)[d.categoryId];
    const year = String(d.releaseDate || '').slice(0, 4);
    return [
      genres || catName,
      year,
      entry.kind === 'series' ? 'Series' : 'Film',
      d.rating ? `★ ${d.rating}` : '',
      (d.qualityBadges || [])[0] || ''
    ];
  }

  function entryInfo(entry) {
    return { meta: entryMeta(entry), text: entry.kind === 'series' ? entry.data.plot : '' };
  }

  function posterItem(entry, prefix) {
    const d = entry.data;
    return {
      fk: entryFk(prefix, entry),
      act: () => openDetail(entry.kind, d),
      info: () => entryInfo(entry),
      more: entry.kind === 'movie' ? () => moviePlot(d) : null,
      html: `
        ${artwork(entryArt(entry), d.cleanName, { w: 480 })}
        <div class="ri-n">${nLogo('xs')}</div>
        <div class="ri-x">
          <div class="n-tag">${nLogo('xs')}<span>${entry.kind === 'series' ? 'SERIES' : 'FILM'}</span></div>
          <div class="ri-x-title">${esc(d.cleanName)}</div>
        </div>`
    };
  }

  function top10Item(entry, rank) {
    return {
      fk: `top10-${rank}`,
      cls: rank >= 10 ? 'wide' : '',
      act: () => openDetail(entry.kind, entry.data),
      info: () => entryInfo(entry),
      more: entry.kind === 'movie' ? () => moviePlot(entry.data) : null,
      html: `<span class="rank">${rank}</span><div class="t10-poster">${artwork(entryArt(entry), entry.data.cleanName)}</div>`
    };
  }

  function cwItem(h) {
    let art = h.artwork;
    let entry = null;
    if (h.contentType === 'movie') {
      const m = S.cat.movieById.get(Number(h.streamID));
      if (m) { entry = { kind: 'movie', data: m }; art = m.streamIcon || art; }
    } else {
      const s = S.cat.seriesById.get(Number(h.seriesID));
      if (s) { entry = { kind: 'series', data: s }; art = s.cover || art; }
    }
    const pct = h.upNext ? 0 : (h.duration ? clamp(h.position / h.duration, 0.03, 1) * 100 : 3);
    const title = XtreamTextFormatter.format(h.title).cleanTitle;
    const left = Math.max(1, Math.ceil(((h.duration || 0) - (h.position || 0)) / 60));
    return {
      fk: `cw-${h.key}`,
      act: async () => {
        if (!entry) return;
        if (h.contentType === 'movie') { playMovie(entry.data, resumeFor(h), h.ext); return; }
        const sInfo = await XtreamAPI.fetchSeriesInfo(S.creds, entry.data.seriesId);
        const ep = flattenEpisodes(sInfo).find(e => e.episodeId === String(h.episodeID));
        if (ep) playEpisode(entry.data, sInfo, ep, resumeFor(h));
        else openDetail('series', entry.data);
      },
      info: () => ({
        meta: [title, h.contentType === 'series' ? `S${h.season}:E${h.episodeNum} “${h.episodeTitle || ''}”` : 'Film', h.upNext ? 'Up next' : `${left} min left`],
        text: entry && entry.kind === 'series' ? entry.data.plot : ''
      }),
      more: entry && entry.kind === 'movie' ? () => moviePlot(entry.data) : null,
      html: `
        <div class="ls-art">${artwork(art, title, { w: 480 })}</div>
        <div class="ls-title">${esc(title)}</div>
        ${h.upNext ? `<div class="ls-upnext">Up next • S${h.season}:E${h.episodeNum}</div>` : `<div class="ls-bar"><i style="width:${pct.toFixed(1)}%"></i></div>`}`
    };
  }

  function liveItem(ch, list) {
    return {
      fk: `live-${ch.streamId}`,
      act: () => playLive(ch, list),
      info: () => ({ meta: [S.cat.catName.live[ch.categoryId] || 'Live TV', 'Live', ...(ch.qualityBadges || []).slice(0, 1)], text: '' }),
      more: async () => {
        const np = nowPlaying(await getEPG(ch.streamId));
        return np ? `Now: ${np.title}${np.description ? ' — ' + np.description : ''}` : '';
      },
      html: `
        <div class="ls-art live">${artwork(ch.streamIcon, ch.cleanName, { fit: true })}<span class="live-badge">LIVE</span></div>
        <div class="ls-title">${esc(ch.cleanName)}</div>`
    };
  }

  function episodeItem(series, sInfo, ep) {
    const pr = S.episodeProgress[ep.episodeId];
    const watched = !!(pr && isWatched(pr.p, pr.d));
    const pct = watched ? 100 : (pr && pr.d ? clamp(pr.p / pr.d, 0, 1) * 100 : 0);
    const resume = pr && pr.d && pr.p > 20 && !watched ? pr.p : 0;
    return {
      fk: `ep-${ep.episodeId}`,
      act: () => playEpisode(series, sInfo, ep, resume),
      info: () => ({ meta: [`S${ep.season}:E${ep.episodeNum}`, ep.cleanTitle, ep.duration, watched ? 'Watched' : ''], text: ep.plot }),
      html: `
        <div class="ls-art">${artwork(ep.movieImage || series.cover, 'E' + ep.episodeNum, { w: 480 })}</div>
        <div class="ls-title">${ep.episodeNum}. ${esc(ep.cleanTitle)}</div>
        ${watched ? `<div class="ls-watched">${ICON.check} Watched</div>` : ''}
        ${pct ? `<div class="ls-bar${watched ? ' done' : ''}"><i style="width:${pct.toFixed(1)}%"></i></div>` : ''}`
    };
  }

  const posterRow = (id, title, entries, prefix = id) =>
    Rows.html({ id, title, style: 'poster', items: entries.map(e => posterItem(e, prefix)) });

  // ------------------------------------------------------------------ Billboard (top of Home / Shows / Movies)

  function billboardHTML(entry, { reason = '', extra = '' } = {}) {
    if (!entry) return '';
    const d = entry.data;
    const inList = isFav(entry.kind, d);
    const meta = entryMeta(entry).filter(Boolean).map(m => `<span>${esc(m)}</span>`).join('<span class="sep">•</span>');
    const plot = entry.kind === 'series' ? d.plot : '';
    const btn = (fk, icon, label, fn) =>
      `<div class="tv-btn focusable" data-fk="${fk}" ${act(fn)} ${onF(el => Rows.top(el))}>${icon}<span>${esc(label)}</span></div>`;
    return `
      <section class="billboard" data-billboard>
        <div class="bb-art">${imgTag(entryArt(entry), '', 1280)}</div>
        <div class="bb-fade"></div>
        ${extra}
        <div class="bb-info">
          <div class="n-tag">${nLogo('xs')}<span>${entry.kind === 'series' ? 'SERIES' : 'FILM'}</span></div>
          <h1 class="bb-title">${esc(d.cleanName)}</h1>
          ${reason ? `<div class="bb-reason">${esc(reason)}</div>` : ''}
          <div class="bb-meta">${meta}</div>
          <p class="bb-synopsis" data-plot-for="${entry.kind === 'movie' ? d.streamId : ''}">${esc(plot || '')}</p>
          <div class="bb-buttons">
            ${btn('bb-play', ICON.play, 'Play', () => quickPlay(entry))}
            ${btn('bb-info', ICON.info, 'More Info', () => openDetail(entry.kind, d))}
            ${btn('bb-list', inList ? ICON.check : ICON.plus, 'My List', el => {
              const on = toggleFav(entry.kind, d);
              el.innerHTML = `${on ? ICON.check : ICON.plus}<span>My List</span>`;
            })}
          </div>
        </div>
      </section>`;
  }

  // Movies only carry their synopsis in get_vod_info — fill it in after render.
  function fillBillboardPlot(root, entry) {
    if (!entry || entry.kind !== 'movie') return;
    moviePlot(entry.data).then(plot => {
      const el = root.querySelector('.bb-synopsis');
      if (el && plot) el.textContent = plot;
    });
  }

  function pickHero(kind) {
    const feed = Home.feed;
    let picks = feed ? feed.heroPicks.filter(p => !kind || p.item.kind === kind) : [];
    if (!picks.length) {
      const pool = kind === 'series' ? S.cat.series : S.cat.movies;
      if (!pool.length) return null;
      return { entry: { kind: kind || 'movie', data: pool[0] }, reason: '' };
    }
    const p = picks[Math.floor(Math.random() * Math.min(picks.length, 4))];
    return { entry: { kind: p.item.kind, data: p.item.data }, reason: p.reason };
  }

  function loadingView(msg) {
    return `<div class="center-status-screen"><div class="spinner big"></div><h2>${esc(msg)}</h2></div>`;
  }

  function emptyState(icon, title, text) {
    return `<div class="empty-state">${icon}<h2>${esc(title)}</h2><p>${esc(text)}</p></div>`;
  }

  // ------------------------------------------------------------------ Pairing screen
  // The TV signs in anonymously and shows a code; the household owner enters it in the NucFlix iPhone app
  // (Settings → Pair a TV). Xtream logins are never typed on, or saved to, the TV.

  const Pair = {
    code: null,
    expiresAt: 0,
    handle: null,
    timer: null,
    error: '',

    render() {
      const code = this.code ? `${this.code.slice(0, 4)}<i></i>${this.code.slice(4)}` : '<span class="spinner"></span>';
      mount($('#pair-screen'), `
        <div class="pair-page">
          ${wordmark('pair-word')}
          <h1>Pair this TV with your NucFlix account</h1>
          <ol class="pair-steps">
            <li>Open <b>NucFlix</b> on your iPhone</li>
            <li>Go to <b>Settings → Pair a TV</b></li>
            <li>Enter this code</li>
          </ol>
          <div class="pair-code">${code}</div>
          <div class="pair-expiry" id="pair-expiry">${this.error ? '' : this.expiryText()}</div>
          ${this.error ? `<div class="pair-error">${esc(this.error)}</div>` : ''}
          <div class="pair-actions">
            <div class="action-btn white focusable" data-fk="pair-new" ${act(() => this.start())}>New Code</div>
          </div>
          <p class="pair-note">Profiles, IPTV lines, My List and Continue Watching come from your account and stay in sync with your iPhone.</p>
        </div>`);
    },

    expiryText() {
      if (!this.code) return 'Getting a code…';
      const left = Math.max(0, Math.round((this.expiresAt - Date.now()) / 1000));
      return `Code expires in ${Math.floor(left / 60)}:${pad2(left % 60)}`;
    },

    defaultFocus() { return $('#pair-screen [data-fk="pair-new"]'); },

    onShow() { this.start(); },
    onHide() { this.stop(); },

    async start() {
      this.stop();
      this.code = null;
      this.error = '';
      refocusAfter($('#pair-screen'), () => this.render());
      try {
        await Cloud.start();
        this.handle = await Cloud.beginPairing(S.deviceModel || 'Fire TV', info => this.paired(info));
        this.code = this.handle.code;
        this.expiresAt = this.handle.expiresAt;
      } catch (e) {
        this.error = `Couldn’t reach NucFlix: ${(e && e.message) || e}. Check the TV’s internet connection, then choose New Code.`;
      }
      if (S.screen === 'pair') refocusAfter($('#pair-screen'), () => this.render());
      this.timer = setInterval(() => this.tick(), 1000);
    },

    tick() {
      if (!this.code) return;
      if (Date.now() >= this.expiresAt) { this.start(); return; }
      const el = $('#pair-expiry');
      if (el) el.textContent = this.expiryText();
    },

    stop() {
      clearInterval(this.timer);
      this.timer = null;
      if (this.handle) { this.handle.cancel(); this.handle = null; }
    },

    paired({ ownerName }) {
      this.handle = null; // the approved code is cleaned up by Cloud
      this.stop();
      toast(`Paired with ${ownerName ? ownerName + '’s' : 'your'} NucFlix account`);
      startCloud();
      householdReady.then(() => Who.show());
    }
  };
  Screens.pair = Pair;

  // ------------------------------------------------------------------ Who's watching?

  const AVATAR_COLORS = {
    red: '#E50914', blue: '#1F80E0', green: '#299E5C', yellow: '#F2B81A',
    purple: '#7A47D9', orange: '#F5731A', teal: '#1A999E', pink: '#ED4D94'
  };

  const Who = {
    show() {
      Router.stack = [];
      Router.go('who', {}, { replace: true });
    },

    render() {
      const profiles = S.cloud.profiles;
      const tiles = profiles.map(p => `
        <div class="who-tile focusable" data-fk="who-${esc(p.id)}" ${act(() => activateProfile(p))}>
          <div class="who-avatar" style="background:${AVATAR_COLORS[p.avatar] || AVATAR_COLORS.red}">
            ${esc(initial(p.name))}
            ${p.kids ? '<span class="who-kids">KIDS</span>' : ''}
          </div>
          <div class="who-name">${esc(p.name)}</div>
        </div>`).join('');
      const notice = !profiles.length
        ? 'Create a profile in the NucFlix iPhone app to start watching.'
        : !S.cloud.lines.length ? 'Add an IPTV line in the NucFlix iPhone app (Settings → IPTV Lines) to start watching.' : '';
      mount($('#who-screen'), `
        <div class="who-page">
          ${wordmark('who-word')}
          <h1>Who’s watching?</h1>
          <div class="who-grid" data-group="who">${tiles}</div>
          ${notice ? `<p class="who-notice">${esc(notice)}</p>` : ''}
          <div class="who-footer">
            <span>${Cloud.ownerName ? `Paired with ${esc(Cloud.ownerName)}’s account` : 'Paired with your NucFlix account'}</span>
            <div class="tv-btn small focusable" data-fk="who-unpair" ${act(() => confirmModal({ title: 'Unpair this TV?', message: 'It will need a new code from your iPhone to watch again.', okLabel: 'Unpair', danger: true, onOk: () => unpairTV() }))}>Unpair</div>
          </div>
        </div>`);
    },

    onShow() { Cloud.stopSession(); },

    defaultFocus() {
      const root = $('#who-screen');
      const last = Cloud.lastProfileId;
      return (last && root.querySelector(`[data-fk="who-${CSS.escape(last)}"]`)) || root.querySelector('.who-tile') || Focus.first(root);
    }
  };
  Screens.who = Who;

  // ------------------------------------------------------------------ Cloud session glue

  let householdReady = Promise.resolve();
  let preloadP = null;
  let lastProgressDocs = [];
  let refreshTimer = null;

  function isKids() { return !!(S.cloud.profile && S.cloud.profile.kids); }

  /** Starts live profiles + lines for the paired household; `householdReady` resolves once both arrived. */
  function startCloud() {
    let gotProfiles = false, gotLines = false, ready;
    householdReady = new Promise(r => { ready = r; });
    Cloud.watchHousehold({
      onProfiles: list => {
        S.cloud.profiles = list;
        const cur = S.cloud.profile && list.find(p => p.id === S.cloud.profile.id);
        if (S.cloud.profile && !cur && S.screen !== 'who') { toast('This profile was removed'); Who.show(); }
        if (cur) S.cloud.profile = cur;
        gotProfiles = true;
        if (gotLines) ready();
        cloudChanged();
      },
      onLines: list => {
        S.cloud.lines = list;
        const cur = S.cloud.line && list.find(l => l.id === S.cloud.line.id);
        if (S.cloud.line && !cur && S.screen !== 'who') { toast('This IPTV line was removed from your account'); Who.show(); }
        if (cur) {
          S.cloud.line = cur;
          if (S.creds && S.creds.id === cur.id) Object.assign(S.creds, { serverURL: cur.serverURL, username: cur.username, password: cur.password, lineName: cur.name });
        }
        gotLines = true;
        if (gotProfiles) ready();
        cloudChanged();
      },
      onUnpaired: () => {
        if (!Cloud.paired) return;
        toast('This TV was removed from your NucFlix account');
        unpairTV();
      }
    });
  }

  function cloudChanged() {
    if (S.screen === 'who') refocusAfter($('#who-screen'), () => Who.render());
    else if (S.screen === 'account') Account.rerender();
  }

  /** Re-renders the visible screen shortly after synced data changes (not while watching). */
  function refreshVisible() {
    markDirty();
    clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => {
      if (S.screen === 'home' && !Modal.stack.length) refocusAfter($('#home-screen'), () => Home.render());
      else if (S.screen === 'mylist') refocusAfter($('#mylist-screen'), () => MyList.render());
    }, 800);
  }

  async function activateProfile(profile) {
    if (!S.cloud.lines.length) { toast('Add an IPTV line in the NucFlix iPhone app first'); return; }
    const line = S.cloud.lines.find(l => l.id === Cloud.lastLineId) || S.cloud.lines[0];
    S.cloud.profile = profile;
    S.taste = Store.get(tasteKey(), []);
    S.prefs.autoplayNext = !(profile.prefs && profile.prefs.autoplayNext === false);
    if (profile.kids && S.prefs.showAdult) {
      S.prefs.showAdult = false;
      if (S.raw) applyCatalogFilter();
    }
    await useLine(line);
  }

  /** Watches through `line` for the current profile; the line's login stays in memory (S.creds). */
  async function useLine(line) {
    S.favorites = new Set();
    S.history = [];
    S.episodeProgress = {};
    lastProgressDocs = [];
    S.cloud.line = line;
    Cloud.startSession(S.cloud.profile.id, line.id, { onFavorites: applyCloudFavorites, onProgress: applyCloudProgress });
    const creds = { id: line.id, lineName: line.name, serverURL: line.serverURL, username: line.username, password: line.password };
    if (preloadP) await preloadP;
    preloadP = null;
    const sameCatalog = S.cat.loaded && S.creds && S.creds.id === line.id;
    S.creds = creds;
    markDirty();
    Router.go('home', {}, { tab: true });
    if (!sameCatalog) {
      S.cat = emptyCatalog();
      S.raw = null;
      refocusAfter($('#home-screen'), () => Home.render());
      const cachedAt = await loadCachedCatalog(creds);
      S.creds = creds;
      if (cachedAt) {
        refreshInBackground(cachedAt);
      } else {
        try {
          await loginWith(creds);
        } catch (e) {
          toast(`Couldn’t reach ${line.name}: ${e.message}`, 6000);
        }
      }
      markDirty();
      if (S.screen === 'home') refocusAfter($('#home-screen'), () => Home.render());
    } else {
      refreshInBackground(Date.now());
    }
    prerenderTabs();
    startTags(line);
  }

  /** AI category tags (kids-safe, adult, language, genre) for the line; re-filters the catalog as they arrive. */
  let tagsTimer = null;
  function startTags(line) {
    if (!S.raw) return;
    Smart.Tags.start(line.id, S.raw, () => {
      clearTimeout(tagsTimer);
      tagsTimer = setTimeout(() => {
        if (!S.raw || !S.cloud.line || S.cloud.line.id !== line.id) return;
        if (isKids() || !S.prefs.showAdult) { applyCatalogFilter(); refreshVisible(); }
      }, 4000);
    });
  }

  function chooseLine() {
    const lines = S.cloud.lines;
    if (!S.cloud.profile || !lines.length) return;
    listModal({
      title: 'IPTV Line',
      subtitle: 'Lines are managed in the NucFlix iPhone app',
      rows: lines.map(l => ({
        label: l.name,
        value: l.username,
        selected: S.cloud.line && S.cloud.line.id === l.id,
        onSelect: () => {
          Modal.close();
          if (S.cloud.line && S.cloud.line.id === l.id) return;
          Cloud.selectLine(l.id);
          useLine(l);
        }
      })),
      focusIndex: Math.max(0, lines.findIndex(l => S.cloud.line && l.id === S.cloud.line.id))
    });
  }

  /** Clears everything this session holds (catalog, line login, synced data). */
  function resetSession() {
    Cloud.stopSession();
    if (S.screen === 'player') VideoAPI.stop();
    S.cloud.profile = null;
    S.cloud.line = null;
    S.creds = null;
    S.cat = emptyCatalog();
    S.raw = null;
    S.favorites = new Set();
    S.history = [];
    S.episodeProgress = {};
    lastProgressDocs = [];
    markDirty();
  }

  async function unpairTV() {
    resetSession();
    S.cloud.profiles = [];
    S.cloud.lines = [];
    await Cloud.unpair();
    Router.stack = [];
    Router.go('pair', {}, { replace: true });
  }

  // ---- favorites / progress <-> Firestore documents (same shape as the iOS app)

  function cloudFavorite(kind, d) {
    return {
      kind, id: kind === 'series' ? d.seriesId : d.streamId, title: d.cleanName || d.name,
      artwork: kind === 'series' ? (d.cover || '') : (d.streamIcon || ''), ext: d.containerExtension, categoryId: d.categoryId
    };
  }

  function cloudProgress(h) {
    if (h.contentType === 'series') {
      return {
        kind: 'episode', id: h.episodeID, episodeId: String(h.episodeID), seriesId: Number(h.seriesID),
        season: Number(h.season) || undefined, episode: Number(h.episodeNum) || undefined, title: h.title,
        subtitle: `S${h.season} E${h.episodeNum}${h.episodeTitle ? ' • ' + h.episodeTitle : ''}`,
        artwork: h.artwork, ext: h.ext, position: h.position, duration: h.duration
      };
    }
    if (h.contentType === 'movie') {
      return { kind: 'movie', id: h.streamID, streamId: Number(h.streamID), title: h.title, artwork: h.artwork, ext: h.ext, position: h.position, duration: h.duration };
    }
    return { kind: 'live', id: h.streamID, streamId: Number(h.streamID), title: h.title, artwork: h.artwork, position: 0, duration: 0 };
  }

  function applyCloudFavorites(docs) {
    const at = d => (d.addedAt && d.addedAt.toMillis ? d.addedAt.toMillis() : 0);
    S.favorites = new Set(docs.slice().sort((a, b) => at(a) - at(b)).map(d => `${d.kind}-${d.id}`));
    refreshVisible();
  }

  function applyCloudProgress(docs) {
    lastProgressDocs = docs;
    const local = new Map(S.history.map(h => [h.key, h]));
    const history = [];
    const seenSeries = new Set();
    const episodes = {};
    for (const d of docs) {
      const at = d.updatedAt && d.updatedAt.toMillis ? d.updatedAt.toMillis() : Date.now();
      const base = { title: d.title, artwork: d.artwork, ext: d.ext, position: d.position || 0, duration: d.duration || 0, updatedAt: at };
      if (d.kind === 'episode') {
        episodes[d.episodeId] = { p: d.position || 0, d: d.duration || 0, at };
        if (seenSeries.has(d.seriesId)) continue;
        seenSeries.add(d.seriesId);
        const m = /S(\d+)\s*E(\d+)/i.exec(d.subtitle || '');
        history.push(Object.assign(base, {
          key: `series-${d.seriesId}`, contentType: 'series', seriesID: d.seriesId, episodeID: String(d.episodeId),
          season: d.season || (m ? +m[1] : 0), episodeNum: d.episode || (m ? +m[2] : 0),
          episodeTitle: String(d.subtitle || '').split('•').slice(1).join('•').trim()
        }));
      } else if (d.kind === 'movie') {
        history.push(Object.assign(base, { key: `movie-${d.streamId}`, contentType: 'movie', streamID: d.streamId }));
      } else if (d.kind === 'live') {
        history.push(Object.assign(base, { key: `live-${d.streamId}`, contentType: 'live', streamID: d.streamId }));
      }
    }
    // Positions this TV recorded but hasn't written yet (writes are throttled) are newer than the server's.
    const merged = history.map(h => { const l = local.get(h.key); return l && l.updatedAt > h.updatedAt ? l : h; });
    S.history = merged.slice(0, 80);
    S.episodeProgress = episodes;
    refreshVisible();
  }

  function clearCloudHistory() {
    Cloud.deleteProgress(lastProgressDocs.map(d => d.key));
    S.history = [];
    S.episodeProgress = {};
    S.taste = [];
    Store.set(tasteKey(), []);
  }

  /**
   * Older versions kept the Xtream login, favorites and history in localStorage and cached catalogs per
   * login. All of that lives in the account now, so whatever is left on this TV is deleted at startup.
   */
  function purgeLegacyData() {
    ['activeCredentials', 'savedProfiles', 'favorites', 'watchHistory', 'episodeProgress', 'tasteEvents', 'cloudMigrated']
      .forEach(k => Store.remove(k));
    CatalogCache.removeWhere(key => key.includes('|')); // old caches were keyed "<server>|<username>"
  }

  async function loginWith(creds) {
    const data = await XtreamAPI.authenticate(creds);
    S.account = data.user_info || null;
    if (!S.creds || S.creds.id !== creds.id) S.epgCache.clear();
    S.creds = creds;
    await loadCatalog();
  }

  // ------------------------------------------------------------------ Home

  const Home = {
    feed: null,
    dirty: true,
    hero: null,

    buildFeed() {
      this.feed = RecommendationEngine.buildFeed({
        events: S.taste,
        movies: S.cat.movies,
        series: S.cat.series,
        vodCategoryNames: S.cat.catName.vod,
        watchHistory: S.history
      });
    },

    liveNow() {
      const favs = favoriteEntries(['live']).map(e => e.data);
      const recent = S.history.filter(h => h.contentType === 'live')
        .map(h => S.cat.liveById.get(Number(h.streamID))).filter(Boolean);
      const seen = new Set();
      const out = [];
      for (const ch of favs.concat(recent, S.cat.live.slice(0, 40))) {
        if (seen.has(ch.streamId)) continue;
        seen.add(ch.streamId);
        out.push(ch);
        if (out.length >= 18) break;
      }
      return out;
    },

    render() {
      const root = $('#home-screen');
      if (!S.cat.loaded) { mount(root, loadingView('Loading NucFlix…')); return; }
      if (!this.dirty && root.querySelector('.rows-content')) return;
      this.dirty = false;
      this.buildFeed();
      this.hero = pickHero(null);
      const f = this.feed;
      const rails = r => r.style === 'top10'
        ? Rows.html({ id: r.id, title: r.title, style: 'top10', items: r.items.map((x, i) => top10Item(x, i + 1)) })
        : posterRow(r.id, r.title, r.items.slice(0, 20));

      const rows = [];
      const cw = continueWatching();
      refreshUpNext();
      if (cw.length) rows.push(Rows.html({ id: 'cw', title: S.cloud.profile ? `Continue Watching for ${S.cloud.profile.name}` : 'Continue Watching', style: 'landscape', items: cw.map(cwItem) }));
      f.rails.slice(0, 2).forEach(r => rows.push(rails(r)));
      const live = this.liveNow();
      if (live.length) rows.push(Rows.html({ id: 'live', title: 'Live TV • Streaming Now', style: 'landscape', items: live.map(ch => liveItem(ch, live)) }));
      f.rails.slice(2).forEach(r => rows.push(rails(r)));
      const myList = favoriteEntries();
      if (myList.length) rows.push(posterRow('mylist', 'My List', myList.slice(0, 30)));

      mountRows(root, this.hero ? billboardHTML(this.hero.entry, { reason: this.hero.reason }) : '',
        rows.length ? rows : [emptyState(ICON.tv, 'Nothing here yet', 'Your provider returned no Movies or Series. Try Live TV.')]);
      if (this.hero) fillBillboardPlot(root, this.hero.entry);
    },

    onShow(args, rendered) {
      if (!rendered && this.dirty && S.cat.loaded) this.render();
    },

    defaultFocus() {
      const root = $('#home-screen');
      return root.querySelector('[data-fk="bb-play"]') || root.querySelector('.ri') || Focus.first(root);
    }
  };
  Screens.home = Home;

  // ------------------------------------------------------------------ Shows & Movies (billboard + category rows, or a category grid)

  // Top k of a large list by score, in one pass (fully sorting ~49k movies for a 10-item row took ~300 ms).
  function topBy(list, k, score) {
    const out = [];
    for (const x of list) {
      const sc = score(x);
      if (out.length === k && sc <= out[k - 1].sc) continue;
      let i = out.length < k ? out.push(null) - 1 : k - 1;
      while (i > 0 && out[i - 1].sc < sc) { out[i] = out[i - 1]; i--; }
      out[i] = { x, sc };
    }
    return out.map(o => o.x);
  }

  function makeBrowseScreen(kind) {
    const screenId = kind === 'movie' ? 'movies' : 'series';
    const PAGE = 140;
    const B = {
      catId: null,
      items: [],
      shown: 0,

      root() { return document.getElementById(screenId + '-screen'); },
      allData() { return kind === 'movie' ? S.cat.movies : S.cat.series; },
      wrap(d) { return { kind, data: d }; },
      noun() { return kind === 'movie' ? 'Movies' : 'Shows'; },

      cats() {
        const counts = {};
        this.allData().forEach(d => { counts[d.categoryId] = (counts[d.categoryId] || 0) + 1; });
        const list = kind === 'movie' ? S.cat.vodCats : S.cat.seriesCats;
        return list.filter(c => counts[c.categoryId]).map(c => Object.assign({ count: counts[c.categoryId] }, c));
      },

      addedAt(d) { return Number((kind === 'movie' ? d.added : d.lastModified) || 0); },

      newest() {
        if (this.newestFor !== S.cat.version) {
          this.newestList = this.allData().slice().sort((a, b) => this.addedAt(b) - this.addedAt(a));
          this.newestFor = S.cat.version;
        }
        return this.newestList;
      },

      render(args = {}) {
        this.catId = args.catId || null;
        const root = this.root();
        if (!S.cat.loaded) { mount(root, loadingView('Loading…')); return; }
        if (this.catId) { this.rowsRev = -1; this.renderGrid(); return; }
        // Revisiting the tab with unchanged data keeps the already-rendered rows (no rebuild / relayout).
        const rev = S.rev + ':' + S.cat.version;
        if (this.rowsRev === rev && root.querySelector('.rows-content')) return;
        this.rowsRev = rev;
        this.renderRows();
      },

      renderRows() {
        const root = this.root();
        if (!Home.feed) Home.buildFeed();
        const hero = pickHero(kind);
        const rows = [];
        const mine = favoriteEntries([kind]);
        if (mine.length) rows.push(posterRow(`${screenId}-mine`, 'My List', mine));
        const fresh = topBy(this.allData(), 24, d => this.addedAt(d)).map(d => this.wrap(d));
        if (fresh.length) rows.push(posterRow(`${screenId}-new`, `New on NucFlix`, fresh));
        const top = topBy(this.allData(), 10, d => parseFloat(d.rating) || 0).map(d => this.wrap(d));
        if (top.length >= 3) rows.push(Rows.html({ id: `${screenId}-top10`, title: `Top 10 ${this.noun()} Today`, style: 'top10', items: top.map((e, i) => top10Item(e, i + 1)) }));
        const catRows = this.cats().filter(c => c.count >= 2).slice(0, 8);
        const buckets = new Map(catRows.map(c => [c.categoryId, []]));
        for (const d of this.allData()) {
          const b = buckets.get(d.categoryId);
          if (b && b.length < 20) b.push(d);
        }
        catRows.forEach(c => rows.push(posterRow(`${screenId}-c${c.categoryId}`, c.cleanName, buckets.get(c.categoryId).map(d => this.wrap(d)))));
        const genres = `
          <div class="bb-genres">
            <span class="bb-section">${this.noun()}</span>
            <div class="tv-btn small focusable" data-fk="genres" ${act(() => this.openCategories())} ${onF(el => Rows.top(el))}>Categories ${ICON.down}</div>
          </div>`;
        mountRows(root, hero ? billboardHTML(hero.entry, { reason: hero.reason, extra: genres }) : genres,
          rows.length ? rows : [emptyState(ICON.tv, `No ${this.noun()} yet`, 'Your provider returned no titles in this section.')]);
        if (hero) fillBillboardPlot(root, hero.entry);
      },

      renderGrid() {
        const root = this.root();
        const isMine = this.catId === '__mylist';
        this.items = isMine ? favoriteEntries([kind])
          : this.catId === '__new' ? this.newest().map(d => this.wrap(d))
          : this.allData().filter(d => d.categoryId === this.catId).map(d => this.wrap(d));
        this.shown = 0;
        const title = isMine ? 'My List' : this.catId === '__new' ? `New ${this.noun()}`
          : ((kind === 'movie' ? S.cat.catName.vod : S.cat.catName.series)[this.catId] || 'Category');
        mount(root, `
          <div class="grid-page">
            <div class="grid-head">
              <div>
                <div class="grid-kicker">${this.noun()}</div>
                <h2>${esc(title)}</h2>
              </div>
              <div class="tv-btn small focusable" data-fk="genres" ${act(() => this.openCategories())}>Categories ${ICON.down}</div>
            </div>
            <div class="grid-focus" id="${screenId}-focus">${this.items.length} titles</div>
            <div class="grid-scroll" data-scroll="y" data-margin="40" data-group="${screenId}-grid">
              ${this.items.length ? '<div class="poster-grid" data-grid></div>' : emptyState(ICON.plus, 'Nothing here yet', 'Try another category.')}
            </div>
          </div>`);
        this.appendMore();
      },

      appendMore() {
        const grid = this.root().querySelector('.poster-grid');
        if (!grid || this.shown >= this.items.length) return;
        const start = this.shown;
        const html = this.items.slice(start, start + PAGE).map((e, j) => {
          const i = start + j;
          return `
            <div class="g-item focusable" data-fk="${entryFk('g', e)}" data-idx="${i}"
              ${act(() => openDetail(e.kind, e.data))} ${onF(() => this.focusItem(e, i))}>
              ${artwork(entryArt(e), e.data.cleanName)}<div class="ri-n">${nLogo('xs')}</div>
            </div>`;
        }).join('');
        const tmp = document.createElement('div');
        tmp.innerHTML = html;
        bindActs(tmp);
        while (tmp.firstElementChild) grid.appendChild(tmp.firstElementChild);
        this.shown = Math.min(this.items.length, start + PAGE);
      },

      focusItem(e, i) {
        if (i >= this.shown - 21) this.appendMore();
        const box = $(`#${screenId}-focus`);
        if (box) box.innerHTML = `<b>${esc(e.data.cleanName)}</b>${entryMeta(e).filter(Boolean).map(m => `<span class="sep">•</span><span>${esc(m)}</span>`).join('')}`;
      },

      openCategories() {
        categoryExplorer({
          title: `${this.noun()} Categories`,
          cats: this.cats(),
          selectedId: this.catId,
          specials: [['__mylist', 'My List', favoriteEntries([kind]).length], ['__new', `New ${this.noun()}`, this.allData().length]],
          onSelect: id => Router.go(screenId, { catId: id }, { replace: !!this.catId })
        });
      },

      defaultFocus() {
        const root = this.root();
        return root.querySelector('[data-fk="bb-play"]') || root.querySelector('.g-item') || root.querySelector('.ri') || Focus.first(root);
      },

      onMenu() {
        const el = Focus.cur;
        if (el && el.classList.contains('g-item')) {
          const e = this.items[Number(el.getAttribute('data-idx'))];
          if (e) toggleFav(e.kind, e.data);
          return true;
        }
        return false;
      }
    };
    return B;
  }
  Screens.movies = makeBrowseScreen('movie');
  Screens.series = makeBrowseScreen('series');

  // ------------------------------------------------------------------ My List (My List / Continue Watching / Favorite Channels)

  const MyList = {
    render() {
      const root = $('#mylist-screen');
      if (!S.cat.loaded) { mount(root, loadingView('Loading…')); return; }
      const rows = [];
      const mine = favoriteEntries();
      if (mine.length) rows.push(posterRow('ml-list', 'My List', mine));
      const cw = continueWatching();
      if (cw.length) rows.push(Rows.html({ id: 'ml-cw', title: 'Continue Watching', style: 'landscape', items: cw.map(cwItem) }));
      const chans = favoriteEntries(['live']).map(e => e.data);
      if (chans.length) rows.push(Rows.html({ id: 'ml-live', title: 'Favorite Channels', style: 'landscape', items: chans.map(ch => liveItem(ch, chans)) }));
      const recent = S.history.filter(h => h.contentType === 'live').map(h => S.cat.liveById.get(Number(h.streamID))).filter(Boolean).slice(0, 18);
      if (recent.length) rows.push(Rows.html({ id: 'ml-recent', title: 'Recently Watched Channels', style: 'landscape', items: recent.map(ch => liveItem(ch, recent)) }));
      if (rows.length) mountRows(root, '', rows, 'no-billboard');
      else mount(root, emptyState(ICON.plus, 'Your List is empty', 'Add shows and movies with “My List”, favorite channels with ☆, and pick up where you left off here.'));
    },
    defaultFocus() { return $('#mylist-screen .ri'); }
  };
  Screens.mylist = MyList;

  // ------------------------------------------------------------------ Category explorer (region groups + category list)

  const REGION_GROUPS = [
    { id: 'all', label: 'All', re: null },
    { id: 'sports', label: 'Cricket & Sports', re: /cricket|sport|football|ipl|fifa|ufc|wwe|willow|espn|bein|dazn/i },
    { id: 'asia', label: 'India & Asia', re: /asia|\bin\b|in\||hindi|punjabi|gujarati|tamil|telugu|malayalam|marathi|yupp|pak|bangla/i },
    { id: 'uk', label: 'UK', re: /\buk\b|sky|tnt|bbc/i },
    { id: 'usa', label: 'USA', re: /\bus\b|usa|nfl|nba|hbo/i },
    { id: '4k', label: '4K & UHD', re: /4k|uhd|hevc|dolby|raw/i }
  ];

  function categoryExplorer({ title, cats, selectedId, specials = [], onSelect }) {
    let group = 'all';
    let wrap = null;
    const row = (id, name, count, prefix) => `
      <div class="cat-item focusable ${id === selectedId ? 'on' : ''}" data-fk="ci-${esc(id)}" ${act(() => { Modal.close(); onSelect(id); })}>
        ${prefix ? `<span class="prefix-tag">${esc(prefix)}</span>` : ''}
        <span class="cat-item-name">${esc(name)}</span>
        ${count != null ? `<span class="cat-item-count">${count}</span>` : ''}
      </div>`;
    const build = () => {
      const g = REGION_GROUPS.find(x => x.id === group);
      const list = g.re ? cats.filter(c => g.re.test(c.categoryName)) : cats;
      return `
        <div class="modal-sheet explorer">
          <h2 class="modal-title">${esc(title)}</h2>
          <div class="chip-row" data-scroll="x" data-margin="20">
            ${REGION_GROUPS.map(x => `<div class="chip focusable ${x.id === group ? 'on' : ''}" data-fk="eg-${x.id}" ${act(() => { group = x.id; redraw(); })}>${esc(x.label)}</div>`).join('')}
          </div>
          <div class="modal-list" data-scroll="y" data-margin="30" data-trap="1">
            ${specials.map(([id, name, count]) => row(id, name, count, '')).join('')}
            ${list.map(c => row(c.categoryId, c.cleanName, c.count, c.prefixBadge)).join('') || '<div class="empty-note small">No categories in this group.</div>'}
          </div>
        </div>`;
    };
    const redraw = () => {
      mount(wrap, build());
      Focus.set(wrap.querySelector(`[data-fk="eg-${group}"]`));
    };
    wrap = Modal.open(build(), { focus: selectedId ? `[data-fk="ci-${CSS.escape(selectedId)}"]` : null });
  }

  // ------------------------------------------------------------------ Live TV (category chips + channel grid)

  const CH_PAGE = 40;

  const Live = {
    catId: null,
    channels: [],
    shown: 0,

    cats() {
      const counts = {};
      S.cat.live.forEach(ch => { counts[ch.categoryId] = (counts[ch.categoryId] || 0) + 1; });
      return S.cat.liveCats.filter(c => counts[c.categoryId]).map(c => Object.assign({ count: counts[c.categoryId] }, c));
    },

    channelsFor(catId) {
      if (catId === '__fav') return favoriteEntries(['live']).map(e => e.data);
      return S.cat.live.filter(ch => ch.categoryId === catId);
    },

    title() {
      return this.catId === '__fav' ? 'Favorite Channels' : (S.cat.catName.live[this.catId] || 'Live TV');
    },

    render(args = {}) {
      if (args.catId) this.catId = args.catId;
      const root = $('#live-screen');
      if (!S.cat.loaded) { mount(root, loadingView('Loading channels…')); return; }
      const cats = this.cats();
      if (!this.catId || (this.catId !== '__fav' && !cats.find(c => c.categoryId === this.catId))) {
        this.catId = cats.length ? cats[0].categoryId : '__fav';
      }
      const chip = (id, label) => `<div class="chip focusable ${id === this.catId ? 'on' : ''}" data-fk="lc-${esc(id)}" data-cat="${esc(id)}" ${act(() => this.selectCat(id))}>${esc(label)}</div>`;
      const chips = `<div class="chip icon focusable" data-fk="lc-all" ${act(() => this.openExplorer())}>${ICON.format}<span>All ${cats.length}</span></div>`
        + chip('__fav', '★ Favorites')
        + cats.slice(0, 40).map(c => chip(c.categoryId, c.cleanName)).join('');
      mount(root, `
        <div class="live-page">
          <div class="live-head">
            <div>
              <div class="grid-kicker">Live TV</div>
              <h2 id="live-title"></h2>
            </div>
            <div class="live-hint">Press <b>☰</b> on a channel for the TV Guide & Favorites</div>
          </div>
          <div class="chip-row" data-scroll="x" data-margin="60" data-group="live-chips">${chips}</div>
          <div class="channel-scroll" id="channel-pane" data-scroll="y" data-margin="40" data-group="chans"></div>
        </div>`);
      this.renderChannels();
    },

    // Channels render in pages as focus approaches the end of what's on screen: drawing a whole
    // 1,000-channel category at once froze the UI for ~0.7 s and made every key press cost 40-60 ms.
    renderChannels(upTo = 0) {
      const pane = $('#channel-pane');
      if (!pane) return;
      const list = this.channelsFor(this.catId);
      this.channels = list;
      this.shown = 0;
      $('#live-title').innerHTML = `${esc(this.title())} <small>${list.length} channel${list.length === 1 ? '' : 's'}</small>`;
      $$('#live-screen .chip[data-cat]').forEach(el => el.classList.toggle('on', el.getAttribute('data-cat') === this.catId));
      mount(pane, list.length
        ? '<div class="channel-grid" data-grid></div>'
        : emptyState(ICON.star, this.catId === '__fav' ? 'No favorite channels yet' : 'No channels here',
          this.catId === '__fav' ? 'Press ☰ on any channel and choose “Add to Favorites”.' : 'Pick another category above.'));
      this.appendChannels(Math.max(CH_PAGE, upTo + 1));
      pane.scrollTop = 0;
      fillEPGLines(pane, list.slice(0, 15).map(c => c.streamId));
    },

    appendChannels(count = CH_PAGE) {
      const grid = $('#channel-pane .channel-grid');
      if (!grid || this.shown >= this.channels.length) return;
      const start = this.shown;
      const end = Math.min(this.channels.length, start + count);
      const html = this.channels.slice(start, end).map((ch, j) => `
        <div class="ch-tile focusable" data-fk="ch-${ch.streamId}" data-idx="${start + j}"
          ${act(() => playLive(ch, this.channels))} ${onF(() => this.focusChannel(ch, start + j))}>
          <div class="ch-art">${artwork(ch.streamIcon, ch.cleanName, { fit: true })}
            ${isFav('live', ch) ? `<span class="ch-fav">${ICON.starFill}</span>` : ''}
            ${(ch.qualityBadges || [])[0] ? `<span class="ch-q">${esc(ch.qualityBadges[0])}</span>` : ''}
          </div>
          <div class="ch-name">${esc(ch.cleanName)}</div>
          <div class="ch-now" data-epg-for="${ch.streamId}">${esc(S.cat.catName.live[ch.categoryId] || 'Live')}</div>
        </div>`).join('');
      const tmp = document.createElement('div');
      tmp.innerHTML = html;
      bindActs(tmp);
      while (tmp.firstElementChild) grid.appendChild(tmp.firstElementChild);
      this.shown = end;
    },

    selectCat(id) { this.catId = id; this.renderChannels(); },

    openExplorer() {
      categoryExplorer({
        title: 'Live TV Categories',
        cats: this.cats(),
        selectedId: this.catId,
        specials: [['__fav', '★ Favorite Channels', favoriteEntries(['live']).length]],
        onSelect: id => {
          this.selectCat(id);
          Focus.set($(`#live-screen .chip[data-cat="${CSS.escape(id)}"]`) || $('#live-screen [data-fk="lc-all"]'));
        }
      });
    },

    focusChannel(ch, i) {
      if (i >= this.shown - 10) this.appendChannels();
      this.loadEPGFor(ch);
    },

    loadEPGFor: debounce(function (ch) { fillEPGLines($('#live-screen'), [ch.streamId]); }, 220),

    defaultFocus() {
      const root = $('#live-screen');
      return root.querySelector('.ch-tile') || root.querySelector('.chip.on') || Focus.first(root);
    },

    onMenu() {
      const el = Focus.cur;
      if (el && el.classList.contains('ch-tile')) {
        const ch = this.channels[Number(el.getAttribute('data-idx'))];
        const idx = Number(el.getAttribute('data-idx'));
        if (ch) openEPGDrawer(ch, this.channels, () => { if (S.screen === 'live') refocusAfter($('#channel-pane'), () => this.renderChannels(idx)); });
        return true;
      }
      return false;
    }
  };
  Screens.live = Live;

  async function openEPGDrawer(ch, list, onClose) {
    const wrap = Modal.open(`
      <div class="modal-sheet epg-sheet">
        <div class="epg-head">
          <div class="epg-logo">${artwork(ch.streamIcon, ch.cleanName, { fit: true })}</div>
          <div><h2 class="modal-title">${esc(ch.cleanName)}</h2><p class="modal-sub">${esc(S.cat.catName.live[ch.categoryId] || 'Live TV')} • TV Guide</p></div>
        </div>
        <div class="modal-actions">
          <div class="tv-btn focusable" ${act(() => { Modal.closeAll(); playLive(ch, list); })}>${ICON.play}<span>Watch Live</span></div>
          <div class="tv-btn focusable" ${act(el => { const on = toggleFav('live', ch); el.innerHTML = `${on ? ICON.starFill : ICON.star}<span>${on ? 'Favorited' : 'Add to Favorites'}</span>`; })}>${isFav('live', ch) ? ICON.starFill + '<span>Favorited</span>' : ICON.star + '<span>Add to Favorites</span>'}</div>
        </div>
        <div class="modal-list epg-list" data-scroll="y" data-margin="30" data-trap="1"><div class="center-status"><div class="spinner"></div> Loading schedule…</div></div>
      </div>`, { onClose });
    const programmes = await getEPG(ch.streamId);
    const box = wrap.querySelector('.epg-list');
    if (!box || !wrap.isConnected) return;
    mount(box, programmes.length ? programmes.map((e, i) => `
      <div class="epg-row focusable ${e.isNowPlaying ? 'now' : ''}" data-fk="epg-${i}">
        <div class="epg-time">${esc(e.formattedTimeRange)}${e.isNowPlaying ? '<span class="live-badge">NOW</span>' : ''}</div>
        <div class="epg-body"><div class="epg-title">${esc(e.title)}</div>
        ${e.description ? `<div class="epg-desc">${esc(e.description)}</div>` : ''}
        ${e.isNowPlaying ? `<div class="mini-progress"><div style="width:${Math.round(e.progress * 100)}%"></div></div>` : ''}</div>
      </div>`).join('') : '<div class="empty-note small">No programme guide available for this channel.</div>');
  }

  // ------------------------------------------------------------------ Detail (full-bleed hero + Episodes + More Like This)

  const Detail = {
    args: null,
    token: 0,
    info: null,
    sInfo: null,
    season: null,

    render(args) {
      this.args = args;
      this.token++;
      this.info = null;
      this.sInfo = null;
      this.season = null;
      this.draw();
      logTaste(args.kind, args.data, 'detailView', 1.0);
      this.fetch(this.token);
    },

    async fetch(tk) {
      const { kind, data } = this.args;
      if (kind === 'movie') {
        const info = await XtreamAPI.fetchVODInfo(S.creds, data.streamId);
        if (tk !== this.token) return;
        this.info = info;
      } else {
        const sInfo = await XtreamAPI.fetchSeriesInfo(S.creds, data.seriesId);
        if (tk !== this.token) return;
        this.sInfo = sInfo;
        const h = historyEntry(`series-${data.seriesId}`);
        const seasons = sInfo.sortedSeasonNumbers;
        this.season = (h && seasons.includes(Number(h.season))) ? Number(h.season) : (seasons[0] ?? null);
      }
      if (S.screen === 'detail' && tk === this.token) refocusAfter($('#detail-screen'), () => this.draw());
    },

    meta() {
      const { kind, data: d } = this.args;
      if (kind === 'movie') {
        const info = (this.info && this.info.info) || {};
        const md = (this.info && this.info.movie_data) || {};
        return {
          plot: info.plot || info.description || '',
          genre: info.genre || '',
          year: String(info.releasedate || info.release_date || '').slice(0, 4),
          duration: info.duration || '',
          cast: info.cast || info.actors || '',
          director: info.director || '',
          rating: d.rating || (info.rating ? String(info.rating) : ''),
          ext: md.container_extension || d.containerExtension || 'mp4'
        };
      }
      const info = (this.sInfo && this.sInfo.info) || {};
      return {
        plot: info.plot || d.plot || '',
        genre: info.genre || d.genre || '',
        year: String(info.releaseDate || info.release_date || d.releaseDate || '').slice(0, 4),
        cast: info.cast || d.cast || '',
        director: info.director || d.director || '',
        rating: d.rating || ''
      };
    },

    draw() {
      const { kind, data: d } = this.args;
      const isMovie = kind === 'movie';
      const m = this.meta();
      const inList = isFav(kind, d);
      const btn = (fk, icon, label, fn) =>
        `<div class="tv-btn focusable" data-fk="${fk}" ${act(fn)} ${onF(el => Rows.top(el))}>${icon}<span>${esc(label)}</span></div>`;
      const buttons = [];
      let resumeBar = '';
      let vlcUrl = '';

      if (isMovie) {
        const h = historyEntry(`movie-${d.streamId}`);
        const resume = resumeFor(h);
        vlcUrl = XtreamCredentials.vodStreamURL(S.creds, d.streamId, m.ext);
        buttons.push(btn('play', ICON.play, resume ? 'Resume' : 'Play', () => playMovie(d, resume, m.ext)));
        if (resume) buttons.push(btn('restart', ICON.restart, 'Start Over', () => playMovie(d, 0, m.ext)));
        if (resume && h.duration) {
          resumeBar = `<div class="dt-resume"><div class="bar"><i style="width:${(resume / h.duration * 100).toFixed(1)}%"></i></div><span>${fmtTime(h.duration - resume)} left</span></div>`;
        }
      } else {
        const target = this.sInfo ? seriesResumeTarget(d, this.sInfo) : null;
        buttons.push(btn('play', ICON.play, target ? target.label : 'Play',
          () => target ? playEpisode(d, this.sInfo, target.ep, target.resume) : toast('Loading episodes…')));
        if (target) vlcUrl = XtreamCredentials.seriesEpisodeURL(S.creds, target.ep.episodeId, target.ep.containerExtension);
      }
      buttons.push(btn('list', inList ? ICON.check : ICON.plus, 'My List', el => {
        const on = toggleFav(kind, d);
        el.innerHTML = `${on ? ICON.check : ICON.plus}<span>My List</span>`;
      }));
      if (vlcUrl) buttons.push(btn('vlc', ICON.vlc, 'Open in VLC', () => openInVlc(vlcUrl, d.cleanName)));

      const rating = parseFloat(m.rating) || 0;
      const match = rating ? Math.min(99, Math.round(62 + rating * 3.7)) : 98;
      const seasons = this.sInfo ? this.sInfo.sortedSeasonNumbers : [];
      const metaBits = [
        m.year,
        isMovie ? m.duration : (seasons.length ? `${seasons.length} Season${seasons.length === 1 ? '' : 's'}` : ''),
        (d.qualityBadges || [])[0] || 'HD',
        isMovie && m.ext ? String(m.ext).toUpperCase() : '',
        m.rating ? `★ ${m.rating}` : ''
      ].filter(Boolean).map(x => `<span>${esc(x)}</span>`).join('<span class="sep">•</span>');
      const credits = [
        m.genre ? `<div><span>Genres</span>${esc(m.genre)}</div>` : '',
        m.cast ? `<div><span>Cast</span>${esc(m.cast)}</div>` : '',
        m.director ? `<div><span>Director</span>${esc(m.director)}</div>` : ''
      ].join('');

      const rows = [];
      if (!isMovie) rows.push(this.episodesHTML());
      const pool = isMovie ? S.cat.movies : S.cat.series;
      const more = pool.filter(x => x.categoryId === d.categoryId && (isMovie ? x.streamId !== d.streamId : x.seriesId !== d.seriesId))
        .slice(0, 20).map(x => ({ kind, data: x }));
      if (more.length) rows.push(posterRow('more', 'More Like This', more));

      mount($('#detail-screen'), `
        <div class="rows-page">
          <div class="rows-content">
            <section class="billboard detail" data-billboard>
              <div class="bb-art">${imgTag(entryArt({ kind, data: d }), '', 1280)}</div>
              <div class="bb-fade"></div>
              <div class="bb-info">
                <div class="n-tag">${nLogo('xs')}<span>${isMovie ? 'FILM' : 'SERIES'}</span></div>
                <h1 class="bb-title">${esc(d.cleanName)}</h1>
                <div class="bb-meta"><span class="match">${match}% Match</span><span class="sep">•</span>${metaBits}</div>
                ${resumeBar}
                <p class="bb-synopsis long">${esc(m.plot || ((this.info || this.sInfo) ? 'No synopsis available.' : 'Loading…'))}</p>
                ${credits ? `<div class="dt-credits">${credits}</div>` : ''}
                <div class="bb-buttons">${buttons.join('')}</div>
              </div>
            </section>
            ${rows.join('')}
          </div>
        </div>`);
    },

    episodesHTML() {
      const d = this.args.data;
      if (!this.sInfo) return '<section class="row-loading"><h3 class="row-title">Episodes</h3><div class="center-status"><div class="spinner"></div> Loading episodes…</div></section>';
      const seasons = this.sInfo.sortedSeasonNumbers;
      if (!seasons.length) return '<section class="row-loading"><h3 class="row-title">Episodes</h3><div class="empty-note small">No episodes available yet.</div></section>';
      const eps = this.sInfo.episodesBySeason[this.season] || [];
      const header = `
        <div class="row-title-bar">
          <h3 class="row-title">Episodes</h3>
          ${seasons.length > 1 ? `<div class="season-chips">${seasons.map(sn => `
            <div class="chip small focusable ${sn === this.season ? 'on' : ''}" data-fk="season-${sn}" ${act(() => this.setSeason(sn))}>Season ${sn}</div>`).join('')}</div>`
            : `<span class="row-sub">Season ${this.season}</span>`}
        </div>`;
      return Rows.html({ id: 'episodes', header, style: 'landscape', items: eps.map(ep => episodeItem(d, this.sInfo, ep)) })
        || `<section class="row-loading">${header}<div class="empty-note small">No episodes in this season.</div></section>`;
    },

    setSeason(sn) {
      this.season = sn;
      this.draw();
      Focus.set($(`#detail-screen [data-fk="season-${sn}"]`));
    },

    onShow(args, rendered) {
      // Returning from the player: refresh resume labels / progress bars.
      if (!rendered && this.args) refocusAfter($('#detail-screen'), () => this.draw());
    },

    defaultFocus() { return $('#detail-screen [data-fk="play"]') || Focus.first($('#detail-screen')); },

    onMenu() {
      if (!this.args) return false;
      toggleFav(this.args.kind, this.args.data);
      refocusAfter($('#detail-screen'), () => this.draw());
      return true;
    }
  };
  Screens.detail = Detail;

  // ------------------------------------------------------------------ Search (D-pad keyboard + results)

  const Search = {
    query: '',

    render() {
      const keys = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890'.split('');
      const keyHTML = keys.map(k => `<div class="kb-key focusable" data-fk="k-${k}" ${act(() => this.type(k))}>${k}</div>`).join('')
        + `<div class="kb-key wide3 focusable" data-fk="k-space" ${act(() => this.type(' '))}>Space</div>`
        + `<div class="kb-key wide3 focusable" data-fk="k-del" ${act(() => this.del())}>Delete</div>`;
      mount($('#search-screen'), `
        <div class="search-page">
          <div class="kb-pane" data-group="kb">
            <div class="search-box" id="search-query">${this.queryHTML()}</div>
            <div class="kb-grid">${keyHTML}</div>
            <div class="tv-btn small wide focusable" data-fk="k-clear" ${act(() => this.setQuery(''))}>Clear</div>
            <div class="tv-btn small wide focusable" data-fk="k-voice" ${act(() => this.nativeKeyboard())}>${ICON.keyboard}<span>Fire TV Keyboard / Voice</span></div>
            ${S.helperUrl ? `<p class="helper-text">Or type on your phone at <b>${esc(S.helperUrl)}</b></p>` : ''}
          </div>
          <div id="search-results" class="search-results" data-scroll="y" data-margin="50" data-group="results"></div>
        </div>`);
      this.renderResults();
    },

    queryHTML() {
      return this.query ? `${esc(this.query)}<span class="caret"></span>` : `<span class="placeholder">Search</span><span class="caret"></span>`;
    },

    type(ch) { if (this.query.length < 60) { this.query += ch; this.changed(); } },
    del() { this.query = this.query.slice(0, -1); this.changed(); },
    setQuery(q) { this.query = String(q || '').slice(0, 60); this.changed(); },

    changed() {
      const box = $('#search-query');
      if (box) box.innerHTML = this.queryHTML();
      this.renderResultsSoon();
    },

    renderResultsSoon: debounce(() => Search.renderResults(), 140),

    nativeKeyboard() {
      if (Native) Native.promptInput('Search NucFlix', this.query, 'search');
      else {
        const v = window.prompt('Search NucFlix', this.query);
        if (v != null) this.setQuery(v);
      }
    },

    renderResults() {
      const box = $('#search-results');
      if (!box) return;
      const hadFocus = Focus.cur && box.contains(Focus.cur);
      const q = this.query.trim();
      let live = [], vod = [], heading;
      if (!q) {
        if (!Home.feed && S.cat.loaded) Home.buildFeed();
        const top = Home.feed ? (Home.feed.rails.find(r => r.id === 'top-picks') || { items: [] }).items : [];
        vod = top.slice(0, 15).map(x => ({ kind: x.kind, data: x.data }));
        heading = 'Recommended TV Shows & Movies';
      } else {
        const res = S.cat.index.search(q, 160, S.prefs.showAdult);
        live = res.filter(r => r.kind === 'live').slice(0, 12).map(r => r.data);
        vod = res.filter(r => r.kind !== 'live').slice(0, 60).map(r => ({ kind: r.kind, data: r.data }));
        heading = (live.length + vod.length) ? 'Top Results' : `No results for “${q}”`;
      }
      // Requests like "funny hindi movies from the 2010s" also get AI-built filters (Gemma 4), shown first.
      const smart = q && this.smart && this.smart.q === q ? this.smart : null;
      if (q && !smart) this.loadSmart(q);
      const smartHTML = smart && smart.items.length ? `
        <div class="results-heading smart">${ICON.check} ${esc(smart.label)}</div>
        <div class="res-grid">${smart.items.map(e => e.kind === 'live' ? `
          <div class="g-item focusable" data-fk="${entryFk('ai', e)}" ${act(() => playLive(e.data, S.cat.live))}>
            ${artwork(e.data.streamIcon, e.data.cleanName, { fit: true, lazy: true })}
          </div>` : `
          <div class="g-item focusable" data-fk="${entryFk('ai', e)}" ${act(() => openDetail(e.kind, e.data))}>
            ${artwork(entryArt(e), e.data.cleanName, { lazy: true })}<div class="ri-n">${nLogo('xs')}</div>
          </div>`).join('')}</div>` : '';
      if (smart && smart.items.length && !(live.length + vod.length)) heading = 'Other results';
      mount(box, `
        ${smartHTML}
        ${smartHTML && !(live.length + vod.length) ? '' : `<div class="results-heading">${esc(heading)}</div>`}
        ${live.length ? `<div class="results-sub">Live Channels</div><div class="res-live">${live.map(ch => `
          <div class="ch-tile focusable" data-fk="sl-${ch.streamId}" ${act(() => playLive(ch, live))}>
            <div class="ch-art">${artwork(ch.streamIcon, ch.cleanName, { fit: true, lazy: true })}</div>
            <div class="ch-name">${esc(ch.cleanName)}</div>
          </div>`).join('')}</div>` : ''}
        ${vod.length ? `${live.length ? '<div class="results-sub">Movies & Shows</div>' : ''}<div class="res-grid">${vod.map(e => `
          <div class="g-item focusable" data-fk="${entryFk('s', e)}" ${act(() => openDetail(e.kind, e.data))}>
            ${artwork(entryArt(e), e.data.cleanName, { lazy: true })}<div class="ri-n">${nLogo('xs')}</div>
          </div>`).join('')}</div>` : ''}
        ${q && !live.length && !vod.length ? '<p class="helper-text">Try another title, channel, or fewer letters.</p>' : ''}`);
      box.scrollTop = 0;
      if (hadFocus) Focus.set(Focus.first(box) || $('#search-screen [data-fk="k-A"]'));
    },

    loadSmart(q) {
      clearTimeout(this.smartTimer);
      this.smartTimer = setTimeout(async () => {
        const f = await Smart.searchFilters(q);
        if (!f || this.query.trim() !== q || S.screen !== 'search') return;
        const items = Smart.applyFilters(f, S.cat);
        this.smart = { q, label: Smart.describe(f), items };
        if (items.length) this.renderResults();
      }, 900);
    },

    defaultFocus() { return $('#search-screen [data-fk="k-A"]'); }
  };
  Screens.search = Search;

  // ------------------------------------------------------------------ Account & Settings (from the profile avatar)

  const Account = {
    render() {
      const ui = S.account || {};
      const c = S.creds || {};
      let expiry = 'Unlimited';
      if (ui.exp_date && Number(ui.exp_date) > 0) {
        const dt = new Date(Number(ui.exp_date) * 1000);
        const days = Math.ceil((dt - Date.now()) / 86400000);
        expiry = `${dt.toLocaleDateString([], { year: 'numeric', month: 'short', day: 'numeric' })} • ${days >= 0 ? days + ' days left' : 'expired'}`;
      }
      const info = [
        ['Server', c.serverURL || '—'],
        ['Username', c.username || '—'],
        ['Status', ui.status || '—'],
        ['Expires', expiry],
        ['Connections', `${ui.active_cons ?? 0} of ${ui.max_connections ?? '—'}`],
        ['Library', `${S.cat.live.length} channels • ${S.cat.movies.length} movies • ${S.cat.series.length} shows`]
      ].map(([k, v]) => `<div class="info-row"><span>${esc(k)}</span><b>${esc(v)}</b></div>`).join('');
      const fmtNames = { m3u8: 'HLS (.m3u8)', ts: 'MPEG-TS (.ts)', m3u8_root: 'HLS Root' };
      const setting = (fk, label, value, desc, fn) => `
        <div class="setting-row focusable" data-fk="${fk}" ${act(fn)}>
          <div><div class="setting-label">${esc(label)}</div><div class="setting-desc">${esc(desc)}</div></div>
          ${value ? `<span class="setting-value">${esc(value)}</span>` : ''}
        </div>`;
      mount($('#account-screen'), `
        <div class="account-page" data-scroll="y" data-margin="60">
          <div class="account-grid">
            <div class="account-card">
              <div class="avatar big">${esc(initial(c.lineName))}</div>
              <h2>${esc(c.lineName || 'NucFlix')}</h2>
              <div class="info-list">${info}</div>
              ${S.helperUrl ? `<div class="helper-box inset">
                <h3>Phone Helper</h3>
                <p class="helper-text">Search NucFlix or type on the TV from your phone:</p>
                <div class="helper-url">${esc(S.helperUrl)}</div>
              </div>` : ''}
            </div>
            <div class="settings-col" data-group="settings">
              <div class="settings-title">Playback</div>
              ${setting('set-format', 'Live Stream Format', fmtNames[S.prefs.liveFormat] || S.prefs.liveFormat, 'Switch if channels buffer or fail to start', () => this.cycle('liveFormat', ['m3u8', 'ts', 'm3u8_root']))}
              ${setting('set-autoplay', 'Autoplay Next Episode', S.prefs.autoplayNext ? 'On' : 'Off', 'Countdown to the next episode when one ends', () => this.toggle('autoplayNext'))}
              ${isKids() ? '' : setting('set-adult', 'Show Adult Content', S.prefs.showAdult ? 'On' : 'Off', 'Hides adult categories when off', () => { this.toggle('showAdult'); applyCatalogFilter(); })}
              <div class="settings-title">Library</div>
              ${setting('set-refresh', 'Refresh Catalog', '', 'Reload channels, movies & shows from your provider', () => this.refresh())}
              ${setting('set-history', 'Clear Watch History', `${S.history.length} items`, 'Clears this profile’s Continue Watching on every device', () => confirmModal({ title: 'Clear watch history?', okLabel: 'Clear', danger: true, onOk: () => { clearCloudHistory(); markDirty(); this.rerender(); toast('Watch history cleared'); } }))}
              <div class="settings-title">NucFlix Account</div>
              ${setting('set-profile', 'Profile', S.cloud.profile ? S.cloud.profile.name : '—', 'Who’s watching? Profiles are managed in the NucFlix iPhone app', () => (Cloud.paired ? Who.show() : unpairTV()))}
              ${setting('set-line', 'IPTV Line', S.cloud.line ? S.cloud.line.name : '—', `${S.cloud.lines.length} line${S.cloud.lines.length === 1 ? '' : 's'} in your account`, () => chooseLine())}
              ${Cloud.paired ? setting('set-unpair', 'Unpair This TV', Cloud.ownerName || '', 'Disconnect from your NucFlix account', () => confirmModal({ title: 'Unpair this TV?', message: 'It will need a new code from your iPhone to watch again.', okLabel: 'Unpair', danger: true, onOk: () => unpairTV() })) : setting('set-pair', 'Pair This TV', '', 'Connect to your NucFlix account', () => unpairTV())}
              ${setting('set-exit', 'Exit NucFlix', '', 'Close the app', () => Native ? Native.exitApp() : toast('Exit'))}
            </div>
          </div>
        </div>`);
    },
    rerender() { refocusAfter($('#account-screen'), () => this.render()); },
    cycle(key, values) {
      S.prefs[key] = values[(values.indexOf(S.prefs[key]) + 1) % values.length];
      savePrefs();
      this.rerender();
    },
    toggle(key) {
      S.prefs[key] = !S.prefs[key];
      savePrefs();
      if (key === 'autoplayNext') Cloud.savePrefs({ autoplayNext: S.prefs.autoplayNext });
      this.rerender();
    },
    async refresh() {
      toast('Refreshing catalog…', 4000);
      try {
        S.epgCache.clear();
        await loadCatalog();
        toast(`Catalog refreshed • ${S.cat.live.length} channels, ${S.cat.movies.length} movies, ${S.cat.series.length} shows`);
      } catch (e) { toast('Refresh failed: ' + e.message); }
      if (S.screen === 'account') this.rerender();
    },
    defaultFocus() { return $('#account-screen [data-fk="set-format"]'); }
  };
  Screens.account = Account;

  function initial(name) {
    return (String(name || 'N').trim()[0] || 'N').toUpperCase();
  }

  // ------------------------------------------------------------------ Video API (native SurfaceView or HTML5 fallback)

  const FallbackVideo = (() => {
    const v = $('#fallback-video');
    let lastEvt = 'loading';
    const emit = event => {
      lastEvt = event;
      App.onNativeVideoState({
        event, playing: !v.paused, buffering: event === 'loading' || event === 'buffering',
        position: v.currentTime || 0, duration: isFinite(v.duration) ? v.duration : 0,
        audioTracks: [], subtitleTracks: [], selectedAudioTrack: -1, selectedSubtitleTrack: -1,
        speed: v.playbackRate, aspectMode: 'fit', error: event === 'error' ? 'This stream can’t play in a desktop browser preview.' : undefined
      });
    };
    if (v) {
      v.addEventListener('playing', () => emit('playing'));
      v.addEventListener('pause', () => emit('paused'));
      v.addEventListener('waiting', () => emit('buffering'));
      v.addEventListener('timeupdate', () => emit('tick'));
      v.addEventListener('ended', () => emit('ended'));
      v.addEventListener('error', () => emit('error'));
    }
    return {
      start(url, id, resume) {
        if (!v) return;
        v.hidden = false;
        v.src = url;
        v.currentTime = resume || 0;
        v.play().catch(() => emit('error'));
        emit('loading');
      },
      stop() { if (v) { v.pause(); v.removeAttribute('src'); v.load(); v.hidden = true; } },
      togglePause() { if (v) (v.paused ? v.play() : v.pause()); },
      seekTo(s) { if (v) v.currentTime = s; },
      setSpeed(s) { if (v) v.playbackRate = s; },
      setAspect() { },
      selectTrack() { },
      beginScrub() { if (v) v.pause(); },
      requestThumb() { },
      endScrub(s) { if (v) { v.currentTime = s; v.play().catch(() => { }); } }
    };
  })();

  const VideoAPI = Native ? {
    start: (u, id, r) => Native.startVideo(u, String(id || ''), Number(r) || 0),
    stop: () => Native.stopVideo(),
    togglePause: () => Native.togglePause(),
    seekTo: s => Native.seekTo(Number(s) || 0),
    setSpeed: s => Native.setSpeed(Number(s) || 1),
    setAspect: m => Native.setAspectMode(m),
    selectTrack: (i, a) => Native.selectTrack(i, !!a),
    beginScrub: () => Native.beginScrub(),
    requestThumb: (s, id) => Native.requestThumb(Number(s) || 0, id | 0),
    endScrub: s => Native.endScrub(Number(s) || 0)
  } : FallbackVideo;

  // ------------------------------------------------------------------ Full-Screen Player + Netflix OSD

  // ------------------------------------------------------------------ Smart playback (Ollama Cloud via Smart)
  // Credits: frames near the end tell us when the end credits really start, so the next-episode countdown
  // and "watched" follow the picture, not a fixed time. Intro: frames in the first minutes find the opening
  // titles for Skip Intro. Both are saved as markers, so a title is only analysed once per household.
  // Live: two frames ~3 s apart catch channels that are black, frozen or off air.

  // Finding intros frame by frame doesn't work on real shows (an opening montage reads as "a scene"), so the
  // scan is off; saved intro markers still show Skip Intro. Planned instead: matching the opening across
  // episodes of a series, the way streaming services do.
  const INTRO_SCAN = false;
  const INTRO_SCAN_UNTIL = 420; // opening titles usually come within the first 7 minutes

  const PlayerAI = {
    item: null,
    ref: null,
    marker: null,
    busy: false,
    nextCheckAt: 0,
    scene: null,      // a normal scene from this title (JPEG base64): sent along so the AI can compare
    lastPos: null,    // for spotting seeks: { pos, at }
    pass: 0,          // bumped on every seek: answers to checks started before it are dropped
    creditsHit: null,
    creditsDone: false,
    intro: null,
    liveDone: false,
    playingSince: 0,
    skipShown: false,
    skipTo: 0,

    start(item) {
      this.stop();
      this.item = item;
      this.intro = { start: null, last: null, first: null, candidate: null, done: false };
      if (item.kind === 'live') return;
      this.ref = item.kind === 'movie' ? { kind: 'movie', id: item.streamId } : { kind: 'episode', id: item.episode.episodeId };
      Cloud.getMarker(this.ref.kind, this.ref.id).then(m => { if (this.item === item) this.marker = m || {}; });
    },

    stop() {
      this.item = null;
      this.marker = null;
      this.busy = false;
      this.nextCheckAt = 0;
      this.scene = null;
      this.lastPos = null;
      this.creditsHit = null;
      this.creditsDone = false;
      this.liveDone = false;
      this.playingSince = 0;
      this.hideSkip();
      this.hideBanner();
    },

    /** Past the detected start of the credits (progress then saves as finished). */
    pastCredits(st) {
      return !!(this.marker && typeof this.marker.creditsAt === 'number' && this.marker.creditsAt > 0 && st.position >= this.marker.creditsAt);
    },

    tick(st) {
      const it = this.item;
      if (!it) return;
      if (it.kind === 'live') { this.liveTick(st); return; }
      const m = this.marker;
      if (!m || !st.duration) return;
      const pos = st.position || 0;
      const dur = st.duration;
      this.watchForSeeks(pos, st.playing);
      if (!this.creditsDone) {
        if (typeof m.creditsAt === 'number' && m.creditsAt > 0) {
          if (pos >= m.creditsAt && pos < dur - 2) this.creditsReached(st);
        } else if (dur > 300 && pos >= Math.max(dur * 0.8, dur - 600) && st.playing) {
          this.check('credits', pos, st);
        }
      }
      if (it.kind === 'episode') {
        if (typeof m.introEnd === 'number') {
          const from = m.introStart || 0;
          if (m.introEnd > from + 5 && pos >= from - 1 && pos < m.introEnd - 3) this.showSkip(m.introEnd);
          else this.hideSkip();
        } else if (INTRO_SCAN && !this.intro.done && pos < INTRO_SCAN_UNTIL && st.playing) {
          this.check('intro', pos, st);
        }
      }
    },

    /** A jump (scrubbing, Skip, resume) breaks the run of frames the evidence was built on: start over. */
    watchForSeeks(pos, playing) {
      // Compared even while buffering (a seek pauses playback for a moment). Standing still is a stall, not a
      // jump; only moving backwards, or forwards faster than the clock, is.
      const prev = this.lastPos;
      this.lastPos = { pos, at: Date.now(), playing };
      if (!prev) return;
      const ran = prev.playing ? (Date.now() - prev.at) / 1000 * (Player.speed || 1) : 0;
      if (pos > prev.pos - 3 && pos < prev.pos + ran + 8) return;
      // Every jump starts a fresh pass over the opening minutes (also after one that ended without a result);
      // "no intro" is only concluded by a pass that ran unbroken from the first minute.
      const m = this.marker;
      this.pass++;
      if (!(m && typeof m.introEnd === 'number')) {
        Object.assign(this.intro, { start: null, last: null, first: null, candidate: null, done: false });
      }
      this.creditsHit = null;
      this.nextCheckAt = Date.now() + 2000; // look again once the picture has settled
    },

    async check(task, pos, st) {
      if (this.busy || Date.now() < this.nextCheckAt || Smart.disabled) return;
      const it = this.item;
      const pass = this.pass;
      this.busy = true;
      this.nextCheckAt = Date.now() + 10000;
      try {
        const f = await Smart.frame();
        if (!f || this.item !== it) return;
        // Next to a normal scene from this episode an opening montage stands out clearly (on real episodes:
        // 0.2–0.5 "intro" alone, 0.86–0.95 compared). Credits are clear on their own.
        const images = task === 'intro' && this.scene ? [f.b64, this.scene] : [f.b64];
        const r = await Smart.frameCheck(task, images, it.title);
        if (!r || this.item !== it || this.pass !== pass) return; // the picture moved on meanwhile
        if (!this.scene && !f.black && (r.probabilities || {}).programme >= 0.7) this.scene = f.b64;
        if (task === 'credits') this.creditsFrame(r, pos, st);
        else this.introFrame(r, pos, st);
      } finally {
        this.busy = false;
      }
    },

    creditsFrame(r, pos, st) {
      const p = r.probabilities || {};
      const credits = (p.end_credits || 0) + (p.next_preview || 0);
      if (credits < 0.7) { this.creditsHit = null; return; }
      if (this.creditsHit == null) {
        this.creditsHit = pos;
        if (credits < 0.92) { this.nextCheckAt = Date.now() + 3000; return; } // confirm with a second look
      }
      this.marker.creditsAt = this.creditsHit;
      Cloud.saveMarker(this.ref.kind, this.ref.id, { creditsAt: this.creditsHit, duration: st.duration });
      this.creditsReached(st);
    },

    creditsReached(st) {
      this.creditsDone = true;
      Player.saveProgress(); // saves as finished now that we're past the credits
      const it = this.item;
      if (it.kind === 'episode' && S.prefs.autoplayNext && Player.nextEpisode() && Player.nextShownFor !== it.uid) Player.showNextCard();
    },

    introFrame(r, pos, st) {
      const p = r.probabilities || {};
      const intro = this.intro;
      if (intro.first == null) intro.first = pos;
      if ((p.intro || 0) >= 0.7) {
        // Two sightings in a row (3 s apart) before the titles count as started: one odd frame isn't an intro.
        this.nextCheckAt = Date.now() + 3000; // and look often while inside, to find the end to a second or two
        if (intro.start == null) {
          if (intro.candidate == null) { intro.candidate = pos; return; }
          intro.start = Math.max(0, intro.candidate - 4);
        }
        intro.last = pos;
        return;
      }
      intro.candidate = null;
      if (intro.start != null) {
        intro.done = true; // the titles just ended, somewhere between the last two looks
        const end = Math.round((intro.last + pos) / 2 * 10) / 10;
        Object.assign(this.marker, { introStart: intro.start, introEnd: end });
        Cloud.saveMarker(this.ref.kind, this.ref.id, { introStart: intro.start, introEnd: end, duration: st.duration });
      } else if (pos > INTRO_SCAN_UNTIL - 20) {
        intro.done = true;
        // No opening titles in the first minutes: remember that too, but only if all of them were watched.
        if (intro.first >= 60) return;
        Object.assign(this.marker, { introStart: 0, introEnd: 0 });
        Cloud.saveMarker(this.ref.kind, this.ref.id, { introStart: 0, introEnd: 0, duration: st.duration });
      }
    },

    showSkip(to) {
      this.skipTo = to;
      if (this.skipShown) return;
      const slot = $('#p-skip-slot');
      if (!slot) return;
      this.skipShown = true;
      mount(slot, `<div class="tv-btn skip-intro focusable" data-fk="skip-intro" ${act(() => this.skipNow())}>Skip Intro</div>`);
      if (Player.osdOn) Focus.set(slot.querySelector('[data-fk="skip-intro"]'));
    },

    hideSkip() {
      if (!this.skipShown) return;
      this.skipShown = false;
      const slot = $('#p-skip-slot');
      const hadFocus = slot && Focus.cur && slot.contains(Focus.cur);
      if (slot) slot.innerHTML = '';
      if (hadFocus && S.screen === 'player') Focus.set(Player.defaultFocus());
    },

    skipNow() {
      const to = this.skipTo;
      this.hideSkip();
      VideoAPI.seekTo(to);
      Player.st.position = to;
      Player.updateUI();
    },

    liveTick(st) {
      if (this.liveDone) return;
      if (!st.playing) { this.playingSince = 0; return; }
      if (!this.playingSince) { this.playingSince = Date.now(); return; }
      if (Date.now() - this.playingSince < 10000 || this.busy || Smart.disabled) return;
      this.liveDone = true;
      this.busy = true;
      const it = this.item;
      (async () => {
        try {
          const a = await Smart.frame();
          await new Promise(r => setTimeout(r, 3000));
          const b = await Smart.frame();
          if (!a || !b || this.item !== it) return;
          const r = await Smart.frameCheck('live', [a.b64, b.b64], it.title);
          if (!r || this.item !== it) return;
          const p = (r.probabilities || {})[r.label] || 0;
          if (r.label && r.label !== 'ok' && p >= 0.7 && r.confidence >= 0.5) this.offAir(r.label);
        } finally {
          this.busy = false;
        }
      })();
    },

    offAir(label) {
      const it = this.item;
      const slot = $('#p-ai-slot');
      if (!slot || !it.channel) return;
      const alt = Smart.alternatives(it.channel, S.cat.live)[0];
      const msg = { black: 'This channel is showing a black screen.', frozen: 'This channel’s picture looks frozen.', offline: 'This channel looks off air.' }[label] || 'This channel may not be working.';
      mount(slot, `
        <div class="ai-banner" data-group="ai">
          <div class="ai-banner-text">${esc(msg)}</div>
          <div class="modal-actions">
            ${alt ? `<div class="tv-btn focusable" data-fk="ai-alt" ${act(() => { this.hideBanner(); playLive(alt, it.channelList); })}>${ICON.play} Try ${esc(alt.cleanName)}</div>` : ''}
            <div class="tv-btn focusable" data-fk="ai-keep" ${act(() => this.hideBanner())}>Keep Watching</div>
          </div>
        </div>`);
      Player.showOSD(true);
      Focus.set(slot.querySelector('[data-fk="ai-alt"], [data-fk="ai-keep"]'));
    },

    hideBanner() {
      const slot = $('#p-ai-slot');
      if (!slot || !slot.innerHTML) return;
      const hadFocus = Focus.cur && slot.contains(Focus.cur);
      slot.innerHTML = '';
      if (hadFocus && S.screen === 'player') { Focus.set(Player.defaultFocus()); Player.scheduleHide(); }
    }
  };

  const Player = {
    item: null,
    st: {},
    osdOn: true,
    osdTimer: null,
    seekTimer: null,
    seekTarget: null,
    scrub: null, // { pos, origin, last, streak, shownId, thumbTimer } while scrubbing the timeline
    thumbSeq: 0,
    lastSave: 0,
    nextTimer: null,
    nextShownFor: null,
    aspect: 'fit',
    speed: 1,

    play(item) {
      if (this.item) this.saveProgress();
      this.cancelNext(true);
      clearTimeout(this.seekTimer);
      this.seekTarget = null;
      if (this.scrub) clearTimeout(this.scrub.thumbTimer);
      this.scrub = null;
      this.item = item;
      this.st = { event: 'loading', buffering: true, position: item.resume || 0, duration: 0 };
      this.lastSave = Date.now();
      this.speed = 1;
      Modal.closeAll();
      if (S.screen !== 'player') Router.go('player', {}, { noFocus: true });
      else this.render();
      stage.classList.add('video-passthrough');
      VideoAPI.start(item.url, item.uid, item.resume || 0);
      Cloud.setNowPlaying({ kind: item.kind, title: item.title }); // phones pause downloads meanwhile
      PlayerAI.start(item);
      if (this.aspect !== 'fit') VideoAPI.setAspect(this.aspect);
      logTaste(item.kind, item.data || item.series || item.channel || { cleanName: item.title, categoryId: item.categoryId }, 'play', 3.0);
      if (item.kind === 'live') recordProgress(item, 0, 0);
      this.showOSD();
    },

    render() {
      const it = this.item;
      if (!it) return;
      const live = it.kind === 'live';
      const btn = (fk, label, icon, fn, cls = '') =>
        `<div class="tv-btn osd-btn focusable ${cls}" data-fk="${fk}" ${act(fn)}>${icon}${label ? `<span>${esc(label)}</span>` : ''}</div>`;
      const left = [
        btn('p-play', '', ICON.pause, () => (this.st.event === 'error' ? this.retry() : VideoAPI.togglePause()), 'round'),
        live ? '' : btn('p-back', '10', ICON.restart, () => this.seekBy(-10)),
        live ? '' : btn('p-fwd', '10', ICON.fwd, () => this.seekBy(10)),
        live ? '' : btn('p-start', 'From Start', ICON.restart, () => { VideoAPI.seekTo(0); this.st.position = 0; this.updateUI(); }),
        live ? btn('p-chdn', 'Prev', ICON.down, () => this.zap(-1)) : '',
        live ? btn('p-chup', 'Next', ICON.up, () => this.zap(1)) : '',
        it.kind === 'episode' && this.nextEpisode() ? btn('p-next', 'Next Episode', ICON.next, () => this.playNext()) : ''
      ].join('');
      const right = [
        live ? btn('p-format', S.prefs.liveFormat.toUpperCase().replace('_ROOT', ' ROOT'), ICON.format, () => this.cycleFormat()) : '',
        live ? btn('p-epg', 'Guide', ICON.epg, () => openEPGDrawer(it.channel, it.channelList)) : '',
        it.kind === 'episode' ? btn('p-eps', 'Episodes', ICON.epg, () => this.episodePicker()) : '',
        btn('p-tracks', 'Audio & Subtitles', ICON.subs, () => this.trackPicker()),
        live ? '' : btn('p-speed', `${this.speed}x`, ICON.speed, () => this.speedPicker()),
        btn('p-aspect', this.aspect === 'fit' ? 'Fit' : this.aspect === 'fill' ? 'Fill' : '16:9', ICON.aspect, () => this.cycleAspect()),
        btn('p-vlc', 'VLC', ICON.vlc, () => { this.saveProgress(); openInVlc(it.url, it.title); })
      ].join('');
      mount($('#player-screen'), `
        <div class="player-osd" id="player-osd">
          <div class="player-top-bar">
            <div class="player-title-block">
              <div class="n-series-tag">${nLogo('sm')} ${live ? 'LIVE TV' : it.kind === 'episode' ? 'SERIES' : 'FILM'}</div>
              <h2>${esc(it.title)}</h2>
              <p>${esc(it.subtitle || '')}</p>
            </div>
            <div class="player-top-right">
              ${live ? '<span class="live-pulse-badge big">LIVE</span>' : ''}
              <span class="quality-badge" id="p-res"></span>
            </div>
          </div>
          <div class="player-center-status" id="p-status"><div class="spinner"></div><span>Loading stream…</span></div>
          <div class="player-bottom-bar">
            ${live ? `
              <div class="live-epg-strip">
                <div class="channel-logo-box">${imgTag(it.artwork) || ICON.tv}</div>
                <div class="channel-info">
                  <div class="channel-title" id="p-epg-title">${esc(it.title)}</div>
                  <div class="channel-epg" id="p-epg-time">Live broadcast</div>
                  <div class="mini-progress wide"><div id="p-epg-bar"></div></div>
                </div>
              </div>` : `
              <div class="scrub-row">
                <span class="scrub-time left" id="p-pos">0:00</span>
                <div class="scrub-track focusable" data-fk="p-scrub" id="p-track">
                  <div class="scrub-fill" id="p-fill" style="width:0%"><div class="scrub-thumb"></div></div>
                  <div class="scrub-preview" id="p-preview" hidden>
                    <div class="scrub-preview-img"><img id="p-preview-img" alt=""></div>
                    <div class="scrub-preview-time" id="p-preview-time"></div>
                  </div>
                </div>
                <span class="scrub-time" id="p-dur">--:--</span>
              </div>`}
            <div class="player-controls-row">
              <div class="player-btn-group" data-group="osd-left">${left}</div>
              <div class="player-btn-group" data-group="osd-right">${right}</div>
            </div>
          </div>
        </div>
        <div id="p-next-slot"></div>
        <div id="p-skip-slot"></div>
        <div id="p-ai-slot"></div>
        <div class="player-subs" id="p-subs" hidden></div>`);
      if (live && it.channel) {
        getEPG(it.channel.streamId).then(list => {
          const np = nowPlaying(list);
          if (!np || !this.item || this.item.streamId !== it.streamId) return;
          const t = $('#p-epg-title'), tm = $('#p-epg-time'), bar = $('#p-epg-bar');
          if (t) t.textContent = np.title;
          if (tm) tm.textContent = `${np.formattedTimeRange}${np.description ? ' • ' + np.description : ''}`;
          if (bar) bar.style.width = Math.round(np.progress * 100) + '%';
        });
      }
      this.updateUI();
    },

    defaultFocus() { return $('#player-screen [data-fk="p-play"]'); },

    updateUI() {
      const st = this.st || {};
      const status = $('#p-status');
      if (status && this.scrub) {
        status.hidden = true;
      } else if (status) {
        if (st.event === 'error') {
          status.hidden = false;
          status.classList.add('error');
          status.innerHTML = `<div class="err-body"><b>⚠ ${esc(st.error || 'Playback error')}</b>
            <span>${/off air/.test(st.error || '')
              ? 'Press <b>OK</b> to try again, or <b>▲ ▼</b> to switch channels.'
              : 'Most IPTV lines allow one stream at a time — make sure it isn’t playing on another device or through a VPN, then press <b>OK</b> to try again.'}</span></div>`;
        } else if (st.buffering || st.event === 'loading' || st.event === 'reconnecting') {
          status.hidden = false;
          status.classList.remove('error');
          const label = st.event === 'loading' ? 'Loading stream…' : st.event === 'reconnecting' ? 'Reconnecting…' : 'Buffering…';
          status.innerHTML = `<div class="spinner"></div><span>${label}</span>`;
        } else if (st.event === 'paused' || (st.playing === false && st.event !== 'tick')) {
          status.hidden = false;
          status.classList.remove('error');
          status.innerHTML = `${ICON.pause}<span>Paused</span>`;
        } else {
          status.hidden = true;
        }
      }
      const pb = $('#player-screen [data-fk="p-play"]');
      if (pb) pb.innerHTML = st.playing ? ICON.pause : ICON.play;
      const fill = $('#p-fill');
      if (fill) {
        const dur = st.duration || 0;
        fill.style.width = dur ? clamp(st.position / dur * 100, 0, 100).toFixed(2) + '%' : '0%';
        $('#p-pos').textContent = fmtTime(st.position);
        $('#p-dur').textContent = dur ? '-' + fmtTime(dur - st.position) : '--:--';
      }
      const res = $('#p-res');
      if (res) {
        const h = st.videoHeight || 0, w = st.videoWidth || 0; // widescreen 4K films are 3840x1600
        res.textContent = (h >= 2000 || w >= 3200) ? '4K UHD' : (h >= 1000 || w >= 1800) ? 'Full HD' : (h >= 700 || w >= 1200) ? 'HD' : h ? `${h}p` : '';
        res.hidden = !h;
      }
    },

    onState(st) {
      if (!this.item || S.screen !== 'player') return;
      if (st.itemId != null && st.itemId !== this.item.uid) return; // late update from the previous item
      const prevEvent = this.st.event;
      this.st = Object.assign({}, this.st, st);
      if (this.seekTarget != null) this.st.position = this.seekTarget;
      if (this.scrub) this.st.position = this.scrub.pos;
      if (st.event === 'error') {
        // Live HLS formats fail on many providers: fall back to MPEG-TS once and remember it.
        if (this.item.kind === 'live' && S.prefs.liveFormat !== 'ts' && this.item.channel) {
          S.prefs.liveFormat = 'ts';
          savePrefs();
          toast('Switched Live TV to MPEG-TS for this provider');
          playLive(this.item.channel, this.item.channelList);
          return;
        }
        this.showOSD(true);
      }
      if (st.event === 'ended') {
        this.saveProgress(true);
        if (this.item.kind === 'episode' && this.nextEpisode() && S.prefs.autoplayNext) { this.playNext(); return; }
        if (this.item.kind !== 'live') { this.exit(); return; }
      }
      if (st.event === 'tick' && Date.now() - this.lastSave > 5000) this.saveProgress();
      PlayerAI.tick(this.st);
      if (this.item.kind === 'episode' && S.prefs.autoplayNext && st.duration > 120 &&
        st.duration - st.position <= 25 && this.nextShownFor !== this.item.uid && this.nextEpisode()) {
        this.showNextCard();
      }
      if (st.event === 'playing' && prevEvent !== 'playing') this.scheduleHide();
      if (st.event !== 'tick' || this.osdOn) this.updateUI();
    },

    saveProgress(ended = false) {
      const it = this.item;
      if (!it || it.kind === 'live') return;
      const st = this.st || {};
      this.lastSave = Date.now();
      if (!st.duration && !ended) return;
      const pos = ended || PlayerAI.pastCredits(st) ? (st.duration || 0) : (st.position || 0);
      recordProgress(it, pos, st.duration || 0);
    },

    retry() {
      if (!this.item) return;
      const resume = this.item.kind === 'live' ? 0 : (this.st.position || this.item.resume || 0);
      this.play(Object.assign({}, this.item, { resume }));
    },

    // Repeated FF / ◀ ▶ presses move the scrubber immediately but send one seek once they stop, so the
    // player isn't asked to seek (and re-buffer) for every intermediate position.
    seekBy(d) {
      if (!this.item || this.item.kind === 'live') return;
      const dur = this.st.duration || 0;
      const base = this.seekTarget != null ? this.seekTarget : (this.st.position || 0);
      const target = clamp(base + d, 0, dur ? dur - 1 : 1e9);
      this.seekTarget = target;
      this.st.position = target;
      clearTimeout(this.seekTimer);
      this.seekTimer = setTimeout(() => {
        this.seekTimer = null;
        VideoAPI.seekTo(this.seekTarget);
        this.seekTarget = null;
      }, 350);
      this.updateUI();
      this.showOSD();
    },

    zap(dir) {
      const it = this.item;
      if (!it || it.kind !== 'live' || !it.channelList || it.channelList.length < 2) return;
      const n = it.channelList.length;
      const idx = ((it.channelIndex + dir) % n + n) % n;
      const ch = it.channelList[idx];
      playLive(ch, it.channelList);
      toast(`${ch.num || idx + 1} • ${ch.cleanName}`, 1800);
    },

    cycleFormat() {
      const order = ['m3u8', 'ts', 'm3u8_root'];
      S.prefs.liveFormat = order[(order.indexOf(S.prefs.liveFormat) + 1) % order.length];
      savePrefs();
      toast(`Stream format: ${S.prefs.liveFormat.toUpperCase()}`);
      const it = this.item;
      if (it && it.channel) {
        playLive(it.channel, it.channelList);
        Focus.set($('#player-screen [data-fk="p-format"]'));
      }
    },

    cycleAspect() {
      const order = ['fit', 'fill', '16:9'];
      this.aspect = order[(order.indexOf(this.aspect) + 1) % order.length];
      VideoAPI.setAspect(this.aspect);
      const el = $('#player-screen [data-fk="p-aspect"] span');
      if (el) el.textContent = this.aspect === 'fit' ? 'Fit' : this.aspect === 'fill' ? 'Fill' : '16:9';
      this.showOSD();
    },

    speedPicker() {
      const speeds = [0.75, 1, 1.25, 1.5];
      listModal({
        title: 'Playback Speed',
        rows: speeds.map(s => ({
          label: s === 1 ? '1x (Normal)' : `${s}x`, selected: s === this.speed,
          onSelect: () => {
            this.speed = s;
            VideoAPI.setSpeed(s);
            Modal.close();
            const el = $('#player-screen [data-fk="p-speed"] span');
            if (el) el.textContent = `${s}x`;
          }
        })),
        focusIndex: Math.max(0, speeds.indexOf(this.speed))
      });
    },

    trackPicker() {
      const st = this.st || {};
      const audio = st.audioTracks || [];
      const subs = st.subtitleTracks || [];
      const rows = [];
      if (!audio.length && !subs.length) {
        rows.push({ label: 'This stream has a single audio track and no subtitles', onSelect: () => Modal.close() });
      }
      audio.forEach((t, i) => rows.push({
        label: `Audio • ${t.name}`, value: i === 0 && st.selectedAudioTrack < 0 ? 'Default' : '',
        selected: st.selectedAudioTrack === t.index,
        onSelect: () => { VideoAPI.selectTrack(t.index, true); Modal.close(); toast(`Audio: ${t.name}`); }
      }));
      if (subs.length) {
        rows.push({ label: 'Subtitles • Off', selected: st.selectedSubtitleTrack < 0, onSelect: () => { VideoAPI.selectTrack(-1, false); Modal.close(); toast('Subtitles off'); } });
        subs.forEach(t => rows.push({
          label: `Subtitles • ${t.name}`, selected: st.selectedSubtitleTrack === t.index,
          onSelect: () => { VideoAPI.selectTrack(t.index, false); Modal.close(); toast(`Subtitles: ${t.name}`); }
        }));
      }
      listModal({ title: 'Audio & Subtitles', subtitle: 'Tracks reported by the stream', rows });
    },

    episodePicker() {
      const it = this.item;
      if (!it || !it.episodes) return;
      listModal({
        title: it.seriesTitle,
        subtitle: 'Episodes',
        rows: it.episodes.map(ep => ({
          label: `S${ep.season}:E${ep.episodeNum} • ${ep.cleanTitle}`,
          value: ep.duration || '',
          selected: ep.episodeId === it.episode.episodeId,
          onSelect: () => { Modal.close(); playEpisode(it.series, it.sInfo, ep, 0); }
        })),
        focusIndex: it.episodeIndex
      });
    },

    nextEpisode() {
      const it = this.item;
      if (!it || it.kind !== 'episode' || !it.episodes) return null;
      return it.episodes[it.episodeIndex + 1] || null;
    },

    playNext() {
      const it = this.item;
      const nx = this.nextEpisode();
      if (!nx) return;
      this.saveProgress(true);
      playEpisode(it.series, it.sInfo, nx, 0);
    },

    showNextCard() {
      const nx = this.nextEpisode();
      if (!nx) return;
      this.nextShownFor = this.item.uid;
      let count = 10;
      const slot = $('#p-next-slot');
      mount(slot, `
        <div class="next-ep-card" data-group="next">
          <div class="next-kicker">Next Episode in <b id="p-next-count">${count}</b></div>
          <div class="next-title">S${nx.season}:E${nx.episodeNum} • ${esc(nx.cleanTitle)}</div>
          <div class="next-progress"><div id="p-next-bar" style="width:0%"></div></div>
          <div class="modal-actions">
            <div class="tv-btn focusable" data-fk="next-play" ${act(() => this.playNext())}>${ICON.play} Play Now</div>
            <div class="tv-btn focusable" data-fk="next-cancel" ${act(() => this.cancelNext())}>Cancel</div>
          </div>
        </div>`);
      this.showOSD(true);
      Focus.set(slot.querySelector('[data-fk="next-play"]'));
      this.nextTimer = setInterval(() => {
        count--;
        const c = $('#p-next-count'), bar = $('#p-next-bar');
        if (c) c.textContent = String(Math.max(0, count));
        if (bar) bar.style.width = ((10 - count) * 10) + '%';
        if (count <= 0) this.playNext();
      }, 1000);
    },

    cancelNext(silent) {
      clearInterval(this.nextTimer);
      this.nextTimer = null;
      const slot = $('#p-next-slot');
      if (slot) slot.innerHTML = '';
      if (!silent && S.screen === 'player') Focus.set(this.defaultFocus());
    },

    showOSD(sticky = false) {
      const osd = $('#player-osd');
      if (!osd) return;
      const wasHidden = !this.osdOn;
      this.osdOn = true;
      osd.classList.remove('hidden-osd');
      if (wasHidden || !Focus.cur || !$('#player-screen').contains(Focus.cur)) Focus.set(this.defaultFocus());
      if (sticky) clearTimeout(this.osdTimer);
      else this.scheduleHide();
    },

    scheduleHide() {
      clearTimeout(this.osdTimer);
      this.osdTimer = setTimeout(() => {
        const st = this.st || {};
        if (S.screen !== 'player' || Modal.stack.length || this.nextTimer || this.scrub) return;
        if (!st.playing || st.event === 'error') return;
        this.hideOSD();
      }, 5000);
    },

    hideOSD() {
      const osd = $('#player-osd');
      if (osd) osd.classList.add('hidden-osd');
      this.osdOn = false;
    },

    exit() {
      this.saveProgress();
      PlayerAI.stop();
      Cloud.flush();
      Cloud.setNowPlaying(null);
      this.cancelNext(true);
      clearTimeout(this.osdTimer);
      clearTimeout(this.seekTimer);
      this.seekTarget = null;
      if (this.scrub) clearTimeout(this.scrub.thumbTimer);
      this.scrub = null;
      VideoAPI.stop();
      this.item = null;
      stage.classList.remove('video-passthrough');
      $('#player-screen').innerHTML = '';
      if (!Router.back()) Router.go('home', {}, { tab: true });
    },

    // ---- Timeline scrubbing with thumbnail previews (Netflix style): ◀ ▶ / FF / REW pause and move a preview
    // along the timeline, faster the longer you keep pressing; OK plays from there, BACK returns.

    startScrub() {
      const pos = this.st.position || 0;
      this.scrub = { pos, origin: pos, last: 0, streak: 0, shownId: 0, thumbTimer: null };
      VideoAPI.beginScrub();
      this.st.playing = false;
      this.showOSD(true);
      const osd = $('#player-osd');
      if (osd) osd.classList.add('scrubbing');
      const track = $('#p-track');
      if (track) Focus.set(track);
      const img = $('#p-preview-img');
      if (img) img.removeAttribute('src');
      const pv = $('#p-preview');
      if (pv) pv.hidden = false;
    },

    scrubStep(dir) {
      const sc = this.scrub;
      const now = performance.now();
      sc.streak = now - sc.last < 550 ? sc.streak + 1 : 0;
      sc.last = now;
      const step = sc.streak < 3 ? 10 : sc.streak < 7 ? 30 : sc.streak < 12 ? 60 : 120;
      const dur = this.st.duration || 0;
      sc.pos = clamp(sc.pos + dir * step, 0, Math.max(0, dur - 2));
      this.st.position = sc.pos;
      this.updateUI();
      this.placePreview();
      clearTimeout(sc.thumbTimer);
      sc.thumbTimer = setTimeout(() => VideoAPI.requestThumb(sc.pos, ++this.thumbSeq), 140);
    },

    placePreview() {
      const sc = this.scrub, track = $('#p-track'), pv = $('#p-preview');
      if (!sc || !track || !pv) return;
      const w = track.offsetWidth, dur = this.st.duration || 1, half = 192;
      pv.style.left = clamp(sc.pos / dur * w, half, Math.max(half, w - half)) + 'px';
      const t = $('#p-preview-time');
      if (t) t.textContent = fmtTime(sc.pos);
    },

    onThumb(id, sec, dataUrl) {
      const sc = this.scrub;
      if (!sc || id < sc.shownId) return;
      sc.shownId = id;
      const img = $('#p-preview-img');
      if (!img) return;
      if (dataUrl) img.src = dataUrl;
      else img.removeAttribute('src'); // frame couldn't be copied: the bubble shows the time only
    },

    endScrub(pos) {
      const sc = this.scrub;
      if (!sc) return;
      clearTimeout(sc.thumbTimer);
      this.scrub = null;
      const osd = $('#player-osd');
      if (osd) osd.classList.remove('scrubbing');
      const pv = $('#p-preview');
      if (pv) pv.hidden = true;
      Object.assign(this.st, { position: pos, event: 'buffering', buffering: true });
      VideoAPI.endScrub(pos);
      this.updateUI();
      this.scheduleHide();
    },

    scrubKey(key) {
      const sc = this.scrub;
      switch (key) {
        case 'LEFT': case 'REW': this.scrubStep(-1); break;
        case 'RIGHT': case 'FF': this.scrubStep(1); break;
        case 'BACK': this.endScrub(sc.origin); break;
        case 'SELECT': case 'PLAY_PAUSE': case 'PLAY': case 'UP': case 'DOWN': this.endScrub(sc.pos); break;
        default: break;
      }
      return true;
    },

    onKey(key) {
      if (Modal.stack.length) return false;
      if (this.scrub) return this.scrubKey(key);
      const canScrub = this.item && this.item.kind !== 'live' && this.st.duration > 0 && this.st.event !== 'error';
      const lr = key === 'LEFT' || key === 'RIGHT';
      const onTrack = this.osdOn && Focus.cur && Focus.cur.id === 'p-track';
      if (canScrub && (key === 'FF' || key === 'REW' || (lr && (!this.osdOn || onTrack)))) {
        this.startScrub();
        this.scrubStep(key === 'RIGHT' || key === 'FF' ? 1 : -1);
        return true;
      }
      switch (key) {
        case 'PLAY_PAUSE': case 'PLAY': case 'PAUSE':
          VideoAPI.togglePause(); this.showOSD(); return true;
        case 'FF': this.seekBy(30); return true;
        case 'REW': this.seekBy(-30); return true;
        case 'CH_UP': this.zap(1); return true;
        case 'CH_DOWN': this.zap(-1); return true;
        case 'BACK':
          if (this.nextTimer) { this.cancelNext(); return true; }
          this.exit();
          return true;
        case 'MENU':
          this.trackPicker(); return true;
        default: break;
      }
      const live = this.item && this.item.kind === 'live';
      if (!this.osdOn) {
        if (key === 'SELECT' && PlayerAI.skipShown) { PlayerAI.skipNow(); return true; }
        if (key === 'LEFT' || key === 'RIGHT') {
          if (live) this.showOSD();
          else this.seekBy(key === 'LEFT' ? -10 : 10);
          return true;
        }
        if ((key === 'UP' || key === 'DOWN') && live) { this.zap(key === 'UP' ? 1 : -1); return true; }
        this.showOSD();
        return true;
      }
      this.scheduleHide();
      return false;
    }
  };
  Screens.player = Player;

  // ------------------------------------------------------------------ Global key handling

  function exitConfirm() {
    confirmModal({
      title: 'Exit NucFlix?', okLabel: 'Exit', cancelLabel: 'Keep Watching', danger: true,
      onOk: () => { if (Native) Native.exitApp(); }
    });
  }

  function handleBack() {
    if (Modal.stack.length) { Modal.close(); return; }
    if (S.screen === 'pair') { exitConfirm(); return; }
    if (Router.back()) return;
    if (S.screen === 'home') {
      const atTop = Focus.cur && (Focus.cur.closest('[data-billboard]') || navEl.contains(Focus.cur));
      if (atTop) { exitConfirm(); return; }
      Focus.set(Home.defaultFocus());
      return;
    }
    goTab('home');
  }

  const App = {
    onRemoteKey(key) {
      if (S.splashActive) return;
      if (S.screen === 'player' && Player.onKey(key)) return;
      switch (key) {
        case 'BACK': handleBack(); return;
        case 'UP': case 'DOWN': case 'LEFT': case 'RIGHT':
          Focus.move(key); return;
        case 'SELECT': {
          const el = Focus.cur;
          if (el && el.isConnected && el._act) {
            el.classList.add('pressed');
            setTimeout(() => el.classList.remove('pressed'), 140);
            try { el._act(el); } catch (e) { console.error(e); }
          } else if (!el || !el.isConnected) {
            Focus.set(defaultFocusFor(S.screen));
          }
          return;
        }
        case 'MENU': {
          const scr = Screens[S.screen];
          if (scr && scr.onMenu && scr.onMenu()) return;
          return;
        }
        case 'PLAY_PAUSE': case 'PLAY': {
          const el = Focus.cur;
          if (el && el._act && !Modal.stack.length) el._act(el);
          return;
        }
        default: return;
      }
    },

    onNativeVideoState(st) { Player.onState(st || {}); },

    onThumb(id, sec, dataUrl) { Player.onThumb(id, sec, dataUrl); },
    onFrame(id, b64, black) { Smart.onFrame(id, b64, black); },

    onNativeCues(text) {
      const el = $('#p-subs');
      if (!el) return;
      el.textContent = text || '';
      el.hidden = !text;
    },

    onNativeFieldInput(fieldKey, val) {
      if (fieldKey === 'search') {
        Search.setQuery(val);
      }
    },

    onPhoneSearch(query) {
      if (!S.cat.loaded) { toast('Pick a profile first to search'); return; }
      Modal.closeAll();
      if (S.screen === 'player') Player.exit();
      Search.query = String(query || '');
      goTab('search');
      toast(`Searching “${Search.query}” from your phone`);
    },

    onPhoneType(text) {
      if (S.screen === 'search') {
        Search.setQuery(text);
      } else if (S.cat.loaded) {
        this.onPhoneSearch(text);
      }
    }
  };
  window.App = App;

  // Desktop preview keyboard support (Fire TV keys are routed natively).
  document.addEventListener('keydown', e => {
    const map = {
      ArrowUp: 'UP', ArrowDown: 'DOWN', ArrowLeft: 'LEFT', ArrowRight: 'RIGHT',
      Enter: 'SELECT', Escape: 'BACK', Backspace: 'BACK', ' ': 'PLAY_PAUSE', m: 'MENU', ContextMenu: 'MENU',
      PageUp: 'CH_UP', PageDown: 'CH_DOWN', MediaPlayPause: 'PLAY_PAUSE'
    };
    const k = map[e.key];
    if (k) { e.preventDefault(); App.onRemoteKey(k); }
  });

  // ------------------------------------------------------------------ Boot

  async function boot() {
    fitStage();
    bindNav();
    purgeLegacyData();
    fetch('/api/session').then(r => r.json()).then(s => {
      if (s.helperUrl) S.helperUrl = s.helperUrl;
      if (s.deviceModel) S.deviceModel = s.deviceModel === 'AFTKRT' ? 'Fire TV Stick 4K Max' : s.deviceModel;
      Cloud.deviceName = S.deviceModel;
    }).catch(() => { });

    // The splash stays up until we know where to go: the pairing code (new TV) or Who's watching. Firebase
    // starts in parallel with the cached catalog of the last line, so Home is quick after picking a profile.
    let state = null;
    try {
      state = await Promise.race([Cloud.start(), new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 15000))]);
    } catch (e) {
      console.warn('cloud start', e);
    }
    if (!state || !state.paired) {
      Router.go('pair');
      await endSplash();
      return;
    }
    if (Cloud.lastLineId) preloadP = loadCachedCatalog({ id: Cloud.lastLineId }).catch(() => null);
    startCloud();
    await Promise.race([householdReady, new Promise(r => setTimeout(r, 10000))]);
    Who.show();
    await endSplash();
  }

  // Builds the Shows and Movies tabs off-screen while the app is idle, so even the first visit is instant.
  function prerenderTabs() {
    const idle = fn => (window.requestIdleCallback ? requestIdleCallback(fn, { timeout: 4000 }) : setTimeout(fn, 200));
    // A content-visibility:hidden screen keeps its layout once it has one, so lay it out once (invisibly)
    // after its rows have streamed in; the first real visit then only has to paint.
    const warmLayout = el => {
      if (el.classList.contains('active')) return;
      el.style.visibility = 'hidden';
      el.style.contentVisibility = 'visible';
      void el.offsetHeight;
      el.style.contentVisibility = '';
      el.style.visibility = '';
    };
    ['series', 'movies'].forEach((name, i) => setTimeout(() => idle(() => {
      if (S.screen === name || !S.cat.loaded) return;
      Screens[name].render({});
      setTimeout(() => idle(() => warmLayout(document.getElementById(name + '-screen'))), 1200);
    }), 2500 + i * 2500));
  }

  boot();
})();
