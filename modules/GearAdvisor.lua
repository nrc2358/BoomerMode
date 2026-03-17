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

local enabled = true

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
-- Safe wrapper for GetItemInfo (global in some builds, C_Item in others).
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
-- GetDetailedItemLevelInfo is available since Legion and should persist into
-- Midnight — mark for version verification.
-- ---------------------------------------------------------------------------
local function GetEffectiveIlvl(link)
    if not link then return nil end
    if GetDetailedItemLevelInfo then
        local ilvl = select(1, GetDetailedItemLevelInfo(link))
        if ilvl and ilvl > 0 then return ilvl end
    end
    -- Fallback: read base ilvl.
    local ok, _, _, _, baseIlvl = pcall(SafeGetItemInfo, link)
    if ok and baseIlvl and baseIlvl > 0 then return baseIlvl end
    return nil
end

-- ---------------------------------------------------------------------------
-- Core comparison logic
-- ---------------------------------------------------------------------------
local function AppendComparison(tooltip, link)
    if not enabled then return end
    if not link then return end

    -- Get the equipLocation and ilvl of the hover item.
    local _, _, _, _, _, _, _, _, equipLoc = SafeGetItemInfo(link)
    if not equipLoc or equipLoc == "" or equipLoc == "INVTYPE_NON_EQUIP" then return end
    if equipLoc == "INVTYPE_BAG" or equipLoc == "INVTYPE_QUIVER" then return end

    local hoverIlvl = GetEffectiveIlvl(link)
    if not hoverIlvl then return end

    -- Find the best equipped item level in the relevant slot(s).
    local doubleSlots = DOUBLE_SLOTS[equipLoc]
    local slotIDs
    if doubleSlots then
        slotIDs = doubleSlots
    else
        local s = EQUIP_SLOT[equipLoc]
        if not s then return end
        slotIDs = { s }
    end

    -- For double-slot items (rings/trinkets) compare against the worst
    -- equipped piece, since that's the one you'd actually replace.
    local isDouble = (doubleSlots ~= nil)
    local compareIlvl = isDouble and math.huge or 0
    for _, slotID in ipairs(slotIDs) do
        local equippedLink = GetInventoryItemLink("player", slotID)
        if equippedLink then
            local eIlvl = GetEffectiveIlvl(equippedLink)
            if eIlvl then
                if isDouble then
                    if eIlvl < compareIlvl then compareIlvl = eIlvl end
                else
                    if eIlvl > compareIlvl then compareIlvl = eIlvl end
                end
            end
        end
    end
    if isDouble and compareIlvl == math.huge then compareIlvl = 0 end

    -- Nothing equipped in this slot — treat as 0 (any item is an upgrade).
    local diff = hoverIlvl - compareIlvl

    local line
    if diff > 0 then
        line = "|cFF00CC00  Upgrade  +" .. diff .. " ilvl|r"
    elseif diff < 0 then
        line = "|cFFFF3333  Downgrade  " .. diff .. " ilvl|r"
    else
        -- Same ilvl but not necessarily the same item.
        if compareIlvl == 0 then
            line = "|cFF00CC00  New Slot  — equip this!|r"
        else
            line = "|cFF949494  Same Item Level  (" .. hoverIlvl .. ")|r"
        end
    end

    tooltip:AddLine(line)
    tooltip:Show()   -- refresh tooltip height
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
                local _, link = tooltip:GetItem()
                AppendComparison(tooltip, link)
            end
        end)
    else
        local function HookOne(tt)
            if tt and tt.HookScript then
                tt:HookScript("OnTooltipSetItem", function(self)
                    local _, link = self:GetItem()
                    AppendComparison(self, link)
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
function GA:Toggle()
    enabled = not enabled
    BoomerModeDB.gear.enabled = enabled
    BoomerMode:Print("Gear Advisor " .. (enabled and "|cFF00FF00enabled|r." or "|cFFFF3333disabled|r."))
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
    if not enabled then return end
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
    if not enabled then return end
    local now = GetTime()
    if now - lastBagScan < BAG_SCAN_COOLDOWN then return end
    lastBagScan = now

    local bestUpgrade = nil
    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink then
                local link = info.hyperlink
                local _, _, _, _, _, _, _, _, equipLoc = SafeGetItemInfo(link)
                if equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP"
                   and equipLoc ~= "INVTYPE_BAG" and equipLoc ~= "INVTYPE_QUIVER" then
                    local hoverIlvl = GetEffectiveIlvl(link)
                    if hoverIlvl then
                        local doubleSlots = DOUBLE_SLOTS[equipLoc]
                        local slotIDs = doubleSlots or (EQUIP_SLOT[equipLoc] and {EQUIP_SLOT[equipLoc]})
                        if slotIDs then
                            local isDouble = (#slotIDs > 1)
                            local compareIlvl = isDouble and math.huge or 0
                            for _, slotID in ipairs(slotIDs) do
                                local equippedLink = GetInventoryItemLink("player", slotID)
                                if equippedLink then
                                    local eIlvl = GetEffectiveIlvl(equippedLink)
                                    if eIlvl then
                                        if isDouble then
                                            if eIlvl < compareIlvl then compareIlvl = eIlvl end
                                        else
                                            if eIlvl > compareIlvl then compareIlvl = eIlvl end
                                        end
                                    end
                                end
                            end
                            if isDouble and compareIlvl == math.huge then compareIlvl = 0 end
                            local diff = hoverIlvl - compareIlvl
                            if diff > 0 and (not bestUpgrade or diff > bestUpgrade.diff) then
                                bestUpgrade = { name = info.itemName or "an item", diff = diff }
                            end
                        end
                    end
                end
            end
        end
    end

    if bestUpgrade then
        BoomerMode.UI:ShowToast(
            "You Have a Gear Upgrade!",
            bestUpgrade.name .. " is +" .. bestUpgrade.diff .. " ilvl better than what you're wearing.",
            "gold"
        )
        BoomerMode.UI:PlayAlert("quest")
    end
end

-- ---------------------------------------------------------------------------
-- Module lifecycle
-- ---------------------------------------------------------------------------
function GA:Initialize()
    enabled = BoomerModeDB.gear.enabled ~= false
    HookTooltips()
end

function GA:OnEvent(event, ...)
    if not enabled then return end
    if event == "UPDATE_INVENTORY_DURABILITY" then
        self:CheckDurability()
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_EQUIPMENT_CHANGED" then
        C_Timer.After(1, function() GA:ScanBagUpgrades() end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(3, function()
            GA:CheckDurability()
            GA:ScanBagUpgrades()
        end)
    end
end
