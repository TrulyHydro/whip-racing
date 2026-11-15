-- Crew ownership persists independently of racer settings and race records.
local ready = false
local busy = false

MySQL.ready(function()
    local ok, err = pcall(MySQL.query.await, [[
        CREATE TABLE IF NOT EXISTS `whip_racing_crews` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `name` VARCHAR(32) NOT NULL,
            `tag` VARCHAR(4) NOT NULL,
            `owner` VARCHAR(64) NOT NULL,
            `ownerName` VARCHAR(64) NOT NULL,
            `createdAt` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`), UNIQUE KEY (`name`),
            UNIQUE KEY (`tag`), UNIQUE KEY (`owner`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    ready = ok
    if not ok then print(('[whip-racing] Crew storage unavailable: %s'):format(err)) end
end)

local function view(row)
    if not row then return nil end
    return {
        id = row.id, name = row.name, tag = row.tag, owner = row.owner,
        color = '#60a5fa', createdAt = row.createdAt, maxMembers = 12,
        elo = 0, position = 0, totalRaces = 0, wonRaces = 0, lastDeltaElo = 0,
        members = { [row.owner] = {
            stateId = row.owner, nickname = Profiles.DisplayName(row.owner, row.ownerName),
            role = 'leader', elo = 0, lastActive = row.createdAt,
        } },
        roles = {
            leader = { id = 'leader', label = 'Leader', permissions = {
                createBattles = false, inviteMembers = false,
                kickMembers = false, manageMembers = false,
            } },
            member = { id = 'member', label = 'Member', permissions = {} },
        },
    }
end

local function getCrew(id, owner)
    if not ready then return nil end
    local row = MySQL.single.await(
        'SELECT *, UNIX_TIMESTAMP(`createdAt`) * 1000 AS `createdAt` FROM `whip_racing_crews` WHERE '
        .. (id and '`id` = ?' or '`owner` = ?'), { id or owner })
    return view(row)
end

lib.callback.register('whip-racing:getUserCrew', function(source)
    local player = Bridge.GetPlayer(source)
    return player and getCrew(nil, player.citizenid)
end)

lib.callback.register('whip-racing:loadCrew', function(_, data)
    return getCrew(tonumber(data and data.crewId) or -1)
end)

lib.callback.register('whip-racing:loadCrews', function(_, data)
    if not ready then return {} end
    data = type(data) == 'table' and data or {}
    local query = tostring(data.query or data.search or ''):lower()
    local list = {}
    for _, row in ipairs(MySQL.query.await(
        'SELECT *, UNIX_TIMESTAMP(`createdAt`) * 1000 AS `createdAt` FROM `whip_racing_crews` ORDER BY `id`') or {}) do
        if row.name:lower():find(query, 1, true) or row.tag:lower():find(query, 1, true) then
            list[#list + 1] = view(row)
        end
    end
    local result = {}
    local offset = math.max(0, math.floor(tonumber(data.offset) or 0))
    for i = offset + 1, math.min(#list, offset + 50) do
        list[i].position = i
        result[#result + 1] = list[i]
    end
    return result
end)

lib.callback.register('whip-racing:createCrew', function(source, data)
    if not ready then return { success = false, error = 'Crew storage is unavailable. Check the server console.' } end
    if busy then return { success = false, error = 'Another crew is being created. Please try again.' } end
    local player = Bridge.GetPlayer(source)
    if not player then return { success = false, error = 'Your character is unavailable.' } end
    data = type(data) == 'table' and data or {}
    local name = tostring(data.name or ''):gsub('^%s+', ''):gsub('%s+$', '')
    local tag = tostring(data.tag or ''):upper()
    if #name < 3 or #name > 32 or not name:match('^[%w%s._-]+$') then
        return { success = false, error = 'Crew names must contain 3–32 letters, numbers, spaces, dots, dashes or underscores.' }
    end
    if #tag < 2 or #tag > 4 or not tag:match('^[A-Z0-9]+$') then
        return { success = false, error = 'Crew tags must contain 2–4 letters or numbers.' }
    end
    local fee = math.max(0, tonumber(Config.CrewCreateMoney) or 5000)
    local paid = false
    busy = true
    local ok, result = pcall(function()
        if getCrew(nil, player.citizenid) then
            return { success = false, error = 'You already belong to a crew.' }
        end
        if MySQL.scalar.await('SELECT `id` FROM `whip_racing_crews` WHERE `name` = ? OR `tag` = ?', { name, tag }) then
            return { success = false, error = 'That crew name or tag is already taken.' }
        end
        if fee > 0 then
            if not Bridge.hasEconomy or player.getMoney(Config.MoneyAccount) < fee
                or not player.removeMoney(Config.MoneyAccount, fee, 'racing-create-crew') then
                return { success = false, error = ('You need $%s in your %s account.'):format(fee, Config.MoneyAccount) }
            end
            paid = true
        end
        local id = MySQL.insert.await(
            'INSERT INTO `whip_racing_crews` (`name`, `tag`, `owner`, `ownerName`) VALUES (?, ?, ?, ?)',
            { name, tag, player.citizenid, player.name })
        if not id then error('Crew insert returned no ID') end
        -- No additional database request after payment has been committed.
        return { success = true, crew = view({ id = id, name = name, tag = tag,
            owner = player.citizenid, ownerName = player.name, createdAt = os.time() * 1000 }) }
    end)
    busy = false
    if ok then return result end
    if paid then player.addMoney(Config.MoneyAccount, fee, 'racing-create-crew-refund') end
    print(('[whip-racing] Crew creation failed: %s'):format(result))
    return { success = false, error = 'Could not save your crew. Please try again.' }
end)

lib.callback.register('whip-racing:leaveCrew', function(source, data)
    local player = Bridge.GetPlayer(source)
    if not ready or not player then return { success = false, error = 'Crew storage or your character is unavailable.' } end
    local count = MySQL.update.await('DELETE FROM `whip_racing_crews` WHERE `id` = ? AND `owner` = ?',
        { tonumber(data and data.crewId) or -1, player.citizenid })
    return { success = count == 1, error = count ~= 1 and 'You do not own this crew.' or nil }
end)
