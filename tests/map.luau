--!strict
-- map.luau — validates the generated greybox against the tags the server code
-- actually reads. The other suite covers module logic; this one covers the
-- contract between build_map.py and ZoneManager/ZombieAI, which is otherwise
-- only checked by a human opening Studio.
--
-- It reads map/*.model.json directly rather than parsing the .rbxl, because
-- Rojo emits a binary-format place file that is not text-searchable.

local fs = require("@lune/fs")

local function scriptDir(): string
	local here = debug.info(1, "s")
	local slash = here:match("()[^/]*$")
	if slash then
		return here:sub(1, slash - 1)
	end
	return "."
end

local MAP_ROOT = scriptDir() .. "/../map"

local passed, failed = 0, 0

local function check(label: string, condition: boolean, detail: string?)
	if condition then
		passed += 1
		print("  PASS  " .. label)
	else
		failed += 1
		print("  FAIL  " .. label .. (detail and ("  -- " .. detail) or ""))
	end
end

-- Minimal JSON decode. Rojo model files only use objects, arrays, strings,
-- numbers, booleans and null, which is all we need.
local function decode(text: string): any
	local pos = 1

	local function skipWs()
		while pos <= #text and text:sub(pos, pos):match("%s") do
			pos += 1
		end
	end

	local parseValue

	local function parseString(): string
		pos += 1 -- opening quote
		local out = ""
		while pos <= #text do
			local c = text:sub(pos, pos)
			if c == '"' then
				pos += 1
				return out
			elseif c == "\\" then
				pos += 1
				local e = text:sub(pos, pos)
				if e == "n" then out ..= "\n"
				elseif e == "t" then out ..= "\t"
				elseif e == "/" then out ..= "/"
				elseif e == "\\" then out ..= "\\"
				else out ..= e end
			else
				out ..= c
			end
			pos += 1
		end
		error("unterminated string")
	end

	local function parseNumber(): number
		local s = pos
		while pos <= #text and text:sub(pos, pos):match("[%d%.%-eE%+]") do
			pos += 1
		end
		return tonumber(text:sub(s, pos - 1)) or 0
	end

	local function parseArray(): { any }
		pos += 1 -- [
		local arr = {}
		skipWs()
		if text:sub(pos, pos) == "]" then
			pos += 1
			return arr
		end
		while true do
			skipWs()
			table.insert(arr, parseValue())
			skipWs()
			local c = text:sub(pos, pos)
			pos += 1
			if c == "]" then break end
			if c ~= "," then error("expected , or ] in array") end
		end
		return arr
	end

	local function parseObject(): { [string]: any }
		pos += 1 -- {
		local obj = {}
		skipWs()
		if text:sub(pos, pos) == "}" then
			pos += 1
			return obj
		end
		while true do
			skipWs()
			local key = parseString()
			skipWs()
			pos += 1 -- :
			skipWs()
			obj[key] = parseValue()
			skipWs()
			local c = text:sub(pos, pos)
			pos += 1
			if c == "}" then break end
			if c ~= "," then error("expected , or } in object") end
		end
		return obj
	end

	parseValue = function(): any
		skipWs()
		local c = text:sub(pos, pos)
		if c == "{" then return parseObject()
		elseif c == "[" then return parseArray()
		elseif c == '"' then return parseString()
		elseif text:sub(pos, pos + 3) == "true" then pos += 4 return true
		elseif text:sub(pos, pos + 4) == "false" then pos += 5 return false
		elseif text:sub(pos, pos + 3) == "null" then pos += 4 return nil
		else return parseNumber() end
	end

	local v = parseValue()
	skipWs()
	return v
end

-- ---------------------------------------------------------------- helpers

type Model = { className: string, children: { any }? }
type PartDef = {
	ClassName: string,
	Name: string,
	Attributes: { [string]: any }?,
}

local function readModel(path: string): Model?
	local contents = fs.readFile(path)
	if not contents then
		return nil
	end
	local ok, decoded = pcall(decode, contents)
	if not ok then
		return nil
	end
	return decoded
end

-- Every Part in a model file, recursing into nested folders.
local function collectParts(model: Model, out: { PartDef })
	for _, child in ipairs(model.children or {}) do
		if child.ClassName == "Part" then
			table.insert(out, child)
		elseif child.children then
			collectParts(child, out)
		end
	end
end

local function attrs(p: PartDef): { [string]: any }
	return p.Attributes or {}
end

-- ---------------------------------------------------------------- the checks

print("\n== Map integrity ==")

-- ZoneManager:GetSpawnPoints scans Workspace.DeadZone.Zones/<id> for BaseParts
-- tagged Role = "SpawnPoint". ZoneManager:_gateForZone needs any BasePart under
-- DeadZone.Gates/<id>. ZoneManager:CheckExtraction needs Role = "Extraction".
-- ZombieAI spawns loot from Role = "Pickup" with a Kind attribute.

local ZONE_IDS = { "suburbs", "hospital", "mall", "base" }
local REQUIRED_LOOT = { "Medkit", "Pills", "Adrenaline", "AmmoPile", "Bandage" }

for _, zid in ipairs(ZONE_IDS) do
	local zonePath = MAP_ROOT .. "/Zones/" .. zid .. "/init.model.json"
	local zoneModel = readModel(zonePath)
	check("zone folder exists: " .. zid, zoneModel ~= nil, zonePath)

	if zoneModel then
		local parts = {}
		collectParts(zoneModel, parts)

		local spawnCount, extractCount = 0, 0
		for _, p in ipairs(parts) do
			local a = attrs(p)
			if a.Role == "SpawnPoint" then
				spawnCount += 1
			elseif a.Role == "Extraction" then
				extractCount += 1
			end
		end

		check("zone has 4 spawn pads: " .. zid, spawnCount == 4, "got " .. spawnCount)
		check("zone has a ground to stand on: " .. zid,
			(function()
				for _, p in ipairs(parts) do
					if p.Name:find("ground") then return true end
				end
				return false
			end)())

		-- Extraction exists only on the final zone, matching Config.Zones[4].
		if zid == "base" then
			check("final zone has an Extraction pad", extractCount == 1, "got " .. extractCount)
		else
			check("non-final zone has no Extraction pad: " .. zid, extractCount == 0,
				"got " .. extractCount)
		end
	end

	-- Gates: the server accepts any BasePart, but a real gate needs to exist.
	local gatePath = MAP_ROOT .. "/Gates/" .. zid .. "/init.model.json"
	local gateModel = readModel(gatePath)
	check("gate folder exists: " .. zid, gateModel ~= nil, gatePath)
	if gateModel then
		local parts = {}
		collectParts(gateModel, parts)
		check("zone has a gate: " .. zid, #parts > 0, "got " .. #parts)
	end
end

-- Loot: every pickup kind the config defines must be placeable somewhere.
local lootModel = readModel(MAP_ROOT .. "/Loot/init.model.json")
check("loot folder exists", lootModel ~= nil, MAP_ROOT .. "/Loot/init.model.json")
if lootModel then
	local parts = {}
	collectParts(lootModel, parts)

	local kinds: { [string]: number } = {}
	for _, p in ipairs(parts) do
		local a = attrs(p)
		if a.Role == "Pickup" then
			local k = tostring(a.Kind)
			kinds[k] = (kinds[k] or 0) + 1
		end
	end

	for _, kind in ipairs(REQUIRED_LOOT) do
		check("loot kind present: " .. kind, (kinds[kind] or 0) > 0,
			"count=" .. tostring(kinds[kind] or 0))
	end
end

-- Zones must be spaced apart so a squad physically walks zone-to-zone
-- rather than standing in two zones at once.
local prevCenter: number? = nil
for zi, zid in ipairs(ZONE_IDS) do
	local m = readModel(MAP_ROOT .. "/Zones/" .. zid .. "/init.model.json")
	if m then
		for _, p in ipairs(m.children or {}) do
			if p.Name:find("ground") and p.Position then
				local center = p.Position[3]
				if prevCenter then
					local gap = math.abs(center - prevCenter)
					check("zone gap is walkable distance: " .. zid, gap >= 100,
						"gap=" .. tostring(gap))
				end
				prevCenter = center
			end
		end
	end
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	local process = require("@lune/process")
	process.exit(1)
end
