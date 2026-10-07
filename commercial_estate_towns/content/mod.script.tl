
local mod = {}

-- the choice of "Estate size" is handed to the game script in baseConfig.locations.town.populationDensity (unused after map generation):
-- 1000 plus 1 when the residential estate mod takes over the space, plus 2 for the commercial estate mod
mod.preRunFn = function(captureParams, _configDict : {{string, string}}, allModParams : {string : {string : integer}}, baseConfig : BaseConfig)
	local params = allModParams["felix_commercial_estate_towns_1"]
	local choice = params and params["takeover"] or 1
	local channel = baseConfig.locations.town.populationDensity
	if channel < 1000 then
		channel = 1000
	end
	if choice >= 2 then
		channel = channel + 2
	end
	baseConfig.locations.town.populationDensity = channel
	log.message("CommercialEstateTowns: estate size choice=" .. tostring(choice) .. " channel=" .. tostring(channel))
end

return mod
