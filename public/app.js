// 위치 기록 앱 — 지도 모드 / 기록 모드 / 설정
import { Tracker, dirName } from './track.js?v=6';
import { createMap, inKR } from './mapkit.js?v=5';

const $ = (id) => document.getElementById(id);
const pad = (n) => String(n).padStart(2, '0');
const hms = (ms) => { const d = new Date(ms); return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`; };
const dur = (ms) => { const s = Math.max(0, Math.floor(ms / 1000)); return `${pad(Math.floor(s / 3600))}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`; };
const durKo = (ms) => { const m = Math.round(ms / 60000); return m < 60 ? `${m}분` : `${Math.floor(m / 60)}시간 ${m % 60}분`; };
const WEEK = '일월화수목금토';
const dateKo = (ms) => { const d = new Date(ms); return `${d.getMonth() + 1}월 ${d.getDate()}일 (${WEEK[d.getDay()]})`; };
const defaultName = (ms) => { const d = new Date(ms); return `${d.getMonth() + 1}월 ${d.getDate()}일 ${pad(d.getHours())}:${pad(d.getMinutes())} 기록`; };

let toastT = null;
function toast(msg, ms = 3000) { const t = $('toast'); t.textContent = msg; t.hidden = false; clearTimeout(toastT); toastT = setTimeout(() => (t.hidden = true), ms); }

async function api(method, url, body) {
  const r = await fetch(url, { method, headers: body ? { 'Content-Type': 'application/json' } : {}, body: body ? JSON.stringify(body) : undefined,
    credentials: 'same-origin', redirect: 'manual' });
  if (r.type === 'opaqueredirect' || r.status === 0) throw new Error('로그인 필요');
  if (!r.ok) { let m = r.status + ''; try { m = (await r.json()).detail || m; } catch {} throw new Error(m); }
  return r.json();
}

// ---------- 로컬 저장 (IndexedDB: 점, localStorage: 기록 상태) ----------
const idb = await new Promise((ok, fail) => {
  const r = indexedDB.open('location-log', 1);
  r.onupgradeneeded = () => { const s = r.result.createObjectStore('pts', { keyPath: ['cid', 'seq'] }); s.createIndex('cid', 'cid'); };
  r.onsuccess = () => ok(r.result); r.onerror = () => fail(r.error);
});
const store = (mode) => idb.transaction('pts', mode).objectStore('pts');
const done = (req) => new Promise((ok, fail) => { req.onsuccess = () => ok(req.result); req.onerror = () => fail(req.error); });
function putPts(arr) {
  return new Promise((ok, fail) => { const t = idb.transaction('pts', 'readwrite'); const s = t.objectStore('pts'); arr.forEach(p => s.put(p)); t.oncomplete = ok; t.onerror = () => fail(t.error); });
}
const getPts = (cid) => done(store('readonly').index('cid').getAll(cid));
function delPts(cid) {
  return new Promise((ok, fail) => {
    const t = idb.transaction('pts', 'readwrite'); const req = t.objectStore('pts').index('cid').openCursor(IDBKeyRange.only(cid));
    req.onsuccess = () => { const c = req.result; if (c) { c.delete(); c.continue(); } }; t.oncomplete = ok; t.onerror = () => fail(t.error);
  });
}
// 업로드 성공 표시: 그 사이 보정으로 바뀐 점(ver 다름)은 다시 보내도록 그대로 둠
function markSynced(arr) {
  return new Promise((ok, fail) => {
    const t = idb.transaction('pts', 'readwrite'); const s = t.objectStore('pts');
    arr.forEach(p => { const g = s.get([p.cid, p.seq]); g.onsuccess = () => { const r = g.result; if (r && r.ver === p.ver) { r.synced = 1; s.put(r); } }; });
    t.oncomplete = ok; t.onerror = () => fail(t.error);
  });
}

let rec = JSON.parse(localStorage.getItem('loc.rec') || 'null');          // 기록 중인 경로
let pending = JSON.parse(localStorage.getItem('loc.pending') || '[]');    // 끝났지만 업로드가 남은 경로
const persist = () => { localStorage.setItem('loc.rec', JSON.stringify(rec)); localStorage.setItem('loc.pending', JSON.stringify(pending)); };
let verN = 0; const ver = () => Date.now() * 1000 + (verN++ % 1000);

// ---------- 현재 경로 점 (화면용) ----------
let curPts = []; const curIdx = new Map();     // seq → curPts 위치
const seqMap = new Map();                       // 추적기 seq → 기록 seq
function setCur(pts) { curPts = pts.sort((a, b) => a.seq - b.seq); curIdx.clear(); curPts.forEach((p, i) => curIdx.set(p.seq, i)); }

// ---------- 추적기 ----------
let live = null, lastFixAt = 0;
const tracker = new Tracker({ onPoint, onCorrect });
function onPoint(pt) {
  live = pt; lastFixAt = performance.now();
  if (!rec) { updateMe(); return; }
  const seq = rec.nextSeq++; seqMap.set(pt.seq, seq); persist();
  const p = { ...pt, seq, cid: rec.cid, synced: 0, ver: ver() };
  const prev = curPts.at(-1);
  if (prev && !isBreak(prev, p)) recDist += haversine(prev, p);
  putPts([p]);
  curIdx.set(seq, curPts.length); curPts.push(p);
  drawAppend(p); logAppend(p, prev);
  updateMe();
}
function onCorrect(list, info) {
  if (!rec) return;
  const ups = [];
  for (const q of list) {
    const s = seqMap.get(q.seq); if (s == null) continue;
    const p = { ...q, seq: s, cid: rec.cid, synced: 0, ver: ver() };
    ups.push(p); const i = curIdx.get(s); if (i != null) curPts[i] = p;
  }
  if (!ups.length) return;
  putPts(ups); calcDist(); redrawLines(); logReset();   // 기록 화면의 추정 줄도 보정된 좌표로
  toast(`GPS 끊김 ${Math.round(info.gapS)}초 구간을 다시 잡힌 위치에 맞춰 보정했습니다 (차이 ${Math.round(info.errM)}m)`, 4000);
}
setInterval(() => tracker.tick(performance.now()), 250);

// GPS
let gpsErr = '';
function startGps() {
  if (!('geolocation' in navigator)) { gpsErr = '이 브라우저는 위치를 지원하지 않습니다'; return; }
  navigator.geolocation.watchPosition((pos) => {
    const c = pos.coords; gpsErr = '';
    tracker.gps({ perf: performance.now(), epoch: Date.now(), lat: c.latitude, lon: c.longitude, alt: c.altitude, acc: c.accuracy,
      speed: c.speed, heading: c.heading });
    if (!live || tracker.mode !== 'gps') updateMe(c.latitude, c.longitude);
  }, (err) => { gpsErr = err.code === 1 ? '위치 권한이 꺼져 있습니다 (설정 › 개인정보 보호 › 위치 서비스 › Safari)' : '위치를 못 받고 있습니다'; },
  { enableHighAccuracy: true, maximumAge: 0, timeout: 30000 });
}

// 자이로·가속도·나침반 (iOS는 사용자 터치 후 권한 요청 필요)
let sensorsOn = false, lastSensorAt = 0;
function attachSensors() {
  if (sensorsOn) return; sensorsOn = true;
  addEventListener('deviceorientation', (e) => { lastSensorAt = performance.now();
    tracker.orientation(e.timeStamp, e.alpha, e.beta, e.gamma, e.webkitCompassHeading, e.webkitCompassAccuracy); });
  addEventListener('devicemotion', (e) => tracker.motion(e.timeStamp, e.acceleration, e.accelerationIncludingGravity, e.rotationRate));
}
const needsPermission = typeof DeviceOrientationEvent !== 'undefined' && typeof DeviceOrientationEvent.requestPermission === 'function';
async function requestSensors() {
  try {
    if (needsPermission) {
      const a = await DeviceOrientationEvent.requestPermission();
      if (typeof DeviceMotionEvent?.requestPermission === 'function') await DeviceMotionEvent.requestPermission();
      if (a !== 'granted') { toast('센서 권한이 없어 터널 구간은 이어 그리지 못합니다'); return; }
    }
  } catch { /* 이미 허용됐거나 지원 안 함 */ }
  attachSensors();
}
if (!needsPermission) attachSensors();
$('sensorBanner').addEventListener('click', async () => { await requestSensors(); $('sensorBanner').hidden = true; });

// 화면 꺼짐 방지
let wake = null;
async function keepAwake(on) {
  try {
    if (on && !wake && 'wakeLock' in navigator) { wake = await navigator.wakeLock.request('screen'); wake.addEventListener('release', () => (wake = null)); }
    if (!on && wake) { await wake.release(); wake = null; }
  } catch {}
}
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') { if (rec) keepAwake(true); sync(); } });

// ---------- 지도 ----------
const cfg = await api('GET', 'api/config').catch(() => ({}));
const map = await createMap($('map'), { naverKey: cfg.naver_map_key, zoom: 16 });
const me = map.marker();
let follow = true, centered = false, lines = [], lastKR = null;
map.onDrag(() => { follow = false; $('btnFollow').classList.remove('on'); });
$('btnFollow').addEventListener('click', () => { follow = true; $('btnFollow').classList.add('on'); if (live) map.pan(live.lat, live.lon); });
function updateMe(lat, lon) {
  const p = live ?? (lat != null ? { lat, lon } : null); if (!p) return;
  const hdg = live?.hdg ?? tracker.compassHeading ?? null;
  const kr = inKR(p);
  if (kr !== lastKR) { lastKR = kr; map.ensure([p]); }   // 해외로 나가면 Leaflet, 돌아오면 네이버
  me.set(p.lat, p.lon, hdg);
  if (!centered) { map.center(p.lat, p.lon, 16); centered = true; } else if (follow && mode === 'map') map.pan(p.lat, p.lon);
}
const COLOR = { gps: '#2563eb', imu: '#f59e0b' };
// 순간 이동(비행·오래 끊김 뒤 다른 곳): 선을 잇지 않음
const isBreak = (q, p) => p.brk || (q && p.ts - q.ts > 0 && haversine(q, p) / ((p.ts - q.ts) / 1000) > 120);
function haversine(a, b) {
  const R = 6371008.8, r = Math.PI / 180, x = Math.sin((b.lat - a.lat) * r / 2) ** 2 + Math.cos(a.lat * r) * Math.cos(b.lat * r) * Math.sin((b.lon - a.lon) * r / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}
function segments(pts) {   // 같은 출처끼리 묶고, 경계 점은 양쪽에 공유
  const segs = [];
  for (const p of pts) {
    const s = segs.at(-1), q = s?.pts.at(-1);
    if (s && isBreak(q, p)) segs.push({ src: p.src, pts: [p] });
    else if (s && s.src === p.src) s.pts.push(p);
    else segs.push({ src: p.src, pts: s ? [q, p] : [p] });
  }
  return segs;
}
function redrawLines() {
  lines.forEach(l => l.line.remove()); lines = [];
  for (const s of segments(curPts)) { const line = map.line({ color: COLOR[s.src], dashed: s.src === 'imu' }); line.set(s.pts); lines.push({ ...s, line }); }
}
function drawAppend(p) {
  const s = lines.at(-1), brk = s && isBreak(s.pts.at(-1), p);
  if (s && !brk && s.src === p.src) { s.pts.push(p); s.line.set(s.pts); return; }
  const line = map.line({ color: COLOR[p.src], dashed: p.src === 'imu' });
  const pts = s && !brk ? [s.pts.at(-1), p] : [p]; line.set(pts); lines.push({ src: p.src, pts, line });
}

// ---------- 기록 모드 목록 ----------
const logList = $('logList');
function logLine(p, prev) {
  const frag = document.createDocumentFragment();
  if (prev && p.ts - prev.ts > 20000) {
    const g = document.createElement('div'); g.className = 'gap';
    g.textContent = `${durKo(p.ts - prev.ts)} 동안 기록 없음`; frag.appendChild(g);
  }
  const d = document.createElement('div'); d.className = 'ln' + (p.src === 'imu' ? ' est-ln' : '');
  const spd = p.spd == null ? '–' : Math.round(p.spd * 3.6);
  d.innerHTML = `<span class="t">${hms(p.ts)}</span><span class="c">${p.lat.toFixed(5)}, ${p.lon.toFixed(5)}${p.src === 'imu' ? '<span class="tag est">추정</span>' : ''}</span>`
    + `<span class="s">${spd}<small>km/h</small></span>`;
  frag.appendChild(d); return frag;
}
// 기록 거리 (순간 이동 구간 제외)
let recDist = 0;
function calcDist() { recDist = 0; for (let i = 1; i < curPts.length; i++) if (!isBreak(curPts[i - 1], curPts[i])) recDist += haversine(curPts[i - 1], curPts[i]); }
function logAppend(p, prev) {
  const stick = logList.scrollHeight - logList.scrollTop - logList.clientHeight < 60;
  logList.appendChild(logLine(p, prev));
  while (logList.childElementCount > 3000) logList.firstElementChild.remove();
  if (stick) logList.scrollTop = logList.scrollHeight;
}
function logReset() {
  logList.innerHTML = '';
  const tail = curPts.slice(-500); tail.forEach((p, i) => logList.appendChild(logLine(p, tail[i - 1])));
  logList.scrollTop = logList.scrollHeight;
}

// ---------- 화면 전환 ----------
let mode = localStorage.getItem('loc.mode') === 'log' ? 'log' : 'map';
function setMode(m) {
  mode = m; localStorage.setItem('loc.mode', m);
  $('mapMode').hidden = m !== 'map'; $('logMode').hidden = m !== 'log';
  $('btnMode').textContent = m === 'map' ? '📝' : '🗺';
  $('btnMode').setAttribute('aria-label', m === 'map' ? '기록 화면으로' : '지도 화면으로');
  if (m === 'log') logList.scrollTop = logList.scrollHeight;
  if (m === 'map' && live && follow) map.pan(live.lat, live.lon);
}
$('btnMode').addEventListener('click', () => setMode(mode === 'map' ? 'log' : 'map'));

// ---------- 기록 시작/종료 ----------
async function startRec() {
  await requestSensors();
  const now = Date.now();
  rec = { cid: crypto.randomUUID?.() ?? `${now}-${Math.random().toString(36).slice(2)}`, name: defaultName(now), startedAt: now, nextSeq: 0, serverId: null };
  persist(); seqMap.clear(); setCur([]); recDist = 0; redrawLines(); logReset();
  keepAwake(true); render(); sync();
  // 방금 받은 GPS가 있으면 첫 점으로 사용
  if (live && tracker.mode === 'gps' && performance.now() - lastFixAt < 3000) onPoint({ ...live, seq: -1, ts: Date.now() });
}
async function stopRec() {
  if (!confirm('기록을 끝낼까요?')) return;
  pending.push({ ...rec, endedAt: Date.now() }); const name = rec.name; rec = null; persist();
  keepAwake(false); render(); sync();
  toast(`"${name}" 저장했습니다`);
}
$('btnRec').addEventListener('click', () => (rec ? stopRec() : startRec()));

// ---------- 서버 동기화 ----------
let syncing = false, syncErr = null;
const slim = (p) => ({ seq: p.seq, ts: p.ts, lat: p.lat, lon: p.lon, brk: p.brk ? 1 : undefined, alt: p.alt ?? null, acc: p.acc ?? null, spd: p.spd ?? null, hdg: p.hdg ?? null, src: p.src });
async function sync() {
  if (syncing) return; syncing = true;
  try {
    for (const j of [...pending, ...(rec ? [rec] : [])]) {
      if (!j.serverId) { const r = await api('POST', 'api/tracks', { client_id: j.cid, name: j.name, started_at: j.startedAt }); j.serverId = r.id; persist(); }
      const pts = (await getPts(j.cid)).filter(p => !p.synced).sort((a, b) => a.seq - b.seq);
      for (let i = 0; i < pts.length; i += 500) {
        const b = pts.slice(i, i + 500);
        await api('POST', `api/tracks/${j.serverId}/points`, { points: b.map(slim) });
        await markSynced(b);
      }
      if (j.endedAt) {
        if ((await getPts(j.cid)).some(p => !p.synced)) continue;   // 그 사이 보정된 점이 있으면 다음 차례에
        await api('PATCH', `api/tracks/${j.serverId}`, { ended_at: j.endedAt, ...(j.renamed ? { name: j.name } : {}) });
        await delPts(j.cid); pending = pending.filter(x => x.cid !== j.cid); persist();
      }
    }
    syncErr = null;
  } catch (e) { syncErr = e.message; } finally { syncing = false; }
}
setInterval(sync, 5000);

// ---------- 화면 갱신 ----------
function render() {
  const b = $('btnRec'); b.classList.toggle('on', !!rec); b.textContent = rec ? '■ 기록 종료' : '● 기록 시작';
  $('logIdle').hidden = !!rec; logList.hidden = !rec; $('logHead').hidden = !rec; $('logCols').hidden = !rec;
}
function tickUI() {
  const now = performance.now();
  const spd = tracker.mode === 'dr' ? tracker.speed : live && now - lastFixAt < 5000 ? live.spd : null;
  $('ovSpeed').innerHTML = `${spd == null ? '–' : Math.round(spd * 3.6)}<small>km/h</small>`;
  const moving = spd != null && spd > 1.5;
  const hdg = tracker.mode === 'dr' ? tracker.course : moving && live?.hdg != null ? live.hdg : tracker.compassHeading;
  $('ovDir').textContent = hdg == null ? '–' : dirName(hdg);
  $('dirBox').classList.toggle('g-off', hdg == null);
  if (hdg != null) {   // 359°→0°에서 바늘이 한 바퀴 돌지 않게 누적 각도로
    needleDeg += ((hdg - needleDeg) % 360 + 540) % 360 - 180;
    $('dirNeedle').style.transform = `rotate(${needleDeg}deg)`;
  }
  $('ovTime').textContent = rec ? dur(Date.now() - rec.startedAt) : '대기';
  let st;
  if (gpsErr) st = `<span class="est">${gpsErr}</span>`;
  else if (tracker.mode === 'dr') st = `<span class="est">GPS 끊김 · 센서로 이어 그리는 중 ${Math.round((now - tracker.last.perf) / 1000)}초</span>`;
  else if (tracker.mode === 'hold') st = '<span class="est">GPS 신호 약함</span>';
  else if (tracker.mode === 'gps') st = `<span class="ok">GPS</span> ±${Math.round(live?.acc ?? 0)}m`;
  else st = '위치 확인 중…';
  if (rec) st += ` · ${curPts.length.toLocaleString()}점`;
  if (syncErr) st += ` · <span class="est">업로드 대기</span>`;
  $('ovStatus').innerHTML = st;
  if (rec) {
    $('lhTime').textContent = dur(Date.now() - rec.startedAt);
    $('lhDist').textContent = (recDist / 1000).toFixed(recDist < 10000 ? 2 : 1);
    $('lhSpd').textContent = spd == null ? '–' : Math.round(spd * 3.6);
    $('lhPts').textContent = curPts.length.toLocaleString();
    $('lhStatus').innerHTML = st.replace(/ · [\d,]+점/, '');
  }
  const sensorsStale = !sensorsOn || now - lastSensorAt > 3000;
  $('sensorBanner').hidden = !(rec && sensorsStale && needsPermission);
}
let needleDeg = 0;
setInterval(tickUI, 500);

// ---------- 설정 ----------
$('btnSet').addEventListener('click', openSettings);
$('btnSetClose').addEventListener('click', () => ($('settings').hidden = true));
async function openSettings() { $('settings').hidden = false; await renderTracks(); }
async function renderTracks() {
  const box = $('trkList');
  let list = [];
  try { await sync(); list = await api('GET', 'api/tracks'); }
  catch (e) { box.innerHTML = `<div class="s-empty">목록을 못 불러왔습니다 (${e.message})</div>`; return; }
  const local = [...pending, ...(rec ? [rec] : [])].filter(j => !list.some(t => t.client_id === j.cid));
  if (!list.length && !local.length) { box.innerHTML = '<div class="s-empty">저장된 기록이 없습니다</div>'; return; }
  box.innerHTML = '';
  for (const j of local) box.appendChild(trackRow({ id: null, client_id: j.cid, name: j.name, started_at: j.startedAt, ended_at: j.endedAt, distance_m: 0, n_points: 0, n_est: 0 }, true));
  for (const t of list) box.appendChild(trackRow(t, false));
}
function trackRow(t, localOnly) {
  const isRec = rec && t.client_id === rec.cid;
  const el = document.createElement('div'); el.className = 'trk';
  const end = t.ended_at ?? (isRec ? Date.now() : null);
  const meta = [dateKo(t.started_at) + ' ' + hms(t.started_at).slice(0, 5) + (end ? '–' + hms(end).slice(0, 5) : ''),
    t.distance_m ? (t.distance_m / 1000).toFixed(1) + 'km' : null, end ? durKo(end - t.started_at) : null,
    t.n_points ? `${t.n_points.toLocaleString()}점` + (t.n_est ? ` (추정 ${t.n_est})` : '') : null].filter(Boolean).join(' · ');
  el.innerHTML = `<div class="trk-name"></div><div class="trk-meta">${meta}</div>
    <div class="trk-acts">
      <button data-a="view" ${t.id ? '' : 'disabled'}>지도</button>
      <button data-a="rename">이름 변경</button>
      <button data-a="daily" ${t.id && !isRec ? '' : 'disabled'}>${t.sent_daily_at ? '데일리요섭 보내기 취소' : '데일리요섭 보내기'}</button>
      <button data-a="del" class="del" ${isRec ? 'disabled' : ''}>삭제</button>
    </div>`;
  const nm = el.querySelector('.trk-name'); nm.textContent = t.name;
  if (isRec) nm.insertAdjacentHTML('beforeend', '<span class="badge rec">기록 중</span>');
  else if (localOnly) nm.insertAdjacentHTML('beforeend', '<span class="badge">업로드 대기</span>');
  if (t.sent_daily_at) nm.insertAdjacentHTML('beforeend', '<span class="badge sent">보냄</span>');
  el.querySelector('[data-a=view]').onclick = () => openDetail(t);
  el.querySelector('[data-a=rename]').onclick = () => {
    if (el.querySelector('.rename')) return;
    const f = document.createElement('div'); f.className = 'rename';
    f.innerHTML = '<input maxlength="200" enterkeyhint="done"><button>저장</button>';
    const inp = f.querySelector('input'); inp.value = t.name;
    const save = async () => {
      const name = inp.value.trim(); if (!name) return;
      try {
        if (t.id) await api('PATCH', `api/tracks/${t.id}`, { name });
        const j = [...pending, ...(rec ? [rec] : [])].find(x => x.cid === t.client_id);
        if (j) { j.name = name; j.renamed = true; persist(); }
        t.name = name; nm.firstChild.textContent = name; f.remove(); toast('이름을 바꿨습니다');
      } catch (e) { toast('이름 변경 실패: ' + e.message); }
    };
    f.querySelector('button').onclick = save; inp.onkeydown = (e) => { if (e.key === 'Enter') save(); };
    el.appendChild(f); inp.focus(); inp.select();
  };
  el.querySelector('[data-a=daily]').onclick = async () => {
    try {
      if (t.sent_daily_at) { await api('DELETE', `api/tracks/${t.id}/send-daily`); toast('데일리요섭에서 뺐습니다'); }
      else { await api('POST', `api/tracks/${t.id}/send-daily`); toast('데일리요섭으로 보냈습니다. 그날 지도에 실제 경로로 나옵니다'); }
      renderTracks();
    } catch (e) { toast('실패: ' + e.message); }
  };
  el.querySelector('[data-a=del]').onclick = async () => {
    if (!confirm(`"${t.name}" 기록을 삭제할까요?\n되돌릴 수 없습니다.`)) return;
    try {
      if (t.id) await api('DELETE', `api/tracks/${t.id}`);
      if (localOnly) { await delPts(t.client_id); pending = pending.filter(x => x.cid !== t.client_id); persist(); }
      el.remove(); toast('삭제했습니다');
    } catch (e) { toast('삭제 실패: ' + e.message); }
  };
  return el;
}

// 경로 보기
let dmap = null;
async function openDetail(t) {
  $('detail').hidden = false; $('detailTitle').textContent = t.name; $('detailInfo').textContent = '불러오는 중…';
  try {
    const d = await api('GET', `api/tracks/${t.id}`);
    dmap?.destroy(); $('detailMap').innerHTML = '';
    dmap = await createMap($('detailMap'), { naverKey: cfg.naver_map_key, lat: d.points[0]?.lat, lon: d.points[0]?.lon, zoom: 14, pts: d.points });
    for (const s of segments(d.points)) dmap.line({ color: COLOR[s.src], dashed: s.src === 'imu' }).set(s.pts);
    if (d.points.length) setTimeout(() => dmap.fit(d.points), 50);
    const end = d.ended_at ?? d.points.at(-1)?.ts ?? d.started_at;
    $('detailInfo').innerHTML = `${dateKo(d.started_at)} ${hms(d.started_at).slice(0, 5)}–${hms(end).slice(0, 5)} · ${(d.distance_m / 1000).toFixed(2)}km · ${durKo(end - d.started_at)} · ${d.n_points.toLocaleString()}점`
      + (d.n_est ? ` · <span style="color:var(--est)">점선 = GPS 끊김 구간 추정 ${d.n_est}점</span>` : '');
  } catch (e) { $('detailInfo').textContent = '불러오기 실패: ' + e.message; }
}
$('btnDetailClose').addEventListener('click', () => { $('detail').hidden = true; dmap?.destroy(); dmap = null; });

// ---------- 시작 ----------
if (rec) {   // 새로고침·앱 재실행: 기록 이어가기
  setCur(await getPts(rec.cid)); calcDist(); redrawLines(); logReset(); keepAwake(true);
  if (curPts.length) { const l = curPts.at(-1); map.center(l.lat, l.lon, 16); centered = true; }
}
setMode(mode); render(); tickUI(); sync(); startGps();
window.__loc = { tracker, get rec() { return rec; }, get pts() { return curPts; }, map, onPoint, sync };
