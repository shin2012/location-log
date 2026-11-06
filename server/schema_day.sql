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
  PRIMARY KEY (arrive)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='하루 종일 기록 머문 곳';
