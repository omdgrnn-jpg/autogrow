-- ============================================================
-- SAVANNAH/JUNGLE LIFE | MEGA SCRIPT v2.1
-- Solara + Delta + Synapse compatible
-- ============================================================

local function safeHook(fn)
    if typeof(hookmetamethod) == "function" then
        local ok, result = pcall(fn)
        if ok then return result end
    end
    return nil
end

local function safeCheck()
    if typeof(checkcaller) == "function" then
        return checkcaller()
    end
    return true
end

local function safeFireProximity(prompt)
    if typeof(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt)
    end
end

local function safeGetEnv()
    if typeof(getgenv) == "function" then
        local ok, env = pcall(getgenv)
        if ok then return env end
    end
    return shared
end

-- ============================================================
-- SERVICES
-- ============================================================
local Players       = game:GetService("Players")
local RS            = game:GetService("ReplicatedStorage")
local RunService    = game:GetService("RunService")
local CoreGui       = game:GetService("CoreGui")
local TweenService  = game:GetService("TweenService")
local Lighting      = game:GetService("Lighting")
local VirtualUser   = game:GetService("VirtualUser")
local UserInput     = game:GetService("UserInputService")
local player        = Players.LocalPlayer

-- ============================================================
-- STATE
-- ============================================================
local cfg = {
    AutoEat          = false,
    AutoDrink        = false,
    AutoEatCarcass   = false,
    GoNearest        = true,
    AutoLeave        = true,
    GrowNew          = false,
    GrowExisting     = false,
    PassiveCoins     = false,
    InfStamina       = true,
    AlwaysDay        = true,
    AntiAfk          = true,
    AutoAttack       = false,
    SpeedBoost       = false,
    FoodESP          = false,
    AutoDailyReward  = false,
    NightVision      = false,
    AutoQuest        = false,
}

local speedMultiplier = 1.5
local inGrowthReset   = false
shared._inGrowthReset = false

-- ============================================================
-- GAME CONFIGS
-- ============================================================
local GAME_CONFIGS = {
    [18214855317] = {
        name      = "SavannahLife",
        growSpawn = Vector3.new(-6245.2, 10.0, 4664.3),
        warSpawn  = Vector3.new(-6245.2, 10.0, 4664.3),
        dangerY   = -100,
    },
    [6174994284] = {
        name      = "SavannahLife",
        growSpawn = Vector3.new(-6245.2, 10.0, 4664.3),
        warSpawn  = Vector3.new(-6245.2, 10.0, 4664.3),
        dangerY   = -100,
    },
    [9237322219] = {
        name      = "JungleLife",
        growSpawn = Vector3.new(1166.835, 24.75, -358.32),
        warSpawn  = Vector3.new(1166.835, 24.75, -358.32),
        dangerY   = -100,
    },
}
local gameConfig = GAME_CONFIGS[game.GameId] or GAME_CONFIGS[18214855317]
shared._growthGameName = gameConfig.name
shared._growSpawn = gameConfig.growSpawn

-- ============================================================
-- UTILS
-- ============================================================
local function getChar()   return player.Character end
local function getRoot()   local c = getChar() return c and c:FindFirstChild("HumanoidRootPart") end
local function getHum()    local c = getChar() return c and c:FindFirstChildOfClass("Humanoid") end
local function safe(fn)    local ok, e = pcall(fn) if not ok then warn(e) end end

local function waitForAttr(char, attr, timeout)
    timeout = timeout or 10
    local t = 0
    while t < timeout do
        local v = char:GetAttribute(attr)
        if v ~= nil then return v end
        task.wait(0.2)
        t = t + 0.2
    end
    return nil
end

local CARNIVORES = {Lion=true, Tiger=true, Cheetah=true, Crocodile=true, Leopard=true}
local function isCarnivore()
    local c = getChar()
    return c and CARNIVORES[c:GetAttribute("AnimalName")] == true
end

local function getAnimal()
    local c = getChar()
    return c and c:GetAttribute("AnimalName") or ""
end

-- ============================================================
-- CORE REMOTES
-- ============================================================
local AskSubState, VegEat, InsectEat, SetFoodType, ToggleGrowth, HandleTP, StartEatCarcass
safe(function()
    AskSubState     = RS:WaitForChild("AskServerToSetSubStateRemoteFunction", 5)
    VegEat          = RS:WaitForChild("VegetationEatingRemoteEvent", 5)
    InsectEat       = RS:WaitForChild("InsectsEatingRemoteEvent", 5)
    SetFoodType     = RS:FindFirstChild("AnimalGameFrameworkShared", true) and
                      RS.AnimalGameFrameworkShared.Utils.CanEatDrink:FindFirstChild("SetFoodTypeRemoteEvent")
    ToggleGrowth    = RS:WaitForChild("ToggleGrowthEnabledRemoteEvent", 5)
    HandleTP        = RS:WaitForChild("HandleTeleportOnFallingThroughMapRemoteEvent", 5)
    StartEatCarcass = RS:FindFirstChild("StartEatingCarcassesRemoteEvent", true)
                      or RS:FindFirstChild("StartEatingCarcassesRemotEvent", true)
end)

local Utils, AnimalConfig
safe(function()
    Utils = require(RS:WaitForChild("AnimalGameFrameworkShared"):WaitForChild("Utils"))
    AnimalConfig = require(RS.Shared.AnimalConfig)
end)

-- ============================================================
-- SUBSTATE HOOK
-- ============================================================
local blockSubState = false

safeHook(function()
    local namecall
    namecall = hookmetamethod(game, "__namecall", function(self, ...)
        if blockSubState and self == AskSubState and not safeCheck() then
            return true
        end
        return namecall(self, ...)
    end)
end)

-- allowSubState(true)  → let InvokeServer calls through
-- allowSubState(false) → intercept and block them
local function allowSubState(allow) blockSubState = not allow end
local function changeSubState(state)
    if not AskSubState then return end
    task.spawn(AskSubState.InvokeServer, AskSubState, state)
end

-- ============================================================
-- ANIMAL MODULE
-- ============================================================
local maxStudsPerSecond = 80
local activeTweenConn
local activeTweenPart

local LerpTween = {}
function LerpTween:TweenPartCFrame(part, goal, duration, onComplete)
    duration = math.max(duration or 1, 0.03)
    local start = part.CFrame
    local startTime = tick()
    local conn
    conn = RunService.PreRender:Connect(function()
        if not part or not part.Parent then conn:Disconnect() return end
        local alpha = math.min((tick() - startTime) / duration, 1)
        part.CFrame = start:lerp(goal, alpha)
        if alpha >= 1 then
            conn:Disconnect()
            part.CFrame = goal
            if onComplete then onComplete() end
        end
    end)
    return conn
end

local Animal = {}
function Animal.CancelTween(zero)
    if activeTweenConn then activeTweenConn:Disconnect() activeTweenConn = nil end
    if zero and activeTweenPart and activeTweenPart.Parent then
        activeTweenPart.AssemblyLinearVelocity = Vector3.zero
        activeTweenPart.AssemblyAngularVelocity = Vector3.zero
    end
    activeTweenPart = nil
    shared._animalTweening = false
end

function Animal.TweenTo(cf)
    local c = getChar() if not c then return end
    local root = getRoot() if not root then return end
    local dur = (cf.Position - root.Position).Magnitude / maxStudsPerSecond
    Animal.CancelTween(true)
    local conn
    conn = LerpTween:TweenPartCFrame(root, cf, dur, function()
        if activeTweenConn == conn then
            activeTweenConn = nil
            activeTweenPart = nil
            shared._animalTweening = false
        end
    end)
    activeTweenConn = conn
    activeTweenPart = root
    shared._animalTweening = true
    return dur
end

function Animal.TweenToAsync(cf)
    local dur = Animal.TweenTo(cf)
    if dur then task.wait(dur) end
end

function Animal.IsOnGrass()
    local root = getRoot() if not root then return false end
    local result = workspace:Raycast(root.Position, Vector3.new(0,-100,0))
    return result and result.Material == Enum.Material.Grass
end

function Animal.IsOnWater()
    local root = getRoot() if not root then return false end
    local result = workspace:Raycast(root.Position, Vector3.new(0,-100,0))
    return result and result.Material == Enum.Material.Water
end

function Animal.IsInsideTerrain()
    local c = getChar() if not c then return false end
    local root = getRoot() if not root then return false end
    local pos = root.Position
    local ok, result = pcall(function()
        local region = Region3.new(pos, pos + Vector3.new(4,4,4)):ExpandToGrid(4)
        local _, occ = workspace.Terrain:ReadVoxels(region, 4)
        return occ[1][1][1] > 0
    end)
    return ok and result or false
end

-- ============================================================
-- GRASS / WATER FINDERS
-- ============================================================
local grassRayParams = RaycastParams.new()
grassRayParams.FilterType = Enum.RaycastFilterType.Include
grassRayParams.FilterDescendantsInstances = {workspace.Terrain}

local waterRayParams = RaycastParams.new()
waterRayParams.FilterType = Enum.RaycastFilterType.Include
waterRayParams.FilterDescendantsInstances = {workspace.Terrain}

local function circlePoints(center, radius, res)
    local n = math.max(3, math.floor(2*math.pi*radius/res))
    local step = 2*math.pi/n
    local pts = {}
    for i = 0, n-1 do
        local a = i*step
        table.insert(pts, Vector3.new(center.X + radius*math.cos(a), center.Y, center.Z + radius*math.sin(a)))
    end
    return pts
end

local function FindNearestGrass(at, radius)
    radius = radius or 6
    local maxR = radius*8
    local pts = circlePoints(at + Vector3.new(0,40,0), radius, 4)
    for _, v in pts do
        local r = workspace:Raycast(v, Vector3.new(0,-80,0), grassRayParams)
        if r and r.Material == Enum.Material.Grass then return r.Position end
    end
    if radius < maxR then return FindNearestGrass(at, radius*2) end
    return nil
end

local function FindNearestWater(at, radius)
    radius = radius or 12
    local maxR = 384
    local pts = circlePoints(at + Vector3.new(0,80,0), radius, 12)
    local best, bestDist = nil, math.huge
    for _, v in pts do
        local r = workspace:Raycast(v, Vector3.new(0,-160,0), waterRayParams)
        if r and r.Material == Enum.Material.Water then
            local flatDir = Vector3.new(r.Position.X-at.X, 0, r.Position.Z-at.Z)
            local d = flatDir.Magnitude
            local shore = r.Position - (d>0 and flatDir.Unit*math.min(2,d) or Vector3.zero)
            if d < bestDist then best = shore bestDist = d end
        end
    end
    if best then return best end
    if radius < maxR then return FindNearestWater(at, math.min(radius*2, maxR)) end
    return nil
end

-- ============================================================
-- CAN EAT/DRINK CHECK
-- ============================================================
local function CanStartEatDrink(char, forDrink)
    if Utils and AnimalConfig then
        local ok, result = pcall(function()
            local v96 = char:GetAttribute("AnimalType")
            local v97 = char:GetAttribute("AnimalName")
            local age  = char:GetAttribute("AnimalAge")
            if not (v96 and v97 and age) then return nil end
            local cfg2 = AnimalConfig[v96][v97]
            local detected = Utils.CanEatDrink.DetectMeatGrassWater(char, cfg2)
            if cfg2.EnableLeavesEating and pcall(Utils.DetectLeaves, char) then return "Eat" end
            if cfg2.EnableInsectEating and pcall(Utils.DetectInsects, char) then return "Eat" end
            return detected
        end)
        if ok then return result end
    end
    if forDrink then
        return Animal.IsOnWater() and "Drink" or nil
    end
    return Animal.IsOnGrass() and "Eat" or nil
end

-- ============================================================
-- CONFIRMED TP
-- ============================================================
local TP_TOLERANCE = 12
local function confirmedTP(char, targetPos, label, maxAttempts)
    maxAttempts = maxAttempts or 6
    for attempt = 1, maxAttempts do
        local root = char:FindFirstChild("HumanoidRootPart")
        local hum  = char:FindFirstChildOfClass("Humanoid")
        if not root or not hum then task.wait(1) continue end
        root.Anchored = false
        hum:ChangeState(Enum.HumanoidStateType.Physics)
        for _ = 1, 25 do
            if char:FindFirstChild("HumanoidRootPart") then
                char:SetPrimaryPartCFrame(CFrame.new(targetPos))
            end
            task.wait()
        end
        task.wait(1)
        hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        for _ = 1, 10 do char:SetAttribute("MovementDisabled", false) task.wait(0.1) end
        local r = char:FindFirstChild("HumanoidRootPart")
        if r then
            local dist = (r.Position - targetPos).Magnitude
            if dist <= TP_TOLERANCE then
                print(string.format("[TP:%s] Confirmed attempt %d (%.1f studs)", label or "?", attempt, dist))
                return true
            end
            warn(string.format("[TP:%s] Attempt %d too far (%.1f studs)", label or "?", attempt, dist))
        end
    end
    warn("[TP] Failed after " .. maxAttempts .. " attempts")
    return false
end

-- ============================================================
-- AUTO EAT LOOP
-- ============================================================
local lastDrinkMove = 0
local DRINK_COOLDOWN = 1.5

task.spawn(function()
    while true do
        task.wait(0.5)
        if not cfg.AutoEat then continue end
        if shared._inGrowthReset or shared._inCarcassEat then continue end

        local char = getChar() if not char then continue end
        if CARNIVORES[getAnimal()] then continue end
        if char:GetAttribute("_drinkingToFull") then continue end

        local food = char:GetAttribute("Food") or 0
        if food >= 90 then continue end

        local ingestion = CanStartEatDrink(char)
        if ingestion == "Eat" then
            allowSubState(true)
            changeSubState("Eating")
            safe(function() if VegEat then VegEat:FireServer() end end)
            safe(function() if InsectEat then InsectEat:FireServer() end end)
        elseif cfg.GoNearest then
            local root = getRoot() if not root then continue end
            local grassPos = FindNearestGrass(root.Position)
            if grassPos then
                local hum = getHum()
                if hum then
                    local goal = grassPos + Vector3.new(0, hum.HipHeight, 0)
                    local dir = goal - root.Position
                    Animal.TweenToAsync(CFrame.lookAlong(goal - dir.Unit, dir))
                end
            end
        end
    end
end)

-- ============================================================
-- AUTO DRINK LOOP
-- ============================================================
task.spawn(function()
    while true do
        task.wait(0.5)
        if not cfg.AutoDrink then continue end
        if shared._inGrowthReset or shared._inCarcassEat then continue end

        local char = getChar() if not char then continue end
        local water = char:GetAttribute("Water") or 100
        local growth = char:GetAttribute("GrowthPercentage") or 0

        if growth >= 1 and not shared._parkingModeActive then
            char:SetAttribute("_drinkingToFull", false)
            continue
        end

        local trigger = shared._growthGameName == "SavannahLife" and 55 or 90
        if water <= trigger then char:SetAttribute("_drinkingToFull", true) end
        if water >= 100 then
            Animal.CancelTween(true)
            char:SetAttribute("_drinkingToFull", false)
            continue
        end
        if not char:GetAttribute("_drinkingToFull") then continue end

        local ingestion = CanStartEatDrink(char, true)
        if ingestion == "Drink" or ingestion == nil and Animal.IsOnWater() then
            Animal.CancelTween(true)
            allowSubState(true)
            changeSubState("Drinking")
        elseif cfg.GoNearest then
            local root = getRoot() if not root then continue end
            if root.Anchored then root.Anchored = false end
            local hum = getHum()
            if hum then hum:ChangeState(Enum.HumanoidStateType.GettingUp) end
            local waterPos = FindNearestWater(root.Position)
            if waterPos then
                local dist = (waterPos - root.Position).Magnitude
                if dist > 1 and tick() - lastDrinkMove >= DRINK_COOLDOWN then
                    lastDrinkMove = tick()
                    Animal.TweenToAsync(CFrame.new(root.Position.X, waterPos.Y, root.Position.Z))
                else
                    task.wait(0.25)
                end
            end
        end
    end
end)

-- ============================================================
-- AUTO EAT CARCASS LOOP  (self-contained: find → TP → eat → return → repeat)
-- ============================================================
task.spawn(function()

    -- find nearest carcass model from CarcassesStorageModel
    local function findNearestCarcass()
        local stor = workspace:FindFirstChild("CarcassesStorageModel")
        if not stor then return nil, math.huge end
        local root = getRoot()
        if not root then return nil, math.huge end
        local nearest, nearDist = nil, math.huge
        local seen = {}
        for _, c in stor:GetChildren() do
            if not seen[c] then
                seen[c] = true
                local cr = c:FindFirstChild("HumanoidRootPart") or c:FindFirstChildWhichIsA("BasePart", true)
                if cr then
                    local d = (root.Position - cr.Position).Magnitude
                    if d < nearDist then nearest = c nearDist = d end
                end
            end
        end
        for _, c in stor:GetDescendants() do
            if c:IsA("Model") and not seen[c] then
                seen[c] = true
                local cr = c:FindFirstChild("HumanoidRootPart") or c:FindFirstChildWhichIsA("BasePart", true)
                if cr then
                    local d = (root.Position - cr.Position).Magnitude
                    if d < nearDist then nearest = c nearDist = d end
                end
            end
        end
        return nearest, nearDist
    end

    -- unanchor + get up + clear movement lock
    local function releaseChar(char)
        local r = char:FindFirstChild("HumanoidRootPart")
        if r then
            r.Anchored = false
            r.AssemblyLinearVelocity = Vector3.zero
            r.AssemblyAngularVelocity = Vector3.zero
        end
        local h = char:FindFirstChildOfClass("Humanoid")
        if h then h:ChangeState(Enum.HumanoidStateType.GettingUp) end
        for _ = 1, 4 do char:SetAttribute("MovementDisabled", false) task.wait(0.1) end
    end

    while true do
        task.wait(1)
        if not cfg.AutoEatCarcass then continue end
        if shared._inGrowthReset then continue end
        if not CARNIVORES[getAnimal()] then continue end

        local char = getChar() if not char then continue end
        local food   = char:GetAttribute("Food") or 0
        local water  = char:GetAttribute("Water") or 100
        local growth = char:GetAttribute("GrowthPercentage") or 0

        if growth >= 1 then continue end

        -- handle low water first — TP to nearest water, drink, come back
        if water <= 35 then
            shared._inCarcassEat = true
            allowSubState(true)
            local root = getRoot()
            if root then
                local waterPos = FindNearestWater(root.Position)
                if waterPos then
                    confirmedTP(char, waterPos, "CarcassLoopDrink")
                    task.wait(0.5)
                    changeSubState("Drinking")
                    -- wait until water recovers or 15s timeout
                    local t = tick()
                    while tick() - t < 15 do
                        task.wait(0.5)
                        local w = (player.Character or char):GetAttribute("Water") or 0
                        if w >= 85 then break end
                        changeSubState("Drinking")
                    end
                    releaseChar(player.Character or char)
                end
            end
            shared._inCarcassEat = false
            continue
        end

        if food >= 90 then continue end
        if not StartEatCarcass then continue end

        local nearest, nearDist = findNearestCarcass()
        if not nearest then
            -- no carcass found — stay put, try again next tick
            continue
        end

        -- lock
        shared._inCarcassEat = true
        char:SetAttribute("_drinkingToFull", false)

        -- TP to carcass
        local cRoot = nearest:FindFirstChild("HumanoidRootPart") or nearest:FindFirstChildWhichIsA("BasePart", true)
        if not cRoot then shared._inCarcassEat = false continue end

        local cPos = cRoot.Position
        confirmedTP(char, Vector3.new(cPos.X, cPos.Y + 2, cPos.Z), "Carcass")
        task.wait(0.4)

        -- anchor while eating so we don't slide off
        local ancRoot = char:FindFirstChild("HumanoidRootPart")
        if ancRoot then ancRoot.Anchored = true end
        local hum = getHum()
        if hum then hum:ChangeState(Enum.HumanoidStateType.GettingUp) task.wait(0.2) end

        allowSubState(true)
        changeSubState("Eating")
        task.wait(0.3)
        pcall(function() StartEatCarcass:FireServer(nearest) end)

        -- wait for food to start rising (confirm eating registered)
        local startFood = char:GetAttribute("Food") or 0
        local confirm = tick()
        local foodRose = false
        while tick() - confirm < 5 do
            task.wait(0.2)
            pcall(function() StartEatCarcass:FireServer(nearest) end)
            local cc = player.Character if not cc then break end
            if (cc:GetAttribute("Food") or 0) > startFood then foodRose = true break end
        end

        if not foodRose then
            -- carcass didn't register — unanchor and skip
            local cc = player.Character or char
            releaseChar(cc)
            blockSubState = false
            shared._inCarcassEat = false
            continue
        end

        -- drain the carcass until full or stall
        local lastFood = char:GetAttribute("Food") or startFood
        local stall = 0
        while true do
            task.wait(0.5)
            local cc = player.Character if not cc then break end
            local curFood = cc:GetAttribute("Food") or 0
            if curFood >= 95 then break end
            if not nearest.Parent then break end
            if curFood > lastFood then
                lastFood = curFood
                stall = 0
                pcall(function() StartEatCarcass:FireServer(nearest) end)
            else
                stall = stall + 1
                if stall >= 6 then break end  -- carcass exhausted
            end
        end

        -- cleanup
        blockSubState = false
        task.wait(0.3)
        local postChar = player.Character or char
        releaseChar(postChar)

        -- clear flag BEFORE returning TP
        shared._inCarcassEat = false

        -- TP back to growSpawn so next iteration finds a fresh carcass from a known good position
        confirmedTP(postChar, gameConfig.growSpawn, "CarcassReturn")
        task.wait(0.5)
        releaseChar(player.Character or postChar)

        print(string.format("[CarcassLoop] Done. Food=%.0f — back at growSpawn",
            (player.Character or postChar):GetAttribute("Food") or 0))
    end
end)

-- ============================================================
-- AUTO LEAVE TERRAIN
-- ============================================================
task.spawn(function()
    local streak = 0
    while true do
        task.wait()
        if not cfg.AutoLeave then streak = 0 continue end
        local char = getChar() if not char then continue end
        local root = getRoot() if not root then continue end
        if shared._animalTweening then streak = 0 continue end

        local an = getAnimal()
        local isLion = an == "Lion" or an == "Tiger"

        if Animal.IsInsideTerrain() then
            if isLion then
                streak = streak + 1
                if streak >= 5 then
                    streak = 0
                    root.CFrame = CFrame.new(root.Position + Vector3.new(0,8,0))
                end
            else
                streak = 0
                root.CFrame = CFrame.new(root.Position + Vector3.new(0,4,0))
            end
        else
            streak = 0
        end
    end
end)

-- ============================================================
-- AUTO ATTACK
-- ============================================================
local AttackRemote = RS:FindFirstChild("AttackHandlerRemoteEvent")
local SpecialAttackRemote = RS:FindFirstChild("SpecialAttackRemoteEvent_RegularAttack")

task.spawn(function()
    local lastBasic = 0
    local lastSpecial = 0
    local BASIC_CD = 0.6
    local SPECIAL_CD = 1.9
    local HUNT_RANGE = 20

    while true do
        task.wait(0.3)
        if not cfg.AutoAttack then continue end
        if not CARNIVORES[getAnimal()] then continue end
        if shared._inGrowthReset then continue end

        local char = getChar() if not char then continue end
        local root = getRoot() if not root then continue end
        local food = char:GetAttribute("Food") or 100
        if food >= 85 then continue end

        local nearest, nearDist = nil, HUNT_RANGE
        for _, p in Players:GetPlayers() do
            if p == player then continue end
            local pc = p.Character
            if not pc then continue end
            local pr = pc:FindFirstChild("HumanoidRootPart")
            local ph = pc:FindFirstChildOfClass("Humanoid")
            if not pr or not ph then continue end
            if ph.Health <= 0 then continue end
            local d = (root.Position - pr.Position).Magnitude
            if d < nearDist then nearest = ph nearDist = d end
        end

        for _, obj in workspace:GetDescendants() do
            if obj:IsA("Humanoid") and obj.Parent ~= char and obj.Health > 0 then
                local r = obj.Parent:FindFirstChild("HumanoidRootPart")
                if r then
                    local d = (root.Position - r.Position).Magnitude
                    if d < nearDist then nearest = obj nearDist = d end
                end
            end
        end

        if nearest then
            local t = tick()
            if t - lastBasic >= BASIC_CD and AttackRemote then
                pcall(function() AttackRemote:FireServer(nearest) end)
                lastBasic = t
            end
            if t - lastSpecial >= SPECIAL_CD and SpecialAttackRemote then
                pcall(function() SpecialAttackRemote:FireServer(nearest) end)
                lastSpecial = t
            end
        end
    end
end)

-- ============================================================
-- SPEED BOOST
-- ============================================================
task.spawn(function()
    while true do
        task.wait(0.1)
        if not cfg.SpeedBoost then continue end
        local hum = getHum()
        if hum then
            hum.WalkSpeed = 16 * speedMultiplier
        end
    end
end)

-- ============================================================
-- INF STAMINA
-- ============================================================
task.spawn(function()
    while true do
        task.wait(0.1)
        if not cfg.InfStamina then continue end
        local char = getChar()
        if char then pcall(function() char:SetAttribute("Stamina", 100) end) end
    end
end)

-- ============================================================
-- ALWAYS DAYTIME
-- ============================================================
task.spawn(function()
    while true do
        task.wait(1)
        if not cfg.AlwaysDay then continue end
        Lighting.ClockTime = 12
        Lighting.FogEnd = 100000
        Lighting.Brightness = 2
    end
end)

-- ============================================================
-- NIGHT VISION
-- ============================================================
task.spawn(function()
    while true do
        task.wait(1)
        if not cfg.NightVision then continue end
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
    end
end)

-- ============================================================
-- ANTI AFK
-- ============================================================
task.spawn(function()
    player.Idled:Connect(function()
        if not cfg.AntiAfk then return end
        VirtualUser:Button2Down(Vector2.zero, workspace.CurrentCamera.CFrame)
        task.wait(1)
        VirtualUser:Button2Up(Vector2.zero, workspace.CurrentCamera.CFrame)
    end)
    while true do
        task.wait(240)
        if not cfg.AntiAfk then continue end
        local cam = workspace.CurrentCamera
        pcall(function()
            local cf = cam.CFrame
            cam.CFrame = cf * CFrame.Angles(0, math.rad(0.5), 0)
            task.wait(0.1)
            cam.CFrame = cf
        end)
        pcall(function()
            VirtualUser:Button2Down(Vector2.zero, cam.CFrame)
            task.wait(0.1)
            VirtualUser:Button2Up(Vector2.zero, cam.CFrame)
        end)
        pcall(function()
            VirtualUser:KeyDown(0x57)
            task.wait(0.1)
            VirtualUser:KeyUp(0x57)
        end)
    end
end)

-- ============================================================
-- FOOD / WATER ESP
-- ============================================================
local espHighlights = {}

local function clearESP()
    for _, h in espHighlights do pcall(function() h:Destroy() end) end
    espHighlights = {}
end

task.spawn(function()
    while true do
        task.wait(3)
        if not cfg.FoodESP then clearESP() continue end
        clearESP()

        local root = getRoot()
        if not root then continue end

        for _, obj in workspace:GetDescendants() do
            if obj:IsA("BasePart") then
                local n = obj.Name:lower()
                local isFood = n:find("grass") or n:find("plant") or n:find("bush") or n:find("berry") or n:find("meat") or n:find("carcass")
                local isWater = n:find("water") or n:find("pond") or n:find("river")

                if isFood or isWater then
                    local dist = (root.Position - obj.Position).Magnitude
                    if dist < 200 then
                        local h = Instance.new("SelectionBox")
                        h.Adornee = obj
                        h.Color3 = isFood and Color3.fromRGB(80,255,80) or Color3.fromRGB(80,180,255)
                        h.LineThickness = 0.04
                        h.SurfaceTransparency = 0.7
                        h.Parent = workspace
                        table.insert(espHighlights, h)
                    end
                end
            end
        end
    end
end)

-- ============================================================
-- AUTO DAILY REWARD
-- ============================================================
task.spawn(function()
    while true do
        task.wait(5)
        if not cfg.AutoDailyReward then continue end
        local pg = player.PlayerGui
        local dailyGui = pg:FindFirstChild("DailyLoginRewardsScreenGui", true)
        if not dailyGui then continue end
        local claimBtn = dailyGui:FindFirstChild("ClaimButton", true)
        if claimBtn and claimBtn.Visible then
            pcall(function() claimBtn.MouseButton1Click:Fire() end)
            print("[DailyReward] Claimed!")
        end
    end
end)

-- ============================================================
-- AUTO QUEST
-- ============================================================
task.spawn(function()
    while true do
        task.wait(5)
        if not cfg.AutoQuest then continue end
        local pg = player.PlayerGui
        local questGui = pg:FindFirstChild("QuestsScreenGui", true)
        if not questGui then continue end
        for _, btn in questGui:GetDescendants() do
            if (btn:IsA("TextButton") or btn:IsA("ImageButton")) and btn.Name == "ClaimButton" then
                pcall(function() btn.MouseButton1Click:Fire() end)
            end
        end
    end
end)

-- ============================================================
-- SAFETY NET
-- ============================================================
RunService.Heartbeat:Connect(function()
    local char = getChar()
    local root = getRoot()
    if not char or not root then return end
    if root.Position.Y < gameConfig.dangerY then
        pcall(function()
            char:SetPrimaryPartCFrame(CFrame.new(gameConfig.growSpawn))
        end)
        if HandleTP then pcall(function() HandleTP:FireServer() end) end
    end
end)

-- ============================================================
-- TOGGLE GROWTH REMOTE LOOP
-- ============================================================
task.spawn(function()
    while true do
        task.wait(5)
        if (cfg.GrowNew or cfg.GrowExisting) and ToggleGrowth then
            pcall(function() ToggleGrowth:FireServer(true) end)
        end
    end
end)

-- ============================================================
-- GROWTH LOOP
-- ============================================================
task.spawn(function()
    local MAX_SLOTS = 40
    local isLooping = false
    local loopToken = 0
    local currentGrowthName = nil
    local growthCheckReady = false
    local lastGrowth = 0
    local parkingMode = false
    shared._parkingModeActive = false

    local function forceUnlock(reason)
        loopToken = loopToken + 1
        isLooping = false
        shared._inGrowthReset = false
        warn("[GrowthLoop] Unlocked: " .. reason)
    end

    local function withLock(fn)
        if isLooping then return false end
        isLooping = true
        loopToken = loopToken + 1
        local myToken = loopToken
        shared._inGrowthReset = true
        local ok, err = pcall(fn)
        if loopToken == myToken then
            shared._inGrowthReset = false
            isLooping = false
        end
        if not ok then warn("[GrowthLoop] Error: " .. err) end
        return ok
    end

    local function getSlotInfo(char)
        return char:GetAttribute("AnimalName") or "Elephant",
               char:GetAttribute("Gender") or "Female",
               char:GetAttribute("Skin") or "Default"
    end

    local function spawnAndSetup(slotName)
        local ok = pcall(function()
            RS.SpawnAsCharacterRemoteFunction:InvokeServer(slotName)
        end)
        if not ok then return false end
        local waited = 0
        while waited < 10 do
            task.wait(0.2) waited = waited + 0.2
            local ch = player.Character
            if ch and ch:FindFirstChild("HumanoidRootPart") then return true end
        end
        return false
    end

    local function resetToMenu()
        pcall(function() RS.CustomCharacterResetRemoteFunction:InvokeServer() end)
        task.wait(2)
    end

    local function teleportAndEnable(charName)
        local waited = 0
        local char
        while waited < 15 do
            task.wait(0.2) waited = waited + 0.2
            local ch = player.Character
            if ch and ch:FindFirstChild("HumanoidRootPart") then
                local cn = ch:GetAttribute("CharacterName")
                if cn == charName or waited >= 8 then char = ch break end
            end
        end
        if not char then return end
        task.wait(1.5)
        char = player.Character or char

        local animal = getSlotInfo(char)
        local isCarn = CARNIVORES[animal] == true

        confirmedTP(char, gameConfig.growSpawn, "GrowSpawn")
        task.wait(7)

        local function toggle(state, lbl)
            if not isCarn then
                if shared._autoEatChecked then shared._autoEatChecked(state) end
            else
                if shared._autoEatCarcassChecked then shared._autoEatCarcassChecked(state) end
            end
            if shared._autoDrinkChecked then shared._autoDrinkChecked(state) end
            if not isCarn then cfg.AutoEat = state else cfg.AutoEatCarcass = state end
            cfg.AutoDrink = state
        end

        toggle(false, "OFF") task.wait(1)
        toggle(true,  "ON")  task.wait(1)
        toggle(false, "OFF") task.wait(1)
        toggle(true,  "ON")
    end

    local function doGrowthReset()
        withLock(function()
            cfg.AutoEat = false cfg.AutoDrink = false
            local char = player.Character if not char then return end
            local animal, gender, skin = getSlotInfo(char)
            local newName = "Slot" .. math.floor(tick())

            confirmedTP(char, gameConfig.warSpawn, "WarSpawn")
            resetToMenu()

            pcall(function()
                RS.CreateNewCharacterRemoteFunction:InvokeServer(newName, animal, gender, skin)
            end)
            task.wait(2)

            if not spawnAndSetup(newName) then return end
            teleportAndEnable(newName)
            currentGrowthName = newName
            shared._currentGrowthName = newName
        end)
    end

    local function doExistingSlotCycle()
        withLock(function()
            cfg.AutoEat = false cfg.AutoDrink = false
            local replication = shared._playerDataReplication
            local nextSlot = nil

            if replication then
                local ok, list = pcall(function() return replication.GetKeyData("SavedCharacters") end)
                if ok and type(list) == "table" then
                    local current = currentGrowthName
                    local found = false
                    for _, entry in list do
                        if type(entry) == "table" and entry.CharacterName then
                            if found then nextSlot = entry.CharacterName break end
                            if entry.CharacterName == current then found = true end
                        end
                    end
                    if not nextSlot and #list > 0 then
                        nextSlot = list[1].CharacterName
                    end
                end
            end

            if not nextSlot then
                warn("[GrowthLoop] No saved slot found")
                return
            end

            local char = player.Character
            if char then confirmedTP(char, gameConfig.warSpawn, "WarSpawn") end
            resetToMenu()

            if not spawnAndSetup(nextSlot) then return end
            task.wait(1)

            local ch = player.Character
            if ch then
                local g = waitForAttr(ch, "GrowthPercentage", 8)
                if g and g >= 1 then
                    print("[GrowthLoop] Slot", nextSlot, "already 100%")
                    return
                end
            end

            teleportAndEnable(nextSlot)
            currentGrowthName = nextSlot
            shared._currentGrowthName = nextSlot
        end)
    end

    task.spawn(function()
        local ch = player.Character
        if ch then
            local name = waitForAttr(ch, "CharacterName", 8)
            if name then
                currentGrowthName = name
                shared._currentGrowthName = name
            end
        end
    end)

    local function armCheck(char)
        growthCheckReady = false
        lastGrowth = 0
        task.spawn(function()
            local v = waitForAttr(char, "GrowthPercentage", 15)
            if v then
                lastGrowth = v >= 1 and 0 or v
                growthCheckReady = true
            end
        end)
    end

    task.spawn(function()
        local ch = player.Character
        if ch then armCheck(ch) end
    end)

    player.CharacterAdded:Connect(function(ch)
        lastGrowth = 0
        growthCheckReady = false
        armCheck(ch)
        task.spawn(function()
            local name = waitForAttr(ch, "CharacterName", 8)
            if name then
                currentGrowthName = name
                shared._currentGrowthName = name
            end
        end)
    end)

    RunService.Heartbeat:Connect(function()
        if isLooping or not growthCheckReady then return end
        if shared._inCarcassEat then return end
        local char = player.Character if not char then return end
        local growth = char:GetAttribute("GrowthPercentage") if not growth then return end

        if growth >= 1 and lastGrowth >= 0.9 then
            if cfg.GrowExisting then task.spawn(doExistingSlotCycle)
            elseif cfg.GrowNew then task.spawn(doGrowthReset) end
            return
        end

        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health <= 0 and not isLooping then
            task.wait(2)
            if currentGrowthName then
                withLock(function()
                    spawnAndSetup(currentGrowthName)
                end)
            end
            return
        end

        lastGrowth = growth
    end)

    task.spawn(function()
        while true do
            task.wait(15)
            local ch = player.Character
            local hasChar = ch and ch:FindFirstChild("HumanoidRootPart") ~= nil
            if not hasChar and (cfg.GrowNew or cfg.GrowExisting) and not isLooping then
                warn("[Watchdog] No character — recovering")
                if currentGrowthName then
                    withLock(function()
                        spawnAndSetup(currentGrowthName)
                        local newCh = player.Character
                        if newCh then teleportAndEnable(currentGrowthName) end
                    end)
                end
            end
        end
    end)

    shared._setGrowNewSlots = function(v) cfg.GrowNew = v end
    shared._setGrowExistingSlots = function(v) cfg.GrowExisting = v end
    shared._setParkingMode = function(v)
        parkingMode = v
        shared._parkingModeActive = v
        cfg.PassiveCoins = v
    end

    print("[GrowthLoop] Started — " .. gameConfig.name)
end)

-- ============================================================
-- UI  (redesigned — clean, dark, no AI slop)
-- ============================================================
if CoreGui:FindFirstChild("MegaScriptGui") then
    CoreGui:FindFirstChild("MegaScriptGui"):Destroy()
end

local gui = Instance.new("ScreenGui")
gui.Name = "MegaScriptGui"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
gui.Parent = CoreGui

-- palette
local C = {
    bg        = Color3.fromRGB(10, 10, 13),
    panel     = Color3.fromRGB(15, 15, 20),
    row       = Color3.fromRGB(20, 20, 27),
    rowHover  = Color3.fromRGB(26, 26, 34),
    border    = Color3.fromRGB(35, 35, 46),
    accent    = Color3.fromRGB(94, 190, 130),
    accentDim = Color3.fromRGB(35, 100, 58),
    red       = Color3.fromRGB(190, 60, 60),
    redDim    = Color3.fromRGB(80, 25, 25),
    textHi    = Color3.fromRGB(220, 220, 220),
    textMid   = Color3.fromRGB(140, 140, 148),
    textLow   = Color3.fromRGB(70, 70, 80),
    yellow    = Color3.fromRGB(210, 175, 60),
}

local win = Instance.new("Frame")
win.Name = "Win"
win.Size = UDim2.new(0, 260, 0, 580)
win.Position = UDim2.new(0, 12, 0.05, 0)
win.BackgroundColor3 = C.bg
win.BorderSizePixel = 0
win.Active = true
win.Draggable = true
win.Parent = gui
Instance.new("UICorner", win).CornerRadius = UDim.new(0, 8)

-- thin left accent stripe
local stripe = Instance.new("Frame")
stripe.Size = UDim2.new(0, 2, 1, -16)
stripe.Position = UDim2.new(0, 0, 0, 8)
stripe.BackgroundColor3 = C.accent
stripe.BorderSizePixel = 0
stripe.Parent = win
Instance.new("UICorner", stripe).CornerRadius = UDim.new(1, 0)

-- header
local hdr = Instance.new("Frame")
hdr.Size = UDim2.new(1, 0, 0, 38)
hdr.BackgroundColor3 = C.panel
hdr.BorderSizePixel = 0
hdr.Parent = win
Instance.new("UICorner", hdr).CornerRadius = UDim.new(0, 8)

local hdrTitle = Instance.new("TextLabel")
hdrTitle.Size = UDim2.new(1, -60, 1, 0)
hdrTitle.Position = UDim2.new(0, 12, 0, 0)
hdrTitle.BackgroundTransparency = 1
hdrTitle.Text = "MEGA SCRIPT  v2.1"
hdrTitle.TextColor3 = C.textHi
hdrTitle.Font = Enum.Font.GothamBold
hdrTitle.TextSize = 12
hdrTitle.TextXAlignment = Enum.TextXAlignment.Left
hdrTitle.Parent = hdr

local hdrGame = Instance.new("TextLabel")
hdrGame.Size = UDim2.new(0, 100, 1, 0)
hdrGame.Position = UDim2.new(1, -110, 0, 0)
hdrGame.BackgroundTransparency = 1
hdrGame.Text = gameConfig.name
hdrGame.TextColor3 = C.accent
hdrGame.Font = Enum.Font.Gotham
hdrGame.TextSize = 10
hdrGame.TextXAlignment = Enum.TextXAlignment.Right
hdrGame.Parent = hdr

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0, 22, 0, 22)
minBtn.Position = UDim2.new(1, -28, 0, 8)
minBtn.BackgroundColor3 = C.border
minBtn.Text = "−"
minBtn.TextColor3 = C.textMid
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 13
minBtn.BorderSizePixel = 0
minBtn.Parent = hdr
Instance.new("UICorner", minBtn).CornerRadius = UDim.new(0, 4)

-- scroll content
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, 0, 1, -42)
scroll.Position = UDim2.new(0, 0, 0, 40)
scroll.BackgroundTransparency = 1
scroll.ScrollBarThickness = 2
scroll.ScrollBarImageColor3 = C.accent
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.BorderSizePixel = 0
scroll.Parent = win

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 2)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = scroll

local scrollPad = Instance.new("UIPadding")
scrollPad.PaddingLeft = UDim.new(0, 8)
scrollPad.PaddingRight = UDim.new(0, 8)
scrollPad.PaddingTop = UDim.new(0, 6)
scrollPad.PaddingBottom = UDim.new(0, 6)
scrollPad.Parent = scroll

-- minimize
local minimized = false
local FULL_H = 580
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    scroll.Visible = not minimized
    win.Size = minimized and UDim2.new(0, 260, 0, 40) or UDim2.new(0, 260, 0, FULL_H)
    minBtn.Text = minimized and "+" or "−"
end)

-- section header
local _order = 0
local function nextOrder(n) _order = _order + (n or 1) return _order end

local function makeSection(label)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 18)
    f.BackgroundTransparency = 1
    f.LayoutOrder = nextOrder(10)
    f.Parent = scroll

    local line = Instance.new("Frame")
    line.Size = UDim2.new(1, 0, 0, 1)
    line.Position = UDim2.new(0, 0, 1, -1)
    line.BackgroundColor3 = C.border
    line.BorderSizePixel = 0
    line.Parent = f

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = C.textLow
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 9
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = f
    return f
end

-- toggle row
local function makeToggle(label, cfgKey)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 28)
    row.BackgroundColor3 = C.row
    row.BorderSizePixel = 0
    row.LayoutOrder = nextOrder()
    row.Parent = scroll
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.75, 0, 1, 0)
    lbl.Position = UDim2.new(0, 10, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = C.textHi
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 11
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    -- pill toggle
    local pillBg = Instance.new("Frame")
    pillBg.Size = UDim2.new(0, 36, 0, 16)
    pillBg.Position = UDim2.new(1, -44, 0.5, -8)
    pillBg.BackgroundColor3 = cfg[cfgKey] and C.accentDim or C.redDim
    pillBg.BorderSizePixel = 0
    pillBg.Parent = row
    Instance.new("UICorner", pillBg).CornerRadius = UDim.new(1, 0)

    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0, 12, 0, 12)
    dot.Position = cfg[cfgKey] and UDim2.new(1, -14, 0.5, -6) or UDim2.new(0, 2, 0.5, -6)
    dot.BackgroundColor3 = cfg[cfgKey] and C.accent or C.red
    dot.BorderSizePixel = 0
    dot.Parent = pillBg
    Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

    local hitbox = Instance.new("TextButton")
    hitbox.Size = UDim2.new(1, 0, 1, 0)
    hitbox.BackgroundTransparency = 1
    hitbox.Text = ""
    hitbox.Parent = row

    hitbox.MouseButton1Click:Connect(function()
        cfg[cfgKey] = not cfg[cfgKey]
        local on = cfg[cfgKey]
        pillBg.BackgroundColor3 = on and C.accentDim or C.redDim
        dot.BackgroundColor3 = on and C.accent or C.red
        TweenService:Create(dot, TweenInfo.new(0.12), {
            Position = on and UDim2.new(1, -14, 0.5, -6) or UDim2.new(0, 2, 0.5, -6)
        }):Play()

        if cfgKey == "GrowNew"          and shared._setGrowNewSlots      then shared._setGrowNewSlots(on) end
        if cfgKey == "GrowExisting"     and shared._setGrowExistingSlots  then shared._setGrowExistingSlots(on) end
        if cfgKey == "PassiveCoins"     and shared._setParkingMode        then shared._setParkingMode(on) end
        if cfgKey == "AutoEat"          and shared._autoEatChecked        then shared._autoEatChecked(on) end
        if cfgKey == "AutoDrink"        and shared._autoDrinkChecked      then shared._autoDrinkChecked(on) end
        if cfgKey == "AutoEatCarcass"   and shared._autoEatCarcassChecked then shared._autoEatCarcassChecked(on) end
    end)

    return row
end

-- slider
local function makeSlider(label, min, max, current, onChange)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 36)
    row.BackgroundColor3 = C.row
    row.BorderSizePixel = 0
    row.LayoutOrder = nextOrder()
    row.Parent = scroll
    Instance.new("UICorner", row).CornerRadius = UDim.new(0, 5)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.65, 0, 0, 14)
    lbl.Position = UDim2.new(0, 10, 0, 5)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.TextColor3 = C.textHi
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 10
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local valLbl = Instance.new("TextLabel")
    valLbl.Size = UDim2.new(0.3, 0, 0, 14)
    valLbl.Position = UDim2.new(0.7, 0, 0, 5)
    valLbl.BackgroundTransparency = 1
    valLbl.Text = tostring(current) .. "x"
    valLbl.TextColor3 = C.accent
    valLbl.Font = Enum.Font.GothamBold
    valLbl.TextSize = 10
    valLbl.TextXAlignment = Enum.TextXAlignment.Right
    valLbl.Parent = row

    local trackBg = Instance.new("Frame")
    trackBg.Size = UDim2.new(1, -20, 0, 4)
    trackBg.Position = UDim2.new(0, 10, 0, 26)
    trackBg.BackgroundColor3 = C.border
    trackBg.BorderSizePixel = 0
    trackBg.Parent = row
    Instance.new("UICorner", trackBg).CornerRadius = UDim.new(1, 0)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new((current-min)/(max-min), 0, 1, 0)
    fill.BackgroundColor3 = C.accent
    fill.BorderSizePixel = 0
    fill.Parent = trackBg
    Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

    local handle = Instance.new("TextButton")
    handle.Size = UDim2.new(0, 12, 0, 12)
    handle.Position = UDim2.new((current-min)/(max-min), -6, 0.5, -6)
    handle.BackgroundColor3 = C.textHi
    handle.Text = ""
    handle.BorderSizePixel = 0
    handle.ZIndex = 5
    handle.Parent = trackBg
    Instance.new("UICorner", handle).CornerRadius = UDim.new(1, 0)

    local dragging = false
    handle.MouseButton1Down:Connect(function() dragging = true end)
    UserInput.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
    UserInput.InputChanged:Connect(function(i)
        if not dragging or i.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        local rel = math.clamp((i.Position.X - trackBg.AbsolutePosition.X) / trackBg.AbsoluteSize.X, 0, 1)
        local val = math.floor(min + rel * (max - min) + 0.5)
        fill.Size = UDim2.new(rel, 0, 1, 0)
        handle.Position = UDim2.new(rel, -6, 0.5, -6)
        valLbl.Text = tostring(val) .. "x"
        onChange(val)
    end)
end

-- build sections
makeSection("EAT / DRINK")
makeToggle("Auto Eat",              "AutoEat")
makeToggle("Auto Eat Carcass",      "AutoEatCarcass")
makeToggle("Auto Drink",            "AutoDrink")
makeToggle("Go To Nearest Source",  "GoNearest")

makeSection("MISC")
makeToggle("Leave Terrain",         "AutoLeave")
makeToggle("Inf Stamina",           "InfStamina")
makeToggle("Always Day",            "AlwaysDay")
makeToggle("Night Vision",          "NightVision")
makeToggle("Anti AFK",              "AntiAfk")
makeToggle("Food / Water ESP",      "FoodESP")
makeToggle("Daily Reward",          "AutoDailyReward")
makeToggle("Quest Claim",           "AutoQuest")

makeSection("COMBAT")
makeToggle("Auto Attack",           "AutoAttack")
makeToggle("Speed Boost",           "SpeedBoost")
makeSlider("Speed Multiplier", 1, 5, speedMultiplier, function(v)
    speedMultiplier = v
end)

makeSection("GROWTH")
makeToggle("New Slots",             "GrowNew")
makeToggle("Existing Slots",        "GrowExisting")
makeToggle("Passive Coins",         "PassiveCoins")

-- ============================================================
-- HUD (top right)
-- ============================================================
if CoreGui:FindFirstChild("MegaScriptHUD") then
    CoreGui:FindFirstChild("MegaScriptHUD"):Destroy()
end

local hud = Instance.new("ScreenGui")
hud.Name = "MegaScriptHUD"
hud.ResetOnSpawn = false
hud.ZIndexBehavior = Enum.ZIndexBehavior.Global
hud.Parent = CoreGui

local hudF = Instance.new("Frame")
hudF.Size = UDim2.new(0, 190, 0, 82)
hudF.Position = UDim2.new(1, -200, 0, 10)
hudF.BackgroundColor3 = C.bg
hudF.BackgroundTransparency = 0.08
hudF.BorderSizePixel = 0
hudF.Parent = hud
Instance.new("UICorner", hudF).CornerRadius = UDim.new(0, 6)

local hudStripe = Instance.new("Frame")
hudStripe.Size = UDim2.new(0, 2, 1, -12)
hudStripe.Position = UDim2.new(0, 0, 0, 6)
hudStripe.BackgroundColor3 = C.accent
hudStripe.BorderSizePixel = 0
hudStripe.Parent = hudF
Instance.new("UICorner", hudStripe).CornerRadius = UDim.new(1, 0)

local function hLine(y, sz, bold, col)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, -14, 0, sz + 2)
    l.Position = UDim2.new(0, 10, 0, y)
    l.BackgroundTransparency = 1
    l.TextColor3 = col or C.textHi
    l.TextSize = sz
    l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextTruncate = Enum.TextTruncate.AtEnd
    l.Parent = hudF
    return l
end

local hudSlot   = hLine(5,  11, true,  C.textHi)
local hudGrowth = hLine(21, 10, false, C.accent)
local hudStats  = hLine(36, 9,  false, C.textMid)
local hudMode   = hLine(51, 8,  false, C.textLow)

local barBg = Instance.new("Frame")
barBg.Size = UDim2.new(1, -20, 0, 3)
barBg.Position = UDim2.new(0, 10, 0, 68)
barBg.BackgroundColor3 = C.border
barBg.BorderSizePixel = 0
barBg.Parent = hudF
Instance.new("UICorner", barBg).CornerRadius = UDim.new(1, 0)

local barFill = Instance.new("Frame")
barFill.Size = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = C.accent
barFill.BorderSizePixel = 0
barFill.Parent = barBg
Instance.new("UICorner", barFill).CornerRadius = UDim.new(1, 0)

task.spawn(function()
    while true do
        task.wait(0.5)
        local ch = player.Character
        local growth = ch and ch:GetAttribute("GrowthPercentage") or 0
        local food   = ch and ch:GetAttribute("Food") or 0
        local water  = ch and ch:GetAttribute("Water") or 0
        local animal = getAnimal()
        local slot   = shared._currentGrowthName or "—"
        local pct    = math.floor(growth * 100)

        hudSlot.Text = slot .. "  ·  " .. animal
        hudGrowth.Text = "Growth  " .. pct .. "%"
        hudStats.Text = "🍖 " .. math.floor(food) .. "%   💧 " .. math.floor(water) .. "%"

        if pct < 50 then
            hudGrowth.TextColor3 = Color3.fromRGB(200, pct * 3, 60)
        else
            hudGrowth.TextColor3 = Color3.fromRGB((100 - pct) * 3, 185, 80)
        end

        barFill.Size = UDim2.new(math.clamp(growth, 0, 1), 0, 1, 0)

        local mode, col
        if cfg.PassiveCoins then
            mode = "passive coins"
            col = C.yellow
        elseif cfg.GrowExisting then
            mode = "existing slots"
            col = C.accent
        elseif cfg.GrowNew then
            mode = "new slots"
            col = Color3.fromRGB(200, 130, 60)
        elseif cfg.AutoAttack then
            mode = "combat"
            col = C.red
        else
            mode = "idle"
            col = C.textLow
        end
        hudMode.Text = mode
        hudMode.TextColor3 = col
        hudStripe.BackgroundColor3 = col
    end
end)

print("[MEGA SCRIPT v2.1] Loaded — " .. gameConfig.name)
