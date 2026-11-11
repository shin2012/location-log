"""python3 tests/test_parking.py"""
import sys
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))
import parking as P  # noqa: E402
import timeline as TL  # noqa: E402

HOME = (37.5000, 127.0000)
FAR = (37.6000, 127.1000)


def cal(dh, level, at=HOME):
    return {"lat": at[0], "lon": at[1], "dh": dh, "level": level}


def test_basic():
    assert P.label(-3) == "B3" and P.label(0) == "1F" and P.label(2) == "3F"
    assert abs(P.dh_from_kpa(101.325, 101.325 - 0.1) - 8.33) < 0.05   # 1 hPa ≈ 8.4 m
    assert P.dh_from_kpa(101.0, 101.1) < 0                              # 기압 오르면 내려간 것
    # 보정 없음: 3.2m
    assert P.estimate(-9.8, *HOME, []) == -3
    assert P.estimate(-1.0, *HOME, []) == 0
    assert P.estimate(6.5, *HOME, []) == 2


def test_one_correction_sets_floor_height():
    # 이 주차장은 층이 높음: -9.8m 가 실제 B2 → 4.9m/층
    c = [cal(-9.8, -2)]
    assert P.estimate(-9.8, *HOME, []) == -3          # 보정 전
    assert P.estimate(-9.9, *HOME, c) == -2           # 보정 뒤
    assert P.estimate(-14.5, *HOME, c) == -3
    # 먼 곳은 전체 중앙값(4.9) 사용 — 장소 기록 없음
    assert P.model(*FAR, c) == (4.9, 0.0)


def test_two_levels_fit_offset():
    # 입구가 지면보다 2m 낮게 시작: B1=-5.5, B2=-9.0 → a=3.5, b=-2
    c = [cal(-5.5, -1), cal(-9.0, -2)]
    a, b = P.model(*HOME, c)
    assert abs(a - 3.5) < 1e-9 and abs(b + 2.0) < 1e-9
    assert P.estimate(-12.4, *HOME, c) == -3


def test_ground_only_offset():
    c = [cal(1.5, 0)]          # 지상 1층인데 +1.5m (도로보다 높은 마당)
    a, b = P.model(*HOME, c)
    assert a == P.DEF_A and abs(b - 1.5) < 1e-9
    assert P.estimate(1.7, *HOME, c) == 0


def test_bad_ratio_falls_back():
    c = [cal(-1.0, -1)]        # 1m 인데 B1 → 1m/층은 말이 안 됨 → b 로
    a, b = P.model(*HOME, c)
    assert a == P.DEF_A and abs(b - 2.2) < 1e-9
    assert P.estimate(-1.2, *HOME, c) == -1


def test_timeline_attach():
    t = datetime(2026, 11, 11, 1, 0)
    pts = [{"ts": t + timedelta(minutes=i), "lat": 37.5 + i * 0.002, "lon": 127.0, "src": "gps", "act": "car"} for i in range(10)]
    cp = [{"event": "car_start", "at": t}, {"event": "car_end", "at": t + timedelta(minutes=11)}]
    parks = [{"ts": t + timedelta(minutes=11), "level": -3, "est": True}]
    out = TL.build_items(t - timedelta(hours=1), t + timedelta(hours=5), [], pts, [], [], cp, [], [], parks)
    mv = [i for i in out["items"] if i["kind"] == "move"]
    assert mv and mv[0]["park"]["label"] == "B3" and mv[0]["park"]["est"] is True
    # 운전 아닌 이동에는 안 붙음
    out = TL.build_items(t - timedelta(hours=1), t + timedelta(hours=5), [], pts, [], [], [], [], [],
                         [{"ts": t + timedelta(hours=3), "level": -1, "est": False}])
    assert "park" not in [i for i in out["items"] if i["kind"] == "move"][0]


if __name__ == "__main__":
    for k, f in list(globals().items()):
        if k.startswith("test_"):
            f()
            print("ok", k)
