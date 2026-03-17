-- =============================================================================
-- Boomer Mode — Core
-- Zero-config for members. Everything works automatically.
-- Leaders type /bm for the dashboard.
-- All other logic lives in modules/ loaded after this file.
-- =============================================================================

BoomerMode         = {}
BoomerMode.version = "1.0.0"
BoomerMode.modules = {}   -- modules register themselves here

-- ---------------------------------------------------------------------------
-- Default saved-variable schema
-- ---------------------------------------------------------------------------
local DB_DEFAULTS = {
    positions      = {},
    arrow          = { enabled = true, bannerEnabled = true },
    quests         = { enabled = true },
    gear           = { tooltipsEnabled = true, durabilityEnabled = true },
    leaderSync     = { enabled = true },
    lootReminder   = true,
    framesLocked   = false,
    firstRun       = true,
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function BoomerMode:Print(msg)
    print("|cFF4CC2FFBoomer Mode:|r " .. tostring(msg))
end

function BoomerMode:IsLeader()
    if IsInRaid() or IsInGroup() then
        return UnitIsGroupLeader("player")
    end
    return false
end

-- Broadcast an internal (non-WoW) event to all modules.
function BoomerMode:NotifyModules(event, ...)
    for _, mod in pairs(self.modules) do
        if mod.OnInternalEvent then
            mod:OnInternalEvent(event, ...)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Saved-variable initialisation
-- ---------------------------------------------------------------------------
local function InitDB()
    if not BoomerModeDB then BoomerModeDB = {} end

    for k, v in pairs(DB_DEFAULTS) do
        if BoomerModeDB[k] == nil then
            if type(v) == "table" then
                BoomerModeDB[k] = {}
                for k2, v2 in pairs(v) do
                    BoomerModeDB[k][k2] = v2
                end
            else
                BoomerModeDB[k] = v
            end
        end
    end

    -- Ensure nested tables survive partial upgrades.
    if not BoomerModeDB.positions   then BoomerModeDB.positions   = {} end
    if not BoomerModeDB.arrow       then BoomerModeDB.arrow       = { enabled = true, bannerEnabled = true } end
    if BoomerModeDB.arrow.bannerEnabled == nil then BoomerModeDB.arrow.bannerEnabled = true end
    if not BoomerModeDB.quests      then BoomerModeDB.quests      = { enabled = true } end
    if not BoomerModeDB.gear        then BoomerModeDB.gear        = { enabled = true } end
    if not BoomerModeDB.leaderSync  then BoomerModeDB.leaderSync  = { enabled = true } end
    -- Clean up removed module keys from old versions.
    BoomerModeDB.coach       = nil
    BoomerModeDB.interaction = nil
    BoomerModeDB.role = nil  -- remove legacy manual role key
end

-- ---------------------------------------------------------------------------
-- Settings panel — simple feature toggles for both roles
-- ---------------------------------------------------------------------------
local settingsFrame = nil

local function ShowLeaderDashboard()
    local ls = BoomerMode.modules.LeaderSync
    if ls then ls:OnBecomeLeader() end
end

local function BuildSettings()
    if settingsFrame then return settingsFrame end
    local UI = BoomerMode.UI
    local f = UI:CreateFrame("BoomerModeSettings", 320, 400, "BOOMER MODE SETTINGS")
    f:SetPoint("CENTER")
    UI:RestorePosition("BoomerModeSettings", f)

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sub:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    sub:SetTextColor(0.78, 0.78, 0.78, 1)
    sub:SetText("v" .. BoomerMode.version .. " — toggle features on/off")

    local yOff = -56
    local function AddToggle(label, getter, toggler)
        local row = CreateFrame("Button", nil, f)
        row:SetSize(280, 24)
        row:SetPoint("TOP", f, "TOP", 0, yOff)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local status = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        status:SetPoint("LEFT", row, "LEFT", 4, 0)
        status:SetWidth(260)
        status:SetJustifyH("LEFT")
        status:SetWordWrap(false)
        local function Refresh()
            local on = getter()
            status:SetText((on and "|cFF00FF00ON|r" or "|cFFFF3333OFF|r") .. "  " .. label)
        end
        Refresh()
        row:SetScript("OnClick", function()
            toggler()
            Refresh()
        end)
        yOff = yOff - 28
    end

    AddToggle("Quest Alerts", function()
        return BoomerModeDB.quests.enabled ~= false
    end, function()
        local mod = BoomerMode.modules.QuestWatcher
        if mod then mod:Toggle() end
    end)

    AddToggle("Gear Advisor Tooltips", function()
        return BoomerModeDB.gear.tooltipsEnabled ~= false
    end, function()
        local mod = BoomerMode.modules.GearAdvisor
        if mod then mod:ToggleTooltips() end
    end)

    AddToggle("Gear Durability Alerts", function()
        return BoomerModeDB.gear.durabilityEnabled ~= false
    end, function()
        local mod = BoomerMode.modules.GearAdvisor
        if mod then mod:ToggleDurability() end
    end)

    AddToggle("Loot Pickup Reminders", function()
        return BoomerModeDB.lootReminder ~= false
    end, function()
        local mod = BoomerMode.modules.LootReminder
        if mod then mod:Toggle() end
    end)

    AddToggle("Navigation Arrow", function()
        return BoomerModeDB.arrow.enabled ~= false
    end, function()
        local mod = BoomerMode.modules.Arrow
        if mod then mod:Toggle() end
    end)

    AddToggle("Waypoint Banner Box", function()
        return BoomerModeDB.arrow.bannerEnabled ~= false
    end, function()
        local mod = BoomerMode.modules.Arrow
        if mod and mod.ToggleBanner then mod:ToggleBanner() end
    end)

    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetPoint("TOPLEFT",  f, "TOPLEFT",  14, yOff - 4)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, yOff - 4)
    sep:SetHeight(1)
    sep:SetColorTexture(1, 0.843, 0, 0.3)
    yOff = yOff - 14

    local lockBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    lockBtn:SetSize(260, 26)
    lockBtn:SetPoint("TOP", f, "TOP", 0, yOff)
    local function RefreshLockBtn()
        local locked = BoomerMode.UI and BoomerMode.UI:IsLocked()
        lockBtn:SetText(locked and "Unlock All Frames" or "Lock All Frames")
    end
    RefreshLockBtn()
    lockBtn:SetScript("OnClick", function()
        if BoomerMode.UI then BoomerMode.UI:ToggleLock() end
        RefreshLockBtn()
    end)
    yOff = yOff - 30

    local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    resetBtn:SetSize(260, 26)
    resetBtn:SetPoint("TOP", f, "TOP", 0, yOff)
    resetBtn:SetText("Reset All Frame Positions")
    resetBtn:SetScript("OnClick", function()
        BoomerModeDB.positions = {}
        BoomerMode:Print("|cFFFFD700All frame positions reset.|r Type /reload to apply.")
    end)

    settingsFrame = f
    f:Hide()
    return f
end

local function ToggleSettings()
    local f = BuildSettings()
    if f:IsShown() then f:Hide() else f:Show() end
end

-- ---------------------------------------------------------------------------
-- First-run welcome panel
-- ---------------------------------------------------------------------------
function BoomerMode:ShowWelcome()
    local f = CreateFrame("Frame", "BoomerModeWelcome", UIParent, "BackdropTemplate")
    f:SetSize(440, 320)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if BoomerMode.UI and BoomerMode.UI:IsLocked() then return end
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.12, 0.97)
    f:SetBackdropBorderColor(1, 0.843, 0, 1)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        BoomerModeDB.firstRun = false
        f:Hide()
    end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -20)
    title:SetTextColor(1, 0.843, 0, 1)
    title:SetText("WELCOME TO BOOMER MODE!")

    local sep1 = f:CreateTexture(nil, "ARTWORK")
    sep1:SetPoint("TOPLEFT",  f, "TOPLEFT",  20, -42)
    sep1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -42)
    sep1:SetHeight(1)
    sep1:SetColorTexture(1, 0.843, 0, 0.4)

    local intro = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    intro:SetPoint("TOPLEFT",  f, "TOPLEFT",  28, -52)
    intro:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, -52)
    intro:SetJustifyH("LEFT")
    intro:SetSpacing(4)
    intro:SetTextColor(0.92, 0.92, 0.92, 1)
    intro:SetText(
        "|cFFFFD700Everything works automatically!|r\n\n" ..
        "You don't need to do anything. This addon will:\n\n" ..
        "|cFFFFD700\226\128\162|r  Alert you when quests update\n" ..
        "|cFFFFD700\226\128\162|r  Point an arrow to your quest objective\n" ..
        "|cFFFFD700\226\128\162|r  Tell you if new gear is better or worse\n" ..
        "|cFFFFD700\226\128\162|r  Warn you when your gear is broken\n" ..
        "|cFFFFD700\226\128\162|r  Show waypoints from your group leader\n" ..
        "|cFFFFD700\226\128\162|r  Remind you to pick up loot\n\n" ..
        "If you're the group leader, type |cFFFFD700/bm|r\nto open the leader dashboard."
    )

    local okBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    okBtn:SetSize(200, 32)
    okBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 18)
    okBtn:SetText("GOT IT!")
    okBtn:SetScript("OnClick", function()
        BoomerModeDB.firstRun = false
        f:Hide()
    end)

    f:Show()
end

-- ---------------------------------------------------------------------------
-- Slash commands  /bm
-- ---------------------------------------------------------------------------
SLASH_BOOMERMODE1 = "/bm"
SlashCmdList["BOOMERMODE"] = function(msg)
    msg = msg or ""
    local cmd = (msg:match("^(%S*)") or ""):lower()

    if cmd == "" then
        if BoomerMode:IsLeader() then
            ShowLeaderDashboard()
        else
            ToggleSettings()
        end

    elseif cmd == "settings" then
        ToggleSettings()

    elseif cmd == "lock" then
        if BoomerMode.UI and BoomerMode.UI.ToggleLock then
            BoomerMode.UI:ToggleLock()
        end

    elseif cmd == "reset" then
        BoomerModeDB.positions = {}
        BoomerMode:Print("|cFFFFD700All frame positions reset.|r Type /reload to apply.")

    elseif cmd == "help" then
        BoomerMode:Print("|cFFFFD700=== Boomer Mode " .. BoomerMode.version .. " ===|r")
        BoomerMode:Print("|cFFFFFFFF/bm|r          — Leader: dashboard  |  Member: settings")
        BoomerMode:Print("|cFFFFFFFF/bm settings|r — Toggle features on/off")
        BoomerMode:Print("|cFFFFFFFF/bm lock|r     — Lock/unlock all frames")
        BoomerMode:Print("|cFFFFFFFF/bm reset|r    — Reset frame positions")

    else
        BoomerMode:Print("Unknown command. Type |cFFFFD700/bm help|r.")
    end
end

-- ---------------------------------------------------------------------------
-- Event frame — routes all WoW events to modules
-- ---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "BoomerModeEventFrame")
BoomerMode.eventFrame = eventFrame

local WATCHED_EVENTS = {
    "ADDON_LOADED",
    "PLAYER_ENTERING_WORLD",
    "ZONE_CHANGED_NEW_AREA",
    "ZONE_CHANGED",
    "ZONE_CHANGED_INDOORS",
    "QUEST_LOG_UPDATE",
    "QUEST_ACCEPTED",
    "QUEST_TURNED_IN",
    "PLAYER_EQUIPMENT_CHANGED",
    "CHAT_MSG_ADDON",
    "GROUP_ROSTER_UPDATE",
    "SUPER_TRACKING_CHANGED",
    "QUEST_POI_UPDATE",
    "UPDATE_INVENTORY_DURABILITY",
    "BAG_UPDATE_DELAYED",
    "LOOT_READY",
    "LOOT_OPENED",
    "LOOT_CLOSED",
}
for _, evt in ipairs(WATCHED_EVENTS) do
    eventFrame:RegisterEvent(evt)
end

-- Ordered initialisation so UI is always first.
local INIT_ORDER = {
    "UI", "Arrow", "QuestWatcher", "GearAdvisor",
    "LeaderSync", "LootReminder",
}

local wasLeader = false

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == "BoomerMode" then
            InitDB()
            -- Register addon-message prefix (C_ChatInfo is the modern API).
            if C_ChatInfo then
                C_ChatInfo.RegisterAddonMessagePrefix("BoomerMode")
            end
            -- Initialise modules in declared order.
            for _, modName in ipairs(INIT_ORDER) do
                local mod = BoomerMode.modules[modName]
                if mod and mod.Initialize then
                    local ok, err = pcall(function() mod:Initialize() end)
                    if not ok then
                        BoomerMode:Print("|cFFFF3333Error loading " .. modName .. ":|r " .. tostring(err))
                    end
                end
            end
            BoomerMode:Print("v" .. BoomerMode.version .. " ready. Everything is automatic!")
            -- First-run welcome screen
            if BoomerModeDB.firstRun then
                C_Timer.After(2, function() BoomerMode:ShowWelcome() end)
            end
        end
        return
    end

    -- Auto-detect leader changes.
    if event == "GROUP_ROSTER_UPDATE" then
        local isLeader = BoomerMode:IsLeader()
        if isLeader and not wasLeader then
            wasLeader = true
            BoomerMode:Print("|cFF00FF00You are the group leader.|r Type |cFFFFD700/bm|r for the dashboard.")
            BoomerMode:NotifyModules("ROLE_CHANGED", "leader")
        elseif not isLeader and wasLeader then
            wasLeader = false
            BoomerMode:NotifyModules("ROLE_CHANGED", "member")
        end
    end

    -- Route everything else to every loaded module.
    for _, mod in pairs(BoomerMode.modules) do
        if mod.OnEvent then
            mod:OnEvent(event, ...)
        end
    end
end)
