-- The gate beam as a browser surface drawn into the world.
--
-- A page shown through ui_page is composited separately from the game, so
-- anything pinned to a projected world point arrives a frame or two late and
-- smears when the camera turns. A DUI is different: the page is rendered to a
-- texture, and that texture is drawn by the engine as a 3D scaleform in the
-- same frame as the world. Same HTML and CSS, none of the lag.
--
-- The numbers below are not guesses. They match a working implementation, and
-- several of them are load-bearing in ways that are not obvious:
--
--   * The movie is always a streamed `generic_texture_renderer_<n>`. One
--     scaleform instance holds one texture, so each simultaneous beam needs its
--     own copy of the .gfx under its own name.
--   * SET_TEXTURE takes the texture region after the two names -- 0, 0, width,
--     height -- not a single flag. Passing one int leaves the texture unmapped
--     and nothing draws.
--   * The DUI needs a moment to paint after it reports available; grabbing its
--     handle immediately yields an empty texture.
--   * The size arguments are not metres. 1.0 is roughly ten metres across,
--     which is why the values here are small and the quad is nudged sideways to
--     centre it on the gate.

DuiBeam = {
    slots = {},
    booting = false,
}

local function buildSlot(slot)
    local cfg = Config.Checkpoints.dui
    local movie = ('generic_texture_renderer_%d'):format(slot)

    local scaleform = RequestScaleformMovie(movie)
    local deadline = GetGameTimer() + 5000

    while not HasScaleformMovieLoaded(scaleform) and GetGameTimer() < deadline do
        Wait(0)
    end

    if not HasScaleformMovieLoaded(scaleform) then
        print(('[whip-racing] scaleform "%s" did not load. Is %s.gfx in stream/? Beam %d falls back to a marker column.')
            :format(movie, movie, slot))
        return nil
    end

    local dui = CreateDui(('nui://%s/web/dui/index.html'):format(GetCurrentResourceName()), cfg.width, cfg.height)

    deadline = GetGameTimer() + 10000
    while not IsDuiAvailable(dui) and GetGameTimer() < deadline do Wait(50) end

    if not IsDuiAvailable(dui) then
        print(('[whip-racing] the beam page never became available for slot %d'):format(slot))
        DestroyDui(dui)
        SetScaleformMovieAsNoLongerNeeded(scaleform)
        return nil
    end

    -- Available is not the same as painted. Taking the handle too early binds a
    -- blank texture that never recovers.
    Wait(cfg.paintDelay)

    local txdName = ('whip_racing_beam_txd_%d'):format(slot)
    local txnName = ('whip_racing_beam_txn_%d'):format(slot)

    local txd = CreateRuntimeTxd(txdName)
    CreateRuntimeTextureFromDuiHandle(txd, txnName, GetDuiHandle(dui))

    BeginScaleformMovieMethod(scaleform, 'SET_TEXTURE')
    ScaleformMovieMethodAddParamTextureNameString(txdName)
    ScaleformMovieMethodAddParamTextureNameString(txnName)
    ScaleformMovieMethodAddParamInt(0)
    ScaleformMovieMethodAddParamInt(0)
    ScaleformMovieMethodAddParamInt(cfg.width)
    ScaleformMovieMethodAddParamInt(cfg.height)
    EndScaleformMovieMethod()

    return { dui = dui, scaleform = scaleform, distance = nil, label = nil, state = nil }
end

--- Builds the surfaces in the background. Until they are ready every gate draws
--- with the marker fallback, so a race never waits on this.
function DuiBeam.Init()
    local cfg = Config.Checkpoints.dui
    if not cfg.enabled or DuiBeam.booting or #DuiBeam.slots > 0 then return end

    DuiBeam.booting = true

    CreateThread(function()
        for slot = 1, math.max(1, cfg.slots) do
            local built = buildSlot(slot)
            if not built then break end
            DuiBeam.slots[slot] = built
        end

        DuiBeam.booting = false
    end)
end

function DuiBeam.Release()
    for _, slot in ipairs(DuiBeam.slots) do
        if slot.scaleform then SetScaleformMovieAsNoLongerNeeded(slot.scaleform) end
        if slot.dui then DestroyDui(slot.dui) end
    end

    DuiBeam.slots = {}
end

--- Draws one gate. Returns false when the slot is not ready, so the caller can
--- fall back to the marker column.
function DuiBeam.Draw(slot, gate, label, state)
    local surface = DuiBeam.slots[slot]
    if not surface then return false end

    local cfg = Config.Checkpoints.dui

    -- Measured from the camera rather than the car, because it is the camera
    -- the billboard is sized and turned for.
    local camera = GetFinalRenderedCamCoord()
    local away = vec2(camera.x - gate.x, camera.y - gate.y)
    local distance = #away
    if distance <= 0.0 then return false end

    local metres = math.floor(distance)

    -- Repaint only on a change. Every message costs a texture upload, and the
    -- distance only ever moves a metre at a time.
    if surface.distance ~= metres or surface.label ~= label or surface.state ~= state then
        surface.distance, surface.label, surface.state = metres, label, state
        SendDuiMessage(surface.dui, json.encode({ distance = metres, label = label, state = state }))
    end

    -- Sized from the distance, which holds the quad at a constant angle above
    -- the gate and a constant size on screen however far away it is.
    local scale = math.min(cfg.maxScale, math.max(cfg.minScale, distance / cfg.referenceDistance))

    local facing = away / distance
    local heading = (math.atan(facing.y, facing.x) + (math.pi / 2)) * 180.0 / math.pi

    -- The quad hangs off its own edge, so it is nudged along the camera-facing
    -- perpendicular to sit centred over the gate.
    local sideways = cross(vec3(facing.x, facing.y, 0.0), vec3(0.0, 0.0, 1.0))

    DrawScaleformMovie_3dSolid(
        surface.scaleform,
        gate.x + (sideways.x * scale * cfg.centreOffset),
        gate.y + (sideways.y * scale * cfg.centreOffset),
        gate.z + (cfg.riseHeight * scale),
        0.0, 0.0, -heading,
        1.0, 1.0, 1.0,
        scale, scale, scale * cfg.aspect,
        2)

    return true
end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    DuiBeam.Release()
end)
