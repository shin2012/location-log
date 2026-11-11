"""시야쥬(위치 기록 앱) 전용 API — https://location.b-612.kr/app-api/* (Bearer 토큰)

경로(track)와 점(track_pt)을 MariaDB location_log 에 저장. 점은 (track_id, seq) 기준 REPLACE 라서
같은 점을 다시 보내도 안전하고, 터널 구간 사후 보정값도 같은 seq 로 덮어씀.
"""
import json
import math
import os
import time
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pymysql

import parking as PK
import timeline as TL
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

app = FastAPI(title="location-log")
APP_TOKEN = os.environ.get("APP_TOKEN", "")


# 앱 전용 API (웹 화면은 2026-11 에 없앰). 앱은 https://location.b-612.kr/app-api/* 로 부름 → /api/* 로 바꿔 처리.
# 모든 요청에 Bearer 토큰 필수 (상태 확인 /api/health 만 예외).
@app.middleware("http")
async def app_gate(request: Request, call_next):
    path = request.scope["path"]
    if path.startswith("/app-api/"):
        path = "/api/" + path[len("/app-api/"):]
        request.scope["path"] = path
        request.scope["raw_path"] = path.encode()
    if path != "/api/health":
        if not APP_TOKEN or request.headers.get("authorization") != f"Bearer {APP_TOKEN}":
            return JSONResponse({"detail": "토큰이 맞지 않음"}, status_code=401)
    return await call_next(request)


@contextmanager
def db():
    c = pymysql.connect(host=os.environ["DB_HOST"], port=int(os.environ.get("DB_PORT", 3306)),
                        user=os.environ["DB_USER"], password=os.environ["DB_PASS"],
                        database=os.environ["DB_NAME"], charset="utf8mb4", autocommit=True,
                        cursorclass=pymysql.cursors.DictCursor)
    try:
        yield c.cursor()
    finally:
        c.close()


def ms_to_dt(ms: float) -> datetime:
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).replace(tzinfo=None)


def dt_to_ms(d):
    return None if d is None else int(d.replace(tzinfo=timezone.utc).timestamp() * 1000)


def hav(a, b):
    R = 6371008.8
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def refresh_stats(cur, tid):
    cur.execute("SELECT lat, lon, src, ts FROM track_pt WHERE track_id=%s ORDER BY seq", (tid,))
    pts = cur.fetchall()
    dist = 0.0
    for p, q in zip(pts, pts[1:]):   # 순간 이동(비행·오래 끊긴 뒤 다른 곳)은 거리에서 뺌
        d, dt = hav((p["lat"], p["lon"]), (q["lat"], q["lon"])), (q["ts"] - p["ts"]).total_seconds()
        if dt > 0 and d / dt > 120:
            continue
        dist += d
    n_est = sum(1 for p in pts if p["src"] == "imu")
    cur.execute("UPDATE track SET distance_m=%s, n_points=%s, n_est=%s WHERE id=%s", (dist, len(pts), n_est, tid))


MODES = ("car", "walk", "bicycle", "other")


def track_row(r):
    return {"id": r["id"], "client_id": r["client_id"], "name": r["name"],
            "started_at": dt_to_ms(r["started_at"]), "ended_at": dt_to_ms(r["ended_at"]),
            "distance_m": round(r["distance_m"], 1), "n_points": r["n_points"], "n_est": r["n_est"],
            "sent_daily_at": dt_to_ms(r["sent_daily_at"]), "mode": r.get("mode", "car"),
            "mode_auto": None if r.get("mode_auto") is None else bool(r["mode_auto"])}


@app.get("/api/health")
def health():
    with db() as cur:
        cur.execute("SELECT 1 AS ok")
        return {"ok": True}


class TrackIn(BaseModel):
    client_id: str = Field(min_length=8, max_length=64)
    name: str = Field(min_length=1, max_length=200)
    started_at: float  # epoch ms


@app.post("/api/tracks")
def create_track(t: TrackIn):
    with db() as cur:
        cur.execute("INSERT INTO track (client_id, name, started_at) VALUES (%s,%s,%s) "
                    "ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id)", (t.client_id, t.name, ms_to_dt(t.started_at)))
        cur.execute("SELECT * FROM track WHERE client_id=%s", (t.client_id,))
        return track_row(cur.fetchone())


@app.get("/api/tracks")
def list_tracks():
    with db() as cur:
        cur.execute("SELECT * FROM track ORDER BY started_at DESC LIMIT 500")
        return [track_row(r) for r in cur.fetchall()]


@app.get("/api/tracks/{tid}")
def get_track(tid: int):
    with db() as cur:
        cur.execute("SELECT * FROM track WHERE id=%s", (tid,))
        r = cur.fetchone()
        if not r:
            raise HTTPException(404, "없는 기록")
        cur.execute("SELECT seq, ts, lat, lon, alt, acc, spd, hdg, src FROM track_pt WHERE track_id=%s ORDER BY seq", (tid,))
        pts = [{**p, "ts": dt_to_ms(p["ts"])} for p in cur.fetchall()]
        return {**track_row(r), "points": pts}


class Pt(BaseModel):
    seq: int
    ts: float
    lat: float
    lon: float
    alt: float | None = None
    acc: float | None = None
    spd: float | None = None
    hdg: float | None = None
    src: str = "gps"


class PtsIn(BaseModel):
    points: list[Pt]


@app.post("/api/tracks/{tid}/points")
def add_points(tid: int, body: PtsIn):
    if not body.points:
        return {"ok": True, "n": 0}
    rows = []
    for p in body.points:
        if not (-90 <= p.lat <= 90 and -180 <= p.lon <= 180):
            continue
        rows.append((tid, p.seq, ms_to_dt(p.ts), p.lat, p.lon, p.alt, p.acc, p.spd, p.hdg,
                     "imu" if p.src == "imu" else "gps"))
    with db() as cur:
        cur.execute("SELECT id FROM track WHERE id=%s", (tid,))
        if not cur.fetchone():
            raise HTTPException(404, "없는 기록")
        cur.executemany("REPLACE INTO track_pt (track_id, seq, ts, lat, lon, alt, acc, spd, hdg, src) "
                        "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)", rows)
        refresh_stats(cur, tid)
    return {"ok": True, "n": len(rows), "max_seq": max(r[1] for r in rows) if rows else None}


class TrackPatch(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    ended_at: float | None = None
    mode: str | None = None
    mode_auto: bool | None = None   # true = 앱이 자동 인식, false = 사용자가 고름


@app.patch("/api/tracks/{tid}")
def patch_track(tid: int, body: TrackPatch):
    with db() as cur:
        if body.name is not None:
            cur.execute("UPDATE track SET name=%s WHERE id=%s", (body.name.strip(), tid))
        if body.ended_at is not None:   # 끝을 자른 자동 운전 기록은 늦게 온 끝 시각으로 다시 늘리지 않음
            cur.execute("UPDATE track SET ended_at=%s WHERE id=%s AND trimmed_at IS NULL", (ms_to_dt(body.ended_at), tid))
        if body.mode is not None:
            if body.mode not in MODES:
                raise HTTPException(400, f"mode must be one of {MODES}")
            cur.execute("UPDATE track SET mode=%s WHERE id=%s", (body.mode, tid))
        if body.mode_auto is not None:
            cur.execute("UPDATE track SET mode_auto=%s WHERE id=%s", (int(body.mode_auto), tid))
        cur.execute("SELECT * FROM track WHERE id=%s", (tid,))
        r = cur.fetchone()
        if not r:
            raise HTTPException(404, "없는 기록")
        return track_row(r)


@app.delete("/api/tracks/{tid}")
def delete_track(tid: int):
    with db() as cur:
        n = cur.execute("DELETE FROM track WHERE id=%s", (tid,))
        if not n:
            raise HTTPException(404, "없는 기록")
    return {"ok": True}


# 데일리요섭 보내기 = 보냄 표시만. 데일리요섭은 이 DB에서 보냄 표시된 기록만 읽음(복사 없음)
# → 삭제·이름 변경·보내기 취소가 데일리요섭에 바로 반영됨
@app.post("/api/tracks/{tid}/send-daily")
def send_daily(tid: int):
    with db() as cur:
        n = cur.execute("UPDATE track SET sent_daily_at=NOW() WHERE id=%s", (tid,))
        cur.execute("SELECT * FROM track WHERE id=%s", (tid,))
        r = cur.fetchone()
        if not r:
            raise HTTPException(404, "없는 기록")
        return track_row(r)


@app.delete("/api/tracks/{tid}/send-daily")
def unsend_daily(tid: int):
    with db() as cur:
        cur.execute("UPDATE track SET sent_daily_at=NULL WHERE id=%s", (tid,))
        cur.execute("SELECT * FROM track WHERE id=%s", (tid,))
        r = cur.fetchone()
        if not r:
            raise HTTPException(404, "없는 기록")
        return track_row(r)


# ── 하루 종일 기록 (앱 상시 기록) ─────────────────────────────────────────
# 점은 ts(UTC) 기준 REPLACE → 같은 묶음을 다시 보내도 안전. 날짜는 한국 시각 기준.
KST = timezone(timedelta(hours=9))
DAY_SRC = ("gps", "fill", "stay", "visit", "slc", "region", "trk", "imu")


class DayPt(BaseModel):
    ts: float  # epoch ms
    lat: float
    lon: float
    alt: float | None = None
    acc: float | None = None
    spd: float | None = None
    src: str = "gps"
    act: str | None = Field(default=None, max_length=10)


class DayPtsIn(BaseModel):
    points: list[DayPt]


class DayVisit(BaseModel):
    arrive: float  # epoch ms
    depart: float | None = None
    lat: float
    lon: float


class DayVisitsIn(BaseModel):
    visits: list[DayVisit]


class DayAct(BaseModel):
    ts: float  # epoch ms, 이 방식 시작
    act: str = Field(max_length=10)
    conf: int = 0


class DayActsIn(BaseModel):
    acts: list[DayAct]


class DayStep(BaseModel):
    ts: float  # epoch ms, 분 시작
    steps: int
    dist: float | None = None
    up: int | None = None      # 만보계 계단 오른 층수 (1.5.0~)
    down: int | None = None


class DayStepsIn(BaseModel):
    steps: list[DayStep]


DAY_ACT = ("stationary", "walk", "run", "bike", "car", "unknown")


def day_range(date: str):
    try:
        d = datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=KST)
    except ValueError:
        raise HTTPException(400, "날짜는 YYYY-MM-DD")
    a = d.astimezone(timezone.utc).replace(tzinfo=None)
    return a, a + timedelta(days=1)


@app.post("/api/day/points")
def day_points(body: DayPtsIn):
    rows = [(ms_to_dt(p.ts), p.lat, p.lon, p.alt, p.acc, p.spd, p.src if p.src in DAY_SRC else "gps", p.act)
            for p in body.points if -90 <= p.lat <= 90 and -180 <= p.lon <= 180]
    if rows:
        with db() as cur:
            cur.executemany("REPLACE INTO day_pt (ts, lat, lon, alt, acc, spd, src, act) "
                            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s)", rows)
    return {"ok": True, "n": len(rows)}


@app.post("/api/day/visits")
def day_visits(body: DayVisitsIn):
    rows = [(ms_to_dt(v.arrive), None if v.depart is None else ms_to_dt(v.depart), v.lat, v.lon) for v in body.visits]
    if rows:
        with db() as cur:
            cur.executemany("REPLACE INTO day_visit (arrive, depart, lat, lon) VALUES (%s,%s,%s,%s)", rows)
    return {"ok": True, "n": len(rows)}


@app.post("/api/day/acts")
def day_acts(body: DayActsIn):
    """이동 방식이 바뀐 시각 (기기 동작 기록). ts 기준 REPLACE → 다시 보내도 안전"""
    rows = [(ms_to_dt(a.ts), a.act, max(0, min(2, a.conf))) for a in body.acts if a.act in DAY_ACT]
    if rows:
        with db() as cur:
            cur.executemany("REPLACE INTO day_act (ts, act, conf) VALUES (%s,%s,%s)", rows)
    return {"ok": True, "n": len(rows)}


@app.post("/api/day/steps")
def day_steps(body: DayStepsIn):
    """1분 걸음 (0 걸음 분 포함)"""
    def fl(x):
        return None if x is None else max(0, min(255, x))
    rows = [(ms_to_dt(p.ts).replace(second=0, microsecond=0), max(0, min(65535, p.steps)), p.dist, fl(p.up), fl(p.down))
            for p in body.steps]
    if rows:
        with db() as cur:
            cur.executemany("REPLACE INTO day_step (ts, steps, dist_m, floors_up, floors_down) VALUES (%s,%s,%s,%s,%s)", rows)
    return {"ok": True, "n": len(rows)}


@app.get("/api/day")
def day_list(limit: int = 90):
    """기록 있는 날짜 (한국 시각) + 점 수"""
    with db() as cur:
        cur.execute("SELECT DATE(CONVERT_TZ(ts, '+00:00', '+09:00')) AS d, COUNT(*) AS n, MIN(ts) AS a, MAX(ts) AS b "
                    "FROM day_pt GROUP BY d ORDER BY d DESC LIMIT %s", (max(1, min(limit, 400)),))
        return [{"date": r["d"].isoformat(), "n_points": r["n"], "first": dt_to_ms(r["a"]), "last": dt_to_ms(r["b"])}
                for r in cur.fetchall()]


@app.get("/api/day/{date}/timeline")
def day_timeline(date: str):
    """타임라인 탭: 머문 곳·이동(방식·운전 여부·걸음·경로)을 시간순으로. 시각은 epoch ms."""
    a, b = day_range(date)
    with db() as cur:
        cur.execute("SELECT arrive, depart, lat, lon FROM day_visit WHERE arrive < %s AND (depart IS NULL OR depart > %s) ORDER BY arrive",
                    (b, a - timedelta(hours=12)))
        now = datetime.now(timezone.utc).replace(tzinfo=None)
        vs = [{"start": r["arrive"], "end": r["depart"] or now, "lat": r["lat"], "lon": r["lon"], "open": r["depart"] is None}
              for r in cur.fetchall()]
        cur.execute("SELECT ts, lat, lon, src, act FROM day_pt WHERE ts >= %s AND ts < %s ORDER BY ts", (a, b))
        pts = [p for p in cur.fetchall() if p["src"] in TL.PATH_SRC]
        cur.execute("(SELECT ts, act FROM day_act WHERE ts < %s ORDER BY ts DESC LIMIT 1) UNION ALL "
                    "(SELECT ts, act FROM day_act WHERE ts >= %s AND ts < %s) ORDER BY ts", (a, a, b))
        acts = cur.fetchall()
        cur.execute("SELECT ts, steps, floors_up, floors_down FROM day_step WHERE ts >= %s AND ts < %s ORDER BY ts", (a, b))
        steps = cur.fetchall()
        # 운전 판정: swarm.FSQ_CarPlay (앱·단축어 둘 다 여기로 모임, 한국 시각) — loc_rw 에 SELECT 권한
        cur.execute("SELECT event_type AS event, event_time - INTERVAL 9 HOUR AS at FROM swarm.FSQ_CarPlay "
                    "WHERE event_time >= %s AND event_time < %s ORDER BY event_time",
                    (a + timedelta(hours=3), b + timedelta(hours=9)))
        cps = cur.fetchall()
        cur.execute("SELECT name, lat, lon, radius FROM auto_place")
        places = cur.fetchall()
        cur.execute("SELECT FROM_UNIXTIME(FSQ_UNIXTIME) AS ts, VENUE AS name, LAT+0 AS lat, LNG+0 AS lon FROM swarm.FSQ_Swarm "
                    "WHERE FSQ_UNIXTIME BETWEEN UNIX_TIMESTAMP(%s) - 43200 AND UNIX_TIMESTAMP(%s) ORDER BY FSQ_UNIXTIME",
                    (a, b))
        cks = [{**c, "lat": float(c["lat"]), "lon": float(c["lon"])} for c in cur.fetchall()]
        parks = _parks(cur, a - timedelta(hours=1), b + timedelta(hours=1))
        cur.execute("SELECT ts, kpa FROM day_baro WHERE ts >= %s AND ts < %s ORDER BY ts", (a - timedelta(hours=1), b))
        baro = cur.fetchall()
        cur.execute("(SELECT ts, bssid FROM day_wifi WHERE ts < %s ORDER BY ts DESC LIMIT 1) UNION ALL "
                    "(SELECT ts, bssid FROM day_wifi WHERE ts >= %s AND ts < %s) ORDER BY ts", (a, a, b))
        wifi = cur.fetchall()
        cur.execute("SELECT ts, lat, lon, dh, level, ap FROM floor_cal")
        fcal = cur.fetchall()
    out = TL.build_items(a, b, vs, pts, acts, steps, cps, places, cks, parks, baro, fcal, wifi)
    for it in out["items"]:
        it["start"], it["end"] = dt_to_ms(it["start"]), dt_to_ms(it["end"])
        if "park" in it:
            it["park"]["ts"] = dt_to_ms(it["park"]["ts"])
        for f in it.get("floors", []):
            f["start"], f["end"] = dt_to_ms(f["start"]), dt_to_ms(f["end"])
    return {"date": date, **out}


@app.get("/api/day/{date}")
def day_get(date: str):
    a, b = day_range(date)
    with db() as cur:
        cur.execute("SELECT ts, lat, lon, alt, acc, spd, src, act FROM day_pt WHERE ts >= %s AND ts < %s ORDER BY ts", (a, b))
        pts = [{**p, "ts": dt_to_ms(p["ts"])} for p in cur.fetchall()]
        cur.execute("SELECT arrive, depart, lat, lon FROM day_visit WHERE (depart IS NULL OR depart >= %s) AND arrive < %s "
                    "ORDER BY arrive", (a, b))
        vs = [{**v, "arrive": dt_to_ms(v["arrive"]), "depart": dt_to_ms(v["depart"])} for v in cur.fetchall()]
        cur.execute("SELECT ts, act, conf FROM day_act WHERE ts >= %s AND ts < %s ORDER BY ts", (a, b))
        acts = [{**x, "ts": dt_to_ms(x["ts"])} for x in cur.fetchall()]
        cur.execute("SELECT SUM(steps) n, SUM(dist_m) m, COUNT(*) k FROM day_step WHERE ts >= %s AND ts < %s", (a, b))
        st = cur.fetchone() or {}
    return {"date": date, "points": pts, "visits": vs, "acts": acts,
            "steps": {"total": int(st.get("n") or 0), "dist_m": float(st.get("m") or 0), "minutes": int(st.get("k") or 0)}}


@app.delete("/api/day/{date}")
def day_delete(date: str):
    a, b = day_range(date)
    with db() as cur:
        n = cur.execute("DELETE FROM day_pt WHERE ts >= %s AND ts < %s", (a, b))
        m = cur.execute("DELETE FROM day_visit WHERE arrive >= %s AND arrive < %s", (a, b))
        k = cur.execute("DELETE FROM day_act WHERE ts >= %s AND ts < %s", (a, b))
        j = cur.execute("DELETE FROM day_step WHERE ts >= %s AND ts < %s", (a, b))
    return {"ok": True, "points": n, "visits": m, "acts": k, "steps": j}


class CarPlayIn(BaseModel):
    event: str               # car_start | car_end
    ts: float                # epoch ms
    lat: float | None = None
    lng: float | None = None


@app.post("/api/carplay")
def carplay(body: CarPlayIn):
    """앱이 CarPlay 연결·해제를 알아채면 → swarm 지도(fsq_map) CarPlay API 로 넘김 (단축어 대신).
    fsq_map 이 2분 안 같은 이벤트는 하나로 합치므로 다시 보내도 안전."""
    import json as _json
    import urllib.request
    if body.event not in ("car_start", "car_end"):
        raise HTTPException(400, "event 는 car_start / car_end")
    url, tok = os.environ.get("FSQ_CARPLAY_URL"), os.environ.get("CARPLAY_API_TOKEN")
    if not url or not tok:
        raise HTTPException(503, "CarPlay 전달 설정 없음")
    data = {"event": body.event, "timestamp": body.ts / 1000, "device": "Sillage"}
    if body.lat is not None and body.lng is not None:
        data.update(lat=round(body.lat, 7), lng=round(body.lng, 7))
    req = urllib.request.Request(url, data=_json.dumps(data).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {tok}"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            out = _json.loads(r.read() or b"{}")
    except Exception as e:
        raise HTTPException(502, f"전달 실패: {str(e)[:120]}")
    return {"ok": True, "id": out.get("id"), "duplicate": bool(out.get("duplicate"))}


# ─── 기압·주차 층 (1.4.0) ───
class BaroIn(BaseModel):
    ts: float   # epoch ms
    kpa: float


class BaroBody(BaseModel):
    samples: list[BaroIn]


@app.post("/api/day/baro")
def day_baro(body: BaroBody):
    """기압 (iOS CMAltimeter, kPa). ts 기준 REPLACE"""
    rows = [(ms_to_dt(x.ts), x.kpa) for x in body.samples if 30 <= x.kpa <= 120]
    if rows:
        with db() as cur:
            cur.executemany("REPLACE INTO day_baro (ts, kpa) VALUES (%s,%s)", rows)
    return {"ok": True, "n": len(rows)}


class WifiEv(BaseModel):
    ts: float                                         # epoch ms, 연결 공유기가 바뀐 때
    bssid: str | None = Field(default=None, max_length=17)   # None = Wi-Fi 연결 없음
    ssid: str | None = Field(default=None, max_length=64)


class WifiBody(BaseModel):
    events: list[WifiEv]


@app.post("/api/day/wifi")
def day_wifi(body: WifiBody):
    """연결된 공유기 고유번호(BSSID)가 바뀐 시각 — 층 판정 보조"""
    rows = [(ms_to_dt(e.ts), e.bssid.lower() if e.bssid else None, e.ssid) for e in body.events]
    if rows:
        with db() as cur:
            cur.executemany("REPLACE INTO day_wifi (ts, bssid, ssid) VALUES (%s,%s,%s)", rows)
    return {"ok": True, "n": len(rows)}


class FloorFix(BaseModel):
    ts: float                    # 층 구간 시작 epoch ms (타임라인 floors[].start)
    lat: float
    lon: float
    dh: float                    # 그 구간 높이 (floors[].dh)
    level: int | None = None     # None = 확정 취소
    ap: str | None = Field(default=None, max_length=20)


@app.put("/api/floor")
def floor_fix(body: FloorFix):
    """머문 곳 층 구간을 사용자가 확정 → 그 장소(150m) 층 높이·공유기 층 학습"""
    ts = ms_to_dt(body.ts)
    with db() as cur:
        if body.level is None:
            cur.execute("DELETE FROM floor_cal WHERE ts BETWEEN %s AND %s", (ms_to_dt(body.ts - 2), ms_to_dt(body.ts + 2)))
        else:
            if not (PK.LEVEL_MIN <= body.level <= PK.LEVEL_MAX):
                raise HTTPException(400, "층 범위 밖")
            cur.execute("REPLACE INTO floor_cal (ts, lat, lon, dh, level, ap) VALUES (%s,%s,%s,%s,%s,%s)",
                        (ts, body.lat, body.lon, body.dh, body.level, body.ap))
    return {"ok": True}


def _park_cal(cur, exclude=None) -> list[dict]:
    cur.execute("SELECT ts, lat, lon, dh, level_user AS level FROM park WHERE level_user IS NOT NULL AND lat IS NOT NULL")
    return [c for c in cur.fetchall() if c["ts"] != exclude]


def _parks(cur, a: datetime, b: datetime) -> list[dict]:
    """[a, b) 주차 — 고친 층이 없으면 지금 보정값으로 다시 추정 (보정이 쌓이면 지난 기록도 바뀜)"""
    cur.execute("SELECT ts, lat, lon, dh, level_est, level_user FROM park WHERE ts >= %s AND ts < %s ORDER BY ts", (a, b))
    rows = cur.fetchall()
    if not rows:
        return []
    cal = _park_cal(cur)
    out = []
    for r in rows:
        if r["level_user"] is not None:
            lv, est = r["level_user"], False
        elif r["lat"] is not None:
            lv, est = PK.estimate(r["dh"], r["lat"], r["lon"], cal), True
        else:
            lv, est = r["level_est"], True
        out.append({"ts": r["ts"], "level": lv, "est": est, "dh": r["dh"]})
    return out


class ParkIn(BaseModel):
    ts: float                    # epoch ms, CarPlay 해제
    lat: float | None = None
    lon: float | None = None
    dh: float
    ref_ts: float | None = None
    level: int                   # 앱이 낸 추정


@app.post("/api/park")
def park_add(body: ParkIn):
    """주차 기록 (앱이 CarPlay 해제 1분 뒤 보냄). 다시 보내도 고친 층은 그대로."""
    ts = ms_to_dt(body.ts)
    with db() as cur:
        cur.execute("INSERT INTO park (ts, lat, lon, dh, ref_ts, level_est) VALUES (%s,%s,%s,%s,%s,%s) "
                    "ON DUPLICATE KEY UPDATE lat=VALUES(lat), lon=VALUES(lon), dh=VALUES(dh), ref_ts=VALUES(ref_ts), "
                    "level_est=VALUES(level_est)",
                    (ts, body.lat, body.lon, body.dh, None if body.ref_ts is None else ms_to_dt(body.ref_ts), body.level))
        lv = PK.estimate(body.dh, body.lat, body.lon, _park_cal(cur, ts)) if body.lat is not None else body.level
    return {"ok": True, "level": lv, "label": PK.label(lv)}


class ParkPatch(BaseModel):
    level: int | None = None     # None = 고친 것 취소 (다시 추정)


@app.patch("/api/park/{ts_ms}")
def park_patch(ts_ms: int, body: ParkPatch):
    if body.level is not None and not (PK.LEVEL_MIN <= body.level <= PK.LEVEL_MAX):
        raise HTTPException(400, "층 범위 밖")
    with db() as cur:
        # 앱이 보낸 ts 와 DB 값이 ms 반올림으로 1ms 어긋날 수 있음
        n = cur.execute("UPDATE park SET level_user=%s WHERE ts BETWEEN %s AND %s",
                        (body.level, ms_to_dt(ts_ms - 2), ms_to_dt(ts_ms + 2)))
    if not n:
        raise HTTPException(404, "주차 기록 없음")
    return {"ok": True}


@app.get("/api/park/calib")
def park_calib():
    """사용자가 고친(확정한) 주차 — 앱이 통신 없이도 같은 규칙으로 추정하도록"""
    with db() as cur:
        return [{"lat": c["lat"], "lon": c["lon"], "dh": round(c["dh"], 2), "level": c["level"]} for c in _park_cal(cur)]


@app.get("/api/park")
def park_list(days: int = 30):
    a = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(days=max(1, min(days, 400)))
    with db() as cur:
        rows = _parks(cur, a, datetime(2100, 1, 1))
    return [{**r, "ts": dt_to_ms(r["ts"]), "label": PK.label(r["level"]), "dh": round(r["dh"], 2)} for r in rows]


# ─── 자동 체크인 (IFTTT·람다 대체) ───
import threading  # noqa: E402

import autocheckin  # noqa: E402
import timefix  # noqa: E402

AC_WRITE = os.environ.get("AUTOCHECKIN_WRITE", "0") == "1"   # 0 = 기록만 (함께 돌려 보는 기간)


AC_MAX_PLACES = 19   # iOS 앱 하나가 감시할 수 있는 영역 20개 - 하루 기록 'day.stay' 1개
AC_MAX_MSG = f"자동 체크인 장소는 최대 {AC_MAX_PLACES}곳까지 켤 수 있습니다"


def _enabled_count(cur, exclude: str | None = None) -> int:
    cur.execute("SELECT COUNT(*) AS n FROM auto_place WHERE enabled=1 AND venue_id<>%s", (exclude or "",))
    return int(cur.fetchone()["n"])


@app.get("/api/autocheckin/places")
def ac_places(all: int = 0):
    """감시할 장소 (all=1 이면 꺼 둔 것도, enabled 포함)"""
    with db() as cur:
        if all:
            cur.execute("SELECT venue_id, name, lat, lon, radius, enabled FROM auto_place ORDER BY name")
            return [{**r, "enabled": bool(r["enabled"])} for r in cur.fetchall()]
        cur.execute("SELECT venue_id, name, lat, lon, radius FROM auto_place WHERE enabled=1 ORDER BY name")
        return cur.fetchall()


class PlacePatch(BaseModel):
    radius: int | None = Field(default=None, ge=50, le=500)
    enabled: bool | None = None
    name: str | None = Field(default=None, min_length=1, max_length=100)
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)


class PlaceNew(BaseModel):
    venue_id: str = Field(min_length=1, max_length=40)
    name: str = Field(min_length=1, max_length=100)
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    radius: int = Field(default=100, ge=50, le=500)


def _stay_center(cur, lat: float, lon: float) -> tuple[float, float, int]:
    """장소 좌표 200m 안 시야쥬 머문 곳들의 가운데 (실제 머무는 자리). 없으면 원래 좌표."""
    d = 0.0018
    cur.execute("SELECT lat, lon FROM day_visit WHERE lat BETWEEN %s AND %s AND lon BETWEEN %s AND %s",
                (lat - d, lat + d, lon - d * 1.3, lon + d * 1.3))
    vs = [(r["lat"], r["lon"]) for r in cur.fetchall() if TL.hav_km((lat, lon), (r["lat"], r["lon"])) <= 0.2]
    if not vs:
        return lat, lon, 0
    vs.sort()
    la = sorted(v[0] for v in vs)[len(vs) // 2]
    lo = sorted(v[1] for v in vs)[len(vs) // 2]
    return la, lo, len(vs)


@app.get("/api/autocheckin/venues")
def ac_venues(lat: float | None = None, lon: float | None = None, q: str = "", limit: int = 30):
    """장소 추가 후보: 내가 체크인했던 포스퀘어 장소 (이름 검색 또는 가까운 순). 이미 등록된 곳은 added=true."""
    limit = max(1, min(limit, 50))
    with db() as cur:
        args: list = []
        where = ""
        if q.strip():
            where = "WHERE VENUE LIKE %s"
            args.append(f"%{q.strip()}%")
        elif lat is not None and lon is not None:
            where = "WHERE LAT+0 BETWEEN %s AND %s AND LNG+0 BETWEEN %s AND %s"
            args += [lat - 0.02, lat + 0.02, lon - 0.025, lon + 0.025]
        cur.execute(f"SELECT FSQ_VENUEID AS venue_id, MAX(VENUE) AS name, MAX(CATEGORY) AS category, "
                    f"SUBSTRING_INDEX(GROUP_CONCAT(LAT ORDER BY FSQ_UNIXTIME DESC), ',', 1)+0 AS lat, "
                    f"SUBSTRING_INDEX(GROUP_CONCAT(LNG ORDER BY FSQ_UNIXTIME DESC), ',', 1)+0 AS lon, "
                    f"COUNT(*) AS n, MAX(FSQ_UNIXTIME) AS last FROM swarm.FSQ_Swarm {where} "
                    f"GROUP BY FSQ_VENUEID ORDER BY n DESC LIMIT 400", args)
        rows = cur.fetchall()
        cur.execute("SELECT venue_id FROM auto_place")
        added = {r["venue_id"] for r in cur.fetchall()}
    for r in rows:
        r["lat"], r["lon"] = float(r["lat"]), float(r["lon"])
        r["dist_m"] = round(TL.hav_km((lat, lon), (r["lat"], r["lon"])) * 1000) if lat is not None and lon is not None else None
        r["added"] = r["venue_id"] in added
        r["last"] = int(r["last"]) * 1000
    if not q.strip() and lat is not None and lon is not None:
        rows = [r for r in rows if r["dist_m"] <= 1500]
        rows.sort(key=lambda r: (r["dist_m"] // 100, -r["n"]))
    return rows[:limit]


@app.post("/api/autocheckin/places")
def ac_place_add(body: PlaceNew, center: int = 1):
    """장소 추가. center=1 이면 감시 중심을 실제로 머물던 자리(시야쥬 머문 곳)로 옮김."""
    with db() as cur:
        cur.execute("SELECT 1 FROM auto_place WHERE venue_id=%s", (body.venue_id,))
        if cur.fetchone():
            raise HTTPException(409, "이미 등록된 장소")
        if _enabled_count(cur) >= AC_MAX_PLACES:
            raise HTTPException(409, AC_MAX_MSG)
        la, lo, n = _stay_center(cur, body.lat, body.lon) if center else (body.lat, body.lon, 0)
        cur.execute("INSERT INTO auto_place (venue_id, name, lat, lon, radius, enabled) VALUES (%s,%s,%s,%s,%s,1)",
                    (body.venue_id, body.name, la, lo, body.radius))
        cur.execute("SELECT venue_id, name, lat, lon, radius, enabled FROM auto_place WHERE venue_id=%s", (body.venue_id,))
        r = cur.fetchone()
    return {**r, "enabled": bool(r["enabled"]), "centered_from": n}


@app.delete("/api/autocheckin/places/{venue_id}")
def ac_place_delete(venue_id: str):
    """장소 삭제 (지난 들어옴·나감 기록은 남음)"""
    with db() as cur:
        n = cur.execute("DELETE FROM auto_place WHERE venue_id=%s", (venue_id,))
    if not n:
        raise HTTPException(404, "없는 장소")
    return {"ok": True}


@app.patch("/api/autocheckin/places/{venue_id}")
def ac_place_patch(venue_id: str, body: PlacePatch):
    sets, args = [], []
    for k in ("radius", "enabled", "name", "lat", "lon"):
        v = getattr(body, k)
        if v is not None:
            sets.append(f"{k}=%s")
            args.append(int(v) if k == "enabled" else v)
    if not sets:
        raise HTTPException(400, "바꿀 값 없음")
    with db() as cur:
        if body.enabled and _enabled_count(cur, exclude=venue_id) >= AC_MAX_PLACES:
            raise HTTPException(409, AC_MAX_MSG)
        n = cur.execute(f"UPDATE auto_place SET {', '.join(sets)} WHERE venue_id=%s", (*args, venue_id))
        cur.execute("SELECT venue_id, name, lat, lon, radius, enabled FROM auto_place WHERE venue_id=%s", (venue_id,))
        r = cur.fetchone()
    if not r:
        raise HTTPException(404, "없는 장소")
    return {**r, "enabled": bool(r["enabled"]), "changed": bool(n)}


class PlaceEventIn(BaseModel):
    client_id: str = Field(min_length=8, max_length=64)
    venue_id: str = Field(max_length=40)
    kind: str                # enter | exit
    ts: float                # epoch ms (기기가 감지한 시각)
    lat: float | None = None
    lon: float | None = None
    acc: float | None = None


@app.post("/api/autocheckin/event")
def ac_event(body: PlaceEventIn):
    if body.kind not in ("enter", "exit"):
        raise HTTPException(400, "kind 는 enter / exit")
    with db() as cur:
        cur.execute("SELECT 1 FROM auto_place WHERE venue_id=%s", (body.venue_id,))
        if not cur.fetchone():
            raise HTTPException(404, "등록 안 된 장소")
        n = cur.execute("INSERT IGNORE INTO place_event (client_id, venue_id, kind, at, lat, lon, acc) "
                        "VALUES (%s,%s,%s,%s,%s,%s,%s)",
                        (body.client_id, body.venue_id, body.kind, ms_to_dt(body.ts), body.lat, body.lon, body.acc))
    ac_process()
    return {"ok": True, "duplicate": n == 0}


@app.get("/api/autocheckin/events")
def ac_events(days: int = 7):
    with db() as cur:
        cur.execute("SELECT e.id, e.venue_id, p.name, e.kind, COALESCE(e.adj_at, e.at) AS at, e.at AS detected_at, "
                    "e.status, e.note, e.fsq_id, e.received_at "
                    "FROM place_event e LEFT JOIN auto_place p USING (venue_id) "
                    "WHERE e.at >= UTC_TIMESTAMP() - INTERVAL %s DAY ORDER BY e.at DESC", (min(days, 60),))
        rows = cur.fetchall()
    for r in rows:
        r["at"], r["detected_at"], r["received_at"] = dt_to_ms(r["at"]), dt_to_ms(r["detected_at"]), dt_to_ms(r["received_at"])
    return {"write": AC_WRITE, "events": rows}


_ac_lock = threading.Lock()


def _ac_forward(venue_id: str, at: datetime) -> str:
    """fsq_map 에 체크인 저장 → FSQ_ID (ManuallySaved_…)."""
    import json as _json
    import urllib.request
    url = os.environ.get("FSQ_AUTOCHECKIN_URL") or (os.environ.get("FSQ_CARPLAY_URL", "").replace("/api/carplay/event", "/api/autocheckin"))
    tok = os.environ.get("CARPLAY_API_TOKEN")
    if not url or not tok:
        raise RuntimeError("전달 설정 없음")
    data = {"venue_id": venue_id, "timestamp": at.replace(tzinfo=timezone.utc).timestamp(), "device": "Sillage"}
    req = urllib.request.Request(url, data=_json.dumps(data).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {tok}"})
    with urllib.request.urlopen(req, timeout=15) as r:
        out = _json.loads(r.read() or b"{}")
    return out.get("fsq_id") or ("중복:" + str(out.get("existing") or ""))


AC_ADJ_WAIT = timedelta(minutes=12)   # 도착 보정에 필요한 위치 점이 아직 안 올라왔으면 이만큼까지 기다림


def _ac_adjust(cur, vid: str, now: datetime) -> None:
    """확정된 진입·이탈의 실제 시각(adj_at): 진입 = 반경 안에서 멈춘 때, 이탈 = 움직이기 시작한 때. 못 찾으면 감지 시각."""
    cur.execute("SELECT id, kind, at FROM place_event WHERE venue_id=%s AND status IN ('confirmed','failed') "
                "AND adj_at IS NULL AND at > %s", (vid, now - timedelta(days=1)))
    todo = cur.fetchall()
    if not todo:
        return
    cur.execute("SELECT lat, lon, radius FROM auto_place WHERE venue_id=%s", (vid,))
    pl = cur.fetchone()
    for e in todo:
        at, adj = e["at"], None
        if e["kind"] == "enter":
            if pl:
                cur.execute("SELECT MAX(ts) AS m FROM day_pt")
                last = (cur.fetchone() or {}).get("m")
                if (not last or last < at + timefix.ARRIVE_FWD) and now - at < AC_ADJ_WAIT:
                    continue          # 진입 뒤 위치 점이 아직 덜 올라옴 → 다음 차례에
                cur.execute("SELECT ts, lat, lon, spd FROM day_pt WHERE ts BETWEEN %s AND %s AND src IN ('gps','trk') ORDER BY ts",
                            (at - timefix.ARRIVE_BACK, at + timefix.ARRIVE_FWD))
                adj = timefix.stop_time(cur.fetchall(), at, (pl["lat"], pl["lon"]), pl["radius"])
        else:
            cur.execute("SELECT MAX(at) AS m FROM place_event WHERE venue_id=%s AND kind='enter' AND at < %s "
                        "AND status IN ('confirmed','sent','failed')", (vid, at))
            prev = (cur.fetchone() or {}).get("m")
            cur.execute("SELECT ts, act FROM day_act WHERE ts BETWEEN %s AND %s ORDER BY ts", (at - timedelta(hours=1), at))
            adj = timefix.move_start(cur.fetchall(), at, not_before=prev)
        cur.execute("UPDATE place_event SET adj_at=%s WHERE id=%s", (adj or at, e["id"]))


def ac_process(now: datetime | None = None) -> dict:
    """대기 중인 진입·이탈 확정 → (쓰기 켜짐이면) 진입을 체크인으로 전달. 1분마다 + 이벤트 받을 때."""
    now = now or datetime.now(timezone.utc).replace(tzinfo=None)
    done = {"confirmed": 0, "ignored": 0, "sent": 0, "failed": 0}
    with _ac_lock, db() as cur:
        cur.execute("SELECT DISTINCT venue_id FROM place_event WHERE status='pending' "
                    "OR (status='failed' AND kind='enter' AND at > %s) "
                    "OR (status='confirmed' AND (adj_at IS NULL OR (kind='enter' AND fsq_id IS NULL)) AND at > %s)",
                    (now - timedelta(days=1), now - timedelta(days=1)))
        for (vid,) in [(r["venue_id"],) for r in cur.fetchall()]:
            cur.execute("SELECT id, kind, at, status, received_at AS recv FROM place_event WHERE venue_id=%s AND at > %s ORDER BY at, id",
                        (vid, now - timedelta(days=2)))
            evs = cur.fetchall()
            for eid, (st, note) in autocheckin.decide(list(evs), now).items():
                cur.execute("UPDATE place_event SET status=%s, note=%s, resolved_at=%s WHERE id=%s",
                            (st, note, now, eid))
                done[st] += 1
            _ac_adjust(cur, vid, now)
            if not AC_WRITE:
                continue
            cur.execute("SELECT id, adj_at FROM place_event WHERE venue_id=%s AND kind='enter' AND fsq_id IS NULL "
                        "AND adj_at IS NOT NULL AND (status='confirmed' OR status='failed') AND at > %s", (vid, now - timedelta(days=1)))
            for r in cur.fetchall():
                try:
                    fid = _ac_forward(vid, r["adj_at"])
                    cur.execute("UPDATE place_event SET status='sent', fsq_id=%s, note=NULL WHERE id=%s", (fid[:40], r["id"]))
                    done["sent"] += 1
                except Exception as e:
                    cur.execute("UPDATE place_event SET status='failed', note=%s WHERE id=%s", (str(e)[:250], r["id"]))
                    done["failed"] += 1
    return done


def _ac_loop():
    while True:
        try:
            ac_process()
        except Exception as e:
            print(f"[autocheckin] {e}", flush=True)
        time.sleep(60)


@app.on_event("startup")
def _ac_start():
    if os.environ.get("AC_LOOP", "1") == "1":
        threading.Thread(target=_ac_loop, daemon=True).start()
