# Sillage — 위치 기록 iPhone 앱 (SwiftUI)

웹판(location.b-612.kr)과 같은 서버·DB를 쓰는 네이티브 앱. 화면이 꺼져도 GPS 기록이 계속됨.

## Mac에서 처음 열기

```bash
git clone https://github.com/shin2012/location-log.git   # 이미 있으면 git pull
open location-log/ios/LocationLog.xcodeproj
```

1. Xcode 16 이상 (프로젝트 형식 77, 폴더 자동 동기화 — `LocationLog/` 안에 파일을 넣으면 바로 빌드에 포함)
2. 타깃 LocationLog → Signing & Capabilities → **Team** 선택 (Apple Developer 계정)
   - 번들 ID `kr.b-612.sillage` 가 이미 쓰이면 바꿔도 됨
3. iPhone 연결 → 실행
4. 앱 **설정** 탭 → 앱 토큰 입력 (서버 `~/apps/location-log/.env` 의 `APP_TOKEN`) → **연결 확인**
5. 위치 권한은 **항상 허용** (설정 탭 버튼으로 이동)

프로젝트 파일이 안 열리면: `brew install xcodegen && cd ios && xcodegen` (project.yml)

## 구조 (웹판 public/app.js와 같은 화면 — 센서 추정 제외)

| 파일 | 하는 일 |
|---|---|
| `LocationLogApp.swift` | 진입점, 한 화면(지도/기록 모드) + 아래 버튼 3개(화면 전환 · 기록 시작/종료 · 설정), 5초마다 올리기 |
| `Views/MapModeView.swift` | 전체 지도 + 위 오버레이(속도·방향 게이지·기록 시간, GPS 상태·점 수·업로드 대기) + 내 위치 따라가기 |
| `Views/LogModeView.swift` | 기록 요약(시간·거리·속도·기록한 위치) + `시각 / 위도, 경도 / 속도` 줄, 20초 넘게 비면 "N분 동안 기록 없음" |
| `Views/SettingsSheet.swift` | 저장된 기록 목록(날짜·거리·시간·점 수, 기록 중/업로드 대기/보냄 표시, 이동 수단, 지도·이름 변경·데일리요섭 보내기·삭제) + 서버·토큰 + 화면 켜 두기 |
| `Views/RouteDetailView.swift` | 경로 보기 (지도 + 정보 줄) |
| `Views/Common.swift` | 색, 안내 메시지(토스트), 상태 줄, 방향 게이지 |
| `Recorder.swift` | CLLocationManager. 앱이 앞에 있으면 늘 위치·나침반 받음, 기록 중이면 백그라운드도. 정확도 40m, 70m/s 순간 이동 처리, 움직이다 3초 끊기면 "GPS 신호 약함" |
| `TrackStore.swift` | 기기 저장(`Application Support/tracks.json`) → 서버로 올림(500점씩). 토큰 없으면 기기에만 보관 |
| `API.swift` | `/app-api/*` 호출 (Bearer 토큰) |
| `Settings.swift` | 서버 주소(UserDefaults)·토큰(키체인) |
| `DayPolicy.swift` | 하루 종일 기록 상태 기계(순수 Foundation): 머묾/이동/움직임 확인/GPS 확인, 단계별 GPS 설정, 출발 구간 메우기. 리눅스 시뮬 `tools/daysim` |
| `DayLogger.swift` | 하루 종일 기록 실행: 머무는 동안 저정확도 위치로 앱만 깨워 두고 GPS 끔, 움직임 감지·주기 GPS 확인·경계/방문/기지국 변화로 출발 감지, 배터리 부족 시 절약, 쉬는 시간·제외 장소, 수동 기록 중엔 그 점을 받아 씀 |
| `DayLogStore.swift` | 날짜별 `day/YYYY-MM-DD.jsonl` 덧붙여 저장 + 묶음 업로드(`/day/points`, Wi-Fi 전용 선택) + 보관 기간 정리 |
| `DaySettings.swift` | 하루 종일 기록 설정(UserDefaults `day.prefs`) |
| `Views/DayLogViews.swift` | 설정 › 하루 종일 기록(각 기능 켜고 끄기), 날짜별 목록, 하루 지도(경로 + 머문 곳) |

웹과 다른 점: 지도는 Apple 지도(웹은 네이버/Leaflet), 터널 센서 추정·센서 실험실 없음.

## 서버 쪽 (이미 적용됨)

- `https://location.b-612.kr/app-api/...` → 웹과 같은 `/api/...` (로그인 없이 통과)
- 대신 api 서버가 `Authorization: Bearer <APP_TOKEN>` 검사 (웹 nginx가 `/app-api/` 요청에만 `X-App-Gate: 1` 표시)
- 웹 `/api/` 는 예전처럼 로그인(tinyauth/Tailscale) 필요

## 남은 일 (Mac에서)

- [ ] 실기기 빌드 확인 (Linux에서는 문법 검사 + 동기화 로직만 실제 서버로 시험함 — SwiftUI·MapKit·CoreLocation 부분은 컴파일 못 해 봄)
- [ ] 앱 아이콘: `Assets.xcassets/AppIcon` 비어 있음
- [ ] 터널 구간 추정(CoreMotion) — 웹 `public/track.js` DR 이식
- [ ] 네이버 지도 SDK로 바꿀지 (지금은 Apple 지도)
- [ ] Cloudflare 봇 검사에 걸리면(간헐적 403/타임아웃) location 서브도메인 proxied=false 검토
