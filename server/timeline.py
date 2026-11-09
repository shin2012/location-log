"""하루 타임라인 (앱 '타임라인' 탭): 머문 곳과 이동을 시간순으로.

데일리요섭 app/sillage.py 와 같은 규칙 (머문 곳 합치기 300m·10분, 머문 곳 밖 점 묶음 = 이동, 15분 끊기면 나눔).
DB 를 읽는 부분(build)과 계산(순수 함수)을 나눠 시험하기 쉽게 함. 시각은 모두 UTC naive.
"""
import math
from datetime import datetime, timedelta

MERGE_KM = 0.3
MERGE_GAP = timedelta(minutes=10)
RUN_GAP = timedelta(minutes=15)
JUMP_MPS = 70
PATH_SRC = ("gps", "fill", "trk", "imu")
MOVING = ("walk", "run", "bike", "car")


def hav_km(a, b) -> float:
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371.0088 * math.asin(math.sqrt(h))


def merge_visits(vs: list[dict]) -> list[dict]:
    """vs: [{start,end,lat,lon}] → 같은 곳(300m) 10분 안 끊김은 하나로. 좌표는 오래 머문 쪽."""
    out: list[dict] = []
    for v in sorted(vs, key=lambda x: x["start"]):
        if out:
            p = out[-1]
            if v["start"] - p["end"] <= MERGE_GAP and hav_km((p["lat"], p["lon"]), (v["lat"], v["lon"])) <= MERGE_KM:
                if (v["end"] - v["start"]) > p["_len"]:
                    p.update(lat=v["lat"], lon=v["lon"], _len=v["end"] - v["start"])
                p["end"] = max(p["end"], v["end"])
                p["open"] = p.get("open") or v.get("open")
                continue
        out.append(dict(v, _len=v["end"] - v["start"]))
    for v in out:
        v.pop("_len", None)
    return out


def runs(pts: list[dict], visits: list[dict]) -> list[list[dict]]:
    """머문 곳 밖의 점을 시간 끊김(15분)으로 묶음. 튀는 점(70m/s 초과) 제외."""
    def inside(p):
        return any(v["start"] <= p["ts"] <= v["end"] and hav_km((v["lat"], v["lon"]), (p["lat"], p["lon"])) <= MERGE_KM
                   for v in visits)
    out, cur = [], []
    for p in pts:
        if inside(p):
            if cur:
                out.append(cur)
            cur = []
            continue
        if cur:
            q = cur[-1]
            dt = (p["ts"] - q["ts"]).total_seconds()
            if dt > RUN_GAP.total_seconds():
                out.append(cur)
                cur = []
            elif dt > 0 and hav_km((q["lat"], q["lon"]), (p["lat"], p["lon"])) * 1000 / dt > JUMP_MPS:
                continue
        cur.append(p)
    if cur:
        out.append(cur)
    return out


def act_durations(acts: list[dict], t0: datetime, t1: datetime) -> dict:
    """acts: 바뀐 시각 [{ts, act}] (시간순, t0 이전 마지막 하나 포함 가능) → [t0,t1] 안 방식별 초."""
    dur: dict[str, float] = {}
    for i, a in enumerate(acts):
        s = max(a["ts"], t0)
        e = min(acts[i + 1]["ts"] if i + 1 < len(acts) else t1, t1)
        if e > s:
            k = "walk" if a["act"] == "run" else a["act"]
            dur[k] = dur.get(k, 0) + (e - s).total_seconds()
    return dur


def move_mode(run: list[dict], acts: list[dict], steps: list[dict]) -> str:
    """car | walk | bike | unknown — 움직인 시간이 가장 긴 방식(2분 미만 무시) → 점에 붙은 방식 → 걸음 → 속도."""
    t0, t1 = run[0]["ts"], run[-1]["ts"]
    dur = {k: v for k, v in act_durations(acts, t0, t1).items() if k in ("car", "walk", "bike") and v >= 120}
    if dur:
        return max(dur, key=dur.get)
    pd: dict[str, int] = {}
    for p in run:
        if p.get("act") in MOVING:
            k = "walk" if p["act"] == "run" else p["act"]
            pd[k] = pd.get(k, 0) + 1
    if pd:
        return max(pd, key=pd.get)
    active = sum(1 for s in steps if t0 <= s["ts"] <= t1 and s["steps"] >= 60)
    if active >= 3:
        return "walk"
    secs = (t1 - t0).total_seconds()
    km = sum(hav_km((a["lat"], a["lon"]), (b["lat"], b["lon"])) for a, b in zip(run, run[1:]))
    if secs > 0 and km / (secs / 3600) >= 20:
        return "car"
    return "unknown"


def simplify(path: list, n: int = 300) -> list:
    if len(path) <= n:
        return path
    step = len(path) / n
    out = [path[int(i * step)] for i in range(n)]
    return out + [path[-1]]


def build_items(day0: datetime, day1: datetime, visits_raw: list[dict], pts: list[dict], acts: list[dict],
                steps: list[dict], carplay: list[dict], places: list[dict]) -> dict:
    """[day0, day1) 하루 (UTC). carplay: [{event, at}] 시간순. places: 자동 체크인 장소 [{name, lat, lon, radius}]."""
    visits = merge_visits(visits_raw)
    items = []
    for v in visits:
        if v["end"] <= day0 or v["start"] >= day1:
            continue
        s, e = max(v["start"], day0), min(v["end"], day1)
        pl = next((p for p in places if hav_km((p["lat"], p["lon"]), (v["lat"], v["lon"])) * 1000 <= max(150, p["radius"] * 1.5)), None)
        items.append({"kind": "visit", "start": s, "end": e, "lat": v["lat"], "lon": v["lon"],
                      "name": pl["name"] if pl else None, "open": bool(v.get("open")),
                      "minutes": round((e - s).total_seconds() / 60)})
    # 운전 = CarPlay 연결 구간
    sessions, on = [], None
    for c in carplay:
        if c["event"] == "car_start":
            on = on or c["at"]
        elif c["event"] == "car_end" and on:
            sessions.append((on, c["at"]))
            on = None
    if on:
        sessions.append((on, day1))
    moves_km = drive_min = 0.0
    for r in runs(pts, visits):
        if len(r) < 2 or r[-1]["ts"] < day0 or r[0]["ts"] >= day1:
            continue
        km = sum(hav_km((a["lat"], a["lon"]), (b["lat"], b["lon"])) for a, b in zip(r, r[1:]))
        if km < 0.05:
            continue
        t0, t1 = r[0]["ts"], r[-1]["ts"]
        mode = move_mode(r, acts, steps)
        drove = any(a <= t1 and t0 <= b for a, b in sessions)
        if drove:
            mode = "car"
        st = sum(s["steps"] for s in steps if t0 <= s["ts"] <= t1)
        items.append({"kind": "move", "start": t0, "end": t1, "km": round(km, 2), "mode": mode, "drove": drove,
                      "steps": st, "est": any(p["src"] == "imu" for p in r),
                      "path": simplify([[round(p["lat"], 6), round(p["lon"], 6)] for p in r])})
        moves_km += km
        if drove:
            drive_min += (t1 - t0).total_seconds() / 60
    items.sort(key=lambda x: x["start"])
    total_steps = sum(s["steps"] for s in steps if day0 <= s["ts"] < day1)
    return {"items": items, "summary": {"km": round(moves_km, 1), "steps": total_steps, "drive_min": round(drive_min),
                                        "visits": sum(1 for i in items if i["kind"] == "visit")}}
