require("monitors")
require("programs")
require("actions")
require("envs")
require("looknfeel")
require("layouts")
require("input")
require("binds")
require("rules")
require("session")

local state = (os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")) .. "/yudae"

local function builtForThisHyprland()
  local ready = io.open(state .. "/plugins.ready", "r")
  if not ready then return false end

  local built = ready:read("*l")
  ready:close()
  return built == hl.version()
end

local loaded = io.open(state .. "/loaded.lua", "r")

if loaded then
    loaded:close()
    if builtForThisHyprland() then dofile(state .. "/loaded.lua") end
end
