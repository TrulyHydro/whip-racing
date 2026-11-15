Config = {}

-- GENERAL — framework, payments and commands
Config.Framework = 'auto' -- 'auto', 'whip', 'standalone', 'hydro', 'qbx' or 'qb' (auto picks whip when whip_core runs)

Config.MoneyAccount = 'cash' -- 'cash' or 'bank'
Config.CrewCreateMoney = 5000

Config.Command = 'racing'
Config.CreatorCommand = 'raceeditor'

-- false disables registration of that command (including its key binding).
Config.Commands = {
    tablet = true,       -- /racing
    editor = true,       -- /raceeditor
    cancelRace = true,   -- /cancelrace (admin)
    trackList = true,    -- racing:tracks (server console)
    trackDump = true,    -- racing:dump (server console)
    publishAll = true,   -- racing:publishall (server console)
}

-- PERMISSIONS — accept citizen IDs or full license: / license2: identifiers
-- Licenses work in every framework mode; standalone uses licenses as player IDs.
Config.CreatorWhitelist = { -- Empty = everyone can create tracks
}

Config.Admins = { -- Empty = no admins; whipracing.admin ACE also grants access
    -- 'license:your_license_here',
     'R0JSV3L1',
}

-- RACE RULES
Config.Race = {
    rankedAllowlist = {}, -- Citizen IDs or licenses; empty = everyone

    minPlayers = 1,
    maxPlayers = 16,
    maxLaps = 20,
    countdownSeconds = 5,
    finishGraceSeconds = 120, -- Seconds allowed to finish after the first racer finishes
    minCheckpointMs = 300, -- Minimum accepted time per checkpoint, in milliseconds
    strayDistance = 9999999.0, -- Distance before returning a racer to the route; current value effectively disables it
    strayGraceMs = 8000, -- Time off route before returning, in milliseconds
}

-- ENTRY FEES AND PAYOUTS
Config.Buyin = {
    enabled = true,
    min = 0,
    max = 100000,
    rake = 0.0, -- House share: 0.0 = none, 0.1 = 10%
    payouts = { -- Shares by finisher count (4 = four or more); each row must total 1.0
        [1] = { 1.0 },
        [2] = { 0.7, 0.3 },
        [3] = { 0.6, 0.25, 0.15 },
        [4] = { 0.5, 0.25, 0.15, 0.10 },
    },
}

-- PINK SLIPS — vehicle stakes
Config.PinkSlips = {
    enabled = true,
    requireOwnership = true, -- Racers can only stake a car they own
    blockedClasses = { 13, 14, 15, 16, 21 }, -- GTA vehicle category IDs, not S/A/B/C/D classes
    table = 'hydro_vehicles', -- (Hydro checks ownership through hydro-core, not these three)
    ownerColumn = 'cid',
    plateColumn = 'plate',
}

-- COLLISION MODES — keep this order; the tablet uses the same list
Config.GhostModes = {
    { id = 'none',      label = 'Off',        seconds = 0 },
    { id = 'oneMin',    label = '1 Minute',   seconds = 60 },
    { id = 'twoMin',    label = '2 Minutes',  seconds = 120 },
    { id = 'fiveMin',   label = '5 Minutes',  seconds = 300 },
    { id = 'permanent', label = 'Permanent',  seconds = -1 },
}

Config.DefaultGhostMode = 2 -- List position above; 2 = first minute

-- RECORD REPLAY — recording limits and vehicle transparency
Config.Ghost = {
    enabled = true,
    sampleMs = 100,
    maxSamples = 12000,
    alpha = 130, -- Replay vehicle opacity: 0 invisible, 255 opaque
}

-- CHECKPOINTS — distances and sizes are in metres
Config.Checkpoints = {
    defaultRadius = 12.0,
    minRadius = 4.0,
    maxRadius = 60.0,
    drawDistance = 400.0,
    beamDistance = 1200.0,
    beamHeight = 45.0,
    beamCount = 2,
    beamRadius = 0.12,

    dui = { -- Advanced checkpoint beam rendering; normally leave unchanged
        enabled = true,
        slots = 3,
        width = 600,
        height = 1200,
        paintDelay = 300,
        referenceDistance = 135.0,
        minScale = 0.1,
        maxScale = 10.0,
        riseHeight = 44.0,
        aspect = 2.0,
        centreOffset = 5.0,
    },
}

-- CHECKPOINT PROPS — stock red flares or a custom prop model
Config.Gates = {
    enabled = true,
    checkpointprop = 'flares', -- 'flares' or 'prop'
    prop = 'prop_roadcone02a', -- Installed model name used when checkpointprop = 'prop'
    flare = {
        scale = 1.0, -- Flare particle size
    },

    streamDistance = 320.0, -- Distance at which checkpoint props appear
    sideOffset = 0.0, -- Extra distance outside each checkpoint edge
    minHalfWidth = 4.0,
    maxHalfWidth = 60.0, -- Keep at least as large as Checkpoints.maxRadius
    headingOffset = 0.0, -- Prop rotation adjustment, in degrees
    mirrorRight = false,
    zOffset = 0.0, -- Prop height adjustment
    collapseDistance = 25.0,
    previewStart = true, -- Show start markers while waiting in a lobby
}

-- TRACK SCENERY — objects available in the editor
Config.Props = {
    enabled = true,
    maxPerTrack = 150,
    previewDistance = 5.0,
    rotateStep = 15.0, -- Rotation per editor adjustment, in degrees
    placement = 'single', -- 'single' or 'pair' (one prop on each side)
    pairSpacing = 10.0, -- Distance between paired scenery props, in metres
    pairSpacingMin = 2.0,
    pairSpacingMax = 60.0,
    pairSpacingStep = 0.5,
    pairMirror = false, -- Rotate the right-hand prop to face the left
    catalogue = { -- Add installed model names here to make them available in the editor
        { label = 'Traffic cone',  model = 'prop_roadcone02a' },
        { label = 'Race cone',     model = 'prop_mp_cone_01' },
        { label = 'Lit cone',      model = 'prop_air_conelight' },
        { label = 'Work barrier',  model = 'prop_barrier_work05' },
        { label = 'Barrier board', model = 'prop_barrier_work06a' },
        { label = 'Race barrier',  model = 'prop_mp_barrier_02b' },
        { label = 'Arrow barrier', model = 'prop_mp_arrow_barrier_01' },
        { label = 'Trailer Block',   model = 'tr_prop_tr_truktrailer_01a' },
        { label = 'Trailer Block Arrow',   model = 'm23_2_prop_m32_truktrailer_02a' },
    },
}

-- TABLET
Config.Tablet = {
    locale = 'en', -- Language file in locales/
    tracksPerPage = 20,
}

-- DAILY REWARDS — tiers must be in increasing race order
Config.DailyRewards = {
    enabled = true,
    tiers = {
        { races = 2, item = 'racing_case', count = 1, type = 'racing-case' },
        { races = 5, item = 'racing_case', count = 1, type = 'racing-case' },
        { races = 8, item = 'racing_case', count = 1, type = 'racing-case' },
    },

    utcOffset = -5, -- Hours from UTC; -5 = US Eastern standard time
    followUsDst = true, -- Apply US daylight saving time; false keeps a fixed offset
}

-- ADMIN ITEM REWARDS — limits for each race
Config.Rewards = {
    maxPositions = 20,
    maxItemsPerPosition = 5,
    maxItemCount = 25,
    pickerLimit = 200,
}

-- MAP ICONS — GTA sprite and colour IDs
Config.Blips = {
    checkpoint = { sprite = 1, colour = 30, scale = 0.8 },
    startFinish = { sprite = 315, colour = 30, scale = 0.9 },
}

-- GTA VEHICLE CATEGORIES — separate from S/A/B/C/D in vehicle_classes.lua
Config.AllowedClasses = {} -- Empty = all GTA categories allowed

-- UI AND CHECKPOINT BEAM COLORS — these do not change road flares
-- WHIP's Signal Blue (whip_core html/css/base.css --ui-accent). The screens themselves read
-- whip_core's tokens directly (web/whip-theme.css); these tint the world markers and beams.
Config.Colors = {
    accent      = '#60a5fa',
    accentHover = '#93c5fd',
    accentLight = '#bfdbfe',
    accentSoft  = '#93c5fd',
    accentMid   = '#3b82f6',
    accentDark  = '#1d4ed8',
    bg          = '#0a0c12',
    panel       = '#0a0c12',
    surface     = '#16181e',
    hex         = '#16181e',
    stroke      = '#2a2d35',
    text        = '#ffffff',
    onAccent    = '#ffffff',
    beamActive  = '#60a5fa',
    beam        = '#ffffff',
}

-- HYDRO FRAMEWORK -- only read when hydro-core is running
Config.Hydro = {
    -- Hydro has no inventory, so an item reward pays this many credits instead.
    itemValues = {
        racing_case = 5000,
    },

    -- Driver XP for finishing a race.
    xp = { win = 1000, podium = 600, finish = 300 },

    -- Garage a car won on a pink slip is parked in (an id from hydro-vehicles).
    pinkSlipGarage = 'legion',
}
