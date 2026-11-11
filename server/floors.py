"""머문 곳 안 층 이동 (순수 함수, 시각은 UTC naive datetime).

기압(day_baro) → 높이 h. 날씨 탓에 기압은 몇 시간에 수 m 씩 천천히 변함(실측 1.5시간 +4m) →
절대값은 믿지 않고, 짧은 시간(≤4분) 안에 2.5m 넘게 바뀌고 그 뒤 1분 안정된 '계단식 변화'만 층 이동으로 봄.
층 이동끼리의 높이 차만 더해 가므로 느린 변화는 쌓이지 않음.

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
STABLE_S = 60         # 이동 뒤 이만큼 ±0.8m 안이면 도착
STABLE_M = 0.8
START_M = 0.6         # 출발 시각 = 기준 높이에서 이만큼 벗어나기 직전
DRIFT_FOLLOW = 0.1    # 머무는 동안 기준 높이가 천천히 따라감
ELEV_MPS = 0.8
STEP_RISE = 0.17      # 계단 한 걸음 높이 m
DEF_A = 3.5           # 건물 층 높이 처음값 (아파트 2.8~3, 사무실 3.5~4, 상가 1층은 4.5~5)
BEFORE = timedelta(minutes=3)   # 머문 곳 시작 조금 전 층 이동도 (도착 감지가 늦음)


def heights(baro: list[dict]) -> list[tuple[datetime, float]]:
    if not baro:
        return []
    p0 = baro[0]["kpa"]
    return [(b["ts"], H_SCALE * math.log(p0 / b["kpa"])) for b in baro]


def detect(hs: list[tuple[datetime, float]]) -> list[dict]:
    """[(ts, h)] 시간순 → [{start, end, dh}]"""
    out = []
    n = len(hs)
    if n < 2:
        return out
    ah = hs[0][1]
    j = 1
    while j < n:
        t, h = hs[j]
        if abs(h - ah) < JUMP_M:
            if abs(h - ah) < 1.0:
                ah += (h - ah) * DRIFT_FOLLOW
            j += 1
            continue
        k = j - 1
        while k > 0 and abs(hs[k][1] - ah) > START_M:
            k -= 1
        start = hs[k][0]
        e, win = j, None
        while e < n and (hs[e][0] - start).total_seconds() <= MAX_DUR:
            w = [x[1] for x in hs[e:] if (x[0] - hs[e][0]).total_seconds() <= STABLE_S]
            if max(w) - min(w) <= STABLE_M:
                win = w
                break
            e += 1
        if win is None:             # 천천히 바뀜 → 날씨
            ah = h
            j += 1
            continue
        plat = sorted(win)[len(win) // 2]
        dh = plat - ah
        if abs(dh) >= JUMP_M:
            out.append({"start": start, "end": hs[e][0], "dh": dh})
        ah = plat
        j = e + 1
    return out


def classify(ev: dict, steps: list[dict]) -> str:
    """elevator | stairs | escalator"""
    s0 = ev["start"].replace(second=0, microsecond=0)
    mins = [s for s in steps if s0 <= s["ts"] <= ev["end"]]
    if any((s.get("floors_up") or 0) + (s.get("floors_down") or 0) > 0 for s in mins):
        return "stairs"
    dur = max(1.0, (ev["end"] - ev["start"]).total_seconds())
    if abs(ev["dh"]) / dur >= ELEV_MPS:
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
                a, b = parking.model(v["lat"], v["lon"], near, def_a=DEF_A)
                seg["level"] = max(parking.LEVEL_MIN, min(parking.LEVEL_MAX, math.floor((dh - b) / a + 0.5)))
                seg["est"] = True
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
