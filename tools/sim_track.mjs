// 터널(GPS 끊김) 구간 추정 시험: node tools/sim_track.mjs
import { Tracker, dist } from '../public/track.js';
import { quatFromOrientation, rotate, V } from '../public/nav.js';

function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32); }
function gauss(r) { return Math.sqrt(-2 * Math.log(r() + 1e-12)) * Math.cos(2 * Math.PI * r()); }
const D = Math.PI / 180, R_E = 6371008.8;

// 구간: [길이 s, 가속 m/s², 회전 °/s]
const PLAN = [[8, 0, 0], [10, 2.2, 0], [30, 0, 0], [15, 0, 1.5], [20, 0, 0], [25, 0, -1.2], [10, -0.4, 0], [25, 0, 0], [8, 0, 2], [20, 0, 0]];
let DBGX;
function run({ seed = 1, tunnel = [60, 130], M = 20, Frel = 73, compassBias = 30, accBias = 0.06, hand = false } = {}) {
  const r = rng(seed), fs = 60, dt = 1 / fs;
  const pts = [], corr = { n: 0 }, store = new Map();
  const tr = new Tracker({ onPoint: p => store.set(p.seq, p), onCorrect: (list, info) => { list.forEach(p => store.set(p.seq, p)); Object.assign(corr, info); } });
  let e = 0, n = 0, v = 0, course = 35, t = 0;
  const lat0 = 37.5, lon0 = 127.0;
  const truth = [];
  for (const [T, acc, w] of PLAN) for (let k = 0; k < T * fs; k++) {
    t += dt; const vPrev = v, cPrev = course;
    v = Math.max(0, v + acc * dt); course += w * dt;
    e += v * Math.sin(course * D) * dt; n += v * Math.cos(course * D) * dt;
    const at = (v - vPrev) / dt, an = v * ((course - cPrev) * D) / dt;   // 진행·구심 가속
    const aE = at * Math.sin(course * D) + an * Math.cos(course * D), aN = at * Math.cos(course * D) - an * Math.sin(course * D);
    const perf = t * 1000;
    truth.push({ perf, e, n });
    // 폰 자세: 세워서 거치(pitch 70°), 상대 방위 = 진북 방위 − Frel
    const phoneTrue = course - M + (hand ? 8 * Math.sin(t * 0.7) : 0), yawRel = phoneTrue - Frel;
    const alpha = -yawRel, beta = 70 + gauss(r) * 0.3, gamma = gauss(r) * 0.3;
    const q = quatFromOrientation(alpha, beta, gamma), qi = [-q[0], -q[1], -q[2], q[3]];
    const inT = t > tunnel[0] && t < tunnel[1];
    const cb = inT && t > (tunnel[0] + tunnel[1]) / 2 ? compassBias : 0;
    tr.orientation(perf, alpha, beta, gamma, ((phoneTrue + 8.8 + cb + gauss(r) * 4) % 360 + 360) % 360, 10);
    // 월드 가속도(상대 좌표, three: x=동, z=−북) → 기기 좌표, iOS 부호
    const az = (Math.atan2(aE, aN) / D) - Frel, am = Math.hypot(aE, aN);
    let wx = am * Math.sin(az * D), wz = -am * Math.cos(az * D), wy = 0;
    wx += gauss(r) * 0.25 + 0.5 * Math.sin(2 * Math.PI * 13 * t) + accBias; wz += gauss(r) * 0.25 - accBias; wy += gauss(r) * 0.5 + Math.sin(2 * Math.PI * 11 * t);
    const d = rotate(qi, wx, wy, wz, new V()), g = rotate(qi, 0, 9.81, 0, new V());
    tr.motion(perf, { x: -d.x, y: -d.y, z: -d.z }, { x: -(d.x + g.x), y: -(d.y + g.y), z: -(d.z + g.z) }, { alpha: 0, beta: 0, gamma: 0 });
    if (k % 60 === 0) {
      const ge = e + gauss(r) * 3, gn = n + gauss(r) * 3;
      const fix = { perf, epoch: 1.7e12 + perf, lat: lat0 + gn / R_E / D, lon: lon0 + ge / (R_E * Math.cos(lat0 * D)) / D, acc: 5,
        speed: v + gauss(r) * 0.3, heading: v > 1 ? ((course + gauss(r) * 2) % 360 + 360) % 360 : -1 };
      if (!inT) tr.gps(fix);
      else if (r() < 0.3) tr.gps({ ...fix, acc: 80 + r() * 100, lat: fix.lat + gauss(r) * 0.0005 });   // 터널 안 엉터리 값
    }
    if (k % 15 === 0) tr.tick(perf);
    if (DBG && k % 300 === 0 && tr.dr) console.log(t.toFixed(0), 'v', v.toFixed(1), tr.dr.v.toFixed(1), 'course', course.toFixed(1), tr.dr.course.toFixed(1), 'pos', e.toFixed(0), n.toFixed(0), (tr.dr.pos.e + (tr.toEN(tr.dr.lat0, tr.dr.lon0, {lat0, lon0}).e)).toFixed(0), (tr.dr.pos.n + tr.toEN(tr.dr.lat0, tr.dr.lon0, {lat0, lon0}).n).toFixed(0), 'F', tr.F?.toFixed(1), 'm', tr.m?.toFixed(1), 'bias', tr.longBias.toFixed(3));
  }
  // 평가: 추정점(imu) 위치를 같은 시각의 실제 위치와 비교
  const tr0 = truth;
  const at = (perf) => tr0[Math.min(tr0.length - 1, Math.round(perf / (1000 / fs)) - 1)];
  const toEN = (p) => ({ e: (p.lon - lon0) * D * R_E * Math.cos(lat0 * D), n: (p.lat - lat0) * D * R_E });
  const imu = [...store.values()].filter(p => p.src === 'imu');
  let se = 0, mx = 0;
  for (const p of imu) { const q = toEN(p), tt = at(p.ts - 1.7e12); const er = Math.hypot(q.e - tt.e, q.n - tt.n); se += er * er; mx = Math.max(mx, er); }
  return { seed, M, compassBias, accBias, hand, tunnelS: tunnel[1] - tunnel[0], imuPts: imu.length,
    exitErrBefore: +(corr.errM ?? NaN).toFixed(1), tunnelLenM: +(imu.length * 20).toFixed(0),
    rmsAfter: +Math.sqrt(se / imu.length).toFixed(1), maxAfter: +mx.toFixed(1), total: store.size };
}
const DBG = process.argv[2] === 'dbg';
if (DBG) { run({ seed: 1 }); process.exit(0); }
const rows = [];
for (const seed of [1, 2, 3]) rows.push(run({ seed }));
rows.push(run({ seed: 4, M: 0, compassBias: 0 }));
rows.push(run({ seed: 5, accBias: 0.15 }));
rows.push(run({ seed: 6, tunnel: [50, 170] }));
rows.push(run({ seed: 7, hand: true }));
console.table(rows);
