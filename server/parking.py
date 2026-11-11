"""주차 층 추정 (순수 함수). 앱 ios/LocationLog/Parking.swift 의 ParkModel 과 같은 규칙.

- 높이 차(dh, m) = 주차 직전 마지막으로 빠르게 달린 곳(지상 도로) 기압 대비 주차한 곳 기압 → 아래로 내려가면 음수.
- 층 번호(level): 지상 1층 = 0, 2층 = 1 …, 지하 1층 = -1, 지하 2층 = -2 … (0층이 없는 실제 층 이름과 1:1)
- 모델: dh ≈ a·level + b. a = 층 높이, b = 입구가 지면과 다른 만큼.
  · 사용자가 고친 주차 중 150m 안 것만 그 장소 보정에 씀 (장소 = 주차 위치 근처, 따로 등록 안 함)
  · 그 장소에서 서로 다른 층 2개 이상 → 최소제곱으로 a, b
  · 한 층만 → 그 층이 지상 1층이 아니면 a = 평균 dh / level (b = 0), 아니면 b 만
  · 장소 기록 없음 → a = 전체 고친 기록의 층 높이 중앙값 (없으면 3.2m), b = 0
"""
import math

H_SCALE = 8434.0      # m — 기압 높이 척도 (15°C). 1 hPa ≈ 8.3 m
DEF_A = 3.2           # 처음 층 높이
A_MIN, A_MAX = 2.0, 6.0
NEAR_M = 150
LEVEL_MIN, LEVEL_MAX = -9, 30


def hav_m(a, b) -> float:
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371008.8 * math.asin(math.sqrt(h))


def dh_from_kpa(ref_kpa: float, now_kpa: float) -> float:
    """기압(kPa) 두 개 → 높이 차 m (now 가 ref 보다 높으면 양수)"""
    return H_SCALE * math.log(ref_kpa / now_kpa)


def label(level: int) -> str:
    return f"B{-level}" if level < 0 else f"{level + 1}F"


def global_a(cal: list[dict], def_a: float = DEF_A) -> float:
    r = sorted(c["dh"] / c["level"] for c in cal if c["level"] != 0 and A_MIN <= c["dh"] / c["level"] <= A_MAX)
    if not r:
        return def_a
    n = len(r)
    return r[n // 2] if n % 2 else (r[n // 2 - 1] + r[n // 2]) / 2


def model(lat: float, lon: float, cal: list[dict], def_a: float = DEF_A) -> tuple[float, float]:
    """cal: 사용자가 고친(확정한) 주차 [{lat, lon, dh, level}] → (a, b)"""
    g = global_a(cal, def_a)
    near = [c for c in cal if hav_m((lat, lon), (c["lat"], c["lon"])) <= NEAR_M]
    if not near:
        return g, 0.0
    if len({c["level"] for c in near}) >= 2:
        n = len(near)
        mx = sum(c["level"] for c in near) / n
        my = sum(c["dh"] for c in near) / n
        sxx = sum((c["level"] - mx) ** 2 for c in near)
        sxy = sum((c["level"] - mx) * (c["dh"] - my) for c in near)
        a = sxy / sxx
        if A_MIN <= a <= A_MAX:
            return a, my - a * mx
    # 한 층만 (또는 맞춤이 엉뚱함) → 가장 많이 고친 층 기준
    cnt: dict[int, int] = {}
    for c in near:
        cnt[c["level"]] = cnt.get(c["level"], 0) + 1
    lv = max(cnt, key=lambda k: (cnt[k], -abs(k)))
    m = sum(c["dh"] for c in near if c["level"] == lv) / cnt[lv]
    if lv != 0 and A_MIN <= m / lv <= A_MAX:
        return m / lv, 0.0
    return g, m - g * lv


def estimate(dh: float, lat: float, lon: float, cal: list[dict]) -> int:
    a, b = model(lat, lon, cal)
    x = (dh - b) / a
    return max(LEVEL_MIN, min(LEVEL_MAX, math.floor(x + 0.5)))
