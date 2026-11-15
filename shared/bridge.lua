Bridge = {}

local function detect()
    if Config.Framework ~= 'auto' then return Config.Framework end
    -- whip_core is a dependency in fxmanifest.lua, so it is already started (or starting) here.
    if GetResourceState('whip_core') ~= 'missing' and Whip then return 'whip' end
    if GetResourceState('hydro-core') == 'started' then return 'hydro' end
    if GetResourceState('qbx_core') == 'started' then return 'qbx' end
    if GetResourceState('qb-core') == 'started' then return 'qb' end
    return 'standalone'
end

Bridge.framework = detect()
Bridge.hasEconomy = Bridge.framework ~= 'standalone'

function Bridge.CommandEnabled(key)
    return not Config.Commands or Config.Commands[key] ~= false
end

function Bridge.RegisterCommand(key, name, callback, restricted)
    if Bridge.CommandEnabled(key) then
        RegisterCommand(name, callback, restricted)
    end
end

local QB
if Bridge.framework == 'qb' then
    QB = exports['qb-core']:GetCoreObject()
end

--- Formats milliseconds as m:ss.mmm, the format used everywhere in the UI.
function Bridge.FormatTime(ms)
    if not ms or ms < 0 then return '--:--.---' end
    local minutes = math.floor(ms / 60000)
    local seconds = math.floor((ms % 60000) / 1000)
    local millis = math.floor(ms % 1000)
    return ('%d:%02d.%03d'):format(minutes, seconds, millis)
end

--- Formats a signed delta as +/-s.mmm for split comparisons.
function Bridge.FormatDelta(ms)
    if ms == nil then return nil end
    local sign = ms >= 0 and '+' or '-'
    local abs = math.abs(ms)
    return ('%s%d.%03d'):format(sign, math.floor(abs / 1000), math.floor(abs % 1000))
end

function Bridge.Ordinal(n)
    local suffix = 'th'
    local mod100 = n % 100
    if mod100 < 11 or mod100 > 13 then
        local mod10 = n % 10
        if mod10 == 1 then suffix = 'st'
        elseif mod10 == 2 then suffix = 'nd'
        elseif mod10 == 3 then suffix = 'rd' end
    end
    return n .. suffix
end

if IsDuplicityVersion() then
    --- Returns a normalised player object: { id, citizenid, name, money(account), removeMoney, addMoney }
    function Bridge.GetPlayer(src)
        if Bridge.framework == 'whip' then
            -- citizenid is the WHIP charId as text: the tables keep VARCHAR ids, and the tablet
            -- compares them as strings. Never the server id, which the next player can get.
            local charId = Whip.core:GetCharId(src)
            if not charId then return nil end
            local name = Whip.core:GetPlayerFullName(src)
            local function method(account) return account == 'bank' and 'bank' or 'cash' end
            return {
                source = src,
                charId = charId,
                citizenid = tostring(charId),
                name = (type(name) == 'string' and name ~= '') and name or GetPlayerName(src),
                getMoney = function(account)
                    if method(account) == 'bank' then return tonumber((Whip.core:GetBalance(src))) or 0 end
                    return tonumber((Whip.core:GetPlayerCash(src))) or 0
                end,
                removeMoney = function(account, amount, reason)
                    local receipt = Whip.core:ChargePlayer(src, math.floor(amount),
                        { method = method(account), reason = 'Racing: ' .. tostring(reason or 'payment') })
                    return receipt and true or false
                end,
                addMoney = function(account, amount, reason)
                    local paid = Whip.core:PayPlayer(src, math.floor(amount),
                        { method = method(account), reason = 'Racing: ' .. tostring(reason or 'payout') })
                    return paid and true or false
                end,
            }
        elseif Bridge.framework == 'hydro' then
            -- One currency: whatever Config.MoneyAccount says, races use the
            -- core's credits account.
            local core = exports['hydro-core']
            local player = core:GetPlayer(src)
            if not player then return nil end
            local account = core:GetCurrencyAccount()
            return {
                source = src,
                citizenid = player.cid,
                name = player.name,
                getMoney = function() return core:GetMoney(src, account) end,
                removeMoney = function(_, amount, reason)
                    return core:RemoveMoney(src, account, amount, reason)
                end,
                addMoney = function(_, amount, reason)
                    return core:AddMoney(src, account, amount, reason)
                end,
            }
        elseif Bridge.framework == 'qbx' then
            local player = exports.qbx_core:GetPlayer(src)
            if not player then return nil end
            return {
                source = src,
                citizenid = player.PlayerData.citizenid,
                name = ('%s %s'):format(player.PlayerData.charinfo.firstname, player.PlayerData.charinfo.lastname),
                getMoney = function(account) return player.PlayerData.money[account] or 0 end,
                removeMoney = function(account, amount, reason)
                    return player.Functions.RemoveMoney(account, amount, reason)
                end,
                addMoney = function(account, amount, reason)
                    return player.Functions.AddMoney(account, amount, reason)
                end,
            }
        elseif Bridge.framework == 'qb' then
            local player = QB.Functions.GetPlayer(src)
            if not player then return nil end
            return {
                source = src,
                citizenid = player.PlayerData.citizenid,
                name = ('%s %s'):format(player.PlayerData.charinfo.firstname, player.PlayerData.charinfo.lastname),
                getMoney = function(account) return player.PlayerData.money[account] or 0 end,
                removeMoney = function(account, amount, reason)
                    return player.Functions.RemoveMoney(account, amount, reason)
                end,
                addMoney = function(account, amount, reason)
                    return player.Functions.AddMoney(account, amount, reason)
                end,
            }
        end

        -- Never persist a temporary server ID: it can belong to someone else later.
        local license = GetPlayerIdentifierByType(src, 'license')
            or GetPlayerIdentifierByType(src, 'license2')
        if not license or not GetPlayerName(src) then return nil end
        return {
            source = src,
            citizenid = license,
            name = GetPlayerName(src),
            getMoney = function() return 0 end,
            removeMoney = function() return false end,
            addMoney = function() return false end,
        }
    end

    --- Puts an item in a player's inventory. Returns false when it could not
    --- be placed -- a full inventory being the usual reason -- so a caller can
    --- decline to mark a reward as claimed rather than swallowing it.
    ---
    --- ox_inventory is preferred and its AddItem reports success; the
    --- framework fallback does not, so there it is taken on trust.
    function Bridge.GiveItem(src, item, count)
        count = count or 1

        -- WHIP: noDrop, so a full inventory refuses rather than dropping the reward at their feet;
        -- the daily case then stays claimable once they free a slot.
        if Bridge.framework == 'whip' then
            local where, why = Whip.core:AddItem(src, item, count, nil, { reason = 'whip-racing reward', noDrop = true })
            if not where then
                print(('[whip-racing] could not give %s x%d to %s: %s'):format(item, count, src, tostring(why)))
                return false
            end
            return true
        end

        -- Hydro has no inventory: an item reward pays its credit value instead.
        if Bridge.framework == 'hydro' then
            local value = Config.Hydro.itemValues[item]
            if not value then
                print(('[whip-racing] no credit value set for reward item %s (Config.Hydro.itemValues)'):format(item))
                return false
            end
            local core = exports['hydro-core']
            return core:AddMoney(src, core:GetCurrencyAccount(), value * count, 'race-reward') and true or false
        end

        if GetResourceState('ox_inventory') == 'started' then
            local ok, result = pcall(function()
                return exports.ox_inventory:AddItem(src, item, count)
            end)

            if not ok then
                print(('[whip-racing] could not give %s to %s: %s'):format(item, src, result))
                return false
            end

            return result and true or false
        end

        if Bridge.framework == 'qbx' then
            local player = exports.qbx_core:GetPlayer(src)
            return player and exports.ox_inventory:AddItem(src, item, count) and true or false
        elseif Bridge.framework == 'qb' then
            local player = QB.Functions.GetPlayer(src)
            if not player then return false end
            return player.Functions.AddItem(item, count) and true or false
        end

        print(('[whip-racing] no inventory to give %s x%d to %s'):format(item, count, src))
        return false
    end

    --- Whether this player runs the tablet's admin section.
    ---
    --- Empty Config.Admins means nobody, not everybody -- the opposite of
    --- Config.CreatorWhitelist, because the wrong default here hands the whole
    --- server the ability to delete other people's tracks. The ace is checked
    --- as well, so permissions can live in server.cfg instead if preferred.
    ---
    --- Never trust the client's word on this: every admin callback asks again.
    function Bridge.MatchesIdentity(src, entries)
        local player = Bridge.GetPlayer(src)
        local license = GetPlayerIdentifierByType(src, 'license')
        local license2 = GetPlayerIdentifierByType(src, 'license2')
        for _, identifier in ipairs(entries or {}) do
            if type(identifier) == 'string' then
                if identifier:match('^license2?:') then
                    if identifier == license or identifier == license2 then return true end
                elseif player and identifier == player.citizenid then
                    return true
                end
            end
        end
        return false
    end

    function Bridge.IsAdmin(src)
        if Bridge.MatchesIdentity(src, Config.Admins) or IsPlayerAceAllowed(src, 'whipracing.admin') then
            return true
        end
        -- WHIP: the whip-racing.admin permission (given in /whip → Player Manager → Permissions),
        -- which full admins (whip.devtools with developer mode on) hold too.
        return Bridge.framework == 'whip' and Whip.core:HasPermission(src, 'whip-racing.admin') == true
    end

    --- Every item the inventory knows, as { [name] = { label } }, for the reward picker and
    --- for checking an admin's reward list.
    function Bridge.ItemCatalogue()
        if Bridge.framework == 'whip' then
            local defs = Whip.core:GetItemDefs()
            local out = {}
            if type(defs) == 'table' then
                for key, def in pairs(defs) do
                    out[key] = { label = type(def) == 'table' and def.name or key }
                end
            end
            return out
        end
        if GetResourceState('ox_inventory') == 'started' then
            local ok, list = pcall(function() return exports.ox_inventory:Items() end)
            if ok and type(list) == 'table' then return list end
        end
        return {}
    end

    --- Run fn once the database tables exist (server/whip.lua makes them on WHIP).
    local readyFns, isReady = {}, false
    function Bridge.OnReady(fn)
        if isReady then CreateThread(fn) else readyFns[#readyFns + 1] = fn end
    end
    function Bridge.MarkReady()
        if isReady then return end
        isReady = true
        for _, fn in ipairs(readyFns) do CreateThread(fn) end
        readyFns = {}
    end
    if Bridge.framework ~= 'whip' then
        -- Other frameworks: the tables come from sql/install.sql, as before.
        AddEventHandler('onResourceStart', function(resource)
            if resource ~= GetCurrentResourceName() then return end
            Wait(500)
            Bridge.MarkReady()
        end)
    end

    --- A net event from the client. On WHIP a SecureEvent (checked values, rate limit, loaded and
    --- alive unless the schema says otherwise); elsewhere a plain net event. fn(src, ...values).
    function Bridge.NetEvent(name, schema, fn)
        if Bridge.framework == 'whip' then
            Whip.register(function()
                Whip.core:SecureEvent(name, schema, function(src, _, ...) return fn(src, ...) end)
            end)
            return
        end
        RegisterNetEvent(name, function(...) fn(source, ...) end)
    end

    function Bridge.Notify(src, message, type)
        if Bridge.framework == 'whip' then
            local kind = ({ success = 'success', error = 'error', warning = 'warning' })[type] or 'info'
            Whip.core:NotifyPlayer(src, message, kind)
            return
        end
        TriggerClientEvent('ox_lib:notify', src, {
            title = 'Racing',
            description = message,
            type = type or 'inform',
        })
    end
else
    function Bridge.Notify(message, type)
        if Bridge.framework == 'whip' then
            local kind = ({ success = 'success', error = 'error', warning = 'warning' })[type] or 'info'
            Whip.core:Notify(message, kind)
            return
        end
        lib.notify({
            title = 'Racing',
            description = message,
            type = type or 'inform',
        })
    end

    function Bridge.GetCitizenId()
        if Bridge.framework == 'whip' then
            local charId = Whip.core:GetCharId()
            return charId and tostring(charId) or nil
        elseif Bridge.framework == 'hydro' then
            local data = exports['hydro-core']:GetPlayerData()
            return data and data.cid
        elseif Bridge.framework == 'qbx' then
            local data = exports.qbx_core:GetPlayerData()
            return data and data.citizenid
        elseif Bridge.framework == 'qb' then
            local data = QB.Functions.GetPlayerData()
            return data and data.citizenid
        end
        return nil
    end
end
