--------------------------------------------------------------------------------
-- Valeera - companion XP / delve run tracker
--   * Window only shown while inside a delve (and "Show window" option is on)
--   * Options live under Game Menu > Options > AddOns > Valeera
--   * /valeera  toggles the option, /valeera reset clears the current run
--------------------------------------------------------------------------------

local ADDON_NAME = ...
local DELVE_DIFFICULTY_ID = 208

local defaults = {
    showWindow  = true,
    lockWindow  = false,
    showPortrait = true,
    fontSize    = 14,
    font        = "",         -- LSM font key; "" = use LSM/Blizzard default
    background  = "Blizzard Tooltip",  -- LSM background key
    border      = "Blizzard Tooltip",  -- LSM border key
    edgeSize    = 12,
    bgColor     = { 0, 0, 0, 0.75 },        -- backdrop tint {r,g,b,a}
    borderColor = { 0.6, 0.6, 0.6, 1 },
    show        = {},         -- per-element visibility, missing = shown
    factionID   = nil,        -- resolved at runtime; user may pin via /valeera faction <id>
    pos         = { point = "CENTER", x = 0, y = 0 },
    history     = {},         -- completed runs
}

local db
local state = {
    inDelve      = false,
    runActive    = false,
    startTime    = nil,
    startXP      = nil,
    startLevel   = nil,
    delveName    = nil,
    tier         = nil,
    pendingTier  = nil,
    lastRun      = nil,
    tierTicker   = nil,
}

local function Print(msg)
    print("|cff9ecbffValeera:|r " .. tostring(msg))
end

--------------------------------------------------------------------------------
-- Companion faction resolution
--------------------------------------------------------------------------------

local function FactionLooksLikeValeera(data)
    return data and data.name and data.name:lower():find("valeera", 1, true) ~= nil
end

local function ResolveFactionID()
    if db.factionID then
        return db.factionID
    end

    -- 1. Delves API, if it exposes the active companion
    if C_DelvesUI then
        local companionID = C_DelvesUI.GetCurrentDelvesCompanionID and C_DelvesUI.GetCurrentDelvesCompanionID()
        if companionID and C_DelvesUI.GetFactionForCompanion then
            local ok, fid = pcall(C_DelvesUI.GetFactionForCompanion, companionID)
            if ok and fid and fid > 0 then
                local data = C_Reputation.GetFactionDataByID(fid)
                if FactionLooksLikeValeera(data) then
                    db.factionID = fid
                    return fid
                end
            end
        end
    end

    -- 2. Visible reputation list
    if C_Reputation and C_Reputation.GetNumFactions then
        for i = 1, C_Reputation.GetNumFactions() do
            local data = C_Reputation.GetFactionDataByIndex(i)
            if FactionLooksLikeValeera(data) then
                db.factionID = data.factionID
                return data.factionID
            end
        end
    end

    -- 3. Brute-force scan of plausible ID range (once)
    if C_Reputation and C_Reputation.GetFactionDataByID then
        for fid = 2600, 3400 do
            local data = C_Reputation.GetFactionDataByID(fid)
            if FactionLooksLikeValeera(data) then
                db.factionID = fid
                return fid
            end
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- XP snapshot
--------------------------------------------------------------------------------

-- Returns level, xpIntoLevel, xpForLevel, totalStanding
local function GetCompanionXP()
    local fid = ResolveFactionID()
    if not fid then
        return nil
    end

    local rep = C_GossipInfo and C_GossipInfo.GetFriendshipReputation and C_GossipInfo.GetFriendshipReputation(fid)
    if not rep or not rep.friendshipFactionID or rep.friendshipFactionID == 0 then
        return nil
    end

    local level
    local ranks = C_GossipInfo.GetFriendshipReputationRanks and C_GossipInfo.GetFriendshipReputationRanks(fid)
    if ranks then
        level = ranks.currentLevel
    end

    local standing  = rep.standing or 0
    local floor     = rep.reactionThreshold or 0
    local ceiling   = rep.nextThreshold or standing
    local into      = standing - floor
    local needed    = ceiling - floor

    return level, into, needed, standing
end

--------------------------------------------------------------------------------
-- Delve tier capture (from difficulty picker, based on the r/wowaddons snippet)
--------------------------------------------------------------------------------

local function ParseTierNumber(text)
    if not text then return nil end
    text = tostring(text)
    local n = text:match("[Tt]ier%s*(%d+)") or text:match("^(%d+)$")
    return n and tonumber(n) or nil
end

local function TryCaptureTier()
    local frame = DelvesDifficultyPickerFrame
    if not frame or not frame:IsShown() then return nil end
    local dropdown = frame.Dropdown
    local textObj = dropdown and dropdown.Text
    local text = textObj and textObj.GetText and textObj:GetText()
    return ParseTierNumber(text)
end

local function StopTierWatch()
    if state.tierTicker then
        state.tierTicker:Cancel()
        state.tierTicker = nil
    end
end

local function StartTierWatch()
    StopTierWatch()
    state.tierTicker = C_Timer.NewTicker(0.1, function()
        local frame = DelvesDifficultyPickerFrame
        if not frame or not frame:IsShown() then
            StopTierWatch()
            return
        end
        local ok, tier = pcall(TryCaptureTier)
        if ok and tier then
            state.pendingTier = tier
        end
    end)
end

--------------------------------------------------------------------------------
-- Delve detection
--------------------------------------------------------------------------------

local function IsInDelve()
    if C_PartyInfo and C_PartyInfo.IsDelveInProgress then
        local ok, res = pcall(C_PartyInfo.IsDelveInProgress)
        if ok and res then return true end
    end
    local _, instanceType, difficultyID = GetInstanceInfo()
    return instanceType == "scenario" and difficultyID == DELVE_DIFFICULTY_ID
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local frame = CreateFrame("Frame", "ValeeraFrame", UIParent, "BackdropTemplate")
frame:SetSize(230, 150)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetBackdrop({
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
frame:SetBackdropColor(0, 0, 0, 0.75)
frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
frame:Hide()

frame:SetScript("OnDragStart", function(self)
    if not db.lockWindow then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint()
    db.pos = { point = point, x = x, y = y }
end)

--------------------------------------------------------------------------------
-- Portrait ring (circular XP progress around companion portrait)
--------------------------------------------------------------------------------

local RING_SIZE   = 96
local PAD         = 18
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local PORTRAIT_ICON = "Interface\\Icons\\Achievement_Character_Bloodelf_Female"

local ring = CreateFrame("Frame", nil, frame)
ring:SetSize(RING_SIZE, RING_SIZE)
ring:SetPoint("TOP", frame, "TOP", 0, -PAD)
frame.ring = ring

-- gold outer rim
ring.rim = ring:CreateTexture(nil, "BACKGROUND", nil, -2)
ring.rim:SetPoint("TOPLEFT", -3, 3)
ring.rim:SetPoint("BOTTOMRIGHT", 3, -3)
ring.rim:SetTexture(CIRCLE_MASK)
ring.rim:SetVertexColor(0.55, 0.42, 0.15, 1)

-- dark base circle
ring.base = ring:CreateTexture(nil, "BACKGROUND", nil, -1)
ring.base:SetAllPoints()
ring.base:SetTexture(CIRCLE_MASK)
ring.base:SetVertexColor(0.08, 0.08, 0.08, 1)

-- segmented progress ring: overlapping dots around the circumference, clockwise from 6 o'clock
local SEGMENTS   = 72
local DOT_SIZE   = 9
local RING_WIDTH = 9
local RING_R     = (RING_SIZE - RING_WIDTH) / 2
local GREEN      = { 0.10, 0.75, 0.15 }
local DARK       = { 0.08, 0.08, 0.08 }
ring.dots = {}
for i = 1, SEGMENTS do
    local a = (i - 1) / SEGMENTS * 2 * math.pi
    local dot = ring:CreateTexture(nil, "BORDER")
    dot:SetSize(DOT_SIZE, DOT_SIZE)
    dot:SetTexture(CIRCLE_MASK)
    -- start at 6 o'clock, sweep clockwise (bottom -> left -> top -> right -> bottom)
    dot:SetPoint("CENTER", ring, "CENTER", -RING_R * math.sin(a), -RING_R * math.cos(a))
    dot:SetVertexColor(DARK[1], DARK[2], DARK[3], 1)
    ring.dots[i] = dot
end

-- portrait (inner circle, masked)
local inner = CreateFrame("Frame", nil, ring)
inner:SetPoint("TOPLEFT", 9, -9)
inner:SetPoint("BOTTOMRIGHT", -9, 9)
inner:SetFrameLevel(ring:GetFrameLevel() + 1)
ring.inner = inner

inner.bg = inner:CreateTexture(nil, "BACKGROUND")
inner.bg:SetAllPoints()
inner.bg:SetTexture(CIRCLE_MASK)
inner.bg:SetVertexColor(0.05, 0.05, 0.05, 1)

inner.portrait = inner:CreateTexture(nil, "ARTWORK")
inner.portrait:SetPoint("TOPLEFT", 2, -2)
inner.portrait:SetPoint("BOTTOMRIGHT", -2, 2)
inner.portrait:SetTexture(PORTRAIT_ICON)
inner.portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
inner.mask = inner:CreateMaskTexture()
inner.mask:SetAllPoints(inner.portrait)
inner.mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
inner.portrait:AddMaskTexture(inner.mask)

-- level badge
local badge = CreateFrame("Frame", nil, ring)
badge:SetSize(34, 34)
badge:SetPoint("BOTTOM", ring, "BOTTOM", 0, -10)
badge:SetFrameLevel(inner:GetFrameLevel() + 1)
ring.badge = badge
badge.rim = badge:CreateTexture(nil, "BACKGROUND")
badge.rim:SetAllPoints()
badge.rim:SetTexture(CIRCLE_MASK)
badge.rim:SetVertexColor(0.55, 0.42, 0.15, 1)
badge.bg = badge:CreateTexture(nil, "BORDER")
badge.bg:SetPoint("TOPLEFT", 2, -2)
badge.bg:SetPoint("BOTTOMRIGHT", -2, 2)
badge.bg:SetTexture(CIRCLE_MASK)
badge.bg:SetVertexColor(0.05, 0.05, 0.05, 1)
badge.text = badge:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
badge.text:SetPoint("CENTER", 0, 0)
badge.text:SetText("?")

-- name under ring
frame.name = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
frame.name:SetPoint("TOP", ring, "BOTTOM", 0, -12)
frame.name:SetText("Valeera Sanguinar")

frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.subtitle:SetPoint("TOP", frame.name, "BOTTOM", 0, -2)
frame.subtitle:SetText("Trusty Delve Companion")

frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
frame.title:SetPoint("TOPLEFT", PAD, -PAD)
frame.title:SetText("Valeera")

frame.lines = {}
for i = 1, 10 do
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    frame.lines[i] = fs
end

-- Data elements, in display order. Each is toggleable via db.show[key].
local ELEMENTS = {
    { key = "delve",       label = "Delve name / tier" },
    { key = "time",        label = "Run time" },
    { key = "level",       label = "Level / progress %" },
    { key = "xpGained",    label = "XP gained" },
    { key = "xpPerMin",    label = "XP per minute" },
    { key = "toNext",      label = "XP to next level" },
    { key = "avgRun",      label = "Average run" },
    { key = "runsToLevel", label = "Runs to level" },
    { key = "timeToLevel", label = "Time to level" },
    { key = "loot",        label = "Loot counts (green/blue/purple)" },
}

local function ElementShown(key)
    local v = db.show and db.show[key]
    if v == nil then return true end
    return v
end

local function SetRingProgress(pct)
    pct = math.max(0, math.min(1, pct or 0))
    local lit = math.floor(pct * SEGMENTS + 0.5)
    for i, dot in ipairs(ring.dots) do
        local c = (i <= lit) and GREEN or DARK
        dot:SetVertexColor(c[1], c[2], c[3], 1)
    end
end

-- Media. LibSharedMedia is optional: when present (ElvUI, WeakAuras, Details et al
-- all embed it) we get every font/texture the user's other addons registered, which
-- is the whole point -- those paths live inside other addons and can't be discovered
-- otherwise. Without it we fall back to a small Blizzard-only list.
-- ponytail: soft dependency, no embedded libs. Vendor LSM only if we ever need it
-- to load before another addon registers media.
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

local FALLBACK_FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local FALLBACK_MEDIA = {
    font = {
        ["Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF",
        ["Arial Narrow"]     = "Fonts\\ARIALN.TTF",
        ["Skurri"]           = "Fonts\\SKURRI.TTF",
        ["Morpheus"]         = "Fonts\\MORPHEUS.TTF",
    },
    background = {
        ["None"]             = "",
        ["Solid"]            = "Interface\\Buttons\\WHITE8X8",
        ["Blizzard Tooltip"] = "Interface\\Tooltips\\UI-Tooltip-Background",
        ["Blizzard Dialog"]  = "Interface\\DialogFrame\\UI-DialogBox-Background",
        ["Blizzard Parchment"] = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal",
    },
    border = {
        ["None"]             = "",
        ["Blizzard Tooltip"] = "Interface\\Tooltips\\UI-Tooltip-Border",
        ["Blizzard Dialog"]  = "Interface\\DialogFrame\\UI-DialogBox-Border",
        ["Blizzard Party"]   = "Interface\\CHARACTERFRAME\\UI-Party-Border",
    },
}

-- Sorted key list for a media type, for the options dropdowns.
local function MediaList(mediatype)
    if LSM then return LSM:List(mediatype) end
    local keys = {}
    for k in pairs(FALLBACK_MEDIA[mediatype]) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

-- Resolve a saved key to a path. Falls back whenever the key is missing or the
-- media it names hasn't been registered (addon uninstalled, or not loaded yet).
local function Media(mediatype, key, default)
    if LSM then
        local path = key and LSM:Fetch(mediatype, key, true)
        return path or LSM:Fetch(mediatype, default) or default
    end
    local t = FALLBACK_MEDIA[mediatype]
    return (key and t[key]) or t[default] or default
end

local function FontPath()
    local key = db and db.font
    if key == "" then key = nil end
    if LSM then
        return (key and LSM:Fetch("font", key, true))
            or LSM:Fetch("font", LSM.DefaultMedia and LSM.DefaultMedia.font)
            or FALLBACK_FONT
    end
    return (key and FALLBACK_MEDIA.font[key]) or FALLBACK_FONT
end

-- Rebuild the backdrop from the saved media keys. SetBackdrop has to be called
-- wholesale -- individual fields can't be patched -- so this replaces it entirely
-- and reapplies the colors after.
local function ApplyMedia()
    local edge = Media("border", db and db.border, "Blizzard Tooltip")
    local edgeSize = (db and db.edgeSize) or 12
    -- A borderless backdrop still needs inset room or the text hugs the edge.
    local inset = edge ~= "" and math.max(2, math.floor(edgeSize / 4)) or 3

    frame:SetBackdrop({
        bgFile   = Media("background", db and db.background, "Blizzard Tooltip"),
        edgeFile = edge ~= "" and edge or nil,
        tile = true, tileSize = 16, edgeSize = edgeSize,
        insets = { left = inset, right = inset, top = inset, bottom = inset },
    })
    local bg = (db and db.bgColor) or defaults.bgColor
    local bd = (db and db.borderColor) or defaults.borderColor
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    frame:SetBackdropBorderColor(bd[1], bd[2], bd[3], bd[4])
end

local function ApplyLayout()
    local size = db and db.fontSize or 14
    local lineH = size + 4
    local showRing = db and db.showPortrait
    local font = FontPath()

    ApplyMedia()

    frame.title:SetFont(font, size, "")
    frame.name:SetFont(font, size + 4, "")
    frame.subtitle:SetFont(font, size - 1, "")
    badge.text:SetFont(font, size + 2, "OUTLINE")

    local top
    if showRing then
        ring:Show(); frame.name:Show(); frame.subtitle:Show(); frame.title:Hide()
        top = PAD + RING_SIZE + 12 + (size + 4) + 2 + (size - 1) + 10
    else
        ring:Hide(); frame.name:Hide(); frame.subtitle:Hide(); frame.title:Show()
        top = PAD + lineH
    end

    for i, fs in ipairs(frame.lines) do
        fs:SetFont(font, size, "")
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", PAD, -(top + (i - 1) * lineH))
    end

    local width = math.max(230, size * 20) + PAD * 2
    local n = 0
    for _, el in ipairs(ELEMENTS) do if ElementShown(el.key) then n = n + 1 end end
    frame:SetSize(width, top + n * lineH + PAD)
end

local function SetLines(...)
    local n = select("#", ...)
    for i = 1, #frame.lines do
        frame.lines[i]:SetText(i <= n and (select(i, ...) or "") or "")
    end
end

local function FormatDuration(secs)
    secs = math.max(0, math.floor(secs or 0))
    return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

-- Aggregate stats over saved history (last STATS_WINDOW runs with XP gain > 0)
local STATS_WINDOW = 10
local function GetRunStats()
    local runs, totalSecs, totalGain = 0, 0, 0
    for i = #db.history, 1, -1 do
        local r = db.history[i]
        if r.gain and r.gain > 0 and r.seconds and r.seconds > 0 then
            runs = runs + 1
            totalSecs = totalSecs + r.seconds
            totalGain = totalGain + r.gain
            if runs >= STATS_WINDOW then break end
        end
    end
    if runs == 0 then return nil end
    return {
        runs    = runs,
        avgSecs = totalSecs / runs,
        avgGain = totalGain / runs,
        perMin  = totalGain / (totalSecs / 60),
    }
end

local function LootLine()
    local cur = state.loot or { 0, 0, 0 }
    local tot = { 0, 0, 0 }
    for _, r in ipairs(db.history) do
        if r.loot then
            tot[1] = tot[1] + (r.loot[1] or 0); tot[2] = tot[2] + (r.loot[2] or 0); tot[3] = tot[3] + (r.loot[3] or 0)
        end
    end
    if state.runActive then
        tot[1] = tot[1] + cur[1]; tot[2] = tot[2] + cur[2]; tot[3] = tot[3] + cur[3]
    end
    return string.format("Loot: |cff1eff00%d|r/|cff0070dd%d|r/|cffa335ee%d|r  (all: |cff1eff00%d|r/|cff0070dd%d|r/|cffa335ee%d|r)",
        cur[1], cur[2], cur[3], tot[1], tot[2], tot[3])
end

local function EstimateLines(into, needed)
    local stats = GetRunStats()
    if not stats then
        return "Avg run: --", "Runs to level: --", "Time to level: --"
    end
    local remaining = (into and needed) and (needed - into) or nil
    local runsLeft = remaining and math.ceil(remaining / stats.avgGain) or nil
    local secsLeft = remaining and (remaining / stats.perMin * 60) or nil
    return
        string.format("Avg run: %s  (%s XP, n=%d)", FormatDuration(stats.avgSecs), BreakUpLargeNumbers(math.floor(stats.avgGain)), stats.runs),
        runsLeft and string.format("Runs to level: ~%d", runsLeft) or "Runs to level: --",
        secsLeft and string.format("Time to level: ~%s", FormatDuration(secsLeft)) or "Time to level: --"
end

local function RefreshDisplay()
    local level, into, needed, standing = GetCompanionXP()

    if db.showPortrait then
        badge.text:SetText(level and tostring(level) or "?")
        SetRingProgress((into and needed and needed > 0) and (into / needed) or 0)
    end

    local e1, e2, e3 = EstimateLines(into, needed)
    local text = {}

    if state.runActive then
        local elapsed = GetTime() - state.startTime
        local gain    = (standing or 0) - (state.startXP or 0)
        local mins    = elapsed / 60
        local perMin  = mins > 0 and gain / mins or 0
        local pct     = (needed and needed > 0) and (into / needed * 100) or 0
        text.delve    = string.format("%s%s", state.delveName or "Delve", state.tier and ("  T" .. state.tier) or "")
        text.time     = "Time: " .. FormatDuration(elapsed)
        text.level    = level and string.format("Level %d  (%.1f%%)", level, pct) or "Level: ?"
        text.xpGained = string.format("XP gained: %s", BreakUpLargeNumbers(gain))
        text.xpPerMin = string.format("XP/min: %s", BreakUpLargeNumbers(math.floor(perMin)))
        text.toNext   = needed and string.format("To next: %s", BreakUpLargeNumbers(needed - into)) or nil
    elseif state.lastRun then
        local r = state.lastRun
        text.delve    = "Last run: " .. (r.delve or "?") .. (r.tier and ("  T" .. r.tier) or "")
        text.time     = "Time: " .. FormatDuration(r.seconds)
        text.level    = r.endLevel and ("Level: " .. r.endLevel) or nil
        text.xpGained = string.format("XP gained: %s", BreakUpLargeNumbers(r.gain))
        text.xpPerMin = string.format("XP/min: %s", BreakUpLargeNumbers(math.floor(r.perMin)))
        text.toNext   = needed and string.format("To next: %s", BreakUpLargeNumbers(needed - into)) or nil
    else
        text.delve    = "Waiting for run..."
        text.level    = level and ("Level " .. level) or "Companion not found"
        text.toNext   = (into and needed) and string.format("%s / %s", BreakUpLargeNumbers(into), BreakUpLargeNumbers(needed)) or nil
    end
    text.avgRun, text.runsToLevel, text.timeToLevel = e1, e2, e3
    text.loot = LootLine()

    local out = {}
    for _, el in ipairs(ELEMENTS) do
        if ElementShown(el.key) and text[el.key] then
            out[#out + 1] = text[el.key]
        end
    end
    frame.visibleCount = #out
    SetLines(unpack(out))
end

local function UpdateVisibility()
    if db.showWindow and state.inDelve then
        ApplyLayout()
        frame:ClearAllPoints()
        frame:SetPoint(db.pos.point, UIParent, db.pos.point, db.pos.x, db.pos.y)
        frame:Show()
        RefreshDisplay()
    else
        frame:Hide()
    end
end

frame.elapsed = 0
frame:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed >= 1 then
        self.elapsed = 0
        RefreshDisplay()
    end
end)

--------------------------------------------------------------------------------
-- Run lifecycle
--------------------------------------------------------------------------------

local function StartRun()
    if state.runActive then return end
    local level, _, _, standing = GetCompanionXP()
    state.runActive  = true
    state.startTime  = GetTime()
    state.startXP    = standing or 0
    state.startLevel = level
    state.delveName  = GetInstanceInfo()
    state.tier       = state.pendingTier
    state.pendingTier = nil
    state.loot = { 0, 0, 0 }
end

local function EndRun()
    if not state.runActive then return end
    local level, into, needed, standing = GetCompanionXP()
    local seconds = GetTime() - state.startTime
    local gain    = (standing or 0) - (state.startXP or 0)
    local run = {
        delve      = state.delveName,
        tier       = state.tier,
        seconds    = seconds,
        gain       = gain,
        perMin     = seconds > 0 and gain / (seconds / 60) or 0,
        startLevel = state.startLevel,
        endLevel   = level,
        when       = time(),
        loot       = state.loot or { 0, 0, 0 },
    }
    state.lastRun = run
    table.insert(db.history, run)
    state.runActive = false
    Print(string.format("Run done: %s%s  %s  +%s XP  (%s/min)",
        run.delve or "?", run.tier and (" T" .. run.tier) or "",
        FormatDuration(seconds), BreakUpLargeNumbers(gain), BreakUpLargeNumbers(math.floor(run.perMin))))
    if level and into and needed then
        local remaining = needed - into
        local stats = GetRunStats()
        local runsLeft = (stats and stats.avgGain > 0) and math.ceil(remaining / stats.avgGain) or nil
        Print(string.format("Valeera level %d  %s XP to next  (~%s runs)",
            level, BreakUpLargeNumbers(remaining), runsLeft and tostring(runsLeft) or "?"))
    end
end

local function CheckDelveState()
    local now = IsInDelve()
    if now ~= state.inDelve then
        state.inDelve = now
        if now then StartRun() else EndRun() end
        UpdateVisibility()
    end
end

--------------------------------------------------------------------------------
-- Options panel (Settings API, AddOns tab)
--------------------------------------------------------------------------------

local function BuildOptions()
    if not Settings or not Settings.RegisterVerticalLayoutCategory then return end

    local category = Settings.RegisterVerticalLayoutCategory("Valeera")

    do
        local setting = Settings.RegisterAddOnSetting(category, "VALEERA_SHOW_WINDOW", "showWindow",
            db, Settings.VarType.Boolean, "Show window", defaults.showWindow)
        setting:SetValueChangedCallback(function() UpdateVisibility() end)
        Settings.CreateCheckbox(category, setting, "Show the tracker window while inside a delve.")
    end

    do
        local setting = Settings.RegisterAddOnSetting(category, "VALEERA_LOCK_WINDOW", "lockWindow",
            db, Settings.VarType.Boolean, "Lock window position", defaults.lockWindow)
        Settings.CreateCheckbox(category, setting, "Prevent the tracker window from being dragged.")
    end

    do
        local setting = Settings.RegisterAddOnSetting(category, "VALEERA_SHOW_PORTRAIT", "showPortrait",
            db, Settings.VarType.Boolean, "Show portrait", defaults.showPortrait)
        setting:SetValueChangedCallback(function() ApplyLayout(); RefreshDisplay() end)
        Settings.CreateCheckbox(category, setting, "Show the companion portrait with the XP progress ring.")
    end

    do
        local setting = Settings.RegisterAddOnSetting(category, "VALEERA_FONT_SIZE", "fontSize",
            db, Settings.VarType.Number, "Font size", defaults.fontSize)
        setting:SetValueChangedCallback(function() ApplyLayout(); RefreshDisplay() end)
        local options = Settings.CreateSliderOptions(10, 24, 1)
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v) return tostring(v) end)
        Settings.CreateSlider(category, setting, options, "Text size for the tracker window.")
    end

    -- Media dropdowns. Blizzard's dropdown renders plain text, so the entries are
    -- named but not previewed in the chosen font/texture.
    local function MediaDropdown(mediatype, key, label, tooltip)
        local setting = Settings.RegisterAddOnSetting(category,
            "VALEERA_" .. key:upper(), key, db, Settings.VarType.String,
            label, defaults[key] or "")
        setting:SetValueChangedCallback(function() ApplyLayout(); RefreshDisplay() end)
        -- Rebuilt on open so media registered after login shows up.
        local function GetOptions()
            local container = Settings.CreateControlTextContainer()
            for _, name in ipairs(MediaList(mediatype)) do
                container:Add(name, name)
            end
            return container:GetData()
        end
        Settings.CreateDropdown(category, setting, GetOptions, tooltip)
    end

    MediaDropdown("font", "font", "Font",
        "Font for the tracker window. Fonts from your other addons appear here.")
    MediaDropdown("background", "background", "Background",
        "Background texture for the tracker window.")
    MediaDropdown("border", "border", "Border",
        "Border texture for the tracker window.")

    -- Color swatches. The Settings API has no color control, so this appends a
    -- plain button to the category layout and drives Blizzard's ColorPickerFrame.
    -- ponytail: hand-rolled because there is no native option, not for style.
    local function ColorSwatch(key, label, tooltip)
        local initializer = Settings.CreateElementInitializer("SettingsListElementTemplate", {
            name = label,
            tooltip = tooltip,
        })
        initializer.InitFrame = function(_, f)
            SettingsListElementMixin.OnLoad(f)
            f:SetTooltipFunc(function(_, t) t:AddLine(label); t:AddLine(tooltip, 1, 1, 1, true) end)
            f.Text:SetText(label)

            if not f.valeeraSwatch then
                local b = CreateFrame("Button", nil, f, "BackdropTemplate")
                b:SetSize(28, 18)
                b:SetPoint("LEFT", f, "CENTER", 0, 0)
                b:SetBackdrop({
                    bgFile = "Interface\\Buttons\\WHITE8X8",
                    edgeFile = "Interface\\Buttons\\WHITE8X8",
                    edgeSize = 1,
                })
                b:SetBackdropBorderColor(0, 0, 0, 1)
                -- Checker plate behind the swatch so alpha is visible.
                local checker = b:CreateTexture(nil, "BACKGROUND")
                checker:SetAllPoints()
                checker:SetColorTexture(0.35, 0.35, 0.35, 1)
                f.valeeraSwatch = b
            end

            local swatch = f.valeeraSwatch
            local function Paint()
                local c = db[key] or defaults[key]
                swatch:SetBackdropColor(c[1], c[2], c[3], c[4])
            end
            Paint()

            swatch:SetScript("OnClick", function()
                local c = db[key] or defaults[key]
                local prev = { c[1], c[2], c[3], c[4] }
                local function Apply()
                    local r, g, b2 = ColorPickerFrame:GetColorRGB()
                    -- GetColorAlpha is the modern accessor; opacity is 1-alpha on older builds.
                    local a = ColorPickerFrame.GetColorAlpha and ColorPickerFrame:GetColorAlpha()
                        or (OpacitySliderFrame and (1 - OpacitySliderFrame:GetValue())) or 1
                    db[key] = { r, g, b2, a }
                    Paint(); ApplyMedia()
                end
                local info = {
                    swatchFunc = Apply,
                    opacityFunc = Apply,
                    hasOpacity = true,
                    opacity = prev[4],
                    r = prev[1], g = prev[2], b = prev[3],
                    cancelFunc = function()
                        db[key] = prev
                        Paint(); ApplyMedia()
                    end,
                }
                if ColorPickerFrame.SetupColorPickerAndShow then
                    info.swatchFunc = Apply
                    ColorPickerFrame:SetupColorPickerAndShow(info)
                else
                    ColorPickerFrame.func = Apply
                    ColorPickerFrame.opacityFunc = Apply
                    ColorPickerFrame.cancelFunc = info.cancelFunc
                    ColorPickerFrame.hasOpacity = true
                    ColorPickerFrame.opacity = prev[4]
                    ColorPickerFrame:SetColorRGB(prev[1], prev[2], prev[3])
                    ColorPickerFrame:Show()
                end
            end)
        end
        pcall(function() SettingsPanel:GetLayout(category):AddInitializer(initializer) end)
    end

    ColorSwatch("bgColor", "Background color",
        "Background tint and opacity. Drop the opacity to 0 for a fully transparent window.")
    ColorSwatch("borderColor", "Border color", "Border tint and opacity.")

    do
        local setting = Settings.RegisterAddOnSetting(category, "VALEERA_EDGE_SIZE", "edgeSize",
            db, Settings.VarType.Number, "Border thickness", defaults.edgeSize)
        setting:SetValueChangedCallback(function() ApplyLayout(); RefreshDisplay() end)
        local options = Settings.CreateSliderOptions(1, 32, 1)
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v) return tostring(v) end)
        Settings.CreateSlider(category, setting, options, "Thickness of the tracker window border.")
    end

    pcall(function()
        local layout = SettingsPanel:GetLayout(category)
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Data elements"))
    end)
    for _, el in ipairs(ELEMENTS) do
        if db.show[el.key] == nil then db.show[el.key] = true end
        local setting = Settings.RegisterAddOnSetting(category, "VALEERA_SHOW_" .. el.key:upper(), el.key,
            db.show, Settings.VarType.Boolean, el.label, true)
        setting:SetValueChangedCallback(function() ApplyLayout(); RefreshDisplay() end)
        Settings.CreateCheckbox(category, setting, "Show the \"" .. el.label .. "\" line in the tracker window.")
    end

    Settings.RegisterAddOnCategory(category)
    frame.settingsCategory = category
end

--------------------------------------------------------------------------------
-- Slash
--------------------------------------------------------------------------------

SLASH_VALEERA1 = "/valeera"
SlashCmdList.VALEERA = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", "")
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    if cmd == "reset" then
        state.runActive = false
        state.lastRun = nil
        if state.inDelve then StartRun() end
        RefreshDisplay()
        Print("run reset")
    elseif cmd == "history" then
        for i = math.max(1, #db.history - 9), #db.history do
            local r = db.history[i]
            Print(string.format("%s%s %s +%s (%s/min)", r.delve or "?", r.tier and (" T" .. r.tier) or "",
                FormatDuration(r.seconds), BreakUpLargeNumbers(r.gain), BreakUpLargeNumbers(math.floor(r.perMin))))
        end
    elseif cmd == "clearhistory" then
        wipe(db.history); state.lastRun = nil; RefreshDisplay()
        Print("history cleared")
    elseif cmd == "faction" then
        db.factionID = tonumber(arg)
        Print("faction id set to " .. tostring(db.factionID))
    elseif cmd == "options" or cmd == "config" then
        if frame.settingsCategory then Settings.OpenToCategory(frame.settingsCategory:GetID()) end
    else
        db.showWindow = not db.showWindow
        UpdateVisibility()
        Print("window " .. (db.showWindow and "shown (in delves)" or "hidden"))
    end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:RegisterEvent("SCENARIO_UPDATE")
events:RegisterEvent("SCENARIO_COMPLETED")
events:RegisterEvent("UPDATE_FACTION")
events:RegisterEvent("GOSSIP_SHOW")
events:RegisterEvent("GOSSIP_CLOSED")
events:RegisterEvent("CHAT_MSG_LOOT")

-- Only curiosities count. Everything else you pick up in a delve -- herbs, ore,
-- mob drops, chest loot -- is not companion XP and must not be counted.
--
-- Two forms show up, depending on whether Dundun's Favor is equipped:
--   * without it, you loot the curiosity item itself
--   * with it, the curiosity is consumed on contact and grants a
--     "Chunk of Companion Experience" instead (several item IDs, one per quality)
-- Matching on name covers every quality tier and both forms; the ID set is not
-- fully enumerable and shifts between patches.
-- ponytail: name match, not an ID table. Add IDs only if a curiosity ever stops
-- matching these names.
local CURIO_PATTERNS = { "Curiosity", "Companion Experience" }

local function IsCuriosityLoot(link)
    local name = link and link:match("|h%[(.-)%]|h")
    if not name then return false end
    for _, pat in ipairs(CURIO_PATTERNS) do
        if name:find(pat, 1, true) then return true end
    end
    return false
end

local function OnLoot(msg, guid)
    if not state.runActive or not state.loot then return end
    if guid and guid ~= UnitGUID("player") then return end
    local link = msg:match("|Hitem:.-|h.-|h")
    if not link then return end
    if not IsCuriosityLoot(link) then return end
    local count = tonumber(msg:match("|hx(%d+)")) or tonumber(msg:match("x(%d+)%.?$")) or 1
    local quality = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(link)
    if not quality then quality = select(3, GetItemInfo(link)) end
    if quality == 2 then state.loot[1] = state.loot[1] + count
    elseif quality == 3 then state.loot[2] = state.loot[2] + count
    elseif quality == 4 then state.loot[3] = state.loot[3] + count end
end

events:SetScript("OnEvent", function(_, event, arg1, ...)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        ValeeraDB = ValeeraDB or {}
        db = ValeeraDB
        for k, v in pairs(defaults) do
            if db[k] == nil then
                db[k] = type(v) == "table" and CopyTable(v) or v
            end
        end
        state.lastRun = db.history[#db.history]
        BuildOptions()
        -- Media can register after we load (addons loading later, user-added fonts).
        -- Without this a saved font silently stays on the fallback until /reload.
        if LSM and LSM.RegisterCallback then
            LSM.RegisterCallback(frame, "LibSharedMedia_Registered", function()
                ApplyLayout(); RefreshDisplay()
            end)
        end
        ApplyLayout()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" or event == "SCENARIO_UPDATE" then
        C_Timer.After(1, CheckDelveState)
    elseif event == "SCENARIO_COMPLETED" then
        if state.inDelve then EndRun(); RefreshDisplay() end
    elseif event == "UPDATE_FACTION" then
        if frame:IsShown() then RefreshDisplay() end
    elseif event == "GOSSIP_SHOW" then
        C_Timer.After(0.2, function()
            if DelvesDifficultyPickerFrame and DelvesDifficultyPickerFrame:IsShown() then
                StartTierWatch()
            end
        end)
    elseif event == "CHAT_MSG_LOOT" then
        OnLoot(arg1, (select(11, ...)))
    elseif event == "GOSSIP_CLOSED" then
        StopTierWatch()
    end
end)
