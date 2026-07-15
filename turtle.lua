--[[
    ComputerCraft Auto-Crafting System - Crafting Turtle Actuator
    Runs on: Crafting Turtle (Slave)
    
    This script listens for rednet commands from the Main Computer,
    executes crafting steps, and returns crafted items or dumps contents
    back into the adjacent storage controller.
--]]

-- Configuration
local DROP_DIRECTION = "forward" -- Options: "forward", "up", "down"
local PROTOCOL = "cc_autocraft"

-- Initialize Rednet
local modem = peripheral.find("modem")
if not modem then
    error("No wireless modem found on the turtle! Please attach one.")
end

local modemName = peripheral.getName(modem)
rednet.open(modemName)
print("Turtle Auto-Crafting Slave Started.")
print("Computer ID: " .. os.getComputerID())
print("Drop Direction: " .. DROP_DIRECTION)
print("Listening for messages...")

--- Selects and drops all items from the turtle's 16 slots into the storage controller.
local function dropAll()
    local success = true
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            local ok
            if DROP_DIRECTION == "forward" then
                ok = turtle.drop()
            elseif DROP_DIRECTION == "up" then
                ok = turtle.dropUp()
            elseif DROP_DIRECTION == "down" then
                ok = turtle.dropDown()
            else
                ok = turtle.drop()
            end
            if not ok then
                success = false
            end
        end
    end
    turtle.select(1) -- Reset selected slot
    return success
end

-- Main command loop
while true do
    local senderId, message, protocol = rednet.receive(PROTOCOL)
    
    if protocol == PROTOCOL and type(message) == "table" then
        local cmd = message.cmd
        print("Received command: " .. tostring(cmd) .. " from Computer " .. senderId)
        
        if cmd == "craft" then
            local count = message.count or 1
            print("Crafting quantity: " .. count)
            
            -- Attempt the craft
            local success, err = turtle.craft(count)
            
            if success then
                print("Craft successful! Dropping items...")
                local dropOk = dropAll()
                if dropOk then
                    rednet.send(senderId, { status = "success" }, PROTOCOL)
                else
                    rednet.send(senderId, { status = "error", reason = "Failed to drop crafted items back to storage." }, PROTOCOL)
                end
            else
                print("Craft failed: " .. tostring(err))
                rednet.send(senderId, { status = "error", reason = err or "Unknown recipe issue" }, PROTOCOL)
            end
            
        elseif cmd == "dump" then
            print("Dumping all items back to storage...")
            local dropOk = dropAll()
            if dropOk then
                rednet.send(senderId, { status = "success" }, PROTOCOL)
            else
                rednet.send(senderId, { status = "error", reason = "Failed to clear inventory completely." }, PROTOCOL)
            end
        else
            print("Unknown command: " .. tostring(cmd))
            rednet.send(senderId, { status = "error", reason = "Unknown command" }, PROTOCOL)
        end
    end
end
