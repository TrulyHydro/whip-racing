-- The tablet interface, and the callbacks it posts to.
--
-- The page is served from this resource and builds its own request URLs as
-- `https://<owning resource>/<name>`, so every call arrives here as an ordinary
-- NUI callback. Nothing external routes them.
--
-- Traffic runs one way in each direction:
--   * out -- the interface POSTs a callback name with a JSON body
--   * in  -- { event = 'sendAppEvent', app = <module>, action = <action>,
--             payload = ... } dispatches into its store; Tablet.Dispatch wraps it
--
-- Response shapes follow the interface's own fixtures. Where this resource has
-- no equivalent -- crews, seasons, tournaments, rewards -- the callback answers
-- empty, so those screens render as "nothing here" rather than hanging on a
-- request that never resolves.

Tablet = { open = false, identity = nil }

--- lib.callback.await raises when the far side has not registered the name --
--- which is what happens when a server file has been added and the resource
--- was restarted but never refreshed. Opening the tablet asks for several
--- things, and one of them going missing must not stop the app mounting: the
--- last thing Tablet.Open does is what makes it render at all.
---
--- So failures are logged with the name that failed and stepped over. A screen
--- missing its data reads as empty; a tablet that never mounts reads as broken.
local function ask(name, ...)
    local ok, result = pcall(lib.callback.await, name, false, ...)

    if ok then return result end

    print(('[whip-racing] %s is unavailable (%s)'):format(name, result))
    print('[whip-racing] if you just added a server file, run `refresh` before `restart`')

    return nil
end

--- The player's own state id and name, asked for once and kept. Nearly every
--- screen keys off this: whether you own a race, whether you are in it, which
--- row on a leaderboard is yours. A placeholder here reads as "you are nobody"
--- and quietly hides the host's own Start Race button.
function Tablet.Identity()
    if not Tablet.identity then
        Tablet.identity = ask('whip-racing:getIdentity')
    end

    return Tablet.identity or { stateId = '0', name = GetPlayerName(PlayerId()) }
end

function Tablet.Dispatch(app, action, payload)
    SendNUIMessage({ event = 'sendAppEvent', app = app, action = action, payload = payload })
end

--- Opens a screen inside the tablet. Its own app events only reach the store,
--- never the router, so this is handled by the shim in web/tablet/index.html.
function Tablet.Navigate(path)
    SendNUIMessage({ event = 'navigate', path = path })
end

function Tablet.Open()
    if Tablet.open then return end

    Tablet.open = true
    UI.Send('tablet', { open = true })
    SetNuiFocus(true, true)

    local identity = Tablet.Identity()

    Tablet.Dispatch('racing', 'setCrewCreateMoney', Config.CrewCreateMoney or 5000)
    Tablet.Dispatch('racing', 'setUserCrew', ask('whip-racing:getUserCrew') or false)

    Tablet.Dispatch('root', 'setPlayerData', {
        stateId = identity.stateId,
        name = identity.name,
    })

    -- Pushed rather than fetched: none of these have a loader behind them.
    Tablet.Dispatch('racing', 'setAvailableSeasons', Tablet.Seasons())
    Tablet.Dispatch('racing', 'setCanCreateTracks', true)

    -- The settings screen copies this into its fields on mount. Without it
    -- every field opens blank, so an alias already set looks like no alias.
    Tablet.Dispatch('racing', 'setSettings', ask('whip-racing:getSettings') or EMPTY)

    -- Shows the admin tab in the nav rail. The server decides who gets it, and
    -- decides again on every action it offers.
    Tablet.Dispatch('racing', 'setAdminMode', identity.isAdmin and true or false)

    -- Shows the second "Create Ranked" button in the race creator. Without it
    -- the creator can only ever make an unranked race.
    Tablet.Dispatch('racing', 'setRankedAllowlist', identity.canRank and true or false)

    -- Without this the ghost field is a fixed line of text rather than a
    -- dropdown, which is why it read "120 sec" and could not be changed.
    Tablet.Dispatch('racing', 'setGhostModeSettings', {
        allowGhostModeInUI = true,
        configGhostMode = Config.DefaultGhostMode,
    })

    Tablet.Dispatch('racing', 'setAvailableCurrencies', {
        { name = 'CASH', label = 'Cash', symbol = '$' },
    })

    -- Whatever lobby this player is already in, so the race screen is right on
    -- arrival rather than a fetch later.
    local menu = ask('whip-racing:getMenu')
    Tablet.PushRace(menu and menu.lobby or nil)

    -- Nothing renders until this lands: it is what opens the app.
    Tablet.Dispatch('racing', 'setVisible', true)
    SendNUIMessage({ event = 'raceActive', active = Race.active and true or false })
end

function Tablet.Close()
    if not Tablet.open then return end
    Tablet.open = false

    Tablet.Dispatch('racing', 'setVisible', false)
    UI.Send('tablet', { open = false })
    SetNuiFocus(false, false)
end

-- ------------------------------------------------------------- Callbacks
-- Every tablet callback below runs protected. If one throws, the tablet would
-- otherwise get an error answer, which its request helper turns into `{}`, and
-- the screen breaks on `.map` / `.filter` / `.length` with nothing to say why.
-- Instead the error (with its traceback) goes to the server console, and the
-- screen gets a harmless empty answer. Callbacks that take over three seconds
-- are reported too.

local FALLBACKS = {
    ['racing:loadHome'] = function()
        return { currentElo = 0, lastRaces = {}, seasonRewards = {}, dailyReward = false,
            hotTracks = {}, popularTracks = {}, newTracks = {}, activeRaces = {} }
    end,
    ['racing:loadProfile'] = function() return false end,
    ['racing:loadRace'] = function() return false end,
    ['racing:loadCurrentTrack'] = function() return false end,
}

local function reportTabletProblem(message)
    print('[whip-racing] ' .. message)
    TriggerServerEvent('whip-racing:tabletError', message:sub(1, 1200))
end

--- A one-line description of an answer: its type, list length or keys. The
--- first answer of each callback is logged to the server console like this,
--- so a screen that misreads its data can be traced to what was sent.
local function shapeOf(value)
    if type(value) ~= 'table' then return type(value) .. '(' .. tostring(value):sub(1, 30) .. ')' end
    local count, keys = #value, {}
    for key, item in pairs(value) do
        if #keys >= 10 then break end
        if type(key) ~= 'number' then keys[#keys + 1] = ('%s:%s'):format(key, type(item) == 'table' and ('table#' .. #item) or type(item)) end
    end
    return ('table list#%d keys{%s}'):format(count, table.concat(keys, ' '))
end

local logged = {}

local registerNUICallback = RegisterNUICallback
local function RegisterNUICallback(name, handler)
    registerNUICallback(name, function(data, cb)
        local answered = false
        local function reply(value)
            if answered then return end
            answered = true
            cb(value)
        end

        local started = GetGameTimer()
        local ok, err = xpcall(handler, debug.traceback, data or {}, reply)
        if not ok then
            reportTabletProblem(('callback %s failed: %s'):format(name, tostring(err)))
            local fallback = FALLBACKS[name]
            reply(fallback and fallback() or {})
        elseif not answered then
            reportTabletProblem(('callback %s returned without answering'):format(name))
            reply({})
        end

        local took = GetGameTimer() - started
        if took > 3000 then reportTabletProblem(('callback %s took %d ms'):format(name, took)) end
    end)
end

-- ------------------------------------------------------------------- Shapes

local EMPTY = {}

--- What to answer when the thing asked for is gone.
---
--- Not EMPTY: an empty Lua table serialises to `[]`, which is *truthy* in
--- JavaScript, so the screen believes it has a race and reads fields off an
--- empty array -- which is where "cannot read properties of undefined" and
--- "cannot convert undefined or null to object" come from. `false` encodes to
--- valid JSON, is falsy, and puts the screen into its own loading state.
local MISSING = false

--- This resource has no seasons: times stand for as long as they stand. The
--- screens still expect one to select, so a single open-ended period covers
--- everything, and nothing ever "ends".
---
--- The header only offers "counting down" or "ended", and neither fits a period
--- that never closes; a rolling year out is the less wrong of the two, and
--- keeps the standings reading as live. Built on each ask rather than once at
--- load: there is no `os` library on the client.
local function season()
    return {
        id = 0,
        name = 'All Time',
        startDate = 0,
        endDate = (GetCloudTimeAsInt() + (365 * 24 * 60 * 60)) * 1000,
        isFinished = false,
        yourPosition = nil,
    }
end

local function seasons()
    return { season() }
end

function Tablet.Seasons() return seasons() end

--- A stored checkpoint in the interface's shape. `w` carries the heading, and
--- `distBetweenProps` the gate width, which is twice our radius.
local function checkpointRows(points, count)
    local rows = {}

    -- A track summary (lists) carries only how many checkpoints there are.
    -- The tablet's lists read nothing but that number, so a placeholder per
    -- checkpoint keeps the count right without sending the coordinates.
    if not points and tonumber(count) then
        for index = 1, tonumber(count) do rows[index] = 0 end
        return rows
    end

    for index, point in ipairs(points or EMPTY) do
        rows[index] = {
            id = index - 1,
            coords = { x = point.x, y = point.y, z = point.z, w = point.heading or 0.0 },
            modelIndex = 0,
            distBetweenProps = (point.radius or Config.Checkpoints.defaultRadius) * 2.0,
        }
    end

    return rows
end

local function trackRow(track)
    return {
        id = track.id,
        name = track.name,
        checkpoints = checkpointRows(track.points, track.checkpoints),
        props = track.props or EMPTY,
        favouriteCount = 0,
        creatorNickname = track.creatorStateId or 'Unknown',
        creatorStateId = track.creatorStateId or '',
        createdAt = track.createdAt or 0,
        updatedAt = track.updatedAt or 0,
        isPublished = track.published and true or false,
        isDeleted = false,
        isOfficial = track.official and true or false,
        isVerified = track.verified and true or false,
        isFeatured = track.featured and true or false,
        isSprint = track.sprint and true or false,
        isFavourite = false,
        -- Same single standing period as the profile uses.
        availableSeasons = seasons(),
        currentSeasonId = 0,
        -- Written into by SET_CURRENT_TRACK_DATA; absent means it throws.
        loadedData = EMPTY,
    }
end

--- The headline times and standings for one track. Ranked and casual are the
--- same figures here: this resource keeps one time per racer per track and
--- draws no distinction between the two.
local function trackData(trackId)
    local stats = lib.callback.await('whip-racing:getTrackStats', false, trackId)
    if not stats then return nil end

    local leaderboard = {}
    for index, row in ipairs(stats.leaderboard or EMPTY) do
        leaderboard[index] = {
            stateId = row.citizenid,
            nickname = row.name,
            crew = nil,
            crewTag = nil,
            position = index,
            time = row.time_ms,
            bestLap = row.best_lap_ms,
            vehicle = row.model,
            elo = 0,
            incognito = false,
            name = row.name,
        }
    end

    return {
        avgTime = stats.avgTime,
        bestTime = stats.bestTime,
        personalBest = stats.personalBest,
        totalRaces = stats.totalRaces,
        leaderboard = leaderboard,
    }
end

--- The ghost dropdown speaks in positions within Config.GhostModes; this
--- resource speaks in ids. The two lists are kept in the same order so the
--- translation is just an index, but it goes through here rather than being
--- assumed at each call site.
--- A host who never opens the dropdown sends nothing, which has to mean the
--- configured default rather than silently meaning "off".
local function ghostModeId(value)
    local entry = Config.GhostModes[tonumber(value) or 0]
        or Config.GhostModes[Config.DefaultGhostMode]
        or Config.GhostModes[1]

    return entry.id
end

local function ghostModeValue(id)
    for index, entry in ipairs(Config.GhostModes) do
        if entry.id == id then return index end
    end

    return 1
end

--- What kind of race this is, in the interface's own words. It used to answer
--- "ranked" for everything, including races created as unranked -- the creator
--- has no ranked option unless one is granted, so that was always a claim
--- rather than a fact.
local function raceModeOf(lobby)
    if lobby.pinkSlip then return 'pink-slip' end
    if lobby.ranked then return 'ranked' end

    return 'unranked'
end

--- Racers in a lobby, keyed by state id: that is how the race screen looks
--- them up, and an array would leave every lookup empty.
local function vehicleLabel(model)
    local hash = tonumber(model) or (model and joaat(model))
    if not hash then return 'Unknown' end
    local display = GetDisplayNameFromVehicleModel(hash)
    local label = GetLabelText(display)
    return label and label ~= 'NULL' and label or (display ~= 'CARNOTFOUND' and display or tostring(model))
end

local function racePlayers(lobby)
    local players = {}
    local host

    for _, entry in ipairs(lobby.players or EMPTY) do
        local stateId = entry.stateId or tostring(entry.source)

        if entry.host then host = stateId end

        players[stateId] = {
            stateId = stateId,
            nickname = entry.name,
            crewTag = nil,
            elo = 0,
            incognito = false,
            anonymousName = nil,
            ready = true,
            vehicle = {
                label = vehicleLabel(entry.model),
                class = entry.vehicleClass or VehicleClasses.Get(entry.model),
                power = nil,
            },
        }
    end

    return players, host
end

--- Reopens the tablet on the track screen, carrying whatever the world editor
--- just laid down.
---
--- The name, the shape and the published flag are the tablet's fields; the
--- checkpoints and props are the editor's. This is the seam between them, and
--- it runs in one direction only, so neither side can overwrite the other's
--- half of the track.
function Tablet.ResumeTrack(handoff)
    Tablet.Open()

    Tablet.Dispatch('racing', 'setEditTrack', {
        id = handoff.id,
        name = handoff.name or '',
        isPublished = handoff.isPublished and true or false,
        isSprint = handoff.isSprint and true or false,
        checkpoints = checkpointRows(handoff.points),
        props = handoff.props or EMPTY,
    })

    Tablet.Navigate('/racing/track/creator')
end

--- Our lobbies as the interface's races. Its statuses are numbers, ours are
--- names, so they are mapped rather than passed through.
local RACE_STATUS = { lobby = 0, countdown = 0, racing = 1, finished = 2 }

local function raceRow(lobby)
    local players, host = racePlayers(lobby)

    return {
        id = lobby.id,
        raceName = lobby.trackName,
        trackId = lobby.trackId,
        trackName = lobby.trackName,
        vehicleClass = lobby.vehicleClasses or {},
        raceMode = raceModeOf(lobby),
        ownerStateId = host or '',
        startTime = 0,
        status = RACE_STATUS[lobby.state] or 0,
        players = players,
        maxPlayers = lobby.maxPlayers or Config.Race.maxPlayers,
        minPlayers = Config.Race.minPlayers,
        maxLaps = lobby.laps or 1,
        maxTimeAfterFirstFinish = Config.Race.finishGraceSeconds,
        season = 0,
        tournament = 0,
        ghostEnabled = ghostModeValue(lobby.ghostMode),
        reverseRoute = false,
        requiredBid = lobby.buyin or 0,
        additionalReward = 0,
        isPrivate = false,
    }
end

--- The lobby this player is in, as the tablet's race screen expects it. Defined
--- down here because it needs raceRow; nothing calls it before load finishes.
function Tablet.PushRace(lobby)
    Tablet.Dispatch('racing', 'setCurrentRace', lobby and raceRow(lobby) or nil)
end

local function lobbyRows()
    local menu = lib.callback.await('whip-racing:getMenu', false) or EMPTY
    local races = {}

    for index, lobby in ipairs(menu.lobbies or EMPTY) do
        races[index] = raceRow(lobby)
    end

    return races
end

-- ---------------------------------------------------------------- Callbacks

--- Only the language code comes back here. The interface then fetches
--- locales/<lang>.json off the resource itself and reads its "ui" object for
--- the wording, so that file has to exist and be listed in fxmanifest.
RegisterNUICallback('getLocale', function(_, cb)
    -- The wording travels with the answer: on GTA V Enhanced the page cannot
    -- fetch locales/<lang>.json itself (web/tablet/index.html explains).
    local lang = Config.Tablet.locale
    local text = LoadResourceFile(GetCurrentResourceName(), ('locales/%s.json'):format(lang))
        or LoadResourceFile(GetCurrentResourceName(), 'locales/en.json')
    local ok, messages = pcall(json.decode, text or '')
    cb({ lang = lang, messages = ok and messages or nil })
end)

RegisterNUICallback('root:close', function(_, cb)
    Tablet.Close()
    cb({})
end)

--- Reported once by the interface as it boots. A wrong resource name still
--- lets the page load -- the locale fetch is caught and swallowed -- and shows
--- up only as untranslated labels, so it is worth saying out loud.
RegisterNUICallback('tablet:diagnostics', function(data, cb)
    if data.localeOk then
        print(('[whip-racing] tablet ready as "%s" (via %s), wording loaded')
            :format(data.resource, data.via))
    else
        print(('[whip-racing] tablet could not read %s -- %s')
            :format(data.localeUrl, data.detail))
        print(('[whip-racing] it resolved this resource as "%s" (via %s) from %s')
            :format(data.resource, data.via, data.href))
        print('[whip-racing] labels will render as raw keys until that file is reachable')
    end

    cb({})
end)

--- An error inside the tablet page, passed on to the server console so it
--- can be read without the player's F8 log (see web/tablet/index.html).
RegisterNUICallback('tablet:error', function(data, cb)
    cb({})
    if type(data) ~= 'table' then return end
    local line = ('[%s] %s %s: %s'):format(tostring(data.kind), tostring(data.route), tostring(data.where), tostring(data.error))
    print('[whip-racing] tablet error ' .. line)
    TriggerServerEvent('whip-racing:tabletError', line:sub(1, 1200))
end)

-- Called once on open; this resource pushes updates rather than being polled.
RegisterNUICallback('racing:subscribe', function(_, cb) cb({}) end)


--- The browser's search, filter and sort all arrive here: it keeps no copy of
--- the list to work on, so a request that ignores them looks like a search box
--- that does nothing.
---
--- It also pages. The list appends whatever comes back and asks for the next
--- page as it is scrolled, stopping once a page comes back empty -- so
--- returning everything every time both breaks the search and duplicates the
--- list on scroll.
local TRACK_FILTERS = {
    isSprint = function(row) return row.isSprint end,
    isLap = function(row) return not row.isSprint end,
    isFeatured = function(row) return row.isFeatured end,
    isOfficial = function(row) return row.isOfficial end,
    isVerified = function(row) return row.isVerified end,
    isFavourite = function(row) return row.isFavourite end,
}

--- "field:asc" / "field:desc", straight from the dropdown's own values. An
--- unknown or default sorting leaves the order the server sent, which already
--- puts featured tracks first.
local function trackSorter(sorting)
    local field, direction = tostring(sorting or ''):match('^(%w+):(%w+)$')
    if not field then return nil end

    local ascending = direction == 'asc'

    return function(a, b)
        local left, right = a[field], b[field]

        -- Ties fall back to id so the order cannot shuffle between pages and
        -- show the same track twice.
        if left == right then return a.id < b.id end
        if left == nil then return false end
        if right == nil then return true end

        if ascending then return left < right end
        return left > right
    end
end

RegisterNUICallback('racing:loadTracks', function(data, cb)
    local tracks = lib.callback.await('whip-racing:getTabletTracks', false) or EMPTY

    -- Race counts cost a query over every stored time and are only read when
    -- sorting by them. The list is searched a keystroke at a time, so this is
    -- worth not asking for.
    local totals = EMPTY
    if tostring(data.sorting or ''):find('raceCount', 1, true) then
        totals = lib.callback.await('whip-racing:getTrackTotals', false) or EMPTY
    end

    -- Matching is case-insensitive and anywhere in the name, so typing part of
    -- a word finds it. `plain` keeps a name containing a dash or a bracket
    -- from being read as a pattern.
    local query = tostring(data.query or ''):lower()
    local passes = TRACK_FILTERS[data.filter]

    local rows = {}

    for _, track in ipairs(tracks) do
        local name = tostring(track.name or ''):lower()

        if query == '' or name:find(query, 1, true) then
            local row = trackRow(track)

            if not passes or passes(row) then
                local total = totals[tostring(track.id)]
                row.raceCount = total and total.races or 0
                rows[#rows + 1] = row
            end
        end
    end

    local sorter = trackSorter(data.sorting)
    if sorter then table.sort(rows, sorter) end

    -- One page from the offset the list asked for. Past the end this answers
    -- empty, which is how the list knows to stop asking.
    local offset = math.max(0, math.floor(tonumber(data.offset) or 0))
    local page = {}

    for index = offset + 1, math.min(offset + Config.Tablet.tracksPerPage, #rows) do
        page[#page + 1] = rows[index]
    end

    cb(page)
end)

RegisterNUICallback('racing:loadCurrentTrack', function(data, cb)
    local trackId = data.trackId or data.id
    local track = lib.callback.await('whip-racing:getTrack', false, trackId)

    if not track then return cb(MISSING) end

    local row = trackRow(track)
    local stats = trackData(trackId)

    if stats then
        row.loadedData = { ['0'] = { ranked = stats, casual = stats } }
    end

    cb(row)
end)

RegisterNUICallback('racing:loadCurrentTrackData', function(data, cb)
    cb(trackData(data.trackId or data.id) or EMPTY)
end)

--- A racer's recent races, as the Recent Races list wants them. `raceId` is
--- what its Details button routes to, so it has to be the logged race id
--- rather than the lobby's, which restarts with the server.
local function recentRaceRows(stateId, limit)
    local races = lib.callback.await('whip-racing:getRecentRaces', false, stateId, limit) or EMPTY
    local rows = {}

    for index, race in ipairs(races) do
        rows[index] = {
            raceId = race.raceId,
            raceName = race.trackName,
            name = race.trackName,
            stateId = stateId,
            -- No rating is kept, so this stays flat rather than inventing
            -- movement. The place and the time are the real story.
            eloChange = 0,
            time = race.time,
            lapTimes = EMPTY,
            position = race.position or 0,
            racers = race.racers,
            laps = race.laps,
            payout = race.payout,
            vehiclePlate = '',
            state = 2,
        }
    end

    return rows
end

--- The home screen's three shelves. Nothing here tracks trending, so "hot" is
--- what has been flagged featured, "popular" is what has been raced most, and
--- "new" is what was added last. A shelf with nothing in it is left out by the
--- screen itself, so empty is a fine answer.
local function homeShelves()
    local tracks = lib.callback.await('whip-racing:getTabletTracks', false) or EMPTY
    local totals = lib.callback.await('whip-racing:getTrackTotals', false) or EMPTY

    local rows = {}
    for index, track in ipairs(tracks) do
        local row = trackRow(track)
        local total = totals[tostring(track.id)]
        row.bestTime = total and total.bestTime or 0
        row.raceCount = total and total.races or 0
        rows[index] = row
    end

    local function pick(filter, order, limit)
        local out = {}
        for _, row in ipairs(rows) do
            if not filter or filter(row) then out[#out + 1] = row end
        end
        table.sort(out, order)
        while #out > limit do out[#out] = nil end
        return out
    end

    return {
        hot = pick(function(row) return row.isFeatured end,
            function(a, b) return a.raceCount > b.raceCount end, 4),
        popular = pick(function(row) return row.raceCount > 0 end,
            function(a, b) return a.raceCount > b.raceCount end, 4),
        new = pick(nil, function(a, b) return (a.createdAt or 0) > (b.createdAt or 0) end, 4),
    }
end

RegisterNUICallback('racing:loadHome', function(_, cb)
    local shelves = homeShelves()

    cb({
        currentElo = 0,
        -- Recent Races, on the home screen and the profile alike.
        lastRaces = recentRaceRows(Tablet.Identity().stateId, 10),
        seasonRewards = EMPTY,
        -- false hides the daily case strip entirely, which is what a server
        -- with Config.DailyRewards.enabled off should see.
        dailyReward = lib.callback.await('whip-racing:getDaily', false) or false,
        hotTracks = shelves.hot,
        popularTracks = shelves.popular,
        newTracks = shelves.new,
        activeRaces = lobbyRows(),
    })
end)

--- Opens every case reached today and pays out in one go, which is what the
--- single Redeem button implies. The interface swaps its reward list for the
--- one that comes back, so it never has to refetch to grey the cases out.
RegisterNUICallback('racing:redeemDaily', function(_, cb)
    local ok, rewards, reason = lib.callback.await('whip-racing:redeemDaily', false)

    cb({ success = ok, rewards = rewards or EMPTY, error = not ok and reason or nil })
end)

RegisterNUICallback('racing:loadActiveRaces', function(_, cb)
    cb(lobbyRows())
end)

--- A finished race out of the log, in the same shape a live one takes. The
--- race screen switches on `status`, and at FINISHED it draws the standings --
--- which is exactly the results board that used to appear over the game.
local function finishedRaceRow(raceId)
    local race = lib.callback.await('whip-racing:getRaceResults', false, raceId)
    if not race then return nil end

    local players = {}

    -- Finishers come back in order, then anyone who did not finish. Those get
    -- numbered on from the last finisher rather than left unplaced: the board
    -- prints the position as an ordinal, so a sentinel would read as "999TH".
    local nextPlace = 0
    for _, row in ipairs(race.rows or EMPTY) do
        if row.position and row.position > nextPlace then nextPlace = row.position end
    end

    for _, row in ipairs(race.rows or EMPTY) do
        local place = row.position

        if not place then
            nextPlace = nextPlace + 1
            place = nextPlace
        end

        players[row.citizenid or tostring(place)] = {
            stateId = row.citizenid,
            nickname = row.name,
            crewTag = nil,
            elo = 0,
            eloChange = 0,
            incognito = false,
            position = place,
            time = row.time,
            bestLapTime = row.bestLap,
            -- The board reads `reward`, not `payout`.
            reward = row.payout or 0,
            lapTimes = EMPTY,
            vehicle = { label = vehicleLabel(row.model), class = VehicleClasses.Get(row.model), power = nil },
        }
    end

    return {
        id = race.id,
        raceName = race.trackName,
        trackId = race.trackId,
        trackName = race.trackName,
        vehicleClass = {},
        raceMode = race.ranked and 'ranked' or 'unranked',
        ownerStateId = '',
        startTime = 0,
        status = 2,   -- FINISHED
        players = players,
        maxPlayers = Config.Race.maxPlayers,
        minPlayers = Config.Race.minPlayers,
        maxLaps = race.laps,
        maxTimeAfterFirstFinish = Config.Race.finishGraceSeconds,
        season = 0,
        tournament = 0,
        ghostEnabled = 1,
        reverseRoute = false,
        requiredBid = 0,
        additionalReward = race.pot or 0,
        currency = 'CASH',
        isPrivate = false,
    }
end

--- A race id can mean either a lobby that is still running or one that has
--- finished. Live wins, since a lobby id is only reused after a restart.
RegisterNUICallback('racing:loadRace', function(data, cb)
    local raceId = data.id or data.raceId

    local lobby = lib.callback.await('whip-racing:getLobby', false, raceId)
    if lobby then return cb(raceRow(lobby)) end

    cb(finishedRaceRow(raceId) or MISSING)
end)

RegisterNUICallback('racing:loadSeason', function(_, cb)
    cb(season())
end)

RegisterNUICallback('racing:loadLeaderboardUsers', function(_, cb)
    local rows = lib.callback.await('whip-racing:getLeaderboard', false) or EMPTY
    local users = {}

    for index, row in ipairs(rows) do
        users[index] = {
            source = index,
            stateId = row.citizenid,
            nickname = row.name,
            profilePicture = nil,
            -- No rating is stored, so wins stand in for it and the standing
            -- itself carries the meaning.
            elo = tonumber(row.wins) or 0,
            crew = nil,
            crewTag = nil,
            wonRaces = tonumber(row.wins) or 0,
            totalRaces = tonumber(row.races) or 0,
            position = index,
            mostUsedVehicle = nil,
        }
    end

    cb(users)
end)

--- Vehicles and tracks share completed-race counts and actual finishing places.
--- Elo is not persisted by this resource.
local function mostUsedRow(label, row)
    return {
        label = label,
        name = label,
        wonRaces = tonumber(row.wins) or 0,
        avgPlace = tonumber(row.avgPlace),
        totalRaces = tonumber(row.races) or 0,
        lastUsed = tonumber(row.lastUsed) or 0,
        netElo = 0,
    }
end

local function vehicleRows(rows)
    local out = {}
    for index, row in ipairs(rows or EMPTY) do
        out[index] = mostUsedRow(vehicleLabel(row.model), row)
    end
    return out
end

local function trackUseRows(rows)
    local out = {}
    for index, row in ipairs(rows or EMPTY) do
        out[index] = mostUsedRow(row.trackName or ('Track ' .. tostring(row.trackId)), row)
    end
    return out
end

--- Everything the profile screen shows for one season.
local function profileData(profile)
    local lastRaces = recentRaceRows(profile.stateId, 15)

    return {
        deltaCash = profile.moneyMade or 0,
        totalRaces = profile.races,
        totalTime = profile.totalTime,
        tracksCreated = profile.tracksCreated,
        avgPlace = profile.avgPlace,
        mostRacedClass = profile.mostRacedClass or 'N/A',
        lastRaces = lastRaces,
        mostUsedVehicles = vehicleRows(profile.vehicles),
        mostPlayedTracks = trackUseRows(profile.tracks),
    }
end

RegisterNUICallback('racing:loadProfile', function(data, cb)
    local profile = lib.callback.await('whip-racing:getProfile', false, data and data.stateId)

    if not profile then return cb(MISSING) end

    cb({
        source = 1,
        stateId = profile.stateId,
        nickname = profile.name,
        profilePicture = nil,
        elo = 0,
        crew = nil,
        crewTag = nil,
        -- No seasons are kept here, so one standing period covers everything
        -- and the selector has something valid to sit on.
        availableSeasons = seasons(),
        currentSeasonId = 0,
        -- The screen only fetches this when the season *changes*, so opening a
        -- second profile would otherwise render against an empty container.
        -- Sending it filled in means it is there from the first frame.
        loadedData = { ['0'] = profileData(profile) },
    })
end)

RegisterNUICallback('racing:loadProfileData', function(data, cb)
    local profile = lib.callback.await('whip-racing:getProfile', false, data and data.stateId)
    cb(profile and profileData(profile) or EMPTY)
end)

--- "Show more" under the most-used lists; both page the same way.
RegisterNUICallback('racing:loadProfileVehicles', function(data, cb)
    cb(vehicleRows(lib.callback.await('whip-racing:getProfileTop', false,
        data.stateId, 'vehicles', data.offset, 3)))
end)

RegisterNUICallback('racing:loadProfileTracks', function(data, cb)
    cb(trackUseRows(lib.callback.await('whip-racing:getProfileTop', false,
        data.stateId, 'tracks', data.offset, 3)))
end)

-- ------------------------------------------------------------------ Actions

RegisterNUICallback('racing:startWaypoint', function(data, cb)
    local track = lib.callback.await('whip-racing:getTrack', false, data.trackId or data.id)
    local start = track and track.points and track.points[1]

    if start then
        SetNewWaypoint(start.x + 0.0, start.y + 0.0)
        Bridge.Notify(('Route set to "%s".'):format(track.name), 'success')
    end

    cb({ ok = start ~= nil })
end)

--- The interface's checkpoint shape, back into ours. The reverse of
--- checkpointRows: the heading rides in `w`, and distBetweenProps is the gate
--- width, which is twice the radius.
local function pointsFromRows(rows)
    local points = {}

    for index, row in ipairs(rows or EMPTY) do
        local coords = row.coords or row

        points[index] = {
            x = coords.x,
            y = coords.y,
            z = coords.z,
            heading = coords.w or coords.heading or 0.0,
            radius = (row.distBetweenProps and row.distBetweenProps / 2.0)
                or Config.Checkpoints.defaultRadius,
        }
    end

    return points
end

--- Out to the world editor, carrying the draft as it stands on screen.
---
--- The draft rather than the stored track: a name typed but not yet saved
--- would otherwise be lost the moment you went out to move a checkpoint. The
--- editor holds those fields untouched and hands them straight back.
RegisterNUICallback('racing:editor', function(data, cb)
    Tablet.Close()

    local draft = data or {}
    local points = pointsFromRows(draft.checkpoints)

    -- Opening the editor on a track with no checkpoints yet is how a new one
    -- starts, so an empty list is not an error.
    if #points == 0 and draft.id and draft.id > 0 then
        local track = lib.callback.await('whip-racing:getTrack', false, draft.id)
        if track then points = track.points end
    end

    Creator.Start(points, {
        id = draft.id and draft.id > 0 and draft.id or nil,
        circuit = not draft.isSprint,
        props = draft.props,
        draft = {
            name = draft.name,
            isPublished = draft.isPublished,
            isSprint = draft.isSprint,
        },
    })

    cb({})
end)

--- Every action answers { success, error }: that is what the interface
--- destructures, and anything else reads to it as a failure.
RegisterNUICallback('racing:deleteTrack', function(data, cb)
    local ok, message = lib.callback.await('whip-racing:deleteTrack', false, data.trackId or data.id)
    Bridge.Notify(message, ok and 'success' or 'error')
    cb({ success = ok, error = not ok and message or nil })
end)

--- The editor's save. Name, shape and visibility all come from the tablet's own
--- fields -- the world editor no longer asks for them.
RegisterNUICallback('racing:saveTrack', function(data, cb)
    local points = pointsFromRows(data.checkpoints)

    local ok, message = lib.callback.await('whip-racing:saveTrack', false, {
        id = data.id and data.id > 0 and data.id or nil,
        name = data.name,
        points = points,
        props = data.props,
        circuit = not data.isSprint,
        published = data.isPublished and true or false,
    })

    Bridge.Notify(message, ok and 'success' or 'error')
    cb({ success = ok, error = not ok and message or nil })
end)

RegisterNUICallback('racing:createRace', function(data, cb)
    local vehicle = GetVehiclePedIsIn(cache.ped or PlayerPedId(), false)
    local track = data.track

    local ok, message, lobby = lib.callback.await('whip-racing:createLobby', false, {
        vehicleClasses = data.vehicleClass,
        trackId = data.trackId or (track and track.id),
        laps = tonumber(data.maxLaps) or 1,
        buyin = tonumber(data.requiredBid) or 0,
        pinkSlip = data.pinkSlipMode and true or false,
        -- The button pressed decides this; the server checks it is allowed.
        ranked = data.isRanked and true or false,
        ghostMode = ghostModeId(data.ghostEnabled),
        -- Only admins see this section, and only admins are allowed to set it
        -- -- the server checks again rather than trusting that.
        positionRewards = data.positionRewards,
        -- Race against the record holder's stored run. Off unless asked for,
        -- and only possible on a track where a ghost was actually recorded.
        raceGhost = data.raceGhost and true or false,
        plate = vehicle ~= 0 and GetVehicleNumberPlateText(vehicle) or nil,
        class = vehicle ~= 0 and GetVehicleClass(vehicle) or 0,
    })

    Bridge.Notify(message, ok and 'success' or 'error')
    -- The interface routes to /racing/race/<id> on the way out, so the id has
    -- to come back with the answer.
    cb({ success = ok, id = lobby and lobby.id, error = not ok and message or nil })
end)

RegisterNUICallback('racing:joinRace', function(data, cb)
    local vehicle = GetVehiclePedIsIn(cache.ped or PlayerPedId(), false)

    local ok, message = lib.callback.await('whip-racing:joinLobby', false, {
        lobbyId = data.raceId or data.id,
        plate = vehicle ~= 0 and GetVehicleNumberPlateText(vehicle) or nil,
        class = vehicle ~= 0 and GetVehicleClass(vehicle) or 0,
    })

    Bridge.Notify(message, ok and 'success' or 'error')
    cb({ success = ok, error = not ok and message or nil })
end)

RegisterNUICallback('racing:leaveRace', function(_, cb)
    local ok = lib.callback.await('whip-racing:leaveLobby', false)
    if ok and Race.active then Race.Cleanup() end
    if ok then Tablet.Close() end
    cb({ success = ok and true or false })
end)

RegisterNUICallback('racing:startRace', function(data, cb)
    local ok, message = lib.callback.await('whip-racing:startLobby', false, data.raceId or data.id)
    if message then Bridge.Notify(message, ok and 'success' or 'error') end
    cb({ success = ok, error = not ok and message or nil })
end)

--- Host-only lobby controls.
RegisterNUICallback('racing:kick', function(data, cb)
    local ok, message = lib.callback.await('whip-racing:kickFromLobby', false,
        data.raceId or data.id, data.stateId)
    cb({ success = ok, error = not ok and message or nil })
end)

RegisterNUICallback('racing:deleteRace', function(data, cb)
    local ok, message = lib.callback.await('whip-racing:disbandLobby', false, data.raceId or data.id)
    cb({ success = ok, error = not ok and message or nil })
end)

--- The admin screen's per-track flags and its delete.
RegisterNUICallback('racing:adminUpdateTrackKey', function(data, cb)
    local track, message = lib.callback.await('whip-racing:setTrackFlag', false,
        data.trackId, data.key, data.value)

    cb({ track = track and trackRow(track) or nil, error = not track and message or nil })
end)

RegisterNUICallback('racing:adminDeleteTrack', function(data, cb)
    local ok, message = lib.callback.await('whip-racing:deleteTrack', false, data.trackId)
    cb({ success = ok, error = not ok and message or nil })
end)

RegisterNUICallback('racing:searchProfiles', function(data, cb)
    local rows = lib.callback.await('whip-racing:searchRacers', false, data.query) or EMPTY
    local users = {}

    for index, row in ipairs(rows) do
        users[index] = {
            source = index,
            stateId = row.citizenid,
            nickname = row.name,
            profilePicture = nil,
            elo = 0,
            crew = nil,
            crewTag = nil,
            totalRaces = tonumber(row.races) or 0,
            wonRaces = 0,
            position = index,
            mostUsedVehicle = nil,
        }
    end

    cb(users)
end)

--- What the racer is sitting in. There is no garage behind this, so the answer
--- is the one car they could actually bring.
--- The item picker in the race creator. Debounced on the interface's side, so
--- this is asked once a query settles rather than once a keystroke.
RegisterNUICallback('racing:getRewardItems', function(data, cb)
    cb(lib.callback.await('whip-racing:getRewardItems', false, data and data.query) or EMPTY)
end)

RegisterNUICallback('racing:getAvailableVehicles', function(_, cb)
    local vehicle = GetVehiclePedIsIn(cache.ped or PlayerPedId(), false)
    if vehicle == 0 then return cb(EMPTY) end

    local model = GetEntityModel(vehicle)

    cb({ {
        label = GetLabelText(GetDisplayNameFromVehicleModel(model)),
        class = VehicleClasses.OfVehicle(vehicle),
        modelHash = model,
        entity = VehToNet(vehicle),
        plate = GetVehicleNumberPlateText(vehicle),
        power = nil,
    } })
end)

--- The settings screen posts every field at once, alias included. It used to
--- be parked in a client-side variable that nothing read, which is why picking
--- a name appeared to work and then changed nothing.
---
--- A refused name comes back with the reason, which the screen shows above the
--- Save button.
RegisterNUICallback('racing:saveSettings', function(data, cb)
    local ok, reason = lib.callback.await('whip-racing:saveSettings', false, data)

    if ok then
        -- Everything showing this player's name is now stale: their own header,
        -- the standings, the lobby they are sitting in. Re-fetching is simpler
        -- than tracking down every screen that has one.
        local identity = lib.callback.await('whip-racing:getIdentity', false)

        if identity then
            Tablet.identity = identity

            Tablet.Dispatch('root', 'setPlayerData', {
                stateId = identity.stateId,
                name = identity.name,
            })
        end

        Bridge.Notify('Racing settings saved.', 'success')
    end

    cb({ success = ok, error = not ok and reason or nil })
end)

-- Crew callbacks return the response shapes expected by the tablet.
for _, action in ipairs({ 'createCrew', 'loadCrews', 'loadCrew', 'leaveCrew' }) do
    RegisterNUICallback('racing:' .. action, function(data, cb)
        local result = ask('whip-racing:' .. action, data)
        if action == 'loadCrews' then return cb(result or EMPTY) end
        if action == 'loadCrew' then return cb(result or MISSING) end
        cb(result or { success = false, error = 'Crew service is unavailable. Check the server console.' })
    end)
end

-- Screens this resource has no concept of. Answering empty keeps them rendered
-- and inert rather than stuck loading.
for _, name in ipairs({
    'racing:loadCrewBattle',
    'racing:loadActiveCrewBattles', 'racing:loadCrewsBattleHistory',
    'racing:loadTournaments', 'racing:getRewardVehicles',
    'racing:createRole', 'racing:inviteMember',
    'racing:kickFromCrew', 'racing:setMemberRole',
    'racing:setRole', 'racing:removeRole', 'racing:claimSeasonReward',
    'racing:joinTournament', 'racing:sendChatMessage',
    'racing:setFavourite', 'racing:findPrivateRace', 'racing:checkPassword',
    'racing:createBattle', 'racing:joinCrewBattle', 'racing:forfeitCrewBattle',
}) do
    RegisterNUICallback(name, function(_, cb) cb(EMPTY) end)
end

-- ox_inventory performs its normal item-use validation before opening the UI.
-- Without ox_inventory (WHIP), it just opens.
exports('useRacingTablet', function(data, slot)
    if GetResourceState('ox_inventory') ~= 'started' then return Tablet.Open() end
    exports.ox_inventory:useItem(data, function(used)
        if used then Tablet.Open() end
    end)
end)

-- Open from another client resource without requiring an inventory or command.
exports('openTablet', function()
    Tablet.Open()
end)
