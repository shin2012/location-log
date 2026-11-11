"""머문 곳 안 층 이동 (순수 함수, 시각은 UTC naive datetime).

기압(day_baro) → 높이 h. 날씨 탓에 기압은 몇 시간에 수 m 씩 천천히 변함(실측 2시간 +3.7m) →
절대값은 믿지 않고, 20초 넘게 ±0.3m 로 머문 높이(plateau)끼리 비교해 4분 안에 2.5m 넘게 달라진 것만 층 이동.
층 이동끼리의 높이 차만 더해 가므로 느린 변화는 쌓이지 않음. 2.5m 안 되는 단차(실측: 시동 끌 때 +1.9m)는 무시.

- 방식: 만보계 계단 층수 있음 → 계단, 수직 속도 ≥0.8m/s → 엘리베이터, 걸음 많음 → 계단, 그 밖 → 에스컬레이터
- 층 번호: 머문 곳에 들어온 순간 = 지상 1층(0) 기준(차로 와서 주차했으면 주차한 높이) + 층 이동 합 → parking 모델(장소 150m 별 층 높이·입구 높이)
- 공유기(BSSID)는 보조: 사용자가 같은 공유기에서 같은 층으로 2번 이상 확정했으면 그 층
"""
import math
from datetime import datetime, timedelta

import parking

H_SCALE = parking.H_SCALE
JUMP_M = 2.5          # 이만큼 넘게 바뀌어야 층 이동
MAX_DUR = 240         # 초 — 이보다 오래 걸린 변화는 날씨로 봄
PLAT_RANGE = 0.6      # 머문 높이: 이 폭 안에서
PLAT_MIN_S = 20       # 이만큼 넘게 이어짐
ELEV_MPS = 0.5       # 변화 가운데(20→80%) 속도. 실측 엘리베이터 한 층 ≈ 0.9m/s
STEP_RISE = 0.17      # 계단 한 걸음 높이 m
DEF_A = 3.5           # 건물 층 높이 처음값 (아파트 2.8~3, 사무실 3.5~4)
DEF_G1 = 4.5          # 1층 → 2층 처음값: 상가·사무실 1층은 층고가 높음 (실측 2026-11-11 1층→2층 5.6m)
BEFORE = timedelta(minutes=3)   # 머문 곳 시작 조금 전 층 이동도 (도착 감지가 늦음)


def heights(baro: list[dict]) -> list[tuple[datetime, float]]:
    if not baro:
        return []
    p0 = baro[0]["kpa"]
    return [(b["ts"], H_SCALE * math.log(p0 / b["kpa"])) for b in baro]


def plateaus(hs: list[tuple[datetime, float]]) -> list[dict]:
    """머문 높이: PLAT_RANGE 안에서 PLAT_MIN_S 넘게 이어진 구간 [{start, end, first, last}] (값은 앞뒤 3개 중앙값)"""
    out, i, n = [], 0, len(hs)
    while i < n:
        lo = hi = hs[i][1]
        j = i
        while j + 1 < n:
            v = hs[j + 1][1]
            if max(hi, v) - min(lo, v) > PLAT_RANGE:
                break
            lo, hi = min(lo, v), max(hi, v)
            j += 1
        if (hs[j][0] - hs[i][0]).total_seconds() >= PLAT_MIN_S:
            vals = [x[1] for x in hs[i:j + 1]]
            out.append({"start": hs[i][0], "end": hs[j][0],
                        "first": sorted(vals[:3])[len(vals[:3]) // 2], "last": sorted(vals[-3:])[len(vals[-3:]) // 2]})
            i = j + 1
        else:
            i += 1
    return out


def detect(hs: list[tuple[datetime, float]]) -> list[dict]:
    """[(ts, h)] 시간순 → 층 이동 [{start, end, dh}].
    이웃한 머문 높이끼리 MAX_DUR 안에 JUMP_M 넘게 다르면 층 이동. 작은 단차(차 문·경사로)와 날씨 변화는 무시."""
    ps = plateaus(hs)
    out = []
    for a, b in zip(ps, ps[1:]):
        dh = b["first"] - a["last"]
        if abs(dh) >= JUMP_M and (b["start"] - a["end"]).total_seconds() <= MAX_DUR:
            out.append({"start": a["end"], "end": b["start"], "dh": dh, "mps": _mid_speed(hs, a, b, dh)})
    return out


def _mid_speed(hs, a, b, dh) -> float:
    """변화의 20%→80% 를 지난 시간으로 잰 수직 속도 (앞뒤에 서성인 시간 빼고)"""
    seg = [x for x in hs if a["end"] <= x[0] <= b["start"]]
    lo, hi = a["last"] + dh * 0.2, a["last"] + dh * 0.8
    sign = 1 if dh > 0 else -1
    t20 = next((x[0] for x in seg if (x[1] - lo) * sign >= 0), None)
    t80 = next((x[0] for x in seg if (x[1] - hi) * sign >= 0), None)
    if t20 is None or t80 is None:
        return abs(dh) / max(1.0, (b["start"] - a["end"]).total_seconds())
    return abs(dh) * 0.6 / max(1.0, (t80 - t20).total_seconds())


def classify(ev: dict, steps: list[dict]) -> str:
    """elevator | stairs | escalator"""
    s0 = ev["start"].replace(second=0, microsecond=0)
    mins = [s for s in steps if s0 <= s["ts"] <= ev["end"]]
    if any((s.get("floors_up") or 0) + (s.get("floors_down") or 0) > 0 for s in mins):
        return "stairs"
    v = ev.get("mps") or abs(ev["dh"]) / max(1.0, (ev["end"] - ev["start"]).total_seconds())
    if v >= ELEV_MPS:   # 계단·에스컬레이터 수직 속도는 0.2~0.3m/s
        return "elevator"
    st = sum(s["steps"] for s in mins)
    if st >= abs(ev["dh"]) / STEP_RISE * 0.6:
        return "stairs"
    return "escalator"


def ap(bssid: str | None) -> str | None:
    """같은 공유기의 2.4/5GHz·여러 이름은 끝 바이트만 다른 경우가 많음 → 앞 5바이트로 묶음"""
    if not bssid:
        return None
    p = [x.zfill(2) for x in bssid.lower().split(":")]
    return ":".join(p[:5]) if len(p) == 6 else bssid.lower()


def wifi_at(wifi: list[dict], a: datetime, b: datetime) -> str | None:
    """[a, b] 동안 가장 오래 연결된 공유기 (wifi: 바뀐 시각 [{ts, bssid}] 시간순, a 이전 하나 포함 가능)"""
    dur: dict[str, float] = {}
    for i, w in enumerate(wifi):
        s = max(w["ts"], a)
        e = min(wifi[i + 1]["ts"] if i + 1 < len(wifi) else b, b)
        k = ap(w.get("bssid"))
        if k and e > s:
            dur[k] = dur.get(k, 0) + (e - s).total_seconds()
    return max(dur, key=lambda k: dur[k]) if dur else None


def default_level(dh: float) -> int:
    """보정 기록이 없는 곳: 1층 높이 DEF_G1, 그 위·지하는 DEF_A 씩 — 가장 가까운 층"""
    if dh >= DEF_G1:
        n = 1 + math.floor((dh - DEF_G1) / DEF_A + 0.5)
    elif dh >= 0:
        n = 1 if dh >= DEF_G1 / 2 else 0
    else:
        n = math.floor(dh / DEF_A + 0.5)
    return max(parking.LEVEL_MIN, min(parking.LEVEL_MAX, n))


def level_of(dh: float, lat: float, lon: float, near: list[dict]) -> int:
    if not near:
        return default_level(dh)
    a, b = parking.model(lat, lon, near, def_a=DEF_A)
    return max(parking.LEVEL_MIN, min(parking.LEVEL_MAX, math.floor((dh - b) / a + 0.5)))


def segments(v: dict, hs: list[tuple[datetime, float]], steps: list[dict], cal: list[dict],
             wifi: list[dict] | None = None, base_dh: float = 0.0) -> list[dict]:
    """머문 곳 v {start, end, lat, lon} 의 층 구간. 층 이동이 없으면 [].
    cal: 사용자가 확정한 층 [{ts, lat, lon, dh, level, ap}]"""
    win = [x for x in hs if v["start"] - BEFORE - timedelta(minutes=2) <= x[0] <= v["end"]]
    evs = [e for e in detect(win) if e["start"] >= v["start"] - BEFORE]
    if not evs:
        return []
    near = [c for c in cal if parking.hav_m((v["lat"], v["lon"]), (c["lat"], c["lon"])) <= parking.NEAR_M]
    by_ts = {c["ts"]: c for c in near}
    ap_lv: dict[str, list[int]] = {}
    for c in near:
        if c.get("ap"):
            ap_lv.setdefault(c["ap"], []).append(c["level"])
    out = []
    t, dh, via = v["start"], base_dh, None
    for e in evs + [None]:
        end = e["start"] if e else v["end"]
        if end > t or not out:
            seg = {"start": t, "end": max(end, t), "dh": round(dh, 2), "via": via}
            hit = next((c for k, c in by_ts.items() if abs((k - t).total_seconds()) < 1), None)
            w = wifi_at(wifi or [], t, max(end, t)) if wifi else None
            seg["ap"] = w
            if hit:
                seg["level"], seg["est"] = hit["level"], False
            elif w and len(ap_lv.get(w, [])) >= 2 and len(set(ap_lv[w])) == 1:
                seg["level"], seg["est"] = ap_lv[w][0], True
            else:
                seg["level"], seg["est"] = level_of(dh, v["lat"], v["lon"], near), True
            seg["label"] = parking.label(seg["level"])
            out.append(seg)
        if e:
            dh += e["dh"]
            t = e["end"]
            via = classify(e, steps)
    # 같은 층이 이어지면 합침 (작은 흔들림 두 번이 서로 상쇄된 경우 등)
    merged = []
    for s in out:
        if merged and merged[-1]["level"] == s["level"]:
            merged[-1]["end"] = s["end"]
            continue
        merged.append(s)
    return merged if len(merged) > 1 else []
