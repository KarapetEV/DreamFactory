--!strict

local Controllers = script.Controllers
local UI = script.UI
local Visuals = script.Visuals

-- HUD первым: CollectionController.Init ждёт папку фрагментов в Workspace (yield).
local HUD = require(UI.HUD)
HUD.Init()
require(UI.ShopUI).Init(HUD)
local PetInventoryUI = require(UI.PetInventoryUI)
PetInventoryUI.Init(HUD)
require(UI.ChaosEventUI).Init(HUD)
require(Controllers.CollectionController).Init()

-- Визуал MVP: только отображение по снимкам/атрибутам сервера, без собственных ремоут.
-- Ошибка одного модуля визуала не должна ломать остальные (и игровой UI выше).
local function initVisual(name: string, ...: any)
	local ok, err = pcall(require(Visuals[name]).Init, ...)
	if not ok then
		warn(`[Visuals] {name} не запустился: {err}`)
	end
end
initVisual("BiomeLighting")
initVisual("FragmentVisuals")
initVisual("PetVisuals")
initVisual("CocoonEffect", PetInventoryUI)
initVisual("FactoryVisuals", HUD)
initVisual("BossVisuals", HUD)
initVisual("PlayerEffects", HUD)
