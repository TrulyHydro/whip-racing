-- Runs on GTA V Legacy and Enhanced from the same source. 'gta5' is the target
-- for both -- Enhanced has no separate value -- and Lua 5.4 is required either way.
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'WHIP Racing'
author 'TrulyHydro'
description 'Inspired Racing Script, with a bunch of stuff. Pink Slips, Wagering, Ranked/Unranked'
version '1.0.2'


-- WHIP: whip_core instead of ox_lib. shared/lib_shim.lua stands in for the ox_lib calls used here
-- (callbacks become whip_core SecureCallbacks). To run on another framework with ox_lib, put
-- '@ox_lib/init.lua' back first in this list; the shim then steps aside.
dependency 'whip_core'
whip_requires '1.0'

shared_scripts {
    '@whip_core/lib/satellite.lua',
    'shared/lib_shim.lua',
    'config/config.lua',
    'shared/settings.lua',      -- the /whip → Settings page (the Racing Case table)
    'config/vehicle_classes.lua',
    'shared/vehicle_classes.lua',
    'shared/bridge.lua',
    'shared/hydro.lua', -- Hydro framework adapter; does nothing on other frameworks
}

client_scripts {
    'client/nui.lua',
    'client/props.lua',
    'client/duibeam.lua',
    'client/checkpoints.lua',
    'client/gates.lua',
    'client/ghost.lua',
    'client/creator.lua',
    'client/tablet.lua',
    'client/case.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/whip.lua',
    'server/cases.lua',
    'server/profiles.lua',
    'server/crews.lua',
    'server/tracks.lua',
    'server/records.lua',
    'server/betting.lua',
    'server/main.lua',
}

ui_page 'web/index.html'

-- stream/ holds a renamed copy of generic_texture_renderer.gfx per beam slot.
-- Legacy loads those; Enhanced does not load streamed .gfx at all and uses the
-- stock movie instead, which client/duibeam.lua falls back to on its own.

files {
    'web/index.html',
    'web/style.css',
    'web/app.js',
    'web/tablet.js',
    'web/tablet.css',
    'web/whip-theme.css',
    'web/case.css',
    'web/case.js',
    'web/dui/index.html',
    'web/dui/style.css',
    'web/dui/main.js',
    'web/fonts/*.woff2',
    'web/tablet/img/**/*',
    'web/tablet/mapTiles/**/*',
    'locales/*.json',
    'racing_case.png',   -- the racing_case item's picture in WHIP's inventory
}

dependencies {
    'oxmysql',
}

-- Only consulted when the resource is escrowed for Legacy. Asset Escrow is not
-- implemented on Enhanced, where this block is inert. README.md, not .txt.
escrow_ignore {
    'config/config.lua',
    'config/vehicle_classes.lua',
    'README.md',
}
