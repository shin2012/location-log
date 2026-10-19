// 아이폰에서 녹화한 센서 로그를 궤적 알고리즘에 다시 넣어보기
// 사용: node tools/replay.mjs logs/<파일>.json [normal|vehicle] [key=value ...]  (gps=0 이면 GPS 행 무시)
import { readFileSync } from 'node:fs';
import { Nav, PRESETS } from '../public/nav.js';

const [file, preset = 'vehicle', ...kv] = process.argv.slice(2);
if (!file) { console.error('사용: node tools/replay.mjs <로그.json> [normal|vehicle] [lpHz=5 ...]'); process.exit(1); }
const params = { ...PRESETS[preset] };
for (const s of kv) { const [k, v] = s.split('='); params[k] = v === 'true' ? true : v === 'false' ? false : Number(v); }

const log = JSON.parse(readFileSync(file, 'utf8'));
const nav = new Nav(params);
const useGps = log.rows.some(r => r[0] === 'g') && params.gps !== 0;
if (useGps) nav.setGps(true);
let still = 0, moving = 0, n = 0, corr = 0;
const t0 = log.rows.find(r => r[0] === 'm')?.[1] ?? 0;
for (const r of log.rows) {
  if (r[0] === 'o') { nav.orientation(r[2], r[3], r[4], r[5], r[6]); continue; }
  if (r[0] === 'g') { const [, ts, lat, lon, alt, acc, altAcc, speed, heading] = r; nav.gps({ ts, lat, lon, alt, acc, altAcc, speed, heading }); continue; }
  const [, ts, ax, ay, az, gx, gy, gz, ra, rb, rg] = r;
  const res = nav.motion(ts, { x: ax, y: ay, z: az }, { x: gx, y: gy, z: gz }, { alpha: ra, beta: rb, gamma: rg });
  if (res === 2) corr++;
  n++; nav.still ? still++ : moving++;
  if (n % 60 === 0) console.log(((ts - t0) / 1000).toFixed(1).padStart(6), nav.still ? '정지' : '이동',
    `흔들림 ${nav.std.toFixed(2)} 진동 ${nav.noise.toFixed(2)} 기준 ${nav.thr.toFixed(2)}`,
    `위치 ${[nav.pos.x, nav.pos.y, nav.pos.z].map(v => v.toFixed(2)).join(',')}`);
}
console.log({ file, preset, gps: useGps, yawCorr: nav.yawCorr && +nav.yawCorr.toFixed(1), gpsFixes: nav.gpsN, samples: n, stillRatio: +(still / n).toFixed(2), corrections: corr,
  final: [nav.pos.x, nav.pos.y, nav.pos.z].map(v => +v.toFixed(3)), dist: +nav.dist.toFixed(2), sign: nav.sign, fs: +nav.fs.toFixed(1) });
