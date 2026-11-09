CREATE TABLE IF NOT EXISTS auto_place (
  venue_id VARCHAR(40) NOT NULL PRIMARY KEY COMMENT '포스퀘어 venueId',
  name     VARCHAR(100) NOT NULL,
  lat      DOUBLE NOT NULL COMMENT '감시 중심(실제 머무는 곳)',
  lon      DOUBLE NOT NULL,
  radius   INT NOT NULL DEFAULT 100 COMMENT 'm',
  enabled  TINYINT NOT NULL DEFAULT 1
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='자동 체크인 장소';
CREATE TABLE IF NOT EXISTS place_event (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  client_id   VARCHAR(64) NOT NULL UNIQUE,
  venue_id    VARCHAR(40) NOT NULL,
  kind        VARCHAR(8) NOT NULL COMMENT 'enter|exit',
  at          DATETIME(3) NOT NULL COMMENT 'UTC, 기기가 감지한 시각',
  lat DOUBLE NULL, lon DOUBLE NULL, acc DOUBLE NULL,
  received_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT 'UTC',
  status      VARCHAR(10) NOT NULL DEFAULT 'pending' COMMENT 'pending|confirmed|ignored|sent|failed',
  note        VARCHAR(255) NULL,
  fsq_id      VARCHAR(40) NULL,
  resolved_at DATETIME(3) NULL,
  KEY (venue_id, at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='자동 체크인 진입·이탈';
