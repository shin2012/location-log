"""위치 기록 API — location.b-612.kr/api/*

경로(track)와 점(track_pt)을 MariaDB location_log 에 저장. 점은 (track_id, seq) 기준 REPLACE 라서
같은 점을 다시 보내도 안전하고, 터널 구간 사후 보정값도 같은 seq 로 덮어씀.
"""
import json
import math
import os
import time
from contextlib import contextmanager
from datetime import datetime, timezone
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
