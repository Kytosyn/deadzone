--!strict
-- ClientController.luau — first-person camera, HUD, input, prompts.
--
-- Owns everything the player sees and does. Movement and shooting are sent to
-- the server as requests; the server validates and applies them, then syncs
-- state back through StateSync.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local Config = require(ReplicatedStorage.Shared.Config)

local player = Players.LocalPlayer
local Remotes = ReplicatedStorage.Remotes

local Client = {}
Client.__index = Client

function Client.new()
	local self = setmetatable({}, Client)

	self.State = "lobby"
	self.Health = Config.MaxHealth
	self.TempHealth = 0
	self.Down = false
	self.BleedOut = Config.DownBleedOut
	self.Money = 0
	self.Kills = 0
	self.ZoneName = "-"
	self.Phase = "build"
	self.Magazine = 0
	self.Reserve = 0

	self.Keys = {}
	self.AimDirection = Vector3.new(0, 0, -1)
	self.MouseDelta = Vector2.new(0, 0)

	return self
end

-- ---------------------------------------------------------------- HUD

local function makeLabel(parent: Instance, text: string, order: number): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = text
	l.BackgroundTransparency = 1
	l.TextColor3 = Color3.fromRGB(220, 235, 255)
	l.Font = Enum.Font.RobotoMono
	l.TextSize = 15
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.LayoutOrder = order
	l.Parent = parent
	return l
end

function Client:BuildHud()
	local gui = Instance.new("ScreenGui")
	gui.Name = "DeadZoneHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Crosshair
	local cross = Instance.new("Frame")
	cross.Name = "Crosshair"
	cross.AnchorPoint = Vector2.new(0.5, 0.5)
	cross.Position = UDim2.fromScale(0.5, 0.5)
	cross.Size = UDim2.fromOffset(14, 14)
	cross.BackgroundTransparency = 1
	cross.Parent = gui
	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(2, 2)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.BackgroundColor3 = Color3.fromRGB(94, 242, 224)
	dot.BackgroundTransparency = 0
	dot.Parent = cross

	-- Top bar: zone + phase
	local top = Instance.new("Frame")
	top.BackgroundTransparency = 1
	top.Position = UDim2.fromOffset(16, 12)
	top.Parent = gui
	local tl = makeLabel(top, "ZoneLabel", 1)
	tl.Text = "ZONE —"
	self.ZoneLabel = tl

	local phase = makeLabel(top, "PhaseLabel", 2)
	phase.TextColor3 = Color3.fromRGB(255, 94, 168)
	phase.Text = ""
	self.PhaseLabel = phase

	-- Bottom left: health
	local health = Instance.new("Frame")
	health.BackgroundTransparency = 1
	health.Position = UDim2.new(0, 16, 1, -20)
	health.Parent = gui
	local hl = makeLabel(health, "HealthLabel", 1)
	hl.Text = "HP 100"
	self.HealthLabel = hl

	local temp = makeLabel(health, "TempLabel", 2)
	temp.TextColor3 = Color3.fromRGB(255, 214, 102)
	temp.Text = ""
	self.TempLabel = temp

	local money = makeLabel(health, "MoneyLabel", 3)
	money.TextColor3 = Color3.fromRGB(94, 242, 224)
	money.Text = "$0   KILLS 0"
	self.MoneyLabel = money

	-- Bottom right: ammo
	local ammo = Instance.new("Frame")
	ammo.BackgroundTransparency = 1
	ammo.AnchorPoint = Vector2.new(1, 1)
	ammo.Position = UDim2.new(1, -16, 1, -20)
	ammo.Parent = gui
	local al = makeLabel(ammo, "AmmoLabel", 1)
	al.TextXAlignment = Enum.TextXAlignment.Right
	al.TextSize = 22
	al.Text = "30 / 180"
	self.AmmoLabel = al

	-- Center prompt (gate, revive)
	local prompt = Instance.new("TextLabel")
	prompt.Name = "Prompt"
	prompt.AnchorPoint = Vector2.new(0.5, 0.5)
	prompt.Position = UDim2.fromScale(0.5, 0.62)
	prompt.BackgroundTransparency = 1
	prompt.TextColor3 = Color3.fromRGB(94, 242, 224)
	prompt.Font = Enum.Font.RobotoMono
	prompt.TextSize = 18
	prompt.Text = ""
	prompt.Parent = gui
	self.PromptLabel = prompt

	-- Bleed-out overlay
	local bleed = Instance.new("Frame")
	bleed.Name = "Bleed"
	bleed.BackgroundColor3 = Color3.fromRGB(120, 0, 20)
	bleed.BackgroundTransparency = 1
	bleed.Size = UDim2.fromScale(1, 1)
	bleed.Parent = gui
	self.BleedFrame = bleed

	self.Gui = gui
end

-- ---------------------------------------------------------------- input

function Client:BindInput()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:_fire()
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			self:_shove()
		elseif input.KeyCode == Enum.KeyCode.R then
			self:_reload()
		elseif input.KeyCode == Enum.KeyCode.F then
			self:_revive()
		elseif input.KeyCode == Enum.KeyCode.E then
			self:_interact()
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			self.MouseDelta = input.Delta
		end
	end)
end

function Client:_cameraOrigin(): Vector3
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local cam = workspace.CurrentCamera
	if root and cam then
		return cam.CFrame.Position
	end
	return root and root.Position or Vector3.new()
end

function Client:_fire()
	if self.State ~= "playing" or self.Down then
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local origin = cam.CFrame.Position
	local dir = cam.CFrame.LookVector
	Remotes.FireWeapon:FireServer("primary", origin, dir)
end

function Client:_shove()
	if self.State ~= "playing" or self.Down then
		return
	end
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	Remotes.MeleeShove:FireServer(cam.CFrame.Position, cam.CFrame.LookVector)
end

function Client:_reload()
	Remotes.FireWeapon:FireServer("primary", Vector3.new(0, -9999, 0), Vector3.new(0, 1, 0))
end

function Client:_interact()
	Remotes.OpenGate:FireServer()
end

function Client:_revive()
	-- The server picks the nearest downed player.
	Remotes.RevivePlayer:FireServer()
end

-- ---------------------------------------------------------------- camera

function Client:UpdateCamera(dt: number)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local cam = workspace.CurrentCamera
	if not root or not hum or not cam then
		return
	end

	-- First-person: put the camera at the head, look where the mouse points.
	local head = char:FindFirstChild("Head") or root
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.new(head.Position + Vector3.new(0, 0.6, 0))
		* CFrame.Angles(0, -math.rad(0), 0)

	-- Apply mouse look.
	local sens = 0.0022
	local delta = self.MouseDelta
	self.MouseDelta = Vector2.new(0, 0)

	local current = cam.CFrame
	local look = current.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude > 0.001 then
		flat = flat.Unit
	end
	-- Yaw around world Y, pitch around the camera's right axis.
	local yaw = math.atan2(-flat.X, -flat.Z) - delta.X * sens
	local pitch = math.asin(clamp(look.Y, -1, 1)) - delta.Y * sens
	pitch = clamp(pitch, -1.4, 1.4)
	local dir = Vector3.new(
		math.sin(yaw) * math.cos(pitch),
		math.sin(pitch),
		math.cos(yaw) * math.cos(pitch)
	)
	cam.CFrame = CFrame.lookAt(cam.CFrame.Position, cam.CFrame.Position + dir)

	-- Hide the player's own head in first person.
	if head:IsA("BasePart") then
		head.LocalTransparencyModifier = 1
	end
end

-- ---------------------------------------------------------------- state sync

function Client:OnStateSync(data: any)
	self.State = data.state or self.State
	self.Health = data.health or self.Health
	self.TempHealth = data.tempHealth or 0
	self.Down = data.down or false
	self.BleedOut = data.bleedOut or 0
	self.Money = data.money or 0
	self.Kills = data.kills or 0
	self.ZoneName = data.zone or self.ZoneName
	self.Phase = data.phase or self.Phase
	self.Magazine = data.magazine or 0
	self.Reserve = data.reserve or 0

	self:_refresh()
end

function Client:_refresh()
	if not self.ZoneLabel then
		return
	end
	self.ZoneLabel.Text = string.upper(tostring(self.ZoneName))
	self.PhaseLabel.Text = self.Phase == "relax" and "— BREATHER —"
		or self.Phase == "crescendo" and "! HORDE !" or ""

	self.HealthLabel.Text = self.Down
		and string.format("DOWN  %.0fs", math.max(0, self.BleedOut))
		or string.format("HP %d", math.max(0, math.floor(self.Health)))
	self.HealthLabel.TextColor3 = self.Down and Color3.fromRGB(255, 94, 168)
		or Color3.fromRGB(220, 235, 255)

	self.TempLabel.Text = self.TempHealth > 0 and string.format("+%.0f temp", self.TempHealth) or ""
	self.MoneyLabel.Text = string.format("$%d   KILLS %d", self.Money, self.Kills)
	self.AmmoLabel.Text = string.format("%d / %d", self.Magazine, self.Reserve)

	-- Bleed-out vignette.
	if self.BleedFrame then
		self.BleedFrame.BackgroundTransparency = self.Down
			and 0.55 + 0.3 * math.abs(math.sin(tick() * 3)) or 1
	end
end

-- ---------------------------------------------------------------- main loop

function Client:Start()
	self:BuildHud()
	self:BindInput()

	Remotes.StateSync.OnClientEvent:Connect(function(data) self:OnStateSync(data) end)

	-- Mouse lock for first person.
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

	RunService.RenderStepped:Connect(function(dt)
		if self.State == "playing" then
			self:UpdateCamera(dt)
		end
	end)
end

-- ---------------------------------------------------------------- bootstrap

local client = Client.new()
client:Start()

return client
