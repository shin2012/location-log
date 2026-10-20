"""이동 중 기록 화면 시연 영상: python tools/record_demo.py <map|log> <출력.mp4>

브라우저 안에서 가짜 GPS(속도·방향 포함, 1초 간격)와 자이로·가속도 이벤트(60Hz)를 실제 도로 경로를 따라
72km/h로 흘려보냄. 5~11초는 터널(GPS 없음) → 8초쯤부터 센서 추정(주황 점선), 11초에 GPS 복귀하며 보정.
시연이 끝나면 만든 기록은 서버에서 지움.
"""
import json, subprocess, sys, time, urllib.request
from pathlib import Path
from playwright.sync_api import sync_playwright

MODE, OUT = sys.argv[1], sys.argv[2]
URL = "https://location.b-612.kr/"
FFMPEG = "/home/yoseop/.hermes/tools/ffmpeg-9.0.1-linux-arm64/bin/ffmpeg"
TMP = Path("/home/yoseop/.hermes/cache/scratch/demo_vid"); TMP.mkdir(parents=True, exist_ok=True)

# 실제 도로 경로 (데일리요섭 10/16 출근길 계산 경로)
d = json.load(urllib.request.urlopen("http://172.22.0.1:8912/api/day/2026-10-16", timeout=120))
route = next(s for s in d["map"]["segs"] if s["a"].startswith("홍은") and "조폐" in s["b"])["path"]

FAKE_GPS = """(() => {
  const subs = new Map(); let id = 0;
  const geo = { watchPosition(ok) { const i = ++id; subs.set(i, ok); if (window.__lastPos) setTimeout(() => ok(window.__lastPos)); return i; },
    clearWatch(i) { subs.delete(i); }, getCurrentPosition(ok) { if (window.__lastPos) ok(window.__lastPos); } };
  Object.defineProperty(navigator, 'geolocation', { value: geo, configurable: true });
  window.__fakeGps = (c) => { const pos = { coords: { latitude: c.lat, longitude: c.lon, accuracy: c.acc ?? 5, altitude: null, altitudeAccuracy: null,
      speed: c.speed ?? null, heading: c.heading ?? null }, timestamp: Date.now() }; window.__lastPos = pos; subs.forEach(f => f(pos)); };
  window.__fakeGps({ lat: %f, lon: %f, speed: 0, heading: -1 });
})();""" % (route[0][0], route[0][1])

SIM = """async ({ route, ta, tb, dur, v, skip }) => {
  const { quatFromOrientation, rotate, V } = await import('/nav.js?v=4');
  const R = 6371008.8, D = Math.PI / 180;
  const hav = (a, b) => { const x = Math.sin((b[0]-a[0])*D/2)**2 + Math.cos(a[0]*D)*Math.cos(b[0]*D)*Math.sin((b[1]-a[1])*D/2)**2; return 2*R*Math.asin(Math.sqrt(x)); };
  const brg = (a, b) => { const y = Math.sin((b[1]-a[1])*D)*Math.cos(b[0]*D), x = Math.cos(a[0]*D)*Math.sin(b[0]*D) - Math.sin(a[0]*D)*Math.cos(b[0]*D)*Math.cos((b[1]-a[1])*D); return (Math.atan2(y, x)/D + 360) % 360; };
  const cum = [0]; for (let i = 1; i < route.length; i++) cum.push(cum[i-1] + hav(route[i-1], route[i]));
  const at = (s) => { let i = cum.findIndex(c => c > s); if (i < 1) i = route.length - 1; const a = route[i-1], b = route[i], k = Math.min(1, (s - cum[i-1]) / Math.max(1e-6, cum[i] - cum[i-1]));
    return { lat: a[0] + (b[0]-a[0])*k, lon: a[1] + (b[1]-a[1])*k, course: brg(a, b) }; };
  const t0 = performance.now(); let lastG = -1, yawS = null;
  window.__simDone = false;
  const iv = setInterval(() => {
    const t = (performance.now() - t0) / 1000; if (t > dur) { clearInterval(iv); window.__simDone = true; return; }
    const p = at(skip + v * t);
    yawS = yawS == null ? p.course : yawS + (((p.course - yawS) % 360 + 540) % 360 - 180) * 0.05;
    const sec = Math.floor(t);
    if (sec !== lastG) { lastG = sec; if (!(t > ta && t < tb)) window.__fakeGps({ lat: p.lat, lon: p.lon, acc: 5, speed: v, heading: p.course }); }
    const alpha = -(yawS - 50), beta = 70 + (Math.random() - .5) * .3, gamma = (Math.random() - .5) * .3;
    window.dispatchEvent(new DeviceOrientationEvent('deviceorientation', { alpha, beta, gamma, absolute: false }));
    const q = quatFromOrientation(alpha, beta, gamma), qi = [-q[0], -q[1], -q[2], q[3]], g = rotate(qi, 0, 9.81, 0, new V());
    const n = () => (Math.random() - .5) * .5;
    window.dispatchEvent(new DeviceMotionEvent('devicemotion', { acceleration: { x: n(), y: n(), z: n() },
      accelerationIncludingGravity: { x: g.x + n(), y: g.y + n(), z: g.z + n() }, rotationRate: { alpha: n(), beta: n(), gamma: n() }, interval: 16 }));
  }, 16);
}"""

with sync_playwright() as p:
    b = p.chromium.launch(args=["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"])
    ctx = b.new_context(viewport={"width": 393, "height": 852}, device_scale_factor=2, is_mobile=True, has_touch=True)
    ctx.add_init_script(FAKE_GPS)
    pg = ctx.new_page()
    t_open = time.time()
    pg.on("dialog", lambda dl: dl.accept())
    pg.goto(URL); pg.wait_for_function("window.__loc", timeout=30000)
    pg.evaluate(f"localStorage.setItem('loc.mode', '{MODE}'); localStorage.removeItem('loc.rec'); localStorage.removeItem('loc.pending')")
    pg.reload(); pg.wait_for_function("window.__loc"); pg.wait_for_timeout(4000)
    # 직진 구간에서 거치 각도를 배우도록 3초 먼저 달림(영상에서는 잘라냄)
    pg.evaluate(SIM, {"route": route, "ta": 99, "tb": 99, "dur": 3.0, "v": 20, "skip": 0})
    pg.wait_for_function("window.__simDone === true", timeout=20000)
    # 화면 녹화: CDP 스크린캐스트(기기 해상도 프레임 + 시각)
    frames = []
    cdp = ctx.new_cdp_session(pg)
    def on_frame(e):
        frames.append((e["metadata"]["timestamp"], e["data"]))
        try: cdp.send("Page.screencastFrameAck", {"sessionId": e["sessionId"]})
        except Exception: pass
    cdp.on("Page.screencastFrame", on_frame)
    cdp.send("Page.startScreencast", {"format": "jpeg", "quality": 85, "maxWidth": 786, "maxHeight": 1704, "everyNthFrame": 1})
    pg.wait_for_timeout(500)
    start = time.time() - t_open
    pg.click("#btnRec")
    pg.evaluate(SIM, {"route": route, "ta": 5, "tb": 11, "dur": 14.5, "v": 20, "skip": 60})
    pg.wait_for_function("window.__simDone === true", timeout=40000)
    pg.wait_for_timeout(1500)
    end = time.time() - t_open
    cdp.send("Page.stopScreencast")
    info = pg.evaluate("({ n: __loc.pts.length, est: __loc.pts.filter(p => p.src === 'imu').length, kind: __loc.map.kind })")
    pg.evaluate("__loc.sync()"); pg.wait_for_timeout(3000)
    cid = pg.evaluate("__loc.rec?.cid")
    ctx.close(); b.close()

# 시연 기록 지우기
try:
    ip = subprocess.run("docker inspect location-api --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}'", shell=True,
                        capture_output=True, text=True).stdout.split()[0]
    for t in json.load(urllib.request.urlopen(f"http://{ip}:8000/api/tracks")):
        if t["client_id"] == cid:
            urllib.request.urlopen(urllib.request.Request(f"http://{ip}:8000/api/tracks/{t['id']}", method="DELETE"))
except Exception as e:
    print("정리 실패", e)

# 프레임 → 실제 시간 간격 그대로 영상으로 (concat 목록에 프레임별 길이)
import base64
for f in TMP.glob("f*.jpg"): f.unlink()
lst = []
for i, (ts, data) in enumerate(frames):
    fn = TMP / f"f{i:05d}.jpg"; fn.write_bytes(base64.b64decode(data))
    nxt = frames[i + 1][0] if i + 1 < len(frames) else ts + 0.1
    lst.append(f"file '{fn}'\nduration {max(0.001, nxt - ts):.4f}")
lst.append(f"file '{TMP / f'f{len(frames) - 1:05d}.jpg'}'")
(TMP / "list.txt").write_text("\n".join(lst))
subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(TMP / "list.txt"),
                "-vf", "scale=786:-2,fps=30", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "23", "-movflags", "+faststart", "-an", OUT], check=True)
print("frames", len(frames))
print(json.dumps({"out": OUT, "secs": round(end - start, 1), **info}, ensure_ascii=False))
