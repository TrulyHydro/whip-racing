Race = {
    active = false,
    lobbyId = nil,
    track = nil,
    laps = 1,
    lap = 1,
    startedAt = 0,
    lapStartedAt = 0,
    splits = {},        -- elapsed ms at each checkpoint of the current lap
    bestLap = nil,
    reference = nil,    -- split times to compare against, from the track record
    ghostMode = 'none',
    standings = {},
    vehicleNetId = nil,
    strayedAt = nil,
    finished = false,
}

local function resetRaceState()
    Race.active = false
    Race.lobbyId = nil
    Race.track = nil
    Race.lap = 1
    Race.splits = {}
    Race.bestLap = nil
    Race.reference = nil
    Race.standings = {}
    Race.vehicleNetId = nil
    Race.strayedAt = nil
    Race.finished = false
end

--- Total checkpoints crossed across all laps, used for live position sorting.
local function progressIndex()
    local perLap = #Race.track.points
    return ((Race.lap - 1) * perLap) + (Checkpoints.index - 1)
end

-- ---------------------------------------------------------------- HUD

--- The route is cut into four sectors so the HUD can show where a lap was won
--- or lost, the way a timing screen would.
local SECTOR_COUNT = 4

local function sectorTimes()
    local points = Race.track and Race.track.points
    local sectors = {}
    if not points then return sectors end

    local count = #points
    local previousMs, previousIndex = 0, 0

    for sector = 1, SECTOR_COUNT do
        local boundary = math.max(1, math.ceil(count * sector / SECTOR_COUNT))
        local split = boundary > previousIndex and Race.splits[boundary] or nil

        if split then
            sectors[sector] = { ms = split - previousMs, done = true }
            previousMs, previousIndex = split, boundary
        else
            sectors[sector] = { ms = 0, done = false }
        end
    end

    return sectors
end

--- Signed angle in degrees turned at `b` when travelling a -> b -> c.
--- Positive is a left-hander.
local function signedTurn(a, b, c)
    local inX, inY = b.x - a.x, b.y - a.y
    local outX, outY = c.x - b.x, c.y - b.y
    local cross = (inX * outY) - (inY * outX)
    local dot = (inX * outX) + (inY * outY)
    return math.deg(math.atan(cross, dot))
end

local function classifyTurn(angle)
    local magnitude = math.abs(angle)
    if magnitude < 12.0 then return 'straight' end

    local side = angle > 0 and 'left' or 'right'
    if magnitude < 40.0 then return 'slight-' .. side end
    if magnitude < 85.0 then return side end
    return 'hairpin-' .. side
end

--- What the next two corners look like, rally-style, so the driver can commit
--- to a line before the gate is on top of them.
local function paceNotes()
    local points = Race.track and Race.track.points
    if not points or #points < 2 then return nil end

    local count = #points
    local wraps = Race.track.circuit or Race.laps > 1

    local function at(index)
        if index <= count then return points[index] end
        if not wraps then return nil end
        return points[((index - 1) % count) + 1]
    end

    local coords = GetEntityCoords(cache.ped or PlayerPedId())
    local here = { x = coords.x, y = coords.y }
    local index = Checkpoints.index
    local a, b, c = at(index), at(index + 1), at(index + 2)

    return {
        now = (a and b) and classifyTurn(signedTurn(here, a, b)) or 'finish',
        next = (a and b and c) and classifyTurn(signedTurn(a, b, c)) or nil,
    }
end

local function hudPayload()
    local now = GetGameTimer()
    local elapsed = Race.startedAt > 0 and (now - Race.startedAt) or 0
    local lapElapsed = Race.lapStartedAt > 0 and (now - Race.lapStartedAt) or 0

    local position, total = 1, #Race.standings
    for index, entry in ipairs(Race.standings) do
        if entry.you then position = index break end
    end
    if total == 0 then total = 1 end

    local delta
    if Race.reference and Race.reference[Checkpoints.index - 1] and Race.splits[Checkpoints.index - 1] then
        delta = Race.splits[Checkpoints.index - 1] - Race.reference[Checkpoints.index - 1]
    end

    return {
        time = elapsed,
        lapTime = lapElapsed,
        bestLap = Race.bestLap,
        lap = Race.lap,
        laps = Race.laps,
        checkpoint = math.min(Checkpoints.index, #Race.track.points),
        checkpoints = #Race.track.points,
        position = position,
        total = total,
        distance = Checkpoints.DistanceToNext(),
        delta = delta,
        standings = Race.standings,
        speed = math.floor(GetEntitySpeed(cache.ped or PlayerPedId()) * 2.236936),
        finished = Race.finished,
        sectors = sectorTimes(),
        pace = paceNotes(),
        progress = math.floor((progressIndex() / math.max(1, Race.laps * #Race.track.points)) * 100),
    }
end

local function startHudLoop()
    CreateThread(function()
        while Race.active do
            UI.SetHud(true, hudPayload())
            Wait(80)
        end
        UI.SetHud(false)
    end)
end

-- ---------------------------------------------------------------- Safety rails

--- Returns racers to the last checkpoint if they wander far off route, and
--- Pause route recovery outside a usable driver seat; leaving is manual.
local function startWatchdog()
    CreateThread(function()
        while Race.active do
            local ped = cache.ped or PlayerPedId()

            local vehicle = GetVehiclePedIsIn(ped, false)
            if vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == ped and not IsEntityDead(vehicle) and not IsEntityDead(ped) then
                local distance = Checkpoints.DistanceToNext()
                if distance and distance > Config.Race.strayDistance then
                    Race.strayedAt = Race.strayedAt or GetGameTimer()
                    if GetGameTimer() - Race.strayedAt > Config.Race.strayGraceMs then
                        local target = Checkpoints.Current()
                        if target then
                            SetEntityCoords(vehicle, target.x, target.y, target.z + 1.0, false, false, false, false)
                            SetEntityHeading(vehicle, target.heading or 0.0)
                            SetVehicleOnGroundProperly(vehicle)
                            Bridge.Notify('Returned to the route.', 'inform')
                        end
                        Race.strayedAt = nil
                    end
                else
                    Race.strayedAt = nil
                end

            else
                Race.strayedAt = nil
            end
            Wait(500)
        end
    end)
end

-- ---------------------------------------------------------------- Race flow

local function onCheckpointHit(index)
    local elapsed = GetGameTimer() - Race.startedAt
    local lapElapsed = GetGameTimer() - Race.lapStartedAt
    Race.splits[index] = lapElapsed

    PlaySoundFrontend(-1, 'CHECKPOINT_NORMAL', 'HUD_MINI_GAME_SOUNDSET', true)

    local isLastCheckpoint = index == #Race.track.points

    if isLastCheckpoint then
        if not Race.bestLap or lapElapsed < Race.bestLap then
            Race.bestLap = lapElapsed
        end

        if Race.lap >= Race.laps then
            Race.Finish(elapsed)
            return
        end

        Race.lap = Race.lap + 1
        Race.lapStartedAt = GetGameTimer()
        Race.splits = {}
        Checkpoints.SetIndex(1)
        PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', true)
    end

    TriggerServerEvent('whip-racing:progress', Race.lobbyId, progressIndex(), elapsed)
end

--- Runs the pre-race countdown, then releases control and starts the clock.
local function runCountdown(seconds, onGo)
    local vehicle = GetVehiclePedIsIn(cache.ped or PlayerPedId(), false)
    if vehicle ~= 0 then
        FreezeEntityPosition(vehicle, true)
    end

    CreateThread(function()
        for count = seconds, 1, -1 do
            UI.Send('countdown', { value = count })
            PlaySoundFrontend(-1, '3_2_1', 'HUD_MINI_GAME_SOUNDSET', true)
            Wait(1000)
        end

        UI.Send('countdown', { value = 0 })
        PlaySoundFrontend(-1, 'GO', 'HUD_MINI_GAME_SOUNDSET', true)

        if vehicle ~= 0 then FreezeEntityPosition(vehicle, false) end
        onGo()

        Wait(1200)
        UI.Send('countdown', { value = nil })
    end)
end

function Race.Begin(payload)
    UI.Close()
    resetRaceState()

    Race.active = true
    Race.lobbyId = payload.lobbyId
    Race.track = payload.track
    Race.laps = payload.laps or 1
    Race.ghostMode = payload.ghostMode or 'none'
    Race.reference = payload.reference
    Race.finished = false

    local ped = cache.ped or PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle ~= 0 then
        Race.vehicleNetId = VehToNet(vehicle)
    end

    -- Drop the lobby preview first -- it owns the same props and the start-gate
    -- pin -- then build the race set, where the start gate streams like any
    -- other. Scenery is built locally from the stored list, so every racer sees
    -- the same barriers without any of it being networked.
    if DuiBeam then DuiBeam.Init() end
    Gates.HidePreview()
    Props.Spawn(Race.track.props)
    Gates.Start(Race.track.points, Race.track.circuit)

    startHudLoop()

    runCountdown(payload.countdown or Config.Race.countdownSeconds, function()
        Race.startedAt = GetGameTimer()
        Race.lapStartedAt = Race.startedAt

        Checkpoints.Start(Race.track.points, onCheckpointHit)
        Ghost.ApplyCollisionMode(Race.ghostMode, Race.startedAt)
        Ghost.StartRecording()

        if payload.ghostRun then
            Ghost.Play(payload.ghostRun.samples, payload.ghostRun.model)
        end

        startWatchdog()
    end)
end

function Race.Finish(totalMs)
    Race.finished = true
    Checkpoints.Stop()
    Ghost.ResetCollisions()
    Ghost.Clear()

    local samples = Ghost.StopRecording()
    local vehicle = GetVehiclePedIsIn(cache.ped or PlayerPedId(), false)
    local model = vehicle ~= 0 and GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)):lower() or nil

    -- Latent: the ghost recording (every 100 ms of the race) is far past what a plain net event
    -- may carry, and the event was refused outright ("Event can not be transmitted"), so the
    -- finish never reached the server. A latent event streams in the background at this many
    -- bytes a second and lands on the same server handler.
    TriggerLatentServerEvent('whip-racing:finish', 250000, Race.lobbyId, {
        time = totalMs,
        bestLap = Race.bestLap,
        splits = Race.splits,
        model = model,
        plate = vehicle ~= 0 and GetVehicleNumberPlateText(vehicle) or nil,
        ghost = samples,
    })

    PlaySoundFrontend(-1, 'RACE_PLACED', 'HUD_AWARDS', true)
end

--- Leaves the race without a finishing time.
function Race.Abandon(reason)
    if not Race.active then return end
    TriggerServerEvent('whip-racing:abandon', Race.lobbyId)
    Bridge.Notify(reason or 'You dropped out of the race.', 'error')
    Race.Cleanup()
end

function Race.Cleanup()
    SendNUIMessage({ event = 'raceActive', active = false })
    Checkpoints.Stop()
    Ghost.ResetCollisions()
    Ghost.Clear()
    Ghost.StopRecording()
    Props.Clear()
    Gates.HidePreview()
    if DuiBeam then DuiBeam.Release() end
    UI.SetHud(false)
    resetRaceState()
end

-- ---------------------------------------------------------------- Server events

RegisterNetEvent('whip-racing:start', function(payload)
    Race.Begin(payload)
end)

RegisterNetEvent('whip-racing:standings', function(standings)
    Race.standings = standings or {}
end)

RegisterNetEvent('whip-racing:lobby', function(lobby)
    UI.Send('lobby', lobby)

    -- Push it into the tablet too. Its race screen reads whatever is already
    -- in the store on the way in and only fetches afterwards, so keeping this
    -- current is what makes the screen right on arrival rather than a frame
    -- later.
    Tablet.PushRace(lobby)

    -- Stand the start gate up as soon as someone is in a lobby, so the whole
    -- grid can find where the race actually begins before it does.
    if Race.active then return end

    if not lobby or not lobby.trackId then
        Gates.HidePreview()
        return
    end

    local track = lib.callback.await('whip-racing:getTrack', false, lobby.trackId)
    if track then Gates.ShowPreview(lobby.trackId, track) end
end)

--- Results no longer take over the screen the moment you cross the line. They
--- are written to the race log and read back from the tablet under Recent
--- Races, so nobody is stuck reading a scoreboard while still rolling.
---
--- What is left here is a one-line summary and a pointer to where the detail
--- lives.
RegisterNetEvent('whip-racing:results', function(results)
    Race.Cleanup()
    UI.Send('lobby', nil)

    local mine
    for _, row in ipairs(results.rows or {}) do
        if row.you or (Tablet.identity and row.citizenid == Tablet.identity.stateId) then
            mine = row
            break
        end
    end

    if mine and mine.place then
        Bridge.Notify(('Finished %s of %d at %s. Results are in the racing tablet.')
            :format(Bridge.Ordinal(mine.place), #(results.rows or {}), results.trackName or 'the track'),
            'success')
    else
        Bridge.Notify('Race over. Results are in the racing tablet.', 'inform')
    end
end)

RegisterNetEvent('whip-racing:cancelled', function(reason)
    if Race.active then
        Bridge.Notify(reason or 'The race was cancelled.', 'error')
        Race.Cleanup()
    end
    UI.Send('lobby', nil)
end)

-- ---------------------------------------------------------------- Menu

Bridge.RegisterCommand('tablet', Config.Command, function()
    if Tablet.open then Tablet.Close() else Tablet.Open() end
end, false)
if Bridge.CommandEnabled('tablet') then
    RegisterKeyMapping(Config.Command, 'Open racing menu', 'keyboard', '')
end

-- ---------------------------------------------------------------- NUI callbacks

RegisterNUICallback('menu:refresh', function(_, cb)
    cb(lib.callback.await('whip-racing:getMenu', false) or {})
end)

RegisterNUICallback('lobby:create', function(data, cb)
    local vehicle = GetVehiclePedIsIn(cache.ped or PlayerPedId(), false)
    local plate = vehicle ~= 0 and GetVehicleNumberPlateText(vehicle) or nil

    local ok, message, lobby = lib.callback.await('whip-racing:createLobby', false, {
        trackId = data.trackId,
        laps = tonumber(data.laps) or 1,
        buyin = tonumber(data.buyin) or 0,
        pinkSlip = data.pinkSlip and true or false,
        ghostMode = data.ghostMode or 'none',
        maxPlayers = tonumber(data.maxPlayers) or Config.Race.maxPlayers,
        raceGhost = data.raceGhost and true or false,
        plate = plate,
    })

    Bridge.Notify(message, ok and 'success' or 'error')
    cb({ ok = ok, lobby = lobby })
end)

RegisterNUICallback('lobby:join', function(data, cb)
    local vehicle = GetVehiclePedIsIn(cache.ped or PlayerPedId(), false)
    if vehicle == 0 then
        Bridge.Notify('Get in a vehicle before joining.', 'error')
        return cb({ ok = false })
    end

    local class = GetVehicleClass(vehicle)
    if #Config.AllowedClasses > 0 then
        local allowed = false
        for _, entry in ipairs(Config.AllowedClasses) do
            if entry == class then allowed = true break end
        end
        if not allowed then
            Bridge.Notify('That vehicle class is not allowed.', 'error')
            return cb({ ok = false })
        end
    end

    local ok, message, lobby = lib.callback.await('whip-racing:joinLobby', false, {
        lobbyId = data.lobbyId,
        plate = GetVehicleNumberPlateText(vehicle),
        model = GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)):lower(),
        class = class,
    })

    Bridge.Notify(message, ok and 'success' or 'error')
    cb({ ok = ok, lobby = lobby })
end)

RegisterNUICallback('lobby:leave', function(data, cb)
    local ok, message = lib.callback.await('whip-racing:leaveLobby', false, data.lobbyId)
    Bridge.Notify(message, ok and 'success' or 'inform')
    cb({ ok = ok })
end)

RegisterNUICallback('lobby:start', function(data, cb)
    local ok, message = lib.callback.await('whip-racing:startLobby', false, data.lobbyId)
    if not ok then Bridge.Notify(message, 'error') end
    cb({ ok = ok })
end)

--- Drops a GPS route to the track's start line so players can drive out to it.
RegisterNUICallback('track:waypoint', function(data, cb)
    local track = lib.callback.await('whip-racing:getTrack', false, data.trackId)
    local start = track and track.points and track.points[1]

    if not start then
        Bridge.Notify('That track no longer exists.', 'error')
        return cb({ ok = false })
    end

    SetNewWaypoint(start.x + 0.0, start.y + 0.0)
    Bridge.Notify(('Route set to "%s".'):format(track.name), 'success')
    cb({ ok = true })
end)

--- Just the coordinates, for drawing the route on the tablet's map. The menu
--- list deliberately omits them to keep its payload small.
RegisterNUICallback('track:route', function(data, cb)
    local track = lib.callback.await('whip-racing:getTrack', false, data.trackId)
    if not track then return cb({}) end

    local route = {}
    for index, point in ipairs(track.points) do
        route[index] = { x = point.x, y = point.y }
    end

    cb(route)
end)

RegisterNUICallback('track:records', function(data, cb)
    cb(lib.callback.await('whip-racing:getRecords', false, data.trackId) or {})
end)

RegisterNUICallback('track:delete', function(data, cb)
    local ok, message = lib.callback.await('whip-racing:deleteTrack', false, data.trackId)
    Bridge.Notify(message, ok and 'success' or 'error')
    cb({ ok = ok })
end)

RegisterNUICallback('track:edit', function(data, cb)
    local track = lib.callback.await('whip-racing:getTrack', false, data.trackId)
    if not track then
        Bridge.Notify('That track no longer exists.', 'error')
        return cb({ ok = false })
    end
    UI.Close()
    Creator.Start(track.points, {
        id = track.id,
        name = track.name,
        circuit = track.circuit,
        published = track.published,
        props = track.props,
    })
    cb({ ok = true })
end)

RegisterNUICallback('race:quit', function(_, cb)
    Race.Abandon('You left the race.')
    cb('ok')
end)

-- ---------------------------------------------------------------- Teardown

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Checkpoints.Stop()
    Ghost.Clear()
    Ghost.ResetCollisions()
    Props.Clear()
    Gates.Clear()
end)
