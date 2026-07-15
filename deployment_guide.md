# Auto-Crafting System: Installation & Update Guide

This document describes how files are loaded, updated, and removed from your in-game computers and turtles.

---

## Update Propagation (How it Works)

Whether updates apply automatically depends on where you are playing Minecraft:

### Case 1: Local Game (Single-player / Local Host Server)
If you play on a local world, the in-game computer's hard drive maps directly to your local computer's operating system folder: `C:\Users\madse\Documents\antigravity\vibrant-brahmagupta`.
- **Automatic Updates:** Any edits we commit to your local folder appear **instantly** inside Minecraft.
- **How to apply updates:** Press `Ctrl+T` on the in-game computer to terminate the running program, then type `main.lua` to restart it. No download commands are needed.

### Case 2: Remote Game (Multiplayer Servers)
If you play on a remote server, the server stores files in its own isolated filesystem. 
- **Manual Updates:** You must pull changes from your GitHub repository using in-game commands.
- **How to apply updates:** Run the `update.lua` script (see instructions below).

---

## Step-by-Step Installation

### 1. On the Main Advanced Computer
To download the initial scripts and launcher:

```bash
# Download the updater script
wget https://raw.githubusercontent.com/Madsebase/cc-autocraft/main/update.lua update.lua

# Run the updater to fetch all application files
update.lua

# Start the application
main.lua
```

### 2. On the Crafting Turtle
Turtles act as simple actuators and do not require the GUI or solver engine:

```bash
# Download the actuator script
wget https://raw.githubusercontent.com/Madsebase/cc-autocraft/main/turtle.lua turtle.lua

# Start the daemon
turtle.lua
```

---

## Step-by-Step Updating

If we make updates to the recipe database or the main UI code, here is how you update the systems:

### 1. On the Main Computer
Simply run the updater script:
```bash
update.lua
```
*Note: If the updater script itself was modified, delete it first (`rm update.lua`) and re-download it.*

### 2. On the Crafting Turtle
Since the turtle only uses a single file, re-download it directly:
```bash
rm turtle.lua
wget https://raw.githubusercontent.com/Madsebase/cc-autocraft/main/turtle.lua turtle.lua
```

---

## Step-by-Step Removal (Uninstallation)

To completely clean and remove all system files:

### 1. From the Main Computer
Run these commands in the terminal shell:
```bash
rm main.lua
rm crafting_engine.lua
rm recipes.json
rm basalt.lua
rm update.lua
```

### 2. From the Crafting Turtle
Run this command in the terminal shell:
```bash
rm turtle.lua
```
