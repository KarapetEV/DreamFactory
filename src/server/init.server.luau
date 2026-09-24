--!strict

local ServerScriptService = game:GetService("ServerScriptService")

local Systems = ServerScriptService.server.Systems

-- DataSystem первым: остальные системы получают данные игрока через DataSystem.GetData/WaitForData.
require(Systems.DataSystem).Init()
