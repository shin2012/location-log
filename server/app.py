"""위치 기록 API — location.b-612.kr/api/*

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
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

app = FastAPI(title="location-log")
LOG_DIR = Path(os.environ.get("LOG_DIR", "/data"))
APP_TOKEN = os.environ.get("APP_TOKEN", "")


# 네이티브 앱 경로(/app-api/)는 로그인(tinyauth)을 거치지 않으므로 토큰으로 막음.
# 웹 nginx가 /app-api/ 요청에만 X-App-Gate: 1 을 붙이고, /api/ 요청에서는 지움.
@app.middleware("http")
async def app_gate(request: Request, call_next):
    if request.headers.get("x-app-gate") == "1":
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
            "sent_daily_at": dt_to_ms(r["sent_daily_at"]), "mode": r.get("mode", "car")}


@app.get("/api/health")
def health():
    with db() as cur:
        cur.execute("SELECT 1 AS ok")
        return {"ok": True}


@app.get("/api/config")
def config():
    return {"naver_map_key": os.environ.get("NCP_MAPS_KEY_ID", ""),
            "daily_ready": True}


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


@app.patch("/api/tracks/{tid}")
def patch_track(tid: int, body: TrackPatch):
    with db() as cur:
        if body.name is not None:
            cur.execute("UPDATE track SET name=%s WHERE id=%s", (body.name.strip(), tid))
        if body.ended_at is not None:
            cur.execute("UPDATE track SET ended_at=%s WHERE id=%s", (ms_to_dt(body.ended_at), tid))
        if body.mode is not None:
            if body.mode not in MODES:
                raise HTTPException(400, f"mode must be one of {MODES}")
            cur.execute("UPDATE track SET mode=%s WHERE id=%s", (body.mode, tid))
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
    rows = [(ms_to_dt(p.ts).replace(second=0, microsecond=0), max(0, min(65535, p.steps)), p.dist)
            for p in body.steps]
    if rows:
        with db() as cur:
            cur.executemany("REPLACE INTO day_step (ts, steps, dist_m) VALUES (%s,%s,%s)", rows)
    return {"ok": True, "n": len(rows)}


@app.get("/api/day")
def day_list(limit: int = 90):
    """기록 있는 날짜 (한국 시각) + 점 수"""
    with db() as cur:
        cur.execute("SELECT DATE(CONVERT_TZ(ts, '+00:00', '+09:00')) AS d, COUNT(*) AS n, MIN(ts) AS a, MAX(ts) AS b "
                    "FROM day_pt GROUP BY d ORDER BY d DESC LIMIT %s", (max(1, min(limit, 400)),))
        return [{"date": r["d"].isoformat(), "n_points": r["n"], "first": dt_to_ms(r["a"]), "last": dt_to_ms(r["b"])}
                for r in cur.fetchall()]


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


# ─── 자동 체크인 (IFTTT·람다 대체) ───
import threading  # noqa: E402

import autocheckin  # noqa: E402

AC_WRITE = os.environ.get("AUTOCHECKIN_WRITE", "0") == "1"   # 0 = 기록만 (함께 돌려 보는 기간)


@app.get("/api/autocheckin/places")
def ac_places():
    with db() as cur:
        cur.execute("SELECT venue_id, name, lat, lon, radius FROM auto_place WHERE enabled=1 ORDER BY name")
        return cur.fetchall()


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
        cur.execute("SELECT e.id, e.venue_id, p.name, e.kind, e.at, e.status, e.note, e.fsq_id, e.received_at "
                    "FROM place_event e LEFT JOIN auto_place p USING (venue_id) "
                    "WHERE e.at >= UTC_TIMESTAMP() - INTERVAL %s DAY ORDER BY e.at DESC", (min(days, 60),))
        rows = cur.fetchall()
    for r in rows:
        r["at"], r["received_at"] = dt_to_ms(r["at"]), dt_to_ms(r["received_at"])
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


def ac_process(now: datetime | None = None) -> dict:
    """대기 중인 진입·이탈 확정 → (쓰기 켜짐이면) 진입을 체크인으로 전달. 1분마다 + 이벤트 받을 때."""
    now = now or datetime.now(timezone.utc).replace(tzinfo=None)
    done = {"confirmed": 0, "ignored": 0, "sent": 0, "failed": 0}
    with _ac_lock, db() as cur:
        cur.execute("SELECT DISTINCT venue_id FROM place_event WHERE status='pending' "
                    "OR (status='failed' AND kind='enter' AND at > %s)", (now - timedelta(days=1),))
        for (vid,) in [(r["venue_id"],) for r in cur.fetchall()]:
            cur.execute("SELECT id, kind, at, status, received_at AS recv FROM place_event WHERE venue_id=%s AND at > %s ORDER BY at, id",
                        (vid, now - timedelta(days=2)))
            evs = cur.fetchall()
            for eid, (st, note) in autocheckin.decide(list(evs), now).items():
                cur.execute("UPDATE place_event SET status=%s, note=%s, resolved_at=%s WHERE id=%s",
                            (st, note, now, eid))
                done[st] += 1
            if not AC_WRITE:
                continue
            cur.execute("SELECT id, at FROM place_event WHERE venue_id=%s AND kind='enter' AND fsq_id IS NULL "
                        "AND (status='confirmed' OR status='failed') AND at > %s", (vid, now - timedelta(days=1)))
            for r in cur.fetchall():
                try:
                    fid = _ac_forward(vid, r["at"])
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


# 센서 원본 녹화 (알고리즘 조정용, /lab)
@app.post("/api/log")
async def post_log(request: Request):
    body = await request.body()
    if not body or len(body) > 60 * 1024 * 1024:
        raise HTTPException(413, "size")
    try:
        rows = len(json.loads(body).get("rows", []))
    except Exception:
        raise HTTPException(400, "json")
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    name = time.strftime("%Y%m%d-%H%M%S", time.localtime()) + f"-{rows}.json"
    (LOG_DIR / name).write_bytes(body)
    return {"name": name, "rows": rows}
