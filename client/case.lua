-- ============================================
-- Racing Case: the opening show
--
-- The server already gave the prize (server/cases.lua); this only plays the reel it sent,
-- which ends on that prize. No NUI focus: the player can still move, and nothing they click
-- changes anything.
-- ============================================

local playing = false

RegisterNetEvent('whip-racing:caseOpen', function(data)
    if type(data) ~= 'table' or type(data.reel) ~= 'table' then return end
    if playing then return end
    playing = true

    -- Over the inventory the case was used from: close it so the reel is seen.
    Whip.core:CloseInventory()

    PlaySoundFrontend(-1, 'Highlight_Move', 'DLC_HEIST_PLANNING_BOARD_SOUNDS', true)
    UI.Send('case', data)

    local seconds = tonumber(data.seconds) or 6
    SetTimeout(math.floor(seconds * 1000), function()
        local prize = data.reel[data.win] or {}
        local big = prize.rarity == 'epic' or prize.rarity == 'legendary'
        PlaySoundFrontend(-1, big and 'RACE_PLACED' or 'PICK_UP', big and 'HUD_AWARDS' or 'HUD_FRONTEND_DEFAULT_SOUNDSET', true)
        local what = (prize.amountText and (prize.amountText .. ' ')) or ''
        Whip.core:Notify(('Racing Case: %s%s'):format(what, prize.label or 'a prize'), 'success', 6000)
    end)
    -- The page fades the reel out on its own; this only lets the next case play.
    SetTimeout(math.floor(seconds * 1000) + 3500, function() playing = false end)
end)
