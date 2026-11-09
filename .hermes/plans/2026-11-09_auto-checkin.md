# 실라쥬 '자동 체크인' — IFTTT·람다 집/회사 체크인 대체 계획

작성: 2026-11-09 · 상태: **사용자 확인 대기 (구현 전)**

## 1. 지금 구조 (확인한 사실)
1. IFTTT(아이폰 위치 트리거, 진입) → 구글 캘린더 'FSQ' 캘린더에 일정 생성, 설명란 = 포스퀘어 venueId.
2. AWS 람다 `getSwarmCheckins` (EventBridge `cron_FSQ-GCal-Sync`, 1분마다) → `swarm.GoogleCalendar_to_Foursquare()`
   - 최근 15분 일정 중 `addedBy` 없는 것(=IFTTT가 만든 것)만, 설명란 venueId를 하드코딩 표 7곳과 비교.
   - 영업처·홍은풍림·쌍문래미안·아현역 헤센스: `FSQ_Swarm`에 `ManuallySaved_<유닉스시각>` 행 INSERT
     (장소 이름·주소·좌표 하드코딩, **시각 = 람다 실행 시각**, CALENDAR_SENT='N') → IFTTT 일정 삭제.
   - 본사·ID본부·골드벤처타워(대전): 포스퀘어 `checkins/add` API로 진짜 체크인.
3. 같은 람다의 `Database_to_GoogleCalendar()`가 CALENDAR_SENT='N' 행을 30분 일정으로 다시 올림.

이용량 (8/1~11/9 ManuallySaved): 영업처 145건, 홍은풍림 83건. 대전 3곳은 1년간 5건, 아현역은 2025-12 이후 없음.

문제점
- IFTTT·캘린더를 한 번 거치는 구조라 늦고(최대 1~2분), IFTTT 장애·정책 변경에 묶임.
- 퇴근할 때 회사 반경을 다시 들어온 것으로 잡혀 생기는 체크인(예: 10/14 19:02·19:36, 10/16 18:14, 10/21 17:52 — 데일리요섭에서 0분 체류).
- 장소가 람다 코드에 하드코딩 — 바꾸려면 람다 재배포.

실라쥬 정확도 (11/6부터 day_visit 있는 6건): IFTTT 체크인과 실라쥬 도착 차이 0~3분.

## 2. 바꿀 구조
```
실라쥬 앱(장소 반경 진입 감지·확인) → location-api POST /api/autocheckin
   → fsq_map POST /api/autocheckin (Bearer, CarPlay 전달과 같은 방식)
   → FSQ_Swarm INSERT (ManuallySaved_<유닉스시각>, CALENDAR_SENT='N')
   → 기존 람다 Database_to_GoogleCalendar 가 캘린더 등록 (변경 없음)
```

### 2-1. 실라쥬 앱 (ios/LocationLog)
- 설정 > '자동 체크인': 장소 목록(이름, 포스퀘어 venueId, 좌표, 반경 기본 150 m, 켜기/끄기). 처음엔 람다 표의 장소로 채움.
- 감지: 장소마다 `CLCircularRegion` 감시(iOS 한도 20개, 지금 '머묾' 감시가 1개 사용). 하루 종일 기록이 꺼져 있어도 동작.
- 확인 규칙(퇴근 때 다시 들어온 것으로 잡히는 체크인 방지):
  - 진입 후 **3분** 넘게 반경 안에 있으면 체크인. 시각은 **진입 시각**(보낸 시각 아님).
  - 같은 장소를 나간 지 **15분 안에** 다시 들어오면 무시.
  - 같은 장소 마지막 자동 체크인 후 다른 곳에 들르지 않았으면 무시.
- 통신이 안 되면 대기열에 쌓았다가 다시 보냄(CarPlayEvents와 같은 방식). 앱에 최근 자동 체크인 기록 표시.

### 2-2. location-api (server/app.py)
- `POST /api/autocheckin {venue_id, at, lat, lng, client_id}` → fsq_map에 그대로 전달. client_id로 중복 전송 막기.

### 2-3. fsq_map (app.py)
- `POST /api/autocheckin` (CARPLAY_API_TOKEN과 같은 Bearer, tinyauth 우회 location 블록 추가).
- 장소 정보(이름·분류·주소·좌표·도시)는 **그 venueId의 가장 최근 FSQ_Swarm 행에서 복사** → 하드코딩 없음.
- FSQ_ID = `ManuallySaved_<유닉스시각>` — fsq_map·Checkin-Sync-Tool·사진 백필 등 10여 곳이 이 접두어로
  '포스퀘어에 없는 체크인'을 판별하므로 새 접두어를 쓰면 전부 고쳐야 함. 그대로 씀.
- 같은 venueId로 ±10분 안에 이미 행이 있으면 저장하지 않음(IFTTT와 함께 돌리는 기간의 중복 방지).
- PHOTO·SHOUT는 '' (NULL이면 람다 캘린더 등록이 막힘).

### 2-4. 람다 / IFTTT
- 함께 돌려 본 뒤 `lambda_function.py`에서 `GoogleCalendar_to_Foursquare()` 호출 제거 → 람다 배포.
- IFTTT 애플릿 끄기는 사용자가 IFTTT 앱에서 직접.

## 3. 진행 순서
1. fsq_map·location-api 엔드포인트 + 테스트(테스트 행은 바로 삭제).
2. 실라쥬 앱 기능 → GitHub Actions → TestFlight.
3. **1주일 함께 돌리기**: 실라쥬는 '기록만'(서버 로그에만 남기고 FSQ_Swarm에 쓰지 않음)으로 시작 → 매일 IFTTT 체크인과 시각·누락·추가 건을 비교해서 보고.
4. 결과 확인 후 실라쥬 쓰기 켜기 → IFTTT 끄기 → 람다에서 캘린더→체크인 단계 제거.
5. 되돌리기: 실라쥬 설정에서 끄고 IFTTT 다시 켜면 원래대로(람다 이전 버전은 태그로 보관).

## 4. 확인받을 것
1. 대상 장소: 영업처·홍은풍림·쌍문래미안만? 아현역(2025-12 이후 없음)·대전 3곳(포스퀘어 진짜 체크인)은 빼도 되는지.
2. 확인 규칙 수치: 3분 머묾 / 15분 내 재진입 무시.
3. 함께 돌리는 기간: 1주일, 처음엔 '기록만'.
4. 퇴근(반경 이탈) 기록은 이번 범위 밖으로 둬도 되는지.
