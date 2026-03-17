-- ===========================================================================
-- LootReminder.lua — Simple toast when loot window opens.
-- ===========================================================================
local LR = {}
BoomerMode.modules = BoomerMode.modules or {}
BoomerMode.modules.LootReminder = LR

local enabled = true

function LR:OnEvent(event, ...)
    if not enabled then return end
    if event == "LOOT_READY" or event == "LOOT_OPENED" then
        BoomerMode.UI:ShowToast("PICK UP YOUR LOOT!", "Grab everything from the loot window.", "gold")
        BoomerMode.UI:PlayAlert("interact")
    end
end

function LR:Toggle()
    enabled = not enabled
    BoomerModeDB.lootReminder = enabled
    BoomerMode:Print("Loot Reminders " .. (enabled and "|cFF00FF00enabled|r." or "|cFFFF3333disabled|r."))
end

function LR:Initialize()
    enabled = BoomerModeDB.lootReminder ~= false
end
