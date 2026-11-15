-- Hydro framework adapter. Loaded after shared/bridge.lua; does nothing unless
-- hydro-core is the framework in use.
--
-- What changes on Hydro:
--   * Racing classes come from each car's Performance Index instead of the
--     hand-written lists in config/vehicle_classes.lua. The tablet only knows
--     S, A, B, C and D, so hydro-core folds S1, S2 and X into S.
--   * A lobby checks the class of the actual car, upgrades included.
--   * Finishing a race pays driver XP.

if Bridge.framework ~= 'hydro' then return end

local core = exports['hydro-core']
local unclassified = Config.UnclassifiedVehicleClass

local function hashOf(model)
    return tonumber(model) or joaat(tostring(model):lower())
end

function VehicleClasses.Get(model)
    if model == nil then return unclassified end
    local ok, class = pcall(function() return core:GetModelRaceClass(hashOf(model)) end)
    return ok and class or unclassified
end

function VehicleClasses.OfVehicle(vehicle)
    if not vehicle or vehicle == 0 then return unclassified end
    local ok, class = pcall(function() return core:GetVehicleRaceClass(vehicle) end)
    return ok and class or unclassified
end

if IsDuplicityVersion() then
    -- Prefer the spawn name hydro-core has on record, so results and records
    -- store "sultan" rather than a hash for cars missing from the class lists.
    local baseModel = VehicleClasses.Model

    function VehicleClasses.Model(hash, fallback)
        local ok, name = pcall(function() return core:GetModelName(hash) end)
        if ok and name then return name end
        return baseModel(hash, fallback)
    end

    function Bridge.RaceFinished(finishers)
        local xp = Config.Hydro.xp
        for place, entry in ipairs(finishers) do
            local amount = place == 1 and xp.win or place <= 3 and xp.podium or xp.finish
            if amount and amount > 0 then core:AddXP(entry.source, amount, 'race') end
        end
    end
end
