"""python3 tests/test_floors.py"""
import json
import math
import sys
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))
import floors as F  # noqa: E402

T0 = datetime(2026, 11, 11, 0, 0)
V = {"start": T0, "end": T0 + timedelta(hours=4), "lat": 37.5, "lon": 127.0}


def series(parts):
    """parts: [(초, 끝 높이)] — 앞 값에서 끝 높이까지 그 시간 동안 고르게. 1초 간격 표본(앱은 8cm 바뀔 때마다 저장)"""
    out, t, h = [], T0, 0.0
    out.append((t, h))
    for dur, h1 in parts:
        for i in range(1, dur + 1):
            out.append((t + timedelta(seconds=i), h + (h1 - h) * i / dur))
        t += timedelta(seconds=dur)
        h = h1
    # 앱처럼 솎기: 8cm 넘게 바뀌거나 60초
    th, last = [], None
    for x in out:
        if last is None or abs(x[1] - last[1]) >= 0.08 or (x[0] - last[0]).total_seconds() >= 60:
            th.append(x)
            last = x
    return th


def test_drift_only():
    # 실측: 1.5시간 +4m (날씨) → 층 이동 없음
    assert F.detect(series([(5400, 4.0)])) == []


def test_office_elevator():
    hs = series([(600, 0.1), (20, 21.0), (3 * 3600, 21.0 + 9.0), (25, 9.0 + 0.3), (600, 9.4)])
    ev = F.detect(hs)
    assert len(ev) == 2, ev
    assert abs(ev[0]["dh"] - 21) < 1 and abs(ev[1]["dh"] + 21) < 1.5
    segs = F.segments(V, hs, [], [])
    assert [s["label"] for s in segs] == ["1F", "7F", "1F"], segs   # 21m = 4.5 + 4.7×3.5 → 7F
    assert segs[1]["via"] == "elevator" and segs[2]["via"] == "elevator"


def test_stairs_with_steps():
    hs = series([(300, 0.0), (70, 5.2), (900, 5.3)])
    m = T0.replace(second=0) + timedelta(minutes=5)
    steps = [{"ts": m, "steps": 46}, {"ts": m + timedelta(minutes=1), "steps": 20}]
    segs = F.segments(V, hs, steps, [])
    assert len(segs) == 2 and segs[1]["via"] == "stairs", segs
    assert segs[1]["label"] == "2F"           # 5.2m: 1층 층고 4.5 기준 → 2F
    # 걸음 없이 천천히 = 에스컬레이터
    assert F.segments(V, hs, [], [])[1]["via"] == "escalator"
    # 만보계 계단 층수가 있으면 계단
    assert F.segments(V, hs, [{"ts": m, "steps": 0, "floors_up": 1}], [])[1]["via"] == "stairs"


def test_calibration_and_wifi():
    hs = series([(600, 0.0), (20, 21.0), (3600, 21.2)])
    segs = F.segments(V, hs, [], [])
    t7 = segs[1]["start"]
    # 사용자가 이 구간을 6F 로 확정 → 그 구간은 확정, 같은 장소 다음엔 층 높이 21/5 = 4.2 로
    cal = [{"ts": t7, "lat": 37.5, "lon": 127.0, "dh": segs[1]["dh"], "level": 5, "ap": None}]
    s2 = F.segments(V, hs, [], cal)
    assert s2[1]["label"] == "6F" and s2[1]["est"] is False
    V2 = dict(V, start=T0 + timedelta(days=1), end=T0 + timedelta(days=1, hours=2))
    hs2 = [(t + timedelta(days=1), h) for t, h in hs]
    assert F.segments(V2, hs2, [], cal)[1]["label"] == "6F"
    # 공유기: 같은 공유기에서 9F 로 두 번 확정 → 기압 추정보다 공유기
    wifi = [{"ts": T0, "bssid": "11:22:33:44:55:01"}, {"ts": T0 + timedelta(minutes=10, seconds=20), "bssid": "AA:BB:CC:DD:EE:02"}]
    calw = [{"ts": T0 - timedelta(days=d), "lat": 37.5, "lon": 127.0, "dh": 21.0, "level": 8, "ap": "aa:bb:cc:dd:ee"} for d in (3, 4)]
    s3 = F.segments(V, hs, [], calw, wifi)
    assert s3[1]["ap"] == "aa:bb:cc:dd:ee" and s3[1]["label"] == "9F"


def test_parking_base():
    # 지하 2층(-7m)에 주차하고 엘리베이터로 +28m → 지상 기준 +21m → 7F
    hs = series([(120, 0.0), (25, 28.0), (900, 28.1)])
    segs = F.segments(V, hs, [], [], base_dh=-7.0)
    assert [s["label"] for s in segs] == ["B2", "7F"], segs


def test_small_wobble_ignored():
    hs = series([(600, 0.0), (10, 1.5), (600, 1.5), (10, 0.0), (600, 0.0)])   # 1.5m 흔들림
    assert F.detect(hs) == []


def test_real_20261111():
    """실측: 13:59 주차장 진입(+2m 경사로), 14:01 주차(차 문 +1.2m), 14:02 2층(+5.2m/8초, 사용자 확인).
    그 뒤 2시간 걸음 0·정지 — 기압은 날씨로 +3.7m 천천히 → 더 나뉘면 안 됨"""
    d = json.loads((Path(__file__).parent / "data" / "floors_20261111.json").read_text())
    baro = [{"ts": datetime.fromisoformat(t), "kpa": k} for t, k in d["baro"]]
    steps = [{"ts": datetime.fromisoformat(t), "steps": n} for t, n in d["steps"]]
    v = {"start": datetime(2026, 11, 11, 4, 59, 39), "end": datetime(2026, 11, 11, 7, 15), "lat": 37.5, "lon": 127.0}
    segs = F.segments(v, F.heights(baro), steps, [], base_dh=0.44)
    assert [s["label"] for s in segs] == ["1F", "2F"], [(s["label"], s["start"], s["dh"]) for s in segs]
    assert segs[1]["via"] == "elevator", segs[1]
    assert segs[1]["start"].strftime("%H:%M") == "05:02"


def _real():
    d = json.loads((Path(__file__).parent / "data" / "floors_20261111.json").read_text())
    baro = [{"ts": datetime.fromisoformat(t), "kpa": k} for t, k in d["baro"]]
    steps = [{"ts": datetime.fromisoformat(t), "steps": n} for t, n in d["steps"]]
    v = {"start": datetime(2026, 11, 11, 4, 59, 39), "end": datetime(2026, 11, 11, 7, 15), "lat": 37.5, "lon": 127.0}
    return v, F.heights(baro), steps


def test_watch_excursion_real():
    """실제 상황: 폰은 2층 사무실에 두고 워치만 차고 3층 다녀옴 (14:31 계단, 14:49 돌아옴). 워치 기록은 흉내"""
    v, hs, steps = _real()
    U = lambda hm: datetime(2026, 11, 11, int(hm[:2]) - 9, int(hm[3:5]), int(hm[6:8]) if len(hm) > 5 else 0)
    hk = [
        {"kind": "steps", "device": "watch", "start": U("14:30"), "end": U("14:32"), "value": 70},
        {"kind": "flights", "device": "watch", "start": U("14:31:00"), "end": U("14:31:40"), "value": 1},
        {"kind": "steps", "device": "watch", "start": U("14:40"), "end": U("14:41"), "value": 3},   # 서서 얘기
        {"kind": "steps", "device": "watch", "start": U("14:49"), "end": U("14:51"), "value": 60},  # 돌아옴
        {"kind": "flights", "device": "phone", "start": U("15:00"), "end": U("15:01"), "value": 1},  # 폰 기록은 무시
    ]
    segs = F.segments(v, hs, steps, [], base_dh=0.44, hk=hk)
    hm = lambda t: (t + timedelta(hours=9)).strftime("%H:%M")
    # 폰으로 확인된 층은 1F·2F 그대로, 워치 계단으로 다녀온 3F 는 2F 아래 하위 항목 (시간순: 3F → 돌아옴)
    assert [(g["label"], hm(g["start"])) for g in segs] == [("1F", "13:59"), ("2F", "14:02")], segs
    subs = [(x["kind"], hm(x["start"]), x.get("label")) for x in segs[1]["subs"]]
    assert subs == [("floor", "14:31", "3F"), ("back", "14:49", "2F")], subs
    assert segs[0]["subs"] == []
    # 폰도 같이 움직였으면(폰 걸음 있음) 워치 층은 안 씀 — 기압이 맡음
    steps2 = steps + [{"ts": U("14:31"), "steps": 40}]
    assert all(not g["subs"] for g in F.segments(v, hs, steps2, [], base_dh=0.44, hk=hk))


def test_watch_only_no_baro_event():
    """기압 층 이동 없는 머묾에서도 워치 계단만으로 나뉨, 확정하면 그 층"""
    hs = series([(7200, 0.5)])
    t = T0 + timedelta(minutes=30)
    hk = [{"kind": "flights", "device": "watch", "start": t, "end": t + timedelta(seconds=40), "value": 2},
          {"kind": "steps", "device": "watch", "start": t + timedelta(minutes=20), "end": t + timedelta(minutes=21), "value": 40}]
    segs = F.segments(V, hs, [], [], hk=hk)
    assert len(segs) == 1 and segs[0]["label"] == "1F"
    assert [(x["kind"], x["label"]) for x in segs[0]["subs"]] == [("floor", "3F"), ("back", "1F")], segs
    cal = [{"ts": segs[0]["subs"][0]["start"], "lat": 37.5, "lon": 127.0, "dh": segs[0]["subs"][0]["dh"], "level": 3, "ap": None}]
    assert F.segments(V, hs, [], cal, hk=hk)[0]["subs"][0]["label"] == "4F"


def test_watch_real_day():
    """실측 2026-11-11 하루 워치 기록: 워치 계단(07:54·10:28·12:32)은 모두 폰도 같이 움직임 → 워치 층 없음"""
    d = json.loads((Path(__file__).parent / "data" / "watch_20261111.json").read_text())
    steps = [{"ts": datetime.fromisoformat(t), "steps": n} for t, n in d["steps"]]
    hk = [{"kind": k, "start": datetime.fromisoformat(a), "end": datetime.fromisoformat(b), "value": v, "device": dv}
          for k, a, b, v, dv in d["hk"]]
    day = {"start": datetime(2026, 11, 10, 15), "end": datetime(2026, 11, 11, 9), "lat": 37.5, "lon": 127.0}
    assert F.excursions(day, steps, hk, []) == []


if __name__ == "__main__":
    for k, f in list(globals().items()):
        if k.startswith("test_"):
            f()
            print("ok", k)
