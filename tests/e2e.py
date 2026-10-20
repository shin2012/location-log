"""location.b-612.kr 화면 시험: python tests/e2e.py (Playwright, 아이폰 크기)"""
import json, sys, time
from playwright.sync_api import sync_playwright

URL = sys.argv[1] if len(sys.argv) > 1 else "https://location.b-612.kr/"
OUT = "/home/yoseop/.hermes/cache/scratch/"
fails = []

with sync_playwright() as p:
    b = p.chromium.launch(args=["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"])
    ctx = b.new_context(viewport={"width": 393, "height": 852}, device_scale_factor=2, is_mobile=True, has_touch=True,
                        geolocation={"latitude": 37.5665, "longitude": 126.9780, "accuracy": 5}, permissions=["geolocation"])
    pg = ctx.new_page()
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("console", lambda m: errs.append(m.text) if m.type == "error" else None)
    pg.on("dialog", lambda d: d.accept())
    pg.goto(URL); pg.wait_for_function("window.__loc", timeout=20000)
    pg.evaluate("localStorage.clear()")
    pg.wait_for_timeout(2500)
    kind = pg.evaluate("__loc.map.kind")
    print("지도 엔진:", kind)
    pg.screenshot(path=OUT + "loc_idle.png")
    pg.click("#btnRec"); pg.wait_for_timeout(500)
    for i in range(12):   # 동쪽으로 초당 약 10m
        ctx.set_geolocation({"latitude": 37.5665 + i * 0.00002, "longitude": 126.9780 + i * 0.00011, "accuracy": 5})
        pg.wait_for_timeout(1000)
    n = pg.evaluate("__loc.pts.length"); print("기록 점:", n)
    if n < 5: fails.append(f"points {n}")
    pg.screenshot(path=OUT + "loc_map.png")
    pg.click("#btnMode"); pg.wait_for_timeout(500)
    lines = pg.evaluate("document.querySelectorAll('#logList .ln').length"); print("기록 줄:", lines)
    if lines < 5: fails.append(f"log lines {lines}")
    pg.screenshot(path=OUT + "loc_log.png")
    # 모드 전환해도 기록 유지
    pg.click("#btnMode"); pg.wait_for_timeout(300)
    if not pg.evaluate("!!__loc.rec"): fails.append("rec lost after mode switch")
    # 새로고침해도 이어짐
    pg.reload(); pg.wait_for_function("window.__loc"); pg.wait_for_timeout(1500)
    n2 = pg.evaluate("__loc.pts.length"); print("새로고침 후 점:", n2, "기록 중:", pg.evaluate("!!__loc.rec"))
    if n2 < n or not pg.evaluate("!!__loc.rec"): fails.append("resume failed")
    pg.wait_for_timeout(5500)   # 동기화
    pg.click("#btnRec"); pg.wait_for_timeout(6000)
    pg.evaluate("__loc.sync()"); pg.wait_for_timeout(2000)
    pg.click("#btnSet"); pg.wait_for_timeout(2500)
    rows = pg.evaluate("[...document.querySelectorAll('.trk')].map(e=>e.innerText.replace(/\\n/g,' | '))"); print("목록:", rows[:3])
    pg.screenshot(path=OUT + "loc_settings.png")
    if not rows: fails.append("no tracks")
    # 이름 변경
    pg.click(".trk >> nth=0 >> [data-a=rename]"); pg.fill(".rename input", "e2e 시험 경로"); pg.click(".rename button"); pg.wait_for_timeout(1000)
    # 지도 보기
    pg.click(".trk >> nth=0 >> [data-a=view]"); pg.wait_for_timeout(3500)
    print("상세:", pg.inner_text("#detailInfo"))
    pg.screenshot(path=OUT + "loc_detail.png")
    pg.click("#btnDetailClose")
    tid = pg.evaluate("fetch('api/tracks').then(r=>r.json()).then(l=>l.find(t=>t.name==='e2e 시험 경로'))")
    print("서버:", json.dumps(tid, ensure_ascii=False)[:200])
    if not tid: fails.append("rename not saved")
    else:
        pg.click(".trk >> nth=0 >> [data-a=del]"); pg.wait_for_timeout(1500)
        left = pg.evaluate(f"fetch('api/tracks/{tid['id']}').then(r=>r.status)"); print("삭제 후 상태:", left)
        if left != 404: fails.append("delete failed")
    pg.goto(URL + "lab/"); pg.wait_for_timeout(2500)
    print("실험실 제목:", pg.title())
    print("페이지 오류:", errs)
    b.close()
print("FAILS:", fails)
