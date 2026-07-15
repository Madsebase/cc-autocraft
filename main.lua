--[[
    ComputerCraft Auto-Crafting System - Main GUI (Frontend)
    Runs on: Main Advanced Computer
    
    Implements a responsive, event-driven Basalt v2 visual interface,
    coordinates the queue manager, and executes background threads.
--]]

-- Self-bootstrapping Basalt v2 installation
if not fs.exists("basalt.lua") then
    print("Basalt UI library not found. Attempting auto-download...")
    if not http then
        error("HTTP API is disabled! Please enable it in computer craft config to auto-download Basalt.")
    end
    local response = http.get("https://raw.githubusercontent.com/Pyroxenium/Basalt2/refs/heads/main/release/basalt-full.lua")
    if not response then
        error("Failed to download Basalt library. Check internet connection.")
    end
    local file = fs.open("basalt.lua", "w")
    file.write(response.readAll())
    file.close()
    response.close()
    print("Basalt v2 downloaded successfully.")
end

-- Import libraries
local basalt = require("basalt")
local engine = require("crafting_engine")

-- Configuration
local PROTOCOL = "cc_autocraft"
local TURTLE_ID = 2 -- Default Turtle rednet ID

-- Discover peripherals
local STORAGE_CONTROLLER = peripheral.find("sophisticatedstorage_controller") or peripheral.find("inventory")
local TURTLE_NAME = nil

for _, name in ipairs(peripheral.getNames()) do
    if name:sub(1, 6) == "turtle" then
        TURTLE_NAME = name
        break
    end
end

-- Setup Rednet
local modem = peripheral.find("modem")
if modem then
    rednet.open(peripheral.getName(modem))
end

-- Helper to resolve shard key
local function getShardKey(itemId)
    local parts = {}
    for part in string.gmatch(itemId, "[^:]+") do
        table.insert(parts, part)
    end
    local path = parts[#parts] or itemId
    local key = ""
    if string.len(path) >= 2 then
        key = string.lower(string.sub(path, 1, 2))
    else
        key = string.lower(path)
    end
    local cleanKey = ""
    for i = 1, string.len(key) do
        local c = string.sub(key, i, i)
        if string.match(c, "[a-z0-9]") then
            cleanKey = cleanKey .. c
        else
            cleanKey = cleanKey .. "_"
        end
    end
    if cleanKey == "" then
        cleanKey = "other"
    end
    return cleanKey
end

-- On-demand recipe loader
local function getRecipe(itemId)
    local key = getShardKey(itemId)
    local path = "recipes/" .. key .. ".json"
    
    if not fs.exists(path) then
        if not fs.exists("recipes") then
            fs.makeDir("recipes")
        end
        local url = "https://raw.githubusercontent.com/Madsebase/cc-autocraft/main/recipes/" .. key .. ".json"
        local response = http.get(url)
        if response then
            local file = fs.open(path, "w")
            file.write(response.readAll())
            file.close()
            response.close()
        else
            return nil
        end
    end
    
    local file = fs.open(path, "r")
    local content = file.readAll()
    file.close()
    
    local data = textutils.unserializeJSON(content)
    if data and data[itemId] then
        return data[itemId]
    end
    return nil
end

-- Metatable-backed recipes table
local recipes = setmetatable({}, {
    __index = function(t, itemId)
        local r = getRecipe(itemId)
        rawset(t, itemId, r or false)
        return r
    end
})

-- Common default items
local commonItems = {
    "minecraft:stick",
    "minecraft:iron_ingot",
    "minecraft:gold_ingot",
    "minecraft:diamond",
    "minecraft:chest",
    "minecraft:crafting_table",
    "minecraft:furnace",
    "minecraft:cobblestone",
    "minecraft:oak_planks"
}

-- Search index cache
local loadedIndexLetter = nil
local loadedIndexItems = {}

local function loadSearchIndex(letter)
    if loadedIndexLetter == letter then
        return loadedIndexItems
    end
    
    local path = "recipes/index_" .. letter .. ".json"
    if not fs.exists(path) then
        if not fs.exists("recipes") then
            fs.makeDir("recipes")
        end
        local url = "https://raw.githubusercontent.com/Madsebase/cc-autocraft/main/recipes/index_" .. letter .. ".json"
        local response = http.get(url)
        if response then
            local file = fs.open(path, "w")
            file.write(response.readAll())
            file.close()
            response.close()
        else
            return {}
        end
    end
    
    local file = fs.open(path, "r")
    local content = file.readAll()
    file.close()
    
    loadedIndexLetter = letter
    loadedIndexItems = textutils.unserializeJSON(content) or {}
    return loadedIndexItems
end

-- State variables
local selectedItem = nil
local canCraft = false
local currentBreakdown = nil
local currentSteps = nil
local currentCache = nil

local jobQueue = {}
local activeJob = nil
local isCancelled = false

-- Defensive Helper to read list values across different Basalt v2 releases
local function getSelectedListValue(listObj)
    local item = listObj:getSelectedItem()
    if type(item) == "table" then
        return item.text
    end
    return item
end

-- Main Basalt Frame Setup
local main = basalt.getMainFrame()
    :setBackground(colors.black)

-- Left Panel: Catalog (JEI Style)
local catalogPanel = main:addFrame()
    :setPosition(1, 1)
    :setSize(20, 19)
    :setBackground(colors.gray)

catalogPanel:addLabel()
    :setPosition(2, 1)
    :setText("SEARCH RECIPES")
    :setForeground(colors.yellow)

local searchInput = catalogPanel:addInput()
    :setPosition(2, 2)
    :setSize(17, 1)
    :setBackground(colors.black)
    :setForeground(colors.white)

local catalogList = catalogPanel:addList()
    :setPosition(2, 4)
    :setSize(17, 14)
    :setBackground(colors.black)
    :setForeground(colors.white)

-- Vertical Divider Line
main:addFrame()
    :setPosition(21, 1)
    :setSize(1, 19)
    :setBackground(colors.blue)

-- Tabs on the Right Panel
local btnCraftTab = main:addButton()
    :setPosition(22, 1)
    :setSize(14, 1)
    :setText("Crafting")
    :setBackground(colors.blue)
    :setForeground(colors.white)

local btnStatusTab = main:addButton()
    :setPosition(37, 1)
    :setSize(14, 1)
    :setText("Status (Idle)")
    :setBackground(colors.gray)
    :setForeground(colors.lightGray)

-- Sub-panes (positioned at y=2 to y=19)
local welcomePane = main:addFrame()
    :setPosition(22, 2)
    :setSize(30, 18)
    :setBackground(colors.black)

local configPane = main:addFrame()
    :setPosition(22, 2)
    :setSize(30, 18)
    :setBackground(colors.black)
    :setVisible(false)

local activePane = main:addFrame()
    :setPosition(22, 2)
    :setSize(30, 18)
    :setBackground(colors.black)
    :setVisible(false)

-- Helper to switch between panes
local function showPane(paneToShow)
    configPane:setVisible(false)
    activePane:setVisible(false)
    welcomePane:setVisible(false)
    paneToShow:setVisible(true)
end

local function setActiveTabUI(activeTab)
    if activeTab == "craft" then
        btnCraftTab:setBackground(colors.blue):setForeground(colors.white)
        btnStatusTab:setBackground(colors.gray):setForeground(colors.lightGray)
    else
        btnCraftTab:setBackground(colors.gray):setForeground(colors.lightGray)
        btnStatusTab:setBackground(colors.blue):setForeground(colors.white)
    end
end

-- Populate Welcome Pane (Error checks / general info)
local titleLabel = welcomePane:addLabel()
    :setPosition(3, 2)
    :setText("Auto-Crafting Terminal")
    :setForeground(colors.yellow)
    :setSize(24, 1)

local statusMessageLabel = welcomePane:addLabel()
    :setPosition(2, 5)
    :setSize(26, 6)

if not STORAGE_CONTROLLER then
    statusMessageLabel:setText("ERROR: Sophisticated Storage Controller not detected!\n\nPlease check your network cables.")
        :setForeground(colors.red)
elseif not TURTLE_NAME then
    statusMessageLabel:setText("ERROR: Crafting Turtle not detected on wired network!\n\nVerify turtle modem is on.")
        :setForeground(colors.red)
else
    statusMessageLabel:setText("Systems: Operational.\n\nSelect a recipe from the left catalog panel to configure crafting.")
        :setForeground(colors.green)
end

-- Populate Config Pane
local selectedItemLabel = configPane:addLabel()
    :setPosition(2, 1)
    :setText("Select an item")
    :setForeground(colors.yellow)
    :setSize(26, 1)

configPane:addLabel()
    :setPosition(2, 3)
    :setText("Qty:")
    :setForeground(colors.white)

local qtyInput = configPane:addInput()
    :setPosition(7, 3)
    :setSize(6, 1)
    :setPattern("%d")
    :setText("1")
    :setBackground(colors.gray)
    :setForeground(colors.white)

local btnDec = configPane:addButton()
    :setPosition(14, 3)
    :setSize(3, 1)
    :setText("-")
    :setBackground(colors.blue)
    :setForeground(colors.white)

local btnInc = configPane:addButton()
    :setPosition(18, 3)
    :setSize(3, 1)
    :setText("+")
    :setBackground(colors.blue)
    :setForeground(colors.white)

configPane:addLabel()
    :setPosition(2, 5)
    :setText("Requirements:")
    :setForeground(colors.yellow)

local reqList = configPane:addList()
    :setPosition(2, 6)
    :setSize(26, 8)
    :setBackground(colors.gray)
    :setForeground(colors.white)

local queueButton = configPane:addButton()
    :setPosition(2, 15)
    :setSize(26, 2)
    :setText("Queue Craft")
    :setBackground(colors.gray)
    :setForeground(colors.lightGray)

-- Populate Active Pane
activePane:addLabel()
    :setPosition(2, 1)
    :setText("Currently Assembling:")
    :setForeground(colors.yellow)

local activeItemLabel = activePane:addLabel()
    :setPosition(2, 2)
    :setText("No Active Job")
    :setForeground(colors.cyan)
    :setSize(26, 1)

local progressBar = activePane:addProgressBar()
    :setPosition(2, 4)
    :setSize(26, 1)
    :setBackground(colors.gray)
    :setForeground(colors.blue)
    :setProgress(0)

local progressPctLabel = activePane:addLabel()
    :setPosition(2, 5)
    :setText("0%")
    :setForeground(colors.white)
    :setSize(26, 1)

local statusLabel = activePane:addLabel()
    :setPosition(2, 7)
    :setText("Status: Idle")
    :setForeground(colors.lightGray)
    :setSize(26, 2)

activePane:addLabel()
    :setPosition(2, 10)
    :setText("Queue List:")
    :setForeground(colors.yellow)

local activeQueueList = activePane:addList()
    :setPosition(2, 11)
    :setSize(26, 3)
    :setBackground(colors.gray)
    :setForeground(colors.white)

local btnStop = activePane:addButton()
    :setPosition(2, 15)
    :setSize(26, 2)
    :setText("EMERGENCY STOP")
    :setBackground(colors.red)
    :setForeground(colors.white)

-- Live Requirements Solver Update
local function updateRequirements(qty)
    reqList:clear()
    if not selectedItem then return end
    
    if not STORAGE_CONTROLLER then return end
    currentCache = engine.cacheInventory(STORAGE_CONTROLLER)
    
    local ok, steps, breakdown = pcall(engine.solveDependencies, recipes, currentCache, selectedItem, qty)
    if not ok then
        reqList:addItem("Error: Circular dependencies!")
        queueButton:disable()
        queueButton:setBackground(colors.gray)
        canCraft = false
        return
    end
    
    currentSteps = steps
    currentBreakdown = breakdown
    canCraft = true
    
    for itemID, info in pairs(breakdown) do
        local displayName = itemID:match(":(.+)$") or itemID
        local line = string.format("%s: %d/%d", displayName, info.available, info.needed)
        
        if info.missing > 0 then
            line = "[!!] " .. line .. " (-" .. info.missing .. ")"
            reqList:addItem(line, colors.black, colors.red)
            canCraft = false
        else
            line = "[OK] " .. line
            reqList:addItem(line, colors.black, colors.green)
        end
    end
    
    if canCraft then
        queueButton:enable()
        queueButton:setBackground(colors.green)
        queueButton:setForeground(colors.white)
    else
        queueButton:disable()
        queueButton:setBackground(colors.gray)
        queueButton:setForeground(colors.lightGray)
    end
end

-- Refresh UI Tab badges
local function updateTabsUI()
    local text = "Status"
    if activeJob then
        text = "Status (*)"
    elseif #jobQueue > 0 then
        text = "Status (" .. #jobQueue .. ")"
    end
    btnStatusTab:setText(text)
end

-- Refresh Active Queue List
local function updateQueueListUI()
    activeQueueList:clear()
    for idx, job in ipairs(jobQueue) do
        local displayName = job.item:match(":(.+)$") or job.item
        activeQueueList:addItem(idx .. ". " .. job.count .. "x " .. displayName)
    end
end

-- Filter Catalog based on Search Bar Query
local function filterCatalog(query)
    catalogList:clear()
    query = (query or ""):lower()
    
    if string.len(query) < 2 then
        -- Show common starter items
        for _, itemID in ipairs(commonItems) do
            local displayName = itemID:match(":(.+)$") or itemID
            if query == "" or displayName:lower():find(query, 1, true) or itemID:lower():find(query, 1, true) then
                catalogList:addItem(itemID)
            end
        end
        return
    end
    
    -- Load index for the first letter of the query
    local firstChar = string.sub(query, 1, 1)
    if not string.match(firstChar, "[a-z]") then
        firstChar = "other"
    end
    
    local items = loadSearchIndex(firstChar)
    for _, itemID in ipairs(items) do
        local displayName = itemID:match(":(.+)$") or itemID
        if displayName:lower():find(query, 1, true) or itemID:lower():find(query, 1, true) then
            catalogList:addItem(itemID)
        end
    end
end

-- Tab Click Handlers
btnCraftTab:onClick(function()
    setActiveTabUI("craft")
    if selectedItem then
        showPane(configPane)
    else
        showPane(welcomePane)
    end
end)

btnStatusTab:onClick(function()
    setActiveTabUI("status")
    showPane(activePane)
end)

-- Search input change handler
searchInput:onChange(function(self)
    filterCatalog(self:getText())
end)

-- Catalog list selection handler
catalogList:onChange(function(self)
    local item = getSelectedListValue(self)
    if item then
        selectedItem = item
        selectedItemLabel:setText(item:match(":(.+)$") or item)
        qtyInput:setText("1")
        setActiveTabUI("craft")
        showPane(configPane)
        updateRequirements(1)
    end
end)

-- Quantity Change Handlers
qtyInput:onChange(function(self)
    local val = tonumber(self:getText()) or 1
    if val < 1 then
        val = 1
        self:setText("1")
    end
    updateRequirements(val)
end)

btnDec:onClick(function()
    local val = tonumber(qtyInput:getText()) or 1
    if val > 1 then
        qtyInput:setText(tostring(val - 1))
        updateRequirements(val - 1)
    end
end)

btnInc:onClick(function()
    local val = tonumber(qtyInput:getText()) or 1
    qtyInput:setText(tostring(val + 1))
    updateRequirements(val + 1)
end)

-- Queue Button Click Handler
queueButton:onClick(function()
    if not selectedItem or not canCraft then return end
    
    local qty = tonumber(qtyInput:getText()) or 1
    
    table.insert(jobQueue, {
        item = selectedItem,
        count = qty,
        steps = currentSteps,
        cache = currentCache
    })
    
    updateTabsUI()
    updateQueueListUI()
    
    -- Immediately navigate to status to let user track execution
    setActiveTabUI("status")
    showPane(activePane)
    
    -- Clear configuration selection
    selectedItem = nil
    qtyInput:setText("1")
end)

-- Stop Button Click Handler
btnStop:onClick(function()
    isCancelled = true
    jobQueue = {}
    activeJob = nil
    
    -- Send urgent Dump command to turtle to push items back to inventory
    rednet.send(TURTLE_ID, { cmd = "dump" }, PROTOCOL)
    
    statusLabel:setText("Status: EMERGENCY STOP PRESSED! DUMP SENT.")
    progressBar:setProgress(0)
    progressPctLabel:setText("Cancelled")
    
    updateTabsUI()
    updateQueueListUI()
    
    os.sleep(1.5)
    
    activeItemLabel:setText("No Active Job")
    statusLabel:setText("Status: Idle")
    
    setActiveTabUI("craft")
    showPane(welcomePane)
end)

-- Background Queue Processor Thread
local function runQueueProcessor()
    basalt.schedule(function()
        while true do
            if not activeJob and #jobQueue > 0 then
                activeJob = table.remove(jobQueue, 1)
                isCancelled = false
                updateTabsUI()
                updateQueueListUI()
                
                local nameStr = activeJob.item:match(":(.+)$") or activeJob.item
                activeItemLabel:setText(activeJob.count .. "x " .. nameStr)
                
                local ok, err = pcall(function()
                    engine.executeCraft(
                        STORAGE_CONTROLLER,
                        TURTLE_NAME,
                        TURTLE_ID,
                        activeJob.steps,
                        activeJob.cache,
                        function(completed, total, statusText)
                            local pct = math.floor((completed / total) * 100)
                            progressBar:setProgress(pct)
                            progressPctLabel:setText(pct .. "% (" .. completed .. "/" .. total .. " steps)")
                            statusLabel:setText("Status: " .. statusText)
                        end,
                        function() return isCancelled end
                    )
                end)
                
                if ok then
                    statusLabel:setText("Status: Crafting Job Complete!")
                    progressBar:setProgress(100)
                    progressPctLabel:setText("100% Complete")
                else
                    if isCancelled then
                        statusLabel:setText("Status: Aborted & Cleaned Up.")
                    else
                        statusLabel:setText("Status: Error: " .. tostring(err))
                    end
                    progressBar:setProgress(0)
                end
                
                os.sleep(2.0) -- Display finished/error status briefly
                
                activeJob = nil
                updateTabsUI()
                updateQueueListUI()
                
                if #jobQueue == 0 then
                    activeItemLabel:setText("No Active Job")
                    progressBar:setProgress(0)
                    progressPctLabel:setText("0%")
                    statusLabel:setText("Status: Idle")
                end
            end
            os.sleep(0.5)
        end
    end)
end

-- Initialize catalog list on startup
filterCatalog("")

-- Start background processor and run Basalt event loop
runQueueProcessor()
basalt.run()
