-- GuardUtils.lua | ModuleScript
-- Ubicación recomendada:
-- ServerScriptService.ServerModules.GuardUtils
--
-- RESPONSABILIDAD:
--   - Validar estructuras de datos del servidor.
--   - Sanitizar strings y números.
--   - Aplicar rate limiting con limpieza acotada.
--   - Administrar mutex con token de propietario y watchdog.
--   - Copiar tablas preservando referencias compartidas y ciclos.
--   - Generar identificadores globalmente únicos.
--
-- NOTA:
--   Las funciones con estado inician el watchdog automáticamente.
--   También puede controlarse explícitamente con Start() y Stop().

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local GuardUtils = { VERSION = "3.0.0-rc.1" }

local CONFIG = table.freeze({
	MAX_KEYS_PER_TABLE = 100,
	MAX_TOTAL_NODES = 10000,
	MAX_DEPTH = 16,
	MAX_STRING_LENGTH = 10000,
	MAX_TOTAL_BYTES = 4 * 1024 * 1024,
	HARD_MAX_STRING_BYTES = 65536,
	HARD_MAX_DEPTH = 64,
	HARD_MAX_NODES = 100000,
	HARD_MAX_KEYS = 10000,
	HARD_MAX_TOTAL_BYTES = 16 * 1024 * 1024,

	MAX_REQUESTS_PER_WINDOW = 10,
	DEFAULT_RATE_LIMIT_WINDOW = 1,
	MAX_RATE_LIMIT_KEYS = 10000,
	RATE_LIMIT_KEY_TTL = 120,
	MAX_RATE_LIMIT_KEY_LENGTH = 200,

	MAX_SAFE_INTEGER = 2 ^ 50,

	WATCHDOG_INTERVAL = 1,
	DEFAULT_MUTEX_TIMEOUT = 30,
	MAX_MUTEX_TIMEOUT = 3600,
})

local rateLimitEntries = {}
local rateLimitKeyCount = 0

-- [registrationId] = {
--     MutexRef = weakValueReference,
--     Timeout = number,
-- }
local mutexRegistrations = {}

-- Evita registrar dos veces la misma tabla.
-- Las claves son débiles para no impedir recolección.
local mutexRegistrationIdsByTable = setmetatable(
	{},
	{
		__mode = "k",
	}
)

local running = false
local watchdogGeneration = 0

-- ==========================================================================
-- HELPERS GENERALES
-- ==========================================================================

local function isFiniteNumber(value)
	return type(value) == "number"
		and value == value
		and value > -math.huge
		and value < math.huge
end

local function isPositiveInteger(value)
	return isFiniteNumber(value)
		and value >= 1
		and value % 1 == 0
end

local function isValidMutexKey(key)
	local keyType = type(key)

	if keyType == "string" then
		return key ~= ""
	end

	if keyType == "number" then
		return isFiniteNumber(key)
	end

	return false
end

local function createWeakValueReference(value)
	return setmetatable(
		{
			Value = value,
		},
		{
			__mode = "v",
		}
	)
end

local function makePath(parentPath, key)
	local kind = type(key)
	if kind == "number" then return parentPath .. "[" .. tostring(key) .. "]" end
	if kind ~= "string" then return parentPath .. "[<" .. kind .. " key>]" end
	local preview = key:sub(1, 64)
	if #key > 64 then preview = preview .. "..." end
	if preview:match("^[%a_][%w_]*$") then return parentPath .. "." .. preview end
	return parentPath .. "[" .. string.format("%q", preview) .. "]"
end

local function validateUtf8(value)
	local length = utf8.len(value)
	return length ~= nil, length
end

local function normalizeValidationOptions(options)
	if options == nil then options = {} end
	if type(options) ~= "table" or getmetatable(options) ~= nil then
		return nil, "INVALID_VALIDATION_OPTIONS"
	end
	local normalized = {}
	local bounds = {
		MaxKeysPerTable = {CONFIG.MAX_KEYS_PER_TABLE, CONFIG.HARD_MAX_KEYS},
		MaxTotalNodes = {CONFIG.MAX_TOTAL_NODES, CONFIG.HARD_MAX_NODES},
		MaxDepth = {CONFIG.MAX_DEPTH, CONFIG.HARD_MAX_DEPTH},
		MaxStringLength = {CONFIG.MAX_STRING_LENGTH, CONFIG.HARD_MAX_STRING_BYTES},
		MaxTotalBytes = {CONFIG.MAX_TOTAL_BYTES, CONFIG.HARD_MAX_TOTAL_BYTES},
	}
	for name, bound in pairs(bounds) do
		local value = rawget(options, name)
		if value == nil then value = bound[1] end
		if not isPositiveInteger(value) or value > bound[2] then
			return nil, "INVALID_VALIDATION_OPTIONS"
		end
		normalized[name] = value
	end
	local flags = {
		RejectMetatables = true, RequireUtf8 = true, RejectNullBytes = true,
		RequireArrayOrDictionary = false, RequireContiguousArrays = false,
	}
	for name, default in pairs(flags) do
		local value = rawget(options, name)
		if value == nil then value = default end
		if type(value) ~= "boolean" then return nil, "INVALID_VALIDATION_OPTIONS" end
		normalized[name] = value
	end
	return normalized
end

local function validateStringValue(value, options, state)
	if #value > CONFIG.HARD_MAX_STRING_BYTES then return false, "STRING_TOO_LONG" end
	state.TotalBytes += #value
	if state.TotalBytes > options.MaxTotalBytes then return false, "MAX_TOTAL_BYTES_EXCEEDED" end
	if options.RejectNullBytes
		and value:find("\0", 1, true) then

		return false, "NULL_BYTE"
	end

	local stringLength

	if options.RequireUtf8 then
		local validUtf8
		validUtf8, stringLength =
			validateUtf8(value)

		if not validUtf8 then
			return false, "INVALID_UTF8"
		end
	else
		stringLength = #value
	end

	if stringLength > options.MaxStringLength then
		return false, "STRING_TOO_LONG"
	end

	return true
end

local function validateTableKey(key, options, state)
	local keyType = type(key)

	if keyType == "string" then
		local valid, errorCode =
			validateStringValue(key, options, state)

		if not valid then
			return false, "INVALID_KEY_" .. errorCode
		end

		return true, "STRING"
	end

	if keyType == "number" then
		if not isPositiveInteger(key)
			or key > CONFIG.MAX_SAFE_INTEGER then

			return false, "INVALID_NUMERIC_KEY"
		end

		return true, "NUMBER"
	end

	return false, "INVALID_KEY_TYPE"
end

local function validateValue(
	value,
	options,
	state,
	depth,
	path
)
	state.TotalNodes += 1

	if state.TotalNodes > options.MaxTotalNodes then
		return false,
			"MAX_TOTAL_NODES_EXCEEDED",
			path
	end

	local valueType = type(value)

	if valueType == "boolean" then
		return true
	end

	if valueType == "number" then
		if not isFiniteNumber(value) then
			return false, "INVALID_NUMBER", path
		end

		if math.abs(value)
			> CONFIG.MAX_SAFE_INTEGER then

			return false, "NUMBER_OUT_OF_SAFE_RANGE", path
		end

		return true
	end

	if valueType == "string" then
		local valid, errorCode =
			validateStringValue(value, options, state)

		if not valid then
			return false, errorCode, path
		end

		return true
	end

	if valueType ~= "table" then
		return false,
			"UNSUPPORTED_TYPE_" .. valueType,
			path
	end

	if depth > options.MaxDepth then
		return false,
			"MAX_DEPTH_EXCEEDED",
			path
	end

	if options.RejectMetatables
		and getmetatable(value) ~= nil then

		return false, "METATABLE_NOT_ALLOWED", path
	end

	if state.ActiveTables[value] then
		return false, "CYCLIC_REFERENCE", path
	end

	state.ActiveTables[value] = true

	local keyCount = 0
	local stringKeyCount = 0
	local numericKeyCount = 0
	local maximumNumericKey = 0

	for key, childValue in next, value do
		keyCount += 1

		if keyCount > options.MaxKeysPerTable then
			return false,
				"MAX_KEYS_PER_TABLE_EXCEEDED",
				path
		end

		local keyValid, keyKindOrError =
			validateTableKey(key, options, state)

		if not keyValid then
			return false,
				keyKindOrError,
				makePath(path, key)
		end

		if keyKindOrError == "STRING" then
			stringKeyCount += 1
		else
			numericKeyCount += 1
			maximumNumericKey =
				math.max(
					maximumNumericKey,
					key
				)
		end

		local childValid,
			childError,
			childPath =
			validateValue(
				childValue,
				options,
				state,
				depth + 1,
				makePath(path, key)
			)

		if not childValid then
			return false,
				childError,
				childPath
		end
	end

	if options.RequireArrayOrDictionary
		and stringKeyCount > 0
		and numericKeyCount > 0 then

		return false,
			"MIXED_TABLE_KEYS",
			path
	end

	if options.RequireContiguousArrays
		and numericKeyCount > 0
		and maximumNumericKey ~= numericKeyCount then

		return false,
			"NON_CONTIGUOUS_ARRAY",
			path
	end

	state.ActiveTables[value] = nil

	return true
end

-- ==========================================================================
-- VALIDACIÓN DE DATOS
-- ==========================================================================

-- Valida una estructura completa.
--
-- Retorna:
--   true
-- o:
--   false, errorCode, errorPath
function GuardUtils.validateData(value, options)
	if value == nil then
		return false, "NIL_ROOT", "$"
	end

	local normalizedOptions, optionsError =
		normalizeValidationOptions(options)

	if not normalizedOptions then
		return false, optionsError, "$"
	end

	local state = {TotalNodes = 0, TotalBytes = 0, ActiveTables = {}}


	return validateValue(
		value,
		normalizedOptions,
		state,
		1,
		"$"
	)
end

-- Compatibilidad simple con la API anterior.
--
-- maxKeys puede ser:
--   - number: máximo de claves por tabla;
--   - table: opciones completas para validateData.
function GuardUtils.isValidData(value, maxKeys)
	local options

	if type(maxKeys) == "number" then
		options = {
			MaxKeysPerTable = maxKeys,
		}
	elseif type(maxKeys) == "table" then
		options = maxKeys
	elseif maxKeys ~= nil then
		return false
	end

	local valid =
		GuardUtils.validateData(
			value,
			options
		)

	return valid == true
end

-- Validador estricto para datos con forma serializable.
--
-- Reglas adicionales:
--   - una tabla debe ser array o diccionario, no ambos;
--   - los arrays deben ser contiguos desde 1.
function GuardUtils.isDataStoreSafe(value, options)
	local strict, code = normalizeValidationOptions(options)
	if not strict then return false, code, "$" end
	strict.RejectMetatables = true
	strict.RequireUtf8 = true
	strict.RejectNullBytes = true
	strict.RequireArrayOrDictionary = true
	strict.RequireContiguousArrays = true
	return GuardUtils.validateData(value, strict)
end

function GuardUtils.jugadorValido(player)
	return typeof(player) == "Instance"
		and player:IsA("Player")
		and player.Parent == Players
end

function GuardUtils.datosCargados(
	player,
	isLoadedFunc
)
	if not GuardUtils.jugadorValido(player) then
		return false, "INVALID_PLAYER"
	end

	if type(isLoadedFunc) ~= "function" then
		return false, "INVALID_CALLBACK"
	end

	local succeeded, result =
		pcall(
			isLoadedFunc,
			player
		)

	if not succeeded then
		warn(
			"[GuardUtils] datosCargados falló:",
			result
		)

		return false, "CALLBACK_ERROR"
	end

	return result == true
end

-- ==========================================================================
-- SANITIZACIÓN
-- ==========================================================================

-- Retorna:
--   cleanedString
-- o:
--   nil, errorCode
function GuardUtils.sanitizeString(
	value,
	maxLength
)
	if type(value) ~= "string" then
		return nil, "INVALID_TYPE"
	end

	local limit = maxLength
	if limit == nil then limit = 1000 end

	if not isPositiveInteger(limit) or limit > CONFIG.HARD_MAX_STRING_BYTES then
		return nil, "INVALID_MAX_LENGTH"
	end
	if #value > CONFIG.HARD_MAX_STRING_BYTES then return nil, "STRING_TOO_LONG" end

	-- Quita caracteres de control, incluido el byte nulo.
	local cleaned =
		value:gsub("%c", "")

	-- Quita espacios exteriores después de limpiar.
	cleaned =
		cleaned:match("^%s*(.-)%s*$")
		or ""

	if cleaned == "" then
		return nil, "EMPTY_STRING"
	end

	local validUtf8, characterCount =
		validateUtf8(cleaned)

	if not validUtf8 then
		return nil, "INVALID_UTF8"
	end

	if characterCount > limit then
		return nil, "STRING_TOO_LONG"
	end

	return cleaned
end

-- options:
--   Integer = true | false
--   Clamp = true | false
--
-- Por seguridad, Clamp es false de forma predeterminada.
-- Un valor fuera del rango se rechaza en vez de corregirse silenciosamente.
function GuardUtils.sanitizeNumber(
	value,
	minimum,
	maximum,
	options
)
	if not isFiniteNumber(value) then
		return nil, "INVALID_NUMBER"
	end

	local minValue, maxValue = minimum, maximum
	if minValue == nil then minValue = 0 end
	if maxValue == nil then maxValue = CONFIG.MAX_SAFE_INTEGER end

	if not isFiniteNumber(minValue)
		or not isFiniteNumber(maxValue)
		or minValue > maxValue
		or math.abs(minValue) > CONFIG.MAX_SAFE_INTEGER
		or math.abs(maxValue) > CONFIG.MAX_SAFE_INTEGER then

		return nil, "INVALID_RANGE"
	end

	if options == nil then options = {} end
	if type(options) ~= "table" or getmetatable(options) ~= nil then return nil, "INVALID_OPTIONS" end
	if (options.Integer ~= nil and type(options.Integer) ~= "boolean")
		or (options.Clamp ~= nil and type(options.Clamp) ~= "boolean") then return nil, "INVALID_OPTIONS" end
	local integerMode =
		options.Integer ~= false

	local clampMode =
		options.Clamp == true

	local sanitized = value

	if integerMode then
		minValue, maxValue = math.ceil(minValue), math.floor(maxValue)
		if minValue > maxValue then return nil, "INVALID_RANGE" end
		sanitized = math.floor(sanitized)
	end

	if sanitized < minValue
		or sanitized > maxValue then

		if not clampMode then
			return nil, "OUT_OF_RANGE"
		end

		sanitized =
			math.clamp(
				sanitized,
				minValue,
				maxValue
			)
	end

	return sanitized
end

-- ==========================================================================
-- RATE LIMITING
-- ==========================================================================

local function validateRateLimitKey(key)
	return type(key) == "string"
		and key ~= ""
		and #key <= CONFIG.MAX_RATE_LIMIT_KEY_LENGTH
end

local function validateRateLimitConfig(
	maxRequests,
	windowSeconds
)
	if not isPositiveInteger(maxRequests) then
		return false
	end

	if not isFiniteNumber(windowSeconds)
		or windowSeconds <= 0 then

		return false
	end

	return true
end

local function compactRateEntry(entry)
	local timestamps = entry.Timestamps
	local head = entry.Head

	if head <= 1 then
		return
	end

	local compacted = {}

	for index = head, #timestamps do
		table.insert(
			compacted,
			timestamps[index]
		)
	end

	entry.Timestamps = compacted
	entry.Head = 1
end

local function cleanupRateEntry(
	entry,
	now,
	windowSeconds
)
	local timestamps = entry.Timestamps
	local head = entry.Head

	while timestamps[head]
		and now - timestamps[head]
		>= windowSeconds do

		head += 1
	end

	entry.Head = head

	if head > 64
		and head > #timestamps / 2 then

		compactRateEntry(entry)
	end
end

local function getActiveRateCount(entry)
	return #entry.Timestamps
	- entry.Head
		+ 1
end

local function ensureStarted()
	if not running then
		GuardUtils.Start()
	end
end

-- Retorna:
--   limited, errorCode?
--
-- Ante configuración inválida falla de forma cerrada:
-- devuelve true para no desactivar accidentalmente la protección.
function GuardUtils.isRateLimited(
	key,
	maxRequestsPerWindow,
	windowSeconds
)
	ensureStarted()

	if not validateRateLimitKey(key) then
		warn(
			"[GuardUtils] Clave de rate limit inválida."
		)

		return true, "INVALID_KEY"
	end

	local limit =
		maxRequestsPerWindow
		or CONFIG.MAX_REQUESTS_PER_WINDOW

	local window =
		windowSeconds
		or CONFIG.DEFAULT_RATE_LIMIT_WINDOW

	if not validateRateLimitConfig(
		limit,
		window
		) then

		warn(
			"[GuardUtils] Configuración de rate limit inválida."
		)

		return true, "INVALID_RATE_LIMIT_CONFIG"
	end

	local now = os.clock()
	local entry = rateLimitEntries[key]

	if not entry then
		if rateLimitKeyCount
			>= CONFIG.MAX_RATE_LIMIT_KEYS then

			return true,
				"RATE_LIMIT_CAPACITY_REACHED"
		end

		entry = {
			Timestamps = {},
			Head = 1,
			LastSeen = now,
			WindowSeconds = window,
		}

		rateLimitEntries[key] = entry
		rateLimitKeyCount += 1
	else
		-- La ventana queda ligada a la clave.
		-- Si el llamador cambia de configuración, se limpia el historial
		-- para evitar mezclar ventanas incompatibles.
		if entry.WindowSeconds ~= window then
			entry.Timestamps = {}
			entry.Head = 1
			entry.WindowSeconds = window
		end

		entry.LastSeen = now
	end

	cleanupRateEntry(
		entry,
		now,
		window
	)

	if getActiveRateCount(entry)
		>= limit then

		return true
	end

	table.insert(
		entry.Timestamps,
		now
	)

	return false
end

function GuardUtils.cleanupRateLimit(key)
	if type(key) ~= "string" then
		return false, "INVALID_KEY"
	end

	if rateLimitEntries[key] then
		rateLimitEntries[key] = nil
		rateLimitKeyCount =
			math.max(
				rateLimitKeyCount - 1,
				0
			)
	end

	return true
end

function GuardUtils.cleanupRateLimitPrefix(prefix)
	if type(prefix) ~= "string"
		or prefix == "" then

		return false, "INVALID_PREFIX"
	end

	for key in pairs(rateLimitEntries) do
		if key:sub(1, #prefix) == prefix then
			rateLimitEntries[key] = nil
			rateLimitKeyCount =
				math.max(
					rateLimitKeyCount - 1,
					0
				)
		end
	end

	return true
end

-- ==========================================================================
-- MUTEX CON TOKEN DE PROPIETARIO
-- ==========================================================================

local function validateMutexTable(mutexTable)
	return type(mutexTable) == "table"
		and getmetatable(mutexTable) == nil
end

local function validateMutexTimeout(timeout)
	return isFiniteNumber(timeout)
		and timeout > 0
		and timeout <= CONFIG.MAX_MUTEX_TIMEOUT
end

local function isValidLockRecord(lock)
	return type(lock) == "table"
		and type(lock.Token) == "string"
		and lock.Token ~= ""
		and isFiniteNumber(lock.LockedAt)
		and isFiniteNumber(lock.ExpiresAt)
		and lock.ExpiresAt >= lock.LockedAt
end

local function getRegisteredTimeout(
	mutexTable
)
	local registrationId =
		mutexRegistrationIdsByTable[mutexTable]

	if not registrationId then
		return nil
	end

	local registration =
		mutexRegistrations[registrationId]

	if not registration then
		mutexRegistrationIdsByTable[mutexTable] = nil

		return nil
	end

	return registration.Timeout
end

local function resolveMutexTimeout(
	mutexTable,
	timeoutOverride
)
	if timeoutOverride ~= nil then
		if not validateMutexTimeout(
			timeoutOverride
			) then

			return nil,
				"INVALID_TIMEOUT"
		end

		return timeoutOverride
	end

	return getRegisteredTimeout(mutexTable)
		or CONFIG.DEFAULT_MUTEX_TIMEOUT
end

function GuardUtils.registerMutexTable(
	mutexTable,
	timeout
)
	ensureStarted()

	if not validateMutexTable(mutexTable) then
		return nil, "INVALID_MUTEX_TABLE"
	end

	local resolvedTimeout =
		timeout
		or CONFIG.DEFAULT_MUTEX_TIMEOUT

	if not validateMutexTimeout(
		resolvedTimeout
		) then

		return nil, "INVALID_TIMEOUT"
	end

	local existingId =
		mutexRegistrationIdsByTable[mutexTable]

	if existingId
		and mutexRegistrations[existingId] then

		mutexRegistrations[existingId].Timeout = resolvedTimeout

		return existingId
	end

	local registrationId =
		HttpService:GenerateGUID(false)

	mutexRegistrations[registrationId] = {
		MutexRef =
			createWeakValueReference(
				mutexTable
			),

		Timeout = resolvedTimeout,
	}

	mutexRegistrationIdsByTable[mutexTable] = registrationId

	return registrationId
end

-- identifier puede ser:
--   - registrationId;
--   - la propia tabla mutex.
function GuardUtils.unregisterMutexTable(
	identifier
)
	local registrationId

	if type(identifier) == "string" then
		registrationId = identifier
	elseif type(identifier) == "table" then
		registrationId =
			mutexRegistrationIdsByTable[identifier]
	else
		return false,
			"INVALID_IDENTIFIER"
	end

	if not registrationId then
		return false, "NOT_REGISTERED"
	end

	local registration =
		mutexRegistrations[registrationId]

	if registration then
		local mutexTable =
			registration.MutexRef.Value

		if mutexTable then
			mutexRegistrationIdsByTable[mutexTable] = nil
		end
	end

	mutexRegistrations[registrationId] = nil

	return true
end

-- Retorna:
--   token
-- o:
--   nil, errorCode
function GuardUtils.acquireMutex(
	mutexTable,
	key,
	timeout
)
	ensureStarted()

	if not validateMutexTable(mutexTable) then
		return nil, "INVALID_MUTEX_TABLE"
	end

	if not isValidMutexKey(key) then
		return nil, "INVALID_KEY"
	end

	-- Toda tabla usada por acquireMutex queda registrada
	-- automáticamente. Así el watchdog no depende de que el llamador
	-- recuerde ejecutar registerMutexTable().
	if not mutexRegistrationIdsByTable[
		mutexTable
		] then
		local registrationId,
			registrationError =
			GuardUtils.registerMutexTable(
				mutexTable,
				timeout
				or CONFIG.DEFAULT_MUTEX_TIMEOUT
			)

		if not registrationId then
			return nil, registrationError
		end
	end

	local resolvedTimeout,
		timeoutError =
		resolveMutexTimeout(
			mutexTable,
			timeout
		)

	if not resolvedTimeout then
		return nil, timeoutError
	end

	local now = os.clock()
	local existingLock =
		mutexTable[key]

	if existingLock ~= nil then
		if not isValidLockRecord(
			existingLock
			) then

			warn(
				"[GuardUtils] Se eliminó un mutex corrupto para la clave:",
				key
			)

			mutexTable[key] = nil
		elseif now < existingLock.ExpiresAt then
			return nil, "LOCKED"
		else
			-- Expiró. Se elimina de forma perezosa sin esperar al watchdog.
			if mutexTable[key]
				== existingLock then

				mutexTable[key] = nil
			end
		end
	end

	local token =
		HttpService:GenerateGUID(false)

	mutexTable[key] = {
		Token = token,
		LockedAt = now,
		ExpiresAt =
			now + resolvedTimeout,
	}

	return token
end

function GuardUtils.releaseMutex(
	mutexTable,
	key,
	token
)
	if not validateMutexTable(mutexTable) then
		return false, "INVALID_MUTEX_TABLE"
	end

	if not isValidMutexKey(key) then
		return false, "INVALID_KEY"
	end

	if type(token) ~= "string"
		or token == "" then

		return false, "INVALID_TOKEN"
	end

	local lock = mutexTable[key]

	if lock == nil then
		return false, "NOT_LOCKED"
	end

	if not isValidLockRecord(lock) then
		return false, "CORRUPT_LOCK"
	end

	if lock.Token ~= token then
		return false, "NOT_OWNER"
	end

	-- La comparación vuelve a hacerse antes de borrar.
	-- Impide eliminar un lock reemplazado.
	if mutexTable[key] ~= lock then
		return false, "LOCK_CHANGED"
	end

	mutexTable[key] = nil
	return true
end

function GuardUtils.renewMutex(
	mutexTable,
	key,
	token,
	timeout
)
	if not validateMutexTable(mutexTable) then
		return false, "INVALID_MUTEX_TABLE"
	end

	if not isValidMutexKey(key) then
		return false, "INVALID_KEY"
	end

	if type(token) ~= "string"
		or token == "" then

		return false, "INVALID_TOKEN"
	end

	local resolvedTimeout,
		timeoutError =
		resolveMutexTimeout(
			mutexTable,
			timeout
		)

	if not resolvedTimeout then
		return false, timeoutError
	end

	local lock = mutexTable[key]

	if not isValidLockRecord(lock) then
		return false,
			lock == nil
			and "NOT_LOCKED"
			or "CORRUPT_LOCK"
	end

	if lock.Token ~= token then
		return false, "NOT_OWNER"
	end

	local now = os.clock()

	lock.LockedAt = now
	lock.ExpiresAt =
		now + resolvedTimeout

	return true
end

function GuardUtils.isMutexLocked(
	mutexTable,
	key
)
	if not validateMutexTable(mutexTable)
		or not isValidMutexKey(key) then

		return false
	end

	local lock = mutexTable[key]

	if not isValidLockRecord(lock) then
		return false
	end

	return os.clock()
		< lock.ExpiresAt
end

-- Ejecuta una función bajo mutex y siempre intenta liberar.
--
-- Retorna:
--   true, ...resultadosDelCallback
-- o:
--   false, errorCode, detalle?
function GuardUtils.withMutex(
	mutexTable,
	key,
	callback,
	timeout
)
	if type(callback) ~= "function" then
		return false, "INVALID_CALLBACK"
	end

	local token, acquireError =
		GuardUtils.acquireMutex(
			mutexTable,
			key,
			timeout
		)

	if not token then
		return false, acquireError
	end

	local packedResults

	local succeeded, callbackError =
		xpcall(
			function()
				packedResults = table.pack(callback(token))
			end,
			debug.traceback
		)

	local released, releaseError =
		GuardUtils.releaseMutex(
			mutexTable,
			key,
			token
		)

	if not succeeded then
		return false,
			"CALLBACK_ERROR",
			callbackError
	end

	if not released then
		return false,
			"LOCK_OWNERSHIP_LOST",
			releaseError
	end

	return true,
		table.unpack(
			packedResults,
			1,
			packedResults.n
		)
end

-- ==========================================================================
-- WATCHDOG Y LIMPIEZA
-- ==========================================================================

local function cleanupRateLimits(now)
	for key, entry in pairs(
		rateLimitEntries
		) do
		local window =
			entry.WindowSeconds
			or CONFIG.DEFAULT_RATE_LIMIT_WINDOW

		cleanupRateEntry(
			entry,
			now,
			window
		)

		if getActiveRateCount(entry) <= 0
			and now - entry.LastSeen
			>= CONFIG.RATE_LIMIT_KEY_TTL then

			rateLimitEntries[key] = nil
			rateLimitKeyCount =
				math.max(
					rateLimitKeyCount - 1,
					0
				)
		end
	end
end

local function cleanupMutexRegistration(
	registrationId,
	registration,
	now
)
	local mutexTable =
		registration.MutexRef.Value

	if not mutexTable then
		mutexRegistrations[registrationId] = nil

		return
	end

	if not validateMutexTable(mutexTable) then
		mutexRegistrations[registrationId] = nil

		mutexRegistrationIdsByTable[mutexTable] = nil

		return
	end

	for key, lock in pairs(mutexTable) do
		if not isValidMutexKey(key) then
			warn(
				"[GuardUtils] Watchdog eliminó una clave de mutex inválida."
			)

			mutexTable[key] = nil
		elseif not isValidLockRecord(lock) then
			warn(
				"[GuardUtils] Watchdog eliminó un mutex corrupto para la clave:",
				key
			)

			mutexTable[key] = nil
		elseif now >= lock.ExpiresAt then
			-- Borra únicamente si sigue siendo exactamente
			-- el mismo registro observado.
			if mutexTable[key] == lock then
				warn(
					"[GuardUtils] Watchdog liberó un mutex vencido para la clave:",
					key
				)

				mutexTable[key] = nil
			end
		end
	end
end

-- Puede llamarse manualmente en pruebas.
function GuardUtils.runMaintenance()
	local now = os.clock()

	local rateSucceeded,
		rateError =
		xpcall(
			function()
				cleanupRateLimits(now)
			end,
			debug.traceback
		)

	if not rateSucceeded then
		warn(
			"[GuardUtils] Error limpiando rate limits:",
			rateError
		)
	end

	for registrationId, registration in pairs(
		mutexRegistrations
		) do
		local succeeded, maintenanceError =
			xpcall(
				function()
					cleanupMutexRegistration(
						registrationId,
						registration,
						now
					)
				end,
				debug.traceback
			)

		if not succeeded then
			warn(
				"[GuardUtils] Error limpiando registro de mutex:",
				registrationId,
				maintenanceError
			)
		end
	end

	return rateSucceeded
end

function GuardUtils.Start()
	if running then
		return true
	end

	running = true
	watchdogGeneration += 1

	local generation =
		watchdogGeneration

	task.spawn(function()
		while running
			and watchdogGeneration
			== generation do

			task.wait(
				CONFIG.WATCHDOG_INTERVAL
			)

			if not running
				or watchdogGeneration
				~= generation then

				break
			end

			GuardUtils.runMaintenance()
		end
	end)

	return true
end

-- clearState:
--   nil / true -> limpia estado interno y locks registrados.
--   false      -> detiene el watchdog pero conserva el estado.
function GuardUtils.Stop(clearState)
	if not running
		and clearState == false then

		return true
	end

	running = false
	watchdogGeneration += 1

	if clearState == false then
		return true
	end

	table.clear(rateLimitEntries)
	rateLimitKeyCount = 0

	for registrationId, registration in pairs(
		mutexRegistrations
		) do
		local mutexTable =
			registration.MutexRef.Value

		if mutexTable then
			table.clear(mutexTable)
			mutexRegistrationIdsByTable[mutexTable] = nil
		end

		mutexRegistrations[registrationId] = nil
	end

	return true
end

GuardUtils.Destroy =
	GuardUtils.Stop

function GuardUtils.GetStats()
	local registrationCount = 0
	local activeMutexCount = 0

	for _, registration in pairs(
		mutexRegistrations
		) do
		registrationCount += 1

		local mutexTable =
			registration.MutexRef.Value

		if mutexTable then
			for _ in pairs(mutexTable) do
				activeMutexCount += 1
			end
		end
	end

	return {
		Running = running,
		RateLimitKeys = rateLimitKeyCount,
		MutexRegistrations = registrationCount,
		ActiveMutexes = activeMutexCount,
	}
end

-- ==========================================================================
-- UTILIDADES ADICIONALES
-- ==========================================================================

-- Preserva correctamente:
--   - referencias compartidas;
--   - ciclos.
--
-- No copia metatables.
function GuardUtils.deepCopy(original)
	if type(original) ~= "table" then return original end
	local root = {}
	local seen, pending = {[original] = root}, {original}
	local cursor, edges = 1, 0
	local function intern(value)
		if type(value) ~= "table" then return value end
		if seen[value] then return seen[value] end
		if #pending >= CONFIG.HARD_MAX_NODES then return nil, "COPY_TABLE_LIMIT" end
		local copy = {}
		seen[value] = copy
		table.insert(pending, value)
		return copy
	end
	while cursor <= #pending do
		local source = pending[cursor]
		local target = seen[source]
		cursor += 1
		for key, value in next, source do
			edges += 1
			if edges > CONFIG.HARD_MAX_NODES then return nil, "COPY_EDGE_LIMIT" end
			local copyKey, keyError = intern(key)
			if keyError then return nil, keyError end
			local copyValue, valueError = intern(value)
			if valueError then return nil, valueError end
			target[copyKey] = copyValue
		end
	end
	return root
end

function GuardUtils.generarId(prefijo)
	local prefix =
		type(prefijo) == "string"
		and prefijo
		or "id"

	prefix =
		prefix:gsub(
			"[^%w_%-]",
			"_"
		)

	if prefix == "" then
		prefix = "id"
	end

	if #prefix > 40 then
		prefix =
			prefix:sub(1, 40)
	end

	return prefix
		.. "_"
		.. HttpService:GenerateGUID(false)
end

return GuardUtils
