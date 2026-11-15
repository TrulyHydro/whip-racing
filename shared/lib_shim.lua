-- ============================================
-- The few ox_lib calls whip-racing uses, on WHIP instead (ox_lib is not installed here).
--
--   lib.callback.register  -> whip_core SecureCallback (a loaded, living character, a rate limit,
--                             and the values below), declared in Whip.register
--   lib.callback.await     -> whip_core Callback
--   lib.notify             -> whip_core Notify
--   lib.requestModel       -> a plain model load
--
-- If ox_lib's init.lua is loaded before this file, its lib is kept and this file does nothing.
-- ============================================

if lib then return end
lib = { callback = {} }

if IsDuplicityVersion() then
    -- What each callback accepts, in argument order. Ids that are only ever numbers are typed;
    -- the table payloads (a lobby form, a track) are 'any' and checked by the handlers themselves,
    -- as they were before. Unlisted callbacks accept up to six unchecked values.
    local ANY = function(n) return { n, 'any' } end
    local SCHEMAS = {
        ['whip-racing:getRewardItems'] = { params = { { 'query', 'string', 60, '' } } },
        ['whip-racing:searchRacers']   = { params = { { 'query', 'string', 60, '' } } },
        ['whip-racing:startLobby']     = { params = { { 'lobbyId', 'id' } }, rateLimit = 1000, burst = 2 },
        ['whip-racing:createLobby']    = { params = { ANY('data') }, rateLimit = 1000, burst = 2 },
        ['whip-racing:joinLobby']      = { params = { ANY('data') }, rateLimit = 1000, burst = 2 },
        ['whip-racing:createCrew']     = { params = { ANY('data') }, rateLimit = 2000 },
        ['whip-racing:redeemDaily']    = { params = {}, rateLimit = 2000 },
        ['whip-racing:saveTrack']      = { params = { ANY('payload') }, rateLimit = 1000, burst = 2 },
        ['whip-racing:saveSettings']   = { params = { ANY('settings') }, rateLimit = 500, burst = 3 },
    }
    local function schemaFor(name)
        local s = SCHEMAS[name]
        if s then return s end
        return { params = { ANY('a1'), ANY('a2'), ANY('a3'), ANY('a4'), ANY('a5'), ANY('a6') } }
    end

    local handlers = {}     -- [name] = fn(source, ...)
    local declared = false  -- Whip.register has run: declare new ones at once

    local function declare(name)
        Whip.core:SecureCallback(name, schemaFor(name), function(source, _, ...)
            return handlers[name](source, ...)
        end)
    end

    function lib.callback.register(name, fn)
        handlers[name] = fn
        if declared then CreateThread(function() declare(name) end) end
    end

    Whip.register(function()
        declared = true
        for name in pairs(handlers) do declare(name) end
    end)
else
    -- ox_lib's cache: every use here is `cache.ped or PlayerPedId()`, so an empty table is enough.
    cache = cache or {}

    --- Waits for the server's answer, as ox_lib's await does (also from an NUI callback handler).
    --- Returns what the handler returned, or false, why.
    function lib.callback.await(name, _delay, ...)
        local args = table.pack(...)
        local p = promise.new()
        CreateThread(function()
            p:resolve(table.pack(exports.whip_core:Callback(name, table.unpack(args, 1, args.n))))
        end)
        local r = Citizen.Await(p)
        return table.unpack(r, 1, r.n)
    end

    function lib.notify(data)
        data = type(data) == 'table' and data or { description = tostring(data) }
        local kind = ({ success = 'success', error = 'error', warning = 'warning' })[data.type] or 'info'
        Whip.core:Notify(data.description or data.title or '', kind)
    end

    function lib.requestModel(model, timeout)
        local hash = type(model) == 'number' and model or joaat(model)
        if not IsModelInCdimage(hash) then return nil end
        RequestModel(hash)
        local deadline = GetGameTimer() + (timeout or 10000)
        while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(0) end
        return HasModelLoaded(hash) and hash or nil
    end
end
