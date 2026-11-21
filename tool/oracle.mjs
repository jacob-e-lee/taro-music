// Deterministic defect finder for the harvest agent: findings come from measurements, not from the model's impressions.
//   node tool/oracle.mjs audit                         static hit-box / inset / truncation audit of the current screen
//   node tool/oracle.mjs wander [--cells N] [--cell "Screen|State|Gesture"] [--reps K] [--chaos]
//                                                       human-ish real touches in the least-covered cells, before/after diffs
// Writes findings to tool/.findings.json (merged across calls; the loop deletes it at the start of a harvest),
// per-gesture diffs to tool/.gestures.json, and coverage counts to tool/coverage.json (all git-ignored).
// Exit 3: phone not in portrait / app not focused / no phone. Page-level network emulation is always restored.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const T = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.dirname(T);
const F = { findings: path.join(T, '.findings.json'), gestures: path.join(T, '.gestures.json'), cov: path.join(T, 'coverage.json') };
const ADB = path.join(process.env.LOCALAPPDATA || '', 'Android', 'Sdk', 'platform-tools', 'adb.exe');
const APP = 'io.github.jacob_e_lee.taro_music';
const SHOWN_LIMIT = 3; // a finding shown this often without becoming a ticket is treated as a false positive

// ---------- cells ----------
const GESTURES = ['fling-down', 'fling-up', 'slow-drag', 'long-press', 'double-tap', 'edge-tap', 'abandoned-drag', 'h-swipe'];
const LISTS = ['Home', 'Explore', 'Library', 'Search'];
export const CELLS = [];
for (const s of LISTS) for (const st of ['idle', 'playing', 'anim', 'deep']) for (const g of GESTURES) CELLS.push(`${s}|${st}|${g}`);
for (const s of ['FullPlayer', 'TabsPanel']) for (const st of ['playing', 'anim']) for (const g of GESTURES) CELLS.push(`${s}|${st}|${g}`);
for (const g of ['fling-down', 'fling-up', 'slow-drag', 'abandoned-drag', 'edge-tap', 'h-swipe']) CELLS.push(`SongMenu|idle|${g}`);

// ---------- pure helpers (unit-tested in tool/oracle.test.mjs) ----------
export const clean = s => String(s).replace(/[\s\]|\[]+/g, '_').slice(0, 90);
export const keyOf = (rule, screen, sel) => `${rule}:${screen}:${clean(sel)}`;
export const knownKeys = text => new Set([...String(text).matchAll(/\[F:([^\]]+)\]/g)].map(m => m[1]));
export function knownNoise(msg, rejectedText) {   // YouTube's own errors already judged in the Rejected list
  const tok = /reading '([^']+)'/.exec(msg)?.[1] || /Blocked aria-hidden|Ignored attempt to cancel/.exec(msg)?.[0];
  return !!tok && rejectedText.includes(tok);
}
export function pickCells(cov, n, rnd = Math.random) {
  const open = CELLS.filter(c => (cov.cells[c] || 0) < 900);
  open.sort((a, b) => (cov.cells[a] || 0) - (cov.cells[b] || 0) || rnd() - 0.5);
  return open.slice(0, n);
}
export const loadJson = (f, d) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return d; } };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const rnd = (a, b) => a + Math.random() * (b - a);
const J = (v, r) => v + rnd(-r, r);

function backlogContext() {
  const read = f => { try { return fs.readFileSync(path.join(ROOT, f), 'utf8'); } catch { return ''; } };
  const b = read('docs/BACKLOG.md');
  return { keys: new Set([...knownKeys(b), ...knownKeys(read('docs/DONE.md'))]), rejected: b.split('## Rejected')[1] || '' };
}

function addFindings(list) {   // dedupe against BACKLOG/DONE keys, suppress false positives, merge into the findings file
  const ctx = backlogContext();
  const cov = loadJson(F.cov, { cells: {}, shown: {} });
  const out = loadJson(F.findings, []);
  for (const f of list) {
    if (ctx.keys.has(f.key) || out.some(o => o.key === f.key)) continue;
    cov.shown[f.key] = (cov.shown[f.key] || 0) + 1;
    if (cov.shown[f.key] > SHOWN_LIMIT) continue;
    out.push(f);
  }
  fs.writeFileSync(F.findings, JSON.stringify(out, null, 1));
  fs.writeFileSync(F.cov, JSON.stringify(cov));
  return out;
}

// ---------- phone / DevTools ----------
const adb = (...a) => execFileSync(ADB, a, { encoding: 'utf8', timeout: 15000 }).trim();
function preflight() {
  try {
    const look = () => adb('shell', 'dumpsys window | grep -E "mCurrentFocus|mCurrentRotation"');
    let t = look();
    if (!t.includes(APP)) {   // the phone is on the launcher: bring our own app forward, then re-check
      adb('shell', `am start -n ${APP}/.MainActivity`);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 6000);
      t = look();
    }
    if (!t.includes(APP) || !/mCurrentRotation=(ROTATION_)?0/.test(t)) throw new Error('not portrait or app not focused');
  } catch (e) { console.log(`ABORT: ${e.message}`); process.exit(3); }
}

let ws, nextId = 0; const waiting = new Map(); const exceptions = [];
const send = (method, params = {}) => new Promise((res, rej) => {
  const id = ++nextId; waiting.set(id, m => (m.error ? rej(new Error(m.error.message)) : res(m.result)));
  ws.send(JSON.stringify({ id, method, params }));
});
const ev = async expr => (await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })).result?.value;

async function connect() {
  const pid = adb('shell', 'pidof', APP).split(/\s+/)[0];
  if (!pid) { console.log('ABORT: app not running'); process.exit(3); }
  adb('forward', 'tcp:9222', `localabstract:webview_devtools_remote_${pid}`);
  let page;
  for (let i = 0; i < 20 && !page; i++) {
    try { page = (await (await fetch('http://localhost:9222/json/list')).json()).find(t => t.type === 'page' && /music\.youtube\.com/.test(t.url)); } catch {}
    if (!page) await sleep(500);
  }
  if (!page) { console.log('ABORT: no page target'); process.exit(3); }
  ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise(r => (ws.onopen = r));
  ws.onmessage = e => {
    const m = JSON.parse(e.data);
    if (m.id) waiting.get(m.id)?.(m);
    else if (m.method === 'Runtime.exceptionThrown') exceptions.push(m.params.exceptionDetails?.exception?.description || m.params.exceptionDetails?.text || '');
  };
  await send('Runtime.enable');
}

// ---------- in-page helpers ----------
const INTER = 'button,a[href],[role=button],tp-yt-paper-tab,tp-yt-paper-item,ytmusic-responsive-list-item-renderer,ytmusic-two-row-item-renderer,ytmusic-menu-service-item-renderer,ytmusic-player-bar,input';
export const PAGE = `(() => {
  const INTER = ${JSON.stringify(INTER)};
  const sel = e => e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') +
    [...e.classList].filter(c => !/\\d|scope|taro-pressed|^style/.test(c)).slice(0, 2).map(c => '.' + c).join('');
  const inset = side => { const d = document.createElement('div');
    d.style.cssText = 'position:fixed;left:0;width:1px;visibility:hidden;' + side + ':0;height:env(safe-area-inset-' + side + ')';
    document.documentElement.appendChild(d); const h = d.getBoundingClientRect().height; d.remove(); return h; };
  const screen = () => {
    const h = document.documentElement, p = location.pathname;
    if (document.querySelector('.taro-menu')) return 'SongMenu';
    if (h.classList.contains('taro-open')) { const pg = document.querySelector('ytmusic-player-page'); return pg && pg.getAttribute('player-page-ui-state') === 'TABS_VIEW' ? 'TabsPanel' : 'FullPlayer'; }
    return p === '/' ? 'Home' : p.startsWith('/explore') ? 'Explore' : p.startsWith('/library') ? 'Library' : p.startsWith('/search') ? 'Search' : 'Other';
  };
  const shown = e => { const r = e.getBoundingClientRect(), s = getComputedStyle(e);
    return r.width > 0 && r.height > 0 && r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth && s.visibility !== 'hidden' && s.display !== 'none' && +s.opacity > 0; };
  const unsafe = (x, y) => { let e = document.elementFromPoint(x, y);   // like / save / playlist / delete / ... never get tapped
    for (let i = 0; e && i < 5; i++, e = e.parentElement) {
      const t = (e.getAttribute('aria-label') || e.getAttribute('title') || '') + ' ' + (e.matches(INTER) ? (e.innerText || '').slice(0, 60) : '');
      if (/like|save|library|playlist|delete|remove|add to|subscribe|download|share|report|sign|feedback|queue|radio|mix/i.test(t)) return true; }
    return false; };
  const snap = () => { const v = document.querySelector('video'), pg = document.querySelector('ytmusic-player-page'), bar = document.querySelector('ytmusic-player-bar'),
      cw = document.querySelector('#contentWrapper');
    return { href: location.pathname + location.search, html: document.documentElement.className, paused: v ? v.paused : null,
      t: v ? Math.round(v.currentTime) : null, y: Math.round(scrollY), cw: cw ? Math.round(cw.scrollTop) : null,
      menu: !!document.querySelector('.taro-menu'), state: pg && pg.getAttribute('player-page-ui-state'),
      tr: [pg, bar].map(e => e && e.style.transform) }; };
  const at = (x, y) => { const e = document.elementFromPoint(x, y); if (!e) return null; const i = e.closest(INTER), r = i && i.getBoundingClientRect();
    return { sel: sel(e), inter: i ? sel(i) : null, inside: !!(r && x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) }; };
  return { INTER, sel, inset, screen, shown, unsafe, snap, at };
})()`;
const P = fn => `(${PAGE}).${fn}`;     // P('snap()') evaluates a helper on the live page

// ---------- real touches ----------
const tp = (x, y) => [{ x, y, id: 0, radiusX: 6, radiusY: 6, force: 0.5 }];
const touch = (type, x, y) => send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : tp(x, y) });
async function drag(x1, y1, x2, y2, ms, wobble = 4) {
  await touch('touchStart', x1, y1);
  const steps = Math.max(4, Math.round(ms / 16));
  for (let i = 1; i <= steps; i++) {
    const f = i / steps, e = f * f * (3 - 2 * f);   // ease in/out, uneven like a hand
    await touch('touchMove', J(x1 + (x2 - x1) * e, wobble), y1 + (y2 - y1) * e);
    await sleep(ms / steps * rnd(0.6, 1.4));
  }
  await touch('touchEnd', x2, y2);
}
const tap = async (x, y) => { x = J(x, 6); y = J(y, 6); await touch('touchStart', x, y); await sleep(rnd(40, 120)); await touch('touchEnd', x, y); };
const hold = async (x, y) => { x = J(x, 4); y = J(y, 4); await touch('touchStart', x, y); await sleep(rnd(550, 950)); await touch('touchEnd', x, y); };

async function perform(g, x, y, W, H) {
  const dy = rnd(250, 600), up = Math.random() < 0.5;
  switch (g) {
    case 'fling-down': return drag(x, y, x, Math.min(H - 20, y + dy), rnd(80, 140), 8);
    case 'fling-up': return drag(x, y, x, Math.max(20, y - dy), rnd(80, 140), 8);
    case 'slow-drag': return drag(x, y, x, up ? Math.max(20, y - dy) : Math.min(H - 20, y + dy), rnd(600, 900));
    case 'long-press': return hold(x, y);
    case 'double-tap': await tap(x, y); await sleep(rnd(60, 160)); return tap(x, y);
    case 'edge-tap': return tap(Math.random() < 0.5 ? rnd(1, 10) : W - rnd(1, 10), y);
    case 'abandoned-drag': return drag(x, y, J(x, 30), y + rnd(20, 70), rnd(150, 300), 10);
    case 'h-swipe': return drag(x, y, Math.max(10, Math.min(W - 10, x + (up ? -1 : 1) * rnd(120, W * 0.7))), J(y, 20), rnd(120, 400));
  }
}

// ---------- audit ----------
export const AUDIT_JS = `(() => { const H = ${PAGE}; const top = H.inset('top'), bot = H.inset('bottom'), screen = H.screen();
    const els = [...document.querySelectorAll(H.INTER)].filter(H.shown).map(e => { const r = e.getBoundingClientRect(); return { e, r, sel: H.sel(e) }; });
    const own = ({ sel }) => /^ytmusic-player-bar|#taro-nav|#taro-scrim/.test(sel);
    const out = [], seen = new Set();
    const add = (rule, sel, detail) => { const k = rule + sel; if (!seen.has(k)) { seen.add(k); out.push({ rule, screen, sel, detail }); } };
    for (const { r, sel } of els) {
      if (Math.min(r.width, r.height) < 44 && r.width * r.height > 0) add('small', sel, Math.round(r.width) + 'x' + Math.round(r.height) + ' css px at ' + Math.round(r.left) + ',' + Math.round(r.top));
    }
    for (const a of els) for (const b of els) {
      if (a === b || a.e.contains(b.e) || b.e.contains(a.e) || (Math.min(a.r.width, a.r.height) >= 48 && Math.min(b.r.width, b.r.height) >= 48)) continue;
      const dx = Math.max(b.r.left - a.r.right, a.r.left - b.r.right), dy = Math.max(b.r.top - a.r.bottom, a.r.top - b.r.bottom);
      const ov = Math.min(a.r.bottom, b.r.bottom) - Math.max(a.r.top, b.r.top), oh = Math.min(a.r.right, b.r.right) - Math.max(a.r.left, b.r.left);
      if ((dx >= 0 && dx < 8 && ov > 0.5 * Math.min(a.r.height, b.r.height)) || (dy >= 0 && dy < 8 && oh > 0.5 * Math.min(a.r.width, b.r.width))) add('gap', a.sel + '+' + b.sel, 'targets ' + Math.round(Math.min(dx < 0 ? 99 : dx, dy < 0 ? 99 : dy)) + ' px apart');
    }
    for (const x of els) { if (own(x)) continue;
      if (x.r.top < top - 1 && x.r.bottom > top + 4) add('top-inset', x.sel, 'crosses the status bar zone (' + Math.round(x.r.top) + ' < ' + Math.round(top) + ')');
      if (x.r.bottom > innerHeight - bot + 1 && x.r.top < innerHeight - bot - 4) add('bottom-inset', x.sel, 'crosses the navigation bar zone');
    }
    for (const e of document.querySelectorAll('h1,h2,h3,yt-formatted-string,.title,.subtitle')) { if (!H.shown(e)) continue;
      const s = getComputedStyle(e); if (s.textOverflow === 'ellipsis' || s.overflow === 'hidden' && s.textOverflow !== 'clip') continue;
      if (e.scrollWidth > e.clientWidth + 2 && e.clientWidth > 0 && s.display !== 'inline') add('clipped-text', H.sel(e), 'scrollWidth ' + e.scrollWidth + ' > ' + e.clientWidth);
    }
    return JSON.stringify(out.slice(0, 80)); })()`;
async function audit() {
  return JSON.parse(await ev(AUDIT_JS)).map(r => ({ key: keyOf(r.rule, r.screen, r.sel), ...r }));
}

// ---------- wander ----------
const sleepAnim = 150;
async function nav(screen) {
  const ids = { Home: 'FEmusic_home', Explore: 'FEmusic_explore', Library: 'FEmusic_library_landing' };
  const endpoint = screen === 'Search' ? '{ searchEndpoint: { query: "lofi" } }' : `{ browseEndpoint: { browseId: ${JSON.stringify(ids[screen])} } }`;
  await ev(`document.querySelector('ytmusic-app').dispatchEvent(new CustomEvent('yt-navigate', { bubbles: true, composed: true, detail: { endpoint: ${endpoint} } }))`);
}
async function cleanUp(W, H) {   // close menu / player, drop keyboard focus, so each cell starts from a known state
  await ev('document.activeElement && document.activeElement.blur && document.activeElement.blur()');
  for (let i = 0; i < 3; i++) {
    const s = await ev(P('screen()'));
    if (s === 'SongMenu') await tap(W / 2, 40);                       // scrim
    else if (s === 'FullPlayer' || s === 'TabsPanel') await drag(W / 2, 90, W / 2, H * 0.8, 160);
    else break;
    await sleep(700);
  }
}
async function ensurePlaying(W, H) {
  const has = () => ev(`!!document.querySelector('ytmusic-player-bar') && !!document.querySelector('ytmusic-player-bar .title')?.textContent?.trim()`);
  if (await has()) return true;
  await nav('Home'); await sleep(2500);
  const r = await ev(`(() => { const H = ${PAGE}; for (const e of document.querySelectorAll('ytmusic-two-row-item-renderer,ytmusic-responsive-list-item-renderer')) {
      if (!H.shown(e)) continue; const r = e.getBoundingClientRect(); const x = r.left + r.width / 2, y = r.top + Math.min(r.height / 2, 60);
      if (!H.unsafe(x, y) && y > 120 && y < innerHeight - 140) return [x, y]; } return null; })()`);
  if (!r) return false;
  await tap(r[0], r[1]); await sleep(3500);
  return has();
}
async function setup(screen, state, W, H) {
  await cleanUp(W, H);
  if (state === 'playing' || screen === 'FullPlayer' || screen === 'TabsPanel') if (!await ensurePlaying(W, H)) return false;
  if (LISTS.includes(screen)) {
    await nav(screen); if (state !== 'anim') await sleep(2200);
    if (screen === 'Search' && !String(await ev('location.pathname')).startsWith('/search')) return false;
    await ev(`scrollTo(0, ${state === 'deep' ? 3500 : 0})`); if (state !== 'anim') await sleep(400);
  } else if (screen === 'FullPlayer' || screen === 'TabsPanel') {
    const bar = await ev(`(() => { const r = document.querySelector('ytmusic-player-bar')?.getBoundingClientRect(); return r && [r.left + r.width / 3, r.top + r.height / 2]; })()`);
    if (bar && await ev(P('screen()')) !== 'FullPlayer' && await ev(P('screen()')) !== 'TabsPanel') { await tap(bar[0], bar[1]); await sleep(state === 'anim' ? sleepAnim : 1200); }
    if (screen === 'TabsPanel') {
      const t = await ev(`(() => { const e = document.querySelector('ytmusic-player-page tp-yt-paper-tab'); const r = e && e.getBoundingClientRect(); return r && [r.left + r.width / 2, r.top + r.height / 2]; })()`);
      if (t) { await tap(t[0], t[1]); await sleep(state === 'anim' ? sleepAnim : 900); }
    }
    if (await ev(P('screen()')) !== screen && state !== 'anim') return false;
  } else if (screen === 'SongMenu') {
    await nav('Library'); await sleep(2200);
    const r = await ev(`(() => { const e = [...document.querySelectorAll('ytmusic-responsive-list-item-renderer,ytmusic-two-row-item-renderer')].find(e => { const r = e.getBoundingClientRect(); return r.top > 150 && r.bottom < innerHeight - 140; });
      const r = e && e.getBoundingClientRect(); return r && [r.left + r.width / 2, r.top + r.height / 2]; })()`);
    if (!r) return false;
    await hold(r[0], r[1]); await sleep(900);
    if (await ev(P('screen()')) !== 'SongMenu') return false;
  }
  return true;
}

async function runCell(cell, reps, W, H, TOPpx, BOTpx, log, found) {
  const [screen, state, g] = cell.split('|');
  if (!await setup(screen, state, W, H)) { log.push({ cell, skipped: 'unreachable' }); return false; }
  for (let i = 0; i < reps; i++) {
    if (i && state !== 'anim') await sleep(500);
    let x = rnd(W * 0.08, W * 0.92), y = rnd(TOPpx + 80, H - BOTpx - 120);
    if (screen === 'SongMenu') { x = W / 2; y = H * 0.7; }
    const before = await ev(P('snap()')), target = await ev(P(`at(${x},${y})`)), screenNow = await ev(P('screen()'));
    const isTapLike = ['long-press', 'double-tap', 'edge-tap'].includes(g);
    if (isTapLike && screenNow !== 'SongMenu' && await ev(P(`unsafe(${x},${y})`))) { log.push({ cell, skipped: 'unsafe target' }); continue; }
    const exc0 = exceptions.length;
    await perform(g, x, y, W, H);
    await sleep(650);
    const after = await ev(P('snap()'));
    const d = { cell, g, x: Math.round(x), y: Math.round(y), target, changed: JSON.stringify(before) !== JSON.stringify(after), before, after };
    log.push(d);
    const base = { screen: screenNow };
    if (isTapLike && g !== 'long-press' && target?.inter && target.inside && !d.changed) {   // retry once: first tap may have been eaten by the previous touch
      await sleep(900); const b2 = await ev(P('snap()')); await tap(x, y); await sleep(650);
      if (JSON.stringify(b2) === JSON.stringify(await ev(P('snap()')))) found.push({ ...base, rule: 'dead-tap', sel: target.inter, detail: `${g} at ${d.x},${d.y} inside ${target.inter}: no URL, player, scroll, sheet or menu change after 650 ms (twice)` });
    }
    if (g === 'long-press' && target?.inter && /list-item|two-row/.test(target.inter) && !after.menu && !d.changed)
      found.push({ ...base, rule: 'dead-long-press', sel: target.inter, detail: `long press at ${d.x},${d.y} on ${target.inter} opened no menu` });
    const vert = ['fling-down', 'fling-up', 'slow-drag'].includes(g);
    if (vert && screenNow !== 'SongMenu') {
      const pageMoved = after.y !== before.y, sheetMoved = JSON.stringify(after.tr) !== JSON.stringify(before.tr) || after.state !== before.state || after.html !== before.html;
      if (pageMoved && sheetMoved && ['FullPlayer', 'TabsPanel'].includes(screenNow)) found.push({ ...base, rule: 'gesture-conflict', sel: g, detail: `${g} at ${d.x},${d.y}: page scrolled ${before.y}->${after.y} while the player sheet also moved` });
      const room = await ev('document.documentElement.scrollHeight - innerHeight - scrollY');
      if (LISTS.includes(screenNow) && !d.changed && g === 'fling-up' && room > 200)
        found.push({ ...base, rule: 'scroll-swallowed', sel: g, detail: `${g} at ${d.x},${d.y} moved nothing although ${Math.round(room)} px of page remain below` });
    }
    for (const m of exceptions.slice(exc0)) {
      if (knownNoise(m, backlogContext().rejected)) continue;
      found.push({ ...base, rule: 'exception', sel: m.split('\n')[0].slice(0, 70), detail: `${g} at ${d.x},${d.y}: ${m.split('\n')[0].slice(0, 160)}` });
    }
  }
  const stuck = await ev(`(() => { const o = []; if (document.querySelector('[taro-pressed]')) o.push('taro-pressed'); if (document.documentElement.classList.contains('taro-sheet')) o.push('taro-sheet'); return o; })()`);
  await sleep(1500);
  const stuck2 = await ev(`(() => { const o = []; if (document.querySelector('[taro-pressed]')) o.push('taro-pressed'); if (document.documentElement.classList.contains('taro-sheet')) o.push('taro-sheet'); return o; })()`);
  for (const s of stuck2.filter(s => stuck.includes(s))) found.push({ screen, rule: 'stuck-state', sel: s, detail: `${s} still set 1.5 s after the last touch in ${cell}` });
  return true;
}

async function chaos(W, H, found) {
  const exc0 = exceptions.length;
  const sc = await ev(P('screen()'));
  const play = await ev(`(() => { const e = document.querySelector('#play-pause-button, ytmusic-player-bar .play-pause-button'); const r = e && e.getBoundingClientRect(); return r && [r.left + r.width / 2, r.top + r.height / 2]; })()`);
  if (play) for (let i = 0; i < 3; i++) { await tap(play[0], play[1]); await sleep(rnd(40, 90)); }   // rapid play/pause: races and duplicate listeners
  await sleep(800);
  await drag(W / 2, H * 0.85, W / 2, H * 0.4, 500);   // sheet drag interrupted by Android Back
  try { adb('shell', 'input', 'keyevent', 'KEYCODE_BACK'); } catch {}
  await sleep(1200);
  try {   // page-level offline for 4 s, always restored
    await send('Network.enable'); await send('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
    await drag(W / 2, H * 0.7, W / 2, H * 0.3, 300); await sleep(4000);
  } finally { await send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }).catch(() => {}); }
  await sleep(3000);
  const ok = await ev(`!!document.querySelector('ytmusic-app') && !!document.querySelector('#taro-nav') && !!window.__taroYtm`).catch(() => false);
  if (!ok) found.push({ screen: sc, rule: 'chaos-dead-page', sel: 'offline-restore', detail: 'after 4 s offline and restore, the app shell or tab bar is gone' });
  for (const m of exceptions.slice(exc0)) if (!knownNoise(m, backlogContext().rejected)) found.push({ screen: sc, rule: 'exception', sel: m.split('\n')[0].slice(0, 70), detail: `chaos: ${m.split('\n')[0].slice(0, 160)}` });
}

async function wander(opt) {
  const dim = await ev('JSON.stringify([innerWidth, innerHeight])').then(JSON.parse);
  const [W, H] = dim;
  const [TOPpx, BOTpx] = JSON.parse(await ev(`(() => { const H = ${PAGE}; return JSON.stringify([H.inset('top'), H.inset('bottom')]); })()`));
  const cov = loadJson(F.cov, { cells: {}, shown: {} });
  const cells = opt.cell ? [opt.cell] : pickCells(cov, opt.cells);
  const log = [], found = [];
  try {
    for (const c of cells) {
      preflight();
      const ok = await runCell(c, opt.reps, W, H, TOPpx, BOTpx, log, found);
      cov.cells[c] = (cov.cells[c] || 0) + (ok ? 1 : 3);   // unreachable cells sink down the list instead of being retried every run
      if (!ok && (cov.cells[c] || 0) >= 9) cov.cells[c] = 999;
    }
    if (opt.chaos) await chaos(W, H, found);
  } finally {
    await send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }).catch(() => {});
    await cleanUp(W, H).catch(() => {}); await nav('Home').catch(() => {});
    const merged = loadJson(F.cov, { cells: {}, shown: {} }); merged.cells = { ...merged.cells, ...cov.cells };
    fs.writeFileSync(F.cov, JSON.stringify(merged));
    fs.writeFileSync(F.gestures, JSON.stringify(log));
  }
  const gestures = log.filter(l => l.g).length;
  const out = addFindings(found.map(f => ({ ...f, key: keyOf(f.rule, f.screen, f.sel) })));
  console.log(`wander: cells ${cells.join(' ; ')} | ${gestures} gestures | ${found.length} raw findings (tool/.gestures.json has the diffs)`);
  return out;
}

function coverageMd() {   // generated summary, committed by the loop with an accepted harvest
  const cov = loadJson(F.cov, { cells: {} });
  const rows = new Map();
  for (const c of CELLS) { const [s] = c.split('|'); const n = cov.cells[c] || 0; const r = rows.get(s) || { cells: 0, hit: 0, runs: 0, dead: 0 };
    r.cells++; if (n) r.hit++; if (n >= 900) r.dead++; else r.runs += n; rows.set(s, r); }
  const untouched = CELLS.filter(c => !(cov.cells[c] > 0));
  const md = ['# Coverage (generated by tool/oracle.mjs; do not edit)', '', 'Cells are Screen x State x Gesture. Runs per screen:', '',
    '| Screen | Cells touched | Runs | Unreachable |', '|---|---|---|---|',
    ...[...rows].map(([s, r]) => `| ${s} | ${r.hit}/${r.cells} | ${r.runs} | ${r.dead} |`), '',
    `Untouched cells: ${untouched.length}/${CELLS.length}` + (untouched.length ? ` (next: ${untouched.slice(0, 5).join(', ')})` : ''), ''].join('\n');
  fs.writeFileSync(path.join(ROOT, 'docs', 'COVERAGE.md'), md);
}

// ---------- main ----------
async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  const opt = { cells: 3, reps: 4, chaos: false, cell: '' };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--cells') opt.cells = +args[++i]; else if (args[i] === '--reps') opt.reps = +args[++i];
    else if (args[i] === '--cell') opt.cell = args[++i]; else if (args[i] === '--chaos') opt.chaos = true;
  }
  if (cmd === 'coverage-md') return coverageMd();   // no phone needed
  if (!['audit', 'wander'].includes(cmd)) { console.log('usage: oracle.mjs audit | wander [--cells N] [--cell "Screen|State|Gesture"] [--reps K] [--chaos]'); process.exit(2); }
  preflight(); await connect();
  let all;
  try {
    if (cmd === 'audit') all = addFindings((await audit()));
    else all = await wander(opt);
  } finally { try { adb('forward', '--remove-all'); } catch {} }
  console.log(`FINDINGS ${all.length} (in tool/.findings.json; ticket key goes in [F:key])`);
  for (const f of all.slice(0, 40)) console.log(`F:${f.key} | ${f.rule} | ${f.screen} | ${f.detail}`);
  process.exit(0);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(e => { console.log('ERROR: ' + e.message); try { adb('forward', '--remove-all'); } catch {} process.exit(1); });
