--[[
    ComputerCraft Auto-Crafting System - Auto-Updater
    Runs on: Main Advanced Computer
    
    Downloads the latest main.lua, crafting_engine.lua, and recipes.json
    directly from the GitHub repository.
--]]

local files = {
    ["recipes.json"] = "https://raw.githubusercontent.com/Madsebase/cc-autocraft/main/recipes.json",
    ["crafting_engine.lua"] = "https://raw.githubusercontent.com/Madsebase/cc-autocraft/main/crafting_engine.lua",
    ["main.lua"] = "https://raw.githubusercontent.com/Madsebase/cc-autocraft/main/main.lua"
}

print("Starting Auto-Crafting System Updater...")
print("Fetching latest files from GitHub...")

for fileName, url in pairs(files) do
    write("Downloading " .. fileName .. "... ")
    local cbUrl = url .. "?cb=" .. (os.epoch and os.epoch("utc") or math.random(1, 100000))
    local response = http.get(cbUrl)
    if response then
        local file = fs.open(fileName, "w")
        file.write(response.readAll())
        file.close()
        response.close()
        print("[OK]")
    else
        print("[FAILED]")
    end
end

print("\nUpdate process complete! Run main.lua to start.")
