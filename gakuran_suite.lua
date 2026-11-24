-- Suite Gakuran Unificada: Auto Parry de Alta Respuesta + Bloqueo al Lord + ESP con HP + HUD Arrastrable
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = pcall(function() return game:GetService("VirtualInputManager") end) and game:GetService("VirtualInputManager") or nil
local CoreGui = game:GetService("CoreGui")

local localPlayer = Players.LocalPlayer
if not localPlayer then
	return
end

local env = (typeof(getgenv) == "function" and getgenv()) or _G
local SUITE_KEY = "GakuranAutoParryFixed_v15"

if env[SUITE_KEY] and typeof(env[SUITE_KEY].Cleanup) == "function" then
	pcall(env[SUITE_KEY].Cleanup)
end

local CONFIG = {
	AutoGuardEnabled = true,
	EspEnabled = true,
	TargetFilter = "ALL", -- "ALL" | "PLR" | "NPC"
	SendNativeGuardKey = true, -- Intenta pulsar F nativo al bloquear/parry si el juego usa F para guardia

	ToggleGuardKey = Enum.KeyCode.F,
	ToggleEspKey = Enum.KeyCode.G,
	CycleFilterKey = Enum.KeyCode.H,

	ParryRange = 16,             -- Distancia para detectar ataque/amenaza inmediata
	ThreatRadius = 26,
	ThreatApproachSpeed = 10,
	BlockDuration = 0.65,
	Cooldown = 0.22,             -- Enfriamiento corto para no perder golpes seguidos
	MinDamageThreshold = 0.05,   -- Detecta incluso daño bajo o ticks
	CounterImpulse = 62,
	FovPulse = 7,

	EspMaxDistance = 450,
	ShowHighlight = true,
	ScanInterval = 0.03,
	EspInterval = 0.12,
	HudInterval = 0.06,
	DragDeadzone = 6
}

local suite = {
	AutoGuardEnabled = CONFIG.AutoGuardEnabled,
	EspEnabled = CONFIG.EspEnabled,
	TargetFilter = CONFIG.TargetFilter,

	IsBlocking = false,
	BlockUntil = 0,
	CooldownUntil = 0,
	LastParryClock = 0,

	LastHealth = nil :: number?,
	ParryCount = 0,
	BlockCount = 0,
	LastEvent = "Auto Parry Listo (Alta Respuesta)",
	AnimBusy = false,

	Connections = {} :: { RBXScriptConnection },
	EspMap = {} :: { [Model]: {
		billboard: BillboardGui,
		highlight: Highlight?,
		nameLabel: TextLabel,
		hpLabel: TextLabel,
		barFill: Frame
	} },
	ShieldPart = nil :: Part?,
	Gui = nil :: ScreenGui?,
	HudRefs = {} :: { [string]: GuiObject },
	Cleanup = nil :: (() -> ())?
}

local function track(conn: RBXScriptConnection): RBXScriptConnection
	table.insert(suite.Connections, conn)
	return conn
end

local function getUiRoot(): Instance
	local root: Instance = CoreGui
	pcall(function()
		if typeof(gethui) == "function" then
			local custom = gethui()
			if typeof(custom) == "Instance" then
				root = custom
			end
		end
	end)
	return root
end

local function getLordRig()
	local char = localPlayer.Character
	if not char then
		return nil, nil, nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = (char:FindFirstChild("HumanoidRootPart") :: BasePart?) or (char.PrimaryPart :: BasePart?)
	if not hum or not root or hum.Health <= 0 then
		return nil, nil, nil
	end
	return char, hum, root
end

-- ============================================================================
-- 1. ESCÁNER DE TODOS LOS NPCS Y JUGADORES (INCLUSO EN CARPETAS)
-- ============================================================================
local function resolveBodyParts(model: Model): (BasePart?, BasePart?)
	local root = (model:FindFirstChild("HumanoidRootPart") :: BasePart?)
		or (model.PrimaryPart :: BasePart?)
		or (model:FindFirstChildWhichIsA("BasePart") :: BasePart?)
	local head = (model:FindFirstChild("Head") :: BasePart?) or root
	return root, head
end

local function getTargets(filterMode: string?)
	local mode = filterMode or suite.TargetFilter
	local lordChar = localPlayer.Character
	local results = {} :: { {
		model: Model,
		humanoid: Humanoid,
		root: BasePart,
		adornee: BasePart,
		isPlayer: boolean
	} }
	local visited = {} :: { [Model]: boolean }

	if mode == "ALL" or mode == "PLR" then
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= localPlayer and plr.Character and not visited[plr.Character] then
				local char = plr.Character
				local hum = char:FindFirstChildOfClass("Humanoid")
				local root, head = resolveBodyParts(char)
				if hum and hum.Health > 0 and hum.MaxHealth > 0 and root and head then
					visited[char] = true
					table.insert(results, {
						model = char,
						humanoid = hum,
						root = root,
						adornee = head,
						isPlayer = true
					})
				end
			end
		end
	end

	if mode == "ALL" or mode == "NPC" then
		for _, inst in ipairs(workspace:GetDescendants()) do
			if inst:IsA("Humanoid") and inst.Health > 0 and inst.MaxHealth > 0 then
				local model = inst.Parent
				if model and model:IsA("Model") and model ~= lordChar and not visited[model] then
					if Players:GetPlayerFromCharacter(model) == nil then
						local root, head = resolveBodyParts(model)
						if root and head then
							visited[model] = true
							table.insert(results, {
								model = model,
								humadnoid = inst,
								root = root,
								adornee = head,
								isPlayer = false
							})
						end
					end
				end
			end
		end
	end

	return results
end

-- ============================================================================
-- 2. DEFENSA: AUTO PARRY + BLOQUEO AUTOMÁTICO AL LORD
-- ============================================================================
local function pulseNativeKey(keyCode: Enum.KeyCode)
	if not CONFIG.SendNativeGuardKey or not VirtualInputManager then
		return
	end
	pcall(function()
		VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
		task.delay(0.06, function()
			pcall(function()
				VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
			end)
		end)
	end)
end

local function clearShield()
	if suite.ShieldPart then
		pcall(function()
			suite.ShieldPart:Destroy()
		end)
		suite.ShieldPart = nil
	end
end

local function syncShield(rootPart: BasePart?)
	if not suite.IsBlocking or not rootPart then
		clearShield()
		return
	end

	local shield = suite.ShieldPart
	if not shield or not shield.Parent then
		shield = Instance.new("Part")
		shield.Name = "GakuranLordShield"
		shield.Shape = Enum.PartType.Block
		shield.Material = Enum.Material.ForceField
		shield.Color = Color3.fromRGB(90, 215, 255)
		shield.Anchored = true
		shield.CanCollide = false
		shield.Transparency = 0.35
		shield.Size = Vector3.new(5.8, 5.8, 0.75)
		shield.Parent = workspace
		suite.ShieldPart = shield
	end

	local lookFlat = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)
	local dir = lookFlat.Magnitude > 0.01 and lookFlat.Unit or Vector3.new(0, 0, -1)
	local frontPos = rootPart.Position + dir * 2.85
	shield.CFrame = CFrame.lookAt(frontPos, frontPos + dir)
end

local function playParryFeedback(rootPart: BasePart)
	if suite.AnimBusy then
		return
	end
	suite.AnimBusy = true

	local ring = Instance.new("Part")
	ring.Name = "GakuranParryRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(120, 235, 255)
	ring.Anchored = true
	ring.CanCollide = false
	ring.Transparency = 0.2
	ring.Size = Vector3.new(0.25, 3.5, 3.5)
	ring.CFrame = CFrame.new(rootPart.Position - Vector3.new(0, 1.4, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = workspace

	local tween = TweenService:Create(
		ring,
		TweenInfo.new(0.20, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.08, 14.5, 14.5), Transparency = 1 }
	)
	tween:Play()
	tween.Completed:Connect(function()
		ring:Destroy()
		suite.AnimBusy = false
	end)

	local cam = workspace.CurrentCamera
	if cam then
		local baseFov = cam.FieldOfView
		local peakFov = math.clamp(baseFov - CONFIG.FovPulse, 40, 110)
		local t1 = TweenService:Create(cam, TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FieldOfView = peakFov })
		local t2 = TweenService:Create(cam, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), { FieldOfView = baseFov })
		t1:Play()
		t1.Completed:Wait()
		if workspace.CurrentCamera then
			t2:Play()
		end
	end
end

local function faceAndRepelThreat(rootPart: BasePart, preferredTarget: BasePart?)
	local chosen = preferredTarget
	if not chosen then
		local bestDist = CONFIG.ThreatRadius
		for _, t in ipairs(getTargets("ALL")) do
			local d = (t.root.Position - rootPart.Position).Magnitude
			if d < bestDist then
				bestDist = d
				chosen = t.root
			end
		end
	end

	if chosen then
		local flat = Vector3.new(chosen.Position.X - rootPart.Position.X, 0, chosen.Position.Z - rootPart.Position.Z)
		if flat.Magnitude > 0.05 then
			local unit = flat.Unit
			pcall(function()
				rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + unit)
				chosen.AssemblyLinearVelocity = unit * CONFIG.CounterImpulse + Vector3.new(0, 15, 0)
			end)
		end
	end
end

local refreshHud: () -> ()

local function raiseAutoBlock(rootPart: BasePart, attackerRoot: BasePart?, statusText: string)
	if not suite.AutoGuardEnabled then
		return
	end
	local now = os.clock()
	local wasUp = suite.IsBlocking
	suite.IsBlocking = true
	suite.BlockUntil = math.max(suite.BlockUntil, now + CONFIG.BlockDuration)

	if not wasUp then
		suite.BlockCount += 1
		pulseNativeKey(CONFIG.ToggleGuardKey)
	end

	suite.LastEvent = statusText
	faceAndRepelThreat(rootPart, attackerRoot)
	syncShield(rootPart)
	if refreshHud then
		refreshHud()
	end
end

local function performAutoParry(humanoid: Humanoid, rootPart: BasePart, attackerRoot: BasePart?, recoveredHp: number, labelPrefix: string?)
	local now = os.clock()
	suite.CooldownUntil = now + CONFIG.Cooldown
	suite.LastParryClock = now
	suite.IsBlocking = true
	suite.BlockUntil = math.max(suite.BlockUntil, now + CONFIG.BlockDuration)
	suite.ParryCount += 1

	if recoveredHp > 0 then
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + recoveredHp)
	end
	suite.LastHealth = humanoid.Health

	suite.LastEvent = string.format("%s #%d", labelPrefix or "¡Auto Parry!", suite.ParryCount)
	pulseNativeKey(CONFIG.ToggleGuardKey)
	faceAndRepelThreat(rootPart, attackerRoot)
	task.spawn(playParryFeedback, rootPart)
	syncShield(rootPart)
	if refreshHud then
		refreshHud()
	end
end

local function scanAndDefendLord()
	if not suite.AutoGuardEnabled then
		return
	end
	local _, humanoid, rootPart = getLordRig()
	if not humanoid or not rootPart then
		return
	end

	local now = os.clock()
	if now < suite.CooldownUntil then
		return
	end

	for _, t in ipairs(getTargets("ALL")) do
		local toLord = rootPart.Position - t.root.Position
		local dist = toLord.Magnitude
		if dist <= CONFIG.ThreatRadius and dist > 0.01 then
			local dir = toLord.Unit
			local approachSpeed = t.root.AssemblyLinearVelocity:Dot(dir)
			local aimingAtLord = t.root.CFrame.LookVector:Dot(dir) > 0.52

			if dist <= CONFIG.ParryRange and (aimingAtLord or approachSpeed >= CONFIG.ThreatApproachSpeed) then
				local kind = t.isPlayer and "PLR" or "NPC"
				performAutoParry(humanoid, rootPart, t.root, 0, string.format("Parry %s (%s)", kind, t.model.Name))
				break
			elseif (approachSpeed >= CONFIG.ThreatApproachSpeed and dist <= 22) or (aimingAtLord and dist <= 18) then
				local kind = t.isPlayer and "PLR" or "NPC"
				raiseAutoBlock(rootPart, t.root, string.format("Bloqueo %s (%s)", kind, t.model.Name))
				break
			end
		end
	end
end

local function bindLord(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end

	suite.LastHealth = humanoid.Health

	track(humanoid.HealthChanged:Connect(function(newHp: number)
		local prevHp = suite.LastHealth or newHp
		suite.LastHealth = newHp

		local lost = prevHp - newHp
		if lost < CONFIG.MinDamageThreshold or newHp <= 0 or not suite.AutoGuardEnabled then
			return
		end

		local _, _, rootPart = getLordRig()
		if not rootPart then
			return
		end

		if os.clock() >= suite.CooldownUntil then
			performAutoParry(humanoid, rootPart, nil, lost, string.format("¡Parry +%.0fHP!", lost))
		else
			raiseAutoBlock(rootPart, nil, "Bloqueo de emergencia")
		end
	end))
end

-- ============================================================================
-- 3. ESP CON BARRA DE VIDA EN TIEMPO REAL
-- ============================================================================
local function removeEsp(model: Model)
	local entry = suite.EspMap[model]
	if entry then
		pcall(function()
			entry.billboard:Destroy()
		end)
		if entry.highlight then
			pcall(function()
				entry.highlight:Destroy()
			end)
		end
		suite.EspMap[model] = nil
	end
end

local function clearAllEsp()
	for model in pairs(suite.EspMap) do
		removeEsp(model)
	end
end

local function createEsp(model: Model, adornee: BasePart, isPlayer: boolean)
	local existing = suite.EspMap[model]
	if existing and existing.billboard.Parent then
		return existing
	end

	local accent = isPlayer and Color3.fromRGB(255, 110, 110) or Color3.fromRGB(255, 190, 85)
	local uiRoot = getUiRoot()

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "GakuranEspBillboard"
	billboard.Adornee = adornee
	billboard.Size = UDim2.fromOffset(156, 46)
	billboard.StudsOffset = Vector3.new(0, 3.2, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = CONFIG.EspMaxDistance
	billboard.Parent = uiRoot

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(14, 19, 29)
	frame.BackgroundTransparency = 0.22
	frame.BorderSizePixel = 0
	frame.Parent = billboard

	local fCorner = Instance.new("UICorner")
	fCorner.CornerRadius = UDim.new(0, 8)
	fCorner.Parent = frame

	local fStroke = Instance.new("UIStroke")
	fStroke.Color = accent
	fStroke.Thickness = 1.2
	fStroke.Transparency = 0.3
	fStroke.Parent = frame

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, -10, 0, 16)
	nameLabel.Position = UDim2.fromOffset(5, 2)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 11
	nameLabel.TextColor3 = Color3.fromRGB(245, 250, 255)
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.Text = model.Name
	nameLabel.Parent = frame

	local hpLabel = Instance.new("TextLabel")
	hpLabel.Size = UDim2.new(1, -10, 0, 13)
	hpLabel.Position = UDim2.fromOffset(5, 16)
	hpLabel.BackgroundTransparency = 1
	hpLabel.Font = Enum.Font.GothamSemibold
	hpLabel.TextSize = 10
	hpLabel.TextColor3 = Color3.fromRGB(170, 255, 190)
	hpLabel.Text = "100 / 100 HP"
	hpLabel.Parent = frame

	local barBg = Instance.new("Frame")
	barBg.Size = UDim2.new(1, -12, 0, 8)
	barBg.Position = UDim2.fromOffset(6, 32)
	barBg.BackgroundColor3 = Color3.fromRGB(38, 44, 56)
	barBg.BorderSizePixel = 0
	barBg.Parent = frame

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(1, 0)
	bgCorner.Parent = barBg

	local barFill = Instance.new("Frame")
	barFill.Size = UDim2.fromScale(1, 1)
	barFill.BackgroundColor3 = Color3.fromRGB(85, 235, 120)
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = barFill

	local highlight: Highlight? = nil
	if CONFIG.ShowHighlight then
		local hl = Instance.new("Highlight")
		hl.Name = "GakuranEspHighlight"
		hl.Adornee = model
		hl.FillColor = accent
		hl.OutlineColor = Color3.fromRGB(255, 240, 210)
		hl.FillTransparency = 0.74
		hl.OutlineTransparency = 0.25
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Parent = uiRoot
		highlight = hl
	end

	local item = {
		billboard = billboard,
		highlight = highlight,
		nameLabel = nameLabel,
		hpLabel = hpLabel,
		barFill = barFill
	}
	suite.EspMap[model] = item
	return item
end

local function updateEsp()
	if not suite.EspEnabled then
		clearAllEsp()
		return
	end

	local _, _, lordRoot = getLordRig()
	local targets = getTargets(suite.TargetFilter)
	local active = {} :: { [Model]: boolean }

	for _, t in ipairs(targets) do
		local dist = lordRoot and (t.root.Position - lordRoot.Position).Magnitude or 0
		if dist <= CONFIG.EspMaxDistance then
			active[t.model] = true
			local item = createEsp(t.model, t.adornee, t.isPlayer)
			local pct = math.clamp(t.humanoid.Health / t.humanoid.MaxHealth, 0, 1)
			local tag = t.isPlayer and "PLR" or "NPC"

			item.nameLabel.Text = string.format("[%s] %s (%.0fm)", tag, t.model.Name, dist)
			item.hpLabel.Text = string.format("%.0f / %.0f HP (%.0f%%)", t.humanoid.Health, t.humanoid.MaxHealth, pct * 100)
			item.barFill.Size = UDim2.fromScale(pct, 1)

			if pct > 0.55 then
				item.barFill.BackgroundColor3 = Color3.fromRGB(85, 235, 120)
			elseif pct > 0.25 then
				item.barFill.BackgroundColor3 = Color3.fromRGB(255, 205, 70)
			else
				item.barFill.BackgroundColor3 = Color3.fromRGB(255, 75, 75)
			end
		end
	end

	for model in pairs(suite.EspMap) do
		if not active[model] then
			removeEsp(model)
		end
	end
end

-- ============================================================================
-- 4. HUD ARRASTRABLE (PC + TÁCTIL) Y CONTROLES
-- ============================================================================
local function makeDraggable(targetGui: GuiObject, onClick: (() -> ())?)
	local dragging = false
	local movedEnough = false
	local dragStart = Vector2.zero
	local startPos = targetGui.Position

	track(targetGui.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			movedEnough = false
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			startPos = targetGui.Position
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local current = Vector2.new(input.Position.X, input.Position.Y)
			local delta = current - dragStart
			if delta.Magnitude >= CONFIG.DragDeadzone then
				movedEnough = true
			end
			if movedEnough then
				targetGui.Position = UDim2.new(
					startPos.X.Scale,
					startPos.X.Offset + delta.X,
					startPos.Y.Scale,
					startPos.Y.Offset + delta.Y
				)
			end
		end
	end))

	track(UserInputService.InputEnded:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			local wasTap = not movedEnough
			dragging = false
			movedEnough = false
			if wasTap and onClick then
				onClick()
			end
		end
	end))
end

local function toggleGuard()
	suite.AutoGuardEnabled = not suite.AutoGuardEnabled
	if not suite.AutoGuardEnabled then
		suite.IsBlocking = false
		clearShield()
		suite.LastEvent = "Auto Parry pausado"
	else
		suite.LastEvent = "Auto Parry activo"
	end
	if refreshHud then
		refreshHud()
	end
end

local function toggleEsp()
	suite.EspEnabled = not suite.EspEnabled
	if not suite.EspEnabled then
		clearAllEsp()
		suite.LastEvent = "ESP oculto"
	else
		suite.LastEvent = "ESP visible"
		updateEsp()
	end
	if refreshHud then
		refreshHud()
	end
end

local function cycleFilter()
	if suite.TargetFilter == "ALL" then
		suite.TargetFilter = "PLR"
	elseif suite.TargetFilter == "PLR" then
		suite.TargetFilter = "NPC"
	else
		suite.TargetFilter = "ALL"
	end
	suite.LastEvent = "Filtro ESP: " .. suite.TargetFilter
	updateEsp()
	if refreshHud then
		refreshHud()
	end
end

local function makeDraggableButton(parent: Instance, name: string, pos: UDim2, text: string, bgColor: Color3, onPress: () -> ())
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Size = UDim2.fromOffset(122, 40)
	btn.Position = pos
	btn.BackgroundColor3 = bgColor
	btn.BackgroundTransparency = 0.1
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 12
	btn.TextColor3 = Color3.fromRGB(242, 250, 255)
	btn.Text = text
	btn.Active = true
	btn.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = btn

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(115, 220, 255)
	stroke.Thickness = 1
	stroke.Transparency = 0.45
	stroke.Parent = btn

	makeDraggable(btn, onPress)
	return btn
end

refreshHud = function()
	local refs = suite.HudRefs
	local modeLabel = refs.ModeLabel :: TextLabel?
	local statsLabel = refs.StatsLabel :: TextLabel?
	local cdBarFill = refs.CdBarFill :: Frame?
	local eventLabel = refs.EventLabel :: TextLabel?
	local guardBtn = refs.GuardBtn :: TextButton?
	local espBtn = refs.EspBtn :: TextButton?
	local filterBtn = refs.FilterBtn :: TextButton?

	local now = os.clock()
	local cdLeft = math.max(0, suite.CooldownUntil - now)
	local cdPct = CONFIG.Cooldown > 0 and math.clamp(1 - (cdLeft / CONFIG.Cooldown), 0, 1) or 1

	if modeLabel then
		if not suite.AutoGuardEnabled then
			modeLabel.Text = "AUTO PARRY: PAUSADO"
			modeLabel.TextColor3 = Color3.fromRGB(255, 115, 115)
		elseif (now - suite.LastParryClock) <= 0.35 then
			modeLabel.Text = "AUTO PARRY: DISPARADO!"
			modeLabel.TextColor3 = Color3.fromRGB(110, 255, 185)
		elseif suite.IsBlocking then
			modeLabel.Text = "AUTO PARRY: BLOQUEANDO"
			modeLabel.TextColor3 = Color3.fromRGB(120, 240, 255)
		else
			modeLabel.Text = "AUTO PARRY: ACTIVO"
			modeLabel.TextColor3 = Color3.fromRGB(120, 225, 255)
		end
	end

	if statsLabel then
		statsLabel.Text = string.format("Parries: %d | Bloqueos: %d", suite.ParryCount, suite.BlockCount)
	end

	if cdBarFill then
		cdBarFill.Size = UDim2.fromScale(cdPct, 1)
		cdBarFill.BackgroundColor3 = cdLeft > 0
			and Color3.fromRGB(255, 195, 80)
			or Color3.fromRGB(95, 235, 175)
	end

	if eventLabel then
		eventLabel.Text = suite.LastEvent
	end

	if guardBtn then
		guardBtn.Text = suite.AutoGuardEnabled and "PARRY: ON" or "PARRY: OFF"
		guardBtn.BackgroundColor3 = suite.AutoGuardEnabled
			and Color3.fromRGB(26, 52, 84)
			or Color3.fromRGB(78, 30, 36)
	end

	if espBtn then
		espBtn.Text = suite.EspEnabled and "ESP: ON" or "ESP: OFF"
		espBtn.BackgroundColor3 = suite.EspEnabled
			and Color3.fromRGB(28, 66, 54)
			or Color3.fromRGB(68, 34, 38)
	end

	if filterBtn then
		filterBtn.Text = "FILTRO: " .. suite.TargetFilter
	end
end

local function buildHud()
	local root = getUiRoot()
	local prev = root:FindFirstChild("GakuranAutoParryFixed_Gui")
	if prev then
		prev:Destroy()
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "GakuranAutoParryFixed_Gui"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = root
	suite.Gui = gui

	local panel = Instance.new("Frame")
	panel.Name = "DraggableHudPanel"
	panel.Size = UDim2.fromOffset(258, 108)
	panel.Position = UDim2.new(0, 16, 0, 16)
	panel.BackgroundColor3 = Color3.fromRGB(15, 22, 34)
	panel.BackgroundTransparency = 0.14
	panel.BorderSizePixel = 0
	panel.Active = true
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(105, 215, 255)
	stroke.Thickness = 1.4
	stroke.Transparency = 0.3
	stroke.Parent = panel

	local modeLabel = Instance.new("TextLabel")
	modeLabel.Size = UDim2.new(1, -16, 0, 22)
	modeLabel.Position = UDim2.fromOffset(8, 6)
	modeLabel.BackgroundTransparency = 1
	modeLabel.Font = Enum.Font.GothamBold
	modeLabel.TextSize = 12.5
	modeLabel.TextXAlignment = Enum.TextXAlignment.Left
	modeLabel.TextColor3 = Color3.fromRGB(120, 225, 255)
	modeLabel.Text = "AUTO PARRY: ACTIVO"
	modeLabel.Parent = panel

	local statsLabel = Instance.new("TextLabel")
	statsLabel.Size = UDim2.new(1, -16, 0, 18)
	statsLabel.Position = UDim2.fromOffset(8, 28)
	statsLabel.BackgroundTransparency = 1
	statsLabel.Font = Enum.Font.GothamSemibold
	statsLabel.TextSize = 11.5
	statsLabel.TextXAlignment = Enum.TextXAlignment.Left
	statsLabel.TextColor3 = Color3.fromRGB(225, 238, 252)
	statsLabel.Text = "Parries: 0 | Bloqueos: 0"
	statsLabel.Parent = panel

	local barBg = Instance.new("Frame")
	barBg.Size = UDim2.new(1, -16, 0, 8)
	barBg.Position = UDim2.fromOffset(8, 52)
	barBg.BackgroundColor3 = Color3.fromRGB(34, 46, 68)
	barBg.BorderSizePixel = 0
	barBg.Parent = panel

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(1, 0)
	bgCorner.Parent = barBg

	local barFill = Instance.new("Frame")
	barFill.Size = UDim2.fromScale(1, 1)
	barFill.BackgroundColor3 = Color3.fromRGB(95, 235, 175)
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = barFill

	local eventLabel = Instance.new("TextLabel")
	eventLabel.Size = UDim2.new(1, -16, 0, 22)
	eventLabel.Position = UDim2.fromOffset(8, 66)
	eventLabel.BackgroundTransparency = 1
	eventLabel.Font = Enum.Font.Gotham
	eventLabel.TextSize = 11.5
	eventLabel.TextXAlignment = Enum.TextXAlignment.Left
	eventLabel.TextColor3 = Color3.fromRGB(185, 210, 232)
	eventLabel.Text = suite.LastEvent
	eventLabel.Parent = panel

	makeDraggable(panel, nil)

	suite.HudRefs.ModeLabel = modeLabel
	suite.HudRefs.StatsLabel = statsLabel
	suite.HudRefs.CdBarFill = barFill
	suite.HudRefs.EventLabel = eventLabel
	suite.HudRefs.GuardBtn = makeDraggableButton(gui, "GuardBtn", UDim2.new(1, -140, 0.54, 0), "PARRY: ON", Color3.fromRGB(26, 52, 84), toggleGuard)
	suite.HudRefs.EspBtn = makeDraggableButton(gui, "EspBtn", UDim2.new(1, -140, 0.54, 46), "ESP: ON", Color3.fromRGB(28, 66, 54), toggleEsp)
	suite.HudRefs.FilterBtn = makeDraggableButton(gui, "FilterBtn", UDim2.new(1, -140, 0.54, 92), "FILTRO: " .. suite.TargetFilter, Color3.fromRGB(48, 38, 76), cycleFilter)
end

-- ============================================================================
-- 5. ATAJOS, BUCLE PRINCIPAL Y LIMPIEZA
-- ============================================================================
track(UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == CONFIG.ToggleGuardKey then
		toggleGuard()
	elseif input.KeyCode == CONFIG.ToggleEspKey then
		toggleEsp()
	elseif input.KeyCode == CONFIG.CycleFilterKey then
		cycleFilter()
	end
end))

local lastScan, lastEsp, lastHud = 0, 0, 0
track(RunService.RenderStepped:Connect(function()
	local now = os.clock()
	local _, _, lordRoot = getLordRig()

	if suite.IsBlocking and now > suite.BlockUntil then
		suite.IsBlocking = false
		clearShield()
	end

	if suite.IsBlocking and lordRoot then
		syncShield(lordRoot)
	end

	if now - lastScan >= CONFIG.ScanInterval then
		lastScan = now
		scanAndDefendLord()
	end

	if now - lastEsp >= CONFIG.EspInterval then
		lastEsp = now
		updateEsp()
	end

	if now - lastHud >= CONFIG.HudInterval then
		lastHud = now
		refreshHud()
	end
end))

if localPlayer.Character then
	task.spawn(bindLord, localPlayer.Character)
end
track(localPlayer.CharacterAdded:Connect(bindLord))

suite.Cleanup = function()
	for _, c in ipairs(suite.Connections) do
		pcall(function()
			c:Disconnect()
		end)
	end
	table.clear(suite.Connections)
	clearAllEsp()
	clearShield()
	if suite.Gui then
		pcall(function()
			suite.Gui:Destroy()
		end)
		suite.Gui = nil
	end
end

env[SUITE_KEY] = suite

buildHud()
refreshHud()
updateEsp()
