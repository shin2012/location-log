// 경로 기록 엔진 — GPS 우선, GPS가 끊긴 구간(터널 등)은 자이로·가속도·나침반으로 추정해 이어 붙임
// 브라우저·Node(시험) 공용. 외부 의존성 없음.
//
// 평소: 정확도 40m 이내 GPS 고정점을 그대로 기록(src='gps').
// 끊김: 마지막 고정점의 속도·진행 방향에서 출발해
//   - 진행 방향 = 끊기기 직전 방향 + 그 뒤 폰의 세로축 회전량(자이로). 나침반은 긴 터널에서만 약하게 끌어당김
//   - 속도 = 직전 속도 + 진행 방향 가속도 적분(치우침 학습값 제거), 직전 속도로 천천히 복원
//   - 1초마다 추정점(src='imu') 생성
// 복귀: 다시 잡힌 GPS와 추정 끝점의 차이를 끊긴 구간 전체에 시간 비례로 나눠 보정 → onCorrect로 같은 seq 재전송
import { V, quatFromOrientation, rotate, LP2 } from './nav.js';

const D = Math.PI / 180, R_E = 6371008.8;
const wrap = (a) => ((a % 360) + 540) % 360 - 180;          // -180..180
const norm360 = (a) => ((a % 360) + 360) % 360;

export const TRACK_PARAMS = {
  goodAcc: 40,        // m 이하 고정점만 사용
  lossMs: 3000,       // 이 시간 동안 좋은 고정점이 없으면 추정 시작
  minDrSpeed: 2.5,    // m/s 미만에서 끊기면 이동 추정 없이 대기(실내 보행 등)
  maxJump: 70,        // m/s 를 넘는 순간 이동은 튐으로 보고 버림
  speedTau: 90,       // s, 추정 속도를 직전 GPS 속도로 되돌리는 시간
  compassAfter: 120,  // s, 이보다 긴 끊김에서만 나침반으로 자이로 방향을 보정
  compassTau: 120,    // s, 나침반으로 방향을 끌어당기는 시간
  compassMaxDiff: 12, // ° 이상 어긋나면 나침반 무시(차체·터널 자기 교란)
  declination: -8.8,  // 자북 편차(한국)
};

export class Tracker {
  constructor({ onPoint = () => {}, onCorrect = () => {}, params = {} } = {}) {
    this.p = { ...TRACK_PARAMS, ...params };
    this.onPoint = onPoint; this.onCorrect = onCorrect;
    this.seq = 0; this.mode = 'wait';
    this.last = null;            // 마지막 좋은 GPS {perf, epoch, lat, lon, spd, hdg, acc}
    this.prevFix = null;
    this.q0 = null; this.ref = 'back'; this.yawRel = null; this.yawRelUnwrapped = null;
    this.compassTrue = null; this.compassAcc = null;
    this.F = null;               // 상대 자세 좌표 → 진북 회전량 (나침반으로 학습)
    this.m = null;               // GPS 진행 방향 − 폰 상대 방위 (거치 각도 + F)
    this.yawRate = 0; this.lastYawT = null;
    this.sign = 1; this.signAcc = 0; this.nSign = 0;
    this.lp = new LP2(); this.aLP = new V(); this.aW = new V(); this.fs = 60; this.lastMotionTs = null;
    this.longBias = 0; this.aInt = 0; this.aIntN = 0; this.hist = []; this.nBias = 0; this.nM = 0;   // 진행 방향 가속도 치우침 학습
    this.dr = null; this.speed = null; this.course = null; this.compassHeading = null;
    this.epochOffset = null;
  }

  // performance 기준 ms → epoch ms
  toEpoch(perf) { return this.epochOffset == null ? perf : perf + this.epochOffset; }
  setClock(perf, epoch) { this.epochOffset = epoch - perf; }

  phoneYaw(q) {   // 폰 기준 벡터의 수평 방위(°): 세워 들면 뒷면 카메라 방향, 눕히면 윗변
    const back = rotate(q, 0, 0, -1, new V()), top = rotate(q, 0, 1, 0, new V());
    if (this.ref === 'back' && Math.abs(back.y) > 0.9) this.ref = 'top';
    else if (this.ref === 'top' && Math.abs(top.y) > 0.9) this.ref = 'back';
    const v = this.ref === 'back' ? back : top;
    return { yaw: Math.atan2(v.x, -v.z) / D, ref: this.ref };
  }

  orientation(ts, alpha, beta, gamma, heading, hacc) {
    if (alpha == null) return;
    this.q0 = quatFromOrientation(alpha, beta, gamma);
    const prevRef = this.ref;
    const { yaw } = this.phoneYaw(this.q0);
    if (this.yawRel != null) {
      let d = wrap(yaw - this.yawRel);
      if (prevRef !== this.ref) {            // 기준 벡터가 바뀌면 방위 연속성 유지
        if (this.dr) this.dr.yaw0 += d;
        if (this.m != null) this.m = norm360(this.m - d);
        if (this.F != null) this.F = norm360(this.F - d);
        d = 0;
      }
      this.yawRelUnwrapped += d;
      if (this.lastYawT != null && ts > this.lastYawT) this.yawRate += (d / ((ts - this.lastYawT) / 1000) - this.yawRate) * 0.1;
    } else this.yawRelUnwrapped = yaw;
    this.yawRel = yaw; this.lastYawT = ts;
    // 나침반: 폰 기준 벡터의 진북 방위
    if (heading != null && heading >= 0 && (hacc == null || (hacc >= 0 && hacc <= 30))) {
      this.compassTrue = norm360(heading + this.p.declination); this.compassAcc = hacc;
      const f = wrap(this.compassTrue - yaw);
      if (!this.dr) this.F = this.F == null ? f : norm360(this.F + wrap(f - this.F) * 0.02);   // 추정 중(터널)에는 학습 멈춤
      this.compassHeading = this.compassTrue;
    }
  }

  motion(ts, acc, accG, rot) {
    if (!this.q0) return;
    if (this.lastMotionTs == null) { this.lastMotionTs = ts; return; }
    let dt = (ts - this.lastMotionTs) / 1000; this.lastMotionTs = ts;
    if (!(dt > 0)) return; if (dt > 0.1) dt = 0.1;
    this.fs += (1 / dt - this.fs) * 0.02;
    if (accG && accG.x != null && this.nSign < 60) {
      const g = rotate(this.q0, accG.x, accG.y, accG.z, new V());
      this.signAcc += g.y; this.nSign++; this.sign = this.signAcc >= 0 ? 1 : -1;
    }
    const s = this.sign;
    if (acc && acc.x != null) rotate(this.q0, acc.x * s, acc.y * s, acc.z * s, this.aW);
    else return;
    this.lp.design(1.5, this.fs); this.lp.step(this.aW, this.aLP);
    // 진행 방향(상대 좌표) 성분
    const fwdRel = this.forwardRel();
    if (fwdRel == null) return;
    const aLong = this.aLP.x * Math.sin(fwdRel * D) + (-this.aLP.z) * Math.cos(fwdRel * D);
    if (!this.dr) { this.aInt += aLong * dt; this.aIntN++; }
    if (this.dr) this.drStep(ts, dt, aLong);
  }

  // 차 진행 방향의 상대 좌표 방위: 진북 진행 방향 − F
  forwardRel() {
    if (this.m == null || this.yawRel == null) return null;
    const F = this.F ?? this.m;   // 나침반이 없으면 폰이 정면을 향해 거치됐다고 가정
    const courseTrue = this.dr ? this.dr.course : norm360(this.yawRel + this.m);
    return courseTrue - F;
  }

  gps(f) {   // {perf, epoch, lat, lon, alt, acc, speed, heading}
    if (f.lat == null) return;
    this.setClock(f.perf, f.epoch);
    if (f.acc != null && f.acc > this.p.goodAcc) return;   // 터널 출입구의 부정확한 값 무시
    let jumped = false;
    if (this.last && !this.dr) {
      // 순간 이동(튐)은 버림. 단, 오래 끊겼거나(비행기 등) 튄 곳 근처에서 연달아 잡히면 새 위치로 받아들임
      const dt = (f.perf - this.last.perf) / 1000, d = dist(this.last, f);
      if (dt > 0 && d / dt > this.p.maxJump) {
        const c = this.jumpCand;
        if (dt < 120 && !(c && dist(c, f) < 100 + (f.acc ?? 30))) { this.jumpCand = { lat: f.lat, lon: f.lon }; return; }
        jumped = true;
      }
    }
    this.jumpCand = null;
    if (jumped) this.last = null;   // 새 출발점: 앞 점과 이어서 속도·방향을 계산하지 않음
    const devSpd = f.speed != null && f.speed >= 0 ? f.speed : null;
    const devHdg = f.heading != null && !Number.isNaN(f.heading) && f.heading >= 0 ? f.heading : null;
    let spd = devSpd, hdg = devHdg;
    if (this.last && (spd == null || hdg == null)) {   // 표시용: 고정점 사이 이동으로 계산 (오차보다 충분히 움직였을 때만)
      const dt = (f.perf - this.last.perf) / 1000, d = dist(this.last, f);
      if (dt > 0.3 && d > Math.max(5, f.acc ?? 10)) { if (spd == null) spd = d / dt; if (hdg == null) hdg = bearing(this.last, f); }
      else if (spd == null && dt > 0.3) spd = 0;
    }
    // 학습 1) 진행 방향 가속도 치우침: 최근 약 5초 GPS 속도 변화 vs 가속도 적분
    if (devSpd != null) {
      this.hist.push({ perf: f.perf, spd: devSpd, I: this.aInt });
      while (this.hist.length > 2 && f.perf - this.hist[1].perf >= 5000) this.hist.shift();
      const h0 = this.hist[0], dt = (f.perf - h0.perf) / 1000;
      if (dt >= 4 && dt <= 8 && this.aIntN > 100) {
        const aGps = (devSpd - h0.spd) / dt, aImu = (this.aInt - h0.I) / dt, k = Math.max(0.05, 1 / (++this.nBias + 1));
        this.longBias += ((aImu - aGps) - this.longBias) * k;
      }
    } else this.hist = [];
    // 학습 2) 진행 방향 − 폰 방위 (기기가 준 속도·방향, 직진 중일 때만)
    if (devHdg != null && devSpd != null && devSpd > 5 && Math.abs(this.yawRate) < 4 && this.yawRel != null) {
      const mm = wrap(devHdg - this.yawRel), k = Math.max(0.1, 1 / (++this.nM + 1));
      this.m = this.m == null ? norm360(mm) : norm360(this.m + wrap(mm - this.m) * k);
    }
    const fix = { perf: f.perf, epoch: f.epoch, lat: f.lat, lon: f.lon, alt: f.alt ?? null, acc: f.acc ?? null, spd, hdg, yawU: this.yawRelUnwrapped };
    if (this.dr) this.endDr(fix);
    this.mode = 'gps';
    this.last = fix; this.speed = spd; this.course = hdg ?? this.course;
    this.emit({ ts: f.epoch, lat: f.lat, lon: f.lon, alt: fix.alt, acc: fix.acc, spd, hdg, src: 'gps', ...(jumped ? { brk: 1 } : {}) });
  }

  // 주기 호출(약 4Hz): GPS 끊김 판정, 추정점 1초 간격 생성
  tick(perf) {
    if (!this.last) return;
    const gap = perf - this.last.perf;
    // 화면 꺼짐·백그라운드로 멈췄다 돌아온 경우: 추정하지 않고 대기 (몇 분을 직선으로 메우지 않도록)
    if (this.dr && perf - this.dr.posPerf > 5000) { this.dr = null; this.mode = 'hold'; return; }
    // 멈춰 있으면 아이폰이 위치를 드문드문 줌 — 끊김이 아님
    if (!this.dr && this.mode === 'gps' && (this.last.spd ?? 0) < this.p.minDrSpeed) return;
    if (!this.dr && gap > this.p.lossMs && this.mode === 'gps' && gap > this.p.lossMs + 2500) { this.mode = 'hold'; return; }
    if (!this.dr && gap > this.p.lossMs && this.mode === 'gps') {
      if (this.last.spd != null && this.last.spd >= this.p.minDrSpeed && this.last.hdg != null && this.yawRel != null) this.startDr(perf);
      else this.mode = 'hold';
    }
    while (this.dr && perf - this.dr.lastEmit >= 1000) {
      const d = this.dr, t = d.lastEmit + 1000;
      d.lastEmit = t;
      // 표시 시각 t의 위치: 마지막 계산 위치에서 (계산 시각 − t)만큼 되돌림
      const back = Math.max(0, (d.posPerf - t) / 1000) * d.v;
      const e = d.pos.e - back * Math.sin(d.course * D), n = d.pos.n - back * Math.cos(d.course * D);
      const ll = this.toLL(e, n);
      const pt = { ts: this.toEpoch(t), lat: ll.lat, lon: ll.lon, alt: this.last.alt, acc: Math.round((this.last.acc ?? 10) + d.dist * 0.03),
        spd: d.v, hdg: norm360(d.course), src: 'imu' };
      d.pts.push({ ...pt, perf: t, e, n, seq: this.seq });
      this.emit(pt);
    }
  }

  startDr(perf) {
    // 끊김은 몇 초 뒤에야 확정되므로, 마지막 고정점부터 지금까지는 그 속도·방향(+자이로 회전)으로 채움
    const L = this.last, el = (perf - L.perf) / 1000;
    const course = L.hdg + (this.yawRelUnwrapped - L.yawU) / 2;   // 사이 구간의 평균 방향
    const dd = L.spd * el;
    this.dr = { t0: L.perf, lastEmit: L.perf, lat0: L.lat, lon0: L.lon,
      pos: { e: dd * Math.sin(course * D), n: dd * Math.cos(course * D) }, posPerf: perf, v: L.spd, v0: L.spd,
      course0: L.hdg, course: L.hdg + (this.yawRelUnwrapped - L.yawU), yaw0: L.yawU, compassOff: null, dist: dd, pts: [] };
    // 끊기기 직전 나침반과 진행 방향의 차이(거치 각도) 기억 → 긴 터널에서 방향 보정에 사용
    if (this.compassTrue != null) this.dr.compassOff = wrap(L.hdg - this.compassTrue);
    this.mode = 'dr';
  }

  drStep(ts, dt, aLong) {
    const d = this.dr, p = this.p;
    // 방향: 자이로 회전량
    let course = d.course0 + (this.yawRelUnwrapped - d.yaw0);
    // 나침반(긴 터널 보정): 끊기기 전 거치 각도 그대로 적용, 크게 어긋나면 무시
    if (d.compassOff != null && this.compassTrue != null && (ts - d.t0) / 1000 > p.compassAfter) {
      const cc = this.compassTrue + d.compassOff, diff = wrap(cc - course);
      if (Math.abs(diff) < p.compassMaxDiff) d.course0 += diff * (dt / p.compassTau), course += diff * (dt / p.compassTau);
    }
    d.course = course;
    // 속도: 진행 방향 가속도 적분 − 치우침, 직전 GPS 속도로 서서히 복원
    d.v += (aLong - this.longBias) * dt;
    d.v += (d.v0 - d.v) * (dt / p.speedTau);
    d.v = Math.max(0, Math.min(d.v, d.v0 * 1.6 + 8));
    const step = d.v * dt; d.posPerf = ts;
    d.pos.e += step * Math.sin(course * D); d.pos.n += step * Math.cos(course * D); d.dist += step;
    this.speed = d.v; this.course = norm360(course);
  }

  endDr(fix) {
    const d = this.dr; this.dr = null;
    if (!d.pts.length) return;
    // 복귀 시점까지 추정 위치 → 실제 GPS와의 차이
    const g = this.toEN(fix.lat, fix.lon, d);
    const ex = g.e - d.pos.e, ey = g.n - d.pos.n, T = fix.perf - d.t0;
    const fixed = d.pts.map(q => {
      const k = Math.min(1, (q.perf - d.t0) / T);
      const ll = this.toLL(q.e + ex * k, q.n + ey * k, d);
      return { seq: q.seq, ts: q.ts, lat: ll.lat, lon: ll.lon, alt: q.alt, acc: q.acc, spd: q.spd, hdg: q.hdg, src: 'imu' };
    });
    this.lastCorrection = { n: fixed.length, errM: Math.hypot(ex, ey), gapS: T / 1000 };
    this.onCorrect(fixed, this.lastCorrection);
  }

  emit(pt) { pt.seq = this.seq++; this.prevFix = pt; this.onPoint(pt); }

  toLL(e, n, d = this.dr) {
    return { lat: d.lat0 + (n / R_E) / D, lon: d.lon0 + (e / (R_E * Math.cos(d.lat0 * D))) / D };
  }
  toEN(lat, lon, d) {
    return { e: (lon - d.lon0) * D * R_E * Math.cos(d.lat0 * D), n: (lat - d.lat0) * D * R_E };
  }
}

export function dist(a, b) {
  const la1 = a.lat * D, la2 = b.lat * D, dl = (b.lon - a.lon) * D;
  const h = Math.sin((la2 - la1) / 2) ** 2 + Math.cos(la1) * Math.cos(la2) * Math.sin(dl / 2) ** 2;
  return 2 * R_E * Math.asin(Math.sqrt(h));
}
export function bearing(a, b) {
  const la1 = a.lat * D, la2 = b.lat * D, dl = (b.lon - a.lon) * D;
  return norm360(Math.atan2(Math.sin(dl) * Math.cos(la2), Math.cos(la1) * Math.sin(la2) - Math.sin(la1) * Math.cos(la2) * Math.cos(dl)) / D);
}
export const dirName = (h) => h == null ? '–' : ['북', '북동', '동', '남동', '남', '남서', '서', '북서'][Math.round(norm360(h) / 45) % 8];
