# 📍 시야쥬 (location-log)

![Swift](https://img.shields.io/badge/SwiftUI-iPhone·iPad-F05138?style=flat-square&logo=swift&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-API-009688?style=flat-square&logo=fastapi&logoColor=white)
![MariaDB](https://img.shields.io/badge/MariaDB-location__log-003545?style=flat-square&logo=mariadb&logoColor=white)

이동 경로와 하루 동선을 기록하는 **iOS 앱 '시야쥬'**와 그 앱 전용 API. 경로 기록(수동), 자동 기록(하루 종일), 자동 체크인, CarPlay·운전 기록을 맡고, 데일리요섭이 DB(`location_log`)를 읽어 하루 페이지에 씀.

> [!NOTE]
> 웹 화면(location.b-612.kr 웹앱·`/lab` 센서 실험실)은 2026-11 에 없앰. 되돌리기: 태그 `before-web-removal`.
> 터널 추정 알고리즘(예전 `public/track.js`)은 앱의 `ios/LocationLog/DeadReckoner.swift` 로 옮겨져 있음.

---

## 🗄 저장

- 폰: 기록은 기기에 바로 저장(앱이 꺼졌다 켜져도 이어 기록) → 서버로 묶어 올림. `(track_id, seq)` 기준 REPLACE라 재전송·사후 보정이 안전
- MariaDB `location_log` (계정 `loc_rw`, `.env`)

| 테이블 | 내용 |
|------|------|
| `track` | id, client_id, name, started_at, ended_at, distance_m, n_points, n_est, sent_daily_at |
| `track_pt` | track_id, seq, ts(UTC), lat, lon, alt, acc, spd, hdg, src(`gps`/`imu`) |
| `day_pt` | 하루 종일 기록 점: ts(UTC, PK), lat, lon, alt, acc, spd, src(`gps`/`fill`/`trk`…), act(이동 수단) — `server/schema_day.sql` |
| `day_visit` | 하루 종일 기록 머문 곳: arrive(PK), depart, lat, lon, updated_at(데일리요섭 변경 감지) |
| `day_act` | 이동 방식이 바뀐 시각: ts(UTC, PK), act(stationary/walk/run/bike/car), conf(0~2) — iOS 동작 기록, 업로드 때마다 7일치 안에서 지난 커서부터 다시 조회 |
| `day_step` | 1분 걸음: ts(UTC 분 시작, PK), steps, dist_m — iOS 만보계(CMPedometer), 0 걸음 분도 올림. 처음 켜면 2일 거슬러, 한 번에 최대 24시간 |
| `day_baro` | 기압: ts(UTC, PK), kpa — iOS 기압계(CMAltimeter), 약 8cm 넘게 바뀌거나 1분마다. 층 이동 분석용 — `server/schema_park.sql` |
| `day_wifi` | 연결 공유기가 바뀐 시각: ts(PK), bssid(공유기 고유번호, NULL=연결 없음), ssid — 층 판정 보조 (1.5.0) |
| `floor_cal` | 사용자가 확정한 층 구간: ts(구간 시작, PK), lat, lon, dh, level, ap(BSSID 앞 5바이트) (1.5.0) |
| `day_hk` | 건강 앱 기록: uuid(PK), kind(steps=워치 걸음만 / flights=오른 층수), start, end, value, device(watch/phone) (1.6.0) |
| `park` | 주차: ts(CarPlay 해제, PK), lat, lon, dh(지상 도로 대비 m), ref_ts, level_est, level_user(사용자 확정) — level 지상1층=0·지하1층=-1 |

<details><summary>API (앱은 <code>/app-api/…</code> 로 부름 = <code>/api/…</code>, 모두 Bearer 토큰)</summary>

| 메서드 | 경로 | 내용 |
|------|------|------|
| GET/POST | `/api/tracks` | 목록 / 생성(client_id 중복이면 기존 것) |
| GET/PATCH/DELETE | `/api/tracks/{id}` | 상세(점 포함) / 이름·종료 시각 / 삭제 |
| POST | `/api/tracks/{id}/points` | 점 일괄 저장 |
| POST | `/api/tracks/{id}/send-daily` | 데일리요섭 보내기 (우선순위 확정 전 503) |
| POST | `/api/day/points`, `/api/day/visits`, `/api/day/acts`, `/api/day/steps` | 하루 종일 기록 묶음 저장 (ts 기준 REPLACE) |
| GET | `/api/day` | 기록 있는 날짜(한국 시각)·점 수 |
| GET/DELETE | `/api/day/{YYYY-MM-DD}` | 그날 점·머문 곳 / 삭제 |
| POST | `/api/carplay` | CarPlay 연결·해제 → fsq_map 전달 |
| GET/POST | `/api/autocheckin/places`, `/api/autocheckin/event`, `/api/autocheckin/events` | 자동 체크인 장소·이벤트 |
| GET | `/api/health` | 상태 확인 (토큰 없이) |

</details>

---

---

## 🚀 배포

```bash
docker compose -p location-log up -d --build   # location-api(FastAPI) 하나
python3 tests/test_autocheckin.py              # 자동 체크인 확정 규칙
python3 tests/test_timefix.py                  # 도착·떠남 시각 보정
```

NPM 호스트 75 `location.b-612.kr` → `location-api:8000` (인증서 `*.b-612.kr`, 로그인 보호 없음 — 모든 요청 Bearer `APP_TOKEN`, `/api/health` 만 예외).
앱 주소는 `https://location.b-612.kr/app-api` 그대로(API 가 `/app-api/` → `/api/` 로 바꿔 받음).

## iPhone 네이티브 앱 (`ios/`)

SwiftUI 앱. 백그라운드에서도 GPS 기록. `https://location.b-612.kr/app-api/` (Bearer `APP_TOKEN`, `.env`)로 같은 API 사용.
자세한 내용: [ios/README.md](ios/README.md)

## 걷기 감지 후 확인 GPS (1.2)
- 머무는 중 움직임 감지(걷기·차 등) → 3분간 정밀 GPS로 확인(`probing`). '멈춤'은 2분 이어져야 끔(엘리베이터 앞 잠깐 멈춤 무시).
- 확인 중 머문 곳 반경 안에서 받은 점은 모아 뒀다가 떠난 것으로 판정되면 떠난 시각 이후 점을 경로 앞에 붙임(현관 → 차), 아니면 버림. 떠난 시각 = 처음 움직이기 시작한 때(2분 미만 멈춤 무시).
- 시험: `swiftc -O ios/LocationLog/DayPolicy.swift tools/probetest/main.swift -o /tmp/pt && /tmp/pt`

## 충전 중 · 운전 · CarPlay (v0.7)
- 충전 중: 움직일 때 '정밀', 머무는 동안 GPS 확인 3분마다 (`chargePrecise`)
- 발열(iOS `thermalState`가 serious 이상): 기록은 끄지 않고 정밀도만 한 단계 낮춤 — 1초 엔진은 내비게이션용 최고 → 일반 최고, 하루 기록 이동 중 최고 → 10m. 상태 문구에 '발열 심각' 표시
- 자동 운전 1초 기록 (1.3.0~): 차로 이동(CarPlay 연결 또는 동작 '자동차') + 충전 중이면 `Recorder.startAuto()` → 1초 GPS + 터널 센서 추정. **경로 기록(track)은 만들지 않고** 점(trk)·추정점(imu)은 하루 기록(`day_pt`)에만. 경로 기록 메뉴와 독립 — 자동 운전 중에 수동 기록을 켜고 꺼도 서로 영향 없음 (Recorder 엔진 = 수동 기록 ∪ 자동 운전)
- 판단 = `DriveGate.swift`(순수 로직, 시험 `tools/drivegate`). 이번 운전에서 CarPlay 연결과 충전이 한 번이라도 확인되면 **운전 끝까지 1초 정밀도 고정** — 충전이 빠지거나 동작이 흔들려도 유지. 끝 = CarPlay 해제 신호 1분 뒤(그 사이 다시 연결되면 이어감). 해제 신호가 안 오면 '자동차' 아닌 동작 10분 뒤 끝(동작 '모름'은 안 셈), 그 뒤 새 연결·'자동차' 동작 전까지 다시 안 켬. CarPlay 없는 '차량 이동'은 조건이 풀리면 3분 뒤 끔 (`driveRecord`)
- CarPlay: 1순위 단축어 자동화(CarPlay 연결 시/해제 시) → 앱 동작 `CarPlay 연결 기록하기`/`CarPlay 연결 해제 기록하기` (`CarPlayIntents.swift`, 한 번 받으면 오디오 경로 판정 끔), 2순위 소리 출력 경로의 carAudio (`CarPlay.swift`) → `POST /api/carplay` (쌓아 두고 재전송) → location-api 가 fsq_map `/api/carplay/event` 로 전달(`FSQ_CARPLAY_URL`, `CARPLAY_API_TOKEN` in .env, device='Sillage'). 단축어 대신 (`carplaySend`)

## 자동 체크인 (v0.9) — IFTTT·람다 대체

```mermaid
flowchart LR
  A[시야쥬 앱<br>장소 반경 100m 진입·이탈] -->|POST /api/autocheckin/event| B[location-api<br>place_event]
  B -->|3분 머묾 확정<br>15분 안 재진입 무시| C{AUTOCHECKIN_WRITE}
  C -->|1| D[fsq_map /api/autocheckin<br>FSQ_Swarm ManuallySaved_]
  D --> E[람다가 캘린더 등록]
  C -->|0 기록만| B
```

- 장소: `auto_place` 테이블 (앱이 6시간마다 받아 감, 앱 업데이트 없이 변경). 감시 중심은 실제 머무는 곳 좌표.
- 이벤트: `place_event` (UTC). 상태 `pending → confirmed / ignored(이유) / sent / failed`. 확정 규칙은 `server/autocheckin.py`, 시험 `python3 tests/test_autocheckin.py`.
- 이탈(퇴근)도 확정해 저장 — 데일리요섭 체류 끝 시각에 쓸 예정.
- `AUTOCHECKIN_WRITE=0`(기본)이면 기록만, `1`이면 확정된 진입을 fsq_map으로 넘겨 체크인 저장. fsq_map은 같은 장소 ±10분 체크인이 있으면 저장하지 않음.
- 시각 보정 (`server/timefix.py`): 확정되면 `place_event.adj_at` 에 실제 시각 저장 — 진입 = 반경 안에서 처음 멈춘 때(위치 점 속도 < 1m/s, 진입 10분 전~5분 뒤), 이탈 = 그 직전 '멈춤 → 걷기·차' 시작(기기 동작 `day_act`, 2분 미만 멈춤은 무시, 최대 10분 앞). 못 찾으면 감지 시각. 스웜 전달·이벤트 API `at` 은 이 시각(`detected_at` = 원래 감지 시각). 진입은 위치 점이 올라올 때까지 최대 12분 기다렸다 전달.
- 타임라인도 같은 기준: 머문 곳 끝 = 움직이기 시작한 때, 다음 이동 시작 = 그 시각.
- (1.2.x 의 자동 운전 기록 끝 자르기 `trim_drives`는 1.3.0 에서 삭제 — 자동 운전이 track 을 만들지 않음. 남아 있던 4건은 빠진 점을 day_pt 에 합친 뒤 삭제, 백업 ~/backups/location_auto_tracks_33-36.json)

## 경로 기록 이동 수단 자동 인식 · 점 솎기 (1.3.0)
- 경로 기록 화면에 이동 수단 선택 없음. 끝낼 때 `ModeGuess`: 기록 구간 기기 동작 기록(CMMotionActivity, 낮은 확신 제외)에서 가장 오래 이어진 차·도보·자전거(2분 미만 무시) → 없으면 평균 속도(20km/h↑ 차량, 8km/h↓ 도보, 그 사이 기타). 인식 중(`LocalTrack.guessing`)에는 서버 반영·목록 정리 미룸, 앱이 꺼지면 다음 실행 때 다시 인식
- 목록에서 바꾸면 `mode_auto=0`(사용자 선택, 자동 인식이 덮어쓰지 않음). 자동 인식 값은 '도보 · 자동' 배지. 서버 `track.mode_auto` (NULL = 1.2 이전 기록)
- 하루 기록 저장 단계의 거리 솎기 삭제: 받은 점은 모두 저장(시각 역행·순간이동만 거름). 덜 받는 건 iOS 정확도·`distanceFilter` 설정이 맡음 — 1초 기록 중 받은 점을 버리던 것(배터리 이득 없음)을 없앤 것

## 타임라인 탭 다시 누르기 (1.3.1)
- '타임라인' 탭(아이패드 사이드바 포함)을 이미 고른 상태에서 다시 누르면(더블탭) 무조건 오늘 날짜로 — 열린 시트·지도 화면 닫고, 이미 오늘이면 새로 불러옴. `AppTab.reselected` 알림

## 주차 층 (1.4.0)
- 하루 기록이 켜져 있으면 기압계(CMAltimeter)를 계속 받음: 최근 2시간은 메모리(주차 계산), 파일·서버(`POST /api/day/baro`)엔 0.001 kPa 넘게 바뀌거나 1분마다.
- CarPlay 해제 = 주차. 마지막으로 5 m/s 이상·정확도 30m 안으로 달린 시각(지상 도로, 30분 안)의 기압과 비교 → 높이 차 dh → 층 추정 → 1분 뒤 알림(맞아요 / 한 층 위 / 한 층 아래). 1분 안에 CarPlay 다시 연결되면 취소.
- 추정 규칙 = `server/parking.py` ↔ `ios/LocationLog/ParkModel.swift` (같은 규칙, 바꾸면 둘 다): dh ≈ a·level + b, 사용자가 확정한 주차 중 150m 안 것으로 장소별 a(층 높이)·b(입구 높이) 맞춤, 없으면 전체 층 높이 중앙값(처음 3.2m).
- 서버 `POST /api/park`, `PATCH /api/park/{ts_ms}` {level|null}, `GET /api/park/calib`, `GET /api/park`. 타임라인 운전 이동에 `park` {ts, level, label, est} — 확정 안 한 건 그때그때 최신 보정으로 다시 추정.
- 시험: `python3 tests/test_parking.py`, `swiftc ios/LocationLog/ParkModel.swift tools/parktest/main.swift -o /tmp/pt && /tmp/pt`

## 머문 곳 안 층 이동 (1.5.0)
- `server/floors.py` (시험 `python3 tests/test_floors.py`): 기압 → 높이. 날씨 탓 느린 변화(실측 1.5시간 +4m)는 무시하고 **4분 안에 2.5m 넘게 바뀐 뒤 1분 안정**된 계단식 변화만 층 이동. 층 이동끼리의 높이 차만 더함.
- 방식: 만보계 계단 층수(`day_step.floors_up/down`) → 계단, 수직 0.8m/s 이상 → 엘리베이터, 걸음 많음 → 계단, 그 밖 → 에스컬레이터.
- 층 번호: 머문 곳에 들어온 순간 = 지상 1층(차로 와서 주차했으면 주차 높이) + 층 이동 합 → parking 모델(장소 150m, 처음 층 높이 3.5m). 사용자 확정 `PUT /api/floor` → `floor_cal`.
- 공유기(BSSID, `WifiLog.swift`, 'Wi-Fi 정보 접근' 권한 `Config/LocationLog.entitlements`)는 보조: 같은 공유기(앞 5바이트)에서 같은 층으로 2번 이상 확정했을 때만 그 층.
- 타임라인 머문 곳 `floors` [{start, end, level, label, est, via, dh, ap}] — 층 이동이 있을 때만. 앱에서 층을 눌러 고침.

## 폰 두고 다닐 때 — 워치 (1.6.0)
- `HealthHistory.swift`: HealthKit anchored query 로 워치 걸음·오른 층수(flightsClimbed) → `POST /api/day/health` (uuid REPLACE, 지운 것 삭제) → `day_hk`. 잠금 중엔 못 읽음 → 다음 업로드에 다시. 권한 = 건강 읽기(entitlement healthkit), 설정 '워치 걸음·계단'.
- `floors.excursions`: 워치 오른 층 + 그 시각 폰 걸음 없음 + 기압 층 이동과 안 겹침 → 그때 폰 층 + 오른 층수. 돌아온 시각 = 2분 넘게 지나 시작된 다음 워치 걸음 덩어리(없으면 폰이 움직인 때). 건강 앱엔 내린 층·엘리베이터가 없음.
- 워치 기록은 **층 이동 추정에만** 씀('폰 두고 이동' 표시는 없앰 — 사용자 결정). 워치 걸음은 최대 10분 덩어리라 폰 걸음과 비교할 땐 덩어리 단위로. 워치 계단 층·돌아옴은 폰으로 확인된 층 구간(`floors[].subs`) 또는 머문 곳(`subs`)의 하위 항목, 시간순, 작은 글씨.

