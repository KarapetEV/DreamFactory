--!strict

local ServerScriptService = game:GetService("ServerScriptService")

local Systems = ServerScriptService.server.Systems
local Services = ServerScriptService.server.Services

-- MovementGuard до систем: доверенная позиция отслеживается с первого CharacterAdded.
require(Services.MovementGuard).Init()

-- DataSystem первым: остальные системы получают данные игрока через DataSystem.GetData/WaitForData.
require(Systems.DataSystem).Init()
require(Systems.CollectionSystem).Init()
require(Systems.FactorySystem).Init()
require(Systems.PetSystem).Init()
require(Systems.RebirthSystem).Init()
require(Systems.ChaosBossSystem).Init()
require(Systems.PvPRaidSystem).Init()
require(Systems.BattlePassSystem).Init()
require(Systems.MonetizationSystem).Init()

-- Визуал: Terrain-декор биомов (геймплей от него не зависит).
require(Services.WorldDecor).Init()
