Creator = {
    active = false,
    mode = 'nodes',  -- 'nodes' places checkpoints, 'props' places scenery
    points = {},
    props = {},
    selected = 0,        -- 0 means "no selection", edits apply to the last placed point
    selectedProp = 0,
    catalogue = 1,       -- index into Config.Props.catalogue
    rotation = 0.0,      -- preview yaw offset from the car's heading
    placement = Config.Props.placement,   -- 'single' or 'pair'
    spacing = Config.Props.pairSpacing,   -- metres between a pair
    radius = Config.Checkpoints.defaultRadius,
    trackId = nil,       -- set when editing an existing track, so saving updates in place
    circuit = false,     -- shape, for the readout only -- the tablet owns it
    draft = nil,         -- the tablet's in-progress track, handed back on finish
    cursor = false,      -- true while the panel owns the mouse and the player is parked
    panel = true,        -- false hides the whole overlay for a clean look at the road
}

-- Control ids used by the editor. Keep them here so the hint bar and the
-- polling loop can never drift apart. Throttle, brake and F (enter vehicle)
-- stay untouched.
--
-- LEFT and RIGHT are read through the cellphone controls, which is where the
-- arrow keys land. They are read rather than blocked: the arrows are also
-- secondary steering, and taking those away would strand anyone who drives on
-- them. So an arrow both steers and resizes while the editor is open, which is
-- the trade for having the gate width under your thumb.
local KEYS = {
    place    = 38,   -- E
    undo     = 177,  -- BACKSPACE
    cursor   = 19,   -- LEFT ALT
    prev     = 15,   -- MOUSE WHEEL UP
    next     = 14,   -- MOUSE WHEEL DOWN
    wider    = 10,   -- PAGE UP
    tighter  = 11,   -- PAGE DOWN
    widerAlt   = 175, -- RIGHT ARROW
    tighterAlt = 174, -- LEFT ARROW
    teleport = 47,   -- G
    remove   = 178,  -- DELETE
    save     = 191,  -- ENTER
    panel     = 288,  -- F1
    mode      = 37,   -- TAB
    placement = 73,   -- X
    spacing   = 21,   -- LEFT SHIFT, held to turn the wheel into the gap control
}

local HINTS = {
    nodes = {
        { key = 'E',      label = 'Drop checkpoint' },
        { key = 'BKSP',   label = 'Undo' },
        { key = 'WHEEL',  label = 'Select node' },
        { key = 'LEFT/RIGHT', label = 'Gate width' },
        { key = 'G',      label = 'Teleport to node' },
        { key = 'DEL',    label = 'Remove node' },
        { key = 'TAB',    label = 'Prop mode' },
        { key = 'ENTER',  label = 'Done' },
        { key = 'L-ALT',  label = 'Cursor' },
        { key = 'F1',     label = 'Hide panel' },
    },
    props = {
        { key = 'E',       label = 'Place' },
        { key = 'BKSP',    label = 'Undo' },
        { key = 'WHEEL',   label = 'Pick model' },
        { key = 'X',       label = 'Single / pair' },
        { key = 'SHF+WHL', label = 'Gate width' },
        { key = 'LEFT/RIGHT', label = 'Rotate' },
        { key = 'G',       label = 'Teleport to prop' },
        { key = 'DEL',     label = 'Remove prop' },
        { key = 'TAB',     label = 'Node mode' },
        { key = 'ENTER',   label = 'Done' },
        { key = 'L-ALT',   label = 'Cursor' },
        { key = 'F1',      label = 'Hide panel' },
    },
}

-- Handles of the translucent placement stand-ins. Pair mode uses both.
local preview = { nil, nil }

-- The same idea in node mode: the two posts this checkpoint would stand up,
-- shown where they would land and at the width currently set. `model` records
-- which one is loaded, so it is only rebuilt when the answer changes -- which
-- is once, as the first node turns the next one from a start into a
-- checkpoint.
local gatePreview = { left = nil, right = nil, model = nil }

local function catalogueEntry()
    return Config.Props.catalogue[Creator.catalogue]
end

--- Lateral offsets from the car's centre line for the current placement mode:
--- one slot on the centre for single, two mirrored slots for a pair.
local function placementOffsets()
    if Creator.placement ~= 'pair' then return { 0.0 } end
    local half = Creator.spacing / 2
    return { -half, half }
end

local function push()
    UI.Send('creator', {
        active = Creator.active,
        mode = Creator.mode,
        points = Creator.points,
        props = Creator.props,
        selected = Creator.selected,
        selectedProp = Creator.selectedProp,
        radius = Creator.radius,
        cursor = Creator.cursor,
        panel = Creator.panel,
        catalogueIndex = Creator.catalogue,
        model = catalogueEntry() and catalogueEntry().label or nil,
        placement = Creator.placement,
        spacing = Creator.spacing,
        circuit = Creator.circuit,
    })
end

local function placementCoords()
    local ped = cache.ped or PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    local entity = vehicle ~= 0 and vehicle or ped
    local coords = GetEntityCoords(entity)
    return coords, GetEntityHeading(entity), entity
end

-- ------------------------------------------------------------------- Props

--- Where one placement slot sits: ahead of the car and offset sideways, dropped
--- onto the ground so props never float or sink.
local function previewPlacement(offset)
    local _, heading, entity = placementCoords()
    local spot = GetOffsetFromEntityInWorldCoords(entity, offset or 0.0, Config.Props.previewDistance, 0.0)
    local found, groundZ = GetGroundZFor_3dCoord(spot.x, spot.y, spot.z + 2.0, false)

    local facing = heading + Creator.rotation
    -- The far side of a gate can be turned to face its partner, which is what
    -- you want for barriers and arrow boards.
    if Config.Props.pairMirror and (offset or 0.0) > 0.0 then facing = facing + 180.0 end

    return spot.x, spot.y, found and groundZ or spot.z, facing % 360.0
end

local function clearPreview()
    for slot, handle in pairs(preview) do
        if handle and DoesEntityExist(handle) then DeleteEntity(handle) end
        preview[slot] = nil
    end
end

--- One stand-in per placement slot, so pair mode shows both sides of the gate.
local function refreshPreview()
    clearPreview()

    local entry = catalogueEntry()
    if not entry then return end

    for slot = 1, #placementOffsets() do
        preview[slot] = Props.CreatePreview(entry.model)
    end
end

-- ------------------------------------------------------------- Pending gate

--- Use the same configured marker as placed checkpoints.
local function pendingGateModel()
    return Gates.MarkerModel()
end

local function clearGatePreview()
    for _, side in ipairs({ 'left', 'right' }) do
        local handle = gatePreview[side]
        Gates.RemoveMarker(handle)
        gatePreview[side] = nil
    end
    gatePreview.model = nil
end

--- Stands the pair up, or moves the pair already standing. Called every frame
--- from the render loop, so it does as little as it can get away with.
local function refreshGatePreview()
    if not Config.Gates.enabled or Creator.mode ~= 'nodes' then
        if gatePreview.model then clearGatePreview() end
        return
    end

    local model = pendingGateModel()

    if gatePreview.model ~= model then
        clearGatePreview()
        gatePreview.left = Props.CreatePreview(model)
        gatePreview.right = Props.CreatePreview(model)
        gatePreview.model = model
    end

    local coords, heading = placementCoords()

    -- The gate is square to the car, so what you see is what dropping the node
    -- here would build. Left of travel is the heading turned a quarter turn.
    local radians = math.rad(heading)
    local fx, fy = -math.sin(radians), math.cos(radians)
    local lx, ly = -fy, fx

    -- Always the pending width, never the selected node's: this is a preview of
    -- the checkpoint about to be dropped, and that is the width it will get.
    local cfg = Config.Gates
    local half = math.max(cfg.minHalfWidth,
        math.min(cfg.maxHalfWidth, Creator.radius + cfg.sideOffset))

    local rightHeading = heading + cfg.headingOffset
    if cfg.mirrorRight then rightHeading = rightHeading + 180.0 end

    -- One row per post: which side it is, which way it sits off the centre
    -- line, and which way it faces.
    local sides = {
        { side = 'left',  sign = 1.0,  facing = heading + cfg.headingOffset },
        { side = 'right', sign = -1.0, facing = rightHeading },
    }

    for _, post in ipairs(sides) do
        local handle = gatePreview[post.side]

        if handle and DoesEntityExist(handle) then
            Gates.AttachFlare(handle)
            local x = coords.x + lx * half * post.sign
            local y = coords.y + ly * half * post.sign
            local found, groundZ = GetGroundZFor_3dCoord(x, y, coords.z + 3.0, false)

            SetEntityCoords(handle, x, y, (found and groundZ or coords.z) + cfg.zOffset,
                false, false, false, false)
            SetEntityHeading(handle, post.facing % 360.0)
        end
    end
end

--- Rebuilds every placed prop from the list. Counts are small enough that a
--- full respawn on each edit is simpler than tracking individual handles.
local function syncProps()
    Props.Spawn(Creator.props)
end

--- Gate markers are derived from the checkpoints, so any edit to a node has to
--- rebuild them. They stream themselves back in around the car.
local function syncGates()
    Gates.Refresh()
end

function Creator.PlaceProp()
    if not Config.Props.enabled then return end

    local entry = catalogueEntry()
    if not entry then return end

    local offsets = placementOffsets()

    if #Creator.props + #offsets > Config.Props.maxPerTrack then
        Bridge.Notify(('This track is at the limit of %d props.'):format(Config.Props.maxPerTrack), 'error')
        return
    end

    for _, offset in ipairs(offsets) do
        local x, y, z, heading = previewPlacement(offset)

        Creator.props[#Creator.props + 1] = {
            model = entry.model,
            x = math.floor(x * 100) / 100,
            y = math.floor(y * 100) / 100,
            z = math.floor(z * 100) / 100,
            heading = math.floor(heading * 10) / 10,
        }
    end

    Creator.selectedProp = #Creator.props
    syncProps()
    push()
end

--- Swaps between dropping one prop and dropping a gate pair.
function Creator.SetPlacement(mode)
    if mode ~= 'single' and mode ~= 'pair' then return end
    if Creator.placement == mode then return end
    Creator.placement = mode
    refreshPreview()
    push()
end

--- Widens or narrows the gap in pair mode -- the room drivers get through.
function Creator.SetSpacing(metres)
    local cfg = Config.Props
    Creator.spacing = math.max(cfg.pairSpacingMin, math.min(cfg.pairSpacingMax, metres))
    push()
end

function Creator.DeleteProp(index)
    if not Creator.props[index] then return end
    table.remove(Creator.props, index)
    Creator.selectedProp = math.min(Creator.selectedProp, #Creator.props)
    syncProps()
    push()
end

function Creator.SelectCatalogue(index)
    local count = #Config.Props.catalogue
    if count == 0 then return end
    if index < 1 then index = count end
    if index > count then index = 1 end
    Creator.catalogue = index
    refreshPreview()
    push()
end

function Creator.Rotate(degrees)
    Creator.rotation = (Creator.rotation + degrees) % 360.0
    push()
end

function Creator.TeleportToProp(index)
    local prop = Creator.props[index]
    if not prop then return end
    local _, _, entity = placementCoords()
    SetEntityCoords(entity, prop.x, prop.y, prop.z + 1.0, false, false, false, false)
end

-- -------------------------------------------------------------- Checkpoints

--- Adds a checkpoint where the player is standing or driving.
function Creator.Place()
    if not Creator.active then return end
    local coords, heading = placementCoords()

    Creator.points[#Creator.points + 1] = {
        x = math.floor(coords.x * 100) / 100,
        y = math.floor(coords.y * 100) / 100,
        z = math.floor(coords.z * 100) / 100,
        heading = math.floor(heading * 10) / 10,
        radius = Creator.radius,
    }

    -- Deliberately leaves nothing selected. Selecting the node just placed
    -- would point the width keys at it, so setting up the next checkpoint at a
    -- different width would silently rewrite the one behind you. Undo still
    -- takes back the last node; resizing an existing one is an explicit act,
    -- reached by picking it with the wheel.
    Creator.selected = 0

    syncGates()
    push()
end

function Creator.Undo()
    if Creator.mode == 'props' then
        if #Creator.props == 0 then return end

        -- Undo mirrors the placement mode, so one press takes back exactly what
        -- one press put down: a single prop, or a whole gate pair.
        for _ = 1, math.min(#placementOffsets(), #Creator.props) do
            table.remove(Creator.props, #Creator.props)
        end

        Creator.selectedProp = math.min(Creator.selectedProp, #Creator.props)
        syncProps()
        push()
        return
    end

    if #Creator.points == 0 then return end
    table.remove(Creator.points, #Creator.points)
    Creator.selected = math.min(Creator.selected, #Creator.points)
    syncGates()
    push()
end

function Creator.Delete(index)
    if not Creator.points[index] then
        if #Creator.points > 0 then
            Bridge.Notify('Pick a checkpoint with the wheel first, or press Backspace to undo.', 'inform')
        end
        return
    end
    table.remove(Creator.points, index)
    Creator.selected = math.min(Creator.selected, #Creator.points)
    syncGates()
    push()
end

--- Moves an existing checkpoint to the player's current position.
function Creator.MoveHere(index)
    local point = Creator.points[index]
    if not point then return end
    local coords, heading = placementCoords()
    point.x, point.y, point.z = coords.x, coords.y, coords.z
    point.heading = heading
    -- Moving a node redefines it, so any imported gate axis no longer applies
    -- and its markers go back to squaring up with the route.
    point.axisX, point.axisY = nil, nil
    syncGates()
    push()
end

--- Resizes exactly one thing: the selected checkpoint, or -- when nothing is
--- selected -- the width the next one will be placed at.
---
--- Never both. Widening the pending gate must not reach back and widen the
--- last one you placed, which is what makes a route come out with widths
--- nobody set.
function Creator.SetRadius(index, radius)
    radius = math.max(Config.Checkpoints.minRadius, math.min(Config.Checkpoints.maxRadius, radius + 0.0))

    if index and Creator.points[index] then
        Creator.points[index].radius = radius
    else
        Creator.radius = radius
    end

    syncGates()
    push()
end

--- Rolling the wheel walks the whole route and back to the start. Position 0 is
--- "the checkpoint you are about to place" and is part of the cycle, so the
--- width keys can be aimed back at the pending gate without placing one.
function Creator.Select(index)
    if #Creator.points == 0 then
        Creator.selected = 0
        push()
        return
    end

    if index < 0 then index = #Creator.points end
    if index > #Creator.points then index = 0 end

    Creator.selected = index
    push()
end

function Creator.Teleport(index)
    local point = Creator.points[index]

    if not point then
        if #Creator.points > 0 then
            Bridge.Notify('Pick a checkpoint with the wheel first.', 'inform')
        end
        return
    end
    local _, _, entity = placementCoords()
    SetEntityCoords(entity, point.x, point.y, point.z + 1.0, false, false, false, false)
    SetEntityHeading(entity, point.heading or 0.0)
end

-- -------------------------------------------------------------------- Modes

function Creator.SetMode(mode)
    if mode ~= 'nodes' and mode ~= 'props' then return end
    if Creator.mode == mode then return end

    Creator.mode = mode
    Creator.rotation = 0.0

    if mode == 'props' then
        refreshPreview()
    else
        clearPreview()
    end

    push()
end

--- Hands the mouse to the panel, or gives control back to the car.
function Creator.SetCursor(state)
    if not Creator.active then return end
    state = state and true or false
    if Creator.cursor == state then return end
    Creator.cursor = state
    if state and not Creator.panel then Creator.panel = true end
    UI.SetFocus(state)
    push()
end

function Creator.TogglePanel()
    Creator.panel = not Creator.panel
    if not Creator.panel and Creator.cursor then
        Creator.cursor = false
        UI.SetFocus(false)
    end
    push()
end

-- ------------------------------------------------------------------- Session

function Creator.Start(existing, meta)
    if Creator.active then return end
    Creator.active = true
    Creator.mode = 'nodes'
    Creator.points = existing or {}
    Creator.props = meta and meta.props or {}
    Creator.selected = #Creator.points
    Creator.selectedProp = #Creator.props
    Creator.catalogue = 1
    Creator.rotation = 0.0
    Creator.placement = Config.Props.placement
    Creator.spacing = Config.Props.pairSpacing
    Creator.radius = Config.Checkpoints.defaultRadius
    Creator.cursor = false
    Creator.panel = true
    Creator.trackId = meta and meta.id or nil
    Creator.circuit = meta and meta.circuit or false
    Creator.draft = meta and meta.draft or nil

    -- The editor takes over the world, so any lobby preview standing from a
    -- race you are queued for has to come down first.
    Gates.HidePreview()

    syncProps()
    Gates.Start(Creator.points, meta and meta.circuit)

    -- The overlay draws over gameplay but does not take focus, so the player
    -- keeps full control of the car until they ask for the cursor.
    UI.Overlay('creator', {
        mode = 'nodes',
        points = Creator.points,
        props = Creator.props,
        radius = Creator.radius,
        selected = Creator.selected,
        selectedProp = Creator.selectedProp,
        cursor = false,
        panel = true,
        hints = HINTS,
        catalogue = Config.Props.catalogue,
        catalogueIndex = 1,
        placement = Creator.placement,
        spacing = Creator.spacing,
        spacingLimits = { min = Config.Props.pairSpacingMin, max = Config.Props.pairSpacingMax, step = Config.Props.pairSpacingStep },
        propsEnabled = Config.Props.enabled,
        limits = {
            min = Config.Checkpoints.minRadius,
            max = Config.Checkpoints.maxRadius,
            maxProps = Config.Props.maxPerTrack,
        },
        track = meta and {
            id = meta.id,
            name = meta.name,
            circuit = meta.circuit,
            published = meta.published,
        } or nil,
    })

    CreateThread(function()
        while Creator.active do
            Checkpoints.DrawPreview(Creator.points, Creator.selected)

            -- The gate this checkpoint would raise, standing where it would
            -- land. Resizing moves it, so the width is judged against the road
            -- rather than against a number in a panel.
            refreshGatePreview()

            -- Draw the route order between placed points so the shape reads at a glance.
            for index = 1, #Creator.points - 1 do
                local a, b = Creator.points[index], Creator.points[index + 1]
                DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 45, 212, 191, 180)
            end

            -- Keep the placement stand-ins glued to the road ahead of the car,
            -- and draw the gap between a pair so the room is measurable.
            if Creator.mode == 'props' then
                local offsets = placementOffsets()
                local corners = {}

                for slot, offset in ipairs(offsets) do
                    local x, y, z, heading = previewPlacement(offset)
                    corners[slot] = { x = x, y = y, z = z }

                    local handle = preview[slot]
                    if handle and DoesEntityExist(handle) then
                        SetEntityCoords(handle, x, y, z, false, false, false, false)
                        SetEntityHeading(handle, heading)
                    end
                end

                if corners[2] then
                    DrawLine(corners[1].x, corners[1].y, corners[1].z + 0.5,
                        corners[2].x, corners[2].y, corners[2].z + 0.5, 153, 246, 228, 200)
                end
            end

            Wait(0)
        end
    end)

    CreateThread(function()
        while Creator.active do
            if not Creator.cursor then
                -- E would otherwise fire a context action, LEFT ALT the weapon
                -- wheel, G a special ability, the wheel the radio wheel and
                -- PgUp/PgDn the free look. Blocking those keeps the editor keys
                -- clean while steering, throttle and F (enter vehicle) stay
                -- completely untouched.
                DisableControlAction(0, KEYS.place, true)
                DisableControlAction(0, KEYS.cursor, true)
                DisableControlAction(0, KEYS.teleport, true)
                DisableControlAction(0, KEYS.prev, true)
                DisableControlAction(0, KEYS.next, true)
                DisableControlAction(0, KEYS.wider, true)
                DisableControlAction(0, KEYS.tighter, true)
                DisableControlAction(0, KEYS.mode, true)
                DisableControlAction(0, KEYS.placement, true)

                local propMode = Creator.mode == 'props'
                local forward = IsDisabledControlJustPressed(0, KEYS.next)
                local back = IsDisabledControlJustPressed(0, KEYS.prev)
                -- The arrows are not disabled, so they come through the plain
                -- check rather than the disabled one.
                local up = IsDisabledControlJustPressed(0, KEYS.wider)
                    or IsControlJustPressed(0, KEYS.widerAlt)
                local down = IsDisabledControlJustPressed(0, KEYS.tighter)
                    or IsControlJustPressed(0, KEYS.tighterAlt)

                if IsDisabledControlJustPressed(0, KEYS.mode) and Config.Props.enabled then
                    Creator.SetMode(propMode and 'nodes' or 'props')
                end

                if IsDisabledControlJustPressed(0, KEYS.place) then
                    if propMode then Creator.PlaceProp() else Creator.Place() end
                end

                if IsDisabledControlJustPressed(0, KEYS.cursor) then Creator.SetCursor(true) end
                if IsControlJustPressed(0, KEYS.undo) then Creator.Undo() end
                if IsControlJustPressed(0, KEYS.panel) then Creator.TogglePanel() end

                if propMode then
                    -- Holding SHIFT turns the wheel into the gap control, so
                    -- the width of a gate is adjustable without leaving the seat.
                    local widening = IsControlPressed(0, KEYS.spacing)

                    if widening and (forward or back) then
                        local step = Config.Props.pairSpacingStep * (forward and -1.0 or 1.0)
                        Creator.SetPlacement('pair')
                        Creator.SetSpacing(Creator.spacing + step)
                    elseif forward then
                        Creator.SelectCatalogue(Creator.catalogue + 1)
                    elseif back then
                        Creator.SelectCatalogue(Creator.catalogue - 1)
                    end

                    if IsDisabledControlJustPressed(0, KEYS.placement) then
                        Creator.SetPlacement(Creator.placement == 'pair' and 'single' or 'pair')
                    end

                    if up then Creator.Rotate(Config.Props.rotateStep) end
                    if down then Creator.Rotate(-Config.Props.rotateStep) end

                    -- G means the same thing in both modes: go to what is
                    -- selected. It was only reachable from the row button
                    -- before, which is gone.
                    if IsDisabledControlJustPressed(0, KEYS.teleport) then
                        Creator.TeleportToProp(Creator.selectedProp)
                    end

                    if IsControlJustPressed(0, KEYS.remove) then Creator.DeleteProp(Creator.selectedProp) end
                else
                    if IsDisabledControlJustPressed(0, KEYS.teleport) then Creator.Teleport(Creator.selected) end
                    if forward then Creator.Select(Creator.selected + 1) end
                    if back then Creator.Select(Creator.selected - 1) end
                    if IsControlJustPressed(0, KEYS.remove) then Creator.Delete(Creator.selected) end

                    if up or down then
                        local point = Creator.points[Creator.selected]
                        local base = point and point.radius or Creator.radius
                        Creator.SetRadius(Creator.selected, base + (up and 1.0 or -1.0))
                    end
                end

                if IsControlJustPressed(0, KEYS.save) then
                    Creator.Finish()
                end
            end

            Wait(0)
        end
    end)

    -- Live telemetry for the panel's map and readout. 10 Hz is plenty and costs
    -- nothing next to the render thread above.
    CreateThread(function()
        while Creator.active do
            local coords, heading = placementCoords()
            local ped = cache.ped or PlayerPedId()
            local vehicle = GetVehiclePedIsIn(ped, false)

            UI.Send('creator:tick', {
                x = coords.x,
                y = coords.y,
                z = coords.z,
                heading = heading,
                rotation = Creator.rotation,
                speed = math.floor(GetEntitySpeed(vehicle ~= 0 and vehicle or ped) * 2.236936),
                inVehicle = vehicle ~= 0,
                street = GetStreetNameFromHashKey(GetStreetNameAtCoord(coords.x, coords.y, coords.z)),
            })

            Wait(100)
        end
    end)
end

--- Hands the route back to the tablet and closes the world editor.
---
--- The editor used to ask for the name, the shape and whether the track was
--- public, and then save it itself. The tablet's track screen asks for exactly
--- the same three things, so whichever you answered last won and the other set
--- was quietly discarded. There is one set of those fields now, and it is the
--- tablet's -- this places checkpoints and props, nothing else.
function Creator.Finish()
    if not Creator.active then return end

    -- Three, not two: that is what the tablet's save button accepts, and being
    -- told here is better than being handed a screen that refuses.
    if #Creator.points < 3 then
        Bridge.Notify('A track needs at least three checkpoints.', 'error')
        return
    end

    local draft = Creator.draft or {}

    local handoff = {
        id = Creator.trackId,
        name = draft.name,
        isPublished = draft.isPublished,
        isSprint = draft.isSprint,
        points = Creator.points,
        props = Creator.props,
    }

    Creator.Stop()
    Tablet.ResumeTrack(handoff)
end

function Creator.Stop()
    Creator.active = false
    Creator.mode = 'nodes'
    Creator.points = {}
    Creator.props = {}
    Creator.selected = 0
    Creator.selectedProp = 0
    Creator.cursor = false
    Creator.panel = true
    Creator.trackId = nil
    clearPreview()
    Props.Clear()
    clearGatePreview()
    Gates.Stop()
    UI.Close()
end

RegisterNUICallback('creator:place', function(_, cb)
    if Creator.mode == 'props' then Creator.PlaceProp() else Creator.Place() end
    cb('ok')
end)
RegisterNUICallback('creator:undo', function(_, cb) Creator.Undo() cb('ok') end)
RegisterNUICallback('creator:delete', function(data, cb) Creator.Delete(data.index) cb('ok') end)
RegisterNUICallback('creator:moveHere', function(data, cb) Creator.MoveHere(data.index) cb('ok') end)
RegisterNUICallback('creator:cursor', function(data, cb) Creator.SetCursor(data.state) cb('ok') end)
RegisterNUICallback('creator:panel', function(_, cb) Creator.TogglePanel() cb('ok') end)
RegisterNUICallback('creator:mode', function(data, cb) Creator.SetMode(data.mode) cb('ok') end)
RegisterNUICallback('creator:catalogue', function(data, cb) Creator.SelectCatalogue(tonumber(data.index) or 1) cb('ok') end)
RegisterNUICallback('creator:rotate', function(data, cb) Creator.Rotate(tonumber(data.degrees) or 0) cb('ok') end)
RegisterNUICallback('creator:placement', function(data, cb) Creator.SetPlacement(data.mode) cb('ok') end)
RegisterNUICallback('creator:spacing', function(data, cb)
    Creator.SetSpacing(tonumber(data.spacing) or Config.Props.pairSpacing)
    cb('ok')
end)
RegisterNUICallback('creator:propDelete', function(data, cb) Creator.DeleteProp(data.index) cb('ok') end)
RegisterNUICallback('creator:propSelect', function(data, cb)
    Creator.selectedProp = data.index
    push()
    cb('ok')
end)
RegisterNUICallback('creator:select', function(data, cb)
    Creator.selected = data.index
    push()
    cb('ok')
end)
RegisterNUICallback('creator:radius', function(data, cb)
    Creator.SetRadius(data.index, tonumber(data.radius) or Config.Checkpoints.defaultRadius)
    cb('ok')
end)

RegisterNUICallback('creator:finish', function(_, cb)
    Creator.Finish()
    cb('ok')
end)

RegisterNUICallback('creator:quit', function(_, cb)
    Creator.Stop()
    cb('ok')
end)

Bridge.RegisterCommand('editor', Config.CreatorCommand, function()
    if Creator.active then
        Creator.Stop()
        return
    end

    local allowed = lib.callback.await('whip-racing:canCreate', false)
    if not allowed then
        Bridge.Notify('You do not have access to the track editor.', 'error')
        return
    end

    Creator.Start()
end, false)
