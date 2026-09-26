--!strict

local Controllers = script.Controllers
local UI = script.UI

-- HUD первым: CollectionController.Init ждёт папку фрагментов в Workspace (yield).
local HUD = require(UI.HUD)
HUD.Init()
require(UI.ShopUI).Init(HUD)
require(Controllers.CollectionController).Init()
