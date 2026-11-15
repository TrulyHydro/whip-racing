local lobbies = {}
local playerLobby = {}   -- source -> lobbyId
local nextLobbyId = 1

-- ---------------------------------------------------------------- Helpers

-- Resolve the actual vehicle on the server; client-supplied classes are not trusted.
local function racerVehicle(source)
    local ped = GetPlayerPed(source)
    local vehicle = ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
    if vehicle == 0 then return nil end
    return VehicleClasses.Model(GetEntityModel(vehicle)), VehicleClasses.OfVehicle(vehicle)
end

local function playerList(lobby)
    local list = {}
    for _, entry in pairs(lobby.players) do
        list[#list + 1] = {
            source = entry.source,
            -- The tablet keys its player list by state id, not by source.
            stateId = entry.citizenid,
            name = Profiles.DisplayName(entry.citizenid, entry.name),
            model = entry.model,
            vehicleClass = entry.vehicleClass or VehicleClasses.Get(entry.model),
            host = entry.source == lobby.host,
            staked = entry.plate and lobby.pinkSlip or false,
        }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function lobbyView(lobby)
    if not lobby then return nil end
    local track = Tracks.Get(lobby.trackId)
    return {
        id = lobby.id,
        state = lobby.state,
        trackId = lobby.trackId,
        trackName = track and track.name or 'Unknown',
        vehicleClasses = lobby.vehicleClasses,
        checkpoints = track and track.checkpoints or 0,
        distance = track and track.distance or 0,
        laps = lobby.laps,
        buyin = lobby.buyin,
        pot = lobby.pot,
        pinkSlip = lobby.pinkSlip,
        ranked = lobby.ranked,
        ghostMode = lobby.ghostMode,
        raceGhost = lobby.raceGhost,
        maxPlayers = lobby.maxPlayers,
        minPlayers = Config.Race.minPlayers,
        host = lobby.host,
        players = playerList(lobby),
    }
end

--- The same lobby, tagged with what this specific player is allowed to do.
local function lobbyViewFor(lobby, src)
    local view = lobbyView(lobby)
    if not view then return nil end
    view.isHost = lobby.host == src
    for _, entry in ipairs(view.players) do
        entry.you = entry.source == src
    end
    return view
end

local function broadcast(lobby, event, payload)
    for source in pairs(lobby.players) do
        TriggerClientEvent(event, source, payload)
    end
end

local function pushLobby(lobby)
    for source in pairs(lobby.players) do
        TriggerClientEvent('whip-racing:lobby', source, lobbyViewFor(lobby, source))
    end
end

local function openLobbies()
    local list = {}
    for _, lobby in pairs(lobbies) do
        if lobby.state == 'lobby' then
            local view = lobbyView(lobby)
            view.count = #view.players
            list[#list + 1] = view
        end
    end
    return list
end

--- Removes a racer and cleans up the lobby if it's now empty or hostless.
local function removePlayer(src, refund)
    local lobbyId = playerLobby[src]
    if not lobbyId then return end

    local lobby = lobbies[lobbyId]
    playerLobby[src] = nil
    if not lobby then return end

    local entry = lobby.players[src]
    if not entry then return end

    if refund and lobby.state == 'lobby' and lobby.buyin > 0 then
        Betting.Refund(src, lobby.buyin)
        lobby.pot = math.max(0, lobby.pot - lobby.buyin)
    end

    lobby.players[src] = nil

    local remaining = 0
    for _ in pairs(lobby.players) do remaining = remaining + 1 end

    if remaining == 0 then
        lobbies[lobbyId] = nil
        return
    end

    if lobby.host == src then
        -- Hand the lobby to whoever is left rather than dropping the race.
        for source in pairs(lobby.players) do
            lobby.host = source
            break
        end
    end

    pushLobby(lobby)
end

-- ---------------------------------------------------------------- Standings

--- Time gap between two racers at the last checkpoint they have both reached.
--- Positive means `racer` got there sooner, so they are ahead of `me`. Comparing
--- at a shared checkpoint is what makes the number meaningful -- raw elapsed
--- times are not comparable when two cars are at different points on the route.
local function gapBetween(racer, me)
    if not me or racer.source == me.source then return nil end

    if racer.finished and me.finished then
        return (me.time or 0) - (racer.time or 0)
    end

    local common = math.min(racer.progress or 0, me.progress or 0)
    if common < 1 then return nil end

    local theirs = racer.splits and racer.splits[common]
    local mine = me.splits and me.splits[common]
    if not theirs or not mine then return nil end

    return mine - theirs
end

local function buildStandings(lobby)
    local racers = {}
    for _, entry in pairs(lobby.players) do
        racers[#racers + 1] = entry
    end

    table.sort(racers, function(a, b)
        if a.finished ~= b.finished then return a.finished end
        if a.finished and b.finished then return a.time < b.time end
        if a.progress ~= b.progress then return a.progress > b.progress end
        return (a.elapsed or 0) < (b.elapsed or 0)
    end)

    for source, entry in pairs(lobby.players) do
        local payload = {}
        for index, racer in ipairs(racers) do
            payload[index] = {
                name = racer.name,
                lap = racer.lap or 1,
                finished = racer.finished or false,
                dnf = racer.dnf or false,
                time = racer.time,
                you = racer.source == source,
                -- Every racer sees the gaps measured against themselves.
                gap = gapBetween(racer, entry),
            }
        end
        TriggerClientEvent('whip-racing:standings', source, payload)
    end
end

-- ---------------------------------------------------------------- Results

local function finaliseRace(lobby)
    if lobby.state == 'finished' then return end
    lobby.state = 'finished'

    local finishers = {}
    local dnfs = {}

    for _, entry in pairs(lobby.players) do
        if entry.finished then
            finishers[#finishers + 1] = entry
        else
            dnfs[#dnfs + 1] = entry
        end
    end

    table.sort(finishers, function(a, b) return a.time < b.time end)

    local payouts = Betting.PayOut(lobby.pot, finishers)

    -- Framework hook (driver XP on Hydro); absent on other frameworks.
    if Bridge.RaceFinished then Bridge.RaceFinished(finishers) end

    -- Items attached to finishing places, if an admin set any up.
    Betting.PayRewards(lobby, finishers)

    -- Pink slips: everyone who didn't win hands their staked car to the winner.
    local slips = {}
    if lobby.pinkSlip and finishers[1] then
        local winner = Bridge.GetPlayer(finishers[1].source)
        if winner then
            for _, entry in pairs(lobby.players) do
                if entry.source ~= finishers[1].source and entry.plate then
                    if Betting.TransferVehicle(entry.plate, winner.citizenid) then
                        slips[#slips + 1] = { from = entry.name, plate = entry.plate, model = entry.model }
                    end
                end
            end
        end
    end

    local winnerTime = finishers[1] and finishers[1].time or nil

    local rows = {}
    for place, entry in ipairs(finishers) do
        local award = 0
        for _, payout in ipairs(payouts) do
            if payout.place == place then award = payout.amount end
        end

        rows[#rows + 1] = {
            place = place,
            citizenid = entry.citizenid,
            name = entry.name,
            time = entry.time,
            bestLap = entry.bestLap,
            gap = winnerTime and (entry.time - winnerTime) or 0,
            payout = award,
            record = entry.record or false,
            model = entry.model,
        }
    end

    for _, entry in ipairs(dnfs) do
        rows[#rows + 1] = {
            place = nil, citizenid = entry.citizenid, name = entry.name,
            dnf = true, model = entry.model,
        }
    end

    local track = Tracks.Get(lobby.trackId)

    -- Written before the results go out so they can carry the id the tablet
    -- looks the race up by later.
    local raceId = History.Record(lobby, rows)

    local results = {
        raceId = raceId,
        trackName = track and track.name or 'Unknown',
        laps = lobby.laps,
        pot = lobby.pot,
        pinkSlips = slips,
        rows = rows,
    }

    for source in pairs(lobby.players) do
        TriggerClientEvent('whip-racing:results', source, results)
        playerLobby[source] = nil
    end

    lobbies[lobby.id] = nil
end

--- Ends the race once everyone has finished, or after the grace period expires.
local function watchFinish(lobby)
    CreateThread(function()
        while lobbies[lobby.id] and lobby.state == 'racing' do
            local outstanding = 0
            local anyFinished = false

            for _, entry in pairs(lobby.players) do
                if entry.finished then
                    anyFinished = true
                else
                    outstanding = outstanding + 1
                end
            end

            if outstanding == 0 then
                finaliseRace(lobby)
                return
            end

            if anyFinished and lobby.firstFinishAt then
                if (os.time() - lobby.firstFinishAt) > Config.Race.finishGraceSeconds then
                    finaliseRace(lobby)
                    return
                end
            end

            Wait(1000)
        end
    end)
end

-- ---------------------------------------------------------------- Callbacks

lib.callback.register('whip-racing:getMenu', function(source)
    local player = Bridge.GetPlayer(source)
    return {
        -- Passing the state id lets the browser include this player's own
        -- unpublished drafts alongside everything that is public.
        tracks = Tracks.List(player and player.citizenid),
        lobbies = openLobbies(),
        lobby = lobbyViewFor(lobbies[playerLobby[source] or 0], source),
        money = player and player.getMoney(Config.MoneyAccount) or 0,
        name = Profiles.DisplayName(player and player.citizenid,
            player and player.name or GetPlayerName(source)),
        canCreate = true,
    }
end)

--- Whether this player may create a ranked race. Empty allowlist means anyone.
local function canRank(src)
    if #Config.Race.rankedAllowlist == 0 then return true end

    if Bridge.MatchesIdentity(src, Config.Race.rankedAllowlist) then return true end

    return Bridge.IsAdmin(src)
end

--- Who this player is. The tablet keys almost everything off the state id --
--- whether you own a race, whether you are in it, which row on a leaderboard is
--- yours -- so it has to be the real one before anything else is asked for.
lib.callback.register('whip-racing:getIdentity', function(source)
    local player = Bridge.GetPlayer(source)

    return {
        stateId = player and player.citizenid or tostring(source),
        name = Profiles.DisplayName(player and player.citizenid,
            player and player.name or GetPlayerName(source)),
        -- Only decides whether the section is *shown*. Every admin callback
        -- checks again for itself, so a client that lies about this gets a
        -- screen full of buttons that all refuse.
        isAdmin = Bridge.IsAdmin(source),
        -- Shows the "Create Ranked" button. Checked again on creation.
        canRank = canRank(source),
    }
end)

--- One lobby by id, for the tablet's race screen.
lib.callback.register('whip-racing:getLobby', function(source, lobbyId)
    return lobbyViewFor(lobbies[tonumber(lobbyId) or 0], source)
end)

lib.callback.register('whip-racing:createLobby', function(source, data)
    if playerLobby[source] then
        return false, 'You are already in a lobby.'
    end

    local track = Tracks.Get(data.trackId)
    if not track then return false, 'That track no longer exists.' end

    local selection = VehicleClasses.Selection(data.vehicleClasses)
    if not selection then return false, 'Choose valid racing classes.' end
    local model, class = racerVehicle(source)
    if not VehicleClasses.Allows(selection, model, class) then
        return false, 'Your vehicle is not in an allowed racing class.'
    end

    if not Bridge.GetPlayer(source) then return false, 'Player identity is unavailable.' end

    local buyin = math.max(Config.Buyin.min, math.min(Config.Buyin.max, math.floor(tonumber(data.buyin) or 0)))
    if not Bridge.hasEconomy or not Config.Buyin.enabled then buyin = 0 end
    local laps = math.max(1, math.min(Config.Race.maxLaps, math.floor(tonumber(data.laps) or 1)))

    if data.pinkSlip then
        local ok, message = Betting.VerifyPinkSlip(source, data.plate, data.class or 0)
        if not ok then return false, message end
    end

    if buyin > 0 then
        local ok, message = Betting.TakeBuyin(source, buyin)
        if not ok then return false, message end
    end

    local player = Bridge.GetPlayer(source)
    local id = nextLobbyId
    nextLobbyId = nextLobbyId + 1

    local lobby = {
        id = id,
        host = source,
        vehicleClasses = selection,
        trackId = data.trackId,
        laps = laps,
        buyin = buyin,
        pot = buyin,
        pinkSlip = data.pinkSlip and Config.PinkSlips.enabled or false,
        ghostMode = data.ghostMode or 'none',
        raceGhost = data.raceGhost and true or false,
        maxPlayers = math.max(2, math.min(Config.Race.maxPlayers, math.floor(tonumber(data.maxPlayers) or Config.Race.maxPlayers))),
        state = 'lobby',
        players = {},
        -- Asking for ranked does not make it so: the allowlist decides.
        ranked = data.ranked and canRank(source) or false,
        -- nil unless an admin attached something the catalogue recognises.
        rewards = Betting.CleanRewards(source, data.positionRewards),
    }

    lobby.players[source] = {
        source = source,
        -- The alias is resolved here, once, so the in-race HUD standings and
        -- the results board show the same name the tablet does.
        name = Profiles.DisplayName(player and player.citizenid,
            player and player.name or GetPlayerName(source)),
        citizenid = player and player.citizenid,
        plate = data.plate,
        model = model,
        vehicleClass = class,
        progress = 0,
        lap = 1,
    }

    lobbies[id] = lobby
    playerLobby[source] = id

    -- The host needs the same lobby event everyone else gets, not just the
    -- callback return: it is what stands the start gate up for them.
    pushLobby(lobby)

    return true, ('Lobby open on %s.'):format(track.name), lobbyViewFor(lobby, source)
end)

lib.callback.register('whip-racing:joinLobby', function(source, data)
    if playerLobby[source] then return false, 'You are already in a lobby.' end

    if not Bridge.GetPlayer(source) then return false, 'Player identity is unavailable.' end
    local lobby = lobbies[data.lobbyId]
    if not lobby then return false, 'That lobby no longer exists.' end
    if lobby.state ~= 'lobby' then return false, 'That race has already started.' end

    local count = 0
    for _ in pairs(lobby.players) do count = count + 1 end
    if count >= lobby.maxPlayers then return false, 'That lobby is full.' end

    local model, class = racerVehicle(source)
    if not VehicleClasses.Allows(lobby.vehicleClasses, model, class) then
        return false, 'Your vehicle is not in an allowed racing class.'
    end

    if lobby.pinkSlip then
        local ok, message = Betting.VerifyPinkSlip(source, data.plate, data.class or 0)
        if not ok then return false, message end
    end

    if lobby.buyin > 0 then
        local ok, message = Betting.TakeBuyin(source, lobby.buyin)
        if not ok then return false, message end
        lobby.pot = lobby.pot + lobby.buyin
    end

    local player = Bridge.GetPlayer(source)
    lobby.players[source] = {
        source = source,
        -- The alias is resolved here, once, so the in-race HUD standings and
        -- the results board show the same name the tablet does.
        name = Profiles.DisplayName(player and player.citizenid,
            player and player.name or GetPlayerName(source)),
        citizenid = player and player.citizenid,
        plate = data.plate,
        model = model,
        vehicleClass = class,
        progress = 0,
        lap = 1,
    }
    playerLobby[source] = lobby.id

    pushLobby(lobby)
    return true, 'Joined the lobby.', lobbyViewFor(lobby, source)
end)

lib.callback.register('whip-racing:leaveLobby', function(source)
    removePlayer(source, true)
    TriggerClientEvent('whip-racing:lobby', source, nil)
    return true, 'Left the lobby.'
end)

--- Host-only. The tablet knows racers by state id, so the source has to be
--- found by matching rather than passed in.
lib.callback.register('whip-racing:kickFromLobby', function(source, lobbyId, stateId)
    local lobby = lobbies[tonumber(lobbyId) or 0]
    if not lobby then return false, 'That lobby no longer exists.' end
    if lobby.host ~= source then return false, 'Only the host can remove racers.' end
    if lobby.state ~= 'lobby' then return false, 'The race is already running.' end

    for target, entry in pairs(lobby.players) do
        if entry.citizenid == stateId or tostring(target) == tostring(stateId) then
            if target == source then return false, 'You cannot remove yourself.' end

            removePlayer(target, true)
            TriggerClientEvent('whip-racing:lobby', target, nil)
            TriggerClientEvent('whip-racing:cancelled', target, 'The host removed you from the race.')

            return true
        end
    end

    return false, 'That racer is not in this lobby.'
end)

--- Closes a lobby down and refunds everyone in it.
lib.callback.register('whip-racing:disbandLobby', function(source, lobbyId)
    local lobby = lobbies[tonumber(lobbyId) or 0]
    if not lobby then return false, 'That lobby no longer exists.' end

    if lobby.host ~= source and not Bridge.IsAdmin(source) then
        return false, 'Only the host can cancel the race.'
    end

    local members = {}
    for target in pairs(lobby.players) do members[#members + 1] = target end

    for _, target in ipairs(members) do
        removePlayer(target, true)
        TriggerClientEvent('whip-racing:lobby', target, nil)
        TriggerClientEvent('whip-racing:cancelled', target, 'The race was cancelled.')
    end

    lobbies[lobby.id] = nil

    return true
end)

lib.callback.register('whip-racing:startLobby', function(source, lobbyId)
    local lobby = lobbies[lobbyId]
    if not lobby then return false, 'That lobby no longer exists.' end
    if lobby.host ~= source then return false, 'Only the host can start the race.' end
    if lobby.state ~= 'lobby' then return false, 'The race is already running.' end

    local count = 0
    for _ in pairs(lobby.players) do count = count + 1 end
    if count < Config.Race.minPlayers then
        return false, ('You need at least %d racers.'):format(Config.Race.minPlayers)
    end

    local track = Tracks.Get(lobby.trackId)
    if not track then return false, 'That track no longer exists.' end

    for src, entry in pairs(lobby.players) do
        local model, class = racerVehicle(src)
        if not VehicleClasses.Allows(lobby.vehicleClasses, model, class) then
            return false, ('%s needs a vehicle in an allowed racing class.'):format(entry.name)
        end
        entry.model = model or entry.model
        entry.vehicleClass = class or entry.vehicleClass
    end

    lobby.state = 'racing' 
    lobby.startedAt = os.time()

    local best = Records.Best(lobby.trackId, lobby.laps)
    local ghostRun = nil
    if lobby.raceGhost and best and best.ghost then
        ghostRun = { samples = best.ghost, model = best.model }
    end

    for src, entry in pairs(lobby.players) do
        entry.progress = 0
        entry.lap = 1
        entry.finished = false
        entry.dnf = false
        entry.time = nil
        entry.splits = {}

        TriggerClientEvent('whip-racing:start', src, {
            lobbyId = lobby.id,
            track = track,
            laps = lobby.laps,
            ghostMode = lobby.ghostMode,
            countdown = Config.Race.countdownSeconds,
            reference = best and best.splits or nil,
            ghostRun = ghostRun,
        })
    end

    watchFinish(lobby)
    return true, 'Race started.'
end)

-- ---------------------------------------------------------------- Race events

-- Checkpoints can come quickly (Config.Race.minCheckpointMs), so the default allowance:
-- ten back to back, then one per 100 ms.
Bridge.NetEvent('whip-racing:progress', {
    params = { { 'lobbyId', 'id' }, { 'progress', 'int', 0, 1000000 }, { 'elapsed', 'number', 0, 86400000, 0 } },
}, function(src, lobbyId, progress, elapsed)
    local lobby = lobbies[lobbyId]
    if not lobby or lobby.state ~= 'racing' then return end

    local entry = lobby.players[src]
    if not entry then return end

    -- Progress only ever moves forward; ignore anything that tries to rewind.
    if type(progress) ~= 'number' or progress <= entry.progress then return end

    local track = Tracks.Get(lobby.trackId)
    local maxProgress = (track and track.checkpoints or 0) * lobby.laps
    if progress > maxProgress then return end

    entry.progress = progress
    entry.elapsed = tonumber(elapsed) or 0
    entry.lap = math.floor(progress / math.max(1, track.checkpoints)) + 1

    -- Kept per checkpoint so live gaps can be measured at a shared point on the
    -- route rather than against raw elapsed time.
    entry.splits = entry.splits or {}
    entry.splits[progress] = entry.elapsed

    buildStandings(lobby)
end)

-- `result` carries the splits and the ghost recording (a table); the checks below are the handler's own.
Bridge.NetEvent('whip-racing:finish', {
    rateLimit = 1000, burst = 2,
    params = { { 'lobbyId', 'id' }, { 'result', 'any' } },
}, function(src, lobbyId, result)
    if type(result) ~= 'table' then return false end
    local lobby = lobbies[lobbyId]
    if not lobby or lobby.state ~= 'racing' then return end

    local entry = lobby.players[src]
    if not entry or entry.finished then return end

    local time = tonumber(result and result.time) or 0

    -- Reject impossible times. The floor is deliberately generous: raise
    -- Config.Race.minCheckpointMs if your tracks are spaced further apart.
    local track = Tracks.Get(lobby.trackId)
    local floor = (track and track.checkpoints or 1) * lobby.laps * (Config.Race.minCheckpointMs or 300)
    if time < floor then
        Bridge.Notify(src, 'Your time was rejected.', 'error')
        entry.finished = false
        return
    end

    -- And it cannot be faster than the wall clock says is possible.
    local wallClock = (os.time() - lobby.startedAt) * 1000
    if time > wallClock + 5000 then return end

    local model, class = racerVehicle(src)
    if not VehicleClasses.Allows(lobby.vehicleClasses, model, class) then
        Bridge.Notify(src, 'Your vehicle is not in an allowed racing class.', 'error')
        return
    end
    entry.finished = true
    entry.time = time
    entry.bestLap = tonumber(result.bestLap)
    entry.model = model or entry.model
    entry.progress = (track and track.checkpoints or 0) * lobby.laps

    lobby.firstFinishAt = lobby.firstFinishAt or os.time()

    local player = Bridge.GetPlayer(src)
    if player then
        entry.record = Records.Submit(lobby.trackId, lobby.laps, player, {
            time = time,
            bestLap = entry.bestLap,
            model = entry.model,
            splits = result.splits,
            ghost = result.ghost,
        })

        -- Counted on crossing the line, not on joining a lobby, so sitting on
        -- a grid all day earns nothing.
        Daily.CountFinish(player.citizenid)
    end

    buildStandings(lobby)
end)

-- whileDead: dying mid-race is a common way to drop out.
Bridge.NetEvent('whip-racing:abandon', {
    rateLimit = 1000, burst = 2, whileDead = true,
    params = { { 'lobbyId', 'id' } },
}, function(src, lobbyId)
    local lobby = lobbies[lobbyId]
    if not lobby then return end

    local entry = lobby.players[src]
    if not entry then return end

    if lobby.state == 'racing' then
        -- Stay in the results as a DNF; the buy-in stays in the pot.
        entry.finished = false
        entry.dnf = true
        entry.progress = -1
        buildStandings(lobby)

        local racing = 0
        for _, other in pairs(lobby.players) do
            if not other.dnf and not other.finished then racing = racing + 1 end
        end
        if racing == 0 then finaliseRace(lobby) end
    else
        removePlayer(src, true)
    end
end)

AddEventHandler('playerDropped', function()
    removePlayer(source, false)
end)

-- ---------------------------------------------------------------- Admin

Bridge.RegisterCommand('cancelRace', 'cancelrace', function(source)
    if source ~= 0 and not Bridge.IsAdmin(source) and not IsPlayerAceAllowed(source, 'command.cancelrace') then
        Bridge.Notify(source, 'You do not have permission to cancel races.', 'error')
        return
    end
    for id, lobby in pairs(lobbies) do
        broadcast(lobby, 'whip-racing:cancelled', 'An admin cancelled the race.')
        for source in pairs(lobby.players) do
            Betting.Refund(source, lobby.buyin)
            playerLobby[source] = nil
        end
        lobbies[id] = nil
    end
end, false)

-- Errors from a player's tablet page (client/tablet.lua forwards them), so a
-- broken screen shows up in the server console. Rate limited per player.
local tabletErrors = {}
Bridge.NetEvent('whip-racing:tabletError', {
    rateLimit = 250, burst = 20, whileDead = true, requirePlayer = false,
    params = { { 'line', 'string', 1200 } },
}, function(src, line)
    tabletErrors[src] = (tabletErrors[src] or 0) + 1
    if tabletErrors[src] > 80 or type(line) ~= 'string' then return end
    print(('[whip-racing] tablet error from %s [%d]: %s'):format(GetPlayerName(src) or '?', src, line:sub(1, 1200)))
end)
AddEventHandler('playerDropped', function() tabletErrors[source] = nil end)
