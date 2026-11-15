Records = {}

--- Top times for a track, fastest first. Names are resolved through the alias
--- on the way out, so a racer who renames themselves is renamed on every time
--- they have ever set rather than only on new ones.
function Records.List(trackId, limit)
    local rows = MySQL.query.await([[
        SELECT id, citizenid, name, model, time_ms, best_lap_ms, laps, created_at
        FROM `whip_racing_records`
        WHERE track_id = ?
        ORDER BY time_ms ASC
        LIMIT ?
    ]], { trackId, limit or 10 }) or {}

    for _, row in ipairs(rows) do
        row.name = Profiles.DisplayName(row.citizenid, row.name)
    end

    return rows
end

--- The single fastest run, including its ghost samples and split times.
function Records.Best(trackId, laps)
    local row = MySQL.single.await([[
        SELECT * FROM `whip_racing_records`
        WHERE track_id = ? AND laps = ?
        ORDER BY time_ms ASC LIMIT 1
    ]], { trackId, laps })

    if not row then return nil end

    return {
        name = Profiles.DisplayName(row.citizenid, row.name),
        model = row.model,
        time = row.time_ms,
        bestLap = row.best_lap_ms,
        splits = row.splits and json.decode(row.splits) or nil,
        ghost = row.ghost and json.decode(row.ghost) or nil,
    }
end

--- Stores a finishing time. Only keeps a ghost when the run is a new best,
--- otherwise the table balloons with replays nobody races against.
---
--- `name` is deliberately the character name, not the alias: it is the record
--- of who actually drove, and it is the fallback for anyone who never picked
--- an alias. What gets *shown* is resolved at read time by Profiles, so
--- renaming yourself renames you on every time you have ever set.
function Records.Submit(trackId, laps, player, result)
    local existing = MySQL.single.await([[
        SELECT id, time_ms FROM `whip_racing_records`
        WHERE track_id = ? AND laps = ? AND citizenid = ?
        LIMIT 1
    ]], { trackId, laps, player.citizenid })

    if existing and existing.time_ms <= result.time then
        return false
    end

    local best = MySQL.scalar.await(
        'SELECT MIN(time_ms) FROM `whip_racing_records` WHERE track_id = ? AND laps = ?', { trackId, laps })

    local isTrackRecord = not best or result.time < best
    local ghost = nil

    if Config.Ghost.enabled and isTrackRecord and result.ghost then
        ghost = json.encode(result.ghost)
    end

    if existing then
        MySQL.update.await([[
            UPDATE `whip_racing_records`
            SET time_ms = ?, best_lap_ms = ?, model = ?, splits = ?, ghost = COALESCE(?, ghost), created_at = NOW()
            WHERE id = ?
        ]], { result.time, result.bestLap, result.model, json.encode(result.splits or {}), ghost, existing.id })
    else
        MySQL.insert.await([[
            INSERT INTO `whip_racing_records` (track_id, citizenid, name, model, laps, time_ms, best_lap_ms, splits, ghost)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]], { trackId, player.citizenid, player.name, result.model, laps,
              result.time, result.bestLap, json.encode(result.splits or {}), ghost })
    end

    return isTrackRecord
end

lib.callback.register('whip-racing:getRecords', function(_, trackId)
    return Records.List(trackId, 15)
end)

--- Everything the tablet's track screen shows: the headline times plus the
--- standings. `personalBest` is the caller's own row, so it is looked up
--- against them rather than being pulled out of the standings.
lib.callback.register('whip-racing:getTrackStats', function(source, trackId)
    trackId = tonumber(trackId)
    if not trackId then return nil end

    local player = Bridge.GetPlayer(source)
    local stateId = player and player.citizenid

    local totals = MySQL.single.await([[
        SELECT COUNT(*) AS totalRaces, COALESCE(AVG(time_ms), 0) AS avgTime,
               COALESCE(MIN(time_ms), 0) AS bestTime
        FROM `whip_racing_records` WHERE `track_id` = ?
    ]], { trackId }) or {}

    local personal = stateId and MySQL.scalar.await([[
        SELECT MIN(time_ms) FROM `whip_racing_records` WHERE `track_id` = ? AND `citizenid` = ?
    ]], { trackId, stateId })

    return {
        totalRaces = tonumber(totals.totalRaces) or 0,
        avgTime = math.floor(tonumber(totals.avgTime) or 0),
        bestTime = tonumber(totals.bestTime) or 0,
        personalBest = tonumber(personal) or 0,
        leaderboard = Records.List(trackId, 15),
    }
end)

-- ------------------------------------------------------------------ History
--
-- The log of races that have actually happened. whip_racing_records keeps a racer's
-- best time per track and overwrites itself, so it can never say where somebody
-- finished or how many times they raced -- this can.
--
-- Written once as the results are worked out, then only read.

History = { available = true }

--- Stores a finished race and everybody in it. Returns the race id, which is
--- what the tablet uses to link back to the result, or nil if it could not be
--- written -- callers carry on either way, since failing to log a race must not
--- stop it paying out.
function History.Record(lobby, rows)
    if not History.available then return nil end

    local track = Tracks.Get(lobby.trackId)

    local ok, raceId = pcall(MySQL.insert.await, [[
        INSERT INTO `whip_racing_races` (`track_id`, `track_name`, `laps`, `pot`, `ranked`)
        VALUES (?, ?, ?, ?, ?)
    ]], { lobby.trackId, track and track.name or 'Unknown', lobby.laps, lobby.pot,
          lobby.ranked and 1 or 0 })

    if not ok or not raceId then
        History.available = false
        print('[whip-racing] could not write race history -- run sql/install.sql')
        print('[whip-racing] recent races will stay empty until whip_racing_races exists')
        return nil
    end

    for _, row in ipairs(rows) do
        if row.citizenid then
            pcall(MySQL.insert.await, [[
                INSERT INTO `whip_racing_race_results`
                    (`race_id`, `citizenid`, `name`, `position`, `time_ms`, `best_lap_ms`, `model`, `payout`)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ]], { raceId, row.citizenid, row.name, row.place, row.time, row.bestLap,
                  row.model, row.payout or 0 })
        end
    end

    return raceId
end

--- A racer's own recent races, newest first: what they drove, where they came,
--- and how the field was sized.
lib.callback.register('whip-racing:getRecentRaces', function(source, stateId, limit)
    local player = Bridge.GetPlayer(source)
    stateId = stateId or (player and player.citizenid)
    if not stateId then return {} end

    limit = math.max(1, math.min(50, math.floor(tonumber(limit) or 10)))

    local ok, rows = pcall(MySQL.query.await, [[
        SELECT r.`id` AS raceId, r.`track_name` AS trackName, r.`laps`,
               r.`finished_at` AS finishedAt,
               e.`position`, e.`time_ms` AS time, e.`best_lap_ms` AS bestLap,
               e.`model`, e.`payout`,
               (SELECT COUNT(*) FROM `whip_racing_race_results` WHERE `race_id` = r.`id`) AS racers
        FROM `whip_racing_race_results` e
        JOIN `whip_racing_races` r ON r.`id` = e.`race_id`
        WHERE e.`citizenid` = ?
        ORDER BY r.`finished_at` DESC
        LIMIT ?
    ]], { stateId, limit })

    return ok and rows or {}
end)

--- Everyone in one race, in finishing order. This is what the results screen
--- used to show as a popup over the game.
lib.callback.register('whip-racing:getRaceResults', function(_, raceId)
    raceId = tonumber(raceId)
    if not raceId then return nil end

    local ok, race = pcall(MySQL.single.await,
        'SELECT * FROM `whip_racing_races` WHERE `id` = ?', { raceId })

    if not ok or not race then return nil end

    local rowsOk, rows = pcall(MySQL.query.await, [[
        SELECT `citizenid`, `name`, `position`, `time_ms` AS time,
               `best_lap_ms` AS bestLap, `model`, `payout`
        FROM `whip_racing_race_results`
        WHERE `race_id` = ?
        ORDER BY `position` IS NULL, `position` ASC
    ]], { raceId })

    if not rowsOk then return nil end

    for _, row in ipairs(rows or {}) do
        row.name = Profiles.DisplayName(row.citizenid, row.name)
    end

    return {
        id = race.id,
        trackId = race.track_id,
        trackName = race.track_name,
        laps = race.laps,
        pot = race.pot,
        ranked = race.ranked == 1 or race.ranked == true,
        finishedAt = race.finished_at,
        rows = rows or {},
    }
end)
