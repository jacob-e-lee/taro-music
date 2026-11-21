// Gate checks on the live phone (zero tokens): golden-path journeys, selector canary, layout baseline, frame/latency baseline.
//   node tool/journey.mjs journeys [--full]    cold-play, queue-sheet; --full adds background + screen-off
//   node tool/journey.mjs selectors            every selector in tool/selectors.json still matches on its screens
//   node tool/journey.mjs layout [--accept]    chrome rects vs tool/baseline.json (2 px)
//   node tool/journey.mjs perf [--accept]      sheet drag / fling frame times vs tool/perf-baseline.json; touch latency findings
//   node tool/journey.mjs baseline             layout + perf --accept
// Exit 0 pass, 1 fail (a line says which check), 3 phone not ready. Findings go to tool/.findings.json like oracle.mjs.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { sleep, adb, APP, preflight, connect, send, ev, PAGE, tap, drag, nav } from './cdp.mjs';
import { setup, addFindings, loadJson, keyOf } from './oracle.mjs';

const T = path.dirname(fileURLToPath(import.meta.url));
const FILE = { sel: path.join(T, 'selectors.json'), layout: path.join(T, 'baseline.json'), perf: path.join(T, 'perf-baseline.json') };
export const BUDGET = { playMs: 12000, tolPx: 2, worstPct: 0.25, worstMs: 8, latencyMs: 100 };

// ---------- pure parts (unit-tested in journey.test.mjs) ----------
export function compareLayout(base, now, tol = BUDGET.tolPx) {   // {state: {name: [l,t,w,h]|null}} -> list of problems
  const out = [];
  for (const [st, els] of Object.entries(base)) for (const [n, r] of Object.entries(els)) {
    const c = now[st]?.[n];
    if (!r && !c) continue;
    if (!r || !c) out.push(`${st}: ${n} ${c ? 'appeared' : 'missing'}`);
    else if (r.some((v, i) => Math.abs(v - c[i]) > tol)) out.push(`${st}: ${n} moved ${r.map(Math.round)} -> ${c.map(Math.round)}`);
  }
  return out;
}
export function comparePerf(base, now) {   // {gesture: {worst, p95, lt}} -> list of problems
  const out = [];
  for (const [g, b] of Object.entries(base)) {
    const n = now[g]; if (!n) continue;
    if (n.worst > b.worst * (1 + BUDGET.worstPct) && n.worst - b.worst > BUDGET.worstMs) out.push(`${g}: worst frame ${b.worst} -> ${n.worst} ms`);
    if (n.lt > b.lt + 1) out.push(`${g}: long tasks ${b.lt} -> ${n.lt}`);
  }
  return out;
}
export const median = a => [...a].sort((x, y) => x - y)[a.length >> 1];
export function mediaSession(dump) {   // our app's native session out of `dumpsys media_session`
  const i = dump.indexOf('SUMMARY: package=' + APP); if (i < 0) return null;
  const blk = dump.slice(i + 10).split('SUMMARY:')[0];   // description is "title, artist, null"; the title may hold commas itself
  return { playing: /state=PLAYING/.test(blk), title: (/description=([^\n]*)/.exec(blk)?.[1] || '').replace(/, [^,]*, [^,]*$/, '') };
}

// ---------- helpers ----------
let fails = 0;
const fail = m => { fails++; console.log('FAIL: ' + m); };
const ok = m => console.log('ok: ' + m);
const session = () => mediaSession(adb('shell', 'dumpsys media_session'));
const dims = async () => JSON.parse(await ev('JSON.stringify([innerWidth, innerHeight])'));
const priority = list => addFindings(list.map(f => ({ ...f, key: keyOf(f.rule, f.screen, f.sel), priority: true })));
const audioState = () => ev(`(() => { const v = document.querySelector('video'); return v ? { paused: v.paused, t: v.currentTime } : null; })()`);
async function advancing() { const a = await audioState(); await sleep(1500); const b = await audioState(); return !!(a && b && !b.paused && b.t > a.t); }

async function playFromSearch() {   // search by yt-navigate (no typing), tap the first safe song row
  await nav('Search'); await sleep(2500);
  const r = await ev(`(() => { const H = ${PAGE}; for (const e of document.querySelectorAll('ytmusic-responsive-list-item-renderer')) {
      if (!H.shown(e) || !/\\bSong\\b/.test(e.innerText || '')) continue; const r = e.getBoundingClientRect(), x = r.left + r.width / 3, y = r.top + r.height / 2;
      if (!H.unsafe(x, y) && y > 150 && y < innerHeight - 160) return [x, y, (e.innerText || '').slice(0, 40)]; } return null; })()`);
  if (!r) return console.log('cold-play: no safe song row in the results'), false;
  console.log('cold-play: tapping ' + JSON.stringify(r[2]));
  await tap(r[0], r[1]);
  const t0 = Date.now();
  while (Date.now() - t0 < BUDGET.playMs) { if (await advancing().catch(() => false)) return Date.now() - t0; }
  return false;
}

// ---------- journeys ----------
async function coldPlay() {
  adb('shell', 'am', 'force-stop', APP); adb('shell', 'am', 'start', '-n', `${APP}/.MainActivity`);
  await sleep(4000); preflight(); await connect();
  for (let i = 0; i < 20 && !await ev('!!window.__taroYtm'); i++) await sleep(500);
  const ms = await playFromSearch() || (console.log('cold-play: retrying once'), await playFromSearch());   // YouTube sometimes ignores the first tap after a cold start
  if (!ms) return fail('cold-play: no advancing audio within ' + BUDGET.playMs + ' ms of tapping a search result');
  const s = session();
  if (!s?.playing || !s.title) return fail(`cold-play: native MediaSession not playing / no title (${JSON.stringify(s)})`);
  ok(`cold-play: playing after ${ms} ms, notification "${s.title}"`);
}
async function queueSheet() {
  const [W, H] = await dims();
  if (!await setup('TabsPanel', 'idle', W, H)) return fail('queue-sheet: could not open the queue panel');
  const row = await ev(`(() => { const H = ${PAGE}; const e = [...document.querySelectorAll('ytmusic-player-queue-item')].filter(H.shown)[1]; const r = e && e.getBoundingClientRect(); return r && [r.left + r.width / 2, r.top + r.height / 2]; })()`);
  if (row) { await tap(row[0], row[1]); await sleep(2500); }
  const title = await ev(`document.querySelector('ytmusic-player-bar .title')?.textContent?.trim()`);
  const s = session();
  if (!title || !s?.title || !(title.startsWith(s.title) || s.title.startsWith(title))) return fail(`queue-sheet: page title "${title}" != notification "${s?.title}"`);
  await setup('Home', 'idle', W, H);
  if (!await advancing()) return fail('queue-sheet: audio stopped after closing the sheet');
  ok(`queue-sheet: "${title}" matches the notification, audio continues`);
}
async function background() {   // --full: audio must survive HOME and screen-off
  const key = k => adb('shell', 'input', 'keyevent', k);
  const check = label => { const s = session(); if (!s?.playing) fail(`background: native session not PLAYING after ${label}`); else ok('background: still PLAYING after ' + label); };
  key('KEYCODE_HOME'); await sleep(15000); check('15 s on the launcher');
  key('KEYCODE_SLEEP'); await sleep(15000); check('15 s screen off');
  key('KEYCODE_WAKEUP'); await sleep(1500); adb('shell', 'wm', 'dismiss-keyguard'); adb('shell', 'am', 'start', '-n', `${APP}/.MainActivity`); await sleep(2500);
  if (!adb('shell', 'dumpsys window | grep mCurrentFocus').includes(APP)) console.log('skipped: app did not come back (lock screen?)');
}

// ---------- selector canary ----------
async function selectors() {
  const [W, H] = await dims(); const list = loadJson(FILE.sel, []), byScreen = {};
  for (const s of list) for (const sc of s.screens) (byScreen[sc] ||= []).push(s);
  const missing = [];
  for (const [sc, items] of Object.entries(byScreen)) {
    if (!await setup(sc, 'playing', W, H)) { console.log(`skipped screen ${sc} (unreachable)`); continue; }
    for (const s of items) if (!await ev(`!!document.querySelector(${JSON.stringify(s.selector)})`)) missing.push({ screen: sc, rule: 'sel', sel: s.name, detail: `selector ${s.selector} matches nothing on ${sc} (YouTube DOM change?)` });
  }
  await setup('Home', 'idle', W, H);
  if (missing.length) { priority(missing); fail('selectors missing: ' + missing.map(m => `${m.sel}@${m.screen}`).join(', ')); } else ok(`selectors: ${list.length} present`);
}

// ---------- layout baseline ----------
const CHROME = ['ytmusic-app-layout > ytmusic-player-bar', '#taro-nav', 'ytmusic-search-box', 'ytmusic-player-page', '.taro-menu', '#taro-mh', 'ytmusic-player-queue'];
const STATES = ['Home', 'Search', 'FullPlayer', 'TabsPanel', 'SongMenu'];
async function layoutNow() {
  const [W, H] = await dims(), now = {};
  for (const st of STATES) {
    if (!await setup(st, 'playing', W, H)) continue;
    now[st] = await ev(`(() => { const o = {}; for (const s of ${JSON.stringify(CHROME)}) { const e = document.querySelector(s), r = e && e.getBoundingClientRect();
      o[s] = r && r.width && r.height ? [r.left, r.top, r.width, r.height].map(v => Math.round(v)) : null; } return o; })()`);
  }
  await setup('Home', 'idle', W, H);
  return now;
}
async function layout(accept) {
  const now = await layoutNow();
  if (accept) { fs.writeFileSync(FILE.layout, JSON.stringify(now, null, 1)); return ok('layout baseline written'); }
  const base = loadJson(FILE.layout, null); if (!base) return console.log('layout: no baseline (run baseline)');
  const bad = compareLayout(base, now);
  if (bad.length) fail('layout drift: ' + bad.join('; ')); else ok('layout: matches baseline');
}

// ---------- frame time / touch latency (recorder is injected here, never shipped in inject.js) ----------
const REC = `(() => { if (window.__rec) return; const r = window.__rec = { d: [], lt: 0, move: 0, fb: 0, last: 0, on: false };
  const els = () => [document.querySelector('ytmusic-player-page'), document.querySelector('ytmusic-app-layout > ytmusic-player-bar')];
  const sigOf = () => els().map(e => e && e.style.transform).join('|') + scrollY; let sig = '';
  const frame = t => { if (r.on) { if (r.last) r.d.push(t - r.last); r.last = t; if (r.move && !r.fb && sigOf() !== sig) r.fb = t - r.move; } requestAnimationFrame(frame); };
  addEventListener('touchmove', () => { if (r.on && !r.move) { r.move = performance.now(); sig = sigOf(); } }, true);
  try { new PerformanceObserver(l => { if (r.on) r.lt += l.getEntries().length; }).observe({ entryTypes: ['longtask'] }); } catch {}
  requestAnimationFrame(frame); })()`;
const rec = async fn => {
  await ev(REC); await ev('Object.assign(window.__rec, { d: [], lt: 0, move: 0, fb: 0, last: 0, on: true })');
  await fn(); await sleep(400); await ev('window.__rec.on = false');
  const r = await ev('({ d: window.__rec.d, lt: window.__rec.lt, fb: Math.round(window.__rec.fb) })');
  const d = r.d.sort((a, b) => a - b);
  return { worst: Math.round(d[d.length - 1] || 0), p95: Math.round(d[Math.floor(d.length * 0.95)] || 0), lt: r.lt, fb: r.fb };
};
async function perfNow() {
  const [W, H] = await dims(), out = {}, lat = [];
  const gestures = {
    'sheet-open-close': async () => { const b = await ev(`(() => { const r = document.querySelector('ytmusic-app-layout > ytmusic-player-bar').getBoundingClientRect(); return [r.left + r.width / 3, r.top + r.height / 2]; })()`);
      await drag(b[0], b[1], b[0], H * 0.15, 320); await sleep(900); await drag(W / 2, 90, W / 2, H * 0.8, 320); await sleep(600); },
    'list-fling': async () => { await drag(W / 2, H * 0.7, W / 2, H * 0.25, 120); await sleep(500); await drag(W / 2, H * 0.7, W / 2, H * 0.25, 120); },
  };
  for (const [g, fn] of Object.entries(gestures)) {
    const reps = [];
    for (let i = 0; i < 3; i++) { if (!await setup('Home', 'playing', W, H)) break; reps.push(await rec(fn)); }
    if (!reps.length) continue;
    out[g] = { worst: median(reps.map(r => r.worst)), p95: median(reps.map(r => r.p95)), lt: median(reps.map(r => r.lt)) };
    const fb = median(reps.map(r => r.fb)); if (fb > BUDGET.latencyMs) lat.push({ screen: 'Home', rule: 'lat', sel: g, detail: `touch to first visual change ${fb} ms (budget ${BUDGET.latencyMs})` });
  }
  await setup('Home', 'idle', W, H);
  return { out, lat };
}
async function perf(accept) {
  const { out, lat } = await perfNow();
  if (lat.length) addFindings(lat.map(f => ({ ...f, key: keyOf(f.rule, f.screen, f.sel) })));
  if (accept) { fs.writeFileSync(FILE.perf, JSON.stringify(out, null, 1)); return ok('perf baseline written ' + JSON.stringify(out)); }
  const base = loadJson(FILE.perf, null); if (!base) return console.log('perf: no baseline (run baseline)');
  const bad = comparePerf(base, out);
  if (bad.length) fail('perf regression: ' + bad.join('; ')); else ok('perf: within baseline ' + JSON.stringify(out));
  for (const l of lat) console.log(`F:${keyOf(l.rule, l.screen, l.sel)} | ${l.detail}`);
}

async function main() {
  const [cmd, ...a] = process.argv.slice(2);
  if (!['journeys', 'selectors', 'layout', 'perf', 'baseline'].includes(cmd)) { console.log('usage: journey.mjs journeys [--full] | selectors | layout [--accept] | perf [--accept] | baseline'); process.exit(2); }
  const accept = a.includes('--accept');
  preflight(); await connect();
  try {
    if (cmd === 'journeys') { await coldPlay(); await queueSheet(); if (a.includes('--full')) await background(); }
    else if (cmd === 'selectors') await selectors();
    else if (cmd === 'layout') await layout(accept);
    else if (cmd === 'perf') await perf(accept);
    else { await layout(true); await perf(true); }
  } finally {
    await send('Network.emulateNetworkConditions', { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 }).catch(() => {});
    try { adb('forward', '--remove-all'); } catch {}
  }
  process.exit(fails ? 1 : 0);
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main().catch(e => { console.log('ERROR: ' + e.message); process.exit(1); });
