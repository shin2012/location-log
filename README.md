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
python3 tests/test_timefix.py                  # 도착·떠남·운전 끝 시각 보정
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
- 충전 중(발열 '심각' 미만): 움직일 때 '정밀', 머무는 동안 GPS 확인 3분마다 (`chargePrecise`)
- 차로 이동(CarPlay 연결 또는 동작 '자동차') + 충전 중: 경로 기록을 자동으로 켬(`Recorder.startAuto`, 이름 '운전 · …' = CarPlay 연결, '차량 이동 · …' = 연결 없음) → 1초 GPS + 터널 센서 추정. 그 점(trk)과 추정점(imu)이 하루 종일 기록에도 들어감. 조건이 풀리면 3분(CarPlay 해제 직후면 1분) 뒤 끔. 직접 켠 기록은 건드리지 않음 (`driveRecord`)
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
- 자동 운전 기록('운전 …'/'차량 이동 …')은 끝나고 10분 뒤 한 번, CarPlay 해제(없으면 동작 '차' 끝) 앞 마지막 주행(2m/s↑) 다음 멈춘 점에서 뒤를 잘라냄 (`track.trimmed_at`, 이후 앱이 보내는 끝 시각은 무시).
