"""앱 TimelineCalc(Swift) ↔ 서버 timeline.py 대조용.

inputs JSON(= GET /api/day/{date}/inputs, 앱 CalcInput 과 같은 모양) → timeline.build_items → /timeline 과 같은 JSON.
python3 tests/calc_golden.py <inputs.json>  → 표준 출력에 결과 JSON
"""
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "server"))
import parking as PK  # noqa: E402
import timeline as TL  # noqa: E402

PATH_SRC = ("gps", "fill", "trk", "imu")


def dt(ms):
    return None if ms is None else datetime.fromtimestamp(ms / 1000, tz=timezone.utc).replace(tzinfo=None)


def ms(d):
    return None if d is None else int(round(d.replace(tzinfo=timezone.utc).timestamp() * 1000))


def run(inp: dict, date: str) -> dict:
    a, b, now = dt(inp["day0"]), dt(inp["day1"]), dt(inp["now"])
    from datetime import timedelta as td
    vs = [{"start": dt(v["arrive"]), "end": dt(v["depart"]) or now, "lat": v["lat"], "lon": v["lon"], "open": v["depart"] is None}
          for v in sorted(inp.get("visits", []), key=lambda v: v["arrive"])
          if dt(v["arrive"]) < b and (v["depart"] is None or dt(v["depart"]) > a - td(hours=12))]
    pts = [{**p, "ts": dt(p["ts"])} for p in sorted(inp.get("points", []), key=lambda p: p["ts"])
           if a <= dt(p["ts"]) < b and p["src"] in PATH_SRC]
    acts_all = sorted(({**x, "ts": dt(x["ts"])} for x in inp.get("acts", [])), key=lambda x: x["ts"])
    acts = [x for x in acts_all if a <= x["ts"] < b]
    prev = [x for x in acts_all if x["ts"] < a]
    if prev:
        acts.insert(0, prev[-1])
    steps = [{"ts": dt(s["ts"]), "steps": s["steps"], "floors_up": s.get("up"), "floors_down": s.get("down")}
             for s in sorted(inp.get("steps", []), key=lambda s: s["ts"]) if a <= dt(s["ts"]) < b]
    car = [{"event": c["event"], "at": dt(c["ts"])} for c in sorted(inp.get("car", []), key=lambda c: c["ts"])
           if a - td(hours=6) <= dt(c["ts"]) < b]
    cks = [{**c, "ts": dt(c["ts"])} for c in sorted(inp.get("checkins", []), key=lambda c: c["ts"])
           if a - td(hours=12) <= dt(c["ts"]) < b]
    cal = inp.get("park_cal", [])
    parks = []
    for r in sorted(inp.get("parks", []), key=lambda r: r["ts"]):
        t = dt(r["ts"])
        if not (a - td(hours=1) <= t < b + td(hours=1)):
            continue
        if r.get("level_user") is not None:
            lv, est = r["level_user"], False
        elif r.get("lat") is not None:
            lv, est = PK.estimate(r["dh"], r["lat"], r["lon"], cal), True
        else:
            lv, est = r["level_est"], True
        parks.append({"ts": t, "level": lv, "est": est, "dh": r["dh"]})
    baro = [{"ts": dt(x["ts"]), "kpa": x["kpa"]} for x in sorted(inp.get("baro", []), key=lambda x: x["ts"])
            if a - td(hours=1) <= dt(x["ts"]) < b]
    wifi_all = sorted(({"ts": dt(w["ts"]), "bssid": w.get("bssid")} for w in inp.get("wifi", [])), key=lambda w: w["ts"])
    wifi = [w for w in wifi_all if a <= w["ts"] < b]
    wp = [w for w in wifi_all if w["ts"] < a]
    if wp:
        wifi.insert(0, wp[-1])
    hk = [{**x, "start": dt(x["start"]), "end": dt(x["end"])} for x in sorted(inp.get("hk", []), key=lambda x: x["start"])
          if dt(x["end"]) >= a and dt(x["start"]) < b]
    fcal = [{**c, "ts": dt(c["ts"])} for c in inp.get("floor_cal", [])]
    out = TL.build_items(a, b, vs, pts, acts, steps, car, inp.get("places", []), cks, parks, baro, fcal, wifi, hk)
    for it in out["items"]:
        it["start"], it["end"] = ms(it["start"]), ms(it["end"])
        if "park" in it:
            it["park"]["ts"] = ms(it["park"]["ts"])
        for f in it.get("floors", []) + it.get("subs", []) + [x for f in it.get("floors", []) for x in f.get("subs", [])]:
            f["start"], f["end"] = ms(f["start"]), ms(f["end"])
    return {"date": date, **out}


if __name__ == "__main__":
    d = json.loads(Path(sys.argv[1]).read_text())
    print(json.dumps(run(d["inputs"] if "inputs" in d else d, d.get("date", "")), ensure_ascii=False))
