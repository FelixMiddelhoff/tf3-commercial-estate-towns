local CheckIntervalSeconds <const> = 5.0
local SlowCheckIntervalSeconds <const> = 30.0
local MaxRemovalAttempts <const> = 3
local MaxRestoreAttempts <const> = 3
local MinCapacity <const> = 10
local FallbackCapacity <const> = 60

-- The zone this mod keeps: 1 = housing (residential), 2 = commerce (commercial), 3 = industry.
-- The other two zones of a marked town are set to zero.
local KeptIndex <const> = 2

-- typical ratio of the towns of the test savegames: housing 1.4, commerce 1.0, industry 1.0
local Ratios : {number} = { 1.4, 1.0, 1.0 }

-- a town is an estate of this kind when its name starts with one of these words (any case)
local Keywords : {string} = {
	"commerc", "gewerbe", "[c]", "[com]", "#com",
}

local isEstate = function(name : string) : boolean
	local lowered = string.lower(name or "")
	for _, keyword in ipairs(Keywords) do
		if string.sub(lowered, 1, #keyword) == keyword then
			return true
		end
	end
	return false
end

local describe = function(town : Engine.Component.Town) : string
	local capacities : {string} = {}
	local sizes : {string} = {}
	for i = 1, 3 do
		capacities[i] = tostring(town.initialLandUseCapacities[i])
		sizes[i] = tostring(town.sizeFactors[i])
	end
	return "capacities=" .. table.concat(capacities, "/") .. " sizes=" .. table.concat(sizes, "/") .. " active=" .. tostring(town.developmentActive)
end

-- sum of the capacities of the two zones that are NOT kept
local otherSum = function(values : {integer}) : integer
	local sum = 0
	for i = 1, 3 do
		if i ~= KeptIndex then
			sum = sum + (values[i] or 0)
		end
	end
	return sum
end

-- typical size of the towns of this map: the median land use (capacity times size) of every zone,
-- taken from the towns that have all three zones. nil when there is no such town.
local referenceCapacities = function() : {integer}
	local values : {{number}} = { {}, {}, {} }
	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		local town = api.engine.getComponent(entity, api.type.ComponentType.TOWN) as Engine.Component.Town
		if town and town.initialLandUseCapacities and town.sizeFactors then
			local c1 = town.initialLandUseCapacities[1] or 0
			local c2 = town.initialLandUseCapacities[2] or 0
			local c3 = town.initialLandUseCapacities[3] or 0
			if c1 > 0 and c2 > 0 and c3 > 0 then
				local townCaps : {number} = { c1, c2, c3 }
				for i = 1, 3 do
					local size = town.sizeFactors[i] or 0
					if size <= 0 then
						size = 1.0
					end
					values[i][#values[i] + 1] = townCaps[i] * size
				end
			end
		end
	end, api.type.ComponentType.TOWN)

	if #values[1] == 0 then
		return nil
	end
	local result : {integer} = { 0, 0, 0 }
	for i = 1, 3 do
		table.sort(values[i])
		local middle = values[i][math.floor((#values[i] + 1) / 2)]
		result[i] = math.floor(middle + 0.5)
		if result[i] < MinCapacity then
			result[i] = MinCapacity
		end
	end
	return result
end

-- state keys per town entity e:
--   "c"..e  0/nil = untouched, 1 = turned into an estate, 2 = restoring (capacities sent)
--   "oK"..e = 1 when the original values were saved, "o1","o2","o3"..e original capacities, "s1","s2","s3"..e original sizes
--   "r"..e removal attempts, "a"..e restore attempts, "t"..e = 1 when the kept zone took over the space of the others and its size still has to be reset
-- All of it is saved with the savegame, but the game drops it when a savegame is loaded without the mod.
local ret : GameScript<{string : number}> = {
	update = function(_userParams : table, state : GameScriptState<{string : number}>, dt : number) : any
		if dt == 0.0 then
			return
		end

		local state2 = state:get() or { elapsed = 0.0 }
		state2.elapsed = (state2.elapsed or 0.0) + dt
		if state2.elapsed < CheckIntervalSeconds then
			state:set(state2)
			return
		end
		state2.elapsed = 0.0

		state2.slowElapsed = (state2.slowElapsed or 0.0) + CheckIntervalSeconds
		local slowNow = false
		if state2.slowElapsed >= SlowCheckIntervalSeconds then
			state2.slowElapsed = 0.0
			slowNow = true
		end

		-- the choice of the mod parameter "Estate size" (see mod.script.tl)
		local baseConfig = api.res.getBaseConfig()
		local takeOver = math.floor(baseConfig.locations.town.populationDensity + 0.5) % 4 >= 2

		api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
			local town = api.engine.getComponent(entity, api.type.ComponentType.TOWN) as Engine.Component.Town
			if not (town and town.initialLandUseCapacities and town.sizeFactors) then
				return
			end

			local e = tostring(entity)
			local name = api.engine.util.getEntityName(entity)
			local marked = isEstate(name)
			local phase = state2["c" .. e] or 0

			local caps : {integer} = {
				town.initialLandUseCapacities[1] or 0,
				town.initialLandUseCapacities[2] or 0,
				town.initialLandUseCapacities[3] or 0,
			}
			local sizes : {number} = {
				town.sizeFactors[1] or 0,
				town.sizeFactors[2] or 0,
				town.sizeFactors[3] or 0,
			}
			local keptCapacity = caps[KeptIndex]
			local othersCapacity = otherSum(caps)

			if marked then
				if phase == 0 or phase == 2 then
					-- a (re)marked town: remember how it looked, if it still has the other zones
					if othersCapacity > 0 then
						state2["oK" .. e] = 1
						for i = 1, 3 do
							state2["o" .. tostring(i) .. e] = caps[i]
							state2["s" .. tostring(i) .. e] = sizes[i]
						end
					end
					state2["c" .. e] = 1
					state2["r" .. e] = 0
					state2["a" .. e] = 0
					log.message("CommercialEstateTowns: commercial estate found: town " .. e .. " '" .. tostring(name) .. "' " .. describe(town))
				end

				if othersCapacity > 0 then
					-- step 1: the other two zones are set to zero, the town needs a district of the kept zone
					local newKept = keptCapacity
					if takeOver then
						-- the estate takes over the space of the other two zones of this town (capacity times size of all three)
						local total = 0.0
						for i = 1, 3 do
							local size = sizes[i]
							if size <= 0 then
								size = 1.0
							end
							total = total + caps[i] * size
						end
						newKept = math.floor(total + 0.5)
						if newKept < MinCapacity then
							newKept = MinCapacity
						end
						state2["t" .. e] = 1
						log.message("CommercialEstateTowns: size taken over from the other zones: town " .. e .. " total=" .. tostring(newKept))
					elseif newKept <= 0 then
						local base = 0
						for i = 1, 3 do
							if i ~= KeptIndex and caps[i] > base then
								base = caps[i]
							end
						end
						newKept = math.floor(base * Ratios[KeptIndex] + 0.5)
						if newKept < MinCapacity then
							newKept = MinCapacity
						end
					end
					local newCaps : {integer} = { 0, 0, 0 }
					newCaps[KeptIndex] = newKept
					api.cmd.sendCommand(api.cmd.makeTownSetInitialLandUseCapacitiesCmd(entity, newCaps))
				elseif (sizes[KeptIndex] <= 0 and keptCapacity > 0) or (state2["t" .. e] or 0) == 1 then
					-- step 2: the kept district is scaled to zero or its size has to be reset after it took over, set it to 1
					state2["t" .. e] = 2
					local newSizes : {number} = { sizes[1], sizes[2], sizes[3] }
					newSizes[KeptIndex] = 1.0
					api.cmd.sendCommand(api.cmd.makeTownUpdateSizeCmd(entity, newSizes, true))
				elseif slowNow then
					-- step 3: buildings of the other zones still stand, ask the town to update its buildings
					local built = api.engine.system.townBuildingSystem.getLandUsePersonCapacities(entity)
					local builtOther = 0
					for i = 1, 3 do
						if i ~= KeptIndex then
							builtOther = builtOther + (built and built[i] or 0)
						end
					end
					local attempts = state2["r" .. e] or 0
					if builtOther > 0 and attempts < MaxRemovalAttempts then
						state2["r" .. e] = attempts + 1
						log.message("CommercialEstateTowns: removal request " .. tostring(attempts + 1) .. " for town " .. e)
						api.cmd.sendCommand(api.cmd.makeTownUpdateSizeCmd(entity, { sizes[1], sizes[2], sizes[3] }, true))
					end
				end
			elseif phase == 1 then
				-- the keyword was removed from the name: restore the other zones
				local haveOriginals = (state2["oK" .. e] or 0) == 1
				log.message("CommercialEstateTowns: keyword removed, restoring town " .. e .. " '" .. tostring(name) .. "' originals=" .. tostring(haveOriginals))
				if haveOriginals then
					local restored : {integer} = { 0, 0, 0 }
					for i = 1, 3 do
						restored[i] = math.floor((state2["o" .. tostring(i) .. e] or 0) + 0.5)
					end
					if restored[KeptIndex] <= 0 then
						restored[KeptIndex] = keptCapacity
					end
					api.cmd.sendCommand(api.cmd.makeTownSetInitialLandUseCapacitiesCmd(entity, restored))
				else
					-- no originals known (the town was already an estate before): typical size of the towns of this map
					local reference = referenceCapacities()
					if reference then
						log.message("CommercialEstateTowns: restored with the typical size of the towns of this map: " .. table.concat({ tostring(reference[1]), tostring(reference[2]), tostring(reference[3]) }, "/"))
						api.cmd.sendCommand(api.cmd.makeTownSetInitialLandUseCapacitiesCmd(entity, reference))
					else
						api.cmd.sendCommand(api.cmd.makeTownSetInitialLandUseCapacitiesCmd(entity))
					end
				end
				state2["c" .. e] = 2
				state2["a" .. e] = 0
			elseif phase == 0 and othersCapacity <= 0 then
				-- no keyword, no memory (the game drops the script state when the mod is missing at load),
				-- but the other two zones are both zero: a leftover estate, restore it
				log.message("CommercialEstateTowns: leftover commercial estate, restoring town " .. e .. " '" .. tostring(name) .. "' " .. describe(town))
				local reference = referenceCapacities()
				if reference then
					log.message("CommercialEstateTowns: restored with the typical size of the towns of this map: " .. table.concat({ tostring(reference[1]), tostring(reference[2]), tostring(reference[3]) }, "/"))
					api.cmd.sendCommand(api.cmd.makeTownSetInitialLandUseCapacitiesCmd(entity, reference))
				else
					api.cmd.sendCommand(api.cmd.makeTownSetInitialLandUseCapacitiesCmd(entity))
				end
				state2["c" .. e] = 2
				state2["a" .. e] = 0
			elseif phase == 2 then
				local allBack = true
				for i = 1, 3 do
					if i ~= KeptIndex and caps[i] <= 0 then
						allBack = false
					end
				end
				if allBack then
					-- the capacities are back: scale the zones up and let the town rebuild
					local newSizes : {number} = { sizes[1], sizes[2], sizes[3] }
					for i = 1, 3 do
						if i ~= KeptIndex then
							local original = state2["s" .. tostring(i) .. e] or 1.0
							if original <= 0 then
								original = 1.0
							end
							newSizes[i] = original
						end
					end
					log.message("CommercialEstateTowns: town " .. e .. " restored, sizes " .. table.concat({ tostring(newSizes[1]), tostring(newSizes[2]), tostring(newSizes[3]) }, "/"))
					api.cmd.sendCommand(api.cmd.makeTownUpdateSizeCmd(entity, newSizes, true))
					state2["c" .. e] = 0
				else
					local attempts = state2["a" .. e] or 0
					state2["a" .. e] = attempts + 1
					if attempts >= MaxRestoreAttempts then
						-- the capacities did not come back: typical size of the towns of this map, or the ratio of the kept zone as the last resort
						local reference = referenceCapacities()
						local unit = FallbackCapacity / Ratios[KeptIndex]
						if keptCapacity > 0 then
							unit = keptCapacity / Ratios[KeptIndex]
						end
						local fallback : {integer} = { caps[1], caps[2], caps[3] }
						for i = 1, 3 do
							if i ~= KeptIndex and fallback[i] <= 0 then
								if reference then
									fallback[i] = reference[i]
								else
									fallback[i] = math.floor(unit * Ratios[i] + 0.5)
								end
								if fallback[i] < MinCapacity then
									fallback[i] = MinCapacity
								end
							end
						end
						log.message("CommercialEstateTowns: fallback capacities for town " .. e)
						api.cmd.sendCommand(api.cmd.makeTownSetInitialLandUseCapacitiesCmd(entity, fallback))
					end
				end
			end
		end, api.type.ComponentType.TOWN)

		state:set(state2)
	end,
}

return ret
