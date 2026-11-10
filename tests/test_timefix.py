"""timefix 시험 — python3 tests/test_timefix.py (실제 2026-11-10 출근길 값 포함)"""
import os
import sys
from datetime import datetime, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server"))
import timefix as F  # noqa: E402

T = lambda h, m, s=0: datetime(2026, 11, 10, h, m, s)  # noqa: E731


def acts(*xs):
    return [{"ts": t, "act": a} for t, a in xs]


def test_depart_blip():
    # 실제: 걷기 07:16:14, 멈춤 07:18:55(3초), 걷기 07:18:58, 차 07:19:38 / 이탈 감지 07:19:33
    a = acts((T(6, 50), "stationary"), (T(7, 16, 14), "walk"), (T(7, 18, 55), "stationary"),
             (T(7, 18, 58), "walk"), (T(7, 19, 38), "car"))
    assert F.move_start(a, T(7, 19, 33)) == T(7, 16, 14)


def test_depart_long_stop_breaks():
    a = acts((T(7, 0), "walk"), (T(7, 5), "stationary"), (T(7, 12), "walk"))
    assert F.move_start(a, T(7, 14)) == T(7, 12)


def test_depart_limit_and_none():
    a = acts((T(6, 0), "walk"))
    assert F.move_start(a, T(7, 14)) is None                      # 10분보다 앞 → 안 당김
    assert F.move_start(acts((T(7, 10), "stationary")), T(7, 14)) is None
    a = acts((T(7, 8), "walk"))
    assert F.move_start(a, T(7, 14), not_before=T(7, 10)) is None  # 진입보다 앞으로는 안 감


def pt(t, lat, lon, spd):
    return {"ts": t, "lat": lat, "lon": lon, "spd": spd}


C = (37.5471484, 126.931715)


def test_arrive_stop():
    # 진입 감지 07:51:02 (달리는 중) → 07:51:39 멈춤
    pts = [pt(T(7, 50, 50), 37.54751, 126.93040, 2.2), pt(T(7, 51, 2), 37.54750, 126.93100, 6.4),
           pt(T(7, 51, 10), 37.54744, 126.93174, 8.4), pt(T(7, 51, 26), 37.54711, 126.93189, 1.6),
           pt(T(7, 51, 39), 37.54708, 126.93178, 0.2), pt(T(7, 52, 7), 37.54713, 126.93179, 0.6)]
    assert F.stop_time(pts, T(7, 51, 2), C, 90) == T(7, 51, 39)


def test_arrive_leaves_again_or_no_stop():
    # 멈췄다가 반경 밖으로 나감 → 그 멈춤은 아님
    pts = [pt(T(7, 51), 37.54708, 126.93178, 0.3), pt(T(7, 52), 37.5500, 126.9400, 9)]
    assert F.stop_time(pts, T(7, 51), C, 90) is None
    # 걸어서 들어와 건물 안으로 (멈춘 점 없음) → None (감지 시각 사용)
    pts = [pt(T(7, 51), 37.54708, 126.93178, 1.4)]
    assert F.stop_time(pts, T(7, 51), C, 90) is None


def test_arrive_late_detection():
    # 진입이 늦게 감지됨 (07:55) — 이미 07:50 에 멈춰 있었음
    pts = [pt(T(7, 49, 50), 37.54720, 126.93178, 5), pt(T(7, 50), 37.54708, 126.93178, 0.1),
           pt(T(7, 53), 37.54709, 126.93177, 0.0)]
    assert F.stop_time(pts, T(7, 55), C, 90) == T(7, 50)


if __name__ == "__main__":
    n = 0
    for k, f in list(globals().items()):
        if k.startswith("test_"):
            f()
            n += 1
    print(f"ok {n}")
