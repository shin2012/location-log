-- 하루 종일 기록 (앱 '하루 종일 기록' 기능). 시각은 모두 UTC.
CREATE TABLE IF NOT EXISTS day_pt (
  ts   DATETIME(3) NOT NULL COMMENT 'UTC',
  lat  DOUBLE NOT NULL,
  lon  DOUBLE NOT NULL,
  alt  DOUBLE NULL,
  acc  DOUBLE NULL COMMENT '수평 오차 m',
  spd  DOUBLE NULL COMMENT 'm/s',
  src  VARCHAR(8) NOT NULL DEFAULT 'gps' COMMENT 'gps|fill(출발 구간 메움)|stay|visit|slc|region|trk(수동 기록)',
  act  VARCHAR(10) NULL COMMENT 'stationary|walk|run|bike|car|unknown',
  PRIMARY KEY (ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='하루 종일 기록 점';

CREATE TABLE IF NOT EXISTS day_visit (
  arrive DATETIME(3) NOT NULL COMMENT 'UTC',
  depart DATETIME(3) NULL COMMENT 'UTC, 머무는 중이면 NULL',
  lat    DOUBLE NOT NULL,
  lon    DOUBLE NOT NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (arrive)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='하루 종일 기록 머문 곳';

-- 이동 방식이 바뀐 시각 (iOS 동작 기록 CMMotionActivity). 다음 행 ts 까지 이 방식.
CREATE TABLE IF NOT EXISTS day_act (
  ts   DATETIME(3) NOT NULL COMMENT 'UTC, 이 방식 시작',
  act  VARCHAR(10) NOT NULL COMMENT 'stationary|walk|run|bike|car|unknown',
  conf TINYINT NOT NULL DEFAULT 0 COMMENT '0 낮음 1 중간 2 높음',
  PRIMARY KEY (ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='하루 종일 기록 이동 방식';

-- 1분 걸음 (iOS 만보계 CMPedometer). 0 걸음 분도 올림 → 행이 있으면 그 분은 측정됨.
CREATE TABLE IF NOT EXISTS day_step (
  ts     DATETIME NOT NULL COMMENT 'UTC, 분 시작',
  steps  SMALLINT UNSIGNED NOT NULL,
  dist_m FLOAT NULL,
  PRIMARY KEY (ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='하루 종일 기록 걸음';

-- 데일리요섭 변경 감지용 (REPLACE 하면 다시 찍힘)
-- ALTER TABLE day_visit ADD COLUMN updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;
