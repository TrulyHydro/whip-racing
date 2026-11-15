-- ============================================
-- WHIP Racing's page in /whip → Settings (permanent admins only)
--
-- Saved values are written into Config on both sides, so the code keeps reading Config.Case;
-- config/config.lua only gives the starting values. Changes are live: the next case opened
-- uses the new table.
-- ============================================

if not Whip or not Whip.configPage then return end   -- not on WHIP

local RARITIES = {
    { value = 'common',    label = 'Common (grey)' },
    { value = 'uncommon',  label = 'Uncommon (green)' },
    { value = 'rare',      label = 'Rare (blue)' },
    { value = 'epic',      label = 'Epic (purple)' },
    { value = 'legendary', label = 'Legendary (gold)' },
}

Whip.configPage({
    label = 'WHIP Racing',
    groups = {
        { label = 'Racing Case', settings = {
            { key = 'Case.enabled', type = 'bool', label = 'Cases can be opened',
              help = 'Off: using a Racing Case says so and keeps it.' },
            { key = 'Case.spinSeconds', type = 'int', min = 3, max = 12, unit = 's', label = 'Spin time',
              help = 'How long the reel spins before it stops on the prize.' },
            { key = 'Case.contents', type = 'records', label = 'What a case can give',
              help = 'Each row is one possible prize. Weight is its share of the chance: '
                  .. 'weight 10 out of 100 in all comes up 10% of the time. Amount is picked between min and max.',
              minItems = 1, maxItems = 40,
              fields = {
                  { key = 'item', type = 'string', maxLen = 60, label = 'Item key',
                    pattern = '^[%w_%-]+$', patternWhy = 'An item key: letters, digits, _ and - (see Economy → Items)' },
                  { key = 'min', type = 'int', min = 1, max = 1000000, label = 'Min' },
                  { key = 'max', type = 'int', min = 1, max = 1000000, label = 'Max' },
                  { key = 'weight', type = 'int', min = 1, max = 10000, label = 'Weight' },
                  { key = 'rarity', type = 'enum', options = RARITIES, label = 'Rarity' },
                  { key = 'label', type = 'string', maxLen = 40, nullable = true, emptyLabel = 'item name',
                    label = 'Shown as' },
                  { key = 'image', type = 'string', maxLen = 200, nullable = true, emptyLabel = 'automatic',
                    label = 'Picture',
                    help = "Only if the reel shows no picture: '@resource/path.png', or a https://cfx-nui-... address" },
              } },
        } },
    },
})
