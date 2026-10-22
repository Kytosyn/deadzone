--!strict
-- globals.luau — installs the mock Roblox globals into the shared environment.
--
-- This lives in its own module on purpose. In the mock, `game` is a local
-- (the DataModel), so a nested function assigning `game = ...` would write
-- that local as an upvalue instead of the global, and loadstring chunks would
-- never see it. Here there is no such local, so the assignment is global.

local M = {}

M.install = function(t: { [string]: any })
	game = t.game
	workspace = t.workspace
	script = t.script
	require = t.require
	task = t.task
	tick = t.tick
	Vector3 = t.Vector3
	CFrame = t.CFrame
	Color3 = t.Color3
	UDim2 = t.UDim2
	Region3 = t.Region3
	Enum = t.Enum
	Instance = t.Instance
	Vector2 = t.Vector2
	RaycastParams = t.RaycastParams
end

return M
