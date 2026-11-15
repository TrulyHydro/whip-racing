-- Gate markers: road flares or custom props on both sides of each checkpoint.
--
-- They stream: only gates within Config.Gates.streamDistance are standing at
-- any moment, because a long track can be well over a hundred checkpoints and
-- spawning both sides of all of them at once would be hundreds of objects.

Gates = {
    points = nil,     -- the checkpoint list being marked
    circuit = false,
    running = false,
    pinFirst = false, -- keep the start gate up regardless of distance
    spawned = {},     -- [index] = { left = handle, right = handle }
    preview = { blip = nil, trackId = nil },
}

local function clearStartBlip()
    if Gates.preview.blip and DoesBlipExist(Gates.preview.blip) then
        RemoveBlip(Gates.preview.blip)
    end
    Gates.preview.blip = nil
    Gates.preview.trackId = nil
end

--- Heading, in GTA's convention, of the route as it passes through `index`.
local function routeHeading(points, index, circuit)
    local from = points[index]
    local to = points[index + 1] or (circuit and points[1]) or nil

    -- The last gate of a sprint has nothing ahead of it, so it takes its
    -- direction from the leg that arrives at it instead.
    if not to then
        to = from
        from = points[index - 1] or from
    end

    local dx, dy = to.x - from.x, to.y - from.y
    if dx == 0.0 and dy == 0.0 then return 0.0, 0.0, 1.0 end

    local length = math.sqrt(dx * dx + dy * dy)
    local fx, fy = dx / length, dy / length

    return math.deg(math.atan(-fx, fy)) % 360.0, fx, fy
end

--- True only when a track's first and last gate sit on the same spot, in which
--- case the start markers would stand inside the finish ones. Measured, not
--- inferred from the circuit flag: most circuits finish some way from where
--- they started.
local function closesOnItself(points)
    if #points < 2 then return false end

    local first, last = points[1], points[#points]
    local gap = math.sqrt((last.x - first.x) ^ 2 + (last.y - first.y) ^ 2)

    return gap <= Config.Gates.collapseDistance
end

--- Shared by placed gates and the editor preview.
function Gates.MarkerModel()
    if Config.Gates.checkpointprop == 'prop' then return Config.Gates.prop end
    return 'w_am_flare'
end

local effects = {} -- [entity] = { handle, retryAt }
local warned = {}

local function warnOnce(key, message)
    if warned[key] then return end
    warned[key] = true
    print('[whip-racing] ' .. message)
end

function Gates.AttachFlare(object)
    if Config.Gates.checkpointprop ~= 'flares' or not object or object == 0 then return end
    if DoesEntityExist(object) and not effects[object] then
        effects[object] = { retryAt = 0 }
    end
end

function Gates.RemoveMarker(object)
    if not object then return end
    local effect = effects[object]
    if effect and effect.handle then StopParticleFxLooped(effect.handle, false) end
    effects[object] = nil
    if DoesEntityExist(object) then DeleteEntity(object) end
end

-- Actual ground-flare particles. No sphere markers or simulated flare lights.
-- Use the stock flare appearance; only its size is configurable.
CreateThread(function()
    while true do
        local cfg = Config.Gates.flare
        local asset = 'core'
        if next(effects) then
            if not HasNamedPtfxAssetLoaded(asset) then RequestNamedPtfxAsset(asset) end
            for object, state in pairs(effects) do
                if not DoesEntityExist(object) then
                    Gates.RemoveMarker(object)
                elseif HasNamedPtfxAssetLoaded(asset) and GetGameTimer() >= state.retryAt then
                    if not state.handle or not DoesParticleFxLoopedExist(state.handle) then
                        state.retryAt = GetGameTimer() + 2000
                        UseParticleFxAssetNextCall(asset)
                        local handle = StartParticleFxLoopedOnEntity('exp_grd_flare', object,
                            0.0, 0.0, 0.08, 0.0, 0.0, 0.0,
                            cfg.scale or 1.0, false, false, false)
                        if handle and handle ~= 0 then
                            state.handle = handle
                            SetParticleFxLoopedAlpha(handle, 1.0)

                        else
                            warnOnce(asset, 'Stock checkpoint flare particle failed to start.')
                        end
                    end
                end
            end
        end
        Wait(500)
    end
end)

local function modelFor(points, index)
    if index == 1 and #points > 1 and closesOnItself(points) then return nil end
    return Gates.MarkerModel()
end

--- Half the width of the gate: the checkpoint radius, clamped so a very tight
--- or very wide gate still reads properly.
local function halfWidth(point)
    local cfg = Config.Gates
    local radius = (point.radius or Config.Checkpoints.defaultRadius) + cfg.sideOffset
    return math.max(cfg.minHalfWidth, math.min(cfg.maxHalfWidth, radius))
end

local function spawnOne(model, x, y, z, heading)
    local hash = Props.LoadModel(model)
    if not hash then
        warnOnce(tostring(model), ('Could not load checkpoint model "%s".'):format(tostring(model)))
        return nil
    end

    local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 3.0, false)
    local object = CreateObject(hash, x, y, (found and groundZ or z) + Config.Gates.zOffset, false, false, false)

    if object == 0 then
        SetModelAsNoLongerNeeded(hash)
        return nil
    end

    SetEntityHeading(object, heading % 360.0)
    FreezeEntityPosition(object, true)
    SetEntityInvincible(object, true)
    -- Markers flank the road rather than block it, and a racer clipping one at
    -- speed should not end their run.
    SetEntityCollision(object, false, false)
    SetModelAsNoLongerNeeded(hash)

    Gates.AttachFlare(object)
    return object
end

local function spawnGate(index)
    local existing = Gates.spawned[index]
    if existing then
        Gates.AttachFlare(existing.left)
        Gates.AttachFlare(existing.right)
        if existing.left and existing.right and DoesEntityExist(existing.left) and DoesEntityExist(existing.right) then return end
        Gates.RemoveMarker(existing.left)
        Gates.RemoveMarker(existing.right)
        Gates.spawned[index] = nil
    end

    local points = Gates.points
    local point = points[index]
    if not point then return end

    local cfg = Config.Gates
    local heading, fx, fy = routeHeading(points, index, Gates.circuit)

    -- The route line cuts corners: on a bend it can sit 45 degrees off the way
    -- the driver actually goes through the gate, which stands the posts across
    -- the road rather than either side of it. A checkpoint dropped in the
    -- editor records the heading the car was facing, and that is the better
    -- answer whenever it is there. Imported gates fall through to the route
    -- line here and are corrected by their stored axis below.
    if point.heading and not (point.axisX and point.axisY) then
        heading = point.heading % 360.0
        local radians = math.rad(heading)
        fx, fy = -math.sin(radians), math.cos(radians)
    end

    local offset = halfWidth(point)

    -- Left of travel is the forward vector turned a quarter turn. Imported
    -- gates carry the axis their author actually used, which is often angled
    -- rather than square to the route, so it wins when it is there.
    local lx, ly = -fy, fx

    if point.axisX and point.axisY then
        lx, ly = point.axisX, point.axisY
        -- Keep "left" on the left: flip the stored axis if it points the other
        -- way, so start banners and signage do not swap sides mid-track.
        if (lx * -fy) + (ly * fx) < 0 then lx, ly = -lx, -ly end
    end

    local model = modelFor(points, index)
    if not model then return end

    local rightHeading = heading + cfg.headingOffset
    if cfg.mirrorRight then rightHeading = rightHeading + 180.0 end

    Gates.spawned[index] = {
        left = spawnOne(model, point.x + lx * offset, point.y + ly * offset, point.z, heading + cfg.headingOffset),
        right = spawnOne(model, point.x - lx * offset, point.y - ly * offset, point.z, rightHeading),
    }
end

local function despawnGate(index)
    local gate = Gates.spawned[index]
    if not gate then return end

    for _, handle in pairs(gate) do
        Gates.RemoveMarker(handle)
    end

    Gates.spawned[index] = nil
end

function Gates.Clear()
    for index in pairs(Gates.spawned) do despawnGate(index) end
    Gates.spawned = {}
end

--- Drops everything so the next stream pass rebuilds from the current list.
--- Called whenever the editor changes a checkpoint.
function Gates.Refresh()
    if not Gates.running then return end
    Gates.Clear()
end

--- `pinFirst` keeps the start gate standing no matter how far away it is, so a
--- lobby waiting across the map can still see where the grid is.
function Gates.Start(points, circuit, pinFirst)
    if not Config.Gates.enabled then return end

    Gates.points = points
    Gates.circuit = circuit and true or false
    Gates.pinFirst = pinFirst and true or false
    Gates.Clear()

    if Gates.running then return end
    Gates.running = true

    CreateThread(function()
        while Gates.running do
            local points = Gates.points

            if points then
                local coords = GetEntityCoords(cache.ped or PlayerPedId())
                local range = Config.Gates.streamDistance

                for index = 1, #points do
                    local point = points[index]
                    local distance = #(coords - vec3(point.x, point.y, point.z))

                    if distance <= range or (index == 1 and Gates.pinFirst) then
                        spawnGate(index)
                    elseif Gates.spawned[index] then
                        -- Hysteresis, so a gate sitting exactly on the boundary
                        -- does not thrash in and out as the car moves.
                        if distance > range * 1.15 then despawnGate(index) end
                    end
                end
            end

            Wait(500)
        end
    end)
end

function Gates.Stop()
    Gates.running = false
    Gates.points = nil
    Gates.pinFirst = false
    Gates.Clear()
    clearStartBlip()
end

-- ----------------------------------------------------------- Lobby preview
--
-- Between joining a lobby and the countdown, the track is dressed exactly as it
-- will be during the race: scenery props up, gate markers streaming, and the
-- start gate pinned so it stands even from across the map. A blip and GPS route
-- point at the grid so the whole lobby can find it.

--- Tears the preview down. The race sets the track up again without the pin,
--- so the start gate goes back to streaming like every other gate.
function Gates.HidePreview()
    Gates.Stop()
    Props.Clear()
end

function Gates.ShowPreview(trackId, track)
    if not Config.Gates.enabled or not Config.Gates.previewStart then return end
    if not track or not track.points or #track.points == 0 then return end

    -- Lobby pushes repeat on every roster change; only rebuild on a new track.
    if Gates.preview.trackId == trackId then return end

    clearStartBlip()
    Gates.preview.trackId = trackId

    Props.Spawn(track.props)
    Gates.Start(track.points, track.circuit, true)

    local point = track.points[1]
    local blip = AddBlipForCoord(point.x, point.y, point.z)
    SetBlipSprite(blip, Config.Blips.startFinish.sprite)
    SetBlipColour(blip, Config.Blips.startFinish.colour)
    SetBlipScale(blip, Config.Blips.startFinish.scale)
    SetBlipAsShortRange(blip, false)
    SetBlipRoute(blip, true)
    SetBlipRouteColour(blip, Config.Blips.startFinish.colour)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName('Race start')
    EndTextCommandSetBlipName(blip)

    Gates.preview.blip = blip
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Gates.Clear()
    for object in pairs(effects) do Gates.RemoveMarker(object) end
    clearStartBlip()
end)
