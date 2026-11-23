local options = YUDAE_PLUGIN.options or {}
local enabled = options.enabled ~= false

local shadow = { enabled = enabled }
if options.range ~= nil then shadow.range = options.range end
if options.offset ~= nil then shadow.offset = options.offset end
if options.alpha ~= nil then shadow.alpha = options.alpha end
if options.contact ~= nil then shadow.contact = options.contact end

hl.config({
    decoration = {
        shadow = {
            enabled = not enabled,
        },
    },
    plugin = {
        shadow = shadow,
    },
})
