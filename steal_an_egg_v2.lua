--[[
  STEAL AN EGG  -  v2 (auto-detect version)
  1. Stand at YOUR base, then execute.  (That spot = home.)
  2. Watch the console (F9). It prints everything it finds and does.
  3. Stop:  getgenv().SAE = false

  Features
   - Picks the best egg by rarity/value, teleports there, grabs it
   - Teleports home the instant you hold it (spam-TP so nobody can steal it)
   - Auto places egg on a free nest at your base
   - Auto hatches ready eggs, auto equips best pets
   - Anti-AFK, auto respawn handling
   - Auto-detects prompts/remotes by keyword, so it needs no game-specific names
   - Run with getgenv().SAE_DEBUG = true first to see what it detects
]]

getgenv().SAE = true
if getgenv().SAE_DEBUG == nil then getgenv().SAE_DEBUG = true end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local lp = Players.LocalPlayer

------------------------------------------------------------ CONFIG
local CFG = {
    Rarity = { "secret", "divine", "mythic", "legendary", "epic", "rare", "uncommon", "common" },
    StealWords = { "steal", "grab", "take", "pick", "collect egg", "claim" },
    PlaceWords = { "place", "deposit", "put", "plant", "nest", "incubat" },
    HatchWords = { "hatch", "open", "claim pet", "collect" },
    HomeRadius = 90,       -- prompts within this distance of home count as "my base"
    MinStealDist = 120,    -- eggs farther than this from home are steal targets
    Tick = 0.3,
    EquipEvery = 20,
    MaxPerRarity = nil,    -- set to e.g. "legendary" to ignore anything below it
}
------------------------------------------------------------

local function log(...) if getgenv().SAE_DEBUG then print("[SAE]", ...) end end
local function lower(s) return tostring(s or ""):lower() end
local function has(text, words)
    text = lower(text)
    for _, w in ipairs(words) do if text:find(w, 1, true) then return true end end
    return false
end

local function char() return lp.Character or lp.CharacterAdded:Wait() end
local function root() return char():WaitForChild("HumanoidRootPart") end

local HOME = root().CFrame
log("Home saved at", HOME.Position)

-- anti afk
lp.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

-- respawn: put home back to base
lp.CharacterAdded:Connect(function(c)
    local r = c:WaitForChild("HumanoidRootPart", 10)
    task.wait(1)
    if r then r.CFrame = HOME end
end)

------------------------------------------------------------ helpers
local function posOf(inst)
    local p = inst
    while p and p ~= workspace do
        if p:IsA("BasePart") then return p.Position end
        if p:IsA("Model") then return p:GetPivot().Position end
        p = p.Parent
    end
end

local function context(inst, depth)
    local t = { lower(inst.Name) }
    local p = inst.Parent
    for _ = 1, depth or 3 do
        if not p or p == workspace then break end
        table.insert(t, lower(p.Name))
        for k, v in pairs(p:GetAttributes()) do table.insert(t, lower(k) .. " " .. lower(v)) end
        p = p.Parent
    end
    return table.concat(t, " ")
end

local function promptText(pp)
    return lower(pp.ActionText) .. " " .. lower(pp.ObjectText) .. " " .. context(pp, 2)
end

local function rarityScore(text)
    for i, r in ipairs(CFG.Rarity) do
        if text:find(r, 1, true) then return (#CFG.Rarity - i + 1) end
    end
    return 0
end

local function valueScore(pp)
    local best = 0
    local p = pp.Parent
    for _ = 1, 3 do
        if not p then break end
        for k, v in pairs(p:GetAttributes()) do
            local kk = lower(k)
            if type(v) == "number" and (kk:find("price") or kk:find("value") or kk:find("size") or kk:find("tier") or kk:find("income")) then
                if v > best then best = v end
            end
        end
        p = p.Parent
    end
    return best
end

local function allPrompts()
    local out = {}
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Enabled then table.insert(out, d) end
    end
    return out
end

local function dist(a, b) return (a - b).Magnitude end

local function tpHome() root().CFrame = HOME end

local function holdingEgg()
    local c = char()
    for _, d in ipairs(c:GetDescendants()) do
        if (d:IsA("Tool") or d:IsA("Model")) and lower(d.Name):find("egg") then return d end
    end
    for _, d in ipairs(lp.Backpack:GetChildren()) do
        if d:IsA("Tool") and lower(d.Name):find("egg") then return d end
    end
    for k, v in pairs(c:GetAttributes()) do
        if lower(k):find("egg") and v then return true end
    end
end

local function press(pp)
    pp.HoldDuration = 0
    pp.RequiresLineOfSight = false
    pp.MaxActivationDistance = math.max(pp.MaxActivationDistance, 20)
    if fireproximityprompt then fireproximityprompt(pp) end
end

------------------------------------------------------------ remotes
local remoteCache = {}
local function remoteFor(words)
    local key = table.concat(words, ",")
    if remoteCache[key] then return remoteCache[key] end
    for _, d in ipairs(RS:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            if has(d.Name, words) then
                remoteCache[key] = d
                log("Remote matched", key, "->", d:GetFullName())
                return d
            end
        end
    end
end

local function fireRemote(r, ...)
    if not r then return false end
    local args = { ... }
    local ok = pcall(function()
        if r:IsA("RemoteEvent") then r:FireServer(unpack(args)) else r:InvokeServer(unpack(args)) end
    end)
    return ok
end

local function clickGui(words)
    local pg = lp:FindFirstChild("PlayerGui")
    if not pg then return false end
    for _, d in ipairs(pg:GetDescendants()) do
        if (d:IsA("TextButton") or d:IsA("ImageButton")) and d.Visible then
            local txt = d:IsA("TextButton") and d.Text or ""
            if has(txt .. " " .. d.Name, words) then
                pcall(function()
                    if firesignal then
                        firesignal(d.MouseButton1Click)
                        firesignal(d.Activated)
                    end
                end)
                return true
            end
        end
    end
    return false
end

------------------------------------------------------------ actions
local function findBestEgg()
    local best, bestScore
    for _, pp in ipairs(allPrompts()) do
        local pos = posOf(pp)
        if pos and dist(pos, HOME.Position) > CFG.MinStealDist then
            local txt = promptText(pp)
            if has(txt, CFG.StealWords) and txt:find("egg") then
                local rs = rarityScore(txt)
                local score = rs * 1e9 + valueScore(pp)
                if not bestScore or score > bestScore then best, bestScore = pp, score end
            end
        end
    end
    return best
end

local function stealBest()
    local pp = findBestEgg()
    if not pp then return false end
    local pos = posOf(pp)
    log("Targeting:", pp:GetFullName())
    root().CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
    for _ = 1, 15 do
        press(pp)
        task.wait(0.05)
        if holdingEgg() then
            for _ = 1, 10 do tpHome() task.wait() end -- spam TP so it sticks
            log("Egg secured, back home")
            return true
        end
    end
    tpHome()
    return false
end

local function placeEgg()
    if not holdingEgg() then return end
    -- 1) try nest prompts at my base
    for _, pp in ipairs(allPrompts()) do
        local pos = posOf(pp)
        if pos and dist(pos, HOME.Position) < CFG.HomeRadius then
            local txt = promptText(pp)
            if has(txt, CFG.PlaceWords) and not has(txt, CFG.HatchWords) then
                root().CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
                press(pp)
                task.wait(0.15)
                if not holdingEgg() then log("Placed egg") tpHome() return end
            end
        end
    end
    -- 2) try remote
    local r = remoteFor({ "place", "deposit", "plant" })
    local t = holdingEgg()
    if r then fireRemote(r, typeof(t) == "Instance" and t.Name or nil) end
    -- 3) try activating the tool
    if typeof(t) == "Instance" and t:IsA("Tool") then
        t.Parent = char()
        pcall(function() t:Activate() end)
    end
    tpHome()
end

local function hatchAll()
    for _, pp in ipairs(allPrompts()) do
        local pos = posOf(pp)
        if pos and dist(pos, HOME.Position) < CFG.HomeRadius then
            local txt = promptText(pp)
            if has(txt, CFG.HatchWords) and not has(txt, CFG.PlaceWords) then
                press(pp)
            end
        end
    end
    fireRemote(remoteFor({ "hatch", "openegg" }))
end

local function equipBest()
    local r = remoteFor({ "equipbest", "equip_best", "bestpet", "equipbestpets" })
    if not fireRemote(r) then clickGui({ "equip best", "equipbest" }) end
end

------------------------------------------------------------ loops
-- bodyguard: if an egg is held and we're away from home, snap back
RunService.Heartbeat:Connect(function()
    if getgenv().SAE and holdingEgg() then
        local r = char():FindFirstChild("HumanoidRootPart")
        if r and dist(r.Position, HOME.Position) > 25 then r.CFrame = HOME end
    end
end)

-- hatch loop
task.spawn(function()
    while getgenv().SAE do
        pcall(hatchAll)
        task.wait(2)
    end
end)

-- equip loop
task.spawn(function()
    while getgenv().SAE do
        pcall(equipBest)
        task.wait(CFG.EquipEvery)
    end
end)

-- main loop
task.spawn(function()
    while getgenv().SAE do
        local ok, err = pcall(function()
            if holdingEgg() then
                placeEgg()
            else
                if stealBest() then
                    task.wait(0.2)
                    placeEgg()
                    pcall(hatchAll)
                    pcall(equipBest)
                end
            end
        end)
        if not ok then log("error:", err) end
        task.wait(CFG.Tick)
    end
end)

log("Running. getgenv().SAE = false to stop. Set getgenv().SAE_DEBUG = false to silence.")
