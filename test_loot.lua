-- Exercises the curiosity loot filter against real CHAT_MSG_LOOT message shapes.
local block do
  local grab, out = false, {}
  for line in io.lines("Valeera.lua") do
    if line:match("^local CURIO_PATTERNS") then grab = true end
    if grab then out[#out+1] = line end
    if grab and line == "end" and #out > 5 and out[#out-1]:match("state%.loot%[3%]") then break end
  end
  block = table.concat(out, "\n")
end
assert(block:find("IsCuriosityLoot"), "failed to slice loot block")

local state = { runActive = true, loot = {0,0,0} }
local QUALITY = {}   -- link -> quality, keyed by item id
local env = {
  state = state, ipairs = ipairs, tonumber = tonumber, pairs = pairs,
  UnitGUID = function() return "player-1" end,
  C_Item = { GetItemQualityByID = function(link)
    local id = link:match("|Hitem:(%d+)")
    return QUALITY[tonumber(id)]
  end },
  GetItemInfo = function() return nil end,
}
env._G = env
local chunk = load(block .. "\nreturn {OnLoot = OnLoot, IsCuriosityLoot = IsCuriosityLoot}", "loot", "t", env)
local M = chunk()

-- Build a loot message the way the game formats one.
local function link(id, name) return ("|cffffffff|Hitem:%d::::::::::|h[%s]|h|r"):format(id, name) end
local function msg(id, name, n)
  local l = link(id, name)
  return n and ("You receive loot: %s|hx%d|."):format(l, n) or ("You receive loot: %s."):format(l)
end

local function reset() state.loot = {0,0,0} end

-- The reported bug: herbs and ore must not count.
QUALITY[210796] = 2   -- an uncommon herb
QUALITY[210930] = 3   -- a rare ore
reset()
M.OnLoot(msg(210796, "Mycobloom"), "player-1")
M.OnLoot(msg(210930, "Bismuth"), "player-1")
assert(state.loot[1] == 0 and state.loot[2] == 0,
  "herbs/ore were counted: " .. table.concat(state.loot, "/"))

-- Curiosities still count, at the right quality bucket.
QUALITY[228071] = 2
QUALITY[228073] = 3
QUALITY[228075] = 4
reset()
M.OnLoot(msg(228071, "Chunk of Companion Experience"), "player-1")
M.OnLoot(msg(228073, "Chunk of Companion Experience"), "player-1")
M.OnLoot(msg(228075, "Chunk of Companion Experience"), "player-1")
assert(state.loot[1] == 1 and state.loot[2] == 1 and state.loot[3] == 1,
  "curiosity chunks miscounted: " .. table.concat(state.loot, "/"))

-- The un-consumed form (no Dundun's Favor) also counts.
QUALITY[999001] = 2
reset()
M.OnLoot(msg(999001, "Mislaid Curiosity"), "player-1")
assert(state.loot[1] == 1, "raw curiosity not counted")

-- Stacks respect the count suffix.
reset()
M.OnLoot(msg(228071, "Chunk of Companion Experience", 3), "player-1")
assert(state.loot[1] == 3, "stack count ignored: " .. state.loot[1])

-- Someone else's loot is still ignored.
reset()
M.OnLoot(msg(228071, "Chunk of Companion Experience"), "player-OTHER")
assert(state.loot[1] == 0, "counted another player's loot")

-- An epic mob drop is still junk, however tempting its quality.
QUALITY[999002] = 4
reset()
M.OnLoot(msg(999002, "Bloodthorn Greataxe"), "player-1")
assert(state.loot[3] == 0, "epic junk drop was counted")

print("all loot filter checks passed")
