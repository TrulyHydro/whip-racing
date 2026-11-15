-- ============================================
-- WHIP setup: tables, the reward item, the admin permission.
--
-- No sql/install.sql to import on WHIP: the tables are made here (CREATE ... IF NOT EXISTS, so
-- existing rows are kept). Once they exist, Bridge.MarkReady lets tracks and profiles load.
-- ============================================

if Bridge.framework ~= 'whip' then return end

local TABLES = {
    { 'whip_racing_tracks', [[
        CREATE TABLE IF NOT EXISTS `whip_racing_tracks` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `name` VARCHAR(64) NOT NULL,
            `creatorStateId` VARCHAR(64) DEFAULT NULL,
            `checkpoints` LONGTEXT NOT NULL,
            `props` LONGTEXT DEFAULT NULL,
            `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            `isPublished` TINYINT(1) NOT NULL DEFAULT 0,
            `isDeleted` TINYINT(1) NOT NULL DEFAULT 0,
            `isOfficial` TINYINT(1) NOT NULL DEFAULT 0,
            `isVerified` TINYINT(1) NOT NULL DEFAULT 0,
            `isFeatured` TINYINT(1) NOT NULL DEFAULT 0,
            `isSprint` TINYINT(1) NOT NULL DEFAULT 1,
            PRIMARY KEY (`id`),
            KEY `creatorStateId` (`creatorStateId`),
            KEY `browse` (`isDeleted`, `isPublished`, `isFeatured`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { 'whip_racing_records', [[
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
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { 'whip_racing_profiles', [[
        CREATE TABLE IF NOT EXISTS `whip_racing_profiles` (
            `citizenid` VARCHAR(64) NOT NULL,
            `nickname` VARCHAR(32) DEFAULT NULL,
            `settings` LONGTEXT DEFAULT NULL,
            `updatedAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`citizenid`),
            UNIQUE KEY `nickname` (`nickname`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { 'whip_racing_daily', [[
        CREATE TABLE IF NOT EXISTS `whip_racing_daily` (
            `citizenid` VARCHAR(64) NOT NULL,
            `day` INT NOT NULL DEFAULT 0,
            `races` INT NOT NULL DEFAULT 0,
            `redeemed` VARCHAR(64) NOT NULL DEFAULT '',
            PRIMARY KEY (`citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { 'whip_racing_races', [[
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
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    { 'whip_racing_race_results', [[
        CREATE TABLE IF NOT EXISTS `whip_racing_race_results` (
            `race_id` INT NOT NULL,
            `citizenid` VARCHAR(64) NOT NULL,
            `name` VARCHAR(64) NOT NULL,
            `position` INT DEFAULT NULL,
            `time_ms` INT DEFAULT NULL,
            `best_lap_ms` INT DEFAULT NULL,
            `model` VARCHAR(64) DEFAULT NULL,
            `payout` INT NOT NULL DEFAULT 0,
            PRIMARY KEY (`race_id`, `citizenid`),
            KEY `player` (`citizenid`, `race_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
}

--- WHIP's EnsureTable takes letters, digits and _ only (every whip_racing_ table now qualifies).
--- EnsureTable for a name it accepts, else the same
--- CREATE TABLE IF NOT EXISTS straight through oxmysql (never asking WHIP, which would print a refusal).
local function ensureTable(name, sql)
    if name:match('^[%w_]+$') and #name <= 64 then
        local ok, why = Whip.core:EnsureTable(name, sql)
        if ok then return true end
        Whip.startProblem('could not create table %s: %s', name, tostring(why))
        return false
    end
    local done, err = pcall(MySQL.query.await, sql)
    if done then return true end
    Whip.startProblem('could not create table %s: %s', name, tostring(err))
    return false
end

-- The resource was hydro-racing, with tables `hydro-racing_*`. Each old table that still exists is
-- renamed to its whip_racing_ name, so tracks, records, profiles and crews carry over. An empty new
-- table in the way (server/crews.lua may make whip_racing_crews first) is dropped; a new table with
-- rows is never touched, and the old one is then left as it is.
local OLD_NAMES = { 'tracks', 'records', 'profiles', 'daily', 'races', 'race_results', 'crews' }

local function tableExists(name)
    local n = MySQL.scalar.await(
        'SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?', { name })
    return (tonumber(n) or 0) > 0
end

local function carryOldTables()
    for _, short in ipairs(OLD_NAMES) do
        local old, new = 'hydro-racing_' .. short, 'whip_racing_' .. short
        local ok, err = pcall(function()
            if not tableExists(old) then return end
            if tableExists(new) then
                local rows = tonumber(MySQL.scalar.await(('SELECT COUNT(*) FROM `%s`'):format(new))) or 0
                if rows > 0 then
                    print(('[whip-racing] both %s and %s have rows: kept %s, left %s alone'):format(old, new, new, old))
                    return
                end
                MySQL.query.await(('DROP TABLE `%s`'):format(new))
            end
            MySQL.query.await(('RENAME TABLE `%s` TO `%s`'):format(old, new))
            print(('[whip-racing] carried %s over as %s'):format(old, new))
        end)
        if not ok then Whip.startProblem('could not carry %s over: %s', old, tostring(err)) end
    end
end

local carried = false

Whip.register(function()
    if not carried then carried = true; carryOldTables() end
    for _, t in ipairs(TABLES) do ensureTable(t[1], t[2]) end

    -- The daily reward. (Unprefixed so Config.DailyRewards keeps working; the console notes it once.)
    Whip.core:RegisterItem('racing_case', {
        name     = 'Racing Case',
        desc     = 'A daily racing reward.',
        weight   = 1.5,
        type     = 'misc',
        stack    = false,
        image    = 'racing_case.png',
    })

    -- Who runs the tablet's admin section, besides Config.Admins and the whipracing.admin ACE.
    -- Give it in /whip → Player Manager → the player → Permissions. Full admins already hold it.
    Whip.core:RegisterPermission('whip-racing.admin', { label = 'Racing admin' })

    Bridge.MarkReady()
end)

Whip.sayStarted()
