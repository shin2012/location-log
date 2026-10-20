// 지도 어댑터: 네이버 지도(기본) → 실패 시 Leaflet + 오픈스트리트맵
// 사용: const m = await createMap(el, {lat, lon, zoom}); const line = m.line({color, dashed}); line.set(pts); m.marker().set(lat, lon, hdg)
let naverLoading = null, leafletLoading = null;

function loadScript(src, timeoutMs) {
  return new Promise((ok, fail) => {
    const s = document.createElement('script'); s.src = src; s.async = true;
    const t = setTimeout(() => fail(new Error('timeout')), timeoutMs);
    s.onload = () => { clearTimeout(t); ok(); }; s.onerror = () => { clearTimeout(t); fail(new Error('load')); };
    document.head.appendChild(s);
  });
}
function loadNaver(key) {
  if (!key) return Promise.reject(new Error('no key'));
  if (window.naver?.maps) return Promise.resolve();
  naverLoading ||= loadScript(`https://oapi.map.naver.com/openapi/v3/maps.js?ncpKeyId=${encodeURIComponent(key)}`, 5000);
  return naverLoading;
}
function loadLeaflet() {
  if (window.L) return Promise.resolve();
  if (!leafletLoading) {
    const css = document.createElement('link'); css.rel = 'stylesheet'; css.href = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css';
    const cssReady = new Promise(ok => { css.onload = ok; css.onerror = ok; setTimeout(ok, 4000); });
    document.head.appendChild(css);
    leafletLoading = Promise.all([loadScript('https://unpkg.com/leaflet@1.9.4/dist/leaflet.js', 8000), cssReady]);
  }
  return leafletLoading;
}

const arrowHtml = (hdg) => `<div class="me"><div class="me-dot"></div>${hdg == null ? '' : `<div class="me-arrow" style="transform:rotate(${hdg}deg)"></div>`}</div>`;

// ---------- 엔진별 구현 ----------
function naverEngine(el, c) {
  const N = naver.maps;
  const map = new N.Map(el, { center: new N.LatLng(c.lat, c.lon), zoom: c.zoom ?? 16, scaleControl: false, mapDataControl: false,
    logoControlOptions: { position: N.Position.BOTTOM_LEFT }, zoomControl: false });
  const ll = (p) => new N.LatLng(p.lat, p.lon);
  return {
    kind: 'naver', raw: map,
    center(lat, lon, zoom) { map.setCenter(new N.LatLng(lat, lon)); if (zoom) map.setZoom(zoom); },
    pan(lat, lon) { map.panTo(new N.LatLng(lat, lon), { duration: 300 }); },
    fit(pts) {
      if (!pts.length) return;
      const b = new N.LatLngBounds(ll(pts[0]), ll(pts[0])); pts.forEach(p => b.extend(ll(p)));
      map.fitBounds(b, { top: 40, right: 40, bottom: 40, left: 40 });
    },
    line({ color, dashed, weight = 5 }) {
      const pl = new N.Polyline({ map, path: [], strokeColor: color, strokeWeight: weight, strokeOpacity: 0.9,
        strokeStyle: dashed ? 'shortdash' : 'solid', strokeLineCap: 'round', strokeLineJoin: 'round' });
      return { set(pts) { pl.setPath(pts.map(ll)); }, remove() { pl.setMap(null); } };
    },
    marker() {
      let mk = null;
      return {
        set(lat, lon, hdg) {
          const icon = { content: arrowHtml(hdg), anchor: new N.Point(20, 20) };
          if (!mk) mk = new N.Marker({ map, position: new N.LatLng(lat, lon), icon, zIndex: 100 });
          else { mk.setPosition(new N.LatLng(lat, lon)); mk.setIcon(icon); }
        },
        remove() { mk?.setMap(null); mk = null; },
      };
    },
    onDrag(fn) { N.Event.addListener(map, 'dragstart', fn); },
    destroy() { map.destroy(); },
  };
}

function leafletEngine(el, c) {
  const map = L.map(el, { zoomControl: false, attributionControl: true }).setView([c.lat, c.lon], c.zoom ?? 16);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(map);
  setTimeout(() => map.invalidateSize(), 100); setTimeout(() => map.invalidateSize(), 600);
  return {
    kind: 'leaflet', raw: map,
    center(lat, lon, zoom) { map.setView([lat, lon], zoom ?? map.getZoom()); },
    pan(lat, lon) { map.panTo([lat, lon], { animate: true, duration: 0.3 }); },
    fit(pts) { if (pts.length) map.fitBounds(pts.map(p => [p.lat, p.lon]), { padding: [40, 40] }); },
    line({ color, dashed, weight = 5 }) {
      const pl = L.polyline([], { color, weight, opacity: 0.9, dashArray: dashed ? '6 8' : null, lineCap: 'round' }).addTo(map);
      return { set(pts) { pl.setLatLngs(pts.map(p => [p.lat, p.lon])); }, remove() { pl.remove(); } };
    },
    marker() {
      let mk = null;
      return {
        set(lat, lon, hdg) {
          const icon = L.divIcon({ html: arrowHtml(hdg), className: '', iconSize: [40, 40], iconAnchor: [20, 20] });
          if (!mk) mk = L.marker([lat, lon], { icon, zIndexOffset: 1000 }).addTo(map);
          else { mk.setLatLng([lat, lon]); mk.setIcon(icon); }
        },
        remove() { mk?.remove(); mk = null; },
      };
    },
    onDrag(fn) { map.on('dragstart', fn); },
    destroy() { map.remove(); },
  };
}

// ---------- 공개 API: 엔진이 바뀌어도(인증 실패 → Leaflet) 선·표시를 다시 그려주는 래퍼 ----------
export async function createMap(el, { lat = 37.5665, lon = 126.978, zoom = 16, naverKey = '' } = {}) {
  const lines = new Set(), markers = new Set(), dragFns = [];
  let eng = null, view = { lat, lon, zoom };
  const build = (kind) => {
    if (eng) { try { eng.destroy(); } catch {} el.innerHTML = ''; el.removeAttribute('style'); el.className = el.className.replace(/\bleaflet-\S+/g, ''); }
    eng = kind === 'naver' ? naverEngine(el, view) : leafletEngine(el, view);
    dragFns.forEach(f => eng.onDrag(f));
    lines.forEach(l => { l.impl = eng.line(l.opt); l.impl.set(l.pts); });
    markers.forEach(m => { m.impl = eng.marker(); if (m.pos) m.impl.set(...m.pos); });
    api.kind = eng.kind;
  };
  const toLeaflet = async () => { await loadLeaflet(); build('leaflet'); };
  const api = {
    kind: null,
    center(lat, lon, zoom) { view = { lat, lon, zoom: zoom ?? view.zoom }; eng.center(lat, lon, zoom); },
    pan(lat, lon) { view.lat = lat; view.lon = lon; eng.pan(lat, lon); },
    fit(pts) { eng.fit(pts); },
    line(opt) {
      const l = { opt, pts: [], impl: eng.line(opt) }; lines.add(l);
      return { set(pts) { l.pts = pts; l.impl.set(pts); }, remove() { l.impl.remove(); lines.delete(l); } };
    },
    marker() {
      const m = { pos: null, impl: eng.marker() }; markers.add(m);
      return { set(lat, lon, hdg) { m.pos = [lat, lon, hdg]; m.impl.set(lat, lon, hdg); }, remove() { m.impl.remove(); markers.delete(m); } };
    },
    onDrag(fn) { dragFns.push(fn); eng.onDrag(fn); },
    destroy() { eng?.destroy(); },
  };
  api.toLeaflet = toLeaflet;
  try {
    await loadNaver(naverKey);
    (window.__mkFail ||= new Set()).add(() => { if (api.kind === 'naver') toLeaflet(); });
    window.navermap_authFailure = () => { window.naverAuthFailed = true; window.__mkFail.forEach(f => f()); };
    if (window.naverAuthFailed) throw new Error('auth');
    build('naver');
  } catch {
    await toLeaflet();
  }
  return api;
}
