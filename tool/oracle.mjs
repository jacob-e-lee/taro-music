// Deterministic defect finder for the harvest agent: findings come from measurements, not from the model's impressions.
//   node tool/oracle.mjs audit                         static hit-box / inset / truncation audit of the current screen
//   node tool/oracle.mjs lens thumb|motion|edge      one rotating harvest lens (thumb reach, animation continuity, long text / slow network)
//   node tool/oracle.mjs wander [--cells N] [--cell "Screen|State|Gesture"] [--reps K] [--chaos]
//                                                       human-ish real touches in the least-covered cells, before/after diffs
// Writes findings to tool/.findings.json (merged across calls; the loop deletes it at the start of a harvest),
// per-gesture diffs to tool/.gestures.json, and coverage counts to tool/coverage.json (all git-ignored).
// Exit 3: phone not in portrait / app not focused / no phone. Page-level network emulation is always restored.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { sleep, rnd, J, adb, APP, preflight, connect, send, ev, exceptions, PAGE, P, touch, drag, tap, hold, nav, cleanUp, ensurePlaying } from './cdp.mjs';
export { PAGE };

const T = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.dirname(T);
const F = { findings: path.join(T, '.findings.json'), gestures: path.join(T, '.gestures.json'), cov: path.join(T, 'coverage.json') };
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

function backlogContext() {
  const read = f => { try { return fs.readFileSync(path.join(ROOT, f), 'utf8'); } catch { return ''; } };
  const b = read('docs/BACKLOG.md');
  return { keys: new Set([...knownKeys(b), ...knownKeys(read('docs/DONE.md'))]), rejected: b.split('## Rejected')[1] || '' };
}

export function addFindings(list) {   // dedupe against BACKLOG/DONE keys, suppress false positives, merge into the findings file
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
export async function setup(screen, state, W, H) {
  await cleanUp(W, H);
  if (state === 'playing' || screen === 'FullPlayer' || screen === 'TabsPanel') if (!await ensurePlaying(W, H)) return false;
  if (LISTS.includes(screen)) {
    await nav(screen); if (state !== 'anim') await sleep(2200);
    if (screen === 'Search' && !String(await ev('location.pathname')).startsWith('/search')) return false;
    await ev(`scrollTo(0, ${state === 'deep' ? 3500 : 0})`); if (state !== 'anim') await sleep(400);
  } else if (screen === 'FullPlayer' || screen === 'TabsPanel') {
    if (!String(await ev('location.pathname')).startsWith('/watch') && await ev(P('screen()')) === 'Search') { await nav('Home'); await sleep(1500); }   // the mini player is not tappable on the search page
    for (let i = 0; i < 12 && await ev(`(document.querySelector('ytmusic-app-layout > ytmusic-player-bar')?.getBoundingClientRect().top ?? 0) < innerHeight * 0.5`) && await ev(P('screen()')) !== 'FullPlayer'; i++) await sleep(500);   // the bar settles at the bottom a moment after a navigation
    const bar = await ev(`(() => { const r = document.querySelector('ytmusic-app-layout > ytmusic-player-bar')?.getBoundingClientRect(); return r && [r.left + r.width / 3, r.top + r.height / 2]; })()`);
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

// ---------- lenses (harvest rotates through these; each is a measurement, not an opinion) ----------
const THUMB = ['.play-pause-button', '.next-button', '.previous-button', 'ytmusic-player-page tp-yt-paper-tab', 'ytmusic-search-box .search-button'];
async function lensThumb(W, H) {   // primary actions should sit in the lower 55 % of the screen
  const found = [];
  for (const st of ['Home', 'FullPlayer', 'TabsPanel']) {
    if (!await setup(st, 'playing', W, H)) continue;
    for (const sel of THUMB) {
      const y = await ev(`(() => { const H = ${PAGE}; const e = [...document.querySelectorAll(${JSON.stringify(sel)})].find(H.shown); const r = e && e.getBoundingClientRect(); return r ? Math.round(r.top + r.height / 2) : null; })()`);
      if (y != null && y < H * 0.45) found.push({ screen: st, rule: 'thumb', sel, detail: `primary action ${sel} centre at y=${y} of ${H} css px: out of easy thumb reach` });
    }
  }
  return found;
}
async function motionProbe(label, screen, trigger, getter) {   // count distinct positions the element passes through while it opens or closes
  await ev(`window.__mp = []; (function f(t0) { const t = performance.now(); try { window.__mp.push(${getter}); } catch {} if (t - t0 < 700) requestAnimationFrame(() => f(t0)); })(performance.now())`);
  await trigger(); await sleep(900);
  const n = new Set((await ev('window.__mp') || []).map(v => Math.round(v / 4))).size;
  return n < 4 ? [{ screen, rule: 'motion', sel: label, detail: `${label}: only ${n} distinct positions in 700 ms (jumps instead of animating)` }] : [];
}
async function lensMotion(W, H) {
  const found = [];
  if (await setup('Home', 'playing', W, H)) {
    const bar = await ev(`(() => { const r = document.querySelector('ytmusic-app-layout > ytmusic-player-bar').getBoundingClientRect(); return [r.left + r.width / 3, r.top + r.height / 2]; })()`);
    found.push(...await motionProbe('player-sheet-open', 'Home', () => tap(bar[0], bar[1]), `document.querySelector('ytmusic-player-page').getBoundingClientRect().top`));
    found.push(...await motionProbe('player-sheet-close', 'FullPlayer', () => drag(W / 2, 90, W / 2, H * 0.8, 160), `document.querySelector('ytmusic-player-page').getBoundingClientRect().top`));
  }
  if (await setup('Library', 'idle', W, H)) {
    const r = await ev(`(() => { const e = [...document.querySelectorAll('ytmusic-responsive-list-item-renderer,ytmusic-two-row-item-renderer')].find(e => { const r = e.getBoundingClientRect(); return r.top > 150 && r.bottom < innerHeight - 140; }); const r = e && e.getBoundingClientRect(); return r && [r.left + r.width / 2, r.top + r.height / 2]; })()`);
    if (r) found.push(...await motionProbe('song-menu-open', 'SongMenu', () => hold(r[0], r[1]), `document.querySelector('.taro-menu') ? document.querySelector('.taro-menu').getBoundingClientRect().top : innerHeight`));
  }
  return found;
}
const LONG = 'Ünïcödé 한국어 제목이 아주 긴 노래 제목입니다 (feat. Some Very Long Featured Artist Name & Another One) [Extended Remix 2026]';
async function lensEdge(W, H) {
  const found = [];
  if (await setup('Home', 'idle', W, H)) {
    const r = JSON.parse(await ev(`(() => { const H = ${PAGE}; const e = [...document.querySelectorAll('ytmusic-responsive-list-item-renderer .title, ytmusic-two-row-item-renderer .title')].find(H.shown); if (!e) return 'null';
      e.textContent = ${JSON.stringify(LONG)}; const r = e.getBoundingClientRect(), s = getComputedStyle(e);
      return JSON.stringify({ right: Math.round(r.right), clip: e.scrollWidth > e.clientWidth + 2 && s.textOverflow !== 'ellipsis' && s.webkitLineClamp === 'none' }); })()`) || 'null');
    if (r && (r.right > W || r.clip)) found.push({ screen: 'Home', rule: 'edge', sel: 'long-title', detail: `a 60-char mixed Korean/English title overflows (right edge ${r.right} of ${W}, clipped without ellipsis: ${r.clip})` });
  }
  try {   // slow 3G: the page must show something (content or a spinner), never a blank screen
    await send('Network.enable');
    await send('Network.emulateNetworkConditions', { offline: false, latency: 600, downloadThroughput: 50 * 1024, uploadThroughput: 20 * 1024 });
    await nav('Library'); await sleep(3500);
    const blank = await ev(`document.body.innerText.trim().length < 20 && !document.querySelector('tp-yt-paper-spinner,paper-spinner-lite,ytmusic-section-list-renderer')`);
    if (blank) found.push({ screen: 'Library', rule: 'edge', sel: 'blank-on-slow-network', detail: 'Library shows no content and no spinner 3.5 s into a slow 3G load' });
  } finally { await send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }).catch(() => {}); }
  await nav('Home'); await sleep(1500);
  return found;
}
async function lens(name) {
  const [W, H] = JSON.parse(await ev('JSON.stringify([innerWidth, innerHeight])'));
  try {
    const found = await ({ thumb: lensThumb, motion: lensMotion, edge: lensEdge }[name])(W, H);
    return addFindings(found.map(f => ({ ...f, key: keyOf(f.rule, f.screen, f.sel) })));
  } finally { await send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }).catch(() => {}); await cleanUp(W, H).catch(() => {}); await nav('Home').catch(() => {}); }
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
  if (!['audit', 'wander', 'lens'].includes(cmd)) { console.log('usage: oracle.mjs audit | wander [--cells N] [--cell "Screen|State|Gesture"] [--reps K] [--chaos] | lens thumb|motion|edge'); process.exit(2); }
  preflight(); await connect();
  let all;
  try {
    if (cmd === 'audit') all = addFindings((await audit()));
    else if (cmd === 'lens') all = await lens(args[0]);
    else all = await wander(opt);
  } finally { try { adb('forward', '--remove-all'); } catch {} }
  console.log(`FINDINGS ${all.length} (in tool/.findings.json; ticket key goes in [F:key])`);
  for (const f of all.slice(0, 40)) console.log(`F:${f.key} | ${f.rule} | ${f.screen} | ${f.detail}`);
  process.exit(0);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(e => { console.log('ERROR: ' + e.message); try { adb('forward', '--remove-all'); } catch {} process.exit(1); });
