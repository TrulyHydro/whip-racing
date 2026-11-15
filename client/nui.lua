UI = {
    open = false,        -- a focus-taking menu is up
    overlay = false,     -- a focus-less overlay (editor) is up
    focused = false,     -- NUI currently owns mouse/keyboard
    hudVisible = false,
}

--- Sends a payload to the NUI page. Every message carries an `action` key.
function UI.Send(action, data)
    SendNUIMessage({ action = action, data = data })
end

--- Grabs or releases NUI input without changing which screen is shown.
function UI.SetFocus(state)
    state = state and true or false
    if UI.focused == state then return end
    UI.focused = state
    SetNuiFocus(state, state)
    UI.Send('focus', { focused = state })
end

--- Opens the interactive menu layer and takes NUI focus.
function UI.Open(screen, data)
    UI.open = true
    UI.Send('open', { screen = screen, payload = data })
    UI.SetFocus(true)
end

--- Opens a screen that draws on top of gameplay but leaves the player in control.
--- Focus is handed over on demand via UI.SetFocus, so driving keeps working.
function UI.Overlay(screen, data)
    UI.overlay = true
    UI.Send('open', { screen = screen, payload = data, overlay = true })
    UI.SetFocus(false)
end

function UI.Close()
    if not UI.open and not UI.overlay then return end
    UI.open = false
    UI.overlay = false
    UI.Send('close')
    UI.SetFocus(false)
end

--- Shows or hides the in-race HUD layer. The HUD never takes focus.
function UI.SetHud(visible, data)
    UI.hudVisible = visible
    UI.Send('hud', {
        visible = visible,
        payload = data,
    })
end

RegisterNUICallback('close', function(_, cb)
    UI.Close()
    cb('ok')
end)

-- Release focus if the resource restarts mid-menu.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    SetNuiFocus(false, false)
end)
