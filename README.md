# 📱 IMU 뷰어

![HTML5](https://img.shields.io/badge/HTML5-웹앱-E34F26?style=flat-square&logo=html5&logoColor=white)
![Three.js](https://img.shields.io/badge/Three.js-0.169-000000?style=flat-square&logo=threedotjs&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-nginx:alpine-2496ED?style=flat-square&logo=docker&logoColor=white)

아이폰 Safari로 접속하면 기기의 자이로·가속도 센서로 현재 자세를 3D 아이폰 모델에 실시간 반영하고(자세 모드), 가속도를 두 번 적분해 이동 궤적을 3D 그래프에 그리는(궤적 모드) 웹페이지.

👉 https://imu.b-612.kr

---

## ✨ 기능

| 항목 | 설명 |
|------|------|
| 3D 자세 표시 | `deviceorientation`(alpha/beta/gamma)을 쿼터니언으로 변환해 아이폰 모델 회전 |
| 기기 축 | 빨강=X(오른쪽), 초록=Y(화면 위), 파랑=Z(화면 밖) |
| 가속도 화살표 | `devicemotion.acceleration`(중력 제외)을 월드 좌표로 변환해 주황 화살표로 표시 |
| 수치 표시 | 앞뒤/좌우 기울기, 방향(나침반), 자이로 각속도, 가속도, 갱신 주기(Hz) |
| 정면 맞추기 | 현재 바라보는 방향을 화면 안쪽(앞)으로 재설정 |
| 시점 전환 | 정면 / 위 / 측면 / 사선 |
| 궤적 모드 | 3D 좌표축(m 눈금, 범위 자동 확대) 위에 이동 경로를 속도별 색으로 표시, 바닥 그림자 궤적, 손가락으로 회전·확대 |
| 그래프 상자 | 원점은 상자 가운데, 바닥면(채움+격자)은 상자 맨 아래, 천장은 옅은 파랑. 위/아래 라벨 |
| 추 | 상자 윗모서리에 매달린 추가 항상 중력 방향을 가리키고, 움직이면 가속도 반대쪽으로 흔들림 |
| 수평 유지 | 폰을 옆으로 기울여도 그래프의 아래가 실제 땅 방향을 향하도록 화면을 반대로 회전 |
| 중력 정렬 | 위가 위로 보이는 기본 시점으로 카메라 초기화 |
| 원점 초기화 | 위치·속도·궤적을 지우고 현재 방향을 '앞'으로 설정 |
| 정지 보정 | 정지 감지 시 속도를 0으로 고정(ZUPT)하고 센서 치우침을 학습해 빼줌, 약한 속도 감쇠 |

---

## 📈 궤적 계산

```mermaid
flowchart LR
  A[devicemotion.acceleration<br>기기 좌표] -->|자세 쿼터니언| B[월드 좌표 가속도]
  B --> C{정지 감지<br>가속도·회전 작음}
  C -->|정지| D[속도=0, 치우침 학습]
  C -->|이동| E[치우침 제거 → 사다리꼴 적분<br>가속도→속도→위치]
  E --> F[궤적 선]
```

> [!WARNING]
> 가속도를 두 번 적분하면 오차가 시간의 제곱으로 커집니다. 수 초 이내 손동작(원·글씨·들어 올리기)은 잘 나오지만, 걸어다니는 수십 초 경로는 정지 보정을 켜도 점점 틀어집니다. 움직임 사이사이 잠깐 멈추면 정확도가 올라갑니다.

---

## 🧭 좌표 변환

```mermaid
flowchart LR
  A[deviceorientation<br>alpha·beta·gamma] --> B[Euler ZXY<br>Rz·Rx·Ry]
  B --> C[지구 좌표<br>X=동 Y=북 Z=위]
  C -->|X축 -90°| D[three.js 좌표<br>Y=위 -Z=앞]
  D --> E[아이폰 모델 quaternion]
```

> [!NOTE]
> iOS는 HTTPS + 사용자 터치 후 `DeviceOrientationEvent.requestPermission()` 호출이 있어야 센서 값을 줍니다. 권한을 거부했다면 Safari를 완전히 닫았다가 다시 열어야 다시 물어봅니다.

---

## 🚀 배포

<details><summary>컨테이너 실행</summary>

```bash
docker run -d --name imu-viewer --network npm_network --restart unless-stopped \
  -v $PWD/public:/usr/share/nginx/html:ro \
  -v $PWD/nginx.conf:/etc/nginx/conf.d/default.conf:ro nginx:alpine
```

NPM 프록시 호스트: `imu.b-612.kr` → `imu-viewer:80` (인증서 `*.b-612.kr`)

</details>
