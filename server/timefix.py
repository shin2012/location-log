"""감지 시각 → 실제 시각 보정 (순수 함수, 시각은 모두 UTC naive datetime).

- 떠남: 반경 이탈은 실제로 나선 뒤 몇 분 늦게 감지됨 → 그 직전 '멈춤 → 움직임'이 시작된 시각
  (기기 동작 기록 day_act). 엘리베이터 앞에서 잠깐 선 것처럼 짧은 멈춤(2분 미만)은 이어진 움직임으로 봄.
- 도착: 반경 진입은 차가 아직 달리는 중에 감지됨 → 진입 뒤 처음 멈춘 시각 (위치 점 속도 < 1m/s, 그 뒤로 반경 안).
- 자동 운전 기록 끝: 기록은 CarPlay 해제·차량 동작이 끝나고도 1~3분 더 돎 → 차가 멈춘 시각에서 자름.
"""
import math
from datetime import datetime, timedelta

MOVING = ("walk", "run", "bike", "car")
BLIP = timedelta(minutes=2)          # 이보다 짧은 멈춤은 무시
DEPART_BACK = timedelta(minutes=10)  # 떠난 시각은 감지 시각에서 이만큼까지만 당김
ARRIVE_BACK = timedelta(minutes=10)  # 진입이 늦게 감지됐을 수 있음 → 이만큼 앞까지 멈춘 점 찾음
ARRIVE_FWD = timedelta(minutes=5)    # 진입 뒤 이만큼 안에 멈춘 점
STOP_MPS = 1.0
DRIVE_MPS = 2.0


def hav_m(a, b) -> float:
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371008.8 * math.asin(math.sqrt(h))


def move_start(acts: list[dict], at: datetime, not_before: datetime | None = None) -> datetime | None:
    """acts: [{ts, act}] 바뀐 시각 (시간순). at 에 이어지고 있던 움직임이 시작된 시각, 없으면 None."""
    lo = at - DEPART_BACK
    if not_before and not_before > lo:
        lo = not_before
    before = [a for a in acts if a["ts"] <= at]
    if not before:
        return None
    start = None
    for i in range(len(before) - 1, -1, -1):
        a = before[i]
        if a["ts"] < lo:
            break
        if a["act"] in MOVING:
            start = a["ts"]
            continue
        # 멈춤(또는 모름): 짧으면 건너뜀, 길면 여기서 끝
        end = before[i + 1]["ts"] if i + 1 < len(before) else at
        if end - a["ts"] >= BLIP:
            break
    return start


def stop_time(pts: list[dict], at: datetime, center: tuple[float, float], radius: float) -> datetime | None:
    """pts: [{ts, lat, lon, spd}] 시간순. 진입 감지(at) 앞뒤에서 반경 안에 멈춘 첫 시각 (그 뒤 반경을 안 벗어남)."""
    win = [p for p in pts if at - ARRIVE_BACK <= p["ts"] <= at + ARRIVE_FWD]
    inside = [hav_m(center, (p["lat"], p["lon"])) <= radius for p in win]
    for i, p in enumerate(win):
        if not inside[i] or p.get("spd") is None or p["spd"] >= STOP_MPS:
            continue
        if all(inside[i:]):
            return p["ts"]
    return None


def drive_cut(pts: list[dict], anchor: datetime) -> datetime | None:
    """자동 운전 기록 점 [{ts, spd}] (시간순) 과 운전이 끝난 신호 시각(anchor: CarPlay 해제·차량 동작 끝)
    → 차가 멈춘 시각 (이 뒤 점은 버림). anchor 뒤에 점이 없으면 None."""
    if not pts or pts[-1]["ts"] <= anchor:
        return None
    last_drive = None
    for i, p in enumerate(pts):
        if p["ts"] > anchor:
            break
        if (p.get("spd") or 0) >= DRIVE_MPS:
            last_drive = i
    if last_drive is None:
        return anchor
    for p in pts[last_drive + 1:]:
        if p.get("spd") is not None and p["spd"] < STOP_MPS:
            return p["ts"]
    return anchor


def drive_anchor(carplay_end: datetime | None, acts: list[dict], t0: datetime, t1: datetime) -> datetime | None:
    """운전 끝 신호: 기록 구간 [t0,t1] 안 마지막 CarPlay 해제 → 없으면 '차' → 다른 동작으로 바뀐 마지막 시각."""
    if carplay_end and t0 <= carplay_end <= t1:
        return carplay_end
    last = None
    for a, b in zip(acts, acts[1:]):
        if a["act"] == "car" and b["act"] != "car" and t0 <= b["ts"] <= t1:
            last = b["ts"]
    return last
