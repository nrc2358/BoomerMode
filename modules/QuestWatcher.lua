-- =============================================================================
-- modules/QuestWatcher.lua
-- * Tracks the player's active quest and provides waypoint data for Arrow.
-- * Alerts on quest accept/complete (big alert for active quest only).
-- * Auto-supertracks new quests when nothing is tracked.
-- * Detects campaign/story quests for LeaderSync comparison.
-- * Checks if the player is missing any of the leader's campaign quests.
-- =============================================================================

local QW = {}
BoomerMode.modules.QuestWatcher = QW

local enabled = true

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function GetQuestTitle(questID)
    if C_QuestLog.GetTitleForQuestID then
        local t = C_QuestLog.GetTitleForQuestID(questID)
        if t and t ~= "" then return t end
    end
    local n = C_QuestLog.GetNumQuestLogEntries()
    for i = 1, n do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID == questID then
            return info.title or ("Quest " .. questID)
        end
    end
    return "Quest " .. tostring(questID)
end

local function QuestPct(questID)
    local objs = C_QuestLog.GetQuestObjectives(questID)
    if not objs or #objs == 0 then return 0 end
    local done, total = 0, 0
    for _, obj in ipairs(objs) do
        total = total + 1
        if obj.finished then done = done + 1 end
    end
    if total == 0 then return 0 end
    return math.floor((done / total) * 100)
end

local function IsCampaignQuest(info)
    if info.campaignID and info.campaignID > 0 then
        return true
    end
    if C_QuestInfoSystem and C_QuestInfoSystem.GetQuestClassification then
        local ok, cls = pcall(C_QuestInfoSystem.GetQuestClassification, info.questID)
        if ok and cls then
            if cls == 1 or cls == 2 then return true end
            if Enum and Enum.QuestClassification then
                if cls == Enum.QuestClassification.Campaign
                   or cls == Enum.QuestClassification.Important then
                    return true
                end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Public: GetQuestTitleByID
-- ---------------------------------------------------------------------------
function QW:GetQuestTitleByID(questID)
    return GetQuestTitle(questID)
end

-- ---------------------------------------------------------------------------
-- Public: GetActiveQuestObjectiveData
-- Returns { {text, finished, numFulfilled, numRequired}, ... } for each
-- objective of the currently active quest.
-- ---------------------------------------------------------------------------
function QW:GetActiveQuestObjectiveData()
    local questID = self:GetActiveQuestID()
    if not questID then return {} end
    local objs = C_QuestLog.GetQuestObjectives(questID)
    if not objs then return {} end
    local result = {}
    for _, obj in ipairs(objs) do
        table.insert(result, {
            text         = obj.text or "",
            finished     = obj.finished or false,
            numFulfilled = obj.numFulfilled or 0,
            numRequired  = obj.numRequired or 0,
        })
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Public: GetCampaignQuestsWithObjectives
-- Returns a list of all campaign/story quests with their objectives.
-- Each entry: {questID, title, pct, isActive, objectives={{text,finished},...}}
-- ---------------------------------------------------------------------------
function QW:GetCampaignQuestsWithObjectives()
    local activeID = self:GetActiveQuestID()
    local quests = self:ScanQuestLog()
    local result = {}
    for _, q in ipairs(quests) do
        if q.isCampaign then
            local objs = C_QuestLog.GetQuestObjectives(q.questID)
            local objectives = {}
            if objs then
                for _, obj in ipairs(objs) do
                    objectives[#objectives + 1] = {
                        text     = obj.text or "",
                        finished = obj.finished or false,
                    }
                end
            end
            result[#result + 1] = {
                questID    = q.questID,
                title      = q.title,
                pct        = q.pct,
                isActive   = (q.questID == activeID),
                objectives = objectives,
            }
        end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Public: ScanQuestLog — returns all quests, campaign-first.
-- ---------------------------------------------------------------------------
function QW:ScanQuestLog()
    local results = {}
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    for i = 1, numEntries do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID then
            table.insert(results, {
                questID    = info.questID,
                title      = info.title or ("Quest " .. info.questID),
                pct        = QuestPct(info.questID),
                isCampaign = IsCampaignQuest(info),
            })
        end
    end
    table.sort(results, function(a, b)
        if a.isCampaign ~= b.isCampaign then return a.isCampaign end
        return a.title < b.title
    end)
    return results
end

-- ---------------------------------------------------------------------------
-- Public: GetCampaignQuestIDs — {[questID]=true} for all campaign quests.
-- ---------------------------------------------------------------------------
function QW:GetCampaignQuestIDs()
    local ids = {}
    local quests = self:ScanQuestLog()
    for _, q in ipairs(quests) do
        if q.isCampaign then
            ids[q.questID] = true
        end
    end
    return ids
end

-- ---------------------------------------------------------------------------
-- Public: GetActiveQuestID
-- Priority: supertracked > first incomplete campaign > any incomplete.
-- ---------------------------------------------------------------------------
function QW:GetActiveQuestID()
    if C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID then
        local questID = C_SuperTrack.GetSuperTrackedQuestID()
        if questID and questID > 0 and C_QuestLog.IsOnQuest(questID) then
            return questID
        end
    end
    local quests = self:ScanQuestLog()
    for _, q in ipairs(quests) do
        if q.isCampaign and q.pct < 100 then
            return q.questID
        end
    end
    for _, q in ipairs(quests) do
        if q.pct < 100 then
            return q.questID
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Public: GetActiveQuestWaypoint
-- Returns {questID, mapID, x, y, title} or nil.
-- Also searches sibling floors (same map group) so multi-level areas work.
-- ---------------------------------------------------------------------------
function QW:GetActiveQuestWaypoint()
    local questID = self:GetActiveQuestID()
    if not questID then return nil end
    local title = GetQuestTitle(questID)

    -- Try C_QuestLog.GetNextWaypoint (returns mapID, x, y in some builds).
    if C_QuestLog.GetNextWaypoint then
        local ok, mapID, x, y = pcall(C_QuestLog.GetNextWaypoint, questID)
        if ok and mapID and x and y and (x > 0 or y > 0) then
            return { questID = questID, mapID = mapID, x = x, y = y, title = title }
        end
    end

    -- Fallback: quest POI on the player's map or parent map.
    local playerMap = C_Map.GetBestMapForUnit("player")
    if not playerMap then return nil end

    local function FindOnMap(mapID)
        if not mapID or mapID == 0 then return nil end
        local ok2, quests = pcall(C_QuestLog.GetQuestsOnMap, mapID)
        if not ok2 or not quests then return nil end
        for _, q in ipairs(quests) do
            if q.questID == questID and q.x and q.y and (q.x > 0 or q.y > 0) then
                return { questID = questID, mapID = mapID, x = q.x, y = q.y, title = title }
            end
        end
        return nil
    end

    local result = FindOnMap(playerMap)
    if result then return result end

    -- Search sibling floors in the same map group (multi-level areas).
    if C_Map.GetMapGroupID and C_Map.GetMapGroupMembersInfo then
        local groupID = C_Map.GetMapGroupID(playerMap)
        if groupID then
            local members = C_Map.GetMapGroupMembersInfo(groupID)
            if members then
                for _, member in ipairs(members) do
                    if member.mapID ~= playerMap then
                        result = FindOnMap(member.mapID)
                        if result then return result end
                    end
                end
            end
        end
    end

    local mapInfo = C_Map.GetMapInfo(playerMap)
    if mapInfo and mapInfo.parentMapID and mapInfo.parentMapID > 0 then
        result = FindOnMap(mapInfo.parentMapID)
        if result then return result end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Public: GetStatus (for LeaderSync STATUS broadcasts)
-- ---------------------------------------------------------------------------
function QW:GetStatus()
    local questID    = self:GetActiveQuestID()
    local questName  = "None"
    local questPct   = 0
    local objectives = {}
    if questID then
        questName = GetQuestTitle(questID)
        questPct  = QuestPct(questID)
        local objs = C_QuestLog.GetQuestObjectives(questID)
        if objs then
            for _, obj in ipairs(objs) do
                table.insert(objectives, {
                    text     = obj.text or "",
                    finished = obj.finished or false,
                })
            end
        end
    end
    local mapID   = C_Map.GetBestMapForUnit("player")
    local mapInfo = mapID and C_Map.GetMapInfo(mapID)
    local zone    = (mapInfo and mapInfo.name) or GetRealZoneText() or "Unknown"
    return {
        questName  = questName,
        questPct   = questPct,
        zone       = zone,
        objectives = objectives,
    }
end

-- ---------------------------------------------------------------------------
-- Check if the player is missing leader's campaign quests
-- ---------------------------------------------------------------------------
function QW:CheckLeaderCampaignQuests(leaderQuestIDs)
    if not enabled then return end
    if not leaderQuestIDs or #leaderQuestIDs == 0 then return end
    local missing = {}
    for _, questID in ipairs(leaderQuestIDs) do
        if not C_QuestLog.IsOnQuest(questID)
           and not C_QuestLog.IsQuestFlaggedCompleted(questID) then
            table.insert(missing, GetQuestTitle(questID))
        end
    end
    if #missing > 0 then
        local list = table.concat(missing, ", ")
        BoomerMode.UI:ShowToast(
            "MISSING STORY QUESTS!",
            "You need: " .. list,
            "red"
        )
        BoomerMode.UI:PlayAlert("alert")
    end
end

-- ---------------------------------------------------------------------------
-- Follow the leader's active quest: supertrack it if the player has it too.
-- ---------------------------------------------------------------------------
local lastLeaderQuestID = nil

function QW:FollowLeaderQuest(questID)
    if not enabled then return end
    if BoomerMode:IsLeader() then return end  -- leader doesn't follow themselves
    if questID == lastLeaderQuestID then return end  -- already following this one
    lastLeaderQuestID = questID

    if not C_QuestLog.IsOnQuest(questID) then return end
    if C_QuestLog.IsQuestFlaggedCompleted(questID) then return end

    -- Supertrack switches the quest arrow + map tracking.
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedQuestID then
        local current = C_SuperTrack.GetSuperTrackedQuestID()
        if current ~= questID then
            C_SuperTrack.SetSuperTrackedQuestID(questID)
            local title = GetQuestTitle(questID)
            BoomerMode:Print("Now tracking leader's quest: |cFFFFD700" .. title .. "|r")
            BoomerMode:NotifyModules("QUEST_WAYPOINT_UPDATE")
        end
    end
end

-- ---------------------------------------------------------------------------
-- Event handlers
-- ---------------------------------------------------------------------------
function QW:OnEvent(event, arg1)
    if not enabled then return end

    if event == "QUEST_ACCEPTED" then
        local questID = arg1
        local title   = GetQuestTitle(questID)
        if C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID then
            local current = C_SuperTrack.GetSuperTrackedQuestID()
            if not current or current == 0 then
                C_SuperTrack.SetSuperTrackedQuestID(questID)
            end
        end
        local activeID = self:GetActiveQuestID()
        if questID == activeID then
            BoomerMode.UI:ShowToast("NEW QUEST!", title, "gold")
            BoomerMode.UI:PlayAlert("quest")
        else
            BoomerMode:Print("New quest: " .. (title or "Unknown"))
        end
        BoomerMode:NotifyModules("QUEST_WAYPOINT_UPDATE")
        if BoomerMode.modules.LeaderSync then
            BoomerMode.modules.LeaderSync:OnQuestUpdate()
        end

    elseif event == "QUEST_TURNED_IN" then
        local questID = arg1
        local title   = GetQuestTitle(questID)
        local activeID = self:GetActiveQuestID()
        if questID == activeID or not activeID then
            BoomerMode.UI:ShowToast("QUEST COMPLETE!", title, "green")
            BoomerMode.UI:PlayAlert("questDone")
        else
            BoomerMode:Print("Quest complete: " .. (title or "Unknown"))
        end
        C_Timer.After(0.5, function()
            BoomerMode:NotifyModules("QUEST_WAYPOINT_UPDATE")
        end)
        if BoomerMode.modules.LeaderSync then
            BoomerMode.modules.LeaderSync:OnQuestUpdate()
        end

    elseif event == "QUEST_LOG_UPDATE" then
        if BoomerMode.modules.LeaderSync then
            BoomerMode.modules.LeaderSync:OnQuestUpdate()
        end

    elseif event == "SUPER_TRACKING_CHANGED" then
        BoomerMode:NotifyModules("QUEST_WAYPOINT_UPDATE")
        if BoomerMode:IsLeader() and BoomerMode.modules.LeaderSync then
            BoomerMode.modules.LeaderSync:BroadcastActiveQuest()
        end

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        C_Timer.After(1, function()
            BoomerMode:NotifyModules("QUEST_WAYPOINT_UPDATE")
        end)
    end
end

function QW:OnInternalEvent(event, arg1)
    -- No internal events to handle currently.
end

-- ---------------------------------------------------------------------------
-- Toggle
-- ---------------------------------------------------------------------------
function QW:Toggle()
    enabled = not enabled
    BoomerModeDB.quests.enabled = enabled
    BoomerMode:Print("Quest Watcher " .. (enabled and "|cFF00FF00enabled|r." or "|cFFFF3333disabled|r."))
end

-- ---------------------------------------------------------------------------
-- Initialize
-- ---------------------------------------------------------------------------
function QW:Initialize()
    enabled = BoomerModeDB.quests.enabled ~= false
    C_Timer.After(3, function()
        BoomerMode:NotifyModules("QUEST_WAYPOINT_UPDATE")
    end)
end
