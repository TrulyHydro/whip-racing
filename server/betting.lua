Betting = {}

local pinkTable = Config.PinkSlips.table
local ownerColumn = Config.PinkSlips.ownerColumn
local plateColumn = Config.PinkSlips.plateColumn

--- Takes the buy-in up front so nobody can race on money they've since spent.
function Betting.TakeBuyin(src, amount)
    if not Bridge.hasEconomy and amount > 0 then return false, 'Paid races are unavailable in standalone mode.' end
    if not Config.Buyin.enabled or amount <= 0 then return true end

    local player = Bridge.GetPlayer(src)
    if not player then return false, 'Player not found.' end

    if player.getMoney(Config.MoneyAccount) < amount then
        return false, ('You need $%s to enter.'):format(amount)
    end

    if not player.removeMoney(Config.MoneyAccount, amount, 'race-buyin') then
        return false, 'The buy-in could not be taken.'
    end

    return true
end

function Betting.Refund(src, amount)
    if not Config.Buyin.enabled or amount <= 0 then return end
    local player = Bridge.GetPlayer(src)
    if player then player.addMoney(Config.MoneyAccount, amount, 'race-refund') end
end

--- Confirms the racer actually owns the car they're staking.
function Betting.VerifyPinkSlip(src, plate, class)
    if not Bridge.hasEconomy then return false, 'Pink slips are unavailable in standalone mode.' end
    if not Config.PinkSlips.enabled then return false, 'Pink slips are disabled.' end
    if not plate then return false, 'You need to be in a vehicle.' end

    for _, blocked in ipairs(Config.PinkSlips.blockedClasses) do
        if blocked == class then
            return false, 'That vehicle class cannot be staked.'
        end
    end

    if not Config.PinkSlips.requireOwnership then return true end

    local player = Bridge.GetPlayer(src)
    if not player then return false, 'Player not found.' end

    -- WHIP: ask whip_core about the car the racer is actually sitting in, rather
    -- than trusting the plate the client sent.
    if Bridge.framework == 'whip' then
        local ped = GetPlayerPed(src)
        local vehicle = ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
        local v = vehicle ~= 0 and Whip.core:GetVehicle({ entity = vehicle }) or nil
        local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end
        if type(v) ~= 'table' or v.session or not v.owner or tostring(v.owner.charId) ~= player.citizenid
            or trim(v.plate) ~= trim(plate) then
            return false, 'You can only stake a vehicle you own.'
        end
        return true
    end

    -- Hydro: ask the core about the car the racer is actually sitting in,
    -- rather than trusting the plate the client sent.
    if Bridge.framework == 'hydro' then
        local ped = GetPlayerPed(src)
        local vehicle = ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
        local info = vehicle ~= 0 and exports['hydro-core']:GetVehicleInfo(vehicle)
        if not info or not info.owned or info.cid ~= player.citizenid or info.plate ~= plate then
            return false, 'You can only stake a vehicle you own.'
        end
        return true
    end

    local owner = MySQL.scalar.await(
        ('SELECT %s FROM %s WHERE %s = ? LIMIT 1'):format(ownerColumn, pinkTable, plateColumn),
        { plate })

    if not owner then
        return false, 'That vehicle is not registered to anyone.'
    end

    if owner ~= player.citizenid then
        return false, 'You can only stake a vehicle you own.'
    end

    return true
end

--- Moves a staked vehicle to the winner and marks it as stored so it can be
--- pulled from a garage rather than vanishing with the despawned entity.
function Betting.TransferVehicle(plate, toCitizenId)
    if not Bridge.hasEconomy then return false end
    if not plate then return false end

    -- WHIP: the winner (online, they just finished) becomes the owner and gets a key; the
    -- loser's keys in their pockets are taken.
    if Bridge.framework == 'whip' then
        local v = Whip.core:GetVehicle({ plate = (tostring(plate):gsub('^%s+', ''):gsub('%s+$', '')) })
        if type(v) ~= 'table' or not v.vehicleId then return false end
        local ok, why = Whip.core:TransferVehicle(v.vehicleId, { charId = tonumber(toCitizenId) },
            { giveKey = true, revokeOldKeys = true })
        if not ok then print(('[whip-racing] pink slip %s not transferred: %s'):format(plate, tostring(why))) end
        return ok == true
    end

    -- Hydro: the core despawns the car and parks it in the winner's garage.
    if Bridge.framework == 'hydro' then
        return exports['hydro-core']:TransferVehicle(plate, toCitizenId, Config.Hydro.pinkSlipGarage) and true or false
    end

    local affected = MySQL.update.await(
        ('UPDATE %s SET %s = ?, state = 1, garage = ? WHERE %s = ?'):format(pinkTable, ownerColumn, plateColumn),
        { toCitizenId, 'pillboxgarage', plate })

    return (affected or 0) > 0
end

--- Splits the pot by finishing order using the configured payout table.
function Betting.PayOut(pot, finishers)
    if not Bridge.hasEconomy then return {} end
    if pot <= 0 or #finishers == 0 then return {} end

    local rake = math.floor(pot * (Config.Buyin.rake or 0.0))
    local payable = pot - rake

    local split = Config.Buyin.payouts[math.min(#finishers, 4)] or { 1.0 }
    local awarded = {}

    for place, entry in ipairs(finishers) do
        local share = split[place]
        if share and share > 0 then
            local amount = math.floor(payable * share)
            local player = Bridge.GetPlayer(entry.source)
            if player and amount > 0 then
                player.addMoney(Config.MoneyAccount, amount, 'race-payout')
                awarded[#awarded + 1] = { name = entry.name, place = place, amount = amount }
            end
        end
    end

    return awarded
end

-- ------------------------------------------------------- Position rewards
--
-- Items an admin attaches to finishing places when creating a race. The picker
-- in the race creator reads the catalogue below; the payout happens when the
-- results are worked out.

--- Everything ox_inventory knows about, as { name, label } pairs the picker can
--- show. Read through the export rather than by parsing data/items.lua: the
--- export *is* that file already loaded, so it stays right when the file moves
--- or a script registers an item at runtime.
---
--- `query` filters on both the name and the label, because an admin looking
--- for "Racing Case" will type either.
lib.callback.register('whip-racing:getRewardItems', function(source, query)
    if not Bridge.IsAdmin(source) then return {} end

    local catalogue = Bridge.ItemCatalogue()
    if not next(catalogue) then
        print('[whip-racing] no inventory item list available -- no items to offer as rewards')
        return {}
    end

    query = tostring(query or ''):lower()

    local matches = {}

    for name, item in pairs(catalogue) do
        local label = item.label or name

        if query == ''
            or tostring(name):lower():find(query, 1, true)
            or tostring(label):lower():find(query, 1, true) then
            matches[#matches + 1] = { name = name, label = label }
        end
    end

    table.sort(matches, function(a, b) return a.label:lower() < b.label:lower() end)

    -- The picker is a dropdown, not a catalogue browser. Everything matches on
    -- an empty query, and a few thousand rows helps nobody -- typing narrows.
    while #matches > Config.Rewards.pickerLimit do matches[#matches] = nil end

    return matches
end)

--- Holds an incoming reward list to what the server is willing to hand out.
---
--- This is the security boundary for the feature. The creator screen is only
--- shown to admins, but that is a UI decision and a UI decision is not a
--- permission: without this, anyone able to post to the endpoint could attach
--- a thousand gold bars to first place and then win their own race.
function Betting.CleanRewards(source, incoming)
    if type(incoming) ~= 'table' then return nil end
    if not Bridge.IsAdmin(source) then return nil end

    local catalogue = Bridge.ItemCatalogue()

    local clean = {}

    for place, entry in pairs(incoming) do
        local position = tonumber(place)

        if position and position >= 1 and position <= Config.Rewards.maxPositions then
            local items = {}

            for _, reward in ipairs(type(entry) == 'table' and (entry.items or entry) or {}) do
                local name = reward and reward.name

                -- An item nobody has heard of is dropped rather than trusted.
                if name and catalogue[name] then
                    local count = math.floor(tonumber(reward.count) or 1)
                    count = math.max(1, math.min(Config.Rewards.maxItemCount, count))

                    items[#items + 1] = { name = name, count = count }

                    if #items >= Config.Rewards.maxItemsPerPosition then break end
                end
            end

            if #items > 0 then clean[tostring(position)] = items end
        end
    end

    if not next(clean) then return nil end

    return clean
end

--- Hands out whatever was attached to each finishing place. Anything that will
--- not fit is reported rather than silently dropped, the same way the daily
--- case is.
function Betting.PayRewards(lobby, finishers)
    if not lobby.rewards then return end

    for place, entry in ipairs(finishers) do
        local items = lobby.rewards[tostring(place)]

        if items then
            for _, reward in ipairs(items) do
                if not Bridge.GiveItem(entry.source, reward.name, reward.count) then
                    Bridge.Notify(entry.source,
                        'No room for a finishing reward -- see an admin.', 'error')

                    print(('[whip-racing] %s had no room for %s x%d (place %d)')
                        :format(entry.name, reward.name, reward.count, place))
                end
            end
        end
    end
end
