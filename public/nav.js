// 가속도 2중 적분 궤적 계산 — 브라우저와 Node(재생 시험) 공용, 외부 의존성 없음
// 좌표: three.js 기준 (X=오른쪽, Y=위, -Z=앞). 기기 자세는 deviceorientation(alpha/beta/gamma).

export const PRESETS = {
  // 손에 들고 실내에서 움직일 때
  normal:  { lpHz: 10, baseTau: 0, velTau: 3.0, dead: 0.04, stillAcc: 0.18, stillK: 0,   accGate: 1.5, stillGyro: 10, stillFrames: 8,  baseRate: 0.05, segFix: true },
  // 차량·대중교통 안: 진동(고주파)과 차량 자체 가감속(저주파)을 걸러냄
  // baseTau: 움직이는 동안 기준선이 따라가는 시간(초, 0=고정), baseRate: 정지 중 기준선 학습 속도
  // accGate: 정지 판정 시 가속도 크기 조건 배수(0=사용 안 함 — 차량은 지속 가감속이 있어 크기 대신 흔들림만 봄)
  vehicle: { lpHz: 5,  baseTau: 0,   velTau: 1.2, dead: 0.10, stillAcc: 0.12, stillK: 2.5, accGate: 0,   stillGyro: 40, stillFrames: 12, baseRate: 0.2, segFix: true },
};

export class V {
  constructor(x = 0, y = 0, z = 0) { this.x = x; this.y = y; this.z = z; }
  set(x, y, z) { this.x = x; this.y = y; this.z = z; return this; }
  copy(v) { this.x = v.x; this.y = v.y; this.z = v.z; return this; }
  length() { return Math.hypot(this.x, this.y, this.z); }
}

const D = Math.PI / 180;
function qmul(a, b) {   // [x,y,z,w]
  return [
    a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
    a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
    a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
    a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
  ];
}
const qaxis = (ax, ang) => { const s = Math.sin(ang / 2); return [ax[0] * s, ax[1] * s, ax[2] * s, Math.cos(ang / 2)]; };
const Q_EARTH = qaxis([1, 0, 0], -Math.PI / 2);
export function quatFromOrientation(alpha, beta, gamma) {   // = three: Euler(beta, gamma, alpha, 'ZXY') 후 Q_EARTH 앞곱
  const q = qmul(qmul(qaxis([0, 0, 1], alpha * D), qaxis([1, 0, 0], beta * D)), qaxis([0, 1, 0], gamma * D));
  return qmul(Q_EARTH, q);
}
export function rotate(q, x, y, z, out) {
  const [qx, qy, qz, qw] = q;
  const tx = 2 * (qy * z - qz * y), ty = 2 * (qz * x - qx * z), tz = 2 * (qx * y - qy * x);
  return out.set(x + qw * tx + qy * tz - qz * ty, y + qw * ty + qz * tx - qx * tz, z + qw * tz + qx * ty - qy * tx);
}

// 2차 버터워스 저역 통과 (축별)
class LP2 {
  constructor() { this.fs = 0; this.fc = 0; this.s = [[0, 0], [0, 0], [0, 0]]; this.init = false; }
  design(fc, fs) {
    if (Math.abs(fc - this.fc) < 1e-9 && Math.abs(fs - this.fs) < 0.5) return;
    this.fc = fc; this.fs = fs;
    const f = Math.min(fc, fs * 0.45), w = 2 * Math.PI * f / fs, c = Math.cos(w), al = Math.sin(w) / (2 * Math.SQRT1_2), a0 = 1 + al;
    this.b0 = (1 - c) / 2 / a0; this.b1 = (1 - c) / a0; this.b2 = this.b0; this.a1 = -2 * c / a0; this.a2 = (1 - al) / a0;
  }
  step(v, out) {   // 직접형 II 전치
    const r = [v.x, v.y, v.z];
    if (!this.init) { // 첫 값으로 상태 채워 출발 시 튐 방지
      for (let i = 0; i < 3; i++) { const y = r[i]; this.s[i][1] = this.b2 * y - this.a2 * y; this.s[i][0] = this.b1 * y - this.a1 * y + this.s[i][1]; }
      this.init = true;
    }
    for (let i = 0; i < 3; i++) {
      const x = r[i], s = this.s[i], y = this.b0 * x + s[0];
      s[0] = this.b1 * x - this.a1 * y + s[1]; s[1] = this.b2 * x - this.a2 * y; r[i] = y;
    }
    return out.set(r[0], r[1], r[2]);
  }
}

// 축 하나(위치·속도·가속도 치우침)의 칼만 필터. 입력: 월드 가속도, 관측: GPS 위치/속도, 정지(속도 0)
export class KF1 {
  constructor() { this.reset(); }
  reset(p = 0, v = 0) { this.x = [p, v, 0]; this.P = [[100, 0, 0], [0, 4, 0], [0, 0, 0.3]]; }
  predict(a, dt, qa, qb) {
    const [p, v, b] = this.x, ab = a - b;
    this.x = [p + v * dt + 0.5 * ab * dt * dt, v + ab * dt, b];
    const F = [[1, dt, -0.5 * dt * dt], [0, 1, -dt], [0, 0, 1]], P = this.P;
    const FP = F.map(r => [0, 1, 2].map(j => r[0] * P[0][j] + r[1] * P[1][j] + r[2] * P[2][j]));
    const N = FP.map(r => [0, 1, 2].map(j => r[0] * F[j][0] + r[1] * F[j][1] + r[2] * F[j][2]));
    const g = [0.5 * dt * dt, dt, 0];
    for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) N[i][j] += g[i] * g[j] * qa * qa;
    N[2][2] += qb * qb * dt;
    this.P = N;
  }
  update(i, z, R) {   // i: 0=위치, 1=속도 관측
    const P = this.P, S = P[i][i] + R, y = z - this.x[i];
    const K = [P[0][i] / S, P[1][i] / S, P[2][i] / S];
    for (let r = 0; r < 3; r++) this.x[r] += K[r] * y;
    const Pi = P[i].slice();
    for (let r = 0; r < 3; r++) for (let c = 0; c < 3; c++) P[r][c] -= K[r] * Pi[c];
    return y;
  }
}

const EARTH_R = 6378137;

export class Nav {
  constructor(params = PRESETS.normal) {
    this.p = { ...params };
    this.q = null; this.alphaOffset = null; this.lastOri = null;
    this.sign = 1; this.signAcc = 0; this.nSign = 0;
    this.fix = true; this.rec = true;
    this.lp = new LP2();
    this.fs = 60;
    // GPS·나침반 융합
    this.gpsOn = false; this.compassOn = false; this.kf = [new KF1(), new KF1(), new KF1()];
    this.origin = null; this.gpsSpeed = null; this.gpsT = -1e9; this.gpsFixT = -1e9; this.gpsAcc = null; this.gpsN = 0;
    this.yawCorr = null; this.heading = null; this.headingAcc = null; this.declination = 0;
    this.reset();
  }
  setGps(on) {
    this.gpsOn = on; this.compassOn = on; this.origin = null; this.yawCorr = null; this.gpsN = 0;
    this.kf.forEach(k => k.reset());
    if (this.lastOri) this.orientation(...this.lastOri);
  }
  // 위치 고정점: {ts(ms, performance 기준), lat, lon, alt, acc, altAcc, speed(m/s), heading(°, 진북)}
  gps(f) {
    if (!this.gpsOn || f.lat == null) return;
    if (!this.origin) {
      this.origin = { lat: f.lat, lon: f.lon, alt: f.alt ?? 0 };
      // 한국 부근 자북 편차 약 서편 8.8° (나침반은 자북 기준, GPS는 진북 기준)
      this.declination = (f.lat > 32 && f.lat < 40 && f.lon > 123 && f.lon < 133) ? -8.8 : 0;
      this.kf.forEach(k => k.reset()); this.pos.set(0, 0, 0);
    }
    const o = this.origin, D2 = Math.PI / 180;
    const e = (f.lon - o.lon) * D2 * EARTH_R * Math.cos(o.lat * D2), n = (f.lat - o.lat) * D2 * EARTH_R;
    const r = Math.max(f.acc || 15, 3) ** 2;
    this.kf[0].update(0, e, r); this.kf[2].update(0, -n, r);
    if (f.alt != null && f.altAcc > 0) this.kf[1].update(0, f.alt - o.alt, Math.max(f.altAcc, 3) ** 2);
    if (f.speed != null && f.speed >= 0) {
      this.gpsSpeed = f.speed; this.gpsT = f.ts;
      if (f.heading != null && !Number.isNaN(f.heading) && f.speed > 1) {
        const h = f.heading * D2, rv = 0.4 ** 2;
        this.kf[0].update(1, f.speed * Math.sin(h), rv); this.kf[2].update(1, -f.speed * Math.cos(h), rv);
      } else if (f.speed < 0.3) { this.kf[0].update(1, 0, 0.3 ** 2); this.kf[2].update(1, 0, 0.3 ** 2); }
    }
    this.gpsAcc = f.acc; this.gpsN++; this.gpsFixT = f.ts;
    this.syncFromKf();
  }
  syncFromKf() {
    const k = this.kf, ox = this.pos.x, oy = this.pos.y, oz = this.pos.z;
    this.pos.set(k[0].x[0], k[1].x[0], k[2].x[0]); this.vel.set(k[0].x[1], k[1].x[1], k[2].x[1]);
    this.dist += Math.hypot(this.pos.x - ox, this.pos.y - oy, this.pos.z - oz);
    this.maxDisp = Math.max(this.maxDisp, Math.abs(this.pos.x), Math.abs(this.pos.y), Math.abs(this.pos.z));
  }
  setParams(p) { this.p = { ...p }; this.lp = new LP2(); this.baseInit = false; this.win = []; this.sHist = []; }
  reset() {
    this.pos = new V(); this.vel = new V(); this.base = new V(); this.bias = this.base; this.baseInit = false;
    this.aW = new V(); this.aLP = new V(); this.aHP = new V(); this.aPrev = new V();
    this.lastTs = null; this.stillN = 0; this.still = true; this.dist = 0; this.maxDisp = 0; this.warm = 0;
    this.win = []; this.sHist = []; this.seg = []; this.lastSeg = null; this.segDist0 = 0; this.segStarted = false; this.std = 0; this.noise = 0; this.thr = this.p.stillAcc; this.gyroLP = 0;
    if (this.gpsOn) { this.origin = null; this.kf?.forEach(k => k.reset()); }
    if (this.lastOri) { this.alphaOffset = this.lastOri[0]; this.orientation(...this.lastOri); }
  }
  // heading: webkitCompassHeading(자북 기준 °), hacc: webkitCompassAccuracy(±°)
  orientation(alpha, beta, gamma, heading, hacc) {
    if (alpha == null) return;
    this.lastOri = [alpha, beta, gamma];
    if (this.alphaOffset === null) this.alphaOffset = alpha;
    if (!this.compassOn) { this.q = quatFromOrientation(alpha - this.alphaOffset, beta, gamma); return; }
    // 나침반으로 방위 보정: 월드 -Z = 진북이 되도록 세로축 회전량(yawCorr)을 천천히 맞춤 (자이로 방위 드리프트 제거)
    const q0 = quatFromOrientation(alpha, beta, gamma);
    if (heading != null && heading >= 0 && (hacc == null || (hacc >= 0 && hacc <= 35))) {
      this.heading = heading; this.headingAcc = hacc;
      const top = rotate(q0, 0, 1, 0, new V()), back = rotate(q0, 0, 0, -1, new V());
      const v = Math.abs(top.y) < 0.75 ? top : back;          // 눕혀 들면 윗변, 세워 들면 뒷면 카메라 방향
      const az = Math.atan2(v.x, -v.z) / D;
      const target = heading + this.declination - az;
      if (this.yawCorr == null) this.yawCorr = target;
      else { const d = ((target - this.yawCorr) % 360 + 540) % 360 - 180; this.yawCorr += d * 0.02; }
    }
    this.q = this.yawCorr == null ? q0 : qmul(qaxis([0, 1, 0], -this.yawCorr * D), q0);
  }
  // ts: ms, acc/accG: {x,y,z} 기기 좌표 m/s², rot: {alpha,beta,gamma} °/s. 반환: 위치가 바뀌었으면 true
  motion(ts, acc, accG, rot) {
    if (!this.q) return false;
    if (this.lastTs == null) { this.lastTs = ts; return false; }
    let dt = (ts - this.lastTs) / 1000; this.lastTs = ts;
    if (!(dt > 0)) return 0; if (dt > 0.1) dt = 0.1;
    this.fs += (1 / dt - this.fs) * 0.02;
    const p = this.p, q = this.q;

    if (accG && accG.x != null && this.nSign < 60) {     // iOS는 스펙과 부호가 반대 → 중력 방향으로 판정
      const g = rotate(q, accG.x, accG.y, accG.z, new V());
      this.signAcc += g.y; this.nSign++; this.sign = this.signAcc >= 0 ? 1 : -1;
    }
    const s = this.sign;
    if (acc && acc.x != null) rotate(q, acc.x * s, acc.y * s, acc.z * s, this.aW);
    else if (accG && accG.x != null) { rotate(q, accG.x * s, accG.y * s, accG.z * s, this.aW); this.aW.y -= 9.81; }
    else return false;

    // 1) 저역 통과: 진동(고주파) 제거
    this.lp.design(p.lpHz, this.fs);
    this.lp.step(this.aW, this.aLP);
    // 2) 기준선(센서 치우침 + 차량 자체 가감속) 제거: 정지 중에 빠르게 학습, 움직이는 동안은 천천히만 따라감
    if (!this.baseInit && p.baseTau > 0) { this.base.copy(this.aLP); this.baseInit = true; }
    if (p.baseTau > 0 && !this.still) {
      const k = 1 - Math.exp(-dt / p.baseTau);
      this.base.set(this.base.x + (this.aLP.x - this.base.x) * k, this.base.y + (this.aLP.y - this.base.y) * k, this.base.z + (this.aLP.z - this.base.z) * k);
    }
    const a = this.aHP.set(this.aLP.x - this.base.x, this.aLP.y - this.base.y, this.aLP.z - this.base.z);

    // 3) 정지 판정: 최근 0.4초 흔들림(표준편차)이 평소 진동 수준 이하
    const W = Math.max(6, Math.round(this.fs * 0.4));
    this.win.push([this.aLP.x, this.aLP.y, this.aLP.z]); if (this.win.length > W) this.win.shift();
    let mx = 0, my = 0, mz = 0; for (const w of this.win) { mx += w[0]; my += w[1]; mz += w[2]; }
    const n = this.win.length; mx /= n; my /= n; mz /= n;
    let v = 0; for (const w of this.win) v += (w[0] - mx) ** 2 + (w[1] - my) ** 2 + (w[2] - mz) ** 2;
    this.std = Math.sqrt(v / n);
    const calib = this.win.length < W || this.sHist.length < this.fs;   // 시작 1초: 가만히 있다고 보고 기준값 학습
    if (this.win.length >= W) { this.sHist.push(this.std); if (this.sHist.length > this.fs * 6) this.sHist.shift(); }
    if (this.sHist.length) {   // 최근 6초 흔들림의 하위 20% = 평소 진동 수준
      const srt = this.sHist.slice().sort((x, y) => x - y);
      this.noise = srt[Math.floor(srt.length * 0.2)];
    }
    this.thr = Math.max(p.stillAcc, p.stillK * this.noise);
    const g = rot ? Math.hypot(rot.alpha || 0, rot.beta || 0, rot.gamma || 0) : 0;
    this.gyroLP += (g - this.gyroLP) * 0.2;
    const cand = calib || this.std < this.thr && (!p.accGate || a.length() < this.thr * p.accGate) && this.gyroLP < p.stillGyro;
    this.stillN = cand ? this.stillN + 1 : 0;
    this.still = this.stillN >= p.stillFrames;

    if (this.gpsOn) {
      // GPS 융합: 가속도로 예측(60Hz), GPS가 들어올 때마다 위치·속도 보정. 차량 가감속은 실제 움직임이므로 제거하지 않음
      const al = [this.aLP.x, this.aLP.y, this.aLP.z];
      for (let i = 0; i < 3; i++) this.kf[i].predict(al[i], dt, p.lpHz <= 5 ? 0.9 : 0.6, 0.02);
      this.kf[1].update(1, 0, 1.5 ** 2);                                    // 수직 속도는 0 근처라고 약하게 가정
      const gpsStopped = ts - this.gpsT < 3000 && this.gpsSpeed != null && this.gpsSpeed < 0.5;
      if (this.fix && this.still && gpsStopped) for (let i = 0; i < 3; i++) this.kf[i].update(1, 0, 0.05 ** 2);
      if (!this.rec || !this.origin) return 0;
      this.syncFromKf();
      return 1;
    }
    if (this.fix && this.still) {     // 정지: 속도 0 (ZUPT) + 치우침 학습
      let corrected = false;
      if (this.seg.length > 1 && p.segFix) corrected = this.fixSegment();
      this.seg = [];
      this.vel.set(0, 0, 0); this.aPrev.set(0, 0, 0);
      const k = p.baseRate; this.base.set(this.base.x + (this.aLP.x - this.base.x) * k, this.base.y + (this.aLP.y - this.base.y) * k, this.base.z + (this.aLP.z - this.base.z) * k);
      this.warm = Math.min(this.warm + 1, 1000);
      return corrected ? 2 : 0;
    }
    if (a.length() < p.dead) a.set(0, 0, 0);
    // 4) 사다리꼴 적분 + 속도 감쇠
    const vx = this.vel.x, vy = this.vel.y, vz = this.vel.z;
    this.vel.set(vx + (a.x + this.aPrev.x) * 0.5 * dt, vy + (a.y + this.aPrev.y) * 0.5 * dt, vz + (a.z + this.aPrev.z) * 0.5 * dt);
    this.aPrev.copy(a);
    if (this.fix) { const k = Math.exp(-dt / p.velTau); this.vel.set(this.vel.x * k, this.vel.y * k, this.vel.z * k); }
    const sp = this.vel.length(); if (sp > 6) { const k = 6 / sp; this.vel.set(this.vel.x * k, this.vel.y * k, this.vel.z * k); }
    if (!this.rec) return 0;
    if (!this.seg.length) {   // 움직임 구간 시작
      this.seg.push({ t: this.lastTs - dt * 1000, x: this.pos.x, y: this.pos.y, z: this.pos.z, sp: 0 });
      this.segDist0 = this.dist; this.segStarted = true;
    }
    const sx = (vx + this.vel.x) * 0.5 * dt, sy = (vy + this.vel.y) * 0.5 * dt, sz = (vz + this.vel.z) * 0.5 * dt;
    this.pos.set(this.pos.x + sx, this.pos.y + sy, this.pos.z + sz);
    this.dist += Math.hypot(sx, sy, sz);
    this.maxDisp = Math.max(this.maxDisp, Math.abs(this.pos.x), Math.abs(this.pos.y), Math.abs(this.pos.z));
    this.seg.push({ t: this.lastTs, x: this.pos.x, y: this.pos.y, z: this.pos.z, sp: this.vel.length() });
    return 1;
  }
  // 움직임이 끝나 정지가 확인되면 끝 속도는 0이어야 함 → 남은 속도를 구간 전체 오차로 보고
  // 시간에 비례해 커진 속도 오차로 가정해 위치를 되짚어 보정 (차량 가감속 변화·치우침 누적 상쇄)
  fixSegment() {
    const s = this.seg, t0 = s[0].t, T = (s[s.length - 1].t - t0) / 1000;
    if (!(T > 0.05)) return false;
    const ex = this.vel.x, ey = this.vel.y, ez = this.vel.z, e = Math.hypot(ex, ey, ez);
    let d = this.segDist0, prev = s[0];
    for (let i = 1; i < s.length; i++) {
      const tau = (s[i].t - t0) / 1000, k = tau * tau / (2 * T), kv = tau / T;
      s[i].x -= ex * k; s[i].y -= ey * k; s[i].z -= ez * k;
      s[i].sp = Math.max(0, s[i].sp - e * kv);
      d += Math.hypot(s[i].x - prev.x, s[i].y - prev.y, s[i].z - prev.z); prev = s[i];
    }
    const last = s[s.length - 1];
    this.pos.set(last.x, last.y, last.z); this.dist = d;
    this.lastSeg = s;
    return true;
  }
}
