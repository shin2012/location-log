// 합성 주행 데이터로 GPS+IMU 융합 시험: node tools/sim_gps.mjs
import { Nav, PRESETS, quatFromOrientation, rotate, V } from '../public/nav.js';

function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32); }
function gauss(r) { return Math.sqrt(-2 * Math.log(r() + 1e-12)) * Math.cos(2 * Math.PI * r()); }

// 주행 경로: 정지 5s → 가속 → 정속 → 90° 좌회전 → 정속 → 감속 정지 → 정지
function makeDrive(dt) {
  const segs = [[5, 0, 0], [7, 2, 0], [10, 0, 0], [8, 0, Math.PI / 2 / 8], [10, 0, 0], [7, -2, 0], [6, 0, 0]];
  let x = 0, z = 0, v = 0, h = 0; const out = [];
  for (const [T, acc, w] of segs) for (let t = 0; t < T; t += dt) {
    const vPrev = v, hPrev = h;
    v = Math.max(0, v + acc * dt); h += w * (v > 0 ? 1 : 0) * dt;
    x += v * Math.sin(h) * dt; z += -v * Math.cos(h) * dt;
    // 월드 가속도 = 진행 방향 가속 + 구심 가속
    const at = (v - vPrev) / dt, an = v * (h - hPrev) / dt;
    out.push({ x, z, v, h, ax: at * Math.sin(h) + an * Math.cos(h), az: -at * Math.cos(h) + an * Math.sin(h) });
  }
  return out;
}

function run(seed, preset = 'vehicle', useGps = true) {
  const r = rng(seed), dt = 1 / 60, drive = makeDrive(dt);
  const nav = new Nav(PRESETS[preset]); nav.setGps(useGps);
  const ori = [0, 70, 0], q = quatFromOrientation(...ori), qi = [-q[0], -q[1], -q[2], q[3]];
  let gb = [0, 0], se = 0, n = 0, seRaw = 0, last = null, maxE = 0;
  const ph = [r() * 6, r() * 6];
  drive.forEach((s, i) => {
    const ts = i * dt * 1000, t = i * dt;
    let ax = s.ax + gauss(r) * 0.3 + 0.05, ay = gauss(r) * 0.5 + 1.0 * Math.sin(2 * Math.PI * 12 * t + ph[0]) * (s.v > 0 ? 1 : 0.2), az = s.az + gauss(r) * 0.3 - 0.04;
    ax += 0.5 * Math.sin(2 * Math.PI * 14 * t + ph[1]) * (s.v > 0 ? 1 : 0.2);
    const d = rotate(qi, ax, ay, az, new V()), g = rotate(qi, 0, 9.81, 0, new V());
    nav.orientation(...ori);
    nav.motion(ts, { x: -d.x, y: -d.y, z: -d.z }, { x: -(d.x + g.x), y: -(d.y + g.y), z: -(d.z + g.z) }, { alpha: gauss(r) * 2, beta: gauss(r) * 2, gamma: 0 });
    if (i % 60 === 30) {   // 1Hz GPS, 느리게 변하는 치우침 + 잡음
      gb = gb.map(b => b * 0.95 + gauss(r) * 0.4);
      const ex = s.x + gb[0] + gauss(r) * 3, ez = s.z + gb[1] + gauss(r) * 3;
      const lat0 = 37.5, lon0 = 127, D = Math.PI / 180;
      nav.gps({ ts, lat: lat0 + (-ez) / 6378137 / D, lon: lon0 + ex / (6378137 * Math.cos(lat0 * D)) / D, alt: 30 + gauss(r) * 5, acc: 5, altAcc: 8,
        speed: Math.max(0, s.v + gauss(r) * 0.3), heading: s.v > 1 ? ((s.h / D + gauss(r) * 3) % 360 + 360) % 360 : NaN });
      last = [ex, ez];
    }
    if (last && i > 120) {
      const e = Math.hypot(nav.pos.x - s.x, nav.pos.z - s.z); se += e * e; n++; maxE = Math.max(maxE, e);
      const eRaw = Math.hypot(last[0] - s.x, last[1] - s.z); seRaw += eRaw * eRaw;
    }
  });
  return { seed, preset, rmsFusion: +Math.sqrt(se / n).toFixed(2), maxFusion: +maxE.toFixed(2), rmsGpsOnly: +Math.sqrt(seRaw / n).toFixed(2), endPos: [nav.pos.x, nav.pos.z].map(v => +v.toFixed(1)), truthEnd: [drive.at(-1).x, drive.at(-1).z].map(v => +v.toFixed(1)) };
}
console.table([1, 2, 3].flatMap(s => [run(s, 'vehicle'), run(s, 'normal')]));
