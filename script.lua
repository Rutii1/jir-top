local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = Workspace.CurrentCamera

local TeamConfig = {
	Survivors = { Color = Color3.fromRGB(80, 80, 80), Enabled = false, Order = 1 },
	Killer = { Color = Color3.fromRGB(80, 80, 80), Enabled = false, Order = 2 },
	Spectator = { Color = Color3.fromRGB(80, 80, 80), Enabled = false, Order = 3 }
}

local KillerBeamConfig = { Enabled = false, Color = Color3.fromRGB(80, 80, 80), Length = 150 }

local ObjectESPConfig = {
    Generator = { Enabled = false, Color = Color3.fromRGB(255, 190, 70) },
    Pallet = { Enabled = false, Color = Color3.fromRGB(80, 190, 255) }
}

local VisualsConfig = {
	FOV = Camera.FieldOfView,
	FOVEnabled = false,
	Fullbright = false,
	NoShadows = false,
	NoFog = false,
	NoBlur = false,
	Zoom = false,
	ZoomDistance = 12,
	Stretch = false,
	StretchY = 0.75
}

local KillerLightConfig = {
	Enabled = false,
	Color = Color3.fromRGB(255, 80, 80),
	Brightness = 2,
	Range = 20,
	Angle = 90
}

local CrosshairConfig = {
	Enabled = false,
	Shape = "Cross",
	Size = 20,
	Thickness = 2,
	Color = Color3.fromRGB(255, 255, 255),
	Outline = true,
	OutlineColor = Color3.fromRGB(0, 0, 0),
	OffsetX = 0,
	OffsetY = 0
}

local CursorConfig = {
	Enabled = false,
	ToggleKey = Enum.KeyCode.F6,
	Shape = CrosshairConfig.Shape,
	Size = CrosshairConfig.Size,
	Thickness = CrosshairConfig.Thickness,
	Color = CrosshairConfig.Color,
	Outline = CrosshairConfig.Outline,
	OutlineColor = CrosshairConfig.OutlineColor
}

local UIConfig = {
	Width = 380,
	Height = 480,
	ToggleKey = Enum.KeyCode.G,
	Background = Color3.fromRGB(10, 10, 10),
	Card = Color3.fromRGB(19, 19, 19),
	Accent = Color3.fromRGB(255, 255, 255),
	Text = Color3.fromRGB(238, 238, 238)
}

local RecentColors = {}
local RecentColorButtons = {}
local waitingForMenuKey = false
local waitingForCursorKey = false
local waitingForStatsKey = false
local statsKeyCaptureJustCompleted = false
local isOpen = false
local EmitPicker

local origBrightness = Lighting.Brightness
local origClockTime = Lighting.ClockTime
local origGlobalShadows = Lighting.GlobalShadows
local origFogEnd = Lighting.FogEnd

-- Fullbright: значения принудительно держатся, даже если игра меняет
-- время суток / яркость (смена дня и ночи больше не сбрасывает эффект).
local FULLBRIGHT_BRIGHTNESS = 2
local FULLBRIGHT_CLOCKTIME = 14

local function EnforceFullbright()
	if not VisualsConfig.Fullbright then return end
	if math.abs(Lighting.Brightness - FULLBRIGHT_BRIGHTNESS) > 0.001 then
		Lighting.Brightness = FULLBRIGHT_BRIGHTNESS
	end
	if math.abs(Lighting.ClockTime - FULLBRIGHT_CLOCKTIME) > 0.001 then
		Lighting.ClockTime = FULLBRIGHT_CLOCKTIME
	end
end

-- Запоминаем актуальные значения игры (для восстановления при выключении),
-- игнорируя наши собственные изменения.
Lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
	if VisualsConfig.Fullbright
		and math.abs(Lighting.ClockTime - FULLBRIGHT_CLOCKTIME) <= 0.001 then
		return
	end
	origClockTime = Lighting.ClockTime
	EnforceFullbright()
end)

Lighting:GetPropertyChangedSignal("Brightness"):Connect(function()
	if VisualsConfig.Fullbright
		and math.abs(Lighting.Brightness - FULLBRIGHT_BRIGHTNESS) <= 0.001 then
		return
	end
	origBrightness = Lighting.Brightness
	EnforceFullbright()
end)

-- No Fog: туман и Atmosphere тоже принудительно отключены, пока опция включена
-- (если игра создаёт новый Atmosphere или меняет FogEnd, он снова убирается).
local NOFOG_END = 1000000
local RemovedAtmospheres = {}

local function EnforceNoFog()
	if not VisualsConfig.NoFog then return end
	if Lighting.FogEnd ~= NOFOG_END then
		Lighting.FogEnd = NOFOG_END
	end
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere then
		RemovedAtmospheres[atmosphere] = true
		atmosphere.Parent = nil
	end
end

local function RestoreFog()
	Lighting.FogEnd = origFogEnd
	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		for atmosphere in pairs(RemovedAtmospheres) do
			pcall(function() atmosphere.Parent = Lighting end)
			if atmosphere.Parent == Lighting then break end
		end
	end
	RemovedAtmospheres = {}
end

Lighting:GetPropertyChangedSignal("FogEnd"):Connect(function()
	if VisualsConfig.NoFog and Lighting.FogEnd == NOFOG_END then
		return
	end
	origFogEnd = Lighting.FogEnd
	EnforceNoFog()
end)

-- Страховка на случай, если игра меняет освещение способом без сигнала.
RunService.Heartbeat:Connect(function()
	EnforceFullbright()
	EnforceNoFog()
end)

-- Disable Blur: отключает все эффекты размытия (BlurEffect и DepthOfFieldEffect)
-- в Lighting и в камере. Если игра включает или создаёт их снова - они
-- отключаются заново.
local BlurOriginal = setmetatable({}, { __mode = "k" })  -- effect -> исходный Enabled
local BlurOurWrites = setmetatable({}, { __mode = "k" })
local BlurWatched = setmetatable({}, { __mode = "k" })

local function IsBlurEffect(instance)
	return instance:IsA("BlurEffect") or instance:IsA("DepthOfFieldEffect")
end

local function SuppressBlur(effect)
	if effect.Enabled then
		BlurOurWrites[effect] = true
		effect.Enabled = false
	end
end

local function HookBlurEffect(effect)
	if BlurOriginal[effect] ~= nil then
		if VisualsConfig.NoBlur then SuppressBlur(effect) end
		return
	end
	BlurOriginal[effect] = effect.Enabled
	effect:GetPropertyChangedSignal("Enabled"):Connect(function()
		if BlurOurWrites[effect] and not effect.Enabled then
			BlurOurWrites[effect] = nil -- это наше собственное выключение
			return
		end
		BlurOurWrites[effect] = nil
		BlurOriginal[effect] = effect.Enabled -- изменила игра
		if VisualsConfig.NoBlur then SuppressBlur(effect) end
	end)
	if VisualsConfig.NoBlur then SuppressBlur(effect) end
end

local function ScanBlurIn(container)
	if not container then return end
	for _, descendant in ipairs(container:GetDescendants()) do
		if IsBlurEffect(descendant) then
			HookBlurEffect(descendant)
		end
	end
end

local function WatchBlurContainer(container)
	if not container or BlurWatched[container] then return end
	BlurWatched[container] = true
	container.DescendantAdded:Connect(function(descendant)
		if IsBlurEffect(descendant) then
			HookBlurEffect(descendant)
		end
	end)
	ScanBlurIn(container)
end

-- pcall: ошибка в этих дополнительных функциях не должна ломать запуск меню.
pcall(WatchBlurContainer, Lighting)
pcall(WatchBlurContainer, Workspace.CurrentCamera)
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	pcall(WatchBlurContainer, Workspace.CurrentCamera)
end)

local function ApplyNoBlur(on)
	if on then
		ScanBlurIn(Lighting)
		ScanBlurIn(Workspace.CurrentCamera)
		for effect in pairs(BlurOriginal) do
			SuppressBlur(effect)
		end
	else
		for effect, wasEnabled in pairs(BlurOriginal) do
			if wasEnabled and effect.Parent and not effect.Enabled then
				effect.Enabled = true
			end
		end
	end
end

-- Camera zoom: фиксированная дистанция камеры (минимум = максимум = значение).
local origMaxZoom, origMinZoom

local function ApplyZoomDistance(distance)
	if LocalPlayer.CameraMaxZoomDistance == distance
		and LocalPlayer.CameraMinZoomDistance == distance then
		return
	end
	if distance > LocalPlayer.CameraMaxZoomDistance then
		LocalPlayer.CameraMaxZoomDistance = distance
		LocalPlayer.CameraMinZoomDistance = distance
	else
		LocalPlayer.CameraMinZoomDistance = distance
		LocalPlayer.CameraMaxZoomDistance = distance
	end
end

local function EnforceZoom()
	if VisualsConfig.Zoom then
		ApplyZoomDistance(VisualsConfig.ZoomDistance)
	end
end

local function SetZoomEnabled(enabled)
	VisualsConfig.Zoom = enabled
	if enabled then
		origMaxZoom = LocalPlayer.CameraMaxZoomDistance
		origMinZoom = LocalPlayer.CameraMinZoomDistance
		EnforceZoom()
	elseif origMaxZoom and origMinZoom then
		LocalPlayer.CameraMaxZoomDistance = origMaxZoom
		LocalPlayer.CameraMinZoomDistance = origMinZoom
	end
end

RunService.RenderStepped:Connect(EnforceZoom)

-- При каждой смене команды Fullbright и No Fog (если включены) выключаются
-- и включаются заново, а размытие перепроверяется.
local function ReapplyWorldEffects()
	-- выключить
	if VisualsConfig.Fullbright then
		Lighting.Brightness = origBrightness
		Lighting.ClockTime = origClockTime
	end
	if VisualsConfig.NoFog then
		RestoreFog()
	end
	-- включить заново
	if VisualsConfig.Fullbright then EnforceFullbright() end
	if VisualsConfig.NoFog then EnforceNoFog() end
	if VisualsConfig.NoBlur then ApplyNoBlur(true) end
end

local ActiveBeams = {}
local ActiveKillerLights = {}

local Theme = {
	Background = Color3.fromRGB(10, 10, 10),
	Card = Color3.fromRGB(19, 19, 19),
	Stroke = Color3.fromRGB(36, 36, 36),
	StrokeHover = Color3.fromRGB(58, 58, 58),
	Track = Color3.fromRGB(40, 40, 40),
	Muted = Color3.fromRGB(80, 80, 80),
	SubText = Color3.fromRGB(125, 125, 125),
	Text = Color3.fromRGB(238, 238, 238),
	White = Color3.fromRGB(255, 255, 255),
	Black = Color3.fromRGB(10, 10, 10)
}

local function New(className, props, children)
	local inst = Instance.new(className)
	local parent
	for key, value in pairs(props or {}) do
		if key == "Parent" then
			parent = value
		else
			inst[key] = value
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	if parent then inst.Parent = parent end
	return inst
end

local function Corner(radius)
	return New("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function Stroke(color, thickness)
	return New("UIStroke", {
		Color = color or Theme.Stroke,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	})
end

local function Tween(obj, goal, time, style)
	local tween = TweenService:Create(
		obj,
		TweenInfo.new(time or 0.18, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		goal
	)
	tween:Play()
	return tween
end

local function Apply(obj, goal, animate, time)
	if animate then
		Tween(obj, goal, time)
	else
		for key, value in pairs(goal) do obj[key] = value end
	end
end

local function Counter()
	local n = 0
	return function()
		n += 1
		return n
	end
end

local function Round(n)
	return math.floor(n + 0.5)
end

local function IsPointerStart(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function IsPointerMove(input)
	return input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch
end

local function PointerPosition(input)
	if input.UserInputType == Enum.UserInputType.Touch then
		return Vector2.new(input.Position.X, input.Position.Y) + GuiService:GetGuiInset()
	end
	return UserInputService:GetMouseLocation()
end

local ScreenGui = New("ScreenGui", {
	Name = "MinimalistCheatMenu",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 10,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = PlayerGui
})

local MainFrame = New("CanvasGroup", {
	Name = "MainFrame",
	Parent = ScreenGui,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(380, 480),
	BackgroundColor3 = Theme.Background,
	BorderSizePixel = 0,
	GroupTransparency = 1,
	Visible = false
}, {
	Corner(12),
	Stroke(Theme.Stroke, 1)
})

local WindowScale = New("UIScale", { Parent = MainFrame, Scale = 0.94 })

local Header = New("Frame", {
	Name = "Header",
	Parent = MainFrame,
	Size = UDim2.new(1, 0, 0, 52),
	BackgroundTransparency = 1,
	Active = true
})

New("Frame", {
	Parent = Header,
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 18, 0.5, 0),
	Size = UDim2.fromOffset(6, 6),
	BackgroundColor3 = Theme.White,
	BorderSizePixel = 0
}, { Corner(3) })

New("TextLabel", {
	Parent = Header,
	Position = UDim2.fromOffset(34, 0),
	Size = UDim2.new(1, -90, 1, 0),
	BackgroundTransparency = 1,
	Text = "CONTROL PANEL",
	TextColor3 = Theme.White,
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	TextXAlignment = Enum.TextXAlignment.Left
})

local KeyPill = New("Frame", {
	Parent = Header,
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -16, 0.5, 0),
	Size = UDim2.fromOffset(26, 22),
	BackgroundColor3 = Theme.Card,
	BorderSizePixel = 0
}, { Corner(6), Stroke(Theme.Stroke, 1) })

local KeyPillLabel = New("TextLabel", {
	Parent = KeyPill,
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Text = UIConfig.ToggleKey.Name,
	TextColor3 = Theme.SubText,
	Font = Enum.Font.GothamBold,
	TextSize = 11
})

local draggingWindow = false
local dragStart, startPos

Header.InputBegan:Connect(function(input)
	if IsPointerStart(input) then
		draggingWindow = true
		dragStart = input.Position
		startPos = MainFrame.Position
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if draggingWindow and IsPointerMove(input) then
		local delta = input.Position - dragStart
		MainFrame.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if IsPointerStart(input) then draggingWindow = false end
end)

-- ============================================================
-- Окно статистики (FPS / Ping / TPS)
-- Отдельное окно: не закрывается вместе с меню, всегда видно, пока включено.
-- Перетаскивается мышью (когда курсор свободен, например при открытом меню).
-- ============================================================
local Stats = game:GetService("Stats")

local StatsConfig = {
	Enabled = false,
	FPS = true,
	Ping = true,
	TPS = true,
	ToggleKey = Enum.KeyCode.F7,
	-- Собственные цвета окна (не зависят от темы меню)
	Background = Color3.fromRGB(10, 10, 10),
	Border = Color3.fromRGB(36, 36, 36),
	Label = Color3.fromRGB(125, 125, 125),
	Value = Color3.fromRGB(238, 238, 238)
}

local StatsStroke = Stroke(StatsConfig.Border, 1)

local StatsFrame = New("CanvasGroup", {
	Name = "StatsWindow",
	Parent = ScreenGui,
	Position = UDim2.fromOffset(math.max(20, Camera.ViewportSize.X - 140), 20),
	Size = UDim2.fromOffset(112, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = StatsConfig.Background,
	BorderSizePixel = 0,
	GroupTransparency = 1,
	Visible = false,
	Active = true
}, {
	Corner(10),
	StatsStroke,
	New("UIPadding", {
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
		PaddingTop = UDim.new(0, 9),
		PaddingBottom = UDim.new(0, 9)
	}),
	New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5) })
})

local StatValueLabels = {}
local StatNameLabels = {}

local function CreateStatRow(order, name)
	local row = New("Frame", {
		Parent = StatsFrame,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		Visible = false
	})
	local nameLabel = New("TextLabel", {
		Parent = row,
		Size = UDim2.fromScale(0.4, 1),
		BackgroundTransparency = 1,
		Text = name,
		TextColor3 = StatsConfig.Label,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left
	})
	table.insert(StatNameLabels, nameLabel)
	local value = New("TextLabel", {
		Parent = row,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0.6, 1),
		BackgroundTransparency = 1,
		Text = "--",
		TextColor3 = StatsConfig.Value,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right
	})
	table.insert(StatValueLabels, value)
	return row, value
end

local FPSRow, FPSValue = CreateStatRow(1, "FPS")
local PingRow, PingValue = CreateStatRow(2, "PING")
local TPSRow, TPSValue = CreateStatRow(3, "TPS")

local statsShown = false

local function RefreshStatsLayout()
	FPSRow.Visible = StatsConfig.FPS
	PingRow.Visible = StatsConfig.Ping
	TPSRow.Visible = StatsConfig.TPS

	local show = StatsConfig.Enabled
		and (StatsConfig.FPS or StatsConfig.Ping or StatsConfig.TPS)
	if show == statsShown then return end
	statsShown = show

	if show then
		StatsFrame.Visible = true
		Tween(StatsFrame, { GroupTransparency = 0 }, 0.2)
	else
		Tween(StatsFrame, { GroupTransparency = 1 }, 0.15)
		task.delay(0.16, function()
			if not statsShown then StatsFrame.Visible = false end
		end)
	end
end

-- Сюда позже записывается функция, которая синхронизирует переключатель в UI
-- (нужна, когда окно включается/выключается клавишей).
local setStatsToggleState

local function SetStatsEnabled(enabled)
	StatsConfig.Enabled = enabled
	if setStatsToggleState then setStatsToggleState(enabled, true) end
	RefreshStatsLayout()
end

local function ApplyStatsColors()
	StatsFrame.BackgroundColor3 = StatsConfig.Background
	StatsStroke.Color = StatsConfig.Border
	for _, label in ipairs(StatNameLabels) do
		label.TextColor3 = StatsConfig.Label
	end
	for _, label in ipairs(StatValueLabels) do
		label.TextColor3 = StatsConfig.Value
	end
end

-- Пинг в мс (туда-обратно). Основной источник - Stats, запасной - GetNetworkPing.
local function GetPingMs()
	local ok, value = pcall(function()
		return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
	end)
	if ok and type(value) == "number" then return value end

	local ok2, value2 = pcall(function()
		return LocalPlayer:GetNetworkPing() * 2000
	end)
	return (ok2 and value2) or 0
end

-- TPS: реальная частота физического шага (Workspace:GetRealPhysicsFPS()).
local function GetTPS()
	local ok, value = pcall(function()
		return Workspace:GetRealPhysicsFPS()
	end)
	return (ok and value) or 0
end

local statsTime, statsFrames = 0, 0
RunService.RenderStepped:Connect(function(dt)
	if not statsShown then
		statsTime, statsFrames = 0, 0
		return
	end

	statsFrames += 1
	statsTime += dt
	if statsTime < 0.5 then return end

	if StatsConfig.FPS then
		FPSValue.Text = tostring(Round(statsFrames / statsTime))
	end
	if StatsConfig.Ping then
		PingValue.Text = string.format("%d ms", Round(GetPingMs()))
	end
	if StatsConfig.TPS then
		TPSValue.Text = tostring(Round(GetTPS()))
	end
	statsTime, statsFrames = 0, 0
end)

-- Перетаскивание окна статистики
local draggingStats = false
local statsDragStart, statsStartPos

StatsFrame.InputBegan:Connect(function(input)
	if IsPointerStart(input) then
		draggingStats = true
		statsDragStart = input.Position
		statsStartPos = StatsFrame.Position
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if draggingStats and IsPointerMove(input) then
		local delta = input.Position - statsDragStart
		local camera = Workspace.CurrentCamera
		local view = camera and camera.ViewportSize or Vector2.new(1920, 1080)
		local size = StatsFrame.AbsoluteSize
		local x = math.clamp(statsStartPos.X.Offset + delta.X, 0, math.max(0, view.X - size.X))
		local y = math.clamp(statsStartPos.Y.Offset + delta.Y, 0, math.max(0, view.Y - size.Y))
		StatsFrame.Position = UDim2.fromOffset(x, y)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if IsPointerStart(input) then draggingStats = false end
end)

local TabCount = 4

local TabBar = New("Frame", {
	Name = "TabBar",
	Parent = MainFrame,
	Position = UDim2.fromOffset(0, 52),
	Size = UDim2.new(1, 0, 0, 30),
	BackgroundTransparency = 1
})

New("Frame", {
	Parent = TabBar,
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 0, 1, 0),
	Size = UDim2.new(1, 0, 0, 1),
	BackgroundColor3 = Theme.Stroke,
	BorderSizePixel = 0
})

local TabIndicator = New("Frame", {
	Parent = TabBar,
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5 / TabCount, 0, 1, 0),
	Size = UDim2.fromOffset(28, 2),
	BackgroundColor3 = Theme.White,
	BorderSizePixel = 0,
	ZIndex = 2
}, { Corner(1) })

local Content = New("Frame", {
	Name = "Content",
	Parent = MainFrame,
	Position = UDim2.fromOffset(0, 82),
	Size = UDim2.new(1, 0, 1, -82),
	BackgroundTransparency = 1,
	ClipsDescendants = true
})

local function CreatePage()
	return New("ScrollingFrame", {
		Parent = Content,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 2,
		ScrollBarImageColor3 = Theme.Muted,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Visible = false
	}, {
		New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }),
		New("UIPadding", {
			PaddingLeft = UDim.new(0, 16),
			PaddingRight = UDim.new(0, 16),
			PaddingTop = UDim.new(0, 14),
			PaddingBottom = UDim.new(0, 14)
		})
	})
end

local EspPage = CreatePage()
local VisPage = CreatePage()
local CrossPage = CreatePage()
local UIPage = CreatePage()
local Tabs = {}

local function SelectTab(index)
	for i, tab in ipairs(Tabs) do
		tab.Page.Visible = (i == index)
		Tween(tab.Button, { TextColor3 = (i == index) and Theme.White or Theme.SubText }, 0.15)
	end
	Tween(TabIndicator, { Position = UDim2.new((index - 0.5) / TabCount, 0, 1, 0) }, 0.22)
end

local function AddTab(name, index, page)
	local button = New("TextButton", {
		Parent = TabBar,
		Position = UDim2.new((index - 1) / TabCount, 0, 0, 0),
		Size = UDim2.new(1 / TabCount, 0, 1, -2),
		BackgroundTransparency = 1,
		Text = name,
		TextColor3 = Theme.SubText,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		AutoButtonColor = false
	})
	Tabs[index] = { Button = button, Page = page }
	button.MouseButton1Click:Connect(function() SelectTab(index) end)
	button.MouseEnter:Connect(function()
		if not Tabs[index].Page.Visible then Tween(button, { TextColor3 = Theme.Text }, 0.12) end
	end)
	button.MouseLeave:Connect(function()
		if not Tabs[index].Page.Visible then Tween(button, { TextColor3 = Theme.SubText }, 0.12) end
	end)
end

AddTab("ESP", 1, EspPage)
AddTab("VISUALS", 2, VisPage)
AddTab("CROSSHAIR", 3, CrossPage)
AddTab("UI", 4, UIPage)

local Sections = {}

-- Сворачиваемый раздел: минималистичная стрелка-шеврон справа.
-- Свёрнут: стрелка смотрит вниз. Развёрнут: плавно поворачивается на 180°.
local function CreateSectionLabel(page, order, text)
	local header = New("TextButton", {
		Parent = page,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Text = string.upper(text),
		TextColor3 = Theme.SubText,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left,
		AutoButtonColor = false
	}, {
		New("UIPadding", { PaddingLeft = UDim.new(0, 4) })
	})
	header:SetAttribute("IsSectionHeader", true)

	local chevron = New("Frame", {
		Name = "Chevron",
		Parent = header,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(12, 12),
		BackgroundTransparency = 1
	})

	-- Стрелка "v" из двух скруглённых палочек.
	local bars = {}
	for _, spec in ipairs({ { -2.5, 45 }, { 2.5, -45 } }) do
		table.insert(bars, New("Frame", {
			Parent = chevron,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, spec[1], 0.5, 0),
			Size = UDim2.fromOffset(7, 2),
			Rotation = spec[2],
			BackgroundColor3 = Theme.SubText,
			BorderSizePixel = 0
		}, { Corner(1) }))
	end

	local expanded = false
	local hovering = false

	local function paint(animate)
		local color = hovering and Theme.White or (expanded and Theme.Text or Theme.SubText)
		Apply(header, { TextColor3 = color }, animate, 0.15)
		for _, bar in ipairs(bars) do
			Apply(bar, { BackgroundColor3 = color }, animate, 0.15)
		end
	end

	local function applyVisibility()
		local orderedChildren = {}
		for _, child in ipairs(page:GetChildren()) do
			if child:IsA("GuiObject") then
				table.insert(orderedChildren, child)
			end
		end
		table.sort(orderedChildren, function(x, y)
			return x.LayoutOrder < y.LayoutOrder
		end)
		local insideSection = false
		for _, child in ipairs(orderedChildren) do
			if child == header then
				insideSection = true
			elseif insideSection then
				if child:GetAttribute("IsSectionHeader") then break end
				child.Visible = expanded
			end
		end
	end

	local function setExpanded(value, animate)
		expanded = value
		local rotation = expanded and 180 or 0
		if animate then
			Tween(chevron, { Rotation = rotation }, 0.28, Enum.EasingStyle.Quart)
		else
			chevron.Rotation = rotation
		end
		paint(animate)
		applyVisibility()
	end

	header.MouseEnter:Connect(function()
		hovering = true
		paint(true)
	end)
	header.MouseLeave:Connect(function()
		hovering = false
		paint(true)
	end)
	header.MouseButton1Click:Connect(function()
		setExpanded(not expanded, true)
	end)

	table.insert(Sections, {
		Header = header,
		Collapse = function() setExpanded(false, false) end
	})

	return header
end

local function CreateCard(page, order, height)
	local cardStroke = Stroke(Theme.Stroke, 1)
	local card = New("Frame", {
		Parent = page,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = Theme.Card,
		BorderSizePixel = 0
	}, { Corner(8), cardStroke })

	card.MouseEnter:Connect(function() Tween(cardStroke, { Color = Theme.StrokeHover }, 0.15) end)
	card.MouseLeave:Connect(function() Tween(cardStroke, { Color = Theme.Stroke }, 0.15) end)
	return card
end

local function CreateLabel(parent, text, position, size)
	return New("TextLabel", {
		Parent = parent,
		Position = position,
		Size = size,
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = Theme.Text,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left
	})
end

local function CreateToggle(parent, position, initial, onChange)
	local state = initial and true or false

	local switchStroke = Stroke(Theme.Muted, 1)
	local switch = New("TextButton", {
		Parent = parent,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = position,
		Size = UDim2.fromOffset(38, 20),
		BackgroundColor3 = Theme.Track,
		Text = "",
		AutoButtonColor = false,
		BorderSizePixel = 0
	}, { Corner(10), switchStroke })

	local knob = New("Frame", {
		Parent = switch,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = Theme.SubText,
		BorderSizePixel = 0
	}, { Corner(7) })

	local function render(animate)
		Apply(switch, { BackgroundColor3 = state and Theme.White or Theme.Track }, animate)
		Apply(switchStroke, { Color = state and Theme.White or Theme.Muted }, animate)
		Apply(knob, {
			Position = state and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
			BackgroundColor3 = state and Theme.Black or Theme.SubText
		}, animate)
	end

	render(false)

	local function setState(value, animate)
		state = value and true or false
		render(animate)
	end

	switch.MouseButton1Click:Connect(function()
		setState(not state, true)
		onChange(state)
	end)

	return switch, setState
end

local function CreateSlider(parent, position, size, minValue, maxValue, initial, valueLabel, onChange, options)
	options = options or {}
	local trackHeight = options.TrackHeight or 4

	local hit = New("TextButton", {
		Parent = parent,
		Position = position,
		Size = size,
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false
	})

	local track = New("Frame", {
		Parent = hit,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, 0, 0, trackHeight),
		BackgroundColor3 = Theme.Track,
		BorderSizePixel = 0
	}, { Corner(trackHeight / 2) })

	local fill = New("Frame", {
		Parent = track,
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.White,
		BorderSizePixel = 0,
		Visible = not options.NoFill
	}, { Corner(trackHeight / 2) })

	local handle = New("Frame", {
		Parent = track,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(12, 12),
		BackgroundColor3 = Theme.White,
		BorderSizePixel = 0,
		ZIndex = 2
	}, { Corner(6), Stroke(Theme.Black, 1) })

	local function setRatio(ratio, fire)
		ratio = math.clamp(ratio, 0, 1)
		fill.Size = UDim2.new(ratio, 0, 1, 0)
		handle.Position = UDim2.new(ratio, 0, 0.5, 0)
		local value = Round(minValue + (maxValue - minValue) * ratio)
		if valueLabel then valueLabel.Text = tostring(value) end
		if fire then onChange(value) end
	end

	setRatio((initial - minValue) / (maxValue - minValue), false)

	local dragging = false

	local function fromInput(input)
		local width = track.AbsoluteSize.X
		if width <= 0 then return end
		local x = PointerPosition(input).X - track.AbsolutePosition.X
		local inset = math.min(6, width / 2)
		local usableWidth = math.max(1, width - inset * 2)
		setRatio((x - inset) / usableWidth, true)
	end

	hit.InputBegan:Connect(function(input)
		if IsPointerStart(input) then
			dragging = true
			Tween(handle, { Size = UDim2.fromOffset(14, 14) }, 0.1)
			fromInput(input)
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if dragging and IsPointerMove(input) then fromInput(input) end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if dragging and IsPointerStart(input) then
			dragging = false
			Tween(handle, { Size = UDim2.fromOffset(12, 12) }, 0.1)
		end
	end)

	local function setValue(value)
		setRatio((value - minValue) / (maxValue - minValue), false)
	end

	return hit, track, setValue
end

local function CreateValueLabel(parent, text, position)
	return New("TextLabel", {
		Parent = parent,
		AnchorPoint = Vector2.new(1, 0),
		Position = position,
		Size = UDim2.fromOffset(60, 18),
		BackgroundTransparency = 1,
		Text = tostring(text),
		TextColor3 = Theme.SubText,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right
	})
end

local WHEEL_SIZE = 176
local WHEEL_R = WHEEL_SIZE / 2
local WHEEL_SPOKES = 180

local PickerState = { H = 0, S = 0, V = 1, Callback = nil, WhiteLock = false }
local pickerOpen = false
local wheelDragging = false

local PickerSheet = New("CanvasGroup", {
	Name = "ColorPicker",
	Parent = MainFrame,
	Position = UDim2.fromOffset(0, 52),
	Size = UDim2.new(1, 0, 1, -52),
	BackgroundColor3 = Theme.Background,
	BorderSizePixel = 0,
	GroupTransparency = 1,
	Visible = false,
	Active = true,
	ZIndex = 10
})

local PickerTitle = New("TextLabel", {
	Parent = PickerSheet,
	Position = UDim2.fromOffset(24, 16),
	Size = UDim2.new(1, -48, 0, 16),
	BackgroundTransparency = 1,
	Text = "COLOR",
	TextColor3 = Theme.SubText,
	Font = Enum.Font.GothamBold,
	TextSize = 10,
	TextXAlignment = Enum.TextXAlignment.Left
})

local PickerCloseButton = New("TextButton", {
	Parent = PickerSheet,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -18, 0, 12),
	Size = UDim2.fromOffset(26, 24),
	BackgroundColor3 = Theme.Card,
	Text = "X",
	TextColor3 = Theme.Text,
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	AutoButtonColor = false,
	BorderSizePixel = 0,
	ZIndex = 12
}, { Corner(6), Stroke(Theme.Stroke, 1) })

local WheelHolder = New("Frame", {
	Parent = PickerSheet,
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 46),
	Size = UDim2.fromOffset(WHEEL_SIZE, WHEEL_SIZE),
	BackgroundTransparency = 1
})

local Wheel = New("CanvasGroup", {
	Parent = WheelHolder,
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BorderSizePixel = 0
}, { Corner(WHEEL_R) })

do
	local spokeWidth = math.ceil(2 * math.pi * WHEEL_R / WHEEL_SPOKES) + 2
	for i = 0, WHEEL_SPOKES - 1 do
		local hue = i / WHEEL_SPOKES
		local angle = math.rad(i * 360 / WHEEL_SPOKES)
		New("Frame", {
			Parent = Wheel,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(
				Round(WHEEL_R + math.sin(angle) * WHEEL_R / 2),
				Round(WHEEL_R - math.cos(angle) * WHEEL_R / 2)
			),
			Size = UDim2.fromOffset(spokeWidth, WHEEL_R + 2),
			Rotation = i * 360 / WHEEL_SPOKES,
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0
		}, {
			New("UIGradient", {
				Rotation = 90,
				Color = ColorSequence.new(Color3.fromHSV(hue, 1, 1), Color3.new(1, 1, 1))
			})
		})
	end
end

local WheelShade = New("Frame", {
	Parent = Wheel,
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ZIndex = 2
})

New("Frame", {
	Parent = WheelHolder,
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	ZIndex = 3
}, { Corner(WHEEL_R), Stroke(Theme.Stroke, 1) })

local WheelCursor = New("Frame", {
	Parent = WheelHolder,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(WHEEL_R, WHEEL_R),
	Size = UDim2.fromOffset(14, 14),
	BackgroundTransparency = 1,
	ZIndex = 4
}, {
	Corner(7),
	Stroke(Theme.White, 2),
	New("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(10, 10),
		BackgroundTransparency = 1
	}, { Corner(5), Stroke(Theme.Black, 1) })
})

local WheelHit = New("TextButton", {
	Parent = WheelHolder,
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Text = "",
	AutoButtonColor = false,
	ZIndex = 5
})

New("TextLabel", {
	Parent = PickerSheet,
	Position = UDim2.fromOffset(24, 246),
	Size = UDim2.new(0.6, 0, 0, 16),
	BackgroundTransparency = 1,
	Text = "Brightness",
	TextColor3 = Theme.SubText,
	Font = Enum.Font.GothamMedium,
	TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Left
})

local BrightnessValue = CreateValueLabel(PickerSheet, 100, UDim2.new(1, -24, 0, 245))

local RefreshPicker

local function GetPickerColor()
	if PickerState.WhiteLock then
		return Color3.new(1, 1, 1)
	end
	return Color3.fromHSV(PickerState.H, PickerState.S, PickerState.V)
end

local _, BrightnessTrack, SetBrightness = CreateSlider(
	PickerSheet, UDim2.fromOffset(24, 268), UDim2.new(1, -48, 0, 18),
	0, 100, 100, BrightnessValue,
	function(value)
		PickerState.V = value / 100
		PickerState.WhiteLock = false
		RefreshPicker()
		if PickerState.Callback then
			PickerState.Callback(Color3.fromHSV(PickerState.H, PickerState.S, PickerState.V))
		end
	end,
	{ NoFill = true, TrackHeight = 8 }
)

BrightnessTrack.BackgroundColor3 = Color3.new(1, 1, 1)
local BrightnessGradient = New("UIGradient", { Parent = BrightnessTrack })

local PreviewSwatch = New("Frame", {
	Parent = PickerSheet,
	Position = UDim2.fromOffset(24, 304),
	Size = UDim2.fromOffset(32, 32),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BorderSizePixel = 0
}, { Corner(8), Stroke(Theme.Muted, 1) })

local HexStroke = Stroke(Theme.Stroke, 1)
local HexBox = New("TextBox", {
	Parent = PickerSheet,
	Position = UDim2.fromOffset(66, 304),
	Size = UDim2.fromOffset(110, 32),
	BackgroundColor3 = Theme.Card,
	BorderSizePixel = 0,
	Text = "#FFFFFF",
	PlaceholderText = "#RRGGBB",
	PlaceholderColor3 = Theme.Muted,
	TextColor3 = Theme.Text,
	Font = Enum.Font.GothamMedium,
	TextSize = 12,
	ClearTextOnFocus = false
}, { Corner(8), HexStroke })

local RecentLabel = New("TextLabel", {
	Parent = PickerSheet,
	Position = UDim2.fromOffset(24, 344),
	Size = UDim2.fromOffset(100, 16),
	BackgroundTransparency = 1,
	Text = "RECENT",
	TextColor3 = Theme.SubText,
	Font = Enum.Font.GothamBold,
	TextSize = 9,
	TextXAlignment = Enum.TextXAlignment.Left
})

local RecentHolder = New("Frame", {
	Parent = PickerSheet,
	Position = UDim2.fromOffset(24, 362),
	Size = UDim2.new(1, -48, 0, 28),
	BackgroundTransparency = 1
})

local WhiteResetButton = New("TextButton", {
	Parent = PickerSheet,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -24, 0, 342),
	Size = UDim2.fromOffset(74, 18),
	BackgroundColor3 = Theme.Card,
	Text = "WHITE",
	TextColor3 = Theme.Text,
	Font = Enum.Font.GothamBold,
	TextSize = 9,
	AutoButtonColor = false,
	BorderSizePixel = 0
}, { Corner(5), Stroke(Theme.Stroke, 1) })

local DoneButton = New("TextButton", {
	Parent = PickerSheet,
	Position = UDim2.fromOffset(24, 402),
	Size = UDim2.new(1, -48, 0, 34),
	BackgroundColor3 = Theme.White,
	Text = "DONE",
	TextColor3 = Theme.Black,
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	AutoButtonColor = false,
	BorderSizePixel = 0
}, { Corner(8) })

DoneButton.MouseEnter:Connect(function() Tween(DoneButton, { BackgroundColor3 = Color3.fromRGB(215, 215, 215) }, 0.12) end)
DoneButton.MouseLeave:Connect(function() Tween(DoneButton, { BackgroundColor3 = Theme.White }, 0.12) end)

local function ToHex(color)
	return string.format("#%02X%02X%02X", Round(color.R * 255), Round(color.G * 255), Round(color.B * 255))
end

local function FromHex(text)
	local clean = string.gsub(text, "#", "")
	if #clean == 6 and string.match(clean, "^%x+$") then
		local r = tonumber(string.sub(clean, 1, 2), 16)
		local g = tonumber(string.sub(clean, 3, 4), 16)
		local b = tonumber(string.sub(clean, 5, 6), 16)
		return Color3.fromRGB(r, g, b)
	end
	return nil
end

local function RememberColor(color)
	local hex = ToHex(color)
	for i = #RecentColors, 1, -1 do
		if ToHex(RecentColors[i]) == hex then
			table.remove(RecentColors, i)
		end
	end
	table.insert(RecentColors, 1, color)
	while #RecentColors > 3 do
		table.remove(RecentColors)
	end
	for i, button in ipairs(RecentColorButtons) do
		local recent = RecentColors[i]
		button.Visible = recent ~= nil
		if recent then button.BackgroundColor3 = recent end
	end
end

for i = 1, 3 do
	local button = New("TextButton", {
		Parent = RecentHolder,
		Position = UDim2.fromOffset((i - 1) * 36, 2),
		Size = UDim2.fromOffset(28, 24),
		BackgroundColor3 = Theme.Card,
		Text = "",
		Visible = false,
		AutoButtonColor = false,
		BorderSizePixel = 0
	}, { Corner(6), Stroke(Theme.Stroke, 1) })
	RecentColorButtons[i] = button
	button.MouseButton1Click:Connect(function()
		local recent = RecentColors[i]
		if recent then
			PickerState.H, PickerState.S, PickerState.V = recent:ToHSV()
			PickerState.WhiteLock = false
			EmitPicker()
		end
	end)
end

WhiteResetButton.MouseButton1Click:Connect(function()
	PickerState.H, PickerState.S = 0, 0
	PickerState.WhiteLock = true
	EmitPicker()
	RememberColor(Color3.new(1, 1, 1))
end)

RefreshPicker = function()
	local color = GetPickerColor()
	WheelShade.BackgroundTransparency = 1
	local angle = PickerState.H * 2 * math.pi
	WheelCursor.Position = UDim2.fromOffset(
		Round(WHEEL_R + math.sin(angle) * PickerState.S * WHEEL_R),
		Round(WHEEL_R - math.cos(angle) * PickerState.S * WHEEL_R)
	)
	BrightnessGradient.Color = ColorSequence.new(Color3.new(0, 0, 0), Color3.fromHSV(PickerState.H, PickerState.S, 1))
	PreviewSwatch.BackgroundColor3 = color
	HexBox.Text = ToHex(color)
	SetBrightness(Round(PickerState.V * 100))
end

EmitPicker = function()
	RefreshPicker()
	RememberColor(GetPickerColor())
	if PickerState.Callback then
		PickerState.Callback(GetPickerColor())
	end
end

local function WheelFromInput(input)
	local center = WheelHolder.AbsolutePosition + WheelHolder.AbsoluteSize / 2
	local radius = WheelHolder.AbsoluteSize.X / 2
	if radius <= 0 then return end
	local delta = PointerPosition(input) - center
	local dist = math.sqrt(delta.X * delta.X + delta.Y * delta.Y)

	PickerState.WhiteLock = false
	PickerState.S = math.clamp(dist / radius, 0, 1)
	if dist > 3 then
		PickerState.H = (math.deg(math.atan2(delta.X, -delta.Y)) % 360) / 360
	end
	EmitPicker()
end

WheelHit.InputBegan:Connect(function(input)
	if IsPointerStart(input) then
		wheelDragging = true
		WheelFromInput(input)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if wheelDragging and IsPointerMove(input) then WheelFromInput(input) end
end)

UserInputService.InputEnded:Connect(function(input)
	if IsPointerStart(input) then wheelDragging = false end
end)

HexBox.Focused:Connect(function() Tween(HexStroke, { Color = Theme.White }, 0.12) end)
HexBox.FocusLost:Connect(function()
	Tween(HexStroke, { Color = Theme.Stroke }, 0.12)
	local color = FromHex(HexBox.Text)
	if color then
		PickerState.H, PickerState.S, PickerState.V = color:ToHSV()
		PickerState.WhiteLock = false
		EmitPicker()
	else
		RefreshPicker()
	end
end)

local function ClosePicker()
	if not pickerOpen then return end
	pickerOpen = false
	wheelDragging = false
	PickerState.Callback = nil
	Tween(PickerSheet, { GroupTransparency = 1 }, 0.15)
	task.delay(0.16, function()
		if not pickerOpen then PickerSheet.Visible = false end
	end)
end

local function OpenColorPicker(title, color, callback)
	PickerState.Callback = nil
	PickerState.H, PickerState.S, PickerState.V = color:ToHSV()
	PickerState.WhiteLock = false
	RememberColor(color)
	PickerTitle.Text = string.upper(title)
	RefreshPicker()
	PickerState.Callback = callback
	pickerOpen = true
	PickerSheet.Visible = true
	Tween(PickerSheet, { GroupTransparency = 0 }, 0.18)
end

DoneButton.MouseButton1Click:Connect(ClosePicker)
PickerCloseButton.MouseButton1Click:Connect(ClosePicker)

local function CreateColorRow(parent, anchor, position, title, initialColor, onChange)
	local rgb = {
		Round(initialColor.R * 255),
		Round(initialColor.G * 255),
		Round(initialColor.B * 255)
	}

	local container = New("Frame", {
		Parent = parent,
		AnchorPoint = anchor,
		Position = position,
		Size = UDim2.fromOffset(138, 20),
		BackgroundTransparency = 1
	})

	local swatchStroke = Stroke(Theme.Muted, 1)
	local swatch = New("TextButton", {
		Parent = container,
		Size = UDim2.fromOffset(20, 20),
		BackgroundColor3 = initialColor,
		Text = "",
		AutoButtonColor = false,
		BorderSizePixel = 0
	}, { Corner(5), swatchStroke })

	swatch.MouseEnter:Connect(function() Tween(swatchStroke, { Color = Theme.White }, 0.12) end)
	swatch.MouseLeave:Connect(function() Tween(swatchStroke, { Color = Theme.Muted }, 0.12) end)

	local boxes = {}

	local function currentColor()
		return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
	end

	local function refresh()
		swatch.BackgroundColor3 = currentColor()
		for i = 1, 3 do boxes[i].Text = tostring(rgb[i]) end
	end

	local placeholders = { "R", "G", "B" }
	for i = 1, 3 do
		local boxStroke = Stroke(Theme.Stroke, 1)
		local box = New("TextBox", {
			Parent = container,
			Position = UDim2.fromOffset(28 + (i - 1) * 38, 0),
			Size = UDim2.fromOffset(34, 20),
			BackgroundColor3 = Theme.Background,
			BorderSizePixel = 0,
			Text = tostring(rgb[i]),
			PlaceholderText = placeholders[i],
			PlaceholderColor3 = Theme.Muted,
			TextColor3 = Theme.Text,
			Font = Enum.Font.GothamMedium,
			TextSize = 11,
			ClearTextOnFocus = false
		}, { Corner(5), boxStroke })
		boxes[i] = box

		box.Focused:Connect(function() Tween(boxStroke, { Color = Theme.White }, 0.12) end)
		box.FocusLost:Connect(function()
			Tween(boxStroke, { Color = Theme.Stroke }, 0.12)
			local num = tonumber(box.Text)
			if num then
				rgb[i] = math.clamp(math.floor(num), 0, 255)
			end
			refresh()
			onChange(currentColor())
		end)
	end

	swatch.MouseButton1Click:Connect(function()
		OpenColorPicker(title, currentColor(), function(color)
			rgb = { Round(color.R * 255), Round(color.G * 255), Round(color.B * 255) }
			refresh()
			onChange(currentColor())
		end)
	end)
end

local function UpdateCharacterHighlight(player)
	if player == LocalPlayer then return end
	local character = player.Character
	if not character then return end

	local highlight = character:FindFirstChild("TeamESP_Highlight")
	local teamName = player.Team and player.Team.Name
	local config = teamName and TeamConfig[teamName]

	if config and config.Enabled then
		if not highlight then
			highlight = Instance.new("Highlight")
			highlight.Name = "TeamESP_Highlight"
			highlight.FillTransparency = 0.65
			highlight.OutlineTransparency = 0
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.Parent = character
		end
		highlight.FillColor = config.Color
		highlight.OutlineColor = config.Color
	else
		if highlight then highlight:Destroy() end
	end
end

local function UpdateAllPlayers()
	for _, player in ipairs(Players:GetPlayers()) do
		UpdateCharacterHighlight(player)
	end
end

-- Object ESP: Generator и Pallet ищутся по имени (Model/BasePart, в имени
-- которых есть generator или pallet, без учёта регистра).
-- ESP окон полностью удалён.
local MAX_HIGHLIGHTS = 255 -- лимит Roblox на одновременно отображаемые Highlight
local OBJECT_ESP_MAX_DISTANCE = 400 -- studs от камеры

local ActiveObjectHighlights = {}
local ObjectCandidates = {} -- instance -> "Generator" | "Pallet"
local ObjectNames = {}      -- instance -> последнее известное имя

local ObjectKeywords = {
	{ Key = "Generator", Lower = "generator" },
	{ Key = "Pallet", Lower = "pallet" }
}

local ObjectPriority = { Generator = 1, Pallet = 2 }

local function IsObjectESPAllowed()
	local team = LocalPlayer.Team
	local teamName = team and team.Name
	return teamName == "Survivors" or teamName == "Killer"
end

local function ClassifyObject(instance)
	if not (instance:IsA("Model") or instance:IsA("BasePart")) then
		return nil
	end
	local lowered = string.lower(instance.Name)
	for _, entry in ipairs(ObjectKeywords) do
		if string.find(lowered, entry.Lower, 1, true) then
			return entry.Key
		end
	end
	return nil
end

local function RegisterObject(instance)
	local keyword = ClassifyObject(instance)
	if keyword then
		ObjectCandidates[instance] = keyword
		ObjectNames[instance] = instance.Name
	else
		ObjectCandidates[instance] = nil
		ObjectNames[instance] = nil
	end
	return keyword
end

local function RemoveObjectHighlight(instance)
	local highlight = ActiveObjectHighlights[instance]
	if highlight then
		highlight:Destroy()
		ActiveObjectHighlights[instance] = nil
	end
end

-- Не подсвечиваем вложенный объект, если его родитель уже подсвечивается.
-- Проверка общая для всех категорий, чтобы разные типы ESP не накладывались.
local function HasHighlightedClassifiedAncestor(instance, cameraPosition)
	local parent = instance.Parent
	while parent and parent ~= Workspace do
		local parentKeyword = ObjectCandidates[parent]
		local parentConfig = parentKeyword and ObjectESPConfig[parentKeyword]
		if parentConfig and parentConfig.Enabled then
			local ok, position = pcall(function()
				if parent:IsA("Model") then return parent:GetPivot().Position end
				if parent:IsA("BasePart") then return parent.Position end
			end)
			if ok and position and (position - cameraPosition).Magnitude <= OBJECT_ESP_MAX_DISTANCE then
				return true
			end
		end
		parent = parent.Parent
	end
	return false
end

local function ObjectPosition(instance)
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return instance.Position
end

local function CountPlayerHighlights()
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character and character:FindFirstChild("TeamESP_Highlight") then
			count += 1
		end
	end
	return count
end

local function EnsureObjectHighlight(instance, config)
	local highlight = ActiveObjectHighlights[instance]
	if not highlight or not highlight.Parent then
		if highlight then highlight:Destroy() end
		highlight = Instance.new("Highlight")
		highlight.Name = "ObjectESP_" .. instance.Name
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.FillTransparency = 0.65
		highlight.OutlineTransparency = 0
		highlight.Adornee = instance
		highlight.Parent = Workspace
		ActiveObjectHighlights[instance] = highlight
	end
	if highlight.Adornee ~= instance then highlight.Adornee = instance end
	if not highlight.Enabled then highlight.Enabled = true end
	if highlight.FillColor ~= config.Color then
		highlight.FillColor = config.Color
		highlight.OutlineColor = config.Color
	end
end

-- Полная пересборка подсветок (вкл/выкл ESP, смена команды, watchdog).
-- Проходит только по кэшу объектов, Workspace не сканируется.
local function RefreshObjectHighlights()
	local anyEnabled = false
	for _, config in pairs(ObjectESPConfig) do
		if config.Enabled then anyEnabled = true break end
	end

	if not (anyEnabled and IsObjectESPAllowed()) then
		for instance in pairs(ActiveObjectHighlights) do
			RemoveObjectHighlight(instance)
		end
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		for instance in pairs(ActiveObjectHighlights) do
			RemoveObjectHighlight(instance)
		end
		return
	end
	local camPos = camera.CFrame.Position
	local wanted = {}

	for instance, keyword in pairs(ObjectCandidates) do
		if not instance:IsDescendantOf(Workspace) then
			ObjectCandidates[instance] = nil
			ObjectNames[instance] = nil
		else
			-- Если объект переименовали, перепроверяем его категорию.
			if instance.Name ~= ObjectNames[instance] then
				keyword = RegisterObject(instance)
			end
			if keyword then
				local config = ObjectESPConfig[keyword]
				if config and config.Enabled and not HasHighlightedClassifiedAncestor(instance, camPos) then
					local ok, position = pcall(ObjectPosition, instance)
					if ok and position then
						local distance = (position - camPos).Magnitude
						if distance <= OBJECT_ESP_MAX_DISTANCE then
							wanted[#wanted + 1] = {
								Instance = instance,
								Config = config,
								Distance = distance,
								Priority = ObjectPriority[keyword] or 9
							}
						end
					end
				end
			end
		end
	end

	-- Сначала ближайшие; при одинаковой дистанции используется приоритет категории.
	table.sort(wanted, function(a, b)
			if math.abs(a.Distance - b.Distance) > 0.01 then
				return a.Distance < b.Distance
			end
			return a.Priority < b.Priority
	end)

	-- Учитываем Highlight игроков и лимит Roblox в 255 объектов.
	local budget = math.max(0, MAX_HIGHLIGHTS - CountPlayerHighlights())
	local keep = {}
	for i = 1, math.min(#wanted, budget) do
		keep[wanted[i].Instance] = wanted[i].Config
	end

	-- Сначала удаляем лишнее, затем создаём/обновляем выбранные подсветки.
	for instance in pairs(ActiveObjectHighlights) do
		if not keep[instance] then
			RemoveObjectHighlight(instance)
		end
	end
	for instance, config in pairs(keep) do
		EnsureObjectHighlight(instance, config)
	end
end

-- Быстрая смена цвета: трогает только уже созданные подсветки категории.
local function UpdateObjectColors(keyword)
	local config = ObjectESPConfig[keyword]
	if not config then return end
	for instance, highlight in pairs(ActiveObjectHighlights) do
		if ObjectCandidates[instance] == keyword then
			highlight.FillColor = config.Color
			highlight.OutlineColor = config.Color
		end
	end
end

Workspace.DescendantAdded:Connect(RegisterObject)

Workspace.DescendantRemoving:Connect(function(instance)
	if ObjectCandidates[instance] then
		ObjectCandidates[instance] = nil
		ObjectNames[instance] = nil
		RemoveObjectHighlight(instance)
	end
end)

-- Единственный начальный скан Workspace (по частям, чтобы не было фриза).
task.spawn(function()
	local descendants = Workspace:GetDescendants()
	for i, instance in ipairs(descendants) do
		if not ObjectCandidates[instance] then
			RegisterObject(instance)
		end
		if i % 2000 == 0 then task.wait() end
	end
	pcall(RefreshObjectHighlights)
end)

-- Watchdog: чинит подсветку, если игра что-то изменила у объекта.
task.spawn(function()
	while true do
		task.wait(0.25)
		pcall(RefreshObjectHighlights)
	end
end)

local function ClearBeams()
	for _, data in pairs(ActiveBeams) do
		if data.Beam then data.Beam:Destroy() end
		if data.Part0 then data.Part0:Destroy() end
		if data.Part1 then data.Part1:Destroy() end
	end
	ActiveBeams = {}
end

local function ClearKillerLights()
	for _, light in pairs(ActiveKillerLights) do
		if light and light.Parent then
			light:Destroy()
		end
	end
	ActiveKillerLights = {}
end

local CrosshairGui = New("ScreenGui", {
	Name = "CrosshairOverlay",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 5,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = PlayerGui
})

-- Курсор находится в отдельном ScreenGui поверх меню. Он не перехватывает ввод,
-- поэтому клики проходят к кнопкам и другим элементам интерфейса под ним.
local CursorGui = New("ScreenGui", {
	Name = "CustomCursorOverlay",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = ScreenGui.DisplayOrder + 1,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Enabled = true,
	Parent = PlayerGui
})

local CrosshairRoot = New("Frame", {
	Name = "Root",
	Parent = CrosshairGui,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(0, 0),
	BackgroundTransparency = 1
})

local CursorRoot = New("Frame", {
	Name = "CustomCursor",
	Parent = CursorGui,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(0, 0),
	BackgroundTransparency = 1,
	Visible = false,
	Active = false,
	Selectable = false,
	ZIndex = 20
})

local OUTLINE_THICKNESS = 1

local function MarkerRect(config, root, cx, cy, w, h, rotation, isRound)
	w, h = math.max(1, Round(w)), math.max(1, Round(h))
	local left = Round(cx - w / 2)
	local top = Round(cy - h / 2)

	if config.Outline then
		New("Frame", {
			Parent = root,
			Position = UDim2.fromOffset(left - OUTLINE_THICKNESS, top - OUTLINE_THICKNESS),
			Size = UDim2.fromOffset(w + OUTLINE_THICKNESS * 2, h + OUTLINE_THICKNESS * 2),
			Rotation = rotation or 0,
			BackgroundColor3 = config.OutlineColor,
			BorderSizePixel = 0,
			Active = false,
			Selectable = false,
			ZIndex = 1
		}, isRound and { New("UICorner", { CornerRadius = UDim.new(1, 0) }) } or nil)
	end

	New("Frame", {
		Parent = root,
		Position = UDim2.fromOffset(left, top),
		Size = UDim2.fromOffset(w, h),
		Rotation = rotation or 0,
		BackgroundColor3 = config.Color,
		BorderSizePixel = 0,
		Active = false,
		Selectable = false,
		ZIndex = 2
	}, isRound and { New("UICorner", { CornerRadius = UDim.new(1, 0) }) } or nil)
end

local function MarkerRing(config, root, diameter, thickness, isRound)
	local outerDiameter = math.max(2, Round(diameter))
	local visibleThickness = math.max(1, Round(thickness))

	local function ring(diam, strokeThickness, color, zIndex)
		local frame = New("Frame", {
			Parent = root,
			Position = UDim2.fromOffset(Round(-diam / 2), Round(-diam / 2)),
			Size = UDim2.fromOffset(diam, diam),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Active = false,
			Selectable = false,
			ZIndex = zIndex
		}, {
			New("UIStroke", {
				Color = color,
				Thickness = strokeThickness,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				LineJoinMode = isRound and Enum.LineJoinMode.Round or Enum.LineJoinMode.Miter
			})
		})
		if isRound then
			New("UICorner", { CornerRadius = UDim.new(1, 0), Parent = frame })
		end
	end

	if config.Outline then
		ring(outerDiameter, visibleThickness + OUTLINE_THICKNESS * 2, config.OutlineColor, 1)
	end
	ring(outerDiameter, visibleThickness, config.Color, 2)
end

local function BuildMarker(config, root, position)
	root:ClearAllChildren()
	root.Position = position
	if not config.Enabled then
		root.Visible = false
		return
	end
	root.Visible = true

	local size, thickness, shape = config.Size, config.Thickness, config.Shape
	if shape == "Cross" then
		local gap = math.max(2, math.floor(size * 0.25))
		local len = math.max(1, size / 2 - gap)
		local off = gap + len / 2
		MarkerRect(config, root, 0, -off, thickness, len)
		MarkerRect(config, root, 0, off, thickness, len)
		MarkerRect(config, root, -off, 0, len, thickness)
		MarkerRect(config, root, off, 0, len, thickness)
	elseif shape == "Plus" then
		MarkerRect(config, root, 0, 0, size, thickness)
		MarkerRect(config, root, 0, 0, thickness, size)
	elseif shape == "Dot" then
		local diameter = math.max(2, size * 0.4)
		MarkerRect(config, root, 0, 0, diameter, diameter, 0, true)
	elseif shape == "X" then
		MarkerRect(config, root, 0, 0, size, thickness, 45)
		MarkerRect(config, root, 0, 0, size, thickness, -45)
	elseif shape == "Circle" then
		MarkerRing(config, root, size, thickness, true)
	elseif shape == "Square" then
		MarkerRing(config, root, size, thickness, false)
	end
end

local function BuildCrosshair()
	BuildMarker(CrosshairConfig, CrosshairRoot,
		UDim2.new(0.5, CrosshairConfig.OffsetX, 0.5, CrosshairConfig.OffsetY))
end

local function BuildCustomCursor()
	BuildMarker(CursorConfig, CursorRoot, CursorRoot.Position)
end

local NextEspOrder = Counter()

local function CreateToggleCard(page, order, name, initial, callback)
	local card = CreateCard(page, order, 46)
	CreateLabel(card, name, UDim2.fromOffset(14, 0), UDim2.new(1, -80, 1, 0))
	local _, setState = CreateToggle(card, UDim2.new(1, -14, 0.5, 0), initial, callback)
	return card, setState
end

local function CreateSliderCard(page, order, name, minValue, maxValue, initial, callback)
	local card = CreateCard(page, order, 68)
	CreateLabel(card, name, UDim2.fromOffset(14, 10), UDim2.new(0.6, 0, 0, 18))
	local valueLabel = CreateValueLabel(card, initial, UDim2.new(1, -14, 0, 10))
	CreateSlider(card, UDim2.fromOffset(14, 38), UDim2.new(1, -28, 0, 18),
		minValue, maxValue, initial, valueLabel, callback)
	return card
end

local function CreateTeamCard(name, config)
	local card = CreateCard(EspPage, NextEspOrder(), 80)
	CreateLabel(card, name, UDim2.fromOffset(14, 0), UDim2.new(1, -80, 0, 48))
	CreateToggle(card, UDim2.new(1, -14, 0, 24), config.Enabled, function(state)
		config.Enabled = state
		UpdateAllPlayers()
	end)
	CreateColorRow(card, Vector2.new(0, 0), UDim2.fromOffset(14, 50), name .. " color", config.Color, function(color)
		config.Color = color
		UpdateAllPlayers()
	end)
end

local function CreateBeamCard()
	local card = CreateCard(EspPage, NextEspOrder(), 134)
	CreateLabel(card, "Killer Beam", UDim2.fromOffset(14, 0), UDim2.new(1, -80, 0, 48))
	CreateToggle(card, UDim2.new(1, -14, 0, 24), KillerBeamConfig.Enabled, function(state)
		KillerBeamConfig.Enabled = state
		if not state then ClearBeams() end
	end)
	CreateColorRow(card, Vector2.new(0, 0), UDim2.fromOffset(14, 50), "Beam color", KillerBeamConfig.Color, function(color)
		KillerBeamConfig.Color = color
	end)

	New("TextLabel", {
		Parent = card,
		Position = UDim2.fromOffset(14, 86),
		Size = UDim2.new(0.6, 0, 0, 16),
		BackgroundTransparency = 1,
		Text = "Beam length",
		TextColor3 = Theme.SubText,
		Font = Enum.Font.GothamMedium,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left
	})
	local valueLabel = CreateValueLabel(card, KillerBeamConfig.Length, UDim2.new(1, -14, 0, 85))
	CreateSlider(card, UDim2.fromOffset(14, 106), UDim2.new(1, -28, 0, 18), 50, 500,
		KillerBeamConfig.Length, valueLabel, function(value)
			KillerBeamConfig.Length = value
		end)
end

CreateSectionLabel(EspPage, NextEspOrder(), "Teams")
for _, teamName in ipairs({ "Survivors", "Killer", "Spectator" }) do
	CreateTeamCard(teamName, TeamConfig[teamName])
end

local function CreateObjectESPCard(name, config, displayName)
    local card = CreateCard(EspPage, NextEspOrder(), 80)
    CreateLabel(card, (displayName or name) .. " ESP", UDim2.fromOffset(14, 0), UDim2.new(1, -80, 0, 48))
    CreateToggle(card, UDim2.new(1, -14, 0, 24), config.Enabled, function(enabled)
        config.Enabled = enabled
        RefreshObjectHighlights()
    end)
    CreateColorRow(card, Vector2.new(0, 0), UDim2.fromOffset(14, 50), name .. " color", config.Color, function(color)
        config.Color = color
        UpdateObjectColors(name)
    end)
end

CreateSectionLabel(EspPage, NextEspOrder(), "Objects")
CreateObjectESPCard("Generator", ObjectESPConfig.Generator)
CreateObjectESPCard("Pallet", ObjectESPConfig.Pallet)

CreateSectionLabel(EspPage, NextEspOrder(), "Beam")
CreateBeamCard()

local NextVisOrder = Counter()

CreateSectionLabel(VisPage, NextVisOrder(), "Camera")

CreateSliderCard(VisPage, NextVisOrder(), "FOV Changer", 70, 120, 70, function(val)
	VisualsConfig.FOV = val
	VisualsConfig.FOVEnabled = true
end)

CreateToggleCard(VisPage, NextVisOrder(), "Camera zoom", false, function(enabled)
	SetZoomEnabled(enabled)
end)

CreateSliderCard(VisPage, NextVisOrder(), "Zoom distance", 1, 128, VisualsConfig.ZoomDistance, function(value)
	VisualsConfig.ZoomDistance = value
	EnforceZoom()
end)

CreateToggleCard(VisPage, NextVisOrder(), "Stretch 4:3", false, function(enabled)
	VisualsConfig.Stretch = enabled
end)

CreateSectionLabel(VisPage, NextVisOrder(), "World")

CreateToggleCard(VisPage, NextVisOrder(), "Fullbright", false, function(enabled)
	VisualsConfig.Fullbright = enabled
	if enabled then
		origBrightness = Lighting.Brightness
		origClockTime = Lighting.ClockTime
		EnforceFullbright()
	else
		Lighting.Brightness = origBrightness
		Lighting.ClockTime = origClockTime
	end
end)

CreateToggleCard(VisPage, NextVisOrder(), "Disable Shadows", false, function(enabled)
	VisualsConfig.NoShadows = enabled
	Lighting.GlobalShadows = not enabled
end)

CreateToggleCard(VisPage, NextVisOrder(), "Disable Fog", false, function(enabled)
	VisualsConfig.NoFog = enabled
	if enabled then
		origFogEnd = Lighting.FogEnd
		EnforceNoFog()
	else
		RestoreFog()
	end
end)

CreateToggleCard(VisPage, NextVisOrder(), "Disable Blur", false, function(enabled)
	VisualsConfig.NoBlur = enabled
	ApplyNoBlur(enabled)
end)

CreateSectionLabel(VisPage, NextVisOrder(), "Killer Light")

CreateToggleCard(VisPage, NextVisOrder(), "Killer Light", KillerLightConfig.Enabled, function(enabled)
	KillerLightConfig.Enabled = enabled
end)

do
	local card = CreateCard(VisPage, NextVisOrder(), 50)
	CreateLabel(card, "Light color", UDim2.fromOffset(14, 0), UDim2.new(0.5, 0, 1, 0))
	CreateColorRow(card, Vector2.new(1, 0.5), UDim2.new(1, -14, 0.5, 0),
		"Killer Light color", KillerLightConfig.Color, function(color)
			KillerLightConfig.Color = color
		end)
end

CreateSliderCard(VisPage, NextVisOrder(), "Light brightness", 0, 10, KillerLightConfig.Brightness, function(value)
	KillerLightConfig.Brightness = value
end)

CreateSliderCard(VisPage, NextVisOrder(), "Light range", 0, 60, KillerLightConfig.Range, function(value)
	KillerLightConfig.Range = value
end)

CreateSliderCard(VisPage, NextVisOrder(), "Light angle", 0, 180, KillerLightConfig.Angle, function(value)
	KillerLightConfig.Angle = value
end)

local NextCrossOrder = Counter()

local function CreateShapeSelector(page, order, shapes, initial, onChange)
	local rows = math.ceil(#shapes / 3)
	local gridHeight = rows * 30 + (rows - 1) * 8
	local card = CreateCard(page, order, gridHeight + 28)

	local grid = New("Frame", {
		Parent = card,
		Position = UDim2.fromOffset(14, 14),
		Size = UDim2.new(1, -28, 0, gridHeight),
		BackgroundTransparency = 1
	}, {
		New("UIGridLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			CellSize = UDim2.new(1 / 3, -6, 0, 30),
			CellPadding = UDim2.fromOffset(8, 8)
		})
	})

	local buttons = {}
	local selected = initial

	local function render(animate)
		for name, entry in pairs(buttons) do
			local active = (name == selected)
			Apply(entry.Button, {
				BackgroundColor3 = active and Theme.White or Theme.Background,
				TextColor3 = active and Theme.Black or Theme.SubText
			}, animate, 0.15)
			Apply(entry.Stroke, { Color = active and Theme.White or Theme.Stroke }, animate, 0.15)
		end
	end

	for index, name in ipairs(shapes) do
		local btnStroke = Stroke(Theme.Stroke, 1)
		local button = New("TextButton", {
			Parent = grid,
			LayoutOrder = index,
			Text = name,
			Font = Enum.Font.GothamMedium,
			TextSize = 12,
			BackgroundColor3 = Theme.Background,
			TextColor3 = Theme.SubText,
			AutoButtonColor = false,
			BorderSizePixel = 0
		}, { Corner(6), btnStroke })
		buttons[name] = { Button = button, Stroke = btnStroke }

		button.MouseEnter:Connect(function()
			if selected ~= name then Tween(button, { TextColor3 = Theme.Text }, 0.12) end
		end)
		button.MouseLeave:Connect(function()
			if selected ~= name then Tween(button, { TextColor3 = Theme.SubText }, 0.12) end
		end)
		button.MouseButton1Click:Connect(function()
			selected = name
			render(true)
			onChange(name)
		end)
	end

	render(false)
	return card
end

CreateSectionLabel(CrossPage, NextCrossOrder(), "Crosshair")

CreateToggleCard(CrossPage, NextCrossOrder(), "Enabled", CrosshairConfig.Enabled, function(state)
	CrosshairConfig.Enabled = state
	BuildCrosshair()
end)

CreateSectionLabel(CrossPage, NextCrossOrder(), "Shape")

CreateShapeSelector(CrossPage, NextCrossOrder(),
	{ "Cross", "Plus", "Dot", "Circle", "Square", "X" },
	CrosshairConfig.Shape,
	function(name)
		CrosshairConfig.Shape = name
		BuildCrosshair()
	end)

CreateSectionLabel(CrossPage, NextCrossOrder(), "Style")

CreateSliderCard(CrossPage, NextCrossOrder(), "Size", 4, 80, CrosshairConfig.Size, function(value)
	CrosshairConfig.Size = value
	BuildCrosshair()
end)

CreateSliderCard(CrossPage, NextCrossOrder(), "Thickness", 1, 10, CrosshairConfig.Thickness, function(value)
	CrosshairConfig.Thickness = value
	BuildCrosshair()
end)

do
	local card = CreateCard(CrossPage, NextCrossOrder(), 46)
	CreateLabel(card, "Color", UDim2.fromOffset(14, 0), UDim2.new(0.5, 0, 1, 0))
	CreateColorRow(card, Vector2.new(1, 0.5), UDim2.new(1, -14, 0.5, 0), "Crosshair color",
		CrosshairConfig.Color, function(color)
			CrosshairConfig.Color = color
			BuildCrosshair()
		end)
end

CreateSectionLabel(CrossPage, NextCrossOrder(), "Outline")

do
	local card = CreateCard(CrossPage, NextCrossOrder(), 80)
	CreateLabel(card, "Outline", UDim2.fromOffset(14, 0), UDim2.new(1, -80, 0, 48))
	CreateToggle(card, UDim2.new(1, -14, 0, 24), CrosshairConfig.Outline, function(state)
		CrosshairConfig.Outline = state
		BuildCrosshair()
	end)
	CreateColorRow(card, Vector2.new(0, 0), UDim2.fromOffset(14, 50), "Outline color",
		CrosshairConfig.OutlineColor, function(color)
			CrosshairConfig.OutlineColor = color
			BuildCrosshair()
		end)
end

CreateSectionLabel(CrossPage, NextCrossOrder(), "Position")

local function CreateOffsetCard(name, configKey)
	local card = CreateCard(CrossPage, NextCrossOrder(), 82)
	CreateLabel(card, name, UDim2.fromOffset(14, 10), UDim2.new(0.5, 0, 0, 18))
	local valueLabel = CreateValueLabel(card, CrosshairConfig[configKey], UDim2.new(1, -76, 0, 10))
	local reset = New("TextButton", {
		Parent = card,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 8),
		Size = UDim2.fromOffset(48, 20),
		BackgroundColor3 = Theme.Background,
		Text = "RESET",
		TextColor3 = Theme.SubText,
		Font = Enum.Font.GothamBold,
		TextSize = 9,
		AutoButtonColor = false,
		BorderSizePixel = 0
	}, { Corner(5), Stroke(Theme.Stroke, 1) })
	local _, _, setValue = CreateSlider(card, UDim2.fromOffset(14, 44), UDim2.new(1, -28, 0, 18),
		-200, 200, CrosshairConfig[configKey], valueLabel, function(value)
			CrosshairConfig[configKey] = value
			BuildCrosshair()
		end)
	reset.MouseButton1Click:Connect(function()
		CrosshairConfig[configKey] = 0
		setValue(0)
		BuildCrosshair()
	end)
end

CreateOffsetCard("Offset X", "OffsetX")
CreateOffsetCard("Offset Y", "OffsetY")


local NextUIOrder = Counter()

CreateSectionLabel(UIPage, NextUIOrder(), "Menu")

local function CreateMenuSizeCard()
	local card = CreateCard(UIPage, NextUIOrder(), 82)
	CreateLabel(card, "Menu size", UDim2.fromOffset(14, 10), UDim2.new(0.6, 0, 0, 18))
	local valueLabel = CreateValueLabel(card, UIConfig.Width, UDim2.new(1, -14, 0, 10))
	CreateSlider(card, UDim2.fromOffset(14, 44), UDim2.new(1, -28, 0, 18),
		300, 520, UIConfig.Width, valueLabel, function(value)
			UIConfig.Width = value
			UIConfig.Height = Round(value * 480 / 380)
			MainFrame.Size = UDim2.fromOffset(UIConfig.Width, UIConfig.Height)
		end)
end

CreateMenuSizeCard()

local function CreateToggleKeyCard()
	local card = CreateCard(UIPage, NextUIOrder(), 62)
	CreateLabel(card, "Open menu key", UDim2.fromOffset(14, 8), UDim2.new(0.55, 0, 0, 18))
	local bindButton = New("TextButton", {
		Parent = card,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 8),
		Size = UDim2.fromOffset(112, 26),
		BackgroundColor3 = Theme.Background,
		Text = UIConfig.ToggleKey.Name,
		TextColor3 = Theme.Text,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		AutoButtonColor = false,
		BorderSizePixel = 0
	}, { Corner(6), Stroke(Theme.Stroke, 1) })
	bindButton.MouseButton1Click:Connect(function()
		waitingForMenuKey = true
		bindButton.Text = "PRESS A KEY"
	end)
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if waitingForMenuKey and input.UserInputType == Enum.UserInputType.Keyboard then
			if input.KeyCode ~= Enum.KeyCode.Unknown then
				UIConfig.ToggleKey = input.KeyCode
				KeyPillLabel.Text = input.KeyCode.Name
				bindButton.Text = input.KeyCode.Name
				waitingForMenuKey = false
			end
		end
	end)
end

CreateToggleKeyCard()

CreateSectionLabel(UIPage, NextUIOrder(), "Stats window")

local _, statsToggleSetter = CreateToggleCard(UIPage, NextUIOrder(), "Show stats window", StatsConfig.Enabled, function(enabled)
	SetStatsEnabled(enabled)
end)
setStatsToggleState = statsToggleSetter

local function CreateStatsToggleKeyCard()
	local card = CreateCard(UIPage, NextUIOrder(), 46)
	CreateLabel(card, "Stats toggle key", UDim2.fromOffset(14, 0), UDim2.new(0.55, 0, 1, 0))
	local bindButton = New("TextButton", {
		Parent = card,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(112, 26),
		BackgroundColor3 = Theme.Background,
		Text = StatsConfig.ToggleKey.Name,
		TextColor3 = Theme.Text,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		AutoButtonColor = false,
		BorderSizePixel = 0
	}, { Corner(6), Stroke(Theme.Stroke, 1) })
	bindButton.MouseButton1Click:Connect(function()
		waitingForStatsKey = true
		bindButton.Text = "PRESS A KEY"
	end)
	UserInputService.InputBegan:Connect(function(input)
		if waitingForStatsKey and input.UserInputType == Enum.UserInputType.Keyboard
			and input.KeyCode ~= Enum.KeyCode.Unknown then
			StatsConfig.ToggleKey = input.KeyCode
			bindButton.Text = input.KeyCode.Name
			waitingForStatsKey = false
			statsKeyCaptureJustCompleted = true
		end
	end)
end

CreateStatsToggleKeyCard()

CreateToggleCard(UIPage, NextUIOrder(), "FPS", StatsConfig.FPS, function(enabled)
	StatsConfig.FPS = enabled
	RefreshStatsLayout()
end)

CreateToggleCard(UIPage, NextUIOrder(), "Ping", StatsConfig.Ping, function(enabled)
	StatsConfig.Ping = enabled
	RefreshStatsLayout()
end)

CreateToggleCard(UIPage, NextUIOrder(), "TPS", StatsConfig.TPS, function(enabled)
	StatsConfig.TPS = enabled
	RefreshStatsLayout()
end)

CreateSectionLabel(UIPage, NextUIOrder(), "Stats colors")

local function CreateStatsColorRow(title, key)
	local card = CreateCard(UIPage, NextUIOrder(), 46)
	CreateLabel(card, title, UDim2.fromOffset(14, 0), UDim2.new(0.48, 0, 1, 0))
	CreateColorRow(card, Vector2.new(1, 0.5), UDim2.new(1, -14, 0.5, 0), "Stats " .. string.lower(title), StatsConfig[key], function(color)
		StatsConfig[key] = color
		ApplyStatsColors()
	end)
end

CreateStatsColorRow("Background", "Background")
CreateStatsColorRow("Border", "Border")
CreateStatsColorRow("Labels", "Label")
CreateStatsColorRow("Values", "Value")

CreateSectionLabel(UIPage, NextUIOrder(), "Custom cursor")

local setCursorToggleState
local SetCursorEnabled
local _, cursorToggleSetter = CreateToggleCard(UIPage, NextUIOrder(), "Enabled", CursorConfig.Enabled, function(state)
	SetCursorEnabled(state)
end)
setCursorToggleState = cursorToggleSetter

CreateShapeSelector(UIPage, NextUIOrder(),
	{ "Cross", "Plus", "Dot", "Circle", "Square", "X" },
	CursorConfig.Shape,
	function(shape)
		CursorConfig.Shape = shape
		BuildCustomCursor()
	end)

CreateSliderCard(UIPage, NextUIOrder(), "Cursor size", 4, 80, CursorConfig.Size, function(value)
	CursorConfig.Size = value
	BuildCustomCursor()
end)

CreateSliderCard(UIPage, NextUIOrder(), "Cursor thickness", 1, 10, CursorConfig.Thickness, function(value)
	CursorConfig.Thickness = value
	BuildCustomCursor()
end)

do
	local card = CreateCard(UIPage, NextUIOrder(), 46)
	CreateLabel(card, "Cursor color", UDim2.fromOffset(14, 0), UDim2.new(0.5, 0, 1, 0))
	CreateColorRow(card, Vector2.new(1, 0.5), UDim2.new(1, -14, 0.5, 0), "Cursor color",
		CursorConfig.Color, function(color)
			CursorConfig.Color = color
			BuildCustomCursor()
		end)
end

do
	local card = CreateCard(UIPage, NextUIOrder(), 80)
	CreateLabel(card, "Cursor outline", UDim2.fromOffset(14, 0), UDim2.new(1, -80, 0, 48))
	CreateToggle(card, UDim2.new(1, -14, 0, 24), CursorConfig.Outline, function(state)
		CursorConfig.Outline = state
		BuildCustomCursor()
	end)
	CreateColorRow(card, Vector2.new(0, 0), UDim2.fromOffset(14, 50), "Cursor outline color",
		CursorConfig.OutlineColor, function(color)
			CursorConfig.OutlineColor = color
			BuildCustomCursor()
		end)
end

local cursorKeyCaptureJustCompleted = false
local virtualCursorPosition = UserInputService:GetMouseLocation()

local function IsLocalPlayerSpectator()
	local teamName = LocalPlayer.Team and LocalPlayer.Team.Name
	-- Поддерживаем оба варианта названия команды.
	return teamName == "Spectators" or teamName == "Spectator"
end

-- Кастомный курсор разрешён только в командах Survivors и Killer.
-- В Spectator (и вне этих команд) он не работает вообще.
local function IsCustomCursorAllowed()
	local teamName = LocalPlayer.Team and LocalPlayer.Team.Name
	return teamName == "Survivors" or teamName == "Killer"
end

local function UpdateCursorDisplay()
	-- Кастомный курсор виден только при открытом меню и включённом
	-- переключателе. Реальный курсор (MouseIconEnabled и т.п.) не трогаем:
	-- им управляет игра.
	CursorRoot.Visible = isOpen and CursorConfig.Enabled and IsCustomCursorAllowed()
end

SetCursorEnabled = function(enabled)
	CursorConfig.Enabled = enabled
	if setCursorToggleState then setCursorToggleState(enabled, true) end
	BuildCustomCursor()
	UpdateCursorDisplay()
end

local function CreateCursorToggleKeyCard()
	local card = CreateCard(UIPage, NextUIOrder(), 62)
	CreateLabel(card, "Cursor toggle key", UDim2.fromOffset(14, 8), UDim2.new(0.55, 0, 0, 18))
	local bindButton = New("TextButton", {
		Parent = card,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 8),
		Size = UDim2.fromOffset(112, 26),
		BackgroundColor3 = Theme.Background,
		Text = CursorConfig.ToggleKey.Name,
		TextColor3 = Theme.Text,
		Font = Enum.Font.GothamBold,
		TextSize = 10,
		AutoButtonColor = false,
		BorderSizePixel = 0
	}, { Corner(6), Stroke(Theme.Stroke, 1) })
	bindButton.MouseButton1Click:Connect(function()
		waitingForCursorKey = true
		bindButton.Text = "PRESS A KEY"
	end)
	UserInputService.InputBegan:Connect(function(input)
		if waitingForCursorKey and input.UserInputType == Enum.UserInputType.Keyboard
			and input.KeyCode ~= Enum.KeyCode.Unknown then
			CursorConfig.ToggleKey = input.KeyCode
			bindButton.Text = input.KeyCode.Name
			waitingForCursorKey = false
			cursorKeyCaptureJustCompleted = true
		end
	end)
end

CreateCursorToggleKeyCard()
CreateSectionLabel(UIPage, NextUIOrder(), "Colors")

local function ApplyTheme()
	Theme.Background = UIConfig.Background
	Theme.Card = UIConfig.Card
	Theme.White = UIConfig.Accent
	Theme.Text = UIConfig.Text
	MainFrame.BackgroundColor3 = Theme.Background
	PickerSheet.BackgroundColor3 = Theme.Background
	for _, page in ipairs({EspPage, VisPage, CrossPage, UIPage}) do
		for _, child in ipairs(page:GetChildren()) do
			if child:IsA("Frame") then
				if child:FindFirstChildOfClass("UIStroke") then
					child.BackgroundColor3 = Theme.Card
				end
			end
		end
	end
	TabIndicator.BackgroundColor3 = Theme.White
end

local function CreateThemeColorRow(title, key)
	local card = CreateCard(UIPage, NextUIOrder(), 46)
	CreateLabel(card, title, UDim2.fromOffset(14, 0), UDim2.new(0.48, 0, 1, 0))
	CreateColorRow(card, Vector2.new(1, 0.5), UDim2.new(1, -14, 0.5, 0), title, UIConfig[key], function(color)
		UIConfig[key] = color
		ApplyTheme()
	end)
end

CreateThemeColorRow("Background", "Background")
CreateThemeColorRow("Cards", "Card")
CreateThemeColorRow("Accent", "Accent")
CreateThemeColorRow("Text", "Text")

BuildCrosshair()
BuildCustomCursor()
UpdateCursorDisplay()

-- По умолчанию все разделы свёрнуты.
for _, section in ipairs(Sections) do
	section.Collapse()
end

SelectTab(1)

RunService:BindToRenderStep("StretchResolution", Enum.RenderPriority.Camera.Value + 1, function()
	if VisualsConfig.Stretch then
		local cam = Workspace.CurrentCamera
		cam.CFrame = cam.CFrame * CFrame.new(0, 0, 0, 1, 0, 0, 0, VisualsConfig.StretchY, 0, 0, 0, 1)
	end
end)

local function UpdateKillerLights()
	if not KillerLightConfig.Enabled then
		if next(ActiveKillerLights) then
			ClearKillerLights()
		end
		return
	end

	local activeUserIds = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Team and player.Team.Name == "Killer" then
			local character = player.Character
			local torso = character and (
				character:FindFirstChild("UpperTorso")
				or character:FindFirstChild("Torso")
				or character:FindFirstChild("LowerTorso")
			)
			if torso and torso:IsA("BasePart") then
				local userId = player.UserId
				activeUserIds[userId] = true

				local light = ActiveKillerLights[userId]
				if not light or light.Parent ~= torso then
					if light then light:Destroy() end
					light = Instance.new("SpotLight")
					light.Name = "KillerTeamSpotLight"
					light.Face = Enum.NormalId.Front
					light.Parent = torso
					ActiveKillerLights[userId] = light
				end

				light.Color = KillerLightConfig.Color
				light.Brightness = KillerLightConfig.Brightness
				light.Range = KillerLightConfig.Range
				light.Angle = KillerLightConfig.Angle
			end
		end
	end

	for userId, light in pairs(ActiveKillerLights) do
		if not activeUserIds[userId] then
			if light then light:Destroy() end
			ActiveKillerLights[userId] = nil
		end
	end
end

RunService.RenderStepped:Connect(function()
	if isOpen then
		-- Пока меню открыто, временно освобождаем мышь от LockCenter,
		-- чтобы настоящий указатель мог двигаться и GUI получал клики.
		-- При закрытии меню исходный MouseBehavior будет восстановлен.
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end

		if CursorConfig.Enabled and IsCustomCursorAllowed() then
			virtualCursorPosition = UserInputService:GetMouseLocation()
			CursorRoot.Position = UDim2.fromOffset(virtualCursorPosition.X, virtualCursorPosition.Y)
		end
	end
	UpdateCursorDisplay()

	if VisualsConfig.FOVEnabled then
		Camera.FieldOfView = VisualsConfig.FOV
	end

	UpdateKillerLights()

	if not KillerBeamConfig.Enabled then
		if next(ActiveBeams) then ClearBeams() end
		return
	end

	local currentActiveUids = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer and player.Team and player.Team.Name == "Killer" then
			local char = player.Character
			local head = char and char:FindFirstChild("Head")
			if head then
				local uid = player.UserId
				currentActiveUids[uid] = true

				local beamData = ActiveBeams[uid]
				if not beamData then
					local p0 = Instance.new("Part", Workspace)
					p0.Transparency = 1 p0.Anchored = true p0.CanCollide = false p0.Size = Vector3.new(0.1,0.1,0.1)
					local att0 = Instance.new("Attachment", p0)

					local p1 = Instance.new("Part", Workspace)
					p1.Transparency = 1 p1.Anchored = true p1.CanCollide = false p1.Size = Vector3.new(0.1,0.1,0.1)
					local att1 = Instance.new("Attachment", p1)

					local beam = Instance.new("Beam", p0)
					beam.Attachment0 = att0
					beam.Attachment1 = att1
					beam.FaceCamera = true
					beam.Width0 = 0.08
					beam.Width1 = 0.08

					beamData = {Part0 = p0, Part1 = p1, Beam = beam}
					ActiveBeams[uid] = beamData
				end

				local origin = head.Position
				local lookVector = head.CFrame.LookVector
				local endPos = origin + (lookVector * KillerBeamConfig.Length)

				beamData.Part0.Position = origin
				beamData.Part1.Position = endPos
				beamData.Beam.Color = ColorSequence.new(KillerBeamConfig.Color)
			end
		end
	end

	for uid, beamData in pairs(ActiveBeams) do
		if not currentActiveUids[uid] then
			if beamData.Beam then beamData.Beam:Destroy() end
			if beamData.Part0 then beamData.Part0:Destroy() end
			if beamData.Part1 then beamData.Part1:Destroy() end
			ActiveBeams[uid] = nil
		end
	end
end)

local function SetupPlayer(player)
	if player == LocalPlayer then return end
	player.CharacterAdded:Connect(function()
		task.wait(0.2)
		UpdateCharacterHighlight(player)
	end)
	player:GetPropertyChangedSignal("Team"):Connect(function()
		UpdateCharacterHighlight(player)
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	SetupPlayer(player)
end
Players.PlayerAdded:Connect(SetupPlayer)

LocalPlayer:GetPropertyChangedSignal("Team"):Connect(UpdateCursorDisplay)
-- При смене команды включаем/выключаем ESP окон, паллет и генераторов.
LocalPlayer:GetPropertyChangedSignal("Team"):Connect(RefreshObjectHighlights)
LocalPlayer:GetPropertyChangedSignal("Team"):Connect(function()
	pcall(ReapplyWorldEffects)
	-- игра может менять освещение с задержкой после смены команды
	task.delay(0.5, function() pcall(ReapplyWorldEffects) end)
end)
UpdateCursorDisplay()

local mouseBehaviorBeforeMenu = nil

local function SetOpen(open)
	if isOpen == open then return end
	isOpen = open
	if open then
		-- Сохраняем режим игры и отпускаем курсор для управления меню.
		mouseBehaviorBeforeMenu = UserInputService.MouseBehavior
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		virtualCursorPosition = UserInputService:GetMouseLocation()
		MainFrame.Visible = true
		UpdateCursorDisplay()
		Tween(MainFrame, { GroupTransparency = 0 }, 0.2)
		Tween(WindowScale, { Scale = 1 }, 0.28, Enum.EasingStyle.Back)
	else
		ClosePicker()
		UpdateCursorDisplay()
		Tween(MainFrame, { GroupTransparency = 1 }, 0.15)
		Tween(WindowScale, { Scale = 0.96 }, 0.15)
		task.delay(0.16, function()
			if not isOpen then MainFrame.Visible = false end
		end)

		-- Возвращаем игре тот режим мыши, который был до открытия меню.
		if mouseBehaviorBeforeMenu then
			UserInputService.MouseBehavior = mouseBehaviorBeforeMenu
			mouseBehaviorBeforeMenu = nil
		end
	end
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

	if cursorKeyCaptureJustCompleted then
		cursorKeyCaptureJustCompleted = false
		return
	end

	if statsKeyCaptureJustCompleted then
		statsKeyCaptureJustCompleted = false
		return
	end

	if not gameProcessed and not waitingForMenuKey and not waitingForCursorKey
		and not waitingForStatsKey then
		if input.KeyCode == CursorConfig.ToggleKey then
			SetCursorEnabled(not CursorConfig.Enabled)
		elseif input.KeyCode == UIConfig.ToggleKey then
			SetOpen(not isOpen)
		elseif input.KeyCode == StatsConfig.ToggleKey then
			SetStatsEnabled(not StatsConfig.Enabled)
		end
	end
end)
