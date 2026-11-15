-- ============================================
-- Racing Case: opening one
--
-- The server decides everything: using a racing_case rolls a prize from Config.Case.contents
-- (set by admins in /whip → Settings → WHIP Racing), gives it, and only then lets WHIP use the
-- case up. The client is sent a reel to play that already ends on that prize: it is a show,
-- never a choice, so nothing the client does can change what was won.
--
-- No room for the prize: nothing is given and the case is kept (noDrop), with a message.
-- ============================================

if Bridge.framework ~= 'whip' then return end

local RARITY = { common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5 }
local REEL_TILES, WIN_TILE = 56, 48   -- the reel's length, and where the prize sits on it

local warned = {}   -- [item key] = true once a bad row's line is printed

--- Config.Case.contents as rows that can be won: real items, sane numbers, a weight above 0.
---@return table rows, number total
local function prizeTable()
    local defs = exports.whip_core:GetItemDefs()
    if type(defs) ~= 'table' then return {}, 0 end

    local rows, total = {}, 0
    for i, r in ipairs(type(Config.Case) == 'table' and Config.Case.contents or {}) do
        local key = type(r) == 'table' and r.item or nil
        local weight = math.floor(tonumber(type(r) == 'table' and r.weight) or 0)
        if key and defs[key] and weight > 0 then
            local min = math.max(1, math.floor(tonumber(r.min) or 1))
            local max = math.max(min, math.floor(tonumber(r.max) or min))
            rows[#rows + 1] = {
                item   = key,
                min    = min,
                max    = max,
                weight = weight,
                rarity = RARITY[r.rarity] and r.rarity or 'common',
                label  = (type(r.label) == 'string' and r.label ~= '') and r.label or defs[key].name or key,
                image  = (type(r.image) == 'string' and r.image ~= '') and r.image or nil,
            }
            total = total + weight
        elseif not warned[tostring(key or i)] then
            warned[tostring(key or i)] = true
            print(('^3[whip-racing] Racing Case row %d skipped: %s^0'):format(i,
                not key and 'no item key' or not defs[key] and ('no item called "' .. tostring(key) .. '"')
                or 'its weight must be 1 or more'))
        end
    end
    return rows, total
end

local function roll(rows, total)
    local at = math.random() * total
    for _, r in ipairs(rows) do
        at = at - r.weight
        if at <= 0 then return r end
    end
    return rows[#rows]
end

--- One tile of the reel, as the page shows it.
local function tile(row, amount)
    return { item = row.item, label = row.label, rarity = row.rarity, image = row.image, amount = amount }
end

local function amountText(item, amount)
    if item == 'cash' then return ('$%s'):format(tostring(amount):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')) end
    return amount > 1 and ('%dx'):format(amount) or nil
end

local function open(source, _, _, _)
    if type(Config.Case) ~= 'table' or not Config.Case.enabled then
        return false, 'Racing cases cannot be opened right now'
    end

    local rows, total = prizeTable()
    if #rows == 0 or total <= 0 then
        return false, 'This case has nothing in it yet: an admin sets its prizes in /whip → Settings'
    end

    local prize = roll(rows, total)
    local amount = math.random(prize.min, prize.max)

    -- Given first; the case is used up only because this handler then returns true.
    local where, why = exports.whip_core:AddItem(source, prize.item, amount, nil,
        { reason = 'Racing Case', noDrop = true })
    if not where then
        return false, ('No room for your prize (%s). Make space and open it again'):format(tostring(why))
    end

    -- The reel: random fillers by the same chances, with the prize at WIN_TILE.
    local reel = {}
    for i = 1, REEL_TILES do
        if i == WIN_TILE then
            reel[i] = tile(prize, amount)
            reel[i].amountText = amountText(prize.item, amount)
        else
            reel[i] = tile(roll(rows, total))
        end
    end

    TriggerClientEvent('whip-racing:caseOpen', source, {
        reel = reel,
        win = WIN_TILE,
        seconds = math.max(3, math.min(12, tonumber(Config.Case.spinSeconds) or 6)),
    })

    print(('[whip-racing] %s [%d] opened a Racing Case: %s x%d (%s)'):format(
        GetPlayerName(source) or '?', source, prize.item, amount, prize.rarity))
    return true
end

Whip.register(function()
    Whip.core:RegisterUseHandler('racing_case', open)
end)
