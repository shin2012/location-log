"""리눅스에서 실제 Swift 층 표시 모델을 컴파일하고 실행한다."""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
scratch = Path(os.environ["TMPDIR"]) / "flooruitest"
scratch.mkdir(exist_ok=True)
source = (root / "ios/LocationLog/TimelineModels.swift").read_text()
# 좌표 타입만 대체하고 테스트 대상 모델·문구·아이콘은 그대로 컴파일한다.
source = source.replace("import CoreLocation", "struct CLLocationCoordinate2D { var latitude: Double; var longitude: Double }")
(scratch / "TimelineModels.swift").write_text(source)
swiftc = os.environ.get("SWIFTC", str(Path.home() / ".local/swift/swift-6.0.3-RELEASE-ubuntu22.04-aarch64/usr/bin/swiftc"))
subprocess.run([swiftc, str(scratch / "TimelineModels.swift"), str(root / "tools/flooruitest/main.swift"), "-o", str(scratch / "test")], check=True)
subprocess.run([str(scratch / "test")], check=True)
