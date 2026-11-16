"""개인 기록 없이 실제 앱의 FloorRow를 iPhone/iPad에서 캡처하고 행 높이를 검사한다."""
import json
import os
from pathlib import Path
import subprocess
import time


def run(*args):
    return subprocess.check_output(args, text=True, timeout=180).strip()


out = Path("floor-shots")
out.mkdir(exist_ok=True)
app = next((Path(os.environ["RUNNER_TEMP"]) / "dd/Build/Products/Debug-iphonesimulator").glob("*.app"))
bundle = "kr.b-612.sillage"
devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
flat = [d for group in devices.values() for d in group]
report = []
for name in ["iPhone 17 Pro", "iPad Pro 13-inch (M5)"]:
    device = next(d for d in flat if d["name"] == name)
    udid = device["udid"]
    run("xcrun", "simctl", "boot", udid)
    run("xcrun", "simctl", "bootstatus", udid, "-b")
    run("xcrun", "simctl", "install", udid, str(app))
    run("xcrun", "simctl", "status_bar", udid, "override", "--time", "2026-11-16T12:00:00+09:00", "--batteryState", "charged", "--batteryLevel", "100")
    container = Path(run("xcrun", "simctl", "get_app_container", udid, bundle, "data"))
    metric = container / "Documents/floor-layout.json"
    for mode in ["light", "dark"]:
        run("xcrun", "simctl", "ui", udid, "appearance", mode)
        for large in [False, True]:
            subprocess.run(["xcrun", "simctl", "terminate", udid, bundle], capture_output=True)
            metric.unlink(missing_ok=True)
            run("xcrun", "simctl", "launch", udid, bundle, "-floorLayoutShot", "YES", "-floorShotLarge", "YES" if large else "NO", "-AppleLanguages", "(ko)")
            for attempt in range(30):
                if metric.exists():
                    break
                time.sleep(1)
            time.sleep(2)
            label = f'{name.replace(" ", "_")}-{mode}-{"large" if large else "normal"}'
            run("xcrun", "simctl", "io", udid, "screenshot", str(out / f"{label}.png"))
            heights = json.loads(metric.read_text())
            (out / f"{label}.json").write_text(json.dumps(heights, indent=2))
            assert len(heights) == 4, (label, heights)
            limit = 200 if large else 90
            assert all(0 < value <= limit for value in heights.values()), (label, heights, limit)
            report.append({"capture": label, "heights": heights, "limit": limit})
            print(label, heights, flush=True)
    run("xcrun", "simctl", "shutdown", udid)
(out / "report.json").write_text(json.dumps(report, indent=2))
print("iPhone/iPad · 라이트/다크 · 기본/큰 글씨: 행 높이 검사 통과")
