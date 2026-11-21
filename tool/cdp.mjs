// Shared phone/DevTools helpers for oracle.mjs and journey.mjs: preflight, CDP connection, in-page helpers, real touches.
// Exit 3 from preflight/connect: phone not in portrait / app not focused / no phone.
import { execFileSync } from 'node:child_process';
import path from 'node:path';
export const ADB = path.join(process.env.LOCALAPPDATA || '', 'Android', 'Sdk', 'platform-tools', 'adb.exe');
export const APP = 'io.github.jacob_e_lee.taro_music';
export const sleep = ms => new Promise(r => setTimeout(r, ms));
export const rnd = (a, b) => a + Math.random() * (b - a);
export const J = (v, r) => v + rnd(-r, r);
export const adb = (...a) => execFileSync(ADB, a, { encoding: 'utf8', timeout: 15000 }).trim();
export function preflight() {
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

let ws, nextId = 0; const waiting = new Map();
export const exceptions = [];
export const send = (method, params = {}) => new Promise((res, rej) => {
  const id = ++nextId; waiting.set(id, m => (m.error ? rej(new Error(m.error.message)) : res(m.result)));
  ws.send(JSON.stringify({ id, method, params }));
});
export const ev = async expr => (await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true })).result?.value;

export async function connect() {
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
export const INTER = 'button,a[href],[role=button],tp-yt-paper-tab,tp-yt-paper-item,ytmusic-responsive-list-item-renderer,ytmusic-two-row-item-renderer,ytmusic-menu-service-item-renderer,ytmusic-player-bar,input';
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
export const P = fn => `(${PAGE}).${fn}`;     // P('snap()') evaluates a helper on the live page

// ---------- real touches ----------
const tp = (x, y) => [{ x, y, id: 0, radiusX: 6, radiusY: 6, force: 0.5 }];
export const touch = (type, x, y) => send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : tp(x, y) });
export async function drag(x1, y1, x2, y2, ms, wobble = 4) {
  await touch('touchStart', x1, y1);
  const steps = Math.max(4, Math.round(ms / 16));
  for (let i = 1; i <= steps; i++) {
    const f = i / steps, e = f * f * (3 - 2 * f);   // ease in/out, uneven like a hand
    await touch('touchMove', J(x1 + (x2 - x1) * e, wobble), y1 + (y2 - y1) * e);
    await sleep(ms / steps * rnd(0.6, 1.4));
  }
  await touch('touchEnd', x2, y2);
}
export const tap = async (x, y) => { x = J(x, 6); y = J(y, 6); await touch('touchStart', x, y); await sleep(rnd(40, 120)); await touch('touchEnd', x, y); };
export const hold = async (x, y) => { x = J(x, 4); y = J(y, 4); await touch('touchStart', x, y); await sleep(rnd(550, 950)); await touch('touchEnd', x, y); };
export async function nav(screen) {
  const ids = { Home: 'FEmusic_home', Explore: 'FEmusic_explore', Library: 'FEmusic_library_landing' };
  const endpoint = screen === 'Search' ? '{ searchEndpoint: { query: "lofi" } }' : `{ browseEndpoint: { browseId: ${JSON.stringify(ids[screen])} } }`;
  await ev(`document.querySelector('ytmusic-app').dispatchEvent(new CustomEvent('yt-navigate', { bubbles: true, composed: true, detail: { endpoint: ${endpoint} } }))`);
}
export async function cleanUp(W, H) {   // close menu / player, drop keyboard focus, so each cell starts from a known state
  await ev('document.activeElement && document.activeElement.blur && document.activeElement.blur()');
  for (let i = 0; i < 3; i++) {
    const s = await ev(P('screen()'));
    if (s === 'SongMenu') await tap(W / 2, 40);                       // scrim
    else if (s === 'FullPlayer' || s === 'TabsPanel') await drag(W / 2, 90, W / 2, H * 0.8, 160);
    else break;
    await sleep(700);
  }
}
export async function ensurePlaying(W, H) {
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
