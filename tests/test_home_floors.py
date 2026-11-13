"""장소별 층 보정: 실제 계산 경로 회귀 시험 (개인 위치·원본 없음)."""
import copy
import json
import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from calc_golden import run


def fixture():
    t0 = 1794500000000
    points, sec, height = [], 0, -30.0
    for dur, target in [(60, -30), (40, 0), (200, 0), (40, 3), (40, 3),
                        (40, 6), (40, 6), (16, 22), (180, 22)]:
        for n in range(dur):
            h = height + (target - height) * n / dur
            points.append({"ts": t0 + (sec + n) * 1000, "kpa": 100 * math.exp(-h / 8434)})
        sec += dur
        height = target
    return {"day0": t0 - 60000, "day1": t0 + 3600000, "now": t0 + 3600000,
            "visits": [{"arrive": t0 + 90000, "depart": t0 + sec * 1000, "lat": 37.5, "lon": 127.0}],
            "parks": [{"ts": t0 + 200000, "lat": 37.5, "lon": 127.0, "dh": 3.4,
                       "level_est": -2, "level_user": None}],
            "steps": [{"ts": (t0 + 480000) // 60000 * 60000, "steps": 2, "up": 1, "down": 0}],
            "baro": points,
            "floor_profiles": [{"lat": 37.5, "lon": 127.0, "radius": 150,
                                "anchors": [{"dh": 0, "level": -2}, {"dh": 3, "level": 0},
                                            {"dh": 6, "level": 0}, {"dh": 22, "level": 6}]}]}


def floors(inp):
    return next(i for i in run(inp, "2026-11-13")["items"] if i["kind"] == "visit").get("floors", [])


class HomeFloors(unittest.TestCase):
    def test_hill_is_not_a_floor_and_two_landings_are_both_first_floor(self):
        inp = fixture()
        fs = floors(inp)
        self.assertEqual([x["level"] for x in fs], [-2, 0, 6])
        self.assertEqual(fs[-1]["via"], "elevator")
        self.assertTrue(all(x["end"] > x["start"] >= inp["parks"][0]["ts"] for x in fs))
    def test_return_from_home_goes_to_first_floor_not_parking(self):
        inp = fixture()
        last = inp["baro"][-1]["ts"]
        sec, height = 1, 22.0
        for dur, target in [(20, 0.8), (60, 0.8), (30, 6), (60, 6), (16, 22), (90, 22)]:
            for n in range(dur):
                h = height + (target - height) * n / dur
                inp["baro"].append({"ts": last + (sec + n) * 1000, "kpa": 100 * math.exp(-h / 8434)})
            sec += dur
            height = target
        inp["visits"][0]["depart"] = last + sec * 1000
        self.assertEqual([x["level"] for x in floors(inp)], [-2, 0, 6, 0, 6])

    def test_outside_profile_is_identical_to_no_profile(self):
        inp = fixture()
        inp["floor_profiles"][0]["lat"] += 1
        baseline = copy.deepcopy(inp)
        baseline.pop("floor_profiles")
        self.assertEqual(run(inp, "x"), run(baseline, "x"))

    def test_missing_or_remote_parking_does_not_invent_floors(self):
        for key in ["baro", "parks"]:
            inp = fixture()
            inp[key] = []
            self.assertEqual(floors(inp), [])
        inp = fixture()
        inp["parks"][0]["lat"] += 1
        self.assertEqual(floors(inp), [])

    def test_old_floor_corrections_and_wifi_do_not_pollute_local_height(self):
        inp = fixture()
        baseline = floors(inp)
        inp["floor_cal"] = [{"ts": inp["visits"][0]["arrive"], "lat": 37.5, "lon": 127.0,
                             "dh": 35, "level": -4, "ap": None}]
        self.assertEqual(floors(inp), baseline)

    def test_invalid_profile_configuration_is_ignored(self):
        import floors as f
        for text in ["{", "null", "{}", '[{"lat":"bad"}]', '[{"lat":0,"lon":0,"radius":1,"anchors":[]}]']:
            self.assertEqual(f.profile_config(text), [])
        self.assertEqual(f.profile_config(json.dumps(fixture()["floor_profiles"])), fixture()["floor_profiles"])

    def test_sensor_gap_does_not_create_a_transition(self):
        inp = fixture()
        a = inp["parks"][0]["ts"]
        inp["baro"] = [p for p in inp["baro"] if p["ts"] < a + 60000 or p["ts"] > a + 300000]
        self.assertEqual(floors(inp), [])


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--fixtures":
        good = fixture()
        cases = [{"name": "hill-stairs-elevator", "input": good,
                  "expected": {"levels": [-2, 0, 6], "elevator": True}}]
        for key in ["baro", "parks"]:
            inp = fixture(); inp[key] = []
            cases.append({"name": "missing-" + key, "input": inp, "expected": {"levels": [], "elevator": False}})
        Path(sys.argv[2]).write_text(json.dumps(cases))
    else:
        unittest.main()
