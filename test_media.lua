-- Extract the media block from Valeera.lua and exercise it both with and
-- without LibSharedMedia present.
local lines, block = {}, nil
do
  local grab, out = false, {}
  for line in io.lines("Valeera.lua") do
    if line:match("^local FALLBACK_FONT") then grab = true end
    if line:match("^local function ApplyLayout") then break end
    if grab then out[#out+1] = line end
  end
  block = table.concat(out, "\n")
end
assert(block and block:find("ApplyMedia"), "failed to slice media block")

local function build(LSM, db)
  local env = {
    LSM = LSM, db = db, defaults = { bgColor = {0,0,0,0.75}, borderColor = {0.6,0.6,0.6,1} }, STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF",
    math = math, table = table, pairs = pairs, ipairs = ipairs,
    frame = { SetBackdrop = function(_, b) _G_BACKDROP = b end,
              SetBackdropColor = function(_, r, g, b2, a) _G_BGCOLOR = {r,g,b2,a} end,
              SetBackdropBorderColor = function(_, r, g, b2, a) _G_BDCOLOR = {r,g,b2,a} end },
  }
  env._G = env
  local chunk = load("local LSM, db, frame = LSM, db, frame\n" .. block ..
    "\nreturn {Media=Media, FontPath=FontPath, ApplyMedia=ApplyMedia, MediaList=MediaList}",
    "media", "t", env)
  return chunk()
end

-- Fake LSM with one addon-contributed font, mimicking ElvUI registering media.
local fakeLSM = {
  DefaultMedia = { font = "Friz Quadrata TT", background = "None", border = "None" },
  media = {
    font = { ["Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF", ["PT Sans Narrow"] = "Interface\\Addons\\ElvUI\\pt.ttf" },
    background = { ["None"] = "", ["Solid"] = "Interface\\Buttons\\WHITE8X8", ["Blizzard Tooltip"] = "Interface\\Tooltips\\UI-Tooltip-Background" },
    border = { ["None"] = "", ["Blizzard Tooltip"] = "Interface\\Tooltips\\UI-Tooltip-Border", ["ElvUI GlowBorder"] = "Interface\\Addons\\ElvUI\\glow" },
  },
}
function fakeLSM:Fetch(mt, key, noDefault)
  local v = key and self.media[mt][key]
  if v then return v end
  if noDefault then return nil end
  return self.media[mt][self.DefaultMedia[mt]]
end
function fakeLSM:List(mt)
  local k = {} for n in pairs(self.media[mt]) do k[#k+1]=n end table.sort(k) return k
end

-- 1. LSM present, user picked an addon-supplied font -> that exact path.
local m = build(fakeLSM, { font = "PT Sans Narrow", background = "Solid", border = "ElvUI GlowBorder", edgeSize = 2 })
assert(m.FontPath() == "Interface\\Addons\\ElvUI\\pt.ttf", "addon font not used: "..tostring(m.FontPath()))
m.ApplyMedia()
assert(_G_BACKDROP.bgFile == "Interface\\Buttons\\WHITE8X8", "bg wrong")
assert(_G_BACKDROP.edgeFile == "Interface\\Addons\\ElvUI\\glow", "border wrong")
assert(_G_BACKDROP.edgeSize == 2 and _G_BACKDROP.insets.left == 2, "thin border insets wrong")

-- 2. Saved font whose addon is gone -> falls back, does not error or blank out.
m = build(fakeLSM, { font = "Uninstalled Font", background = "Solid", border = "Blizzard Tooltip" })
assert(m.FontPath() == "Fonts\\FRIZQT__.TTF", "stale font key did not fall back")

-- 3. Border "None" -> no edgeFile, but insets still leave room for text.
m = build(fakeLSM, { border = "None", background = "Solid", edgeSize = 12 })
m.ApplyMedia()
assert(_G_BACKDROP.edgeFile == nil, "None border should omit edgeFile")
assert(_G_BACKDROP.insets.left == 3, "None border lost text padding")

-- 4. No LSM at all -> Blizzard-only fallback still works end to end.
m = build(nil, { font = "Morpheus", background = "Blizzard Parchment", border = "Blizzard Dialog", edgeSize = 16 })
assert(m.FontPath() == "Fonts\\MORPHEUS.TTF", "fallback font table broken")
m.ApplyMedia()
assert(_G_BACKDROP.bgFile:find("Parchment"), "fallback bg broken")
assert(_G_BACKDROP.edgeFile:find("UI%-DialogBox%-Border"), "fallback border broken")
assert(#m.MediaList("font") == 4, "fallback list wrong")

-- 5. No LSM, and a saved key that only exists in someone else's LSM.
m = build(nil, { font = "PT Sans Narrow", background = "Solid", border = "None" })
assert(m.FontPath() == "Fonts\\FRIZQT__.TTF", "no-LSM stale key did not fall back")

-- 6. Fresh install (nil font) -> LSM default, never nil.
m = build(fakeLSM, { background = "Solid", border = "None" })
assert(m.FontPath() == "Fonts\\FRIZQT__.TTF", "nil font did not resolve to default")
-- 7. font = "" (fresh install default) resolves to the default, not a blank path.
m = build(fakeLSM, { font = "", background = "Solid", border = "None" })
assert(m.FontPath() == "Fonts\\FRIZQT__.TTF", 'empty font key did not resolve to default')
m = build(nil, { font = "", background = "Solid", border = "None" })
assert(m.FontPath() == "Fonts\\FRIZQT__.TTF", 'empty font key broke without LSM')

-- 8. Saved colors drive the backdrop, including a fully transparent background.
m = build(fakeLSM, { background = "Solid", border = "Blizzard Tooltip",
                     bgColor = {0.1, 0.2, 0.3, 0}, borderColor = {1, 0, 0, 0.5} })
m.ApplyMedia()
assert(_G_BGCOLOR[4] == 0, "alpha 0 background not applied")
assert(_G_BGCOLOR[1] == 0.1 and _G_BGCOLOR[3] == 0.3, "bg color not applied")
assert(_G_BDCOLOR[1] == 1 and _G_BDCOLOR[4] == 0.5, "border color not applied")

-- 9. Upgrading from 0.3.0 (no color keys saved) falls back to defaults, not nil.
m = build(fakeLSM, { background = "Solid", border = "Blizzard Tooltip" })
m.ApplyMedia()
assert(_G_BGCOLOR[4] == 0.75, "missing bgColor did not fall back to default")
assert(_G_BDCOLOR[1] == 0.6, "missing borderColor did not fall back to default")

print("all media checks passed")
