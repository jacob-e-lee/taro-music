// Reads the live page over DevTools (adb-forwarded to localhost:9222). Exit 0 if inject.js ran. One JSON line out.
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = (o, code) => { console.log(JSON.stringify(o)); process.exit(code); };

let page;
for (let i = 0; i < 30 && !page; i++) {
  try { page = (await (await fetch('http://localhost:9222/json/list')).json()).find(t => t.type === 'page' && /music\.youtube\.com/.test(t.url)); } catch {}
  if (!page) await sleep(1000);
}
if (!page) out({ ok: false, why: 'no page target' }, 1);

const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise(r => (ws.onopen = r));
let id = 0;
const waiting = new Map();
ws.onmessage = e => { const m = JSON.parse(e.data); waiting.get(m.id)?.(m); };
const ev = expression => new Promise(r => {
  const i = ++id;
  waiting.set(i, m => r(m.result?.result?.value));
  ws.send(JSON.stringify({ id: i, method: 'Runtime.evaluate', params: { expression, awaitPromise: true, returnByValue: true } }));
});

let up = false;
for (let i = 0; i < 20 && !up; i++) {
  up = (await ev('!!window.__taroYtm && document.readyState === "complete"')) === true;
  if (!up) await sleep(1000);
}
if (!up) out({ ok: false, why: '__taroYtm not set / page not loaded' }, 1);

// 1.5 s of frame timing on the idle page (informational)
const frames = await Promise.race([
  ev(`new Promise(res => { let n = 0, max = 0, last = performance.now(), lt = 0; const s = last;
    try { new PerformanceObserver(l => lt += l.getEntries().length).observe({ entryTypes: ['longtask'] }); } catch (e) {}
    (function f(t) { const d = t - last; last = t; if (n++) max = Math.max(max, d);
      if (t - s < 1500) requestAnimationFrame(f); else res(JSON.stringify({ frames: n, maxMs: Math.round(max), longtasks: lt })); })(s); })`),
  sleep(5000).then(() => 'no frames (screen off?)'),
]);
out({ ok: true, frames }, 0);
