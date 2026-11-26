local repo = require("repo")
local path = repo .. "/shell/cache/display.lua"

local ok, saved = pcall(dofile, path)
if not ok or type(saved) ~= "table" then saved = {} end

if type(saved.outputs) == "table" then
    for output, entry in pairs(saved.outputs) do
        hl.monitor({
            output   = output,
            mode     = entry.mode or "preferred",
            position = "auto",
            scale    = tostring(entry.scale or 1),
        })
    end
end
