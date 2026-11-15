Checkpoints = {
    active = nil,      -- list of { x, y, z, radius, heading }
    index = 1,         -- 1-based index of the checkpoint currently being chased
    blips = {},
    marker = nil,
    running = false,
    onHit = nil,       -- callback(index, coords)
}

local function hexToRgb(hex)
    hex = hex:gsub('#', '')
    return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

local ACCENT_R, ACCENT_G, ACCENT_B = hexToRgb(Config.Colors.accent)
local LIGHT_R, LIGHT_G, LIGHT_B = hexToRgb(Config.Colors.accentLight)

local function clearBlips()
    for _, blip in ipairs(Checkpoints.blips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
    Checkpoints.blips = {}
end

--- Draws the route blip for the current checkpoint and a faded one for the next.
local function refreshBlips()
    clearBlips()
    if not Checkpoints.active then return end

    local current = Checkpoints.active[Checkpoints.index]
    if not current then return end

    local isFinal = Checkpoints.index == #Checkpoints.active
    local style = isFinal and Config.Blips.startFinish or Config.Blips.checkpoint

    local blip = AddBlipForCoord(current.x, current.y, current.z)
    SetBlipSprite(blip, style.sprite)
    SetBlipColour(blip, style.colour)
    SetBlipScale(blip, style.scale)
    SetBlipAsShortRange(blip, false)
    SetBlipRoute(blip, true)
    SetBlipRouteColour(blip, style.colour)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(isFinal and 'Finish' or ('Checkpoint %d'):format(Checkpoints.index))
    EndTextCommandSetBlipName(blip)
    Checkpoints.blips[#Checkpoints.blips + 1] = blip

    local upcoming = Checkpoints.active[Checkpoints.index + 1]
    if upcoming then
        local hint = AddBlipForCoord(upcoming.x, upcoming.y, upcoming.z)
        SetBlipSprite(hint, Config.Blips.checkpoint.sprite)
        SetBlipColour(hint, Config.Blips.checkpoint.colour)
        SetBlipScale(hint, 0.5)
        SetBlipAlpha(hint, 120)
        SetBlipAsShortRange(hint, true)
        Checkpoints.blips[#Checkpoints.blips + 1] = hint
    end
end

-- --------------------------------------------------------------- Gate beams
--
-- Every beam is issued by the engine in the same frame as the world, so none of
-- it can trail the camera and all of it is depth tested for free.
--
-- The preferred form is a browser surface drawn as a 3D scaleform (see
-- client/duibeam.lua), which keeps HTML typography without the lag a
-- screen-space page has. Gates with no surface fall back to a plain marker
-- column, which shows where the gate is but not how far.

local BEAM_R, BEAM_G, BEAM_B = hexToRgb(Config.Colors.beam)
local LIVE_R, LIVE_G, LIVE_B = hexToRgb(Config.Colors.beamActive)

--- The plain column, used when no browser surface is available for this gate.
local function drawMarkerBeam(gate, isTarget)
    local cfg = Config.Checkpoints
    local r, g, b = BEAM_R, BEAM_G, BEAM_B
    if isTarget then r, g, b = LIVE_R, LIVE_G, LIVE_B end

    DrawMarker(1, gate.x, gate.y, gate.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        cfg.beamRadius * 2.0, cfg.beamRadius * 2.0, cfg.beamHeight,
        r, g, b, isTarget and 200 or 120, false, false, 2, false, nil, nil, false)
end

--- Draws a gate, preferring the browser surface and falling back to the marker.
--- `slot` is which of the DUI surfaces this gate may use.
local function drawBeam(slot, gate, index, isTarget, isFinal)
    local state = isFinal and 'final' or (isTarget and 'target' or '')
    local label = isFinal and 'Finish' or ('Checkpoint %d'):format(index)

    if DuiBeam and DuiBeam.Draw(slot, gate, label, state) then return true end

    drawMarkerBeam(gate, isTarget)
    return false
end

--- Distance from the player to the checkpoint being chased, or nil when idle.
function Checkpoints.DistanceToNext()
    if not Checkpoints.running or not Checkpoints.active then return nil end
    local target = Checkpoints.active[Checkpoints.index]
    if not target then return nil end
    local ped = cache.ped or PlayerPedId()
    local coords = GetEntityCoords(ped)
    return #(coords - vec3(target.x, target.y, target.z))
end

function Checkpoints.Current()
    if not Checkpoints.active then return nil end
    return Checkpoints.active[Checkpoints.index]
end

--- Starts chasing a route. `onHit` fires each time a checkpoint is entered.
function Checkpoints.Start(list, onHit)
    Checkpoints.active = list
    Checkpoints.index = 1
    Checkpoints.onHit = onHit
    Checkpoints.running = true
    refreshBlips()

    CreateThread(function()
        while Checkpoints.running do
            local wait = 250
            local list = Checkpoints.active
            local target = list and list[Checkpoints.index]

            if target then
                local cfg = Config.Checkpoints
                local ped = cache.ped or PlayerPedId()
                local coords = GetEntityCoords(ped)
                local distance = #(coords - vec3(target.x, target.y, target.z))

                if distance < cfg.beamDistance then
                    -- Markers have to be issued every frame, and drawing in the
                    -- same frame as the world is the whole point: no projection,
                    -- no interface round trip, nothing to lag behind the camera.
                    wait = 0

                    local last = math.min(#list, Checkpoints.index + cfg.beamCount - 1)

                    -- Drawn far to near, so the gate being chased lands on top.
                    for index = last, Checkpoints.index, -1 do
                        local gate = list[index]
                        local slot = index - Checkpoints.index + 1
                        local isTarget = index == Checkpoints.index

                        drawBeam(slot, gate, index, isTarget, index == #list)
                    end
                end

                -- Crossing the gate is checked whatever the beam is doing, so
                -- draw range and hit detection can never drift apart.
                local radius = target.radius or cfg.defaultRadius

                local ped = cache.ped or PlayerPedId()
                local vehicle = GetVehiclePedIsIn(ped, false)
                if distance <= radius and vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == ped and not IsEntityDead(ped) and not IsEntityDead(vehicle) then
                    local hitIndex = Checkpoints.index
                    Checkpoints.index = hitIndex + 1
                    if Checkpoints.onHit then
                        Checkpoints.onHit(hitIndex, vec3(target.x, target.y, target.z))
                    end
                    if Checkpoints.running then refreshBlips() end
                end
            end

            Wait(wait)
        end
    end)
end

--- Rewinds to a specific checkpoint, used for lap rollover and stray recovery.
function Checkpoints.SetIndex(index)
    Checkpoints.index = index
    if Checkpoints.running then refreshBlips() end
end

function Checkpoints.Stop()
    Checkpoints.running = false
    Checkpoints.active = nil
    Checkpoints.onHit = nil
    Checkpoints.index = 1
    clearBlips()
end

--- Standalone preview used by the track editor: draws every checkpoint at once.
function Checkpoints.DrawPreview(list, highlightIndex)
    for index, point in ipairs(list) do
        local ped = cache.ped or PlayerPedId()
        local distance = #(GetEntityCoords(ped) - vec3(point.x, point.y, point.z))
        if distance < Config.Checkpoints.drawDistance then
            local radius = point.radius or Config.Checkpoints.defaultRadius
            local r, g, b = ACCENT_R, ACCENT_G, ACCENT_B
            local alpha = 90

            if index == highlightIndex then
                r, g, b, alpha = LIGHT_R, LIGHT_G, LIGHT_B, 170
            end

            DrawMarker(1, point.x, point.y, point.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                radius * 2.0, radius * 2.0, 1.6, r, g, b, alpha, false, false, 2, false, nil, nil, false)

            if distance < 120.0 then
                local onScreen, screenX, screenY = World3dToScreen2d(point.x, point.y, point.z + 2.0)
                if onScreen then
                    SetTextScale(0.34, 0.34)
                    SetTextFont(4)
                    SetTextColour(255, 255, 255, 220)
                    SetTextCentre(true)
                    SetTextOutline()
                    BeginTextCommandDisplayText('STRING')
                    AddTextComponentSubstringPlayerName(tostring(index))
                    EndTextCommandDisplayText(screenX, screenY)
                end
            end
        end
    end
end
