--[[
    NetErrror Mobile Suite
    Single-file mobile HUD + client suite (Luau).
    UI strings: Russian. Identifiers/comments: English.
]]

-- Guard: fully unload a previous instance before starting a new one.
local CLEANUP_KEY = "NETRRROR_MOBILE_SUITE"
if getgenv and type(getgenv) == "function" then
    local previousInstance = getgenv()[CLEANUP_KEY]
    if previousInstance and type(previousInstance.unload) == "function" then
        pcall(previousInstance.unload)
    end
end

-- Luraph compatibility stubs for development bundles.
if loadstring then
    pcall(loadstring, "getfenv().LPH_NO_VIRTUALIZE = function(...) return ... end")
end

-- Services.
local playersService = game:GetService("Players")
local runService = game:GetService("RunService")
local tweenService = game:GetService("TweenService")
local userInputService = game:GetService("UserInputService")
local guiService = game:GetService("GuiService")
local lightingService = game:GetService("Lighting")
local httpService = game:GetService("HttpService")
local workspaceService = workspace

local localPlayer = playersService.LocalPlayer

local virtualUserService = nil
pcall(function()
    virtualUserService = game:GetService("VirtualUser")
end)

local virtualInputService = nil
pcall(function()
    virtualInputService = game:GetService("VirtualInputManager")
end)

-- Constants.
local CONFIG_FILENAME = "NetErrror_MobileSuite.json"
local DRAG_THRESHOLD = 10
local BASE_WALK_SPEED = 16
local COMBAT_MAX_RANGE = 500
local AURA_FAIL_LIMIT = 12
local AURA_SUSPEND_SECONDS = 5
local ESP_SMOOTH_RATE = 14
local SONIC_CYAN = Color3.fromRGB(96, 226, 255)
local HEALTH_COLOR_LOW = Color3.fromRGB(255, 94, 126)
local HEALTH_COLOR_HIGH = Color3.fromRGB(110, 230, 120)
local UI_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

local COLORS = {
    bgMain = Color3.fromRGB(13, 11, 20),
    bgPanel = Color3.fromRGB(23, 20, 33),
    bgSecondary = Color3.fromRGB(33, 27, 48),
    accentMain = Color3.fromRGB(155, 109, 255),
    accentSecondary = Color3.fromRGB(116, 71, 216),
    textPrimary = Color3.fromRGB(244, 240, 255),
    textSecondary = Color3.fromRGB(152, 144, 168),
    borderColor = Color3.fromRGB(48, 40, 64),
    danger = Color3.fromRGB(255, 94, 126),
}

local FONTS = {
    medium = Enum.Font.GothamMedium,
    semibold = Enum.Font.GothamSemibold,
    bold = Enum.Font.GothamBold,
    black = Enum.Font.GothamBlack,
}

-- Default configuration (autosaved as JSON, colors/enum items are never stored).
local defaultConfig = {
    speedEnabled = false, speedValue = 22, antiReset = false,
    jumpPowerEnabled = false, jumpPowerValue = 60, infiniteJump = false,
    flyEnabled = false, flySpeed = 60, noclipEnabled = false,
    aimEnabled = false, aimSmoothness = 8, aimFOV = 120, aimShowFOV = true,
    aimPrediction = 0.3, aimPart = "Head", aimWallCheck = true, aimIgnoreTeam = true,
    aimTargetLock = false, aimAutoAttack = false, aimHardTap = false, aimNoRecoil = false,
    hitboxEnabled = false, hitboxSize = 8,
    auraEnabled = false, auraMethod = "activate", auraRange = 14, auraInterval = 0.25,
    orbitEnabled = false, orbitRadius = 7, orbitSpeed = 1.2,
    espEnabled = false, espRange = 500, espTracers = false, espOffscreen = true,
    espHealth = true, espNames = true,
    vfxEnabled = true, vfxIntensity = 1,
    trapImmunity = false, antiVoidEnabled = true, deadBlock = false,
    fullbright = false, antiAFK = false, observerBadge = true,
    qaPins = { speed = true, fly = true, aim = false, aura = false },
    qaPositions = {},
    floatPosition = { x = 0.86, y = 0.78 },
}

local config = {}

local function deepMergeConfig(target, source)
    for key, defaultValue in pairs(target) do
        local loadedValue = source[key]
        if typeof(defaultValue) == "table" then
            if typeof(loadedValue) == "table" then
                for subKey, subDefault in pairs(defaultValue) do
                    local loadedSub = loadedValue[subKey]
                    if typeof(loadedSub) == typeof(subDefault) then
                        target[key][subKey] = loadedSub
                    end
                end
            end
        elseif typeof(loadedValue) == typeof(defaultValue) then
            target[key] = loadedValue
        end
    end
end

do
    for key, value in pairs(defaultConfig) do
        if typeof(value) == "table" then
            local copy = {}
            for subKey, subValue in pairs(value) do
                copy[subKey] = subValue
            end
            config[key] = copy
        else
            config[key] = value
        end
    end
    pcall(function()
        if isfile and readfile and isfile(CONFIG_FILENAME) then
            deepMergeConfig(config, httpService:JSONDecode(readfile(CONFIG_FILENAME)))
        end
    end)
end

local configSavePending = false
local function saveConfigNow()
    if configSavePending or state and state.unloaded then return end
    configSavePending = true
    task.delay(0.5, function()
        configSavePending = false
        pcall(function()
            writefile(CONFIG_FILENAME, httpService:JSONEncode(config))
        end)
    end)
end

-- State.
local state = {
    camera = workspaceService.CurrentCamera,
    character = localPlayer and localPlayer.Character or nil,
    humanoid = nil,
    hrp = nil,
    baseFieldOfView = 70,
    smoothedWalkSpeed = BASE_WALK_SPEED,
    flyVelocity = Vector3.zero,
    flyLinearVelocity = nil,
    flyAlignOrientation = nil,
    flyUpHeldUntil = 0,
    flyDownHeld = false,
    orbitAngle = 0,
    aimTarget = nil,
    lastAutoAttackTime = 0,
    auraSwingTimer = 0,
    auraFailCount = 0,
    auraSuspendedUntil = 0,
    auraCycleIndex = 0,
    auraFlashUntil = 0,
    speedEmitter = nil,
    flyEmitter = nil,
    lastSafePosition = nil,
    lastViewport = nil,
    menuOpen = false,
    unloaded = false,
    loaded = false,
}

local combatCandidates = {}
local noclipCache = {}
local touchImmunityCache = {}
local hitboxBackups = {}
local espEntries = {}
local lightingBackup = nil
local cachedVoidLimit = nil

-- ============ ResourceManager (Maid) ============
local ResourceManager = {}
ResourceManager.__index = ResourceManager

function ResourceManager.new()
    return setmetatable({
        tagBuckets = {},
        resourceTags = {},
        destroyed = false,
    }, ResourceManager)
end

function ResourceManager:register(tag, resource)
    if resource == nil then
        return resource
    end
    tag = tag or "general"
    local bucket = self.tagBuckets[tag]
    if not bucket then
        bucket = {}
        self.tagBuckets[tag] = bucket
    end
    bucket[#bucket + 1] = resource
    self.resourceTags[resource] = tag
    return resource
end

function ResourceManager:connect(signalObject, callback, tag)
    local connection = signalObject:Connect(callback)
    return self:register(tag or "connections", connection)
end

local function releaseSingleResource(resource)
    local resourceType = typeof(resource)
    if resourceType == "RBXScriptConnection" then
        pcall(function()
            resource:Disconnect()
        end)
    elseif resourceType == "Instance" then
        pcall(function()
            resource:Destroy()
        end)
    elseif resourceType == "function" then
        pcall(resource)
    end
end

function ResourceManager:release(resource)
    if resource == nil then
        return
    end
    local tag = self.resourceTags[resource]
    if tag then
        local bucket = self.tagBuckets[tag]
        if bucket then
            for index = #bucket, 1, -1 do
                if bucket[index] == resource then
                    table.remove(bucket, index)
                    break
                end
            end
        end
        self.resourceTags[resource] = nil
    end
    releaseSingleResource(resource)
end

function ResourceManager:releaseByPrefix(prefix)
    for tag, bucket in pairs(self.tagBuckets) do
        if tag == prefix or string.sub(tag, 1, #prefix) == prefix then
            for _, resource in ipairs(bucket) do
                releaseSingleResource(resource)
            end
            self.tagBuckets[tag] = nil
        end
    end
    for resource, tag in pairs(self.resourceTags) do
        if tag == prefix or string.sub(tag, 1, #prefix) == prefix then
            self.resourceTags[resource] = nil
        end
    end
end

function ResourceManager:destroyAll()
    self.destroyed = true
    for _, bucket in pairs(self.tagBuckets) do
        for _, resource in ipairs(bucket) do
            releaseSingleResource(resource)
        end
    end
    self.tagBuckets = {}
    self.resourceTags = {}
end

local resourceManager = ResourceManager.new()

-- ============ Unified loop dispatcher ============
local heartbeatTasks = {}
local renderTasks = {}

local function addHeartbeatTask(tag, interval, callback)
    table.insert(heartbeatTasks, { tag = tag, interval = interval, accumulator = 0, callback = callback })
end

local function addRenderTask(tag, callback)
    table.insert(renderTasks, { tag = tag, callback = callback })
end

resourceManager:connect(runService.Heartbeat, function(deltaTime)
    for index = 1, #heartbeatTasks do
        local taskEntry = heartbeatTasks[index]
        taskEntry.accumulator += deltaTime
        if taskEntry.accumulator >= taskEntry.interval then
            local elapsed = taskEntry.accumulator
            taskEntry.accumulator = 0
            local success, errorMessage = pcall(taskEntry.callback, elapsed)
            if not success then
                warn("[NetErrror] Ошибка игрового цикла '" .. taskEntry.tag .. "': " .. tostring(errorMessage))
            end
        end
    end
end, "loops.heartbeat")

resourceManager:connect(runService.RenderStepped, function(deltaTime)
    for index = 1, #renderTasks do
        local taskEntry = renderTasks[index]
        local success, errorMessage = pcall(taskEntry.callback, deltaTime)
        if not success then
            warn("[NetErrror] Ошибка кадра '" .. taskEntry.tag .. "': " .. tostring(errorMessage))
        end
    end
end, "loops.render")

-- ============ Helpers ============
local activeTweens = setmetatable({}, { __mode = "k" })

local function tween(object, tweenInfo, properties)
    local previousTween = activeTweens[object]
    if previousTween then
        previousTween:Cancel()
    end
    local createdTween = tweenService:Create(object, tweenInfo or UI_TWEEN_INFO, properties)
    activeTweens[object] = createdTween
    createdTween:Play()
    return createdTween
end

local function newInstance(className, properties, children)
    local instanceObject = Instance.new(className)
    if properties then
        for propertyName, propertyValue in pairs(properties) do
            if propertyName ~= "Parent" then
                instanceObject[propertyName] = propertyValue
            end
        end
    end
    if children then
        for _, child in ipairs(children) do
            child.Parent = instanceObject
        end
    end
    if properties and properties.Parent ~= nil then
        instanceObject.Parent = properties.Parent
    end
    return instanceObject
end

-- Forward declarations for cross-module references.
local notify
local syncQuickActions
local setQuickActionPinned
local unloadScript
local updateSpeedVFX
local updateFlyVFX
local applyLayout

-- Drawing availability probe (tracers / FOV ring / markers degrade gracefully).
local drawingAvailable = false
pcall(function()
    local probeCircle = Drawing.new("Circle")
    probeCircle:Remove()
    drawingAvailable = true
end)

local fovRing, aimPulse
if drawingAvailable then
    fovRing = Drawing.new("Circle")
    fovRing.NumSides = 64
    fovRing.Thickness = 1.5
    fovRing.Filled = false
    fovRing.Transparency = 0.1
    fovRing.Visible = false
    aimPulse = Drawing.new("Circle")
    aimPulse.NumSides = 32
    aimPulse.Thickness = 2
    aimPulse.Filled = false
    aimPulse.Transparency = 0.05
    aimPulse.Visible = false
end

-- ============ GUI root ============
local function resolveGuiParent()
    local success, hiddenFolder = pcall(gethui)
    if success and hiddenFolder then
        return hiddenFolder
    end
    local coreSuccess, coreGui = pcall(function()
        return game:GetService("CoreGui")
    end)
    if coreSuccess and coreGui then
        return coreGui
    end
    return localPlayer:FindFirstChildOfClass("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 9)
end

local uiSuffix = "NE000000"
pcall(function()
    uiSuffix = (httpService:GenerateGUID(false):sub(1, 8):gsub("-", ""))
end)

local screenGui = newInstance("ScreenGui", {
    Name = "NetErrrorSuite_" .. uiSuffix,
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999,
    Parent = resolveGuiParent(),
})

local espLayer = newInstance("Frame", {
    Name = "ESPLayer_" .. uiSuffix,
    BackgroundTransparency = 1,
    Size = UDim2.fromScale(1, 1),
    Parent = screenGui,
    ZIndex = 1,
})

local notifyHolder = newInstance("Frame", {
    Name = "NotifyHolder_" .. uiSuffix,
    BackgroundTransparency = 1,
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 12),
    Size = UDim2.new(0, 340, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    Parent = screenGui,
    ZIndex = 8,
})
newInstance("UIListLayout", {
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    Parent = notifyHolder,
})

local observerBadge = newInstance("Frame", {
    Name = "ObserverBadge_" .. uiSuffix,
    BackgroundColor3 = COLORS.bgPanel,
    Position = UDim2.new(0, 12, 0, 12),
    Size = UDim2.fromOffset(134, 30),
    Visible = false,
    Parent = screenGui,
    ZIndex = 7,
})
newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = observerBadge })
newInstance("UIStroke", { Color = COLORS.borderColor, Thickness = 1, Parent = observerBadge })
local observerBadgeLabel = newInstance("TextLabel", {
    BackgroundTransparency = 1,
    Size = UDim2.fromScale(1, 1),
    Font = FONTS.bold,
    TextSize = 11,
    TextColor3 = COLORS.textSecondary,
    Text = "Наблюдают: 0",
    Parent = observerBadge,
})

-- ============ Frame-based vector icons (no emoji, no external assets) ============
local function buildBoltIcon(holder, color)
    local parts = {}
    parts[1] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(4, 12), Rotation = 30, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, -3, 0.5, -2), Parent = holder })
    parts[2] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(4, 12), Rotation = -30, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 3, 0.5, 2), Parent = holder })
    return parts
end

local function buildChevronIcon(holder, color, direction)
    local parts = {}
    if direction == "down" then
        parts[1] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(4, 10), Rotation = -40, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, -5, 0.5, -3), Parent = holder })
        parts[2] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(4, 10), Rotation = 40, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 5, 0.5, -3), Parent = holder })
    else
        parts[1] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(4, 10), Rotation = 40, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, -5, 0.5, 3), Parent = holder })
        parts[2] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(4, 10), Rotation = -40, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 5, 0.5, 3), Parent = holder })
    end
    return parts
end

local function buildCrosshairIcon(holder, color)
    local parts = {}
    parts[1] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(3, 7), AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Parent = holder })
    parts[2] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(3, 7), AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), Parent = holder })
    parts[3] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(7, 3), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Parent = holder })
    parts[4] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(7, 3), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Parent = holder })
    local centerDot = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(4, 4), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0), Parent = holder })
    newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = centerDot })
    parts[5] = centerDot
    return parts
end

local function buildRingIcon(holder, color, backgroundColor)
    local outer = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = holder })
    newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = outer })
    local inner = newInstance("Frame", { BackgroundColor3 = backgroundColor, BorderSizePixel = 0, Size = UDim2.new(1, -8, 1, -8), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0), ZIndex = 2, Parent = holder })
    newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = inner })
    return { outer }, inner
end

local function buildPinIcon(holder, color)
    local parts = {}
    local head = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(8, 8), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.32, 0), Parent = holder })
    newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = head })
    parts[1] = head
    parts[2] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(3, 6), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.6, 0), Parent = holder })
    parts[3] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(8, 3), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.84, 0), Parent = holder })
    return parts
end

local function buildCloseIcon(holder, color)
    local parts = {}
    parts[1] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(3, 13), Rotation = 45, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = holder })
    parts[2] = newInstance("Frame", { BackgroundColor3 = color, BorderSizePixel = 0, Size = UDim2.fromOffset(3, 13), Rotation = -45, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = holder })
    return parts
end

-- ============ Drag / tap isolation (threshold 10px) ============
local function makeDraggable(element, options)
    options = options or {}
    local elementTag = options.tag or tostring(element)
    local dragging = false
    local dragMoved = false
    local dragStartPos = Vector2.zero
    local elementStartPos = Vector2.zero

    resourceManager:connect(element.InputBegan, function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType ~= Enum.UserInputType.Touch and inputType ~= Enum.UserInputType.MouseButton1 then return end
        dragging = true
        dragMoved = false
        dragStartPos = Vector2.new(inputObject.Position.X, inputObject.Position.Y)
        elementStartPos = Vector2.new(element.AbsolutePosition.X, element.AbsolutePosition.Y)
        if options.onPress then pcall(options.onPress) end
    end, "drag.begin." .. elementTag)

    resourceManager:connect(userInputService.InputChanged, function(inputObject)
        if not dragging then return end
        local inputType = inputObject.UserInputType
        if inputType ~= Enum.UserInputType.Touch and inputType ~= Enum.UserInputType.MouseMovement then return end
        local delta = Vector2.new(inputObject.Position.X, inputObject.Position.Y) - dragStartPos
        if not dragMoved and delta.Magnitude > DRAG_THRESHOLD then
            dragMoved = true
        end
        if dragMoved and options.onDrag then
            pcall(options.onDrag, elementStartPos, delta)
        end
    end, "drag.move." .. elementTag)

    resourceManager:connect(userInputService.InputEnded, function(inputObject)
        if not dragging then return end
        local inputType = inputObject.UserInputType
        if inputType ~= Enum.UserInputType.Touch and inputType ~= Enum.UserInputType.MouseButton1 then return end
        dragging = false
        if options.onRelease then pcall(options.onRelease) end
        if dragMoved then
            if options.onDragEnd then pcall(options.onDragEnd) end
        elseif options.onTap then
            pcall(options.onTap)
        end
        dragMoved = false
    end, "drag.end." .. elementTag)
end

local function applySavedPosition(element, savedPosition, defaultPosition, fallbackSize)
    local camera = workspaceService.CurrentCamera
    if not camera then return end
    local viewport = camera.ViewportSize
    local elementSize = element.AbsoluteSize
    if elementSize.X <= 0 then
        elementSize = Vector2.new(fallbackSize or 56, fallbackSize or 56)
    end
    local sourcePosition = savedPosition or defaultPosition
    local targetX = (sourcePosition.x or 0.5) * viewport.X
    local targetY = (sourcePosition.y or 0.5) * viewport.Y
    local safeInset = guiService:GetGuiInset()
    targetX = math.clamp(targetX, safeInset.X + 8, math.max(safeInset.X + 8, viewport.X - elementSize.X - 8))
    targetY = math.clamp(targetY, safeInset.Y + 8, math.max(safeInset.Y + 8, viewport.Y - elementSize.Y - 8))
    element.Position = UDim2.fromOffset(targetX, targetY)
end

local function saveElementPosition(element, configKey, subKey)
    local camera = workspaceService.CurrentCamera
    if not camera then return end
    local viewport = camera.ViewportSize
    local absolutePosition = element.AbsolutePosition
    local normalized = {
        x = math.clamp(absolutePosition.X / math.max(viewport.X, 1), 0, 1),
        y = math.clamp(absolutePosition.Y / math.max(viewport.Y, 1), 0, 1),
    }
    if subKey then
        config[configKey][subKey] = normalized
    else
        config[configKey] = normalized
    end
    saveConfigNow()
end

-- ============ Main panel skeleton ============
local UI_MARGIN = 12
local FOOTER_HEIGHT = 50

local panel = newInstance("Frame", {
    Name = "MainPanel_" .. uiSuffix,
    AnchorPoint = Vector2.new(1, 0.5),
    BackgroundColor3 = COLORS.bgMain,
    Visible = false,
    Parent = screenGui,
    ZIndex = 10,
})
newInstance("UICorner", { CornerRadius = UDim.new(0, 14), Parent = panel })
newInstance("UIStroke", { Color = COLORS.borderColor, Thickness = 1, Transparency = 0.2, Parent = panel })
local panelScale = newInstance("UIScale", { Scale = 1, Parent = panel })

local panelDragX, panelDragY = 0, 0
local panelDragBase = Vector2.zero

local function applyPanelPosition()
    panel.Position = UDim2.new(1, -UI_MARGIN + panelDragX, 0.5, panelDragY)
end

local header = newInstance("Frame", {
    Name = "Header",
    BackgroundTransparency = 1,
    Size = UDim2.new(1, 0, 0, 56),
    Active = true,
    Parent = panel,
    ZIndex = 2,
})
local logoHolder = newInstance("Frame", { BackgroundColor3 = COLORS.accentMain, Size = UDim2.fromOffset(34, 34), Position = UDim2.new(0, 12, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Parent = header })
newInstance("UICorner", { CornerRadius = UDim.new(0, 10), Parent = logoHolder })
newInstance("UIGradient", { Color = ColorSequence.new(COLORS.accentMain, COLORS.accentSecondary), Rotation = 45, Parent = logoHolder })
newInstance("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Font = FONTS.black, TextSize = 16, TextColor3 = COLORS.textPrimary, Text = "N", Parent = logoHolder })
newInstance("TextLabel", { BackgroundTransparency = 1, Position = UDim2.new(0, 56, 0, 10), Size = UDim2.new(0, 180, 0, 18), Font = FONTS.bold, TextSize = 15, TextColor3 = COLORS.textPrimary, TextXAlignment = Enum.TextXAlignment.Left, Text = "NETRRROR", Parent = header })
newInstance("TextLabel", { BackgroundTransparency = 1, Position = UDim2.new(0, 56, 0, 30), Size = UDim2.new(0, 180, 0, 12), Font = FONTS.bold, TextSize = 9, TextColor3 = COLORS.textSecondary, TextXAlignment = Enum.TextXAlignment.Left, Text = "MOBILE SUITE  •  v1.0", Parent = header })

local closeButton = newInstance("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromOffset(34, 34), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Parent = header })
local closeIconHolder = newInstance("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(14, 14), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = closeButton })
buildCloseIcon(closeIconHolder, COLORS.textSecondary)

local navBar = newInstance("Frame", { Name = "NavBar", BackgroundTransparency = 1, Position = UDim2.new(0, 0, 0, 56), Size = UDim2.new(1, 0, 0, 36), Parent = panel })
newInstance("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder, Parent = navBar })
newInstance("Frame", { BackgroundColor3 = COLORS.borderColor, BorderSizePixel = 0, Position = UDim2.new(0, 12, 0, 92), Size = UDim2.new(1, -24, 0, 1), Parent = panel })

local pagesHolder = newInstance("Frame", { Name = "Pages", BackgroundTransparency = 1, ClipsDescendants = true, Position = UDim2.new(0, 0, 0, 93), Size = UDim2.new(1, 0, 1, -(93 + FOOTER_HEIGHT)), Parent = panel })

local footer = newInstance("Frame", { Name = "Footer", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT), Parent = panel })
newInstance("TextLabel", { BackgroundTransparency = 1, Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(1, -150, 1, 0), Font = FONTS.medium, TextSize = 10, TextColor3 = COLORS.textSecondary, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "Конфиг: " .. CONFIG_FILENAME .. " • автосохранение", Parent = footer })
local unloadFooterButton = newInstance("TextButton", { Text = "ВЫГРУЗИТЬ", AutoButtonColor = false, BackgroundColor3 = COLORS.bgPanel, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(118, 34), Font = FONTS.bold, TextSize = 11, TextColor3 = COLORS.danger, Parent = footer })
newInstance("UICorner", { CornerRadius = UDim.new(0, 10), Parent = unloadFooterButton })
newInstance("UIStroke", { Color = COLORS.danger, Thickness = 1, Transparency = 0.2, Parent = unloadFooterButton })

-- Tabs + pages.
local pageDefinitions = {
    { id = "combat", title = "БОЙ" },
    { id = "movement", title = "ДВИЖЕНИЕ" },
    { id = "visual", title = "ВИЗУАЛ" },
    { id = "survival", title = "ВЫЖИВАНИЕ" },
    { id = "world", title = "МИР" },
}

local pages = {}
local navButtons = {}

local function createPage(definition, index)
    local page = newInstance("ScrollingFrame", {
        Name = "Page_" .. definition.id,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromScale(0, 0),
        Size = UDim2.fromScale(1, 1),
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = COLORS.accentMain,
        Visible = index == 1,
        Parent = pagesHolder,
    })
    newInstance("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })
    newInstance("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 14), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = page })
    pages[definition.id] = page
    return page
end

local function selectTab(index)
    for tabIndex, navEntry in ipairs(navButtons) do
        local isSelected = tabIndex == index
        tween(navEntry.button, PRESS_TWEEN_INFO, { BackgroundColor3 = isSelected and COLORS.bgSecondary or COLORS.bgMain })
        tween(navEntry.label, PRESS_TWEEN_INFO, { TextColor3 = isSelected and COLORS.accentMain or COLORS.textSecondary })
        tween(navEntry.indicator, PRESS_TWEEN_INFO, { BackgroundTransparency = isSelected and 0 or 1 })
    end
    for pageIndex, definition in ipairs(pageDefinitions) do
        local page = pages[definition.id]
        local isSelected = pageIndex == index
        if isSelected and not page.Visible then
            page.Visible = true
            page.Position = UDim2.fromOffset(0, 14)
            tween(page, UI_TWEEN_INFO, { Position = UDim2.fromOffset(0, 0) })
        elseif not isSelected then
            page.Visible = false
        end
    end
end

for index, definition in ipairs(pageDefinitions) do
    createPage(definition, index)
    local tabButton = newInstance("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = COLORS.bgMain, BorderSizePixel = 0, Size = UDim2.new(1 / #pageDefinitions, 0, 1, 0), LayoutOrder = index, Parent = navBar })
    local tabLabel = newInstance("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Font = FONTS.bold, TextSize = 10, TextColor3 = COLORS.textSecondary, Text = definition.title, Parent = tabButton })
    local indicator = newInstance("Frame", { BackgroundColor3 = COLORS.accentMain, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.fromOffset(22, 2), BackgroundTransparency = 1, Parent = tabButton })
    navButtons[index] = { button = tabButton, label = tabLabel, indicator = indicator }
    resourceManager:connect(tabButton.Activated, function()
        selectTab(index)
    end, "nav." .. definition.id)
end

-- ============ UI components ============
local toggleRegistry = {}

local function createSection(page, title)
    local section = newInstance("Frame", { BackgroundColor3 = COLORS.bgPanel, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = #page:GetChildren(), Parent = page })
    newInstance("UICorner", { CornerRadius = UDim.new(0, 12), Parent = section })
    newInstance("UIStroke", { Color = COLORS.borderColor, Thickness = 1, Transparency = 0.35, Parent = section })
    newInstance("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 12), PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = section })
    newInstance("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 14), Font = FONTS.bold, TextSize = 11, TextColor3 = COLORS.textSecondary, TextXAlignment = Enum.TextXAlignment.Left, Text = title, Parent = section })
    local content = newInstance("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.new(0, 0, 0, 20), Parent = section })
    newInstance("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = content })
    local rowOrder = 0
    local function nextOrder()
        rowOrder += 1
        return rowOrder
    end
    return content, nextOrder
end

local function createToggle(parent, order, title, configKey, onChanged, options)
    options = options or {}
    local row = newInstance("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = order, Parent = parent })
    local rowStroke = newInstance("UIStroke", { Color = COLORS.accentMain, Thickness = 1, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = row })
    newInstance("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -170, 1, 0), Position = UDim2.new(0, 4, 0, 0), Font = FONTS.medium, TextSize = 13, TextColor3 = COLORS.textPrimary, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = title, Parent = row })
    local track = newInstance("Frame", { BackgroundColor3 = COLORS.bgSecondary, Size = UDim2.fromOffset(46, 26), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, options.pinKey and -42 or -4, 0.5, 0), Parent = row })
    newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = track })
    newInstance("UIStroke", { Color = COLORS.borderColor, Thickness = 1, Transparency = 0.4, Parent = track })
    local knob = newInstance("Frame", { BackgroundColor3 = COLORS.textSecondary, Size = UDim2.fromOffset(20, 20), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 13, 0.5, 0), ZIndex = 2, Parent = track })
    newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = knob })

    local pinIconParts = nil
    if options.pinKey then
        local pinButton = newInstance("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromOffset(32, 32), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -4, 0.5, 0), Parent = row })
        local pinIconHolder = newInstance("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = pinButton })
        pinIconParts = buildPinIcon(pinIconHolder, COLORS.textSecondary)
        local pinnedInitially = config.qaPins[options.pinKey] == true
        for _, part in ipairs(pinIconParts) do
            part.BackgroundColor3 = pinnedInitially and COLORS.accentMain or COLORS.textSecondary
        end
        resourceManager:connect(pinButton.Activated, function()
            local pinned = not config.qaPins[options.pinKey]
            setQuickActionPinned(options.pinKey, pinned)
            for _, part in ipairs(pinIconParts) do
                tween(part, PRESS_TWEEN_INFO, { BackgroundColor3 = pinned and COLORS.accentMain or COLORS.textSecondary })
            end
        end, "pin." .. options.pinKey)
    end

    local function setVisual(enabled)
        tween(track, UI_TWEEN_INFO, { BackgroundColor3 = enabled and COLORS.accentMain or COLORS.bgSecondary })
        tween(knob, UI_TWEEN_INFO, { Position = UDim2.new(0, enabled and 33 or 13, 0.5, 0), BackgroundColor3 = enabled and COLORS.textPrimary or COLORS.textSecondary })
        tween(rowStroke, UI_TWEEN_INFO, { Transparency = enabled and 0.35 or 1 })
    end

    local function apply(value, runCallbacks, save)
        config[configKey] = value
        if not state.unloaded then
            setVisual(value)
            if runCallbacks and onChanged then
                pcall(onChanged, value)
            end
            if runCallbacks and syncQuickActions then
                syncQuickActions(configKey, value)
            end
        end
        if save then
            saveConfigNow()
        end
    end

    resourceManager:connect(row.Activated, function()
        apply(not config[configKey], true, true)
    end, "toggle." .. configKey)

    toggleRegistry[configKey] = {
        configKey = configKey,
        title = title,
        set = function(value, skipSave)
            apply(value, true, not skipSave)
        end,
    }
    apply(config[configKey], false, false)
    return { set = toggleRegistry[configKey].set, row = row }
end

local function createSlider(parent, order, title, configKey, minValue, maxValue, step, options)
    options = options or {}
    local row = newInstance("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 56), LayoutOrder = order, Parent = parent })
    newInstance("TextLabel", { BackgroundTransparency = 1, Position = UDim2.new(0, 4, 0, 2), Size = UDim2.new(1, -78, 0, 18), Font = FONTS.medium, TextSize = 13, TextColor3 = COLORS.textPrimary, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = title, Parent = row })
    local valueLabel = newInstance("TextLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -4, 0, 2), Size = UDim2.new(0, 72, 0, 18), Font = FONTS.bold, TextSize = 12, TextColor3 = COLORS.accentMain, TextXAlignment = Enum.TextXAlignment.Right, Text = "", Parent = row })
    local trackZone = newInstance("Frame", { BackgroundTransparency = 1, Active = true, Size = UDim2.new(1, 0, 0, 26), Position = UDim2.new(0, 0, 0, 28), Parent = row })
    local track = newInstance("Frame", { BackgroundColor3 = COLORS.bgSecondary, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 2, 0.5, 0), Size = UDim2.new(1, -4, 0, 6), Parent = trackZone })
    newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = track })
    local fill = newInstance("Frame", { BackgroundColor3 = COLORS.accentMain, BorderSizePixel = 0, Size = UDim2.new(0, 0, 1, 0), Parent = track })
    newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fill })
    local handle = newInstance("Frame", { BackgroundColor3 = COLORS.textPrimary, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(16, 16), ZIndex = 2, Parent = trackZone })
    newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = handle })

    local dragging = false

    local function formatValue(value)
        if options.formatter then
            return options.formatter(value)
        end
        if step and step >= 1 then
            return tostring(math.floor(value + 0.5))
        end
        return tostring(math.floor(value * 100 + 0.5) / 100)
    end

    local function applyValue(rawValue, animate)
        local value = math.clamp(rawValue, minValue, maxValue)
        if step and step > 0 then
            value = minValue + math.floor((value - minValue) / step + 0.5) * step
            local decimals = 0
            local stepCopy = step
            while stepCopy < 1 and decimals < 4 do
                stepCopy *= 10
                decimals += 1
            end
            local roundingFactor = 10 ^ decimals
            value = math.clamp(math.floor(value * roundingFactor + 0.5) / roundingFactor, minValue, maxValue)
        end
        local alpha = (value - minValue) / math.max(maxValue - minValue, 1e-6)
        if animate then
            tween(fill, PRESS_TWEEN_INFO, { Size = UDim2.new(alpha, 0, 1, 0) })
            tween(handle, PRESS_TWEEN_INFO, { Position = UDim2.new(alpha, 0, 0.5, 0) })
        else
            fill.Size = UDim2.new(alpha, 0, 1, 0)
            handle.Position = UDim2.new(alpha, 0, 0.5, 0)
        end
        valueLabel.Text = formatValue(value)
        if config[configKey] ~= value then
            config[configKey] = value
            if options.onChanged then
                pcall(options.onChanged, value)
            end
            saveConfigNow()
        end
    end

    local function valueFromInput(inputObject)
        local trackStart = track.AbsolutePosition.X
        local trackWidth = math.max(track.AbsoluteSize.X, 1)
        local relative = math.clamp((inputObject.Position.X - trackStart) / trackWidth, 0, 1)
        return minValue + relative * (maxValue - minValue)
    end

    resourceManager:connect(trackZone.InputBegan, function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType ~= Enum.UserInputType.Touch and inputType ~= Enum.UserInputType.MouseButton1 then return end
        dragging = true
        -- Horizontal slider gesture locks vertical scrolling while dragging.
        local page = row:FindFirstAncestorOfClass("ScrollingFrame")
        if page then
            page.ScrollingEnabled = false
        end
        applyValue(valueFromInput(inputObject), false)
    end, "slider." .. configKey .. ".begin")

    resourceManager:connect(userInputService.InputChanged, function(inputObject)
        if not dragging then return end
        local inputType = inputObject.UserInputType
        if inputType ~= Enum.UserInputType.Touch and inputType ~= Enum.UserInputType.MouseMovement then return end
        applyValue(valueFromInput(inputObject), false)
    end, "slider." .. configKey .. ".move")

    resourceManager:connect(userInputService.InputEnded, function(inputObject)
        if not dragging then return end
        local inputType = inputObject.UserInputType
        if inputType ~= Enum.UserInputType.Touch and inputType ~= Enum.UserInputType.MouseButton1 then return end
        dragging = false
        local page = row:FindFirstAncestorOfClass("ScrollingFrame")
        if page then
            page.ScrollingEnabled = true
        end
    end, "slider." .. configKey .. ".end")

    applyValue(config[configKey] or minValue, false)
    return { apply = applyValue }
end

local function createButton(parent, order, title, callback, options)
    options = options or {}
    local isDanger = options.danger == true
    local row = newInstance("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = isDanger and COLORS.bgPanel or COLORS.bgSecondary, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = order, Parent = parent })
    newInstance("UICorner", { CornerRadius = UDim.new(0, 10), Parent = row })
    newInstance("UIStroke", { Color = isDanger and COLORS.danger or COLORS.borderColor, Thickness = 1, Transparency = isDanger and 0.2 or 0.4, Parent = row })
    local buttonScale = newInstance("UIScale", { Scale = 1, Parent = row })
    newInstance("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Font = FONTS.semibold, TextSize = 13, TextColor3 = isDanger and COLORS.danger or COLORS.textPrimary, Text = title, Parent = row })
    resourceManager:connect(row.Activated, function()
        tween(buttonScale, PRESS_TWEEN_INFO, { Scale = 0.96 })
        task.delay(0.09, function()
            if buttonScale.Parent then
                tween(buttonScale, PRESS_TWEEN_INFO, { Scale = 1 })
            end
        end)
        if callback then
            pcall(callback)
        end
    end, "button." .. title)
    return row
end

local function createSegmented(parent, order, title, optionsList, configKey)
    local row = newInstance("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 62), LayoutOrder = order, Parent = parent })
    newInstance("TextLabel", { BackgroundTransparency = 1, Position = UDim2.new(0, 4, 0, 2), Size = UDim2.new(1, -8, 0, 18), Font = FONTS.medium, TextSize = 13, TextColor3 = COLORS.textPrimary, TextXAlignment = Enum.TextXAlignment.Left, Text = title, Parent = row })
    local buttonHolder = newInstance("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32), Position = UDim2.new(0, 0, 0, 26), Parent = row })
    local optionButtons = {}

    local function applySelected(selectedValue)
        for _, option in ipairs(optionsList) do
            local visuals = optionButtons[option.value]
            if visuals then
                local isSelected = selectedValue == option.value
                tween(visuals.background, PRESS_TWEEN_INFO, { BackgroundColor3 = isSelected and COLORS.accentMain or COLORS.bgSecondary })
                tween(visuals.label, PRESS_TWEEN_INFO, { TextColor3 = isSelected and COLORS.textPrimary or COLORS.textSecondary })
            end
        end
    end

    for index, option in ipairs(optionsList) do
        local optionButton = newInstance("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = COLORS.bgSecondary, BorderSizePixel = 0, Position = UDim2.new((index - 1) / #optionsList, index > 1 and 2 or 0, 0, 0), Size = UDim2.new(1 / #optionsList, -2, 1, 0), Parent = buttonHolder })
        newInstance("UICorner", { CornerRadius = UDim.new(0, 8), Parent = optionButton })
        local optionLabel = newInstance("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Font = FONTS.semibold, TextSize = 12, TextColor3 = COLORS.textSecondary, Text = option.label, Parent = optionButton })
        optionButtons[option.value] = { background = optionButton, label = optionLabel }
        resourceManager:connect(optionButton.Activated, function()
            config[configKey] = option.value
            applySelected(option.value)
            saveConfigNow()
        end, "segment." .. configKey .. "." .. tostring(option.value))
    end

    applySelected(config[configKey])
    return row
end

local function createCycleButton(parent, order, title, values, configKey, formatter)
    local row = newInstance("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = order, Parent = parent })
    newInstance("UIStroke", { Color = COLORS.borderColor, Thickness = 1, Transparency = 0.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = row })
    newInstance("TextLabel", { BackgroundTransparency = 1, Position = UDim2.new(0, 4, 0, 0), Size = UDim2.new(1, -180, 1, 0), Font = FONTS.medium, TextSize = 13, TextColor3 = COLORS.textPrimary, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = title, Parent = row })
    local valueLabel = newInstance("TextLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.new(0, 160, 1, 0), Font = FONTS.bold, TextSize = 12, TextColor3 = COLORS.accentMain, TextXAlignment = Enum.TextXAlignment.Right, Text = "", Parent = row })

    local function refresh()
        local currentValue = config[configKey]
        valueLabel.Text = formatter and formatter(currentValue) or tostring(currentValue)
    end

    resourceManager:connect(row.Activated, function()
        local currentIndex = 1
        for index, value in ipairs(values) do
            if value == config[configKey] then
                currentIndex = index
                break
            end
        end
        config[configKey] = values[(currentIndex % #values) + 1]
        refresh()
        saveConfigNow()
    end, "cycle." .. configKey)

    refresh()
    return row
end

local function bindSection(content, nextOrder)
    return {
        toggle = function(title, configKey, onChanged, options)
            return createToggle(content, nextOrder(), title, configKey, onChanged, options)
        end,
        slider = function(title, configKey, minValue, maxValue, step, options)
            return createSlider(content, nextOrder(), title, configKey, minValue, maxValue, step, options)
        end,
        button = function(title, callback, options)
            return createButton(content, nextOrder(), title, callback, options)
        end,
        segmented = function(title, optionsList, configKey)
            return createSegmented(content, nextOrder(), title, optionsList, configKey)
        end,
        cycle = function(title, values, configKey, formatter)
            return createCycleButton(content, nextOrder(), title, values, configKey, formatter)
        end,
    }
end

-- ============ Quick Action HUD ============
local quickActionDefinitions = {
    { key = "speed", title = "СКОР", toggleKey = "speedEnabled", defaultPosition = { x = 0.9, y = 0.16 }, buildIcon = function(holder, color) return buildBoltIcon(holder, color) end },
    { key = "fly", title = "ПОЛЁТ", toggleKey = "flyEnabled", defaultPosition = { x = 0.9, y = 0.3 }, buildIcon = function(holder, color) return buildChevronIcon(holder, color, "up") end },
    { key = "aim", title = "АИМ", toggleKey = "aimEnabled", defaultPosition = { x = 0.9, y = 0.44 }, buildIcon = function(holder, color) return buildCrosshairIcon(holder, color) end },
    { key = "aura", title = "АУРА", toggleKey = "auraEnabled", defaultPosition = { x = 0.9, y = 0.58 }, buildIcon = function(holder, color) return buildRingIcon(holder, color, COLORS.bgPanel) end },
}

local quickActionDefinitionByKey = {}
for _, definition in ipairs(quickActionDefinitions) do
    quickActionDefinitionByKey[definition.key] = definition
end

local quickActionButtons = {}

local function updateQuickActionActive(key)
    local visuals = quickActionButtons[key]
    local definition = quickActionDefinitionByKey[key]
    if not (visuals and definition) then return end
    local active = config[definition.toggleKey] == true
    tween(visuals.button, UI_TWEEN_INFO, { BackgroundColor3 = active and COLORS.accentSecondary or COLORS.bgPanel })
    tween(visuals.stroke, UI_TWEEN_INFO, { Color = active and COLORS.accentMain or COLORS.borderColor, Transparency = active and 0 or 0.25 })
    tween(visuals.label, UI_TWEEN_INFO, { TextColor3 = active and COLORS.textPrimary or COLORS.textSecondary })
    for _, part in ipairs(visuals.iconParts) do
        tween(part, UI_TWEEN_INFO, { BackgroundColor3 = active and COLORS.textPrimary or COLORS.textSecondary })
    end
    if visuals.ringInner then
        tween(visuals.ringInner, UI_TWEEN_INFO, { BackgroundColor3 = active and COLORS.accentSecondary or COLORS.bgPanel })
    end
end

syncQuickActions = function(configKey)
    for _, definition in ipairs(quickActionDefinitions) do
        if definition.toggleKey == configKey then
            updateQuickActionActive(definition.key)
        end
    end
end

local function createQuickActionButton(definition)
    if quickActionButtons[definition.key] then return end
    local button = newInstance("TextButton", {
        Name = "QA_" .. definition.key .. "_" .. uiSuffix,
        Text = "",
        AutoButtonColor = false,
        BackgroundColor3 = COLORS.bgPanel,
        Size = UDim2.fromOffset(56, 56),
        Parent = screenGui,
        ZIndex = 5,
    })
    newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = button })
    local stroke = newInstance("UIStroke", { Color = COLORS.borderColor, Thickness = 1.5, Transparency = 0.25, Parent = button })
    local iconHolder = newInstance("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(22, 22), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.4, 0), Parent = button })
    local iconParts, ringInner = definition.buildIcon(iconHolder, COLORS.textSecondary)
    local label = newInstance("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 12), Position = UDim2.new(0, 0, 0.68, 0), Font = FONTS.bold, TextSize = 9, TextColor3 = COLORS.textSecondary, Text = definition.title, Parent = button })
    quickActionButtons[definition.key] = { button = button, stroke = stroke, iconParts = iconParts, ringInner = ringInner, label = label }

    makeDraggable(button, {
        tag = "qa." .. definition.key,
        onPress = function()
            tween(button, PRESS_TWEEN_INFO, { Size = UDim2.fromOffset(52, 52) })
        end,
        onRelease = function()
            tween(button, PRESS_TWEEN_INFO, { Size = UDim2.fromOffset(56, 56) })
        end,
        onDrag = function(elementStartPos, delta)
            button.Position = UDim2.fromOffset(elementStartPos.X + delta.X, elementStartPos.Y + delta.Y)
        end,
        onDragEnd = function()
            saveElementPosition(button, "qaPositions", definition.key)
        end,
        onTap = function()
            local registry = toggleRegistry[definition.toggleKey]
            if registry then
                registry.set(not config[definition.toggleKey])
            end
        end,
    })

    applySavedPosition(button, config.qaPositions[definition.key], definition.defaultPosition, 56)
    updateQuickActionActive(definition.key)
end

setQuickActionPinned = function(key, pinned)
    config.qaPins[key] = pinned
    if pinned then
        createQuickActionButton(quickActionDefinitionByKey[key])
    else
        local visuals = quickActionButtons[key]
        if visuals then
            visuals.button:Destroy()
            quickActionButtons[key] = nil
        end
    end
    saveConfigNow()
end

-- Floating open/close button + fly descend mini-button.
local floatButton = newInstance("TextButton", { Name = "FloatButton_" .. uiSuffix, Text = "", AutoButtonColor = false, BackgroundColor3 = COLORS.bgPanel, Size = UDim2.fromOffset(56, 56), Parent = screenGui, ZIndex = 6 })
newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = floatButton })
local floatStroke = newInstance("UIStroke", { Color = COLORS.accentMain, Thickness = 2, Transparency = 0.15, Parent = floatButton })
local floatLogo = newInstance("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(26, 26), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = floatButton })
newInstance("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Font = FONTS.black, TextSize = 18, TextColor3 = COLORS.accentMain, Text = "N", Parent = floatLogo })

local flyDescendButton = newInstance("TextButton", { Name = "FlyDescend_" .. uiSuffix, Text = "", AutoButtonColor = false, BackgroundColor3 = COLORS.bgPanel, Size = UDim2.fromOffset(44, 44), Visible = false, Parent = screenGui, ZIndex = 6 })
newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = flyDescendButton })
newInstance("UIStroke", { Color = COLORS.borderColor, Thickness = 1.5, Parent = flyDescendButton })
local descendIconHolder = newInstance("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(16, 16), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = flyDescendButton })
buildChevronIcon(descendIconHolder, COLORS.textSecondary, "down")

resourceManager:connect(flyDescendButton.InputBegan, function(inputObject)
    local inputType = inputObject.UserInputType
    if inputType == Enum.UserInputType.Touch or inputType == Enum.UserInputType.MouseButton1 then
        state.flyDownHeld = true
        tween(flyDescendButton, PRESS_TWEEN_INFO, { BackgroundColor3 = COLORS.accentSecondary })
    end
end, "hud.descend.begin")

resourceManager:connect(userInputService.InputEnded, function(inputObject)
    local inputType = inputObject.UserInputType
    if inputType == Enum.UserInputType.Touch or inputType == Enum.UserInputType.MouseButton1 then
        state.flyDownHeld = false
        tween(flyDescendButton, PRESS_TWEEN_INFO, { BackgroundColor3 = COLORS.bgPanel })
    end
end, "hud.descend.end")

local function positionDescendButton()
    flyDescendButton.Position = UDim2.fromOffset(floatButton.Position.X.Offset, floatButton.Position.Y.Offset - 64)
end

local function setMenuOpen(open)
    state.menuOpen = open
    if open then
        applyLayout()
        panel.Visible = true
        panelScale.Scale = 0.92
        tween(panelScale, UI_TWEEN_INFO, { Scale = 1 })
        tween(floatStroke, UI_TWEEN_INFO, { Thickness = 3 })
    else
        local hideTween = tween(panelScale, UI_TWEEN_INFO, { Scale = 0.92 })
        hideTween.Completed:Once(function()
            if not state.menuOpen then
                panel.Visible = false
            end
        end)
        tween(floatStroke, UI_TWEEN_INFO, { Thickness = 2 })
    end
end

makeDraggable(floatButton, {
    tag = "float",
    onPress = function()
        tween(floatButton, PRESS_TWEEN_INFO, { Size = UDim2.fromOffset(52, 52) })
    end,
    onRelease = function()
        tween(floatButton, PRESS_TWEEN_INFO, { Size = UDim2.fromOffset(56, 56) })
    end,
    onDrag = function(elementStartPos, delta)
        floatButton.Position = UDim2.fromOffset(elementStartPos.X + delta.X, elementStartPos.Y + delta.Y)
    end,
    onDragEnd = function()
        saveElementPosition(floatButton, "floatPosition")
        positionDescendButton()
    end,
    onTap = function()
        setMenuOpen(not state.menuOpen)
    end,
})

makeDraggable(header, {
    tag = "panel",
    onPress = function()
        panelDragBase = Vector2.new(panelDragX, panelDragY)
    end,
    onDrag = function(_, delta)
        panelDragX = panelDragBase.X + delta.X
        panelDragY = panelDragBase.Y + delta.Y
        applyPanelPosition()
    end,
})

resourceManager:connect(closeButton.Activated, function()
    setMenuOpen(false)
end, "ui.close")

resourceManager:connect(unloadFooterButton.Activated, function()
    unloadScript()
end, "ui.unload.footer")

-- ============ Module: Combat ============
local combatRaycastParams = RaycastParams.new()
combatRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
combatRaycastParams.IgnoreWater = true

local function isPositionVisible(camera, worldPosition, targetCharacter)
    if not (camera and state.character) then return true end
    combatRaycastParams.FilterDescendantsInstances = { state.character, targetCharacter }
    local origin = camera.CFrame.Position
    local result = workspaceService:Raycast(origin, worldPosition - origin, combatRaycastParams)
    return result == nil or result.Instance:IsDescendantOf(targetCharacter)
end

local function getAimPart(character)
    if not character then return nil end
    if config.aimPart == "Head" then
        return character:FindFirstChild("Head") or character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
    end
    return character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso") or character:FindFirstChild("HumanoidRootPart")
end

local function emulateTap(screenPosition)
    pcall(function()
        if typeof(mousemoveabs) == "function" then
            mousemoveabs(math.floor(screenPosition.X), math.floor(screenPosition.Y))
        end
        if typeof(mouse1click) == "function" then
            mouse1click()
            return
        end
        if virtualInputService then
            virtualInputService:SendMouseMoveEvent(screenPosition.X, screenPosition.Y, nil)
            virtualInputService:SendMouseButtonEvent(screenPosition.X, screenPosition.Y, 0, true, nil, 0)
            virtualInputService:SendMouseButtonEvent(screenPosition.X, screenPosition.Y, 0, false, nil, 0)
        end
    end)
end

local function getWeaponHandle()
    local character = state.character
    if not character then return nil end
    local tool = character:FindFirstChildOfClass("Tool")
    if tool then
        local handle = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart")
        if handle then
            return handle
        end
    end
    return character:FindFirstChild("HumanoidRootPart")
end

local function attackMethodActivate()
    local character = state.character
    if not character then return false end
    local tool = character:FindFirstChildOfClass("Tool")
    if not tool then return false end
    local success = pcall(function()
        tool:Activate()
    end)
    if success then
        task.delay(0.12, function()
            pcall(function()
                tool:Deactivate()
            end)
        end)
    end
    return success
end

local function attackMethodTouch(targetCharacter)
    if typeof(firetouchinterest) ~= "function" then return false end
    local handle = getWeaponHandle()
    local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart") or targetCharacter:FindFirstChildWhichIsA("BasePart")
    if not (handle and targetRoot) then return false end
    local touchSuccess = false
    pcall(function()
        firetouchinterest(handle, targetRoot, 0)
        touchSuccess = true
    end)
    if touchSuccess then
        task.delay(0.06, function()
            pcall(function()
                firetouchinterest(handle, targetRoot, 1)
            end)
        end)
        local head = targetCharacter:FindFirstChild("Head")
        if head then
            pcall(function()
                firetouchinterest(handle, head, 0)
            end)
            task.delay(0.06, function()
                pcall(function()
                    firetouchinterest(handle, head, 1)
                end)
            end)
        end
    end
    return touchSuccess
end

local function attackMethodBring(targetCharacter)
    local handle = getWeaponHandle()
    local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
    if not (handle and targetRoot) then return false end
    local originalCFrame = handle.CFrame
    local success = pcall(function()
        handle.CFrame = targetRoot.CFrame
    end)
    if success then
        task.delay(0.06, function()
            pcall(function()
                handle.CFrame = originalCFrame
            end)
        end)
    end
    return success
end

local function attackMethodClick()
    if typeof(mouse1click) == "function" then
        return pcall(mouse1click)
    end
    return false
end

local auraMethodOrder = { "activate", "touch", "bring", "click" }
local auraMethodLabels = {
    activate = "Активация",
    touch = "Касание",
    bring = "Поднос оружия",
    click = "Клик",
    cycle = "По кругу",
}

local function performAttack(targetCharacter)
    if not targetCharacter then return false end
    local method = config.auraMethod
    if method == "cycle" then
        state.auraCycleIndex = (state.auraCycleIndex % #auraMethodOrder) + 1
        method = auraMethodOrder[state.auraCycleIndex]
    end
    if method == "activate" then return attackMethodActivate() end
    if method == "touch" then return attackMethodTouch(targetCharacter) end
    if method == "bring" then return attackMethodBring(targetCharacter) end
    if method == "click" then return attackMethodClick() end
    return false
end

local function retakeNearestTarget()
    state.aimTarget = nil
    local target = combatCandidates[1]
    if target then
        state.aimTarget = target
        notify("Цель перехвачена: " .. tostring(target.player.DisplayName), "info")
    else
        notify("Рядом нет подходящих целей", "danger")
    end
end

local function restoreHitboxes()
    for part, backup in pairs(hitboxBackups) do
        if part and part.Parent then
            pcall(function()
                part.Size = backup.size
                part.CanQuery = backup.canQuery
            end)
        end
    end
    table.clear(hitboxBackups)
end

local function restoreHitboxesForCharacter(character)
    for part, backup in pairs(hitboxBackups) do
        if part and part:IsDescendantOf(character) then
            pcall(function()
                part.Size = backup.size
                part.CanQuery = backup.canQuery
            end)
            hitboxBackups[part] = nil
        end
    end
end

-- ============ Module: ESP ============
local function releaseEspEntry(entry)
    if entry.tracer then
        pcall(function() entry.tracer:Remove() end)
    end
    if entry.marker then
        pcall(function() entry.marker:Remove() end)
    end
    for _, frameObject in ipairs(entry.frames) do
        pcall(function() frameObject:Destroy() end)
    end
    if entry.billboard then
        pcall(function() entry.billboard:Destroy() end)
    end
end

local function createEspEntry(player)
    if espEntries[player] then return espEntries[player] end
    local entry = {
        player = player,
        frames = {},
        smoothPosition = Vector2.zero,
        smoothSize = Vector2.new(20, 40),
        smoothHealth = 1,
        hasView = false,
    }
    local box = newInstance("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false, Parent = espLayer, ZIndex = 2 })
    newInstance("UICorner", { CornerRadius = UDim.new(0, 4), Parent = box })
    newInstance("UIStroke", { Color = COLORS.accentMain, Thickness = 1.5, Transparency = 0.15, Parent = box })
    local distanceLabel = newInstance("TextLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 2), Size = UDim2.new(1, 0, 0, 12), Font = FONTS.bold, TextSize = 10, TextColor3 = COLORS.textSecondary, Text = "", Parent = box })
    local healthBack = newInstance("Frame", { BackgroundColor3 = COLORS.bgMain, BackgroundTransparency = 0.3, BorderSizePixel = 0, Visible = false, Parent = espLayer, ZIndex = 2 })
    newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = healthBack })
    local healthFill = newInstance("Frame", { BackgroundColor3 = HEALTH_COLOR_HIGH, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 1, 1, -1), Size = UDim2.new(1, -2, 1, -2), Parent = healthBack })
    newInstance("UICorner", { CornerRadius = UDim.new(1, 0), Parent = healthFill })

    entry.box = box
    entry.distanceLabel = distanceLabel
    entry.healthBack = healthBack
    entry.healthFill = healthFill
    entry.frames = { box, distanceLabel, healthBack, healthFill }

    if drawingAvailable then
        entry.tracer = Drawing.new("Line")
        entry.tracer.Visible = false
        entry.tracer.Thickness = 1
        entry.tracer.Transparency = 0.2
        entry.marker = Drawing.new("Circle")
        entry.marker.Visible = false
        entry.marker.Thickness = 2
        entry.marker.NumSides = 20
        entry.marker.Radius = 5
        entry.marker.Filled = true
        entry.marker.Transparency = 0.1
    end

    espEntries[player] = entry
    return entry
end

local function ensureEspBillboard(entry, character)
    if entry.billboard and entry.billboard.Parent then
        return
    end
    local head = character:FindFirstChild("Head") or character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
    if not head then return end
    entry.billboard = newInstance("BillboardGui", {
        Adornee = head,
        Size = UDim2.fromOffset(140, 20),
        StudsOffset = Vector3.new(0, 2.8, 0),
        AlwaysOnTop = true,
        MaxDistance = config.espRange + 100,
        LightInfluence = 0,
        ResetOnSpawn = false,
        Parent = espLayer,
    })
    entry.nameLabel = newInstance("TextLabel", {
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        Font = FONTS.bold,
        TextSize = 11,
        TextColor3 = COLORS.textPrimary,
        TextStrokeColor3 = COLORS.bgMain,
        TextStrokeTransparency = 0.4,
        Text = entry.player.DisplayName,
        Parent = entry.billboard,
    })
end

local function setEspEnabled(enabled)
    if enabled then
        for _, player in ipairs(playersService:GetPlayers()) do
            if player ~= localPlayer then
                createEspEntry(player)
            end
        end
    else
        for player, entry in pairs(espEntries) do
            releaseEspEntry(entry)
            espEntries[player] = nil
        end
    end
end

-- ============ Module: VFX ============
updateSpeedVFX = function()
    resourceManager:releaseByPrefix("vfx.speed")
    state.speedEmitter = nil
    local camera = workspaceService.CurrentCamera
    local hrp = state.hrp
    local active = config.speedEnabled and config.vfxEnabled and state.character and hrp
    if active then
        local attachmentTop = newInstance("Attachment", { Name = "NetTrailTop_" .. uiSuffix, Position = Vector3.new(0, 0.9, 0), Parent = hrp })
        local attachmentBottom = newInstance("Attachment", { Name = "NetTrailBottom_" .. uiSuffix, Position = Vector3.new(0, -0.9, 0), Parent = hrp })
        local trail = newInstance("Trail", {
            Name = "NetTrail_" .. uiSuffix,
            Attachment0 = attachmentTop,
            Attachment1 = attachmentBottom,
            Lifetime = 0.35,
            LightEmission = 1,
            LightInfluence = 0,
            FaceCamera = true,
            Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.75, 0.55), NumberSequenceKeypoint.new(1, 1) }),
            Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, COLORS.accentMain), ColorSequenceKeypoint.new(0.5, SONIC_CYAN), ColorSequenceKeypoint.new(1, COLORS.accentMain) }),
            WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.25) }),
            Parent = hrp,
        })
        local emitter = newInstance("ParticleEmitter", {
            Name = "NetSpeedParticles_" .. uiSuffix,
            Texture = "rbxasset://textures/particles/sparkles_main.dds",
            Color = ColorSequence.new(COLORS.accentMain, SONIC_CYAN),
            LightEmission = 0.9,
            Size = NumberSequence.new(0.4),
            Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) }),
            Lifetime = NumberRange.new(0.4, 0.7),
            Speed = NumberRange.new(3, 6),
            SpreadAngle = Vector2.new(180, 180),
            Rate = 0,
            Parent = hrp,
        })
        resourceManager:register("vfx.speed", attachmentTop)
        resourceManager:register("vfx.speed", attachmentBottom)
        resourceManager:register("vfx.speed", trail)
        resourceManager:register("vfx.speed", emitter)
        state.speedEmitter = emitter
        if camera then
            tween(camera, TweenInfo.new(0.7, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { FieldOfView = state.baseFieldOfView + 18 })
        end
    elseif camera then
        tween(camera, TweenInfo.new(0.7, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { FieldOfView = state.baseFieldOfView })
    end
end

updateFlyVFX = function()
    resourceManager:releaseByPrefix("vfx.fly")
    state.flyEmitter = nil
    local character = state.character
    local hrp = state.hrp
    local active = config.flyEnabled and config.vfxEnabled and character and hrp
    if active then
        local highlight = newInstance("Highlight", {
            Name = "NetFlyAura_" .. uiSuffix,
            FillColor = COLORS.accentMain,
            FillTransparency = 0.62,
            OutlineColor = COLORS.accentMain,
            OutlineTransparency = 0.18,
            DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
            Parent = character,
        })
        local emitter = newInstance("ParticleEmitter", {
            Name = "NetFlyParticles_" .. uiSuffix,
            Texture = "rbxasset://textures/particles/smoke_main.dds",
            Color = ColorSequence.new(COLORS.accentMain, COLORS.textPrimary),
            LightEmission = 0.45,
            Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 1.5) }),
            Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) }),
            Lifetime = NumberRange.new(0.7, 1.1),
            Speed = NumberRange.new(2, 5),
            SpreadAngle = Vector2.new(35, 35),
            EmissionDirection = Enum.NormalId.Bottom,
            Rate = 14,
            Parent = hrp,
        })
        resourceManager:register("vfx.fly", highlight)
        resourceManager:register("vfx.fly", emitter)
        state.flyEmitter = emitter
    end
end

-- ============ Module: Movement ============
local function restoreNoclip()
    for part in pairs(noclipCache) do
        if part and part.Parent then
            pcall(function()
                part.CanCollide = true
            end)
        end
    end
    table.clear(noclipCache)
end

local function destroyFlyConstraints()
    state.flyLinearVelocity = nil
    state.flyAlignOrientation = nil
    resourceManager:releaseByPrefix("char.fly")
end

local function buildFlyConstraints(hrp)
    destroyFlyConstraints()
    local rootAttachment = newInstance("Attachment", { Name = "NetFlyAttachment_" .. uiSuffix, Parent = hrp })
    local linearVelocity = newInstance("LinearVelocity", {
        Name = "NetFlyVelocity_" .. uiSuffix,
        Attachment0 = rootAttachment,
        RelativeTo = Enum.ActuatorRelativeTo.World,
        VelocityConstraintMode = Enum.VelocityConstraintMode.Vector,
        MaxForce = 400000,
        VectorVelocity = Vector3.zero,
        Parent = hrp,
    })
    local alignOrientation = newInstance("AlignOrientation", {
        Name = "NetFlyAlign_" .. uiSuffix,
        Mode = Enum.OrientationAlignmentMode.OneAttachment,
        Attachment0 = rootAttachment,
        Responsiveness = 60,
        MaxTorque = 500000,
        RigidityEnabled = false,
        CFrame = CFrame.new(),
        Parent = hrp,
    })
    state.flyLinearVelocity = linearVelocity
    state.flyAlignOrientation = alignOrientation
    resourceManager:register("char.fly", rootAttachment)
    resourceManager:register("char.fly", linearVelocity)
    resourceManager:register("char.fly", alignOrientation)
end

local function setFlyEnabled(enabled)
    if enabled then
        local hrp = state.hrp
        if not hrp then
            if state.loaded then
                notify("Полёт недоступен: персонаж не найден", "danger")
            end
            return
        end
        buildFlyConstraints(hrp)
        state.flyVelocity = hrp.AssemblyLinearVelocity
        if state.humanoid then
            pcall(function()
                state.humanoid:ChangeState(Enum.HumanoidStateType.Physics)
            end)
        end
        updateFlyVFX()
    else
        destroyFlyConstraints()
        state.flyVelocity = Vector3.zero
        if state.humanoid then
            pcall(function()
                state.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
            end)
        end
        updateFlyVFX()
    end
end

local function isDescendInputActive()
    local success, result = pcall(function()
        return userInputService:IsKeyDown(Enum.KeyCode.LeftControl) or userInputService:IsKeyDown(Enum.KeyCode.LeftShift)
    end)
    return success and result == true
end

local function getVoidLimit()
    if cachedVoidLimit == nil then
        local destroyHeight = -500
        if typeof(gethiddenproperty) == "function" then
            pcall(function()
                destroyHeight = gethiddenproperty(workspaceService, "FallenPartsDestroyHeight")
            end)
        end
        cachedVoidLimit = destroyHeight + 30
    end
    return cachedVoidLimit
end

-- ============ Module: Survival ============
local function restoreTrapImmunity()
    for part, originalValue in pairs(touchImmunityCache) do
        if part and part.Parent then
            pcall(function()
                part.CanTouch = originalValue
            end)
        end
    end
    table.clear(touchImmunityCache)
end

local function setTrapImmunity(enabled)
    if not enabled then
        restoreTrapImmunity()
    end
end

local function setDeadBlock(enabled)
    local humanoid = state.humanoid
    if humanoid then
        pcall(function()
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, not enabled)
        end)
    end
end

-- ============ Module: World ============
local function setFullbright(enabled)
    if enabled then
        lightingBackup = {
            Brightness = lightingService.Brightness,
            Ambient = lightingService.Ambient,
            OutdoorAmbient = lightingService.OutdoorAmbient,
            GlobalShadows = lightingService.GlobalShadows,
            FogEnd = lightingService.FogEnd,
            EnvironmentDiffuseScale = lightingService.EnvironmentDiffuseScale,
            EnvironmentSpecularScale = lightingService.EnvironmentSpecularScale,
        }
        lightingService.Brightness = 3
        lightingService.Ambient = Color3.fromRGB(200, 200, 200)
        lightingService.OutdoorAmbient = Color3.fromRGB(200, 200, 200)
        lightingService.GlobalShadows = false
        lightingService.FogEnd = 100000
        lightingService.EnvironmentDiffuseScale = 1
        lightingService.EnvironmentSpecularScale = 1
    elseif lightingBackup then
        pcall(function()
            lightingService.Brightness = lightingBackup.Brightness
            lightingService.Ambient = lightingBackup.Ambient
            lightingService.OutdoorAmbient = lightingBackup.OutdoorAmbient
            lightingService.GlobalShadows = lightingBackup.GlobalShadows
            lightingService.FogEnd = lightingBackup.FogEnd
            lightingService.EnvironmentDiffuseScale = lightingBackup.EnvironmentDiffuseScale
            lightingService.EnvironmentSpecularScale = lightingBackup.EnvironmentSpecularScale
        end)
        lightingBackup = nil
    end
end

-- ============ Page content ============
do
    local content, nextOrder = createSection(pages.combat, "АВТОНАВОДКА")
    local section = bindSection(content, nextOrder)
    section.toggle("Автонаводка", "aimEnabled", nil, { pinKey = "aim" })
    section.toggle("Захват цели", "aimTargetLock")
    section.button("Перехватить ближайшего", retakeNearestTarget)
    section.segmented("Точка прицела", { { label = "Голова", value = "Head" }, { label = "Торс", value = "Torso" } }, "aimPart")
    section.slider("Плавность наводки", "aimSmoothness", 1, 20, 1)
    section.slider("Радиус FOV", "aimFOV", 30, 350, 5)
    section.toggle("Показывать кольцо FOV", "aimShowFOV")
    section.slider("Упреждение", "aimPrediction", 0, 1, 0.05)
    section.toggle("Проверка стен", "aimWallCheck")
    section.toggle("Игнорировать союзников", "aimIgnoreTeam")
    section.toggle("Жёсткий тап по цели", "aimHardTap")
    section.toggle("Автоатака в зоне", "aimAutoAttack")
    section.toggle("Анти-отдача", "aimNoRecoil")
end

do
    local content, nextOrder = createSection(pages.combat, "ХИТБОКСЫ")
    local section = bindSection(content, nextOrder)
    section.toggle("Увеличение хитбоксов", "hitboxEnabled")
    section.slider("Размер", "hitboxSize", 4, 20, 1)
end

do
    local content, nextOrder = createSection(pages.combat, "КИЛЛАУРА")
    local section = bindSection(content, nextOrder)
    section.toggle("Киллаура", "auraEnabled", function()
        state.auraFailCount = 0
        state.auraSwingTimer = 0
        state.auraSuspendedUntil = 0
    end, { pinKey = "aura" })
    section.cycle("Метод атаки", { "activate", "touch", "bring", "click", "cycle" }, "auraMethod", function(value)
        return auraMethodLabels[value] or tostring(value)
    end)
    section.slider("Радиус", "auraRange", 8, 30, 1)
    section.slider("Интервал", "auraInterval", 0.1, 1, 0.05, { formatter = function(value) return string.format("%.2f сек", value) end })
end

do
    local content, nextOrder = createSection(pages.combat, "ОРБИТА")
    local section = bindSection(content, nextOrder)
    section.toggle("Орбита вокруг цели", "orbitEnabled")
    section.slider("Радиус орбиты", "orbitRadius", 4, 15, 1)
    section.slider("Скорость", "orbitSpeed", 0.5, 3, 0.1, { formatter = function(value) return string.format("x%.1f", value) end })
end

do
    local content, nextOrder = createSection(pages.movement, "СКОРОСТЬ")
    local section = bindSection(content, nextOrder)
    section.toggle("Скорость бега", "speedEnabled", function() updateSpeedVFX() end, { pinKey = "speed" })
    section.slider("Значение", "speedValue", 16, 80, 1)
    section.toggle("Защита от сброса", "antiReset")
end

do
    local content, nextOrder = createSection(pages.movement, "ПРЫЖКИ")
    local section = bindSection(content, nextOrder)
    section.toggle("Сила прыжка", "jumpPowerEnabled", function(value)
        if not value and state.humanoid then
            pcall(function()
                state.humanoid.UseJumpPower = true
                state.humanoid.JumpPower = 50
            end)
        end
    end)
    section.slider("Сила", "jumpPowerValue", 50, 150, 1)
    section.toggle("Бесконечный прыжок", "infiniteJump")
end

do
    local content, nextOrder = createSection(pages.movement, "ПОЛЁТ")
    local section = bindSection(content, nextOrder)
    section.toggle("Полёт", "flyEnabled", function(value)
        setFlyEnabled(value)
        flyDescendButton.Visible = value and true or false
    end, { pinKey = "fly" })
    section.slider("Скорость полёта", "flySpeed", 20, 150, 1)
end

do
    local content, nextOrder = createSection(pages.visual, "ESP ИГРОКОВ")
    local section = bindSection(content, nextOrder)
    section.toggle("ESP", "espEnabled", function(value) setEspEnabled(value) end)
    section.slider("Дистанция", "espRange", 50, 2000, 10, { formatter = function(value) return math.floor(value + 0.5) .. " м" end })
    section.toggle("Полоска здоровья", "espHealth")
    section.toggle("Никнеймы", "espNames")
    section.toggle("Трассеры", "espTracers")
    section.toggle("Индикатор за спиной", "espOffscreen")
end

do
    local content, nextOrder = createSection(pages.visual, "VFX ЭФФЕКТЫ")
    local section = bindSection(content, nextOrder)
    section.toggle("Клиентские эффекты", "vfxEnabled", function()
        updateSpeedVFX()
        updateFlyVFX()
    end)
    section.slider("Интенсивность", "vfxIntensity", 0.2, 2, 0.1, { formatter = function(value) return string.format("x%.1f", value) end })
end

do
    local content, nextOrder = createSection(pages.survival, "ЗАЩИТА")
    local section = bindSection(content, nextOrder)
    section.toggle("Иммунитет к ловушкам", "trapImmunity", function(value) setTrapImmunity(value) end)
    section.toggle("Анти-пустота", "antiVoidEnabled")
    section.toggle("Блокировка смерти", "deadBlock", function(value) setDeadBlock(value) end)
end

do
    local content, nextOrder = createSection(pages.world, "МИР И СИСТЕМА")
    local section = bindSection(content, nextOrder)
    section.toggle("NoClip", "noclipEnabled", function(value)
        if not value then
            restoreNoclip()
        end
    end)
    section.toggle("Fullbright", "fullbright", function(value) setFullbright(value) end)
    section.toggle("Анти-AFK", "antiAFK")
    section.toggle("Детектор наблюдателей", "observerBadge")
    section.button("Выгрузить скрипт", function() unloadScript() end, { danger = true })
end

-- ============ Notifications ============
notify = function(message, kind)
    task.spawn(function()
        if state.unloaded then return end
        local toast = newInstance("Frame", { BackgroundColor3 = COLORS.bgPanel, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Parent = notifyHolder, ZIndex = 8 })
        newInstance("UICorner", { CornerRadius = UDim.new(0, 10), Parent = toast })
        local toastStroke = newInstance("UIStroke", { Color = kind == "danger" and COLORS.danger or COLORS.accentMain, Thickness = 1, Transparency = 1, Parent = toast })
        local toastLabel = newInstance("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, -20, 1, 0), Position = UDim2.new(0, 10, 0, 0), Font = FONTS.medium, TextSize = 12, TextColor3 = COLORS.textPrimary, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, TextTransparency = 1, Text = message, Parent = toast })
        tween(toast, UI_TWEEN_INFO, { BackgroundTransparency = 0.05 })
        tween(toastStroke, UI_TWEEN_INFO, { Transparency = 0.25 })
        tween(toastLabel, UI_TWEEN_INFO, { TextTransparency = 0 })
        task.wait(2.8)
        if state.unloaded then
            toast:Destroy()
            return
        end
        local fadeTween = tween(toast, UI_TWEEN_INFO, { BackgroundTransparency = 1 })
        tween(toastStroke, UI_TWEEN_INFO, { Transparency = 1 })
        tween(toastLabel, UI_TWEEN_INFO, { TextTransparency = 1 })
        fadeTween.Completed:Once(function()
            toast:Destroy()
        end)
    end)
end

-- ============ Loop tasks ============
addHeartbeatTask("combat.scan", 0.2, function()
    table.clear(combatCandidates)
    local localCharacter = state.character
    local localHrp = state.hrp
    if not (localCharacter and localHrp) then return end
    for _, player in ipairs(playersService:GetPlayers()) do
        if player == localPlayer then continue end
        if config.aimIgnoreTeam and player.Team ~= nil and player.Team == localPlayer.Team then continue end
        local character = player.Character
        if not character then continue end
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if not (humanoid and humanoid.Health > 0 and hrp) then continue end
        local distance = (hrp.Position - localHrp.Position).Magnitude
        if distance > COMBAT_MAX_RANGE then continue end
        table.insert(combatCandidates, { player = player, character = character, humanoid = humanoid, hrp = hrp, distance = distance })
    end
    table.sort(combatCandidates, function(a, b)
        return a.distance < b.distance
    end)
end)

addHeartbeatTask("combat.aura", 0.1, function(elapsed)
    if not config.auraEnabled or state.unloaded then return end
    if os.clock() < state.auraSuspendedUntil then return end
    state.auraSwingTimer += elapsed
    if state.auraSwingTimer < config.auraInterval then return end
    state.auraSwingTimer = 0
    local target = combatCandidates[1]
    if not target or target.distance > config.auraRange then
        return
    end
    local success = performAttack(target.character)
    if success then
        -- Fail protection reset + visual feedback.
        state.auraFailCount = 0
        state.auraFlashUntil = os.clock() + 0.25
        local visuals = quickActionButtons.aura
        if visuals then
            tween(visuals.stroke, TweenInfo.new(0.1), { Color = COLORS.textPrimary })
            task.delay(0.14, function()
                if not state.unloaded then
                    tween(visuals.stroke, TweenInfo.new(0.2), { Color = config.auraEnabled and COLORS.accentMain or COLORS.borderColor })
                end
            end)
        end
    else
        state.auraFailCount += 1
        if state.auraFailCount >= AURA_FAIL_LIMIT then
            state.auraFailCount = 0
            state.auraSuspendedUntil = os.clock() + AURA_SUSPEND_SECONDS
            notify("Киллаура приостановлена: метод атаки недоступен", "danger")
        end
    end
end)

-- Aim runs post-camera via BindToRenderStep so smoothing is not overridden.
local aimRenderCallback
aimRenderCallback = function(deltaTime)
    local camera = workspaceService.CurrentCamera
    if not camera then return end
    local viewport = camera.ViewportSize
    local safeInset = guiService:GetGuiInset()

    if drawingAvailable and fovRing then
        if config.aimEnabled and config.aimShowFOV then
            fovRing.Visible = true
            fovRing.Position = viewport / 2
            fovRing.Radius = config.aimFOV
            fovRing.Color = COLORS.accentMain
        else
            fovRing.Visible = false
        end
    end

    if not config.aimEnabled or not (state.character and state.hrp and state.humanoid and state.humanoid.Health > 0) then
        state.aimTarget = nil
        if drawingAvailable and aimPulse then
            aimPulse.Visible = false
        end
        return
    end

    -- Killaura flash ring (priority over aim pulse).
    local auraFlashActive = os.clock() < state.auraFlashUntil
    if drawingAvailable and aimPulse and auraFlashActive then
        local auraTarget = combatCandidates[1]
        if auraTarget and auraTarget.hrp then
            local auraVpPos = camera:WorldToViewportPoint(auraTarget.hrp.Position)
            if auraVpPos.Z > 0 then
                aimPulse.Visible = true
                aimPulse.Position = Vector2.new(auraVpPos.X, auraVpPos.Y)
                aimPulse.Radius = 22 + math.sin(os.clock() * 12) * 4
                aimPulse.Color = COLORS.danger
            end
        end
    end

    local screenCenter = Vector2.new(viewport.X / 2 + safeInset.X, viewport.Y / 2 + safeInset.Y)
    local aimPoint = userInputService.TouchEnabled and screenCenter or userInputService:GetMouseLocation()

    -- Keep the locked target while it stays valid.
    local chosen = nil
    if config.aimTargetLock and state.aimTarget then
        local locked = state.aimTarget
        local lockedHrp = locked.hrp
        if lockedHrp and lockedHrp.Parent and locked.humanoid and locked.humanoid.Health > 0 then
            if (lockedHrp.Position - state.hrp.Position).Magnitude <= COMBAT_MAX_RANGE then
                chosen = locked
            end
        end
    end

    -- Otherwise pick the closest candidate to the cursor inside the FOV.
    if not chosen then
        local bestDistance = math.huge
        for index = 1, math.min(#combatCandidates, 8) do
            local candidate = combatCandidates[index]
            local aimPart = getAimPart(candidate.character)
            if not aimPart then continue end
            local vpPos = camera:WorldToViewportPoint(aimPart.Position)
            if vpPos.Z <= 0 then continue end
            local screenPos = Vector2.new(vpPos.X + safeInset.X, vpPos.Y + safeInset.Y)
            local screenDistance = (screenPos - aimPoint).Magnitude
            if screenDistance > config.aimFOV then continue end
            if config.aimWallCheck and not isPositionVisible(camera, aimPart.Position, candidate.character) then continue end
            if screenDistance < bestDistance then
                bestDistance = screenDistance
                chosen = candidate
            end
        end
    end
    state.aimTarget = chosen

    if not chosen then
        if drawingAvailable and aimPulse and not auraFlashActive then
            aimPulse.Visible = false
        end
        return
    end

    local aimPart = getAimPart(chosen.character)
    if not aimPart then return end
    local aimWorldPosition = aimPart.Position
    if config.aimPrediction > 0 then
        aimWorldPosition = aimWorldPosition + chosen.hrp.AssemblyLinearVelocity * config.aimPrediction
    end

    -- Frame-rate independent exponential smoothing towards the target.
    local desiredDirection = (aimWorldPosition - camera.CFrame.Position).Unit
    local alpha = 1 - math.exp(-deltaTime * config.aimSmoothness)
    local targetCFrame = CFrame.lookAt(camera.CFrame.Position, camera.CFrame.Position + desiredDirection)
    camera.CFrame = camera.CFrame:Lerp(targetCFrame, alpha)

    if config.aimAutoAttack or config.aimHardTap then
        if os.clock() - state.lastAutoAttackTime >= math.max(config.auraInterval, 0.15) then
            state.lastAutoAttackTime = os.clock()
            if config.aimAutoAttack then
                performAttack(chosen.character)
            end
            if config.aimHardTap then
                local tapVpPos = camera:WorldToViewportPoint(aimWorldPosition)
                if tapVpPos.Z > 0 then
                    emulateTap(Vector2.new(tapVpPos.X + safeInset.X, tapVpPos.Y + safeInset.Y))
                end
            end
        end
    end

    if drawingAvailable and aimPulse and not auraFlashActive then
        local pulseVpPos = camera:WorldToViewportPoint(aimWorldPosition)
        if pulseVpPos.Z > 0 then
            aimPulse.Visible = true
            aimPulse.Position = Vector2.new(pulseVpPos.X, pulseVpPos.Y)
            aimPulse.Radius = 9 + math.sin(os.clock() * 7) * 3
            aimPulse.Color = COLORS.accentMain
        else
            aimPulse.Visible = false
        end
    end
end

local AIM_RENDER_STEP_NAME = "NetErrrorAimStep_" .. uiSuffix
local aimRenderBound = false
resourceManager:register("loops.aimstep", function()
    if aimRenderBound then
        pcall(function()
            runService:UnbindFromRenderStep(AIM_RENDER_STEP_NAME)
        end)
        aimRenderBound = false
    end
end)
pcall(function()
    runService:BindToRenderStep(AIM_RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 2, aimRenderCallback)
    aimRenderBound = true
end)

addRenderTask("visual.esp", function(deltaTime)
    if not config.espEnabled then return end
    local camera = workspaceService.CurrentCamera
    if not camera then return end
    local safeInset = guiService:GetGuiInset()
    local viewport = camera.ViewportSize
    for player, entry in pairs(espEntries) do
        local visible = false
        local markerHrp = nil
        local character = player.Character
        if character and state.hrp then
            local humanoid = character:FindFirstChildOfClass("Humanoid")
            local hrp = character:FindFirstChild("HumanoidRootPart")
            if humanoid and humanoid.Health > 0 and hrp then
                local distance = (hrp.Position - state.hrp.Position).Magnitude
                if distance <= config.espRange then
                    markerHrp = hrp
                    local centerVp = camera:WorldToViewportPoint(hrp.Position)
                    if centerVp.Z > 0 then
                        local topVp = camera:WorldToViewportPoint(hrp.Position + Vector3.new(0, 2.7, 0))
                        local bottomVp = camera:WorldToViewportPoint(hrp.Position - Vector3.new(0, 2.3, 0))
                        local targetHeight = math.max(math.abs(bottomVp.Y - topVp.Y), 14)
                        local targetWidth = math.clamp(targetHeight * 0.62, 16, 220)
                        local targetCenter = Vector2.new(centerVp.X + safeInset.X, centerVp.Y + safeInset.Y)
                        local targetSize = Vector2.new(targetWidth, targetHeight)
                        local smoothing = entry.hasView and (1 - math.exp(-deltaTime * ESP_SMOOTH_RATE)) or 1
                        entry.smoothPosition = entry.smoothPosition:Lerp(targetCenter, smoothing)
                        entry.smoothSize = entry.smoothSize:Lerp(targetSize, smoothing)
                        local healthRatio =