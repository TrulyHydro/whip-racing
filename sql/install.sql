-- ---------------------------------------------------------------------------
--  whip-racing schema
-- ---------------------------------------------------------------------------
--  DESTRUCTIVE: this drops any existing whip_racing_tracks. The column set changed
--  shape (snake_case -> camelCase, `data` -> `checkpoints`, `circuit` ->
--  `isSprint`, plus the is* flags), so CREATE IF NOT EXISTS alone would leave
--  an old table in place and every query would fail against it.
--
--  whip_racing_records is truncated for the same reason: track ids restart from 1, so
--  old rows would silently re-attach themselves to whichever new track happens
--  to claim their track_id and poison the leaderboards.
-- ---------------------------------------------------------------------------

DROP TABLE IF EXISTS `whip_racing_tracks`;

CREATE TABLE `whip_racing_tracks` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `name` VARCHAR(64) NOT NULL,
    `creatorStateId` VARCHAR(64) DEFAULT NULL,
    -- JSON array of { x, y, z, heading, radius }
    `checkpoints` LONGTEXT NOT NULL,
    -- JSON array of props placed along the route: { model, x, y, z, heading }
    `props` LONGTEXT DEFAULT NULL,
    `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    `isPublished` TINYINT(1) NOT NULL DEFAULT 0,
    `isDeleted` TINYINT(1) NOT NULL DEFAULT 0,
    `isOfficial` TINYINT(1) NOT NULL DEFAULT 0,
    `isVerified` TINYINT(1) NOT NULL DEFAULT 0,
    `isFeatured` TINYINT(1) NOT NULL DEFAULT 0,
    -- 1 = point to point, 0 = circuit. Lap count is a per-race lobby setting.
    `isSprint` TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (`id`),
    KEY `creatorStateId` (`creatorStateId`),
    KEY `browse` (`isDeleted`, `isPublished`, `isFeatured`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `whip_racing_records` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `track_id` INT NOT NULL,
    `citizenid` VARCHAR(64) NOT NULL,
    `name` VARCHAR(64) NOT NULL,
    `model` VARCHAR(64) DEFAULT NULL,
    `laps` INT NOT NULL DEFAULT 1,
    `time_ms` INT NOT NULL,
    `best_lap_ms` INT DEFAULT NULL,
    `splits` LONGTEXT DEFAULT NULL,
    `ghost` LONGTEXT DEFAULT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `entry` (`track_id`, `laps`, `citizenid`),
    KEY `leaderboard` (`track_id`, `laps`, `time_ms`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

TRUNCATE TABLE `whip_racing_records`;

-- ---------------------------------------------------------------------------
--  Per-racer settings, and the alias they race under.
--
--  Not destructive: this is additive, and an existing table keeps its rows.
--  `nickname` is what every screen shows instead of the character name, and it
--  is resolved at read time rather than copied into `whip_racing_records` -- so changing
--  it renames a racer everywhere at once, including on times already set.
--  NULL means "use the character name".
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `whip_racing_profiles` (
    `citizenid` VARCHAR(64) NOT NULL,
    `nickname` VARCHAR(32) DEFAULT NULL,
    -- JSON blob of the tablet's settings toggles, stored whole.
    `settings` LONGTEXT DEFAULT NULL,
    `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`citizenid`),
    -- One racer per alias: a leaderboard with two of the same name is worse
    -- than telling somebody their pick is taken.
    UNIQUE KEY `nickname` (`nickname`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
--  Daily reward progress. One row per racer, rewritten as the day rolls over.
--
--  `day` is days since the epoch measured in the reset timezone, so comparing
--  it to today's number is the whole "has it reset?" check -- no timestamps to
--  compare and no job to run at midnight.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `whip_racing_daily` (
    `citizenid` VARCHAR(64) NOT NULL,
    `day` INT NOT NULL DEFAULT 0,
    `races` INT NOT NULL DEFAULT 0,
    -- Comma-separated race counts already claimed, e.g. "2,5".
    `redeemed` VARCHAR(64) NOT NULL DEFAULT '',
    PRIMARY KEY (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
--  Race history: one row per race, and one per racer in it.
--
--  Separate from `whip_racing_records` on purpose. That table keeps a racer's *best* time
--  per track and overwrites itself, so it can never answer "where did I come
--  last Tuesday" -- it has no placings and no repeats. This is the log: every
--  race, every finisher, in the order they crossed.
--
--  `whip_racing_races.id` is what the tablet links a result to, so it has to outlive
--  the in-memory lobby id, which restarts with the server.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `whip_racing_races` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `track_id` INT DEFAULT NULL,
    `track_name` VARCHAR(64) NOT NULL DEFAULT 'Unknown',
    `laps` INT NOT NULL DEFAULT 1,
    `pot` INT NOT NULL DEFAULT 0,
    `ranked` TINYINT(1) NOT NULL DEFAULT 0,
    `finished_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `recent` (`finished_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `whip_racing_race_results` (
    `race_id` INT NOT NULL,
    `citizenid` VARCHAR(64) NOT NULL,
    `name` VARCHAR(64) NOT NULL,
    -- NULL means they did not finish.
    `position` INT DEFAULT NULL,
    `time_ms` INT DEFAULT NULL,
    `best_lap_ms` INT DEFAULT NULL,
    `model` VARCHAR(64) DEFAULT NULL,
    `payout` INT NOT NULL DEFAULT 0,
    PRIMARY KEY (`race_id`, `citizenid`),
    KEY `player` (`citizenid`, `race_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
