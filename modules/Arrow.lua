-- =============================================================================
-- modules/Arrow.lua
-- Navigation — automatic quest-objective waypoints.
--
-- AUTO MODE   — Points to the current active quest objective automatically.
-- LEADER MODE — Leader-sent waypoints take priority over auto-quest.
--               When cleared the auto-quest waypoint resumes immediately.
--
-- PRIMARY PATH  — TomTom is installed (OptionalDeps: TomTom in .toc).
-- FALLBACK PATH — Blizzard native waypoint (C_Map.SetUserWaypoint).
-- =============================================================================

local Arrow = {}
BoomerMode.modules.Arrow = Arrow

local currentUID            = nil    -- TomTom waypoint UID
local infoFrame             = nil    -- small persistent info banner
local leaderWaypointActive  = false  -- true while a leader-sent waypoint is shown
local autoWaypointQuestID   = nil
local autoWaypointMapID     = nil
local autoWaypointX         = nil
local autoWaypointY         = nil
local refreshTicker         = nil

-- ---------------------------------------------------------------------------
-- TomTom presence check
-- ---------------------------------------------------------------------------
local function TomTomOK()
    return TomTom ~= nil and type(TomTom.AddWaypoint) == "function"
end

-- ---------------------------------------------------------------------------
-- Internal: set the actual waypoint (TomTom or native)
-- ---------------------------------------------------------------------------
local function ApplyWaypoint(mapID, x, y, title)
    if currentUID and TomTomOK() then
        TomTom:RemoveWaypoint(currentUID)
        currentUID = nil
    end
    if C_Map.ClearUserWaypoint then
        C_Map.ClearUserWaypoint()
    end

    if TomTomOK() then
        currentUID = TomTom:AddWaypoint(mapID, x, y, {
            title      = title,
            persistent = false,
            minimap    = true,
            world      = true,
            crazy      = true,
        })
    else
        local ok, mapPoint = pcall(UiMapPoint.CreateFromCoordinates, mapID, x, y)
        if ok and mapPoint then
            C_Map.SetUserWaypoint(mapPoint)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Internal: clear any active waypoint (TomTom + native)
-- ---------------------------------------------------------------------------
local function ClearWaypointInternal()
    if currentUID and TomTomOK() then
        TomTom:RemoveWaypoint(currentUID)
    end
    currentUID = nil
    if C_Map.ClearUserWaypoint then
        C_Map.ClearUserWaypoint()
    end
end

-- ---------------------------------------------------------------------------
-- Public: set a waypoint
-- source = "leader" means leader broadcast; "quest" means auto-quest.
-- ---------------------------------------------------------------------------
function Arrow:SetWaypoint(mapID, x, y, title, source)
    if not BoomerModeDB.arrow.enabled then return end

    title  = title or "Go Here!"
    source = source or "leader"

    if source == "leader" then
        leaderWaypointActive = true
    end

    ApplyWaypoint(mapID, x, y, title)

    if source == "leader" then
        BoomerMode.UI:ShowToast("WAYPOINT SET!", title, "gold")
        BoomerMode.UI:PlayAlert("quest")
    end

    self:_updateBanner(mapID, x, y, title)
    if infoFrame and BoomerModeDB.arrow.bannerEnabled ~= false then infoFrame:Show() end
end

-- ---------------------------------------------------------------------------
-- Public: clear the active waypoint
-- ---------------------------------------------------------------------------
function Arrow:ClearWaypoint()
    ClearWaypointInternal()
    leaderWaypointActive = false
    autoWaypointQuestID  = nil
    autoWaypointMapID    = nil
    autoWaypointX        = nil
    autoWaypointY        = nil
    if infoFrame then
        infoFrame.label:SetText("")
        infoFrame:Hide()
    end
    -- Leader waypoint cleared — try to resume quest waypoint
    self:UpdateQuestWaypoint()
end

-- ---------------------------------------------------------------------------
-- Public: toggle the module on/off
-- ---------------------------------------------------------------------------
function Arrow:Toggle()
    BoomerModeDB.arrow.enabled = not BoomerModeDB.arrow.enabled
    if BoomerModeDB.arrow.enabled then
        BoomerMode:Print("Navigation |cFF00FF00enabled|r." ..
            (TomTomOK() and "" or " (Install TomTom for the arrow HUD)"))
        self:UpdateQuestWaypoint()
    else
        BoomerMode:Print("Navigation |cFFFF3333disabled|r.")
        ClearWaypointInternal()
        if infoFrame then infoFrame:Hide() end
    end
end

-- ---------------------------------------------------------------------------
-- Public: toggle the waypoint banner box on/off (TomTom arrow is unaffected)
-- ---------------------------------------------------------------------------
function Arrow:ToggleBanner()
    BoomerModeDB.arrow.bannerEnabled = not (BoomerModeDB.arrow.bannerEnabled ~= false)
    if BoomerModeDB.arrow.bannerEnabled then
        BoomerMode:Print("Waypoint banner |cFF00FF00shown|r.")
        if infoFrame and (leaderWaypointActive or autoWaypointQuestID) then
            infoFrame:Show()
        end
    else
        BoomerMode:Print("Waypoint banner |cFFFF3333hidden|r.")
        if infoFrame then infoFrame:Hide() end
    end
end

-- ---------------------------------------------------------------------------
-- Auto-quest waypoint: fetch active quest objective and point arrow there
-- ---------------------------------------------------------------------------
function Arrow:UpdateQuestWaypoint()
    if not BoomerModeDB.arrow.enabled then return end
    if leaderWaypointActive then return end

    local QW = BoomerMode.modules.QuestWatcher
    if not QW or not QW.GetActiveQuestWaypoint then return end

    local wp = QW:GetActiveQuestWaypoint()
    if not wp then
        if autoWaypointQuestID then
            ClearWaypointInternal()
            autoWaypointQuestID = nil
            if infoFrame then
                infoFrame.label:SetText("")
                infoFrame:Hide()
            end
        end
        return
    end

    -- Only update the actual waypoint if the target changed
    if wp.questID == autoWaypointQuestID
       and wp.mapID == autoWaypointMapID
       and wp.x == autoWaypointX
       and wp.y == autoWaypointY then
        -- Waypoint unchanged, but refresh banner for floor direction updates
        self:_updateBanner(wp.mapID, wp.x, wp.y, wp.title or "Quest Objective")
        return
    end

    autoWaypointQuestID = wp.questID
    autoWaypointMapID   = wp.mapID
    autoWaypointX       = wp.x
    autoWaypointY       = wp.y

    local title = wp.title or "Quest Objective"
    ApplyWaypoint(wp.mapID, wp.x, wp.y, title)
    self:_updateBanner(wp.mapID, wp.x, wp.y, title)
    if infoFrame and BoomerModeDB.arrow.bannerEnabled ~= false then infoFrame:Show() end
end

-- ---------------------------------------------------------------------------
-- Build the small info banner
-- ---------------------------------------------------------------------------
local function BuildInfoBanner()
    local BANNER_W = 300
    local f = BoomerMode.UI:CreateFrame("BoomerModeArrowBanner", BANNER_W, 500, nil)
    f:SetPoint("RIGHT", UIParent, "RIGHT", -20, 0)
    BoomerMode.UI:RestorePosition("BoomerModeArrowBanner", f)

    local textWidth = BANNER_W - 20  -- usable text width

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -10)
    label:SetWidth(textWidth)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(true)
    label:SetTextColor(1, 0.843, 0, 1)
    label:SetText("")
    f.label = label

    -- OnUpdate shrinks the oversized frame to fit actual text height.
    f._lastHeight = 0
    f:SetScript("OnUpdate", function(self)
        local labelH = self.label:GetStringHeight() or 0
        if labelH == 0 then return end
        local height = labelH + 20  -- 10 top + 10 bottom padding
        if height < 30 then height = 30 end
        if math.abs(height - self._lastHeight) > 1 then
            self._lastHeight = height
            self:SetHeight(height)
        end
    end)

    return f
end

-- ---------------------------------------------------------------------------
-- Format objective text: move trailing percentage/fraction to the front
-- ---------------------------------------------------------------------------
local function FormatObjective(text)
    -- Match "blah: 45%" or "blah: 3/8" at end
    local desc, progress = text:match("^(.-):%s*(%d[%d/%%]*)%%?$")
    if not desc then
        -- Match "blah 45%" at end (no colon)
        desc, progress = text:match("^(.-)%s+(%d+%%)$")
    end
    if not desc then
        -- Match "blah: 3/8" at end
        desc, progress = text:match("^(.-):%s*(%d+/%d+)$")
    end
    if desc and progress then
        -- Ensure % is shown
        if not progress:find("%%") and not progress:find("/") then
            progress = progress .. "%%"
        end
        return "(" .. progress .. ") " .. desc
    end
    return text
end

-- ---------------------------------------------------------------------------
-- Update banner text
-- ---------------------------------------------------------------------------
function Arrow:_updateBanner(mapID, x, y, title)
    if not infoFrame then return end

    local lines = {}

    -- Show all story/campaign quests with objectives
    local QW = BoomerMode.modules.QuestWatcher
    if QW and QW.GetCampaignQuestsWithObjectives then
        local campaigns = QW:GetCampaignQuestsWithObjectives()
        for i, quest in ipairs(campaigns) do
            if quest.isActive then
                lines[#lines + 1] = "|cFFFFD700>> " .. quest.title .. " (" .. quest.pct .. "%%)|r"
            else
                lines[#lines + 1] = "|cFF949494" .. quest.title .. " (" .. quest.pct .. "%%)|r"
            end
            for _, obj in ipairs(quest.objectives) do
                if obj.text and obj.text ~= "" then
                    local formatted = FormatObjective(obj.text)
                    if obj.finished then
                        lines[#lines + 1] = "  |cFF22E622Done|r " .. formatted
                    elseif quest.isActive then
                        lines[#lines + 1] = "  |cFFFFFFFF- " .. formatted .. "|r"
                    else
                        lines[#lines + 1] = "  |cFF949494- " .. formatted .. "|r"
                    end
                end
            end
        end
    end

    if #lines == 0 then
        infoFrame.label:SetText("|cFF949494No story quests|r")
    else
        infoFrame.label:SetText(table.concat(lines, "\n"))
    end
end

-- ---------------------------------------------------------------------------
-- Module lifecycle
-- ---------------------------------------------------------------------------
function Arrow:Initialize()
    infoFrame = BuildInfoBanner()
    refreshTicker = C_Timer.NewTicker(2, function()
        if BoomerModeDB.arrow.enabled and not leaderWaypointActive then
            Arrow:UpdateQuestWaypoint()
        end
    end)
end

function Arrow:OnEvent(event, ...)
    if event == "QUEST_POI_UPDATE"
       or event == "ZONE_CHANGED"
       or event == "ZONE_CHANGED_INDOORS"
       or event == "QUEST_LOG_UPDATE"
       or event == "QUEST_ACCEPTED"
       or event == "QUEST_TURNED_IN"
       or event == "SUPER_TRACKING_CHANGED" then
        self:UpdateQuestWaypoint()
    end
end

function Arrow:OnInternalEvent(event, ...)
    if event == "QUEST_WAYPOINT_UPDATE" then
        self:UpdateQuestWaypoint()
    end
end
