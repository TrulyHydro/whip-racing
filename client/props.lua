Props = { spawned = {} }

--- `model` is either a name written by this editor or a raw hash carried over
--- from an imported track, so both have to resolve.
function Props.LoadModel(model)
    local hash = type(model) == 'number' and math.floor(model) or joaat(model)
    if not IsModelValid(hash) then return nil end

    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(0) end

    if not HasModelLoaded(hash) then return nil end
    return hash
end

function Props.Clear()
    for _, handle in ipairs(Props.spawned) do
        if DoesEntityExist(handle) then DeleteEntity(handle) end
    end
    Props.spawned = {}
end

--- Spawns a track's scenery locally. Props are client side only: every racer
--- builds the same set from the same stored list, so nothing has to be
--- networked and nothing outlives the race.
function Props.Spawn(list)
    Props.Clear()
    if not Config.Props.enabled or not list then return end

    for _, prop in ipairs(list) do
        local hash = Props.LoadModel(prop.model)

        if hash then
            local object = CreateObject(hash, prop.x + 0.0, prop.y + 0.0, prop.z + 0.0, false, false, false)
            SetEntityHeading(object, prop.heading or 0.0)
            FreezeEntityPosition(object, true)
            SetEntityInvincible(object, true)
            SetModelAsNoLongerNeeded(hash)
            Props.spawned[#Props.spawned + 1] = object
        end
    end
end

--- Translucent, collision-free stand-in the editor drags around in front of
--- the car so you can see what you are about to place.
function Props.CreatePreview(model)
    local hash = Props.LoadModel(model)
    if not hash then return nil end

    local object = CreateObject(hash, 0.0, 0.0, 0.0, false, false, false)
    SetEntityAlpha(object, 160, false)
    SetEntityCollision(object, false, false)
    FreezeEntityPosition(object, true)
    SetEntityInvincible(object, true)
    SetModelAsNoLongerNeeded(hash)

    return object
end

--- Drops catalogue entries whose model does not exist on this client, so a bad
--- name in the config surfaces as a warning rather than a prop that silently
--- refuses to place.
local function validateCatalogue()
    local kept = {}

    for _, entry in ipairs(Config.Props.catalogue) do
        if IsModelValid(joaat(entry.model)) then
            kept[#kept + 1] = entry
        else
            print(('[whip-racing] prop model "%s" (%s) does not exist, removing it from the picker')
                :format(entry.model, entry.label))
        end
    end

    Config.Props.catalogue = kept
end

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    validateCatalogue()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    Props.Clear()
end)
