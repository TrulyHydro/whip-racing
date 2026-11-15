VehicleClasses = {}
local byHash, byName = {}, {}
for class, models in pairs(Config.VehicleClasses) do
    for _, model in ipairs(models) do
        local name = model:lower()
        local hash = joaat(name) % 4294967296
        assert(not byHash[hash], ('Vehicle %s is assigned to more than one racing class'):format(name))
        byHash[hash] = { name = name, class = class }
        byName[name] = byHash[hash]
    end
end
function VehicleClasses.Get(model)
    local entry = type(model) == 'string' and byName[model:lower()] or nil
    entry = entry or (model and byHash[(tonumber(model) or joaat(tostring(model):lower())) % 4294967296])
    return entry and entry.class or Config.UnclassifiedVehicleClass
end
function VehicleClasses.Model(hash, fallback)
    hash = hash % 4294967296
    return byHash[hash] and byHash[hash].name or fallback or tostring(hash)
end
function VehicleClasses.Selection(value)
    if value == nil or value == '' then return {} end
    if type(value) == 'string' then value = { value } end
    if type(value) ~= 'table' then return nil end
    local out, seen = {}, {}
    for _, class in ipairs(value) do
        if not Config.VehicleClasses[class] then return nil end
        if not seen[class] then out[#out + 1] = class; seen[class] = true end
    end
    return out
end
--- Class of a vehicle in the world. By model here; the Hydro adapter replaces
--- this with the car's real PI class, upgrades included.
function VehicleClasses.OfVehicle(vehicle)
    if not vehicle or vehicle == 0 then return Config.UnclassifiedVehicleClass end
    return VehicleClasses.Get(GetEntityModel(vehicle))
end
function VehicleClasses.Allows(selection, model, class)
    if not selection or #selection == 0 then return true end
    class = class or VehicleClasses.Get(model)
    for _, allowed in ipairs(selection) do
        if allowed == class then return true end
    end
    return false
end
