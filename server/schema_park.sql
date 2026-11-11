-- 기압계 (iOS CMAltimeter). 층 이동·주차 층 추정용. 시각 UTC.
-- 앱은 기압이 약 10cm(0.001 kPa) 넘게 바뀌었거나 1분 지났을 때만 저장해 올림.
CREATE TABLE IF NOT EXISTS day_baro (
  ts  DATETIME(3) NOT NULL COMMENT 'UTC',
  kpa DOUBLE NOT NULL COMMENT '기압 kPa',
  PRIMARY KEY (ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='하루 종일 기록 기압';

-- 주차 (CarPlay 해제 순간). level: 지상1층=0, 2층=1, 지하1층=-1 …
CREATE TABLE IF NOT EXISTS park (
  ts         DATETIME(3) NOT NULL COMMENT 'UTC, CarPlay 해제',
  lat        DOUBLE NULL,
  lon        DOUBLE NULL,
  dh         DOUBLE NOT NULL COMMENT '지상 도로(ref_ts) 대비 높이 차 m',
  ref_ts     DATETIME(3) NULL COMMENT '기준: 마지막으로 빠르게 달린 시각',
  level_est  SMALLINT NOT NULL COMMENT '앱이 알림 낼 때 추정한 층',
  level_user SMALLINT NULL COMMENT '사용자가 고치거나 맞다고 한 층',
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='주차 층';

-- 1.5.0: 머문 곳 안 층 이동
-- 연결된 공유기가 바뀐 시각 (iOS NEHotspotNetwork). bssid NULL = Wi-Fi 연결 없음
CREATE TABLE IF NOT EXISTS day_wifi (
  ts    DATETIME(3) NOT NULL COMMENT 'UTC',
  bssid VARCHAR(17) NULL COMMENT '공유기 고유번호 (소문자)',
  ssid  VARCHAR(64) NULL,
  PRIMARY KEY (ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='연결 공유기';

-- 사용자가 확정한 층 구간 → 장소별 층 높이·공유기 층 학습 (level: 지상1층=0)
CREATE TABLE IF NOT EXISTS floor_cal (
  ts    DATETIME(3) NOT NULL COMMENT '층 구간 시작 UTC',
  lat   DOUBLE NOT NULL,
  lon   DOUBLE NOT NULL,
  dh    DOUBLE NOT NULL COMMENT '들어온 곳(지상 또는 주차 높이) 대비 m',
  level SMALLINT NOT NULL,
  ap    VARCHAR(20) NULL COMMENT '그 구간 주로 연결된 공유기 (BSSID 앞 5바이트)',
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='층 확정';

ALTER TABLE day_step ADD COLUMN IF NOT EXISTS floors_up TINYINT UNSIGNED NULL COMMENT '만보계 계단 오른 층수',
                     ADD COLUMN IF NOT EXISTS floors_down TINYINT UNSIGNED NULL COMMENT '만보계 계단 내린 층수';

-- 1.6.0: 건강 앱 (워치 걸음·오른 층수). 폰을 두고 다닐 때 층 이동
CREATE TABLE IF NOT EXISTS day_hk (
  uuid   CHAR(36) NOT NULL COMMENT 'HealthKit 기록 uuid',
  kind   VARCHAR(8) NOT NULL COMMENT 'steps | flights',
  start  DATETIME(3) NOT NULL COMMENT 'UTC',
  end    DATETIME(3) NOT NULL,
  value  DOUBLE NOT NULL COMMENT '걸음 수 / 오른 층수',
  device VARCHAR(8) NOT NULL DEFAULT 'other' COMMENT 'watch | phone | other',
  PRIMARY KEY (uuid),
  KEY (start)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='건강 앱 걸음·층';

-- 1.8.0: 다른 앱 데이터에 기대지 않게 시야쥬 쪽에 사본
-- CarPlay 연결·해제: 앱이 보낸 것 + swarm.FSQ_CarPlay(단축어 등)를 조회할 때 복사. 원본이 지워져도 남음
CREATE TABLE IF NOT EXISTS car_event (
  ts     DATETIME(3) NOT NULL COMMENT 'UTC',
  event  VARCHAR(10) NOT NULL COMMENT 'car_start | car_end',
  lat    DOUBLE NULL,
  lng    DOUBLE NULL,
  src    VARCHAR(8) NOT NULL DEFAULT 'app' COMMENT 'app | fsq',
  fsq_id INT NULL,
  PRIMARY KEY (ts, event),
  UNIQUE KEY (fsq_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='CarPlay 연결 사본';

-- 스웜 체크인 이름 사본: 타임라인 조회 때 원본과 비교해 바뀌었으면 고침, 원본에서 사라져도 남김(gone_at)
CREATE TABLE IF NOT EXISTS checkin_snap (
  fsq_id     VARCHAR(24) NOT NULL,
  ts         DATETIME NOT NULL COMMENT 'UTC',
  venue      VARCHAR(255) NOT NULL,
  lat        DOUBLE NOT NULL,
  lon        DOUBLE NOT NULL,
  seen_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  changed_at TIMESTAMP NULL,
  gone_at    TIMESTAMP NULL COMMENT '원본에서 사라진 걸 알아챈 때 (그래도 씀)',
  PRIMARY KEY (fsq_id),
  KEY (ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='스웜 체크인 사본';

ALTER TABLE day_hk ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP NULL COMMENT '건강 앱에서 지워짐 (사본은 남겨 계속 씀)';

-- 1.9.0: 앱이 계산한 날짜별 타임라인 결과 (서버는 계산 안 함 — 보관·전달만)
CREATE TABLE IF NOT EXISTS day_result (
  date        DATE NOT NULL COMMENT '한국 날짜',
  json        MEDIUMTEXT NOT NULL,
  device      VARCHAR(40) NOT NULL DEFAULT '',
  computed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='앱 계산 타임라인 결과';
