"""자동 체크인 — 시야쥬 앱이 보낸 장소 반경 진입·이탈을 확정하고 swarm(fsq_map)에 체크인으로 넘김.

앱은 감지한 그대로(진입/이탈 + 시각)만 보내고, 걸러내기는 여기서 한다 (앱이 백그라운드에서 몇 분씩 기다릴 수 없음).
- 진입 후 3분 안에 나가면 진입·이탈 둘 다 무시 (지나가기만 함)
- 나간 뒤 15분 안에 다시 들어오면 이탈·재진입 둘 다 무시 (퇴근할 때 반경 경계를 오가는 경우)
- 이미 안에 있는데 또 들어옴 / 이미 나갔는데 또 나감 → 무시
- 진입은 3분, 이탈은 15분이 지나야 확정 (그 사이 반대 이벤트가 오면 위 규칙)
시각은 모두 UTC naive datetime.
"""
from datetime import datetime, timedelta

ENTER_CONFIRM = timedelta(minutes=3)
EXIT_CONFIRM = timedelta(minutes=15)
DONE = ("confirmed", "sent", "failed")
RECV_GRACE = timedelta(minutes=2)      # 받은 지 2분은 기다림 — 밀려 있던 이벤트가 한꺼번에 올 때 짝(이탈·재진입)이 뒤따라 옴   # 확정된 것 (failed = 확정됐으나 전달 실패)


def decide(events: list[dict], now: datetime) -> dict:
    """한 장소의 이벤트(시각순, 이미 처리된 것 포함) → {id: (status, note)} (pending 인 것만 결정).
    events: {id, kind, at, status, recv(받은 시각, 없으면 at)}"""
    ev = sorted(events, key=lambda e: (e["at"], e["id"]))
    out: dict = {}
    last = None      # 마지막으로 확정된 kind ('enter'|'exit'|None=모름)
    skip = set()
    for i, e in enumerate(ev):
        if e["status"] != "pending":
            if e["status"] in DONE:
                last = e["kind"]
            continue
        if e["id"] in skip:
            continue
        nxt = ev[i + 1] if i + 1 < len(ev) else None
        if e["kind"] == "enter":
            if nxt and nxt["kind"] == "exit" and nxt["at"] - e["at"] < ENTER_CONFIRM:
                out[e["id"]] = ("ignored", "3분 안에 나감")
                if nxt["status"] == "pending":
                    out[nxt["id"]] = ("ignored", "짧은 진입")
                    skip.add(nxt["id"])
                continue
            if last == "enter":
                out[e["id"]] = ("ignored", "이미 안에 있음")
                continue
            if now - e["at"] < ENTER_CONFIRM or now - e.get("recv", e["at"]) < RECV_GRACE:
                break            # 아직 모름 — 뒤 이벤트도 이걸 알아야 판단 가능
            out[e["id"]] = ("confirmed", None)
            last = "enter"
        else:
            if nxt and nxt["kind"] == "enter" and nxt["at"] - e["at"] < EXIT_CONFIRM:
                out[e["id"]] = ("ignored", "15분 안에 다시 들어옴")
                if nxt["status"] == "pending":
                    out[nxt["id"]] = ("ignored", "재진입")
                    skip.add(nxt["id"])
                continue
            if last == "exit":
                out[e["id"]] = ("ignored", "이미 나감")
                continue
            if now - e["at"] < EXIT_CONFIRM or now - e.get("recv", e["at"]) < RECV_GRACE:
                break
            out[e["id"]] = ("confirmed", None)
            last = "exit"
    return out
