-- =============================================================================
-- modules/UI.lua
-- Shared visual layer: frame factory, toast notifications, sounds, colours,
-- and position save/restore.  Loaded before all other modules.
-- =============================================================================

local UI = {}
BoomerMode.modules.UI = UI
BoomerMode.UI = UI   -- shorthand alias used by other modules

-- ---------------------------------------------------------------------------
-- Colour palette  (r, g, b  as 0-1 floats and |cAARRGGBB| hex strings)
-- ---------------------------------------------------------------------------
UI.Colors = {
    gold   = { 1,    0.843, 0    },
    green  = { 0.13, 0.90,  0.13 },
    red    = { 1,    0.20,  0.20 },
    gray   = { 0.58, 0.58,  0.58 },
    blue   = { 0.30, 0.76,  1    },
    white  = { 1,    1,     1    },
    orange = { 1,    0.55,  0    },
}

UI.Hex = {
    gold   = "|cFFFFD700",
    green  = "|cFF22E622",
    red    = "|cFFFF3333",
    gray   = "|cFF949494",
    blue   = "|cFF4CC2FF",
    white  = "|cFFFFFFFF",
    orange = "|cFFFF8C00",
    reset  = "|r",
}

-- ---------------------------------------------------------------------------
-- Sound helpers
-- The SOUNDKIT global table is the safest way to reference sounds; numeric
-- fallbacks are used when SOUNDKIT isn't available yet.
-- ---------------------------------------------------------------------------
local SK = SOUNDKIT or {}
local SOUNDS = {
    quest        = SK.IG_QUEST_LOG_UPDATE            or 878,
    questDone    = SK.UI_QUEST_TOAST_TURN_IN         or 878,
    alert        = SK.RAID_WARNING                   or 8959,
    danger       = SK.RAID_BOSS_EMOTE_WARNING_BEFORE or 8959,
    success      = SK.UI_QUESTPOI_REPORTCOMPLETE     or 878,
    interact     = SK.IG_MAINMENU_OPEN               or 779,
    levelup      = SK.LEVELUP                        or 888,
    defensive    = SK.RAID_BOSS_EMOTE_WARNING_BEFORE or 8959,
}

function UI:PlayAlert(soundType)
    local id = SOUNDS[soundType] or SOUNDS.alert
    PlaySound(id, "Master")
end

-- ---------------------------------------------------------------------------
-- Frame lock system — when locked, frames cannot be dragged.
-- ---------------------------------------------------------------------------
local framesLocked = false
local managedFrames = {}  -- tracked frames for lock/unlock

function UI:IsLocked()
    return framesLocked
end

function UI:SetLocked(locked)
    framesLocked = locked
    BoomerModeDB.framesLocked = locked
    for _, f in ipairs(managedFrames) do
        if locked then
            f:SetMovable(false)
            if f._dragHandle then f._dragHandle:EnableMouse(false) end
        else
            f:SetMovable(true)
            if f._dragHandle then f._dragHandle:EnableMouse(true) end
        end
    end
end

function UI:ToggleLock()
    self:SetLocked(not framesLocked)
    BoomerMode:Print("Frames " .. (framesLocked and "|cFFFF3333LOCKED|r — windows cannot be moved." or "|cFF00FF00UNLOCKED|r — drag windows to reposition."))
end

-- ---------------------------------------------------------------------------
-- Frame factory
-- Returns a styled, movable, drag-saveable frame.
-- ---------------------------------------------------------------------------
function UI:CreateFrame(frameName, width, height, titleText)
    local f = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.10, 0.93)
    f:SetBackdropBorderColor(1, 0.843, 0, 1)

    -- Title
    if titleText then
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", f, "TOP", 0, -12)
        title:SetTextColor(1, 0.843, 0, 1)
        title:SetText(titleText)
        f.titleStr = title

        -- Invisible drag handle across the title area
        local drag = CreateFrame("Frame", nil, f)
        drag:SetPoint("TOPLEFT",  f, "TOPLEFT",  8, -4)
        drag:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -4)
        drag:SetHeight(28)
        drag:EnableMouse(not framesLocked)
        drag:RegisterForDrag("LeftButton")
        drag:SetScript("OnDragStart", function() if not framesLocked then f:StartMoving() end end)
        drag:SetScript("OnDragStop", function()
            f:StopMovingOrSizing()
            UI:SavePosition(frameName, f)
        end)
        f._dragHandle = drag
    end

    if framesLocked then
        f:SetMovable(false)
    end
    f:SetScript("OnDragStart", function(self) if not framesLocked then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        UI:SavePosition(frameName, self)
    end)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)
    f.closeBtn = closeBtn

    f:SetFrameStrata("HIGH")
    f:Hide()

    -- Register for lock management
    table.insert(managedFrames, f)

    return f
end

-- ---------------------------------------------------------------------------
-- Position persistence
-- ---------------------------------------------------------------------------
function UI:SavePosition(key, frame)
    if not BoomerModeDB or not BoomerModeDB.positions then return end
    local point, _, relPoint, x, y = frame:GetPoint()
    if point then
        BoomerModeDB.positions[key] = { point, relPoint, x, y }
    end
end

function UI:RestorePosition(key, frame)
    if not BoomerModeDB or not BoomerModeDB.positions then return end
    local pos = BoomerModeDB.positions[key]
    if pos then
        frame:ClearAllPoints()
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    end
end

-- ---------------------------------------------------------------------------
-- Toast notification system
-- Up to 3 toasts visible at once; extras are queued.
-- ---------------------------------------------------------------------------
local TOAST_W        = 400
local TOAST_H        = 78
local TOAST_GAP      = 8
local TOAST_DURATION = 5.5   -- seconds visible
local TOAST_FADE     = 0.55  -- seconds to fade out
local MAX_TOASTS     = 3
local TOAST_ANCHOR   = "TOP"   -- anchor from top-center, well above action bars

local toastPool  = {}   -- pre-built frames
local toastQueue = {}   -- {title, msg, colorKey}

local function MakeToastFrame()
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetSize(TOAST_W, TOAST_H)
    f:SetFrameStrata("TOOLTIP")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.10, 0.96)

    local titleStr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleStr:SetPoint("TOPLEFT",  f, "TOPLEFT",  12, -10)
    titleStr:SetPoint("TOPRIGHT", f, "TOPRIGHT", -36, -10)
    titleStr:SetJustifyH("LEFT")
    f.titleStr = titleStr

    local bodyStr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    bodyStr:SetPoint("TOPLEFT",  titleStr, "BOTTOMLEFT",  0, -4)
    bodyStr:SetPoint("TOPRIGHT", titleStr, "BOTTOMRIGHT", 0, -4)
    bodyStr:SetJustifyH("LEFT")
    bodyStr:SetTextColor(0.90, 0.90, 0.90, 1)
    f.bodyStr = bodyStr

    -- Dismiss button
    local x = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    x:SetSize(24, 24)
    x:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    x:SetScript("OnClick", function()
        f:SetScript("OnUpdate", nil)
        f:Hide()
        UI:_pumpQueue()
    end)

    f._busy = false
    f:Hide()
    return f
end

for i = 1, MAX_TOASTS do toastPool[i] = MakeToastFrame() end

local function PositionToasts()
    for i = 1, MAX_TOASTS do
        toastPool[i]:ClearAllPoints()
        toastPool[i]:SetPoint("TOP", UIParent, "TOP",
            0, -80 - (i - 1) * (TOAST_H + TOAST_GAP))
    end
end
PositionToasts()

function UI:_pumpQueue()
    if #toastQueue == 0 then return end
    for i = 1, MAX_TOASTS do
        local f = toastPool[i]
        if not f._busy then
            local t = table.remove(toastQueue, 1)
            UI:_showOnFrame(f, t.title, t.msg, t.colorKey)
            return
        end
    end
end

function UI:_showOnFrame(f, title, msg, colorKey)
    local c = UI.Colors[colorKey] or UI.Colors.gold
    f._busy = true
    f:SetAlpha(1)
    f.titleStr:SetText(title)
    f.titleStr:SetTextColor(c[1], c[2], c[3], 1)
    f.bodyStr:SetText(msg or "")
    f:Show()

    local elapsed = 0
    f:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed < TOAST_DURATION then return end
        local fade = elapsed - TOAST_DURATION
        local alpha = 1 - (fade / TOAST_FADE)
        if alpha <= 0 then
            self:SetScript("OnUpdate", nil)
            self:Hide()
            self._busy = false
            UI:_pumpQueue()
        else
            self:SetAlpha(alpha)
        end
    end)
end

-- Public entry point.
function UI:ShowToast(title, msg, colorKey)
    for i = 1, MAX_TOASTS do
        if not toastPool[i]._busy then
            self:_showOnFrame(toastPool[i], title, msg, colorKey)
            return
        end
    end
    -- All slots busy — queue it.
    table.insert(toastQueue, { title = title, msg = msg, colorKey = colorKey })
end

-- ---------------------------------------------------------------------------
-- Screen-edge danger flash
-- ---------------------------------------------------------------------------
local flashFrame
local function EnsureFlashFrame()
    if flashFrame then return end
    flashFrame = CreateFrame("Frame", "BoomerModeFlash", UIParent)
    flashFrame:SetAllPoints(UIParent)
    flashFrame:SetFrameStrata("BACKGROUND")
    local t = flashFrame:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(1, 0, 0, 0)
    flashFrame.tex = t
    flashFrame:Hide()
end

function UI:FlashScreen(r, g, b, maxAlpha, duration)
    EnsureFlashFrame()
    r, g, b       = r or 1, g or 0, b or 0
    maxAlpha      = maxAlpha or 0.30
    duration      = duration or 0.8
    flashFrame.tex:SetColorTexture(r, g, b, maxAlpha)
    flashFrame:SetAlpha(1)
    flashFrame:Show()
    local elapsed = 0
    flashFrame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        local a = 1 - (elapsed / duration)
        if a <= 0 then
            self:SetScript("OnUpdate", nil)
            self:Hide()
        else
            self:SetAlpha(a)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Module lifecycle stubs (UI has no WoW events of its own)
-- ---------------------------------------------------------------------------
function UI:Initialize()
    -- Restore lock state from saved variables.
    if BoomerModeDB and BoomerModeDB.framesLocked then
        framesLocked = true
    end
end
function UI:OnEvent() end
