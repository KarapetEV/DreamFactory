--!strict

local Controllers = script.Controllers
local UI = script.UI

-- HUD первым: CollectionController.Init ждёт папку фрагментов в Workspace (yield).
require(UI.HUD).Init()
require(Controllers.CollectionController).Init()
