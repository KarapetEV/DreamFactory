--!strict

-- Событие для связи систем без прямых зависимостей (принцип «Модульность» в CLAUDE.md).
-- Обработчики запускаются через task.spawn: ошибка или yield подписчика не прерывает
-- код, который вызвал Fire (например, транзакцию FactorySystem).

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal = {
	Connect: (self: Signal, handler: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
}

type Handler = {
	Connection: Connection,
	Callback: (...any) -> (),
}

local Signal = {}
Signal.__index = Signal

function Signal.new(): Signal
	return setmetatable({ _handlers = {} :: { Handler } }, Signal) :: any
end

function Signal.Connect(self: any, handler: (...any) -> ()): Connection
	local handlers: { Handler } = self._handlers
	local entry: Handler

	local connection: Connection = {
		Connected = true,
		Disconnect = function(conn: Connection)
			if not conn.Connected then
				return
			end
			conn.Connected = false
			local index = table.find(handlers, entry)
			if index then
				table.remove(handlers, index)
			end
		end,
	}
	entry = { Connection = connection, Callback = handler }
	table.insert(handlers, entry)
	return connection
end

function Signal.Fire(self: any, ...: any)
	-- Снимок: подписки/отписки внутри обработчиков не ломают текущий обход.
	for _, entry in table.clone(self._handlers :: { Handler }) do
		if entry.Connection.Connected then
			task.spawn(entry.Callback, ...)
		end
	end
end

return Signal
