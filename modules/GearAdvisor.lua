---@diagnostic disable: deprecated
-- =============================================================================
-- modules/GearAdvisor.lua
-- Hooks the game tooltip and appends a single, colour-coded verdict line:
--
--   |cFF00CC00  Upgrade  +14 ilvl  |r
--   |cFFFF3333  Downgrade  -6 ilvl |r
--   |cFF999999  Same Item Level    |r
--
-- Works on GameTooltip, ShoppingTooltip1, and ShoppingTooltip2.
-- =============================================================================

local GA = {}
BoomerMode.modules.GearAdvisor = GA

local tooltipsEnabled   = true
local durabilityEnabled = true

-- ---------------------------------------------------------------------------
-- Slot mapping  (WoW's INVTYPE_* strings → inventory slot IDs)
-- ---------------------------------------------------------------------------
local EQUIP_SLOT = {
    INVTYPE_HEAD           = 1,
    INVTYPE_NECK           = 2,
    INVTYPE_SHOULDER       = 3,
    INVTYPE_BODY           = 4,
    INVTYPE_CHEST          = 5,
    INVTYPE_ROBE           = 5,
    INVTYPE_WAIST          = 6,
    INVTYPE_LEGS           = 7,
    INVTYPE_FEET           = 8,
    INVTYPE_WRIST          = 9,
    INVTYPE_HAND           = 10,
    INVTYPE_FINGER         = 11,   -- ring slot 1 (ring2 = 12, handled below)
    INVTYPE_TRINKET        = 13,   -- trinket slot 1 (trinket2 = 14)
    INVTYPE_CLOAK          = 15,
    INVTYPE_WEAPON         = 16,
    INVTYPE_SHIELD         = 17,
    INVTYPE_2HWEAPON       = 16,
    INVTYPE_WEAPONMAINHAND = 16,
    INVTYPE_WEAPONOFFHAND  = 17,
    INVTYPE_HOLDABLE       = 17,
    INVTYPE_RANGED         = 18,
    INVTYPE_RANGEDRIGHT    = 18,
    INVTYPE_TABARD         = 19,
}

-- For ring/trinket slots we compare against both slots and take the worse-equipped.
local DOUBLE_SLOTS = {
    INVTYPE_FINGER  = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 },
}

-- ---------------------------------------------------------------------------
-- Safe wrapper for GetItemInfo — prefers modern C_Item API.
-- ---------------------------------------------------------------------------
local function SafeGetItemInfo(link)
    if C_Item and C_Item.GetItemInfo then
        return C_Item.GetItemInfo(link)
    elseif GetItemInfo then
        return GetItemInfo(link)
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Get the effective (scaled) item level from an item link.
-- ---------------------------------------------------------------------------
local function GetEffectiveIlvl(link)
    if not link then return nil end
    if GetDetailedItemLevelInfo then
        local ilvl = GetDetailedItemLevelInfo(link)
        if ilvl and ilvl > 0 then return ilvl end
    end
    return nil
end

-- Use ItemLocation for equipped slots so post-upgrade ilvls are always fresh.
local function GetEquippedIlvl(slotID)
    if ItemLocation and C_Item and C_Item.GetCurrentItemLevel then
        local loc = ItemLocation:CreateFromEquipmentSlot(slotID)
        if loc and loc:IsValid() then
            local ilvl = C_Item.GetCurrentItemLevel(loc)
            if ilvl and ilvl > 0 then return ilvl end
        end
    end
    local link = GetInventoryItemLink("player", slotID)
    return link and GetEffectiveIlvl(link)
end

-- Use ItemLocation for bag items — always returns the correct post-squish ilvl.
local function GetBagItemIlvl(bag, slot)
    if ItemLocation and C_Item and C_Item.GetCurrentItemLevel then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        if loc and loc:IsValid() then
            local ilvl = C_Item.GetCurrentItemLevel(loc)
            if ilvl and ilvl > 0 then return ilvl end
        end
    end
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info and info.hyperlink then
        return GetEffectiveIlvl(info.hyperlink)
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Core comparison logic
-- ---------------------------------------------------------------------------
local isProcessing = false   -- guard against tooltip recursion

local function AppendComparison(tooltip, link)
    if isProcessing then return end
    if not tooltipsEnabled then return end
    if not link then return end

    isProcessing = true

    -- Get the equipLocation and ilvl of the hover item.
    local ok, _, _, _, _, _, _, _, _, equipLoc = pcall(SafeGetItemInfo, link)
    if not ok or not equipLoc or equipLoc == "" or equipLoc == "INVTYPE_NON_EQUIP" then
        isProcessing = false
        return
    end
    if equipLoc == "INVTYPE_BAG" or equipLoc == "INVTYPE_QUIVER" then
        isProcessing = false
        return
    end

    local hoverIlvl = GetEffectiveIlvl(link)
    if not hoverIlvl then
        isProcessing = false
        return
    end

    -- Find the best equipped item level in the relevant slot(s).
    local doubleSlots = DOUBLE_SLOTS[equipLoc]
    local slotIDs
    if doubleSlots then
        slotIDs = doubleSlots
    else
        local s = EQUIP_SLOT[equipLoc]
        if not s then
            isProcessing = false
            return
        end
        slotIDs = { s }
    end

    -- For double-slot items (rings/trinkets) compare against the worst
    -- equipped piece, since that's the one you'd actually replace.
    local isDouble = (doubleSlots ~= nil)
    local compareIlvl = isDouble and math.huge or 0
    local hasEquipped = false
    for _, slotID in ipairs(slotIDs) do
        local eIlvl = GetEquippedIlvl(slotID)
        if eIlvl then
            hasEquipped = true
            if isDouble then
                if eIlvl < compareIlvl then compareIlvl = eIlvl end
            else
                if eIlvl > compareIlvl then compareIlvl = eIlvl end
            end
        end
    end
    if isDouble and compareIlvl == math.huge then compareIlvl = 0 end

    local line
    if not hasEquipped then
        line = "|cFF00CC00  New Slot  — equip this!|r"
    else
        local diff = hoverIlvl - compareIlvl
        if diff > 0 then
            line = "|cFF00CC00  Upgrade  +" .. diff .. " ilvl|r"
        elseif diff < 0 then
            line = "|cFFFF3333  Downgrade  " .. diff .. " ilvl|r"
        else
            line = "|cFF949494  Same Item Level  (" .. hoverIlvl .. ")|r"
        end
    end

    tooltip:AddLine(line)
    tooltip:Show()   -- refresh tooltip height (isProcessing guard prevents recursion)
    isProcessing = false
end

-- ---------------------------------------------------------------------------
-- Hook tooltips — use modern TooltipDataProcessor when available, fall back
-- to HookScript("OnTooltipSetItem") for older clients.
-- ---------------------------------------------------------------------------
local function HookTooltips()
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
       and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
            if tooltip == GameTooltip or tooltip == ShoppingTooltip1
               or tooltip == ShoppingTooltip2 or tooltip == ItemRefTooltip then
                local ok, _, link = pcall(tooltip.GetItem, tooltip)
                if ok then AppendComparison(tooltip, link) end
            end
        end)
    else
        local function HookOne(tt)
            if tt and tt.HookScript then
                tt:HookScript("OnTooltipSetItem", function(self)
                    local ok, _, link = pcall(self.GetItem, self)
                    if ok then AppendComparison(self, link) end
                end)
            end
        end
        HookOne(GameTooltip)
        HookOne(ShoppingTooltip1)
        HookOne(ShoppingTooltip2)
        HookOne(ItemRefTooltip)
    end
end

-- ---------------------------------------------------------------------------
-- Public: Toggle
-- ---------------------------------------------------------------------------
function GA:ToggleTooltips()
    tooltipsEnabled = not tooltipsEnabled
    BoomerModeDB.gear.tooltipsEnabled = tooltipsEnabled
    BoomerMode:Print("Gear Advisor Tooltips " .. (tooltipsEnabled and "|cFF00FF00enabled|r." or "|cFFFF3333disabled|r."))
end

function GA:ToggleDurability()
    durabilityEnabled = not durabilityEnabled
    BoomerModeDB.gear.durabilityEnabled = durabilityEnabled
    BoomerMode:Print("Durability Alerts " .. (durabilityEnabled and "|cFF00FF00enabled|r." or "|cFFFF3333disabled|r."))
end

-- ---------------------------------------------------------------------------
-- Durability monitoring
-- ---------------------------------------------------------------------------
local DURABILITY_SLOTS = {1, 3, 5, 6, 7, 8, 9, 10, 16, 17}
local lastDurabilityAlert = 0
local DURABILITY_ALERT_COOLDOWN = 300  -- 5 minutes

function GA:GetDurabilityPct()
    local lowest = 100
    for _, slotID in ipairs(DURABILITY_SLOTS) do
        local current, maximum = GetInventoryItemDurability(slotID)
        if current and maximum and maximum > 0 then
            local pct = math.floor((current / maximum) * 100)
            if pct < lowest then lowest = pct end
        end
    end
    return lowest
end

function GA:CheckDurability()
    if not durabilityEnabled then return end
    local now = GetTime()
    if now - lastDurabilityAlert < DURABILITY_ALERT_COOLDOWN then return end

    local lowest = self:GetDurabilityPct()
    if lowest == 0 then
        lastDurabilityAlert = now
        BoomerMode.UI:ShowToast(
            "Your Gear is Broken!",
            "Visit a repair vendor (anvil icon on minimap).",
            "red"
        )
        BoomerMode.UI:PlayAlert("alert")
    elseif lowest <= 20 then
        lastDurabilityAlert = now
        BoomerMode.UI:ShowToast(
            "Gear Needs Repair",
            "Your gear is getting worn out. Find a repair vendor soon.",
            "orange"
        )
        BoomerMode.UI:PlayAlert("interact")
    end
end

-- ---------------------------------------------------------------------------
-- Average equipped ilvl (canonical source, used by LeaderSync too)
-- ---------------------------------------------------------------------------
local EQUIP_SLOTS_FOR_ILVL = {1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17}
local NUM_ILVL_SLOTS = 16  -- divisor the game uses for average ilvl

function GA:GetAvgIlvl()
    -- Prefer the canonical Blizzard API (matches the character panel exactly).
    if GetAverageItemLevel then
        local _, equipped = GetAverageItemLevel()
        if equipped and equipped > 0 then
            return math.floor(equipped)
        end
    end
    -- Fallback: manual calculation over 16 equippable slots.
    local total = 0
    for _, slotID in ipairs(EQUIP_SLOTS_FOR_ILVL) do
        local link = GetInventoryItemLink("player", slotID)
        if link then
            local ilvl = GetEffectiveIlvl(link)
            if ilvl and ilvl > 0 then
                total = total + ilvl
                -- 2H weapon with no off-hand: count main-hand ilvl for both slots
                if slotID == 16 then
                    local _, _, _, _, _, _, _, _, el = SafeGetItemInfo(link)
                    if el == "INVTYPE_2HWEAPON" and not GetInventoryItemLink("player", 17) then
                        total = total + ilvl
                    end
                end
            end
        end
    end
    return math.floor(total / NUM_ILVL_SLOTS)
end

-- ---------------------------------------------------------------------------
-- Bag upgrade scanner — alerts if there's a better item sitting in bags
-- ---------------------------------------------------------------------------
local lastBagScan = 0
local BAG_SCAN_COOLDOWN = 30

function GA:ScanBagUpgrades()
    if not tooltipsEnabled then return end
    local now = GetTime()
    if now - lastBagScan < BAG_SCAN_COOLDOWN then return end
    lastBagScan = now

    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink then
                local link = info.hyperlink
                local okItem, _, _, _, _, _, _, _, _, equipLoc = pcall(SafeGetItemInfo, link)
                if okItem and equipLoc and equipLoc ~= ""
                   and equipLoc ~= "INVTYPE_NON_EQUIP"
                   and equipLoc ~= "INVTYPE_BAG"
                   and equipLoc ~= "INVTYPE_QUIVER" then
                    local hoverIlvl = GetBagItemIlvl(bag, slot)
                    if hoverIlvl and hoverIlvl > 0 then
                        local doubleSlots = DOUBLE_SLOTS[equipLoc]
                        local slotIDs = doubleSlots or (EQUIP_SLOT[equipLoc] and { EQUIP_SLOT[equipLoc] })
                        if slotIDs then
                            for _, slotID in ipairs(slotIDs) do
                                local eIlvl = GetEquippedIlvl(slotID)
                                if eIlvl and hoverIlvl > eIlvl then
                                    BoomerMode.UI:ShowToast(
                                        "Check Your Bags!",
                                        "You may have a gear upgrade sitting in your bags. Hover over items to compare!",
                                        "gold"
                                    )
                                    BoomerMode.UI:PlayAlert("quest")
                                    return
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Module lifecycle
-- ---------------------------------------------------------------------------
function GA:Initialize()
    tooltipsEnabled   = BoomerModeDB.gear.tooltipsEnabled ~= false
    durabilityEnabled = BoomerModeDB.gear.durabilityEnabled ~= false
    -- Migrate old single-flag setting
    if BoomerModeDB.gear.enabled ~= nil then
        tooltipsEnabled   = BoomerModeDB.gear.enabled ~= false
        durabilityEnabled = BoomerModeDB.gear.enabled ~= false
        BoomerModeDB.gear.tooltipsEnabled   = tooltipsEnabled
        BoomerModeDB.gear.durabilityEnabled = durabilityEnabled
        BoomerModeDB.gear.enabled = nil
    end
    HookTooltips()
end

function GA:OnEvent(event, ...)
    if event == "UPDATE_INVENTORY_DURABILITY" then
        self:CheckDurability()
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED"
           or event == "LOOT_CLOSED" then
        C_Timer.After(1, function() GA:ScanBagUpgrades() end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(3, function()
            GA:CheckDurability()
            GA:ScanBagUpgrades()
        end)
    end
end
