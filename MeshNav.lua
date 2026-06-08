-- MeshNav.lua
-- Distributed Relative Positioning System (Mesh-Nav)
-- Designed for WoW Classic (TBC 2.5.5 / Vanilla 1.15.8)

local addonName, addonTable = ...
local frame = CreateFrame("Frame", "MeshNavEventFrame", UIParent)

-- Default SavedVariables
MeshNavDB = MeshNavDB or {}

-- Database Versioning Tracker (Concept matching ItemRack's EventsVersion)
local DB_VERSION = 10100 -- Matches 1.0.0 (Format: Major * 10000 + Minor * 100 + Patch)

-- Local State
local localPlayerName = UnitName("player")
local roster = {} -- Sorted list of names
local distances = {} -- Matrix: distances[nameA][nameB] = bucket
local positions = {} -- Solved positions: positions[name] = {x, y}
local lastSyncTime = 0
local ttsTimer = 0

-- Mob Tracking State
local localMobs = {} -- localMobs[shortGUID] = { bucket, hostility, name }
local mobDistances = {} -- mobDistances[shortGUID][senderName] = { bucket, hostility, time }
local mobPositions = {} -- mobPositions[shortGUID] = { x, y, hostility }
local mobNames = {} -- mobNames[shortGUID] = name

-- UI Scale Constants
local RADAR_SIZE = 200
local MAX_RADAR_RANGE = 40
local SCALE = (RADAR_SIZE / 2) / MAX_RADAR_RANGE -- 2.5 pixels per yard

-- Setup event listeners
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_ADDON")

-- Helper: Safe Item Range Check
local function IsItemInRangeWrapper(itemID, unit)
    if C_Item and C_Item.IsItemInRange then
        return C_Item.IsItemInRange(itemID, unit)
    elseif IsItemInRange then
        return IsItemInRange(itemID, unit)
    end
    return nil
end

-- Helper: Convert bucket to estimated yards
local function BucketToYards(bucket)
    if bucket == 1 then return 5 end   -- 0-10 yds (midpoint 5)
    if bucket == 2 then return 19 end  -- 10-28 yds (midpoint 19)
    if bucket == 3 then return 29 end  -- 28-30 yds (midpoint 29)
    if bucket == 4 then return 35 end  -- 30-40 yds (midpoint 35)
    return 48                          -- 40+ yds
end

-- Helper: Generate a short 4-character hex hash of unit GUID for network minification
local function GetShortGUID(guid)
    if not guid then return nil end
    local hash = 0
    for i = 1, #guid do
        hash = (hash * 33 + string.byte(guid, i)) % 65536
    end
    return string.format("%04x", hash)
end

-- Rebuild the alphabetically sorted roster of active party/raid members
local function RebuildRoster()
    local tempRoster = {}
    
    -- Insert player
    table.insert(tempRoster, localPlayerName)
    
    -- Insert other group members
    if IsInRaid() then
        for i = 1, 40 do
            local unit = "raid" .. i
            if UnitExists(unit) and not UnitIsUnit(unit, "player") then
                local name = UnitName(unit)
                if name then table.insert(tempRoster, name) end
            end
        end
    else
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local name = UnitName(unit)
                if name then table.insert(tempRoster, name) end
            end
        end
    end
    
    -- Sort alphabetically to ensure matching indices across all clients
    table.sort(tempRoster)
    
    roster = tempRoster
    
    -- Cleanup distances and positions for players who left
    local activeMap = {}
    for _, name in ipairs(roster) do
        activeMap[name] = true
    end
    
    for name in pairs(positions) do
        if not activeMap[name] then
            positions[name] = nil
        end
    end
    
    for nameA in pairs(distances) do
        if not activeMap[nameA] then
            distances[nameA] = nil
        else
            for nameB in pairs(distances[nameA]) do
                if not activeMap[nameB] then
                    distances[nameA][nameB] = nil
                end
            end
        end
    end
end

-- Find the unit token corresponding to a player name
local function GetUnitTokenByName(name)
    if name == localPlayerName then
        return "player"
    end
    if IsInRaid() then
        for i = 1, 40 do
            local unit = "raid" .. i
            if UnitExists(unit) and UnitName(unit) == name then
                return unit
            end
        end
    else
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) and UnitName(unit) == name then
                return unit
            end
        end
    end
    return nil
end

-- Measure distance buckets from the local player to everyone else
local function GetUnitDistanceBucket(unit)
    if UnitIsUnit(unit, "player") then
        return 0
    end
    if not UnitExists(unit) or not UnitIsConnected(unit) then
        return 5
    end
    
    if CheckInteractDistance(unit, 3) then -- ~10 yds (Duel)
        return 1
    elseif CheckInteractDistance(unit, 1) then -- ~28 yds (Inspect)
        return 2
    else
        local item30 = MeshNavDB.item30 or 21519
        local item40 = MeshNavDB.item40 or 9062
        
        local in30 = IsItemInRangeWrapper(item30, unit)
        if in30 == true then
            return 3
        elseif in30 == false then
            local in40 = IsItemInRangeWrapper(item40, unit)
            if in40 == true then
                return 4
            end
        else
            -- Fallback directly to 40 yds if 30yd item returns nil
            local in40 = IsItemInRangeWrapper(item40, unit)
            if in40 == true then
                return 4
            end
        end
    end
    return 5
end

-- Scan targets, focus, and nameplates for hostile and friendly mobs
local function ScanMobs()
    local MobsList = {}
    
    local scanUnits = { "target", "focus" }
    for i = 1, 40 do
        table.insert(scanUnits, "nameplate" .. i)
    end
    
    for _, unit in ipairs(scanUnits) do
        if UnitExists(unit) and not UnitIsPlayer(unit) then
            local guid = UnitGUID(unit)
            if guid and (string.find(guid, "Creature") or string.find(guid, "Vehicle")) then
                local short = GetShortGUID(guid)
                local bucket = GetUnitDistanceBucket(unit)
                
                if bucket and bucket < 5 then -- only track if in range (<40 yds)
                    local isHostile = UnitCanAttack("player", unit) or UnitIsEnemy("player", unit)
                    local isFriendly = UnitIsFriend("player", unit)
                    local hostility = isHostile and "H" or (isFriendly and "F" or "N")
                    
                    local name = UnitName(unit)
                    if name then
                        mobNames[short] = name
                    end
                    
                    MobsList[short] = {
                        bucket = bucket,
                        hostility = hostility,
                        name = name
                    }
                end
            end
        end
    end
    localMobs = MobsList
end

-- Update local players distance vectors
local function UpdateLocalDistances()
    if not distances[localPlayerName] then
        distances[localPlayerName] = {}
    end
    
    for _, name in ipairs(roster) do
        if name ~= localPlayerName then
            local unit = GetUnitTokenByName(name)
            local bucket = 5
            if unit then
                bucket = GetUnitDistanceBucket(unit)
            end
            distances[localPlayerName][name] = bucket
        else
            distances[localPlayerName][name] = 0
        end
    end
    
    -- Scan mobs in this cycle
    ScanMobs()
end

-- Serialize and broadcast local coordinates and mob vectors
local function BroadcastDistances()
    -- Find our own sorted index
    local localIdx = nil
    for idx, name in ipairs(roster) do
        if name == localPlayerName then
            localIdx = idx
            break
        end
    end
    if not localIdx then return end
    
    -- Format: "index:b1b2b3b4...|shortGUID:hostility:bucket,..."
    local payload = tostring(localIdx) .. ":"
    for _, name in ipairs(roster) do
        local b = distances[localPlayerName] and distances[localPlayerName][name] or 5
        payload = payload .. tostring(b)
    end
    
    -- Append visible mobs
    local mobParts = {}
    for short, data in pairs(localMobs) do
        table.insert(mobParts, string.format("%s:%s:%d", short, data.hostility, data.bucket))
        -- Cap at 5 closest mobs to stay well within network bandwidth boundaries
        if #mobParts >= 5 then break end
    end
    
    if #mobParts > 0 then
        payload = payload .. "|" .. table.concat(mobParts, ",")
    end
    
    -- Send via party/raid channel
    local channel = IsInRaid() and "RAID" or "PARTY"
    if IsInGroup() then
        C_ChatInfo.SendAddonMessage("MN_SYNC", payload, channel)
        
        -- Log entry if logging is enabled
        if MeshNavDB.logging then
            local entry = {
                ["time"] = time(),
                ["sender"] = localPlayerName,
                ["payload"] = payload
            }
            table.insert(MeshNavDB.history, entry)
            if #MeshNavDB.history > 1000 then
                table.remove(MeshNavDB.history, 1)
            end
        end
    end
end

-- Parse incoming sync messages from other players
local function HandleIncomingMessage(sender, message)
    local senderName = Ambiguate(sender, "none")
    if senderName == localPlayerName then return end
    
    local mainParts = {}
    for p in string.gmatch(message, "[^|]+") do
        table.insert(mainParts, p)
    end
    
    local playerPart = mainParts[1]
    local mobPart = mainParts[2]
    
    -- Parse player distances
    local parts = {}
    for p in string.gmatch(playerPart, "[^:]+") do
        table.insert(parts, p)
    end
    
    local senderIdx = tonumber(parts[1])
    local bucketsStr = parts[2]
    if not senderIdx or not bucketsStr then return end
    if #bucketsStr ~= #roster then return end
    if roster[senderIdx] ~= senderName then return end
    
    -- Log entry if logging is enabled
    if MeshNavDB.logging then
        local entry = {
            ["time"] = time(),
            ["sender"] = senderName,
            ["payload"] = message
        }
        table.insert(MeshNavDB.history, entry)
        if #MeshNavDB.history > 1000 then
            table.remove(MeshNavDB.history, 1)
        end
    end
    
    -- Update players distances matrix
    if not distances[senderName] then
        distances[senderName] = {}
    end
    
    for j = 1, #roster do
        local targetName = roster[j]
        if targetName ~= senderName then
            local bucket = tonumber(bucketsStr:sub(j, j))
            if bucket then
                distances[senderName][targetName] = bucket
            end
        end
    end
    
    -- Parse mob distances
    if mobPart then
        for mobEntry in string.gmatch(mobPart, "[^,]+") do
            local mParts = {}
            for mp in string.gmatch(mobEntry, "[^:]+") do
                table.insert(mParts, mp)
            end
            local short = mParts[1]
            local hostility = mParts[2]
            local bucket = tonumber(mParts[3])
            
            if short and hostility and bucket then
                if not mobDistances[short] then
                    mobDistances[short] = {}
                end
                mobDistances[short][senderName] = {
                    bucket = bucket,
                    hostility = hostility,
                    time = time()
                }
            end
        end
    end
end

-- Trilateration Solver using Verlet Relaxation
local function RunVerletSolver()
    local N = #roster
    if N <= 1 then return end
    
    -- Find our index
    local L = nil
    for idx, name in ipairs(roster) do
        if name == localPlayerName then
            L = idx
            break
        end
    end
    if not L then return end
    
    -- Setup current node coordinates
    local nodes = {}
    for i = 1, N do
        local name = roster[i]
        nodes[i] = {
            name = name,
            x = positions[name] and positions[name].x or 0,
            y = positions[name] and positions[name].y or 0
        }
    end
    
    -- Lock local player at center (0, 0)
    nodes[L].x = 0
    nodes[L].y = 0
    
    -- Initialize unpositioned nodes in circular offsets
    for i = 1, N do
        if i ~= L and nodes[i].x == 0 and nodes[i].y == 0 then
            local b = distances[localPlayerName] and distances[localPlayerName][nodes[i].name] or 5
            local d = BucketToYards(b)
            local angle = (i * 2 * math.pi) / N
            nodes[i].x = d * math.cos(angle)
            nodes[i].y = d * math.sin(angle)
        end
    end
    
    -- Relaxation loops for players
    for iter = 1, 30 do
        for i = 1, N do
            for j = i + 1, N do
                local nameI = nodes[i].name
                local nameJ = nodes[j].name
                
                -- Determine target distance
                local targetDist = 48
                local isBucket5 = false
                
                if i == L or j == L then
                    -- Local player's measurements are master
                    local otherName = (i == L) and nameJ or nameI
                    local b = distances[localPlayerName] and distances[localPlayerName][otherName] or 5
                    targetDist = BucketToYards(b)
                    if b == 5 then isBucket5 = true end
                else
                    -- For other pairs, merge their reports
                    local b_ij = distances[nameI] and distances[nameI][nameJ]
                    local b_ji = distances[nameJ] and distances[nameJ][nameI]
                    
                    if b_ij == 5 or b_ji == 5 then
                        isBucket5 = true
                    end
                    
                    if b_ij or b_ji then
                        local y1 = BucketToYards(b_ij or 5)
                        local y2 = BucketToYards(b_ji or 5)
                        targetDist = (y1 + y2) / 2
                    end
                end
                
                -- Compute current distance
                local dx = nodes[j].x - nodes[i].x
                local dy = nodes[j].y - nodes[i].y
                local dist = math.sqrt(dx*dx + dy*dy)
                if dist < 0.1 then dist = 0.1 end
                
                -- Apply constraints
                if isBucket5 then
                    if dist < 40 then
                        local err = dist - 40
                        local offsetX = (dx / dist) * err
                        
                        if i == L then
                            nodes[j].x = nodes[j].x - offsetX
                            nodes[j].y = nodes[j].y - ((dy / dist) * err)
                        elseif j == L then
                            nodes[i].x = nodes[i].x + offsetX
                            nodes[i].y = nodes[i].y + ((dy / dist) * err)
                        else
                            nodes[i].x = nodes[i].x + offsetX * 0.5
                            nodes[i].y = nodes[i].y + ((dy / dist) * err) * 0.5
                            nodes[j].x = nodes[j].x - offsetX * 0.5
                            nodes[j].y = nodes[j].y - ((dy / dist) * err) * 0.5
                        end
                    end
                else
                    local err = dist - targetDist
                    local offsetX = (dx / dist) * err
                    
                    if i == L then
                        nodes[j].x = nodes[j].x - offsetX
                        nodes[j].y = nodes[j].y - ((dy / dist) * err)
                    elseif j == L then
                        nodes[i].x = nodes[i].x + offsetX
                        nodes[i].y = nodes[i].y + ((dy / dist) * err)
                    else
                        nodes[i].x = nodes[i].x + offsetX * 0.5
                        nodes[i].y = nodes[i].y + ((dy / dist) * err) * 0.5
                        nodes[j].x = nodes[j].x - offsetX * 0.5
                        nodes[j].y = nodes[j].y - ((dy / dist) * err) * 0.5
                    end
                end
            end
        end
    end
    
    -- Smoothly update player positions coordinates
    for i = 1, N do
        local name = nodes[i].name
        if not positions[name] then
            positions[name] = {x = nodes[i].x, y = nodes[i].y}
        else
            positions[name].x = positions[name].x + (nodes[i].x - positions[name].x) * 0.15
            positions[name].y = positions[name].y + (nodes[i].y - positions[name].y) * 0.15
        end
    end
    
    -- Solve positions for mobs relative to players
    local now = time()
    for short, reports in pairs(mobDistances) do
        local active = false
        local hostility = "H"
        
        -- Cleanup reports older than 3 seconds
        for sender, data in pairs(reports) do
            if now - data.time > 3 then
                reports[sender] = nil
            else
                active = true
                hostility = data.hostility
            end
        end
        
        if not active then
            mobDistances[short] = nil
            mobPositions[short] = nil
        else
            -- Initialize mob position if untracked
            if not mobPositions[short] then
                local bestPlayer = nil
                local bestDist = 999
                
                for sender, data in pairs(reports) do
                    local y = BucketToYards(data.bucket)
                    if y < bestDist then
                        bestDist = y
                        bestPlayer = sender
                      end
                end
                
                if localMobs[short] then
                    bestPlayer = localPlayerName
                    bestDist = BucketToYards(localMobs[short].bucket)
                end
                
                if bestPlayer and positions[bestPlayer] then
                    local px = positions[bestPlayer].x
                    local py = positions[bestPlayer].y
                    -- Place slightly offset
                    mobPositions[short] = { x = px + bestDist * 0.7, y = py + bestDist * 0.7 }
                else
                    mobPositions[short] = { x = 0, y = 15 }
                end
            end
            
            local mx = mobPositions[short].x
            local my = mobPositions[short].y
            
            -- Run relaxation iterations for this mob
            for iter = 1, 20 do
                for sender, data in pairs(reports) do
                    local px, py
                    if sender == localPlayerName then
                        px, py = 0, 0
                    else
                        if positions[sender] then
                            px = positions[sender].x
                            py = positions[sender].y
                        end
                    end
                    
                    if px and py then
                        local targetDist = BucketToYards(data.bucket)
                        local dx = mx - px
                        local dy = my - py
                        local dist = math.sqrt(dx*dx + dy*dy)
                        if dist < 0.1 then dist = 0.1 end
                        
                        if data.bucket == 5 then
                            if dist < 40 then
                                local err = dist - 40
                                mx = mx + (dx / dist) * err
                                my = my + (dy / dist) * err
                            end
                        else
                            local err = dist - targetDist
                            mx = mx - (dx / dist) * err * 0.4
                            my = my - (dy / dist) * err * 0.4
                        end
                    end
                end
                
                -- Constrain to local player measurements if we see it
                if localMobs[short] then
                    local targetDist = BucketToYards(localMobs[short].bucket)
                    local dx = mx - 0
                    local dy = my - 0
                    local dist = math.sqrt(dx*dx + dy*dy)
                    if dist < 0.1 then dist = 0.1 end
                    local err = dist - targetDist
                    mx = mx - (dx / dist) * err * 0.4
                    my = my - (dy / dist) * err * 0.4
                end
            end
            
            -- Smoothly update coordinates
            mobPositions[short].x = mobPositions[short].x + (mx - mobPositions[short].x) * 0.15
            mobPositions[short].y = mobPositions[short].y + (my - mobPositions[short].y) * 0.15
            mobPositions[short].hostility = hostility
        end
    end
end

-- UI Setup
local radarFrame = CreateFrame("Frame", "MeshNavFrame", UIParent, "BackdropTemplate")
radarFrame:SetSize(RADAR_SIZE, RADAR_SIZE)
radarFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
radarFrame:SetMovable(true)
radarFrame:EnableMouse(true)
radarFrame:RegisterForDrag("LeftButton")
radarFrame:SetScript("OnDragStart", function(self)
    if not MeshNavDB.locked then
        self:StartMoving()
    end
end)
radarFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    MeshNavDB.point = point
    MeshNavDB.relativePoint = relPoint
    MeshNavDB.posX = x
    MeshNavDB.posY = y
end)

-- Glass background texture
local bg = radarFrame:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints(radarFrame)
bg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
bg:SetVertexColor(0.02, 0.02, 0.02, 0.75) -- Darker, higher contrast
bg:SetMask("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")

-- Compass spacer for clean circular outer border
local border = radarFrame:CreateTexture(nil, "OVERLAY")
border:SetAllPoints(radarFrame)
border:SetTexture("Interface\\Minimap\\Compass-Ring")
border:SetVertexColor(0.4, 0.4, 0.4, 0.5) -- High contrast

-- Render concentric helper rings
local function CreateRadarRing(radius, label)
    local size = radius * 2 * SCALE
    local ring = radarFrame:CreateTexture(nil, "BORDER")
    ring:SetSize(size, size)
    ring:SetPoint("CENTER", radarFrame, "CENTER", 0, 0)
    ring:SetTexture("Interface\\Minimap\\Compass-Ring")
    ring:SetVertexColor(1, 1, 1, 0.22) -- High contrast
    
    local text = radarFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("BOTTOM", ring, "TOP", 0, -10)
    text:SetText(label)
    text:SetTextColor(0.8, 0.8, 0.8, 0.6) -- High contrast
    return ring
end

local ring10 = CreateRadarRing(10, "10y")
local ring28 = CreateRadarRing(28, "28y")
local ring40 = CreateRadarRing(40, "40y")

-- Center Dot for Player
local centerDot = CreateFrame("Frame", nil, radarFrame)
centerDot:SetSize(10, 10)
centerDot:SetPoint("CENTER", radarFrame, "CENTER", 0, 0)

local centerBg = centerDot:CreateTexture(nil, "BACKGROUND")
centerBg:SetSize(12, 12)
centerBg:SetPoint("CENTER", centerDot, "CENTER", 0, 0)
centerBg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
centerBg:SetVertexColor(0, 0, 0, 0.9)
centerBg:SetMask("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")

local centerFg = centerDot:CreateTexture(nil, "ARTWORK")
centerFg:SetSize(8, 8)
centerFg:SetPoint("CENTER", centerDot, "CENTER", 0, 0)
centerFg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
centerFg:SetVertexColor(0.1, 0.95, 0.95, 1.0) -- High contrast cyan player dot
centerFg:SetMask("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")

-- Pools of UI dot frames (Players and Mobs)
local dotPool = {}
local function GetDotFrame(index)
    if not dotPool[index] then
        local dot = CreateFrame("Frame", "MeshNavDot" .. index, radarFrame)
        dot:SetSize(12, 12)
        
        local hl = dot:CreateTexture(nil, "BACKGROUND", nil, -1)
        hl:SetSize(18, 18)
        hl:SetPoint("CENTER", dot, "CENTER", 0, 0)
        hl:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        hl:SetVertexColor(1, 0.85, 0, 1) -- Gold
        hl:SetMask("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        hl:Hide()
        dot.hl = hl

        local bg = dot:CreateTexture(nil, "BACKGROUND")
        bg:SetSize(14, 14)
        bg:SetPoint("CENTER", dot, "CENTER", 0, 0)
        bg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        bg:SetVertexColor(0, 0, 0, 0.9)
        bg:SetMask("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        dot.bg = bg

        local fg = dot:CreateTexture(nil, "ARTWORK")
        fg:SetSize(10, 10)
        fg:SetPoint("CENTER", dot, "CENTER", 0, 0)
        fg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        fg:SetMask("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        dot.fg = fg

        local text = dot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("BOTTOM", dot, "TOP", 0, 2)
        dot.text = text

        dot:EnableMouse(true)
        dot:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.playerName or "Unknown Player", 1, 1, 1)
            if self.playerClass then
                local color = RAID_CLASS_COLORS[self.classToken]
                if color then
                    GameTooltip:AddLine(self.playerClass, color.r, color.g, color.b)
                else
                    GameTooltip:AddLine(self.playerClass, 1, 1, 1)
                end
            end
            if self.playerDist then
                GameTooltip:AddLine(string.format("Est. Distance: %.1f yards", self.playerDist), 0.8, 0.8, 0.8)
            end
            if MeshNavDB.guide == self.playerName then
                GameTooltip:AddLine("â˜… Current Guide", 1, 0.85, 0)
            else
                GameTooltip:AddLine("Right-Click to Set as Guide", 0.5, 0.5, 0.5)
            end
            GameTooltip:Show()
        end)
        dot:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)
        dot:SetScript("OnMouseDown", function(self, button)
            if button == "RightButton" and self.playerName then
                if MeshNavDB.guide == self.playerName then
                    MeshNavDB.guide = nil
                    print("|cff00ff00MeshNav:|r Guide cleared.")
                else
                    MeshNavDB.guide = self.playerName
                    print("|cff00ff00MeshNav:|r Set guide target to: " .. self.playerName)
                end
                if GameTooltip:IsOwnedBy(self) then
                    self:GetScript("OnEnter")(self)
                end
            end
        end)

        dotPool[index] = dot
    end
    return dotPool[index]
end

-- Pool of Mob dot frames (high contrast red/green circles)
local mobDotPool = {}
local function GetMobDotFrame(index)
    if not mobDotPool[index] then
        local dot = CreateFrame("Frame", "MeshNavMobDot" .. index, radarFrame)
        dot:SetSize(8, 8) -- Smaller than player dots

        local bg = dot:CreateTexture(nil, "BACKGROUND")
        bg:SetSize(10, 10)
        bg:SetPoint("CENTER", dot, "CENTER", 0, 0)
        bg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        bg:SetVertexColor(0, 0, 0, 0.95)
        bg:SetMask("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")

        local fg = dot:CreateTexture(nil, "ARTWORK")
        fg:SetSize(6, 6)
        fg:SetPoint("CENTER", dot, "CENTER", 0, 0)
        fg:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        fg:SetMask("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        dot.fg = fg

        dot:EnableMouse(true)
        dot:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local name = mobNames[self.mobGUID] or (self.hostility == "H" and "Hostile Enemy" or "Friendly NPC")
            
            if self.hostility == "H" then
                GameTooltip:AddLine(name, 1, 0.2, 0.2)
            else
                GameTooltip:AddLine(name, 0.2, 1, 0.2)
            end
            
            if self.mobDist then
                GameTooltip:AddLine(string.format("Est. Distance: %.1f yards", self.mobDist), 0.8, 0.8, 0.8)
            end
            GameTooltip:Show()
        end)
        dot:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        mobDotPool[index] = dot
    end
    return mobDotPool[index]
end

-- Refresh HUD UI
local function UpdateRadarUI()
    -- Hide all player and mob dots initially
    for _, dot in ipairs(dotPool) do dot:Hide() end
    for _, dot in ipairs(mobDotPool) do dot:Hide() end
    
    -- Render players
    local dotIdx = 1
    for _, name in ipairs(roster) do
        if name ~= localPlayerName and positions[name] then
            local x = positions[name].x
            local y = positions[name].y
            local dist = math.sqrt(x*x + y*y)
            local isClamped = false
            
            if dist > MAX_RADAR_RANGE then
                x = x * (MAX_RADAR_RANGE / dist)
                y = y * (MAX_RADAR_RANGE / dist)
                dist = MAX_RADAR_RANGE
                isClamped = true
            end
            
            local px = x * SCALE
            local py = y * SCALE
            
            local dot = GetDotFrame(dotIdx)
            dot.playerName = name
            dot.playerDist = dist
            
            local unit = GetUnitTokenByName(name)
            if unit then
                local _, classToken = UnitClass(unit)
                dot.classToken = classToken
                dot.playerClass = UnitClass(unit)
                
                local color = RAID_CLASS_COLORS[classToken]
                if color then
                    dot.fg:SetVertexColor(color.r, color.g, color.b, 1.0)
                    dot.text:SetTextColor(color.r, color.g, color.b)
                else
                    dot.fg:SetVertexColor(0.8, 0.8, 0.8, 1.0)
                    dot.text:SetTextColor(0.8, 0.8, 0.8)
                end
            end
            
            dot.text:SetText(string.sub(name, 1, 3))
            
            if isClamped then
                dot:SetAlpha(0.4)
            else
                dot:SetAlpha(1.0)
            end
            
            if MeshNavDB.guide == name then
                dot.hl:Show()
            else
                dot.hl:Hide()
            end
            
            dot:SetPoint("CENTER", radarFrame, "CENTER", px, py)
            dot:Show()
            dotIdx = dotIdx + 1
        end
    end
    
    -- Render Mobs
    local mobIdx = 1
    for short, pos in pairs(mobPositions) do
        local x = pos.x
        local y = pos.y
        local dist = math.sqrt(x*x + y*y)
        local isClamped = false
        
        if dist > MAX_RADAR_RANGE then
            x = x * (MAX_RADAR_RANGE / dist)
            y = y * (MAX_RADAR_RANGE / dist)
            dist = MAX_RADAR_RANGE
            isClamped = true
        end
        
        local px = x * SCALE
        local py = y * SCALE
        
        local dot = GetMobDotFrame(mobIdx)
        dot.mobGUID = short
        dot.mobDist = dist
        dot.hostility = pos.hostility
        
        -- High contrast red for enemies, green for friends
        if pos.hostility == "H" then
            dot.fg:SetVertexColor(1.0, 0.1, 0.1, 1.0)
        else
            dot.fg:SetVertexColor(0.1, 1.0, 0.1, 1.0)
        end
        
        if isClamped then
            dot:SetAlpha(0.35)
        else
            dot:SetAlpha(1.0)
        end
        
        dot:SetPoint("CENTER", radarFrame, "CENTER", px, py)
        dot:Show()
        mobIdx = mobIdx + 1
        
        -- Safety cap on mob dots to keep UI clean
        if mobIdx > 25 then break end
    end
end

-- Calculate clock hour relative to player facing (12 o'clock is forward)
local function GetClockDirection(name)
    if not positions[name] then return nil, nil end
    local x = positions[name].x
    local y = positions[name].y
    
    local dist = math.sqrt(x*x + y*y)
    if dist < 0.1 then return 12, 0 end
    
    local deg = math.deg(math.atan2(x, y))
    if deg < 0 then
        deg = deg + 360
    end
    
    local hour = math.floor((deg + 15) / 30) % 12
    if hour == 0 then
        hour = 12
    end
    
    return hour, dist
end

-- Announce guide position via TTS
local function AnnounceGuideTTS()
    local guide = MeshNavDB.guide
    if not guide then return end
    
    -- Make sure guide is still in roster
    local guideExists = false
    for _, name in ipairs(roster) do
        if name == guide then
            guideExists = true
            break
        end
    end
    if not guideExists then return end
    
    local hour, dist = GetClockDirection(guide)
    if not hour or not dist then return end
    
    local message = string.format("%s at %d o'clock, %d yards", guide, hour, math.floor(dist))
    
    if C_TextToSpeech and C_TextToSpeech.SpeakText then
        C_TextToSpeech.SpeakText(message)
    else
        print("|cff00ff00MeshNav TTS:|r " .. message)
    end
end

-- Global Trigger function called by Keybinding in Bindings.xml
function MeshNav_TriggerTTS()
    local guide = MeshNavDB.guide
    if not guide then
        print("|cff00ff00MeshNav:|r No guide target assigned. Right-click a player dot or use /mn guide <name>.")
        return
    end
    
    local guideExists = false
    for _, name in ipairs(roster) do
        if name == guide then
            guideExists = true
            break
        end
    end
    if not guideExists then
        print("|cff00ff00MeshNav:|r Guide " .. guide .. " is not in the group.")
        return
    end
    
    local hour, dist = GetClockDirection(guide)
    if not hour or not dist then
        print("|cff00ff00MeshNav:|r Cannot resolve relative coordinates for " .. guide .. ".")
        return
    end
    
    AnnounceGuideTTS()
end

-- Update TTS announcement timer
local function UpdateTTSAnnouncements(elapsed)
    if not MeshNavDB.ttsEnabled or not MeshNavDB.guide then return end
    
    ttsTimer = ttsTimer + elapsed
    local interval = MeshNavDB.ttsInterval or 5
    if ttsTimer >= interval then
        ttsTimer = 0
        AnnounceGuideTTS()
    end
end

-- Event scripting frame
local timeSinceLastUpdate = 0
local UPDATE_INTERVAL = 0.5

frame:SetScript("OnUpdate", function(self, elapsed)
    timeSinceLastUpdate = timeSinceLastUpdate + elapsed
    if timeSinceLastUpdate >= UPDATE_INTERVAL then
        timeSinceLastUpdate = 0
        
        -- Periodic roster refresh and range polling
        UpdateLocalDistances()
        BroadcastDistances()
    end
    
    -- Run solver and render positions
    RunVerletSolver()
    UpdateRadarUI()
    
    -- Check periodic TTS triggers
    UpdateTTSAnnouncements(elapsed)
end)

-- Main event router
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == "MeshNav" then
            localPlayerName = UnitName("player") or localPlayerName
            -- Set up defaults
            MeshNavDB = MeshNavDB or {}
            
            -- In-game DB Version Check & Update Protocol (ItemRack EventsVersion pattern)
            local dbVer = MeshNavDB.version or 0
            if dbVer < DB_VERSION then
                print("|cff00ff00MeshNav Database Deploy:|r Updating database from version " .. dbVer .. " to " .. DB_VERSION)
                MeshNavDB.version = DB_VERSION
                MeshNavDB.item30 = 21519
                MeshNavDB.item40 = 9062
            end
            
            if MeshNavDB.posX == nil then MeshNavDB.posX = 0 end
            if MeshNavDB.posY == nil then MeshNavDB.posY = 0 end
            if MeshNavDB.point == nil then MeshNavDB.point = "CENTER" end
            if MeshNavDB.relativePoint == nil then MeshNavDB.relativePoint = "CENTER" end
            if MeshNavDB.locked == nil then MeshNavDB.locked = false end
            if MeshNavDB.logging == nil then MeshNavDB.logging = false end
            if MeshNavDB.ttsEnabled == nil then MeshNavDB.ttsEnabled = false end
            if MeshNavDB.ttsInterval == nil then MeshNavDB.ttsInterval = 5 end
            if MeshNavDB.item30 == nil then MeshNavDB.item30 = 21519 end
            if MeshNavDB.item40 == nil then MeshNavDB.item40 = 9062 end
            if MeshNavDB.history == nil then MeshNavDB.history = {} end
            
            -- Position frame
            radarFrame:ClearAllPoints()
            radarFrame:SetPoint(MeshNavDB.point, UIParent, MeshNavDB.relativePoint, MeshNavDB.posX, MeshNavDB.posY)
            
            -- Register prefix
            C_ChatInfo.RegisterAddonMessagePrefix("MN_SYNC")
            print("|cff00ff00MeshNav Loaded:|r Use /mn for controls. Drag Circular Frame to move. Right-click player dots to target as Guide. High contrast minimap active.")
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        localPlayerName = UnitName("player") or localPlayerName
        RebuildRoster()
        UpdateLocalDistances()
    elseif event == "GROUP_ROSTER_UPDATE" then
        RebuildRoster()
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        if prefix == "MN_SYNC" then
            HandleIncomingMessage(sender, message)
        end
    end
end)

-- Command options
SLASH_MESHNAV1 = "/mn"
SLASH_MESHNAV2 = "/meshnav"
SlashCmdList["MESHNAV"] = function(msg)
    local args = {}
    for word in string.gmatch(msg, "%S+") do
        table.insert(args, word)
    end
    
    local cmd = args[1] and string.lower(args[1])
    
    if not cmd then
        print("|cff00ff00MeshNav Commands:|r")
        print("  |cffffdd00/mn show/hide|r - Toggle radar visibility")
        print("  |cffffdd00/mn lock|r - Toggle frame dragging lock")
        print("  |cffffdd00/mn guide <name>|r - Manually lock guide target by name")
        print("  |cffffdd00/mn clear|r - Remove guide selection")
        print("  |cffffdd00/mn tts|r - Triggers immediate audio check of the guide")
        print("  |cffffdd00/mn speak <on/off>|r - Toggle periodic TTS pings")
        print("  |cffffdd00/mn interval <sec>|r - Set periodic TTS ping time (default 5s)")
        print("  |cffffdd00/mn log|r - Toggle saved variables log data writing")
        print("  |cffffdd00/mn clearlog|r - Flush the history database")
        print("  |cffffdd00/mn item30 <id>|r - Update 30yd item range check ID")
        print("  |cffffdd00/mn item40 <id>|r - Update 40yd item range check ID")
        return
    end
    
    if cmd == "show" then
        radarFrame:Show()
        print("|cff00ff00MeshNav:|r Radar visibility enabled.")
    elseif cmd == "hide" then
        radarFrame:Hide()
        print("|cff00ff00MeshNav:|r Radar visibility hidden.")
    elseif cmd == "lock" then
        MeshNavDB.locked = not MeshNavDB.locked
        print("|cff00ff00MeshNav:|r Frame locking is now: " .. (MeshNavDB.locked and "LOCKED" or "UNLOCKED"))
    elseif cmd == "guide" then
        local target = args[2]
        if target then
            target = string.upper(string.sub(target, 1, 1)) .. string.lower(string.sub(target, 2))
            MeshNavDB.guide = target
            print("|cff00ff00MeshNav:|r Set guide target to " .. target)
        else
            print("|cff00ff00MeshNav:|r Please specify a player name: /mn guide <name>")
        end
    elseif cmd == "clear" then
        MeshNavDB.guide = nil
        print("|cff00ff00MeshNav:|r Guide target cleared.")
    elseif cmd == "tts" then
        if MeshNavDB.guide then
            AnnounceGuideTTS()
        else
            print("|cff00ff00MeshNav:|r No guide target assigned. Right-click a player dot or use /mn guide <name>.")
        end
    elseif cmd == "speak" then
        local opt = args[2] and string.lower(args[2])
        if opt == "on" then
            MeshNavDB.ttsEnabled = true
        elseif opt == "off" then
            MeshNavDB.ttsEnabled = false
        else
            MeshNavDB.ttsEnabled = not MeshNavDB.ttsEnabled
        end
        ttsTimer = 0
        print("|cff00ff00MeshNav:|r Periodic TTS announcements: " .. (MeshNavDB.ttsEnabled and "ENABLED" or "DISABLED"))
    elseif cmd == "interval" then
        local sec = tonumber(args[2])
        if sec and sec > 0 then
            MeshNavDB.ttsInterval = sec
            ttsTimer = 0
            print("|cff00ff00MeshNav:|r TTS interval set to: " .. sec .. " seconds.")
        else
            print("|cff00ff00MeshNav:|r Usage: /mn interval <seconds>")
        end
    elseif cmd == "log" then
        MeshNavDB.logging = not MeshNavDB.logging
        print("|cff00ff00MeshNav:|r Database matrix logging is now: " .. (MeshNavDB.logging and "ENABLED" or "DISABLED"))
    elseif cmd == "clearlog" then
        MeshNavDB.history = {}
        print("|cff00ff00MeshNav:|r Database history log database flushed.")
    elseif cmd == "item30" then
        local id = tonumber(args[2])
        if id then
            MeshNavDB.item30 = id
            print("|cff00ff00MeshNav:|r 30yd check item set to item ID: " .. id)
        else
            print("|cff00ff00MeshNav:|r Usage: /mn item30 <itemID>")
        end
    elseif cmd == "item40" then
        local id = tonumber(args[2])
        if id then
            MeshNavDB.item40 = id
            print("|cff00ff00MeshNav:|r 40yd check item set to item ID: " .. id)
        else
            print("|cff00ff00MeshNav:|r Usage: /mn item40 <itemID>")
        end
    else
        print("|cff00ff00MeshNav:|r Unknown command. Type /mn for help.")
    end
end

