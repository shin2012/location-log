# 위치 기록 — iPhone 앱 (SwiftUI)

웹판(location.b-612.kr)과 같은 서버·DB를 쓰는 네이티브 앱. 화면이 꺼져도 GPS 기록이 계속됨.

## Mac에서 처음 열기

```bash
git clone https://github.com/shin2012/location-log.git   # 이미 있으면 git pull
open location-log/ios/LocationLog.xcodeproj
```

1. Xcode 16 이상 (프로젝트 형식 77, 폴더 자동 동기화 — `LocationLog/` 안에 파일을 넣으면 바로 빌드에 포함)
2. 타깃 LocationLog → Signing & Capabilities → **Team** 선택 (Apple Developer 계정)
   - 번들 ID `kr.b612.locationlog` 가 이미 쓰이면 바꿔도 됨
3. iPhone 연결 → 실행
4. 앱 **설정** 탭 → 앱 토큰 입력 (서버 `~/apps/location-log/.env` 의 `APP_TOKEN`) → **연결 확인**
5. 위치 권한은 **항상 허용** (설정 탭 버튼으로 이동)

프로젝트 파일이 안 열리면: `brew install xcodegen && cd ios && xcodegen` (project.yml)

## 구조

| 파일 | 하는 일 |
|---|---|
| `LocationLogApp.swift` | 진입점, 탭(기록·목록·설정), 5초마다 올리기 |
| `Recorder.swift` | CLLocationManager. 백그라운드 위치, 정확도 40m 거름, 70m/s 넘는 순간 이동 처리(웹 track.js 규칙) |
| `TrackStore.swift` | 이 기기 기록을 `Application Support/tracks.json`에 저장 → 서버로 올림(점 500개씩). 다 올라간 끝난 기록은 지움 |
| `API.swift` | `/app-api/*` 호출 (Bearer 토큰) |
| `Settings.swift` | 서버 주소(UserDefaults)·토큰(키체인) |
| `Views/` | 기록 화면(지도+통계), 목록(서버), 상세(지도·이름·이동 수단·데일리요섭 보내기), 설정 |
| `Config/Info.plist` | 위치 권한 문구, `UIBackgroundModes=location` (나머지는 Xcode가 자동 생성) |

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
