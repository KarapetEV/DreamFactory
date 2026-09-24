--[[
	Тестовая обвязка для серверных модулей вне Roblox (запуск через lune: src/tests/run.luau).

	Даёт каждому тесту изолированный «мир»:
	- кооперативный планировщик: task.wait/task.spawn на корутинах с виртуальным временем,
	  чтобы гонки (медленный UpdateAsync, реджойн посреди загрузки) воспроизводились
	  детерминированно;
	- поддельный DataStore: UpdateAsync с глубоким копированием и настраиваемой задержкой
	  каждого вызова (очередь StoreDelays);
	- загрузчик модулей проекта по дереву default.project.json (ReplicatedStorage.shared,
	  script.Parent...) с подменой глобалов game/task/os/warn/Enum.

	Каждый вызов world:NewServer() загружает модули заново — это отдельный «процесс сервера»
	со своим состоянием модулей, но общим DataStore мира.

	Чтение файлов и компиляция зависят от рантайма, поэтому их передаёт раннер через
	Harness.Configure({ ReadFile = ..., Load = ... }).
]]

export type Runtime = {
	-- Содержимое файла по пути относительно корня репозитория.
	ReadFile: (path: string) -> string,
	-- Компилирует исходник в функцию с заданным окружением глобалов.
	Load: (source: string, chunkName: string, env: { [string]: any }) -> () -> any,
}

-- Пути Rojo-дерева (default.project.json), нужные серверным модулям.
local ROJO_ROOTS = {
	ReplicatedStorage = { shared = "src/shared" },
	ServerScriptService = { server = "src/server" },
}

local runtime: Runtime? = nil

local Harness = {}

function Harness.Configure(newRuntime: Runtime)
	runtime = newRuntime
end

local function getRuntime(): Runtime
	assert(runtime, "Harness.Configure не вызван (запускайте тесты через src/tests/run.luau)")
	return runtime
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[k] = deepCopy(v)
	end
	return copy
end

-- Узел «дерева инстансов», соответствующий пути в репозитории. require(узел) грузит
-- <путь>.luau; индексация даёт дочерний узел; .Parent — родительский каталог.
local function pathNode(path: string): any
	return setmetatable({ __path = path }, {
		__index = function(_self, key)
			if key == "Parent" then
				return pathNode((string.match(path, "^(.*)/[^/]+$")) or "")
			end
			return pathNode(path .. "/" .. tostring(key))
		end,
	})
end

local World = {}
World.__index = World

export type Player = { UserId: number, Name: string, Parent: any }

function Harness.NewWorld()
	local self = setmetatable({}, World)

	self.Now = 0
	self.Records = {} :: { [string]: any }
	-- Задержки (виртуальные секунды) для следующих вызовов UpdateAsync, по одной на вызов.
	self.StoreDelays = {} :: { number }
	self.Warnings = {} :: { string }
	self._sleeping = {} :: { { at: number, seq: number, co: thread } }
	self._seq = 0
	self._guid = 0

	local world = self

	self.Task = {
		wait = function(seconds: number?): number
			world._seq += 1
			table.insert(world._sleeping, {
				at = world.Now + (seconds or 0.03),
				seq = world._seq,
				co = coroutine.running(),
			})
			return coroutine.yield()
		end,
		spawn = function(fn: (...any) -> ...any, ...: any): thread
			local co = coroutine.create(fn)
			world:_resume(co, ...)
			return co
		end,
	}

	self.Store = {
		UpdateAsync = function(_store: any, key: string, transform: (any, any) -> (any, any)): any
			local delay = table.remove(world.StoreDelays, 1)
			if delay and delay > 0 then
				world.Task.wait(delay)
			end
			local newValue = transform(deepCopy(world.Records[key]), nil)
			if newValue ~= nil then
				world.Records[key] = deepCopy(newValue)
			end
			return newValue
		end,
	}

	return self
end

function World:_resume(co: thread, ...: any)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		error(debug.traceback(co, tostring(err)), 0)
	end
end

-- Запускает функцию в новой корутине (как task.spawn в игре).
function World:Spawn(fn: () -> ())
	self.Task.spawn(fn)
end

-- Прокручивает виртуальное время, пока есть спящие корутины и не достигнут limit.
function World:RunUntil(limit: number)
	while #self._sleeping > 0 do
		table.sort(self._sleeping, function(a, b)
			if a.at == b.at then
				return a.seq < b.seq
			end
			return a.at < b.at
		end)
		local nextItem = self._sleeping[1]
		if nextItem.at > limit then
			break
		end
		table.remove(self._sleeping, 1)
		self.Now = math.max(self.Now, nextItem.at)
		self:_resume(nextItem.co)
	end
	self.Now = math.max(self.Now, limit)
end

-- Прокрутить время на duration секунд вперёд от текущего момента.
function World:Advance(duration: number)
	self:RunUntil(self.Now + duration)
end

function World:NewPlayer(userId: number?): Player
	return { UserId = userId or 42, Name = "TestPlayer", Parent = true }
end

function World:_makeEnv(moduleCache: { [string]: any }, scriptPath: string?): { [string]: any }
	local world = self
	local signal = { Connect = function() end }

	local services = {
		HttpService = {
			GenerateGUID = function(_self: any, _wrap: boolean?): string
				world._guid += 1
				return `guid-{world._guid}`
			end,
		},
		DataStoreService = {
			GetDataStore = function(_self: any, _name: string)
				return world.Store
			end,
			GetRequestBudgetForRequestType = function()
				return 100
			end,
		},
		RunService = {
			IsStudio = function()
				return false
			end,
			IsServer = function()
				return true
			end,
		},
		Players = {
			PlayerAdded = signal,
			PlayerRemoving = signal,
			GetPlayers = function()
				return {}
			end,
		},
	}
	for serviceName, roots in ROJO_ROOTS do
		local service = services[serviceName] or {}
		for childName, path in roots do
			service[childName] = pathNode(path)
		end
		services[serviceName] = service
	end

	local env: { [string]: any } = {}
	env.task = self.Task
	env.warn = function(...: any)
		local parts = {}
		for i = 1, select("#", ...) do
			table.insert(parts, tostring((select(i, ...))))
		end
		table.insert(world.Warnings, table.concat(parts, " "))
	end
	env.os = {
		time = function(): number
			return 1_000_000 + math.floor(world.Now)
		end,
		clock = function(): number
			return world.Now
		end,
	}
	env.Enum = { DataStoreRequestType = { UpdateAsync = "UpdateAsync" } }
	env.game = {
		PlaceId = 1,
		JobId = "",
		BindToClose = function() end,
		GetService = function(_self: any, name: string)
			return assert(services[name], `Harness: сервис {name} не застаблен`)
		end,
	}
	env.script = if scriptPath then pathNode(scriptPath) else nil
	env.require = function(node: any): any
		local path = assert(type(node) == "table" and rawget(node, "__path"), "Harness: require поддерживает только пути проекта")
		return world:_loadModule(path, moduleCache)
	end

	return env
end

function World:_loadModule(path: string, moduleCache: { [string]: any }): any
	local cached = moduleCache[path]
	if cached ~= nil then
		-- false — маркер модуля, вернувшего nil.
		return if cached == false then nil else cached
	end

	local rt = getRuntime()
	local source = rt.ReadFile(path .. ".luau")
	local chunk = rt.Load(source, path, self:_makeEnv(moduleCache, path))
	local result = chunk()
	moduleCache[path] = if result == nil then false else result
	return result
end

-- Новый «процесс сервера»: свежие копии модулей, общий DataStore мира.
-- Возвращает ProfileStoreService (уже Init) и DataSystem (без Init — события Players не нужны).
function World:NewServer(onSessionLost: ((player: any) -> ())?): (any, any)
	local cache = {}
	local profileStore = self:_loadModule("src/server/Services/ProfileStoreService", cache)
	local dataSystem = self:_loadModule("src/server/Systems/DataSystem", cache)
	profileStore.Init({
		StoreName = "TestProfiles",
		CreateDefaultData = dataSystem.BuildDefaultProfile,
		OnSessionLost = onSessionLost,
	})
	return profileStore, dataSystem
end

Harness.DeepCopy = deepCopy

return Harness
