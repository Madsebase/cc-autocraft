--[[
    ComputerCraft Auto-Crafting System - Crafting Engine (Backend)
    Runs on: Main Computer
    
    Handles recipe database loading, inventory caching, dependency solving,
    slot mapping, and push-delivery orchestration.
--]]

local PROTOCOL = "cc_autocraft"

local M = {}

-- Slot mapping: 3x3 recipe (1-9) -> 4x4 Turtle inventory (1-16)
local slotMap = {
    [1] = 1, [2] = 2, [3] = 3,
    [4] = 5, [5] = 6, [6] = 7,
    [7] = 9, [8] = 10, [9] = 11
}

--- Loads the recipe database from recipes.json
-- @return table The recipe database
function M.loadRecipes()
    if not fs.exists("recipes.json") then
        return {}
    end
    local file = fs.open("recipes.json", "r")
    local content = file.readAll()
    file.close()
    return textutils.unserializeJSON(content) or {}
end

--- Caches the inventory of the Sophisticated Storage Controller
-- @param storage table The wrapped storage peripheral
-- @return table The inventory cache with slot details
function M.cacheInventory(storage)
    local cache = {
        emptySlots = {}
    }
    
    local size = storage.size()
    local list = storage.list()
    
    for slot = 1, size do
        local item = list[slot]
        if item then
            local name = item.name
            if not cache[name] then
                cache[name] = {
                    total = 0,
                    slots = {}
                }
            end
            cache[name].total = cache[name].total + item.count
            table.insert(cache[name].slots, {
                slot = slot,
                count = item.count
            })
        else
            table.insert(cache.emptySlots, slot)
        end
    end
    
    return cache
end

--- Solves the recursive dependency tree for a target item and quantity.
-- @param recipes table Loaded recipe database
-- @param cache table Inventory cache
-- @param targetItem string Item ID to craft
-- @param targetCount number Quantity to craft
-- @return table steps list of crafting steps (post-order)
-- @return table breakdown material breakdown list
function M.solveDependencies(recipes, cache, targetItem, targetCount)
    local virtualInventory = {}
    for itemID, info in pairs(cache) do
        if itemID ~= "emptySlots" then
            virtualInventory[itemID] = info.total
        end
    end
    
    local materialBreakdown = {}
    local craftingSteps = {}
    local visiting = {}
    
    local function addBreakdown(itemID, amountNeeded)
        if not materialBreakdown[itemID] then
            materialBreakdown[itemID] = {
                name = itemID,
                needed = 0,
                available = (cache[itemID] and cache[itemID].total) or 0,
                missing = 0
            }
        end
        materialBreakdown[itemID].needed = materialBreakdown[itemID].needed + amountNeeded
    end
    
    local function solveInternal(itemID, needed)
        -- Insert yield to prevent "Too long without yielding" in large recipes
        os.sleep(0)
        
        addBreakdown(itemID, needed)
        
        local available = virtualInventory[itemID] or 0
        local fromStorage = math.min(available, needed)
        virtualInventory[itemID] = available - fromStorage
        local remaining = needed - fromStorage
        
        if remaining <= 0 then
            return
        end
        
        local recipe = recipes[itemID]
        if recipe then
            if visiting[itemID] then
                error("Circular dependency detected for item: " .. itemID)
            end
            visiting[itemID] = true
            
            local yieldPerCraft = recipe.count or 1
            local craftsNeeded = math.ceil(remaining / yieldPerCraft)
            local totalCrafted = craftsNeeded * yieldPerCraft
            local excess = totalCrafted - remaining
            
            -- Add excess back to virtual inventory
            virtualInventory[itemID] = (virtualInventory[itemID] or 0) + excess
            
            -- Count ingredient occurrence
            local ingredientCounts = {}
            for i = 1, 9 do
                local ingID = recipe.ingredients[i]
                if ingID and ingID ~= "" then
                    ingredientCounts[ingID] = (ingredientCounts[ingID] or 0) + 1
                end
            end
            
            -- Solve for ingredients
            for ingID, countInRecipe in pairs(ingredientCounts) do
                local totalIngNeeded = craftsNeeded * countInRecipe
                solveInternal(ingID, totalIngNeeded)
            end
            
            visiting[itemID] = nil
            
            -- Add step (post-order traversal, so sub-components are built first)
            table.insert(craftingSteps, {
                item = itemID,
                count = totalCrafted,
                crafts = craftsNeeded,
                recipe = recipe
            })
        else
            -- Raw ingredient, cannot craft and missing from storage
            materialBreakdown[itemID].missing = materialBreakdown[itemID].missing + remaining
        end
    end
    
    solveInternal(targetItem, targetCount)
    
    return craftingSteps, materialBreakdown
end

--- Pushes items from storage cache slots to the turtle
local function pushItemFromStorage(storage, cache, turtleName, itemID, amountNeeded, turtleSlot)
    local itemInfo = cache[itemID]
    if not itemInfo then return 0 end
    
    local remainingToPush = amountNeeded
    local pushedTotal = 0
    
    local slotIdx = 1
    while remainingToPush > 0 and slotIdx <= #itemInfo.slots do
        local slotInfo = itemInfo.slots[slotIdx]
        if slotInfo.count > 0 then
            local pushCount = math.min(remainingToPush, slotInfo.count)
            
            -- Pushes items to the Turtle on the wired network
            local ok, actualPushed = pcall(storage.pushItems, turtleName, slotInfo.slot, pushCount, turtleSlot)
            
            if ok and actualPushed and actualPushed > 0 then
                slotInfo.count = slotInfo.count - actualPushed
                itemInfo.total = itemInfo.total - actualPushed
                remainingToPush = remainingToPush - actualPushed
                pushedTotal = pushedTotal + actualPushed
            else
                slotIdx = slotIdx + 1
            end
        else
            slotIdx = slotIdx + 1
        end
    end
    
    -- Clean up exhausted slots in cache
    local newSlots = {}
    for _, s in ipairs(itemInfo.slots) do
        if s.count > 0 then
            table.insert(newSlots, s)
        end
    end
    itemInfo.slots = newSlots
    
    return pushedTotal
end

--- Tracks newly crafted items in the virtual cache memory
local function addCraftedToCache(cache, itemID, count)
    if not cache[itemID] then
        cache[itemID] = { total = 0, slots = {} }
    end
    
    local remaining = count
    cache[itemID].total = cache[itemID].total + count
    
    -- 1. Stack into existing cached slots if possible
    for _, slotInfo in ipairs(cache[itemID].slots) do
        if slotInfo.count < 64 then
            local space = 64 - slotInfo.count
            local toAdd = math.min(space, remaining)
            slotInfo.count = slotInfo.count + toAdd
            remaining = remaining - toAdd
            if remaining <= 0 then break end
        end
    end
    
    -- 2. Allocate to empty storage slots
    while remaining > 0 do
        if #cache.emptySlots > 0 then
            local newSlot = table.remove(cache.emptySlots)
            local toAdd = math.min(64, remaining)
            table.insert(cache[itemID].slots, { slot = newSlot, count = toAdd })
            remaining = remaining - toAdd
        else
            -- Fallback slot if storage is fully packed
            local virtualSlot = 9999 + remaining
            table.insert(cache[itemID].slots, { slot = virtualSlot, count = remaining })
            remaining = 0
        end
    end
end

--- Executes the crafting steps sequentially
-- @param storage table Wrapped storage controller peripheral
-- @param turtleName string Network peripheral name of the turtle (e.g. "turtle_0")
-- @param turtleId number Rednet computer ID of the turtle
-- @param steps table Array of crafting steps
-- @param cache table The inventory cache
-- @param updateProgress function Callback(completedSteps, totalSteps, statusText)
-- @param isCancelled function Returns true if user clicked cancel
function M.executeCraft(storage, turtleName, turtleId, steps, cache, updateProgress, isCancelled)
    local totalSteps = #steps
    for stepIdx, step in ipairs(steps) do
        if isCancelled() then
            error("Crafting job cancelled by user.")
        end
        
        local item = step.item
        local craftsRemaining = step.crafts
        local recipe = step.recipe
        
        updateProgress(stepIdx - 1, totalSteps, "Preparing to craft: " .. item)
        
        while craftsRemaining > 0 do
            if isCancelled() then
                error("Crafting job cancelled by user.")
            end
            
            local batchCrafts = math.min(craftsRemaining, 64)
            
            -- Push ingredients
            for i = 1, 9 do
                local ingredient = recipe.ingredients[i]
                if ingredient and ingredient ~= "" then
                    local targetTurtleSlot = slotMap[i]
                    local amountToPush = batchCrafts -- assuming 1 per grid slot
                    
                    local pushed = pushItemFromStorage(storage, cache, turtleName, ingredient, amountToPush, targetTurtleSlot)
                    if pushed < amountToPush then
                        error("Safety Abort: Missing " .. ingredient .. " in storage (expected " .. amountToPush .. ", pushed " .. pushed .. ").")
                    end
                end
                os.sleep(0.05) -- prevent server lag on rapid transfers
            end
            
            -- Trigger Craft on Turtle
            updateProgress(stepIdx - 1, totalSteps, "Turtle assembling batch of " .. batchCrafts .. " " .. item)
            rednet.send(turtleId, { cmd = "craft", count = batchCrafts }, PROTOCOL)
            
            -- Wait for response
            local senderId, response, protocol = rednet.receive(PROTOCOL, 30)
            if not response then
                error("Connection Timeout: Turtle did not respond.")
            end
            if response.status ~= "success" then
                error("Turtle Error: " .. (response.reason or "unknown assembly error"))
            end
            
            -- Update virtual inventory cache
            addCraftedToCache(cache, item, batchCrafts * (recipe.count or 1))
            
            craftsRemaining = craftsRemaining - batchCrafts
            os.sleep(0.05)
        end
    end
    
    updateProgress(totalSteps, totalSteps, "Crafting Job Completed Successfully!")
end

return M
