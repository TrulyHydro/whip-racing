-- Per-racer settings, and the alias they race under.
--
-- The alias is resolved at read time rather than copied into `whip_racing_records`, so
-- changing it renames somebody everywhere at once -- profile, standings, track
-- leaderboards, the lobby list -- including on times they set years ago. The
-- name stored alongside a record stays as the fallback for anyone who never
-- picked an alias.

Profiles = { cache = {}, available = false }

--- Everything is kept in memory: it is a row per racer, read on nearly every
--- screen and written once in a while.
---
--- A missing table must not throw here. This runs at resource start, in front
--- of the track load, and an error at this point takes the rest of startup
--- with it -- which surfaces as an empty track list rather than as anything
--- pointing at the real problem. Missing tables degrade to "no aliases" and
--- say so.
function Profiles.LoadAll()
    Profiles.cache = {}

    local ok, rows = pcall(MySQL.query.await,
        'SELECT `citizenid`, `nickname`, `settings` FROM `whip_racing_profiles`')

    if not ok then
        Profiles.available = false
        print('[whip-racing] whip_racing_profiles is missing -- run sql/install.sql')
        print('[whip-racing] racing aliases and daily rewards are off until it exists')
        return 0
    end

    Profiles.available = true

    for _, row in ipairs(rows or {}) do
        Profiles.cache[row.citizenid] = {
            nickname = row.nickname,
            settings = row.settings and json.decode(row.settings) or {},
        }
    end

    return #(rows or {})
end

function Profiles.Get(citizenid)
    return citizenid and Profiles.cache[citizenid] or nil
end

--- The name to show for a racer: their alias if they picked one, otherwise
--- whatever name was recorded with them.
function Profiles.DisplayName(citizenid, fallback)
    local profile = Profiles.Get(citizenid)
    return (profile and profile.nickname) or fallback or 'Unknown'
end

-- ------------------------------------------------------------------ Aliases

local MIN_LENGTH = 3
local MAX_LENGTH = 24

--- Anything that would make one racer unreadable as another, or unreadable
--- full stop. "Anon-" is reserved: the interface uses that prefix to mean a
--- racer who is hiding, and a chosen name must not be able to imitate it.
local function validate(nickname)
    nickname = tostring(nickname or ''):gsub('^%s+', ''):gsub('%s+$', '')

    -- Clearing it is allowed, and means "go back to my character name".
    if nickname == '' then return true, nil end

    if #nickname < MIN_LENGTH then
        return false, nil, ('Pick something at least %d characters long.'):format(MIN_LENGTH)
    end

    if #nickname > MAX_LENGTH then
        return false, nil, ('Keep it to %d characters or fewer.'):format(MAX_LENGTH)
    end

    if nickname:lower():find('anon-', 1, true) then
        return false, nil, 'Names cannot contain "Anon-".'
    end

    if not nickname:find('^[%w%s._-]+$') then
        return false, nil, 'Letters, numbers, spaces, dots, dashes and underscores only.'
    end

    return true, nickname
end

--- Case-insensitive, so two racers cannot be told apart only by capitals.
local function takenBy(nickname)
    if not nickname then return nil end

    for citizenid, profile in pairs(Profiles.cache) do
        if profile.nickname and profile.nickname:lower() == nickname:lower() then
            return citizenid
        end
    end

    return nil
end

--- Stores the whole settings object and, when it carries one, the alias.
--- Returns false plus a reason the player can act on.
function Profiles.Save(citizenid, incoming)
    if not citizenid then return false, 'You are not signed in.' end
    if not Profiles.available then return false, 'Racing profiles are not set up on this server.' end

    local ok, nickname, reason = validate(incoming and incoming.nickname)
    if not ok then return false, reason end

    local owner = takenBy(nickname)
    if owner and owner ~= citizenid then
        return false, 'Somebody already races under that name.'
    end

    -- The alias lives in its own column; everything else is stored whole and
    -- handed back untouched, so a toggle added to the interface later needs no
    -- change here.
    local settings = {}
    for key, value in pairs(incoming or {}) do
        if key ~= 'nickname' then settings[key] = value end
    end

    MySQL.query.await([[
        INSERT INTO `whip_racing_profiles` (`citizenid`, `nickname`, `settings`)
        VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE `nickname` = VALUES(`nickname`), `settings` = VALUES(`settings`)
    ]], { citizenid, nickname, json.encode(settings) })

    Profiles.cache[citizenid] = { nickname = nickname, settings = settings }

    return true
end

-- ---------------------------------------------------------------- Callbacks

--- What the settings screen fills its fields from. The alias is folded back in
--- so the interface sees one object, the same shape it posts back.
lib.callback.register('whip-racing:getSettings', function(source)
    local player = Bridge.GetPlayer(source)
    local profile = player and Profiles.Get(player.citizenid)

    local settings = {}
    for key, value in pairs(profile and profile.settings or {}) do
        settings[key] = value
    end

    settings.nickname = (profile and profile.nickname) or ''

    return settings
end)

lib.callback.register('whip-racing:saveSettings', function(source, settings)
    local player = Bridge.GetPlayer(source)
    if not player then return false, 'You are not signed in.' end

    return Profiles.Save(player.citizenid, settings)
end)

-- Once the tables exist (server/whip.lua on WHIP; at resource start otherwise).
Bridge.OnReady(function()
    local count = Profiles.LoadAll()
    print(('[whip-racing] %d racer profile(s) loaded'):format(count))
end)

-- ---------------------------------------------------------------- Daily case
--
-- Finish races, open cases. Progress resets at midnight in the configured
-- timezone.
--
-- The reset is not a scheduled job: each row records which day it belongs to,
-- and a row from an earlier day is simply treated as empty the next time it is
-- read. Nothing has to be running at midnight for the day to turn over, and a
-- server that was offline overnight is already correct when it comes back.

Daily = {}

local DAY_SECONDS = 24 * 60 * 60

--- Whether a UTC timestamp falls inside US daylight saving: from 2am on the
--- second Sunday in March to 2am on the first Sunday in November.
---
--- Worked out from the date rather than read from a timezone database, because
--- Lua here has none. The rule has held since 2007.
local function inUsDst(utc)
    local parts = os.date('!*t', utc)
    local month, day, weekday = parts.month, parts.day, parts.wday - 1

    if month < 3 or month > 11 then return false end
    if month > 3 and month < 11 then return true end

    -- The Sunday this date belongs to, as a day of the month. Negative before
    -- the first Sunday of the month, which is fine: both comparisons still
    -- read the right way.
    local previousSunday = day - weekday

    if month == 3 then return previousSunday >= 8 end
    return previousSunday <= 0
end

--- Seconds to add to UTC to land in the reset timezone.
local function offsetSeconds(utc)
    local hours = Config.DailyRewards.utcOffset or 0

    if Config.DailyRewards.followUsDst and inUsDst(utc) then
        hours = hours + 1
    end

    return math.floor(hours * 3600)
end

--- Which day a UTC timestamp belongs to, counted in the reset timezone. Two
--- timestamps share a number exactly when they fall on the same local day.
local function dayNumber(utc)
    return math.floor((utc + offsetSeconds(utc)) / DAY_SECONDS)
end

--- When the current day ends, in milliseconds -- what the countdown on the
--- home screen ticks down to.
local function endOfDay(utc)
    local offset = offsetSeconds(utc)
    local nextMidnight = (dayNumber(utc) + 1) * DAY_SECONDS - offset

    return nextMidnight * 1000
end

--- This racer's progress for today. A row from a previous day reads as a fresh
--- one, so the reset costs nothing and cannot be missed.
function Daily.Progress(citizenid)
    local today = dayNumber(os.time())

    -- Same reasoning as Profiles.LoadAll: a missing table reads as "nothing
    -- done today" rather than throwing out of whichever screen asked.
    local ok, row = pcall(MySQL.single.await,
        'SELECT `day`, `races`, `redeemed` FROM `whip_racing_daily` WHERE `citizenid` = ?',
        { citizenid })

    if not ok then
        if Daily.available ~= false then
            Daily.available = false
            print('[whip-racing] whip_racing_daily is missing -- run sql/install.sql')
        end

        return { day = today, races = 0, redeemed = {}, unavailable = true }
    end

    Daily.available = true

    if not row or tonumber(row.day) ~= today then
        return { day = today, races = 0, redeemed = {} }
    end

    local redeemed = {}
    for value in tostring(row.redeemed or ''):gmatch('%d+') do
        redeemed[tonumber(value)] = true
    end

    return { day = today, races = tonumber(row.races) or 0, redeemed = redeemed }
end

--- Nothing to write when the table is not there; Daily.Progress has already
--- said so once.
local function store(citizenid, progress)
    if progress.unavailable then return end

    local claimed = {}
    for _, tier in ipairs(Config.DailyRewards.tiers) do
        if progress.redeemed[tier.races] then claimed[#claimed + 1] = tostring(tier.races) end
    end

    MySQL.query.await([[
        INSERT INTO `whip_racing_daily` (`citizenid`, `day`, `races`, `redeemed`)
        VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE `day` = VALUES(`day`), `races` = VALUES(`races`),
            `redeemed` = VALUES(`redeemed`)
    ]], { citizenid, progress.day, progress.races, table.concat(claimed, ',') })
end

--- Counts one finish. Called when a racer crosses the line, not when they join
--- a lobby, so sitting on a grid all day earns nothing.
function Daily.CountFinish(citizenid)
    if not Config.DailyRewards.enabled or not citizenid then return end

    local progress = Daily.Progress(citizenid)
    progress.races = progress.races + 1
    store(citizenid, progress)
end

--- The shape the home screen expects. `maxRaces` scales the progress bar, so
--- it is the last tier rather than a separate setting.
function Daily.View(citizenid)
    if not Config.DailyRewards.enabled then return nil end
    if Daily.available == false then return nil end

    local tiers = Config.DailyRewards.tiers
    if #tiers == 0 then return nil end

    local progress = citizenid and Daily.Progress(citizenid)
        or { races = 0, redeemed = {} }

    local rewards = {}
    for index, tier in ipairs(tiers) do
        rewards[index] = {
            racesRequired = tier.races,
            type = tier.type,
            redeemed = progress.redeemed[tier.races] and true or false,
            cash = tier.cash,
        }
    end

    return {
        races = progress.races,
        maxRaces = tiers[#tiers].races,
        endTimestamp = endOfDay(os.time()),
        rewards = rewards,
    }
end

lib.callback.register('whip-racing:getDaily', function(source)
    local player = Bridge.GetPlayer(source)
    return Daily.View(player and player.citizenid)
end)

--- Pays out every tier reached and not yet claimed. One press takes all of
--- them, which is what the single Redeem button implies.
---
--- A tier is only marked claimed once its reward is actually in hand. Cases do
--- not stack, so each one needs a free slot, and a full inventory is the
--- normal way this fails -- marking it claimed anyway would quietly destroy
--- the reward. An unclaimed tier stays on the strip and can be taken later,
--- which is the failure worth having.
lib.callback.register('whip-racing:redeemDaily', function(source)
    if not Config.DailyRewards.enabled then return false, nil, 'Daily rewards are switched off.' end

    local player = Bridge.GetPlayer(source)
    if not player then return false, nil, 'You are not signed in.' end

    local progress = Daily.Progress(player.citizenid)
    if progress.unavailable then return false, nil, 'Daily rewards are not set up on this server.' end

    -- Validate before giving any items so unsupported cash tiers cannot interrupt a claim.
    if not Bridge.hasEconomy then
        for _, tier in ipairs(Config.DailyRewards.tiers) do
            if progress.races >= tier.races and not progress.redeemed[tier.races]
                and tier.cash and tier.cash > 0 then
                return false, nil, 'Cash daily rewards are unavailable in standalone mode.'
            end
        end
    end

    local reached, claimed, cases, cash, full = 0, 0, 0, 0, false

    for _, tier in ipairs(Config.DailyRewards.tiers) do
        if progress.races >= tier.races and not progress.redeemed[tier.races] then
            reached = reached + 1

            local count = tier.count or 1
            local given = true

            if tier.item then
                given = Bridge.GiveItem(source, tier.item, count)
                if given then cases = cases + count else full = true end
            end

            -- Cash only follows an item that actually landed, so a tier is
            -- never half paid.
            if given then
                if tier.cash and tier.cash > 0 then
                    player.addMoney(Config.MoneyAccount, tier.cash, 'Racing daily reward')
                    cash = cash + tier.cash
                end

                progress.redeemed[tier.races] = true
                claimed = claimed + 1
            end
        end
    end

    if reached == 0 then
        return false, nil, 'Finish more races first.'
    end

    if claimed == 0 then
        return false, nil, 'No room in your inventory.'
    end

    store(player.citizenid, progress)

    local parts = {}
    if cases > 0 then
        parts[#parts + 1] = ('%d case%s'):format(cases, cases == 1 and '' or 's')
    end
    if cash > 0 then
        parts[#parts + 1] = ('$%d'):format(cash)
    end

    Bridge.Notify(source, ('Daily reward: %s'):format(table.concat(parts, ' and ')), 'success')

    if full then
        Bridge.Notify(source, 'Some rewards were left -- free up a slot and redeem again.', 'inform')
    end

    -- The interface replaces its reward list with whatever comes back, so it
    -- gets the freshly stored one rather than being told to refetch.
    return true, Daily.View(player.citizenid).rewards
end)
