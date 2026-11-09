"""자동 체크인 확정 규칙 (DB 없이). 실행: python3 tests/test_autocheckin.py"""
import sys
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
from autocheckin import decide  # noqa: E402

T0 = datetime(2026, 11, 10, 0, 0)


def E(i, kind, m, status="pending"):
    return {"id": i, "kind": kind, "at": T0 + timedelta(minutes=m), "status": status}


def test_enter_confirms_after_3min():
    assert decide([E(1, "enter", 0)], T0 + timedelta(minutes=2)) == {}
    assert decide([E(1, "enter", 0)], T0 + timedelta(minutes=3)) == {1: ("confirmed", None)}


def test_pass_by_ignored():
    r = decide([E(1, "enter", 0), E(2, "exit", 2)], T0 + timedelta(minutes=30))
    assert r == {1: ("ignored", "3분 안에 나감"), 2: ("ignored", "짧은 진입")}


def test_leave_jitter_reenter_ignored():
    """퇴근: 18:00 나감 → 18:05 다시 들어옴 → 18:20 진짜 나감. 체크인 다시 안 생기고 이탈은 마지막 것만."""
    ev = [E(1, "enter", 0, "confirmed"), E(2, "exit", 600), E(3, "enter", 605), E(4, "exit", 620)]
    r = decide(ev, T0 + timedelta(minutes=700))
    assert r == {2: ("ignored", "15분 안에 다시 들어옴"), 3: ("ignored", "재진입"), 4: ("confirmed", None)}


def test_exit_waits_15min():
    ev = [E(1, "enter", 0, "confirmed"), E(2, "exit", 60)]
    assert decide(ev, T0 + timedelta(minutes=70)) == {}
    assert decide(ev, T0 + timedelta(minutes=75)) == {2: ("confirmed", None)}


def test_double_enter_and_exit_ignored():
    ev = [E(1, "enter", 0, "sent"), E(2, "enter", 30)]
    assert decide(ev, T0 + timedelta(minutes=60)) == {2: ("ignored", "이미 안에 있음")}
    ev = [E(1, "exit", 0, "confirmed"), E(2, "exit", 30)]
    assert decide(ev, T0 + timedelta(minutes=60)) == {2: ("ignored", "이미 나감")}


def test_exit_without_known_enter_confirms():
    """앱 설치 때 이미 안에 있어 진입 기록이 없어도 퇴근은 기록."""
    assert decide([E(1, "exit", 0)], T0 + timedelta(minutes=20)) == {1: ("confirmed", None)}


def test_late_batch_waits_for_pair():
    """밀려 있던 진입·이탈이 늦게 따로 도착해도 짝을 보고 판단 (받은 지 2분 기다림)."""
    late = T0 + timedelta(minutes=30)
    ev = [dict(E(1, "enter", 0), recv=late)]
    assert decide(ev, late + timedelta(seconds=10)) == {}
    ev.append(dict(E(2, "exit", 1), recv=late + timedelta(seconds=20)))
    assert decide(ev, late + timedelta(minutes=3)) == {1: ("ignored", "3분 안에 나감"), 2: ("ignored", "짧은 진입")}


def test_new_visit_after_real_exit():
    ev = [E(1, "enter", 0, "sent"), E(2, "exit", 60, "confirmed"), E(3, "enter", 300)]
    assert decide(ev, T0 + timedelta(minutes=310)) == {3: ("confirmed", None)}


if __name__ == "__main__":
    n = 0
    for k, f in list(globals().items()):
        if k.startswith("test_"):
            f(); n += 1
    print(f"ok {n}")
