Tracks = { cache = {} }

--- Rough track length in metres. Derived on load rather than stored, so it can
--- never drift out of step with the checkpoint list.
local function measure(points)
    local total = 0.0
    for index = 1, #points - 1 do
        local a, b = points[index], points[index + 1]
        total = total + math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 + (b.z - a.z) ^ 2)
    end
    return math.floor(total)
end

-- ------------------------------------------------------- Checkpoint shapes
--
-- Stored checkpoint arrays do not all look the same: rows written by this
-- editor are flat { x, y, z }, but tracks imported from elsewhere commonly nest
-- the position under `coords`/`position`/`pos`, use a numeric triple, or
-- capitalise the keys. Everything is normalised to the flat shape on load, so
-- the rest of the resource only ever sees one format -- and a track re-saved
-- from the editor is written back in that format.

local function readVector(value)
    if type(value) ~= 'table' then return nil end

    local x = tonumber(value.x or value.X or value[1])
    local y = tonumber(value.y or value.Y or value[2])
    local z = tonumber(value.z or value.Z or value[3])

    if not x or not y or not z then return nil end
    return x, y, z
end

local function clampRadius(radius)
    return math.max(Config.Checkpoints.minRadius,
        math.min(Config.Checkpoints.maxRadius, radius or Config.Checkpoints.defaultRadius))
end

--- The common imported shape is a gate: two [x, y, z, heading] posts marking
--- the left and right side of the line you cross, plus a marker-type integer.
--- The gate centre becomes the checkpoint and half its width becomes the
--- radius, which is exactly the area the original track meant you to drive
--- through.
local function readGatePair(raw)
    local leftX, leftY, leftZ = readVector(raw[1])
    local rightX, rightY, rightZ = readVector(raw[2])
    if not leftX or not rightX then return nil end

    local width = math.sqrt((rightX - leftX) ^ 2 + (rightY - leftY) ^ 2)

    return {
        x = (leftX + rightX) / 2,
        y = (leftY + rightY) / 2,
        z = (leftZ + rightZ) / 2,
        -- These posts carry a track-wide heading rather than a per-gate one, so
        -- it is derived from the route direction in a second pass instead.
        heading = nil,
        radius = clampRadius(width / 2),
        -- Unit vector along the gate line. Original tracks angle their gates
        -- rather than squaring them to the route, so keeping the real axis lets
        -- the gate markers stand where the author actually put the posts.
        axisX = width > 0 and (rightX - leftX) / width or nil,
        axisY = width > 0 and (rightY - leftY) / width or nil,
    }
end

local function normalisePoint(raw)
    if type(raw) ~= 'table' then return nil end

    local gate = readGatePair(raw)
    if gate then return gate end

    local x, y, z = readVector(raw)
    if not x then x, y, z = readVector(raw.coords) end
    if not x then x, y, z = readVector(raw.coord) end
    if not x then x, y, z = readVector(raw.position) end
    if not x then x, y, z = readVector(raw.pos) end
    if not x then x, y, z = readVector(raw.location) end
    if not x then return nil end

    local nested = type(raw.coords) == 'table' and raw.coords or nil
    local heading = tonumber(raw.heading or raw.h or raw.w or (nested and (nested.w or nested.heading))) or 0.0
    local radius = tonumber(raw.radius or raw.r or raw.scale or raw.size)

    return { x = x, y = y, z = z, heading = heading, radius = clampRadius(radius) }
end

--- Returns the normalised list plus how many entries had to be thrown away, so
--- the loader can say something useful instead of failing silently.
local function normalisePoints(raw)
    local points, skipped = {}, 0

    for _, entry in ipairs(raw or {}) do
        local point = normalisePoint(entry)
        if point then
            points[#points + 1] = point
        else
            skipped = skipped + 1
        end
    end

    -- Gates arrive without a usable heading. Point each one down the route, so
    -- teleporting to a checkpoint and being returned to one both face the way
    -- the driver should actually be going.
    for index, point in ipairs(points) do
        if not point.heading then
            local ahead = points[index + 1] or points[index - 1]

            if ahead then
                local dx, dy = ahead.x - point.x, ahead.y - point.y
                if points[index + 1] == nil then dx, dy = -dx, -dy end
                point.heading = (math.deg(math.atan(-dx, dy))) % 360.0
            else
                point.heading = 0.0
            end
        end
    end

    return points, skipped
end

--- Props come in two shapes: this editor writes { model = 'name', x, y, z,
--- heading }, while imported tracks use the flat array [x, y, z, heading,
--- modelHash]. `model` ends up either a name or a hash number; the client
--- handles both.
local function normaliseProps(raw)
    local props = {}

    for _, entry in ipairs(raw or {}) do
        if type(entry) == 'table' then
            local model = entry.model
            local x, y, z, heading

            if model == nil and tonumber(entry[5]) then
                x, y, z = tonumber(entry[1]), tonumber(entry[2]), tonumber(entry[3])
                heading = tonumber(entry[4]) or 0.0
                model = tonumber(entry[5])
            else
                x, y, z = readVector(entry)
                if not x then x, y, z = readVector(entry.coords) end
                heading = tonumber(entry.heading or entry.h or entry.w) or 0.0
            end

            if x and y and z and (type(model) == 'string' or type(model) == 'number') then
                props[#props + 1] = { model = model, x = x, y = y, z = z, heading = heading }
            end
        end
    end

    return props
end

--- TINYINT(1) does not come back in one consistent shape: depending on the
--- oxmysql/mysql2 version and its typeCast settings a flag arrives as the
--- number 1, the boolean true, or the string "1". Comparing against 1 alone
--- silently turns every flag off, which reads as "the tracks vanished".
local function truthy(value)
    return value == 1 or value == true or value == '1'
end

--- Timestamps arrive as either a string or a number depending on the driver.
--- The tablet feeds them to new Date(), which wants milliseconds, so they are
--- flattened here rather than at each call site.
local function toMillis(value)
    if type(value) == 'number' then
        return value > 1e11 and value or math.floor(value * 1000)
    end

    if type(value) == 'string' then
        local year, month, day, hour, min, sec =
            value:match('(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)')

        if year then
            return os.time({
                year = tonumber(year), month = tonumber(month), day = tonumber(day),
                hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
            }) * 1000
        end
    end

    return 0
end

local function decode(row)
    local points, skipped = normalisePoints(json.decode(row.checkpoints or '[]'))
    local props = normaliseProps(row.props and json.decode(row.props) or {})

    if skipped > 0 then
        print(('[whip-racing] track %s ("%s"): skipped %d checkpoint(s) with no readable position')
            :format(row.id, row.name, skipped))
    end

    return {
        id = row.id,
        name = row.name,
        creatorStateId = row.creatorStateId,
        points = points,
        props = props,
        checkpoints = #points,
        propCount = #props,
        distance = measure(points),
        sprint = truthy(row.isSprint),
        circuit = not truthy(row.isSprint),
        published = truthy(row.isPublished),
        official = truthy(row.isOfficial),
        verified = truthy(row.isVerified),
        featured = truthy(row.isFeatured),
        createdAt = toMillis(row.createdAt),
        updatedAt = toMillis(row.updatedAt),
    }
end

function Tracks.LoadAll()
    local rows = MySQL.query.await('SELECT * FROM `whip_racing_tracks` WHERE `isDeleted` = 0 ORDER BY `name` ASC') or {}
    Tracks.cache = {}

    local loaded, drafts = 0, 0

    for _, row in ipairs(rows) do
        -- One row with malformed JSON must not take the whole catalogue down
        -- with it, so each is decoded on its own.
        local ok, track = pcall(decode, row)

        if ok and #track.points > 0 then
            Tracks.cache[row.id] = track
            loaded = loaded + 1
            if not track.published then drafts = drafts + 1 end
        elseif ok then
            print(('[whip-racing] track %s ("%s") has no usable checkpoints, skipping it')
                :format(row.id, row.name))
        else
            print(('[whip-racing] track %s ("%s") could not be read: %s')
                :format(row.id, row.name, track))
        end
    end

    print(('[whip-racing] loaded %d of %d tracks'):format(loaded, #rows))

    if drafts > 0 then
        print(('[whip-racing] %d of them are unpublished, so they only show in their own creator\'s list. '
            .. 'Run `racing:publishall` to publish them, or set isPublished = 1 in the database.'):format(drafts))
    end
end

function Tracks.Get(id)
    return Tracks.cache[id]
end

--- Menu-sized list: no checkpoint or prop arrays, which keeps the payload
--- small. Unpublished tracks are only visible to the person who built them.
function Tracks.List(stateId)
    local list = {}

    for _, track in pairs(Tracks.cache) do
        if track.published or (stateId and track.creatorStateId == stateId) then
            list[#list + 1] = {
                id = track.id,
                name = track.name,
                creatorStateId = track.creatorStateId,
                checkpoints = track.checkpoints,
                propCount = track.propCount,
                distance = track.distance,
                sprint = track.sprint,
                circuit = track.circuit,
                published = track.published,
                official = track.official,
                verified = track.verified,
                featured = track.featured,
                mine = stateId ~= nil and track.creatorStateId == stateId,
            }
        end
    end

    -- Featured tracks lead the list, everything else falls back to name order.
    table.sort(list, function(a, b)
        if a.featured ~= b.featured then return a.featured end
        return a.name < b.name
    end)

    return list
end

--- Everything the tablet needs about every track, checkpoints included. The
--- browser list deliberately omits those to stay small; the tablet draws routes
--- from them, so here they are carried through.
lib.callback.register('whip-racing:getTabletTracks', function(source)
    local player = Bridge.GetPlayer(source)
    local stateId = player and player.citizenid
    local list = {}

    -- Summaries only: every checkpoint and prop of every track came to a few
    -- hundred kilobytes in one message, too big to arrive, so the tablet's
    -- lists sat waiting and then broke. Lists show only how many checkpoints
    -- a track has (`checkpoints`, a count); a track's own page loads it whole
    -- through whip-racing:getTrack.
    for _, track in pairs(Tracks.cache) do
        if track.published or (stateId and track.creatorStateId == stateId) then
            local summary = {}
            for key, value in pairs(track) do
                if key ~= 'points' and key ~= 'props' then summary[key] = value end
            end
            list[#list + 1] = summary
        end
    end

    table.sort(list, function(a, b)
        if a.featured ~= b.featured then return a.featured end
        return a.name < b.name
    end)

    return list
end)

--- Per-track totals, so the tablet's home screen can pick out what is worth
--- racing without asking for every track's stats one at a time.
lib.callback.register('whip-racing:getTrackTotals', function()
    local rows = MySQL.query.await([[
        SELECT `track_id` AS trackId, COUNT(*) AS races, MIN(time_ms) AS bestTime
        FROM `whip_racing_records` GROUP BY `track_id`
    ]]) or {}

    local totals = {}
    for _, row in ipairs(rows) do
        totals[tostring(row.trackId)] = {
            races = tonumber(row.races) or 0,
            bestTime = tonumber(row.bestTime) or 0,
        }
    end

    return totals
end)

-- Profile statistics come from the append-only results log, not personal bests.
local function profileTop(stateId, kind, offset, limit)
    offset = math.max(0, math.floor(tonumber(offset) or 0))
    limit = math.max(1, math.min(100, math.floor(tonumber(limit) or 3)))
    local grouping = kind == 'vehicles' and 'e.model' or 'r.track_id'
    local label = kind == 'vehicles' and 'e.model AS model' or 'r.track_id AS trackId, MAX(r.track_name) AS trackName'
    local filter = kind == 'vehicles' and " AND e.model IS NOT NULL AND e.model <> ''" or ''
    return MySQL.query.await(([[
        SELECT %s, COUNT(*) AS races, SUM(e.position = 1) AS wins,
               AVG(e.position) AS avgPlace, AVG(e.time_ms) AS avgTime,
               UNIX_TIMESTAMP(MAX(r.finished_at)) * 1000 AS lastUsed
        FROM `whip_racing_race_results` e JOIN `whip_racing_races` r ON r.id = e.race_id
        WHERE e.citizenid = ? AND e.position IS NOT NULL AND e.time_ms IS NOT NULL%s
        GROUP BY %s ORDER BY races DESC, lastUsed DESC LIMIT ? OFFSET ?
    ]]):format(label, filter, grouping), { stateId, limit, offset }) or {}
end

lib.callback.register('whip-racing:getLeaderboard', function()
    local rows = MySQL.query.await([[
        SELECT citizenid, MAX(name) AS name, COUNT(*) AS races,
               MIN(time_ms) AS best, SUM(position = 1) AS wins
        FROM `whip_racing_race_results` WHERE position IS NOT NULL AND time_ms IS NOT NULL
        GROUP BY citizenid ORDER BY wins DESC, races DESC LIMIT 100
    ]]) or {}
    for _, row in ipairs(rows) do row.name = Profiles.DisplayName(row.citizenid, row.name) end
    return rows
end)

lib.callback.register('whip-racing:getProfile', function(source, stateId, limit)
    local player = Bridge.GetPlayer(source)
    stateId = stateId or (player and player.citizenid)
    if not stateId then return nil end
    local totals = MySQL.single.await([[
        SELECT COUNT(*) AS races, COALESCE(SUM(time_ms), 0) AS totalTime,
               COALESCE(SUM(payout), 0) AS moneyMade, AVG(position) AS avgPlace, MAX(name) AS name
        FROM `whip_racing_race_results`
        WHERE citizenid = ? AND position IS NOT NULL AND time_ms IS NOT NULL
    ]], { stateId }) or {}
    local models = MySQL.query.await([[
        SELECT model, COUNT(*) AS races FROM `whip_racing_race_results`
        WHERE citizenid = ? AND position IS NOT NULL AND time_ms IS NOT NULL
        GROUP BY model
    ]], { stateId }) or {}
    local classes, mostClass, mostCount = {}, 'N/A', 0
    for _, row in ipairs(models) do
        local class = VehicleClasses.Get(row.model)
        classes[class] = (classes[class] or 0) + (tonumber(row.races) or 0)
    end
    for class, count in pairs(classes) do
        if count > mostCount or (count == mostCount and class < mostClass) then
            mostClass, mostCount = class, count
        end
    end
    local created = 0
    for _, track in pairs(Tracks.cache) do
        if tostring(track.creatorStateId) == tostring(stateId) then created = created + 1 end
    end
    return {
        stateId = stateId,
        name = Profiles.DisplayName(stateId, totals.name or (player and player.citizenid == stateId and player.name)),
        races = tonumber(totals.races) or 0,
        totalTime = tonumber(totals.totalTime) or 0,
        moneyMade = tonumber(totals.moneyMade) or 0,
        avgPlace = tonumber(totals.avgPlace),
        mostRacedClass = mostClass,
        tracksCreated = created,
        vehicles = profileTop(stateId, 'vehicles', 0, limit),
        tracks = profileTop(stateId, 'tracks', 0, limit),
    }
end)

lib.callback.register('whip-racing:getProfileTop', function(source, stateId, kind, offset, limit)
    local player = Bridge.GetPlayer(source)
    stateId = stateId or (player and player.citizenid)
    if not stateId then return {} end
    return profileTop(stateId, kind, offset, limit)
end)

local function canCreate(src)
    if #Config.CreatorWhitelist == 0 then return true end
    if Bridge.MatchesIdentity(src, Config.CreatorWhitelist) then return true end
    return IsPlayerAceAllowed(src, 'whipracing.editor')
end

lib.callback.register('whip-racing:canCreate', function(source)
    return canCreate(source)
end)

lib.callback.register('whip-racing:getTrack', function(_, trackId)
    return Tracks.Get(trackId)
end)

--- Strips anything unexpected out of the checkpoint list before it reaches the
--- database. Clients are never trusted with the shape of stored rows.
local function cleanPoints(points)
    local clean = {}
    for index, point in ipairs(points) do
        clean[index] = {
            x = tonumber(point.x) or 0.0,
            y = tonumber(point.y) or 0.0,
            z = tonumber(point.z) or 0.0,
            heading = tonumber(point.heading) or 0.0,
            radius = math.max(Config.Checkpoints.minRadius,
                math.min(Config.Checkpoints.maxRadius, tonumber(point.radius) or Config.Checkpoints.defaultRadius)),
            -- Carried through so re-saving an imported track does not square up
            -- gates the original author deliberately angled. The editor clears
            -- it on any node it moves.
            axisX = tonumber(point.axisX),
            axisY = tonumber(point.axisY),
        }
    end
    return clean
end

--- Props are held to the configured catalogue, so a tampered client cannot
--- introduce arbitrary models. Models a track already had are grandfathered
--- through: imported tracks use models outside the catalogue, and editing one
--- must not quietly strip its scenery.
local function cleanProps(props, existing)
    local allowed = {}

    for _, entry in ipairs(Config.Props.catalogue) do
        allowed[entry.model] = true
    end

    for _, prop in ipairs(existing or {}) do
        allowed[prop.model] = true
    end

    local clean, rejected = {}, 0

    for _, prop in ipairs(props or {}) do
        local model = prop.model
        if type(model) == 'string' and tonumber(model) then model = tonumber(model) end

        if not allowed[model] then
            rejected = rejected + 1
        elseif #clean < Config.Props.maxPerTrack then
            clean[#clean + 1] = {
                model = model,
                x = tonumber(prop.x) or 0.0,
                y = tonumber(prop.y) or 0.0,
                z = tonumber(prop.z) or 0.0,
                heading = tonumber(prop.heading) or 0.0,
            }
        end
    end

    return clean, rejected
end

lib.callback.register('whip-racing:saveTrack', function(source, payload)
    if not canCreate(source) then
        return false, 'You do not have access to the track editor.'
    end

    local name = tostring(payload.name or ''):sub(1, 48)
    if #name < 3 then
        return false, 'Give the track a name of at least three characters.'
    end

    if type(payload.points) ~= 'table' or #payload.points < 2 then
        return false, 'A track needs at least two checkpoints.'
    end

    local previous = payload.id and Tracks.Get(payload.id)
    local points = cleanPoints(payload.points)
    local props, rejected = cleanProps(payload.props, previous and previous.props)
    local player = Bridge.GetPlayer(source)

    if rejected > 0 then
        print(('[whip-racing] %s tried to save %d prop(s) with models outside the catalogue; they were dropped')
            :format(GetPlayerName(source), rejected))
    end
    local stateId = player and player.citizenid or nil

    local isSprint = payload.circuit and 0 or 1
    local isPublished = payload.published and 1 or 0

    -- Editing an existing track overwrites it instead of leaving a duplicate
    -- behind, which also keeps the lap records attached to the same id.
    local existing = previous
    if existing then
        local isOwner = stateId and stateId == existing.creatorStateId
        if not isOwner and not Bridge.IsAdmin(source)
            and not IsPlayerAceAllowed(source, 'whipracing.editor') then
            return false, 'You can only edit tracks you created.'
        end

        MySQL.update.await(
            'UPDATE `whip_racing_tracks` SET `name` = ?, `checkpoints` = ?, `props` = ?, `isSprint` = ?, `isPublished` = ? WHERE `id` = ?',
            { name, json.encode(points), json.encode(props), isSprint, isPublished, existing.id })

        existing.name = name
        existing.points = points
        existing.props = props
        existing.checkpoints = #points
        existing.propCount = #props
        existing.distance = measure(points)
        existing.sprint = isSprint == 1
        existing.circuit = isSprint ~= 1
        existing.published = isPublished == 1

        return true, ('Updated "%s" with %d checkpoints.'):format(name, #points)
    end

    local id = MySQL.insert.await(
        'INSERT INTO `whip_racing_tracks` (`name`, `creatorStateId`, `checkpoints`, `props`, `isSprint`, `isPublished`) VALUES (?, ?, ?, ?, ?, ?)',
        { name, stateId, json.encode(points), json.encode(props), isSprint, isPublished })

    if not id then return false, 'The track could not be saved.' end

    Tracks.cache[id] = {
        id = id,
        name = name,
        creatorStateId = stateId,
        points = points,
        props = props,
        checkpoints = #points,
        propCount = #props,
        distance = measure(points),
        sprint = isSprint == 1,
        circuit = isSprint ~= 1,
        published = isPublished == 1,
        official = false,
        verified = false,
        featured = false,
    }

    return true, ('Saved "%s" with %d checkpoints.'):format(name, #points)
end)

--- Soft delete. The row stays put so an admin can undo it straight from the
--- database; it just stops being loaded.
lib.callback.register('whip-racing:deleteTrack', function(source, trackId)
    local track = Tracks.Get(trackId)
    if not track then return false, 'That track no longer exists.' end

    local player = Bridge.GetPlayer(source)
    local isOwner = player and player.citizenid == track.creatorStateId
    if not isOwner and not Bridge.IsAdmin(source)
            and not IsPlayerAceAllowed(source, 'whipracing.editor') then
        return false, 'You can only delete tracks you created.'
    end

    MySQL.update.await('UPDATE `whip_racing_tracks` SET `isDeleted` = 1 WHERE `id` = ?', { trackId })
    Tracks.cache[trackId] = nil

    return true, ('Deleted "%s".'):format(track.name)
end)

--- The admin screen's per-track switches. Only the flags are writable, and
--- only by someone with the ace: everything else about a track goes through
--- the editor.
local FLAG_COLUMNS = {
    isPublished = 'published',
    isOfficial = 'official',
    isVerified = 'verified',
    isFeatured = 'featured',
    isSprint = 'sprint',
}

lib.callback.register('whip-racing:setTrackFlag', function(source, trackId, key, value)
    if not Bridge.IsAdmin(source) then
        return nil, 'You do not have access to that.'
    end

    local field = FLAG_COLUMNS[key]
    if not field then return nil, 'That is not a track flag.' end

    local track = Tracks.Get(trackId)
    if not track then return nil, 'That track no longer exists.' end

    local on = value and true or false

    MySQL.update.await(('UPDATE `whip_racing_tracks` SET `%s` = ? WHERE `id` = ?'):format(key),
        { on and 1 or 0, track.id })

    track[field] = on
    if key == 'isSprint' then track.circuit = not on end

    return track
end)

--- Racer search for the profile screen, over recorded finishes.
lib.callback.register('whip-racing:searchRacers', function(_, query)
    query = tostring(query or ''):gsub('%%', ''):sub(1, 32)
    if #query < 2 then return {} end

    local like = '%' .. query .. '%'

    local rows = MySQL.query.await([[
        SELECT `citizenid`, MAX(`name`) AS name, COUNT(*) AS races
        FROM `whip_racing_race_results`
        WHERE (`name` LIKE ? OR `citizenid` LIKE ?) AND position IS NOT NULL AND time_ms IS NOT NULL
        GROUP BY `citizenid`
        ORDER BY races DESC
        LIMIT 25
    ]], { like, like }) or {}

    -- The query above only sees the name recorded with a time. Somebody racing
    -- under an alias would be unfindable by the name everyone actually sees
    -- them under, so aliases are matched separately and folded in.
    local found = {}
    for _, row in ipairs(rows) do found[row.citizenid] = true end

    local wanted = {}
    for citizenid, profile in pairs(Profiles.cache) do
        if not found[citizenid] and profile.nickname
            and profile.nickname:lower():find(query:lower(), 1, true) then
            wanted[#wanted + 1] = citizenid
        end
    end

    if #wanted > 0 then
        local placeholders = string.rep('?', #wanted, ', ')

        local extra = MySQL.query.await(([[
            SELECT `citizenid`, MAX(`name`) AS name, COUNT(*) AS races
            FROM `whip_racing_race_results`
            WHERE `citizenid` IN (%s) AND position IS NOT NULL AND time_ms IS NOT NULL
            GROUP BY `citizenid`
        ]]):format(placeholders), wanted) or {}

        for _, row in ipairs(extra) do
            rows[#rows + 1] = row
            found[row.citizenid] = true
        end

        -- An alias picked by somebody who has never finished a race has no row
        -- to join to, but they are still a racer worth finding.
        for _, citizenid in ipairs(wanted) do
            if not found[citizenid] then
                rows[#rows + 1] = { citizenid = citizenid, name = nil, races = 0 }
            end
        end
    end

    for _, row in ipairs(rows) do
        row.name = Profiles.DisplayName(row.citizenid, row.name)
    end

    table.sort(rows, function(a, b)
        if a.races == b.races then return a.name < b.name end
        return (tonumber(a.races) or 0) > (tonumber(b.races) or 0)
    end)

    while #rows > 25 do rows[#rows] = nil end

    return rows
end)

-- Once the tables exist (server/whip.lua on WHIP; at resource start otherwise).
Bridge.OnReady(function()
    Tracks.LoadAll()
end)

-- ---------------------------------------------------------------- Diagnostics

--- Prints what the server actually holds, and why any given track is or is not
--- reaching the browser. The usual answer to "my tracks are in the database but
--- not in the menu" is that they are sitting there unpublished.
Bridge.RegisterCommand('trackList', 'racing:tracks', function(source)
    if source ~= 0 then return end

    local rows = MySQL.query.await('SELECT `id`, `name`, `isPublished`, `isDeleted`, `isSprint` FROM `whip_racing_tracks`') or {}

    local cached = 0
    for _ in pairs(Tracks.cache) do cached = cached + 1 end

    print(('[whip-racing] %d rows in whip_racing_tracks, %d loaded into the cache'):format(#rows, cached))

    for _, row in ipairs(rows) do
        local track = Tracks.cache[row.id]
        local status

        if truthy(row.isDeleted) then
            status = 'deleted (isDeleted = 1)'
        elseif not track then
            status = 'NOT LOADED - check the console for a decode error'
        elseif not track.published then
            status = 'unpublished - only its creator sees it'
        else
            status = ('listed, %d checkpoints, %d props'):format(track.checkpoints, track.propCount)
        end

        print(('  #%s  %-28s %s'):format(row.id, row.name, status))
    end

    print(('[whip-racing] raw isPublished type for the first row: %s')
        :format(rows[1] and type(rows[1].isPublished) or 'no rows'))
end, true)

--- Prints the raw stored JSON for one track. Use this when checkpoints are
--- being skipped, so the actual key names are visible rather than guessed at.
Bridge.RegisterCommand('trackDump', 'racing:dump', function(source, args)
    if source ~= 0 then return end

    local id = tonumber(args[1])
    if not id then
        print('[whip-racing] usage: racing:dump <trackId>')
        return
    end

    local row = MySQL.single.await('SELECT `name`, `checkpoints`, `props` FROM `whip_racing_tracks` WHERE `id` = ?', { id })
    if not row then
        print(('[whip-racing] no track with id %d'):format(id))
        return
    end

    print(('[whip-racing] track %d "%s"'):format(id, row.name))
    print(('  checkpoints (first 600 chars): %s'):format((row.checkpoints or ''):sub(1, 600)))
    print(('  props (first 300 chars): %s'):format((row.props or 'NULL'):sub(1, 300)))

    local decoded = json.decode(row.checkpoints or '[]')
    local first = type(decoded) == 'table' and decoded[1]

    if type(first) == 'table' then
        local keys = {}
        for key in pairs(first) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        print(('  keys on the first checkpoint: %s'):format(table.concat(keys, ', ')))
    else
        print(('  first checkpoint is not a table (%s)'):format(type(first)))
    end
end, true)

--- Publishes every track that is not deleted. Console only.
Bridge.RegisterCommand('publishAll', 'racing:publishall', function(source)
    if source ~= 0 then return end

    local affected = MySQL.update.await('UPDATE `whip_racing_tracks` SET `isPublished` = 1 WHERE `isDeleted` = 0')
    Tracks.LoadAll()
    print(('[whip-racing] published %s tracks'):format(affected or 0))
end, true)
