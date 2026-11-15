Ghost = {
    recording = false,
    samples = {},
    entity = nil,
    playing = false,
}

--- Starts sampling the local player's vehicle so the run can be replayed later.
function Ghost.StartRecording()
    if not Config.Ghost.enabled then return end
    Ghost.samples = {}
    Ghost.recording = true

    CreateThread(function()
        local startedAt = GetGameTimer()
        while Ghost.recording do
            local vehicle = GetVehiclePedIsIn(cache.ped or PlayerPedId(), false)
            if vehicle ~= 0 then
                local coords = GetEntityCoords(vehicle)
                local rotation = GetEntityRotation(vehicle, 2)
                Ghost.samples[#Ghost.samples + 1] = {
                    t = GetGameTimer() - startedAt,
                    x = math.floor(coords.x * 100) / 100,
                    y = math.floor(coords.y * 100) / 100,
                    z = math.floor(coords.z * 100) / 100,
                    h = math.floor(rotation.z * 10) / 10,
                    p = math.floor(rotation.x * 10) / 10,
                    r = math.floor(rotation.y * 10) / 10,
                }
                if #Ghost.samples >= Config.Ghost.maxSamples then
                    Ghost.recording = false
                end
            end
            Wait(Config.Ghost.sampleMs)
        end
    end)
end

--- Stops sampling and hands back the recorded run, or nil if nothing usable.
function Ghost.StopRecording()
    Ghost.recording = false
    if #Ghost.samples < 2 then return nil end
    return Ghost.samples
end

--- Tells the engine to ignore the ghost against every vehicle currently
--- streamed in, in both directions.
---
--- SetEntityCollision alone stops the ghost being *pushed*, but the game still
--- resolves the overlap when the ghost is warped inside another car -- and it
--- resolves it by removing the car. Pairing the two entities explicitly is what
--- makes the ghost pass through instead.
---
--- Cars stream in and out constantly, so this is re-run periodically rather
--- than once at spawn.
local function phaseThroughTraffic(entity)
    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if vehicle ~= entity and DoesEntityExist(vehicle) then
            SetEntityNoCollisionEntity(entity, vehicle, false)
            SetEntityNoCollisionEntity(vehicle, entity, false)
        end
    end
end

--- Replays a recorded run alongside the player as a translucent, non-solid car.
function Ghost.Play(samples, model)
    if not samples or #samples < 2 then return end

    local hash = tonumber(model) or joaat(model or 'adder')
    lib.requestModel(hash, 10000)

    local first = samples[1]
    local entity = CreateVehicle(hash, first.x, first.y, first.z, first.h, false, false)
    SetModelAsNoLongerNeeded(hash)

    SetEntityAlpha(entity, Config.Ghost.alpha, false)
    SetEntityCollision(entity, false, false)
    -- The thorough form: no collision *and* no physics, so the ghost cannot
    -- displace anything it is warped into.
    SetEntityCompletelyDisableCollision(entity, false, false)
    -- Keep it out of the population manager's reasoning about occupied space,
    -- which is what evicts a parked car the ghost is standing in.
    SetVehicleIsConsideredByPlayer(entity, false)
    SetEntityInvincible(entity, true)
    SetVehicleEngineOn(entity, true, true, false)
    SetEntityCanBeDamaged(entity, false)
    FreezeEntityPosition(entity, true)
    SetVehicleDoorsLocked(entity, 4)
    SetEntityAsMissionEntity(entity, true, true)

    phaseThroughTraffic(entity)

    Ghost.entity = entity
    Ghost.playing = true

    CreateThread(function()
        local startedAt = GetGameTimer()
        local index = 1
        local lastPairing = 0

        while Ghost.playing and DoesEntityExist(entity) do
            local elapsed = GetGameTimer() - startedAt

            -- Advance to the sample pair bracketing the current time.
            while samples[index + 1] and samples[index + 1].t < elapsed do
                index = index + 1
            end

            local from = samples[index]
            local to = samples[index + 1]

            if not to then break end

            local span = to.t - from.t
            local alpha = span > 0 and math.min((elapsed - from.t) / span, 1.0) or 0.0

            local x = from.x + (to.x - from.x) * alpha
            local y = from.y + (to.y - from.y) * alpha
            local z = from.z + (to.z - from.z) * alpha

            -- Interpolate heading the short way around the circle.
            local deltaH = ((to.h - from.h + 180) % 360) - 180
            local heading = from.h + deltaH * alpha

            SetEntityCoordsNoOffset(entity, x, y, z, false, false, false)
            SetEntityRotation(entity, from.p, from.r, heading, 2, true)

            -- Traffic the ghost has not met yet needs pairing before it
            -- reaches it. Four times a second is well ahead of race speed and
            -- cheap enough not to matter.
            if GetGameTimer() - lastPairing > 250 then
                lastPairing = GetGameTimer()
                phaseThroughTraffic(entity)
            end

            Wait(0)
        end

        Ghost.Clear()
    end)
end

function Ghost.Clear()
    Ghost.playing = false
    if Ghost.entity and DoesEntityExist(Ghost.entity) then
        DeleteEntity(Ghost.entity)
    end
    Ghost.entity = nil
end

--- Applies racer-vs-racer collision rules for the configured ghost window.
--- `seconds` of -1 means ghosted for the whole race.
function Ghost.ApplyCollisionMode(mode, raceStartedAt)
    local setting
    for _, entry in ipairs(Config.GhostModes) do
        if entry.id == mode then setting = entry break end
    end
    if not setting or setting.seconds == 0 then return end

    Ghost.ghosting = true

    CreateThread(function()
        local lastAlphaPass = 0

        while Ghost.ghosting do
            local elapsed = (GetGameTimer() - raceStartedAt) / 1000
            if setting.seconds >= 0 and elapsed > setting.seconds then break end

            local ped = cache.ped or PlayerPedId()
            local myVehicle = GetVehiclePedIsIn(ped, false)

            if myVehicle ~= 0 then
                local refreshAlpha = GetGameTimer() - lastAlphaPass > 500
                if refreshAlpha then lastAlphaPass = GetGameTimer() end

                for _, playerId in ipairs(GetActivePlayers()) do
                    local otherPed = GetPlayerPed(playerId)
                    if otherPed ~= ped then
                        local otherVehicle = GetVehiclePedIsIn(otherPed, false)
                        if otherVehicle ~= 0 then
                            -- `true` = this frame only, so the loop must re-assert it
                            -- every tick. Stopping the loop restores solid collision.
                            SetEntityNoCollisionEntity(myVehicle, otherVehicle, true)
                            if refreshAlpha then
                                SetEntityAlpha(otherVehicle, Config.Ghost.alpha, false)
                            end
                        end
                    end
                end
            end

            Wait(0)
        end

        Ghost.ghosting = false
        Ghost.ResetCollisions()
    end)
end

function Ghost.ResetCollisions()
    Ghost.ghosting = false
    for _, playerId in ipairs(GetActivePlayers()) do
        local vehicle = GetVehiclePedIsIn(GetPlayerPed(playerId), false)
        if vehicle ~= 0 then ResetEntityAlpha(vehicle) end
    end
end
