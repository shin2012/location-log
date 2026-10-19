// 합성 데이터로 궤적 알고리즘 시험: node tools/sim.mjs
import { Nav, PRESETS, quatFromOrientation, rotate, V } from '../public/nav.js';

function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32); }
function gauss(r) { return Math.sqrt(-2 * Math.log(r() + 1e-12)) * Math.cos(2 * Math.PI * r()); }

// handPos(t) → 월드 위치(m). car: 진동·차량 가감속 포함 여부
export function run(preset, { T = 30, car = false, hand = null, seed = 1, trace = false, params = null } = {}) {
  const r = rng(seed), nav = new Nav(params || PRESETS[preset]);
  const ori = [10, 65, -5]; nav.orientation(...ori);
  const q = quatFromOrientation(0, ori[1], ori[2]);
  const qi = [-q[0], -q[1], -q[2], q[3]];
  const fs = 60, n = Math.round(T * fs);
  const ph = Array.from({ length: 6 }, () => r() * 6.28);
  let maxErr = 0, endErr = 0, ts = 0;
  const hp = (t) => hand ? hand(t) : [0, 0, 0];
  const acc = (t) => { const h = 1e-3, a = hp(t - h), b = hp(t), c = hp(t + h); return [0, 1, 2].map(i => (a[i] - 2 * b[i] + c[i]) / (h * h)); };
  for (let i = 0; i < n; i++) {
    ts += 1000 / fs * (1 + (r() - 0.5) * 0.1);
    const t = ts / 1000;
    let [ax, ay, az] = acc(t);
    // 센서 잡음 + 고정 치우침
    ax += gauss(r) * 0.03 + 0.02; ay += gauss(r) * 0.03 - 0.015; az += gauss(r) * 0.03 + 0.01;
    if (car) {
      // 노면·엔진 진동 (12/18/23Hz + 60Hz 샘플링에 접힌 성분), 수직이 가장 큼
      const vib = (f, A, p) => A * Math.sin(2 * Math.PI * f * t + p);
      ay += vib(12, 1.2, ph[0]) + vib(23, 0.8, ph[1]) + vib(18.5, 0.6, ph[2]) + gauss(r) * 0.5;
      ax += vib(14, 0.5, ph[3]) + gauss(r) * 0.3;
      az += vib(17, 0.6, ph[4]) + gauss(r) * 0.35;
      // 차량 가감속·커브 (저주파)
      az += -1.5 * Math.sin(2 * Math.PI * 0.08 * t) * (t > 3 ? 1 : 0);
      ax += 1.0 * Math.sin(2 * Math.PI * 0.05 * t + 1) * (t > 3 ? 1 : 0);
      // 과속방지턱
      if (t % 9 > 6 && t % 9 < 6.3) ay += 4 * Math.sin((t % 9 - 6) / 0.3 * Math.PI * 2);
    }
    // 월드 → 기기 좌표 (iOS 부호 반전 재현)
    const d = rotate(qi, ax, ay, az, new V());
    const g = rotate(qi, 0, 9.81, 0, new V());
    nav.orientation(...ori);
    nav.motion(ts, { x: -d.x, y: -d.y, z: -d.z }, { x: -(d.x + g.x), y: -(d.y + g.y), z: -(d.z + g.z) },
      { alpha: car ? gauss(r) * 3 : gauss(r) * 0.5, beta: car ? gauss(r) * 3 : 0, gamma: 0 });
    const tp = hp(t), e = Math.hypot(nav.pos.x - tp[0], nav.pos.y - tp[1], nav.pos.z - tp[2]);
    if (t > 1) maxErr = Math.max(maxErr, e); endErr = e;
    if (trace && i % 15 == 0) console.log(t.toFixed(2), nav.still ? 'S' : 'M', 'std', nav.std.toFixed(2), 'thr', nav.thr.toFixed(2), 'true', tp.map(v => v.toFixed(2)).join(','), 'est', [nav.pos.x, nav.pos.y, nav.pos.z].map(v => v.toFixed(2)).join(','));
  }
  return { preset, car, hand: !!hand, endErr: +endErr.toFixed(3), maxErr: +maxErr.toFixed(3), dist: +nav.dist.toFixed(2), sign: nav.sign };
}

// 손동작: 3초 대기 후 0.8Hz 원(반지름 0.25m) 2바퀴, 정지 상태에서 출발·도착
const circle = (t) => {
  const t0 = 4, dur = 2.5; if (t < t0) return [0, 0, 0];
  const u = Math.min((t - t0) / dur, 1), s = (1 - Math.cos(Math.PI * u)) / 2;   // 부드러운 출발·정지
  const th = s * 4 * Math.PI, R = 0.25;
  return [R * (1 - Math.cos(th)), 0.05 * Math.sin(th), -R * Math.sin(th)];
};
export { circle };
if (process.argv[2] === 'x') { /* sweep에서 import */ } else if (process.argv[2] === 'trace') { run('vehicle', { car: true, hand: circle, T: 10, trace: true }); process.exit(0); }
const rows = [];
if (process.argv[2] !== 'x') for (const preset of ['normal', 'vehicle']) {
  for (const seed of [1, 2, 3]) {
    rows.push({ seed, ...run(preset, { car: true, seed }) });
    rows.push({ seed, ...run(preset, { car: true, hand: circle, T: 10, seed }) });
    rows.push({ seed, ...run(preset, { car: false, hand: circle, T: 10, seed }) });
  }
}
if (rows.length) console.table(rows);
