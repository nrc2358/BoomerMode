-- =============================================================================
-- modules/LeaderSync.lua
-- Leader dashboard + group-wide addon-message protocol.
--
-- The leader's own campaign quests are auto-detected from their quest log and
-- broadcast to the group.  Each member reports which campaign quests they have.
-- The dashboard shows N/M story quest match so the leader instantly sees if
-- a partner missed picking up a quest.
--
-- MESSAGE FORMAT  (prefix "BoomerMode", max 255 chars)
--   STATUS        |name:quest:pct:zone:ilvl:dur:cid1,cid2,cid3
--   REQUEST       (leader -> all, ask for STATUS)
--   WAYPOINT      |mapID:x:y:title       (leader -> all, sets Arrow waypoint)
--   TOAST         |colorKey:title:msg    (leader -> all, shows toast)
--   CAMPAIGN_LIST |cid1,cid2,cid3        (leader -> all, story quests to match)
--   ACTIVE_QUEST  |questID               (leader -> all, supertrack this quest)
-- =============================================================================

local LS = {}
BoomerMode.modules.LeaderSync = LS

local enabled    = true
local dashboard  = nil
local memberData = {}
local lastBroadcast = 0
local BROADCAST_INTERVAL = 30
local ROW_HEADER_H  = 22
local OBJ_ITEM_H    = 15
local MAX_OBJ_LINES = 6
local MAX_ROWS      = 10

-- Leader's campaign quest list (auto-detected from their own quest log).
local leaderCampaignQuests = {}   -- { {questID=N, title="..."}, ... }
local leaderCampaignIDs    = {}   -- { [questID] = true }

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------
local function SendAddon(message, channel, target)
    local fn = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
    if not fn then return end
    pcall(fn, "BoomerMode", message, channel, target)
end

local function GroupChannel()
    if IsInRaid()  then return "RAID"  end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function Sanitise(s)
    s = tostring(s or ""):gsub("[|:~;]", " ")
    return s:sub(1, 60)
end

-- Sanitise objective text: keep colons (part of display), strip protocol chars.
local function SanitiseObj(s)
    s = tostring(s or ""):gsub("[|~;]", " ")
    return s:sub(1, 40)
end

-- ---------------------------------------------------------------------------
-- Leader campaign quest detection (scans leader's own quest log)
-- ---------------------------------------------------------------------------
local function RefreshLeaderCampaignQuests()
    leaderCampaignQuests = {}
    leaderCampaignIDs    = {}
    local QW = BoomerMode.modules.QuestWatcher
    if not QW then return end
    local quests = QW:ScanQuestLog()
    for _, q in ipairs(quests) do
        if q.isCampaign then
            table.insert(leaderCampaignQuests, { questID = q.questID, title = q.title })
            leaderCampaignIDs[q.questID] = true
        end
    end
end

-- ---------------------------------------------------------------------------
-- Build STATUS payload
-- ---------------------------------------------------------------------------
local function BuildStatusPayload()
    local name = UnitName("player") or "Unknown"
    local QW = BoomerMode.modules.QuestWatcher
    local status = QW and QW:GetStatus() or { questName = "?", questPct = 0, zone = "?" }

    local GA = BoomerMode.modules.GearAdvisor
    local ilvl   = GA and GA.GetAvgIlvl and GA:GetAvgIlvl() or 0
    local durPct = GA and GA.GetDurabilityPct and GA:GetDurabilityPct() or 100

    local cids = {}
    if QW and QW.GetCampaignQuestIDs then
        local idSet = QW:GetCampaignQuestIDs()
        for id in pairs(idSet) do
            table.insert(cids, tostring(id))
        end
    end
    local cidsStr = #cids > 0 and table.concat(cids, ",") or "0"

    local base = string.format("STATUS|%s:%s:%d:%s:%d:%d:%s",
        Sanitise(name),
        Sanitise(status.questName),
        status.questPct,
        Sanitise(status.zone),
        ilvl,
        durPct,
        cidsStr
    )
    -- Append per-objective data after a second | separator.
    local objParts = {}
    for i, obj in ipairs(status.objectives or {}) do
        if i > MAX_OBJ_LINES then break end
        table.insert(objParts, SanitiseObj(obj.text) .. "~" .. (obj.finished and "1" or "0"))
    end
    if #objParts > 0 then
        local objStr = "|" .. table.concat(objParts, ";")
        if #base + #objStr <= 255 then
            return base .. objStr
        end
    end
    return base
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------
function LS:BroadcastStatus()
    local ch = GroupChannel()
    if not ch then return end
    SendAddon(BuildStatusPayload(), ch)
end

function LS:RequestSync()
    local ch = GroupChannel()
    if not ch then return end
    SendAddon("REQUEST", ch)
    self:_recordSelf()
    self:BroadcastCampaignList()
    self:BroadcastActiveQuest()
    self:RefreshDashboard()
end

function LS:BroadcastWaypoint(mapID, x, y, title)
    local ch = GroupChannel()
    if not ch then return end
    local msg = string.format("WAYPOINT|%d:%.4f:%.4f:%s",
        mapID, x, y, Sanitise(title or "Go Here!"))
    SendAddon(msg, ch)
    if BoomerMode.modules.Arrow then
        BoomerMode.modules.Arrow:SetWaypoint(mapID, x, y, title, "leader")
    end
end

function LS:BroadcastToast(colorKey, title, msg)
    local ch = GroupChannel()
    if not ch then return end
    local payload = string.format("TOAST|%s:%s:%s",
        Sanitise(colorKey), Sanitise(title), Sanitise(msg))
    SendAddon(payload, ch)
    BoomerMode.UI:ShowToast(title, msg, colorKey)
    BoomerMode.UI:PlayAlert("alert")
end

function LS:BroadcastCampaignList()
    local ch = GroupChannel()
    if not ch then return end
    RefreshLeaderCampaignQuests()
    local ids = {}
    for _, q in ipairs(leaderCampaignQuests) do
        table.insert(ids, tostring(q.questID))
    end
    if #ids > 0 then
        SendAddon("CAMPAIGN_LIST|" .. table.concat(ids, ","), ch)
    end
end

function LS:BroadcastActiveQuest()
    local ch = GroupChannel()
    if not ch then return end
    local QW = BoomerMode.modules.QuestWatcher
    if not QW then return end
    local questID = QW:GetActiveQuestID()
    if questID and questID > 0 then
        SendAddon("ACTIVE_QUEST|" .. tostring(questID), ch)
    end
end

function LS:OnBecomeLeader()
    RefreshLeaderCampaignQuests()
    if dashboard then dashboard:Show() end
    self:RequestSync()
    self:BroadcastActiveQuest()
end

function LS:OnQuestUpdate()
    local now = GetTime()
    if now - lastBroadcast > 5 then
        lastBroadcast = now
        self:BroadcastStatus()
        if BoomerMode:IsLeader() then
            RefreshLeaderCampaignQuests()
            self:BroadcastCampaignList()
            self:BroadcastActiveQuest()
        end
    end
end

function LS:_recordSelf()
    local name = UnitName("player") or "Unknown"
    local QW = BoomerMode.modules.QuestWatcher
    local status = QW and QW:GetStatus() or { questName = "?", questPct = 0, zone = "?" }
    local GA = BoomerMode.modules.GearAdvisor
    local ilvl   = GA and GA.GetAvgIlvl and GA:GetAvgIlvl() or 0
    local durPct = GA and GA.GetDurabilityPct and GA:GetDurabilityPct() or 100
    local campaignIDs = {}
    if QW and QW.GetCampaignQuestIDs then
        campaignIDs = QW:GetCampaignQuestIDs()
    end
    memberData[name] = {
        questName   = status.questName,
        questPct    = status.questPct,
        zone        = status.zone,
        ilvl        = ilvl,
        durPct      = durPct,
        campaignIDs = campaignIDs,
        objectives  = status.objectives or {},
    }
end

-- ---------------------------------------------------------------------------
-- Parse incoming addon messages
-- ---------------------------------------------------------------------------
local function ParseMessage(msgBody, senderName)
    local msgType, data = msgBody:match("^([^|]+)|?(.*)$")
    if not msgType then return end
    msgType = msgType:upper()

    if msgType == "STATUS" then
        local name, quest, pctStr, zone, ilvlStr, durStr, cidsStr =
            data:match("^([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):([^:]*):?(.*)$")
        if name then
            -- Split cidsStr at the optional second | to separate campaign IDs from objectives.
            local rawCids, objStr = cidsStr:match("^([^|]*)|?(.*)$")
            rawCids = rawCids or cidsStr
            local campaignIDs = {}
            if rawCids and rawCids ~= "" and rawCids ~= "0" then
                for id in rawCids:gmatch("(%d+)") do
                    local n = tonumber(id)
                    if n and n > 0 then campaignIDs[n] = true end
                end
            end
            local objectives = {}
            if objStr and objStr ~= "" then
                for entry in objStr:gmatch("([^;]+)") do
                    local text, flag = entry:match("^(.+)~([01])$")
                    if text then
                        table.insert(objectives, { text = text, finished = flag == "1" })
                    end
                end
            end
            memberData[name] = {
                questName   = quest or "?",
                questPct    = tonumber(pctStr) or 0,
                zone        = zone or "?",
                ilvl        = tonumber(ilvlStr) or 0,
                durPct      = tonumber(durStr) or 100,
                campaignIDs = campaignIDs,
                objectives  = objectives,
            }
            if BoomerMode:IsLeader() then
                LS:RefreshDashboard()
            end
        end

    elseif msgType == "REQUEST" then
        LS:BroadcastStatus()

    elseif msgType == "WAYPOINT" then
        local mapIDs, xs, ys, title =
            data:match("^([^:]*):([^:]*):([^:]*):?(.*)$")
        if mapIDs and BoomerMode.modules.Arrow then
            BoomerMode.modules.Arrow:SetWaypoint(
                tonumber(mapIDs), tonumber(xs), tonumber(ys),
                title ~= "" and title or "Go Here!",
                "leader"
            )
        end

    elseif msgType == "TOAST" then
        local colorKey, title, msg =
            data:match("^([^:]*):([^:]*):?(.*)$")
        if title then
            BoomerMode.UI:ShowToast(title, msg, colorKey)
            BoomerMode.UI:PlayAlert("alert")
        end

    elseif msgType == "CAMPAIGN_LIST" then
        local ids = {}
        for id in data:gmatch("(%d+)") do
            local n = tonumber(id)
            if n and n > 0 then table.insert(ids, n) end
        end
        if #ids > 0 then
            local QW = BoomerMode.modules.QuestWatcher
            if QW and QW.CheckLeaderCampaignQuests then
                QW:CheckLeaderCampaignQuests(ids)
            end
        end

    elseif msgType == "ACTIVE_QUEST" then
        local questID = tonumber(data)
        if questID and questID > 0 then
            local QW = BoomerMode.modules.QuestWatcher
            if QW and QW.FollowLeaderQuest then
                QW:FollowLeaderQuest(questID)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Dashboard
-- ---------------------------------------------------------------------------
local COL_NAMES = { "Player", "Current Quest", "Zone", "ilvl", "Dur.", "Story" }
local NUM_COLS  = #COL_NAMES
local MIN_DASH_W = 360
local MIN_DASH_H = 300
local MAX_DASH_W = 900
local MAX_DASH_H = 800

-- Compute adaptive column start-fractions so the short numeric columns keep a
-- fixed pixel width while Player / Quest / Zone share the remaining space.
local activeFracs = { 0.00, 0.15, 0.53, 0.67, 0.76, 0.86 }  -- fallback

local function ComputeColFracs(contentW)
    local ilvlPx  = 38
    local durPx   = 42
    local storyPx = 48
    local fixedPx = ilvlPx + durPx + storyPx
    local flexPx  = math.max(contentW - fixedPx, 80)
    local playerPx = math.floor(flexPx * 0.20)
    local questPx  = math.floor(flexPx * 0.50)
    local zonePx   = flexPx - playerPx - questPx
    activeFracs = {
        0,
        playerPx / contentW,
        (playerPx + questPx) / contentW,
        (playerPx + questPx + zonePx) / contentW,
        (playerPx + questPx + zonePx + ilvlPx) / contentW,
        (playerPx + questPx + zonePx + ilvlPx + durPx) / contentW,
    }
end

local function MakeHeaderRow(parent, contentW)
    if parent._headerLabels then
        for i, label in ipairs(parent._headerLabels) do
            label:ClearAllPoints()
            label:SetPoint("TOPLEFT", parent, "TOPLEFT", math.floor(activeFracs[i] * contentW), -4)
            if i < NUM_COLS then
                label:SetWidth(math.floor((activeFracs[i + 1] - activeFracs[i]) * contentW) - 4)
            else
                label:SetWidth(math.floor((1 - activeFracs[i]) * contentW) - 4)
            end
        end
        return
    end
    parent._headerLabels = {}
    for i, text in ipairs(COL_NAMES) do
        local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", parent, "TOPLEFT", math.floor(activeFracs[i] * contentW), -4)
        if i < NUM_COLS then
            label:SetWidth(math.floor((activeFracs[i + 1] - activeFracs[i]) * contentW) - 4)
        else
            label:SetWidth(math.floor((1 - activeFracs[i]) * contentW) - 4)
        end
        label:SetJustifyH("LEFT")
        label:SetWordWrap(false)
        label:SetTextColor(1, 0.843, 0, 1)
        label:SetText(text)
        parent._headerLabels[i] = label
    end
end

local rowFrames = {}

local function UpdateRow(rowFrame, name, data, contentW)
    if not data then
        rowFrame:Hide()
        return ROW_HEADER_H
    end
    rowFrame:Show()

    for i, col in ipairs(rowFrame.cols) do
        col:ClearAllPoints()
        col:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", math.floor(activeFracs[i] * contentW), -2)
        if i < NUM_COLS then
            col:SetWidth(math.floor((activeFracs[i + 1] - activeFracs[i]) * contentW) - 4)
        else
            col:SetWidth(math.floor((1 - activeFracs[i]) * contentW) - 4)
        end
    end

    -- Col 1: Player name
    rowFrame.cols[1]:SetText(name)
    rowFrame.cols[1]:SetTextColor(1, 1, 1, 1)

    -- Col 2: Quest name
    rowFrame.cols[2]:SetText(data.questName or "?")
    rowFrame.cols[2]:SetTextColor(0.9, 0.9, 0.9, 1)

    -- Col 3: Zone
    rowFrame.cols[3]:SetText(data.zone or "?")
    rowFrame.cols[3]:SetTextColor(0.78, 0.78, 0.78, 1)

    -- Col 4: ilvl
    rowFrame.cols[4]:SetText(tostring(data.ilvl or 0))
    rowFrame.cols[4]:SetTextColor(0.30, 0.76, 1, 1)

    -- Col 5: Durability
    local dur = data.durPct or 100
    rowFrame.cols[5]:SetText(dur .. "%")
    if dur == 0 then
        rowFrame.cols[5]:SetTextColor(1, 0.20, 0.20, 1)
    elseif dur <= 20 then
        rowFrame.cols[5]:SetTextColor(1, 0.55, 0, 1)
    elseif dur <= 50 then
        rowFrame.cols[5]:SetTextColor(1, 0.843, 0, 1)
    else
        rowFrame.cols[5]:SetTextColor(0.13, 0.90, 0.13, 1)
    end

    -- Col 6: Story (N/M campaign quest match)
    local leaderCount = #leaderCampaignQuests
    if leaderCount > 0 then
        local memberCount = 0
        if data.campaignIDs then
            for _, lq in ipairs(leaderCampaignQuests) do
                if data.campaignIDs[lq.questID] then
                    memberCount = memberCount + 1
                end
            end
        end
        rowFrame.cols[6]:SetText(memberCount .. "/" .. leaderCount)
        if memberCount == leaderCount then
            rowFrame.cols[6]:SetTextColor(0.13, 0.90, 0.13, 1)
        elseif memberCount > 0 then
            rowFrame.cols[6]:SetTextColor(1, 0.55, 0, 1)
        else
            rowFrame.cols[6]:SetTextColor(1, 0.20, 0.20, 1)
        end
    else
        rowFrame.cols[6]:SetText("--")
        rowFrame.cols[6]:SetTextColor(0.58, 0.58, 0.58, 1)
    end

    -- Objective sub-lines below the quest name column.
    local objs    = data.objectives or {}
    local objX    = math.floor(activeFracs[2] * contentW) + 8
    local objW    = math.floor((activeFracs[3] - activeFracs[2]) * contentW) - 12
    local objCount = 0
    for j = 1, MAX_OBJ_LINES do
        local lbl = rowFrame.objLabels[j]
        if j <= #objs then
            local obj = objs[j]
            lbl:ClearAllPoints()
            lbl:SetPoint("TOPLEFT", rowFrame, "TOPLEFT", objX,
                -(ROW_HEADER_H + (j - 1) * OBJ_ITEM_H))
            lbl:SetWidth(objW)
            lbl:SetText(obj.text or "")
            if obj.finished then
                lbl:SetTextColor(0.13, 0.90, 0.13, 1)
            else
                lbl:SetTextColor(0.60, 0.60, 0.60, 1)
            end
            lbl:Show()
            objCount = j
        else
            lbl:Hide()
        end
    end

    return ROW_HEADER_H + objCount * OBJ_ITEM_H
end

-- ---------------------------------------------------------------------------
-- Reflow all dashboard content for the current frame size.
-- ---------------------------------------------------------------------------
local function ReflowDashboard(f)
    local fw = f:GetWidth()
    local contentW = fw - 24
    local pad = 12

    -- Recompute adaptive column fractions for the current width.
    ComputeColFracs(contentW)

    -- Pick smaller fonts when the panel is narrow.
    local isNarrow = contentW < 480
    local rowFont = isNarrow and "GameFontNormalSmall" or "GameFontNormal"
    local objFont = "GameFontNormalSmall"

    -- Apply font to all existing row font-strings.
    for _, row in ipairs(rowFrames) do
        for _, col in ipairs(row.cols or {}) do
            col:SetFontObject(rowFont)
        end
        for _, ol in ipairs(row.objLabels or {}) do
            ol:SetFontObject(objFont)
        end
    end

    if f._headerBg then
        f._headerBg:ClearAllPoints()
        f._headerBg:SetPoint("TOPLEFT", f, "TOPLEFT", pad, -48)
        f._headerBg:SetPoint("TOPRIGHT", f, "TOPRIGHT", -pad, -48)
        f._headerBg:SetHeight(18)
        MakeHeaderRow(f._headerBg, contentW)
    end

    if f._sep then
        f._sep:ClearAllPoints()
        f._sep:SetPoint("TOPLEFT", f, "TOPLEFT", pad, -68)
        f._sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -pad, -68)
    end

    -- Adaptive button sizing: distribute available width evenly.
    if f._syncBtn and f._wayptBtn then
        local btnGap = 6
        local availW = contentW - btnGap
        local btnW   = math.floor(availW / 2)
        f._syncBtn:SetSize(btnW, 24)
        f._syncBtn:ClearAllPoints()
        f._syncBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 12)
        f._wayptBtn:SetSize(btnW, 24)
        f._wayptBtn:ClearAllPoints()
        f._wayptBtn:SetPoint("BOTTOMLEFT", f._syncBtn, "BOTTOMRIGHT", btnGap, 0)
    elseif f._syncBtn then
        f._syncBtn:ClearAllPoints()
        f._syncBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 12)
    end
end

-- ---------------------------------------------------------------------------
-- Build the dashboard frame
-- ---------------------------------------------------------------------------
local function BuildDashboard()
    local fw = 640
    local fh = 90 + MAX_ROWS * (ROW_HEADER_H + OBJ_ITEM_H) + 100
    local f  = BoomerMode.UI:CreateFrame("BoomerModeLeaderDash", fw, fh, "GROUP LEADER DASHBOARD")
    f:SetPoint("CENTER")
    BoomerMode.UI:RestorePosition("BoomerModeLeaderDash", f)

    f:SetResizable(true)
    f:SetClampedToScreen(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(MIN_DASH_W, MIN_DASH_H, MAX_DASH_W, MAX_DASH_H)
    elseif f.SetMinResize then
        f:SetMinResize(MIN_DASH_W, MIN_DASH_H)
        f:SetMaxResize(MAX_DASH_W, MAX_DASH_H)
    end

    -- Resize grip — enlarged for easier grabbing
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(24, 24)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(f:GetFrameLevel() + 10)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:RegisterForDrag("LeftButton")
    grip:SetScript("OnDragStart", function()
        if not BoomerMode.UI:IsLocked() then
            f:StartSizing("BOTTOMRIGHT")
        end
    end)
    grip:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        if BoomerModeDB and BoomerModeDB.positions then
            local pos = BoomerModeDB.positions["BoomerModeLeaderDash"]
            if pos then
                pos[5] = f:GetWidth()
                pos[6] = f:GetHeight()
            end
        end
    end)

    -- Live reflow while resizing
    f:SetScript("OnSizeChanged", function()
        ReflowDashboard(f)
        if dashboard then LS:RefreshDashboard() end
    end)

    -- Column headers
    local contentW = fw - 24
    local headerBg = CreateFrame("Frame", nil, f)
    headerBg:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -48)
    headerBg:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -48)
    headerBg:SetHeight(18)
    MakeHeaderRow(headerBg, contentW)
    f._headerBg = headerBg

    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -68)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -68)
    sep:SetHeight(1)
    sep:SetColorTexture(1, 0.843, 0, 0.5)
    f._sep = sep

    -- Member rows
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetPoint("TOPLEFT",  f, "TOPLEFT",  12, -70)
        row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -70)
        row:SetHeight(ROW_HEADER_H)

        if i % 2 == 0 then
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(1, 1, 1, 0.04)
        end

        row.cols = {}
        for colIdx = 1, NUM_COLS do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetPoint("TOPLEFT", row, "TOPLEFT", math.floor(activeFracs[colIdx] * contentW), -2)
            if colIdx < NUM_COLS then
                fs:SetWidth(math.floor((activeFracs[colIdx + 1] - activeFracs[colIdx]) * contentW) - 4)
            else
                fs:SetWidth(math.floor((1 - activeFracs[colIdx]) * contentW) - 4)
            end
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            fs:SetText("")
            row.cols[colIdx] = fs
        end
        -- Pre-allocate objective sub-line labels (shown below the quest name col).
        row.objLabels = {}
        for j = 1, MAX_OBJ_LINES do
            local ol = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            ol:SetJustifyH("LEFT")
            ol:SetWordWrap(false)
            ol:SetText("")
            ol:Hide()
            row.objLabels[j] = ol
        end
        row:Hide()
        rowFrames[i] = row
    end

    -- Action buttons
    local syncBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    syncBtn:SetSize(100, 24)
    syncBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 12)
    syncBtn:SetText("Sync Group")
    syncBtn:SetScript("OnClick", function() LS:RequestSync() end)
    f._syncBtn = syncBtn

    local wayptBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    wayptBtn:SetSize(130, 24)
    wayptBtn:SetPoint("BOTTOMLEFT", syncBtn, "BOTTOMRIGHT", 8, 0)
    wayptBtn:SetText("Send Waypoint...")
    wayptBtn:SetScript("OnClick", function() LS:OpenWaypointDialog() end)
    f._wayptBtn = wayptBtn

    -- Restore saved size
    if BoomerModeDB and BoomerModeDB.positions then
        local pos = BoomerModeDB.positions["BoomerModeLeaderDash"]
        if pos and pos[5] and pos[6] then
            f:SetSize(pos[5], pos[6])
        end
    end

    ReflowDashboard(f)
    return f
end

-- ---------------------------------------------------------------------------
-- Refresh dashboard rows
-- ---------------------------------------------------------------------------
function LS:RefreshDashboard()
    if not dashboard or not dashboard:IsShown() then return end

    RefreshLeaderCampaignQuests()

    local names = {}
    for name in pairs(memberData) do table.insert(names, name) end
    table.sort(names)

    local contentW = dashboard:GetWidth() - 24
    ReflowDashboard(dashboard)

    -- Place rows with variable heights driven by each member's objective count.
    local pad      = 12
    local yOffset  = 70
    for i = 1, MAX_ROWS do
        local row  = rowFrames[i]
        if not row then break end
        local name = names[i]
        local data = name and memberData[name] or nil
        local rowH = UpdateRow(row, name or "", data, contentW)
        if data then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT",  dashboard, "TOPLEFT",  pad,  -yOffset)
            row:SetPoint("TOPRIGHT", dashboard, "TOPRIGHT", -pad, -yOffset)
            row:SetHeight(rowH)
            row:Show()
            yOffset = yOffset + rowH
        else
            row:Hide()
        end
    end


end

-- ---------------------------------------------------------------------------
-- Waypoint broadcast dialog
-- ---------------------------------------------------------------------------
function LS:OpenWaypointDialog()
    if _G["BoomerModeWayptDialog"] and _G["BoomerModeWayptDialog"]:IsShown() then
        _G["BoomerModeWayptDialog"]:Hide()
        return
    end
    local d = BoomerMode.UI:CreateFrame("BoomerModeWayptDialog", 340, 140, "SEND WAYPOINT TO GROUP")
    d:SetPoint("CENTER")
    d:Show()

    local instr = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    instr:SetPoint("TOPLEFT", d, "TOPLEFT", 14, -36)
    instr:SetTextColor(0.9, 0.9, 0.9, 1)
    instr:SetText("Send your current position as a waypoint\nto the whole group.")

    local curBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    curBtn:SetSize(200, 24)
    curBtn:SetPoint("TOPLEFT", d, "TOPLEFT", 14, -68)
    curBtn:SetText("Use My Current Position")
    curBtn:SetScript("OnClick", function()
        local mID = C_Map.GetBestMapForUnit("player") or 0
        local p   = C_Map.GetPlayerMapPosition(mID, "player")
        if p then
            LS:BroadcastWaypoint(mID, p.x, p.y, "Follow me here!")
            BoomerMode.UI:ShowToast("WAYPOINT SENT!", "Your position has been sent.", "gold")
            d:Hide()
        else
            BoomerMode:Print("Could not get player map position.")
        end
    end)

    local cancelBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    cancelBtn:SetSize(80, 24)
    cancelBtn:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -36, 12)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function() d:Hide() end)
end

-- ---------------------------------------------------------------------------
-- Module events
-- ---------------------------------------------------------------------------
function LS:OnEvent(event, ...)
    if not enabled then return end

    if event == "CHAT_MSG_ADDON" then
        local prefix, msgBody, channel, sender = ...
        if prefix ~= "BoomerMode" then return end
        local shortName = sender and sender:match("([^%-]+)") or sender
        ParseMessage(msgBody, shortName)

    elseif event == "GROUP_ROSTER_UPDATE" then
        if BoomerMode:IsLeader() then
            local inGroup = {}
            for i = 1, GetNumGroupMembers() do
                local unit = (IsInRaid() and "raid" or "party") .. i
                local name = UnitName(unit)
                if name then inGroup[name] = true end
            end
            inGroup[UnitName("player")] = true
            for name in pairs(memberData) do
                if not inGroup[name] then memberData[name] = nil end
            end
            self:RefreshDashboard()
        end

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        local now = GetTime()
        if now - lastBroadcast > 5 then
            lastBroadcast = now
            self:BroadcastStatus()
        end
    end
end

function LS:OnInternalEvent(event, ...)
    if event == "ROLE_CHANGED" then
        local role = ...
        if role == "leader" then
            self:OnBecomeLeader()
        else
            if dashboard then dashboard:Hide() end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Periodic auto-broadcast ticker
-- ---------------------------------------------------------------------------
local function StartBroadcastTicker()
    C_Timer.NewTicker(BROADCAST_INTERVAL, function()
        if not enabled then return end
        if not BoomerMode:IsLeader() then
            LS:BroadcastStatus()
        else
            LS:_recordSelf()
            LS:RefreshDashboard()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Module init
-- ---------------------------------------------------------------------------
function LS:Initialize()
    enabled   = BoomerModeDB.leaderSync.enabled ~= false
    dashboard = BuildDashboard()

    if BoomerMode:IsLeader() then
        RefreshLeaderCampaignQuests()
        dashboard:Show()
        self:_recordSelf()
    end

    StartBroadcastTicker()
end
