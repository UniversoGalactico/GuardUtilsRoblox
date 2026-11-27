--!strict
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

local GuardUtils = { VERSION = "3.0.0-rc.8" }

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
	MAX_RATE_REQUESTS = 1000,
	MAX_RATE_WINDOW = 3600,
	MAX_RATE_TIMESTAMPS = 100000,
	RATE_LIMIT_KEY_TTL = 120,
	MAX_RATE_LIMIT_KEY_LENGTH = 200,

	MAX_SAFE_INTEGER = 2 ^ 50,

	WATCHDOG_INTERVAL = 1,
	DEFAULT_MUTEX_TIMEOUT = 30,
	MAX_MUTEX_TIMEOUT = 3600,
	MAX_MUTEX_REGISTRATIONS = 1024,
	MAX_MUTEX_KEYS_PER_REGISTRATION = 1024,
	MAX_MUTEX_RECORDS = 32768,
	MAX_MUTEX_KEY_BYTES = 200,
})

type RateEntry = {
	Timestamps: {number}, Head: number, LastSeen: number,
	WindowSeconds: number, Limit: number,
}
type Namespace = {[any]: any}
type Lease = {Token: string, StartedAt: number, Duration: number}
type Registration = {
	MutexRef: {Value: Namespace?},
	Timeout: number,
	Locks: {[any]: Lease?},
	Count: number,
}
type ValidationPolicy = {
	read MaxKeysPerTable: number, read MaxTotalNodes: number, read MaxDepth: number,
	read MaxStringLength: number, read MaxTotalBytes: number,
	read RejectMetatables: boolean, read RequireUtf8: boolean, read RejectNullBytes: boolean,
	read RequireArrayOrDictionary: boolean, read RequireContiguousArrays: boolean,
}
type ValidationState = {
	TotalNodes: number, TotalBytes: number, ActiveTables: {[any]: boolean?}, Path: {any},
}

local rateLimitEntries: {[string]: RateEntry?} = {}
local rateLimitKeyCount = 0
local rateLimitTimestampCount = 0

-- [registrationId] = { MutexRef = weakValueReference, Timeout = number, Locks = privateMap, Count = number }
local mutexRegistrations: {[string]: Registration?} = {}
local mutexRegistrationCount = 0
local mutexRecordCount = 0

-- Evita registrar dos veces la misma tabla.
-- Las claves son débiles para no impedir recolección.
local mutexRegistrationIdsByTable: {[any]: string?} = setmetatable(
	{},
	{
		__mode = "k",
	}
)

local running = false
local watchdogGeneration = 0
local watchdogThread: thread? = nil
local startWatchdog: () -> boolean = function(): boolean return false end
local lastClock = 0

-- ==========================================================================
-- HELPERS GENERALES
-- ==========================================================================

local function isFiniteNumber(value: any): boolean
	return type(value) == "number"
		and value == value
		and value > -math.huge
		and value < math.huge
end

-- os.clock is trusted but a faulty/regressing clock must never move expiry backwards.
local function readClock(): number
	local now = os.clock()
	if isFiniteNumber(now) and now >= lastClock then lastClock = now end
	return lastClock
end

-- Exact comparison of elapsed time for finite nonnegative binary64 timestamps.
-- FastTwoSum: because now >= startedAt >= 0, the rounding residual of
-- now - startedAt is (now - elapsed) - startedAt. Only equality with the
-- interval can be ambiguous after rounding. Do not form now + duration.
local function elapsedAtLeast(now: number, startedAt: number, interval: number): boolean
	if now < startedAt then return false end
	local elapsed = now - startedAt
	if elapsed ~= interval then return elapsed > interval end
	return (now - elapsed) - startedAt >= 0
end

local function leaseExpired(lock: Lease, now: number): boolean
	return elapsedAtLeast(now, lock.StartedAt, lock.Duration)
end

local function isPositiveInteger(value: any): boolean
	return isFiniteNumber(value)
		and value >= 1
		and value % 1 == 0
end

local function isValidMutexKey(key: any): boolean
	local keyType = type(key)

	if keyType == "string" then
		return key ~= "" and #key <= CONFIG.MAX_MUTEX_KEY_BYTES
	end

	if keyType == "number" then
		return isFiniteNumber(key)
	end

	return false
end

local function createWeakValueReference(value: Namespace): {Value: Namespace?}
	return setmetatable(
		{
			Value = value :: Namespace?,
		},
		{
			__mode = "v",
		}
	)
end

local function makePath(parentPath: string, key: any): string
	local kind = type(key)
	if kind == "number" then return parentPath .. "[" .. tostring(key) .. "]" end
	if kind ~= "string" then return parentPath .. "[<" .. kind .. " key>]" end
	local preview = key:sub(1, 64)
	if #key > 64 then preview = preview .. "..." end
	if preview:match("^[%a_][%w_]*$") then return parentPath .. "." .. preview end
	return parentPath .. "[" .. string.format("%q", preview) .. "]"
end

-- Inputs to defensive boundary functions intentionally accept any runtime value.

-- Shared immutable default policies avoid rebuilding option maps on every request.
local function defaultValidationPolicy(strict: boolean): ValidationPolicy
	return table.freeze({
		MaxKeysPerTable = CONFIG.MAX_KEYS_PER_TABLE, MaxTotalNodes = CONFIG.MAX_TOTAL_NODES,
		MaxDepth = CONFIG.MAX_DEPTH, MaxStringLength = CONFIG.MAX_STRING_LENGTH,
		MaxTotalBytes = CONFIG.MAX_TOTAL_BYTES, RejectMetatables = true,
		RequireUtf8 = true, RejectNullBytes = true,
		RequireArrayOrDictionary = strict, RequireContiguousArrays = strict,
	})
end
local GENERIC_DEFAULTS = defaultValidationPolicy(false)
local STRICT_DEFAULTS = defaultValidationPolicy(true)
local VALIDATION_OPTION_KEYS: {[string]: boolean} = {
	MaxKeysPerTable = true, MaxTotalNodes = true, MaxDepth = true,
	MaxStringLength = true, MaxTotalBytes = true, RejectMetatables = true,
	RequireUtf8 = true, RejectNullBytes = true, RequireArrayOrDictionary = true,
	RequireContiguousArrays = true,
}
table.freeze(VALIDATION_OPTION_KEYS)

local function hasOnlyOptions(options: {[any]: any}, allowed: {[string]: boolean}): boolean
	-- At most the number of recognized keys plus one iteration. Never execute
	-- caller metamethods, even for malformed option keys.
	for key in next, options do
		if type(key) ~= "string" or not allowed[key] then return false end
	end
	return true
end

local function normalizeValidationOptions(options: any, strict: boolean): (ValidationPolicy?, string?)
	if options == nil then return (if strict then STRICT_DEFAULTS else GENERIC_DEFAULTS), nil end
	if type(options) ~= "table" or getmetatable(options) ~= nil then
		return nil, "INVALID_VALIDATION_OPTIONS"
	end
	if not hasOnlyOptions(options, VALIDATION_OPTION_KEYS) then return nil, "UNKNOWN_VALIDATION_OPTION" end
	local function readBound(name: string, default: number, ceiling: number): number?
		local value: any = rawget(options, name)
		if value == nil then return default end
		if not isPositiveInteger(value) or value > ceiling then return nil end
		return value
	end
	local function readFlag(name: string, default: boolean): boolean?
		local value: any = rawget(options, name)
		if value == nil then value = default end
		if type(value) ~= "boolean" then return nil end
		return strict or value
	end
	local maxKeys = readBound("MaxKeysPerTable", CONFIG.MAX_KEYS_PER_TABLE, CONFIG.HARD_MAX_KEYS)
	local maxNodes = readBound("MaxTotalNodes", CONFIG.MAX_TOTAL_NODES, CONFIG.HARD_MAX_NODES)
	local maxDepth = readBound("MaxDepth", CONFIG.MAX_DEPTH, CONFIG.HARD_MAX_DEPTH)
	local maxString = readBound("MaxStringLength", CONFIG.MAX_STRING_LENGTH, CONFIG.HARD_MAX_STRING_BYTES)
	local maxBytes = readBound("MaxTotalBytes", CONFIG.MAX_TOTAL_BYTES, CONFIG.HARD_MAX_TOTAL_BYTES)
	local metatables = readFlag("RejectMetatables", true)
	local utf = readFlag("RequireUtf8", true)
	local nulls = readFlag("RejectNullBytes", true)
	local shape = readFlag("RequireArrayOrDictionary", false)
	local contiguous = readFlag("RequireContiguousArrays", false)
	if maxKeys == nil or maxNodes == nil or maxDepth == nil or maxString == nil or maxBytes == nil
		or metatables == nil or utf == nil or nulls == nil or shape == nil or contiguous == nil then
		return nil, "INVALID_VALIDATION_OPTIONS"
	end
	return {
		MaxKeysPerTable = maxKeys, MaxTotalNodes = maxNodes, MaxDepth = maxDepth,
		MaxStringLength = maxString, MaxTotalBytes = maxBytes,
		RejectMetatables = metatables, RequireUtf8 = utf, RejectNullBytes = nulls,
		RequireArrayOrDictionary = shape, RequireContiguousArrays = contiguous,
	}, nil
end

local function validateStringValue(value: string, options: ValidationPolicy, state: ValidationState): (boolean, string?)
	if #value > CONFIG.HARD_MAX_STRING_BYTES then return false, "STRING_TOO_LONG" end
	state.TotalBytes += #value
	if state.TotalBytes > options.MaxTotalBytes then return false, "MAX_TOTAL_BYTES_EXCEEDED" end
	if options.RejectNullBytes and value:find("\0", 1, true) then return false, "NULL_BYTE" end
	local length = #value
	if options.RequireUtf8 then
		local characters = utf8.len(value)
		if characters == nil then return false, "INVALID_UTF8" end
		length = characters
	end
	if length > options.MaxStringLength then return false, "STRING_TOO_LONG" end
	return true, nil
end

local function validateTableKey(key: any, options: ValidationPolicy, state: ValidationState)
	local kind = type(key)
	if kind == "string" then
		local ok, code = validateStringValue(key, options, state)
		if not ok then return false, "INVALID_KEY_" .. (code or "INVALID_STRING") end
		return true, "STRING"
	elseif kind == "number" then
		if not isPositiveInteger(key) or key > CONFIG.MAX_SAFE_INTEGER then return false, "INVALID_NUMERIC_KEY" end
		return true, "NUMBER"
	end
	return false, "INVALID_KEY_TYPE"
end

-- Track keys, not concatenated paths. Render a bounded diagnostic only on failure.
local function validationError(state: ValidationState, code: string, extraKey: any?)
	local path = "$"
	for _, key in ipairs(state.Path) do path = makePath(path, key) end
	if extraKey ~= nil then path = makePath(path, extraKey) end
	return false, code, path
end

local function validateValue(value: any, options: ValidationPolicy, state: ValidationState, depth: number): (boolean, string?, string?)
	state.TotalNodes += 1
	if state.TotalNodes > options.MaxTotalNodes then return validationError(state, "MAX_TOTAL_NODES_EXCEEDED") end

	local kind = type(value)
	if kind == "boolean" then return true, nil, nil end
	if kind == "number" then
		if not isFiniteNumber(value) then return validationError(state, "INVALID_NUMBER") end
		if math.abs(value) > CONFIG.MAX_SAFE_INTEGER then return validationError(state, "NUMBER_OUT_OF_SAFE_RANGE") end
		return true, nil, nil
	end
	if kind == "string" then
		local ok, code = validateStringValue(value, options, state)
		if not ok then return validationError(state, code or "INVALID_STRING") end
		return true, nil, nil
	end
	if kind ~= "table" then return validationError(state, "UNSUPPORTED_TYPE_" .. kind) end
	if depth > options.MaxDepth then return validationError(state, "MAX_DEPTH_EXCEEDED") end
	if options.RejectMetatables and getmetatable(value) ~= nil then return validationError(state, "METATABLE_NOT_ALLOWED") end
	if state.ActiveTables[value] then return validationError(state, "CYCLIC_REFERENCE") end
	state.ActiveTables[value] = true

	local keys, strings, numbers, maxIndex = 0, 0, 0, 0
	for key, child in next, value do
		keys += 1
		if keys > options.MaxKeysPerTable then return validationError(state, "MAX_KEYS_PER_TABLE_EXCEEDED") end
		local validKey, keyKind = validateTableKey(key, options, state)
		if not validKey then return validationError(state, keyKind or "INVALID_KEY_TYPE", key) end
		if keyKind == "STRING" then
			strings += 1
		else
			numbers += 1
			maxIndex = math.max(maxIndex, key)
		end
		state.Path[depth] = key
		local ok, code, path = validateValue(child, options, state, depth + 1)
		if not ok then return false, code, path end
		state.Path[depth] = nil
	end

	if options.RequireArrayOrDictionary and strings > 0 and numbers > 0 then
		return validationError(state, "MIXED_TABLE_KEYS")
	end
	if options.RequireContiguousArrays and maxIndex ~= numbers then
		return validationError(state, "NON_CONTIGUOUS_ARRAY")
	end
	state.ActiveTables[value] = nil
	return true, nil, nil
end

local function validateRoot(value: any, options: any?, strict: boolean): (boolean, string?, string?)
	if value == nil then return false, "NIL_ROOT", "$" end
	local policy, code = normalizeValidationOptions(options, strict)
	if not policy then return false, code, "$" end
	local state: ValidationState = {TotalNodes = 0, TotalBytes = 0, ActiveTables = {}, Path = {}}
	return validateValue(value, policy, state, 1)
end

function GuardUtils.validateData(value: any, options: any?)
	return validateRoot(value, options, false)
end

function GuardUtils.isValidData(value: any, maxKeys: any?): boolean
	if maxKeys == nil then return GuardUtils.validateData(value) == true end
	if type(maxKeys) == "number" then return GuardUtils.validateData(value, {MaxKeysPerTable = maxKeys}) == true end
	if type(maxKeys) == "table" then return GuardUtils.validateData(value, maxKeys) == true end
	return false
end

function GuardUtils.isDataStoreSafe(value: any, options: any?)
	return validateRoot(value, options, true)
end

function GuardUtils.jugadorValido(player: any): boolean
	local kind = typeof(player)
	return kind == "Instance"
		and player:IsA("Player")
		and player.Parent == Players
end

function GuardUtils.datosCargados(player: any, isLoadedFunc: any): (boolean, string?)
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

	if not GuardUtils.jugadorValido(player) then return false, "INVALID_PLAYER" end
	return result == true, nil
end

-- ==========================================================================
-- SANITIZACIÓN
-- ==========================================================================

-- Retorna:
--   cleanedString
-- o:
--   nil, errorCode
function GuardUtils.sanitizeString(value: any, maxLength: any?): (string?, string?)
	if type(value) ~= "string" then
		return nil, "INVALID_TYPE"
	end

	local limit = maxLength
	if limit == nil then limit = 1000 end

	if not isPositiveInteger(limit) or limit > CONFIG.HARD_MAX_STRING_BYTES then
		return nil, "INVALID_MAX_LENGTH"
	end
	if #value > CONFIG.HARD_MAX_STRING_BYTES then return nil, "STRING_TOO_LONG" end
	if not utf8.len(value) then return nil, "INVALID_UTF8" end

	-- Quita caracteres de control, incluido el byte nulo.
	local cleaned =
		string.gsub(value :: string, "%c", "")

	-- Quita espacios exteriores después de limpiar.
	cleaned =
		cleaned:match("^%s*(.-)%s*$")
		or ""

	if cleaned == "" then
		return nil, "EMPTY_STRING"
	end

	local characterCount = utf8.len(cleaned)
	if not characterCount then
		return nil, "INVALID_UTF8"
	end

	if characterCount > limit then
		return nil, "STRING_TOO_LONG"
	end

	return cleaned, nil
end

-- options:
--   Integer = true | false
--   Clamp = true | false
--
-- Por seguridad, Clamp es false de forma predeterminada.
-- Un valor fuera del rango se rechaza en vez de corregirse silenciosamente.
local NUMBER_OPTION_KEYS: {[string]: boolean} = {Integer = true, Clamp = true}
table.freeze(NUMBER_OPTION_KEYS)

function GuardUtils.sanitizeNumber(value: any, minimum: any?, maximum: any?, options: any?): (number?, string?)
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
	if not hasOnlyOptions(options, NUMBER_OPTION_KEYS) then return nil, "UNKNOWN_NUMBER_OPTION" end
	if (options.Integer ~= nil and type(options.Integer) ~= "boolean")
		or (options.Clamp ~= nil and type(options.Clamp) ~= "boolean") then return nil, "INVALID_OPTIONS" end
	local integerMode =
		options.Integer ~= false

	local clampMode =
		options.Clamp == true

	-- Reject raw out-of-range values before normalization. Flooring must not
	-- turn an invalid input into an accepted boundary value.
	if not clampMode and (value < minValue or value > maxValue) then
		return nil, "OUT_OF_RANGE"
	end
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

	return sanitized, nil
end

-- ==========================================================================
-- RATE LIMITING
-- ==========================================================================

local function validateRateLimitKey(key: any): boolean
	return type(key) == "string"
		and key ~= ""
		and #key <= CONFIG.MAX_RATE_LIMIT_KEY_LENGTH
end

local function validateRateLimitConfig(limit: any, window: any): boolean
	return isPositiveInteger(limit) and limit <= CONFIG.MAX_RATE_REQUESTS
		and isFiniteNumber(window) and window > 0 and window <= CONFIG.MAX_RATE_WINDOW
end
local function getActiveRateCount(entry: RateEntry): number
	return #entry.Timestamps - entry.Head + 1
end
local function cleanupRateEntry(entry: RateEntry, now: number, window: number)
	local stamps, head = entry.Timestamps, entry.Head
	if #stamps == 0 then return end
	while stamps[head] and elapsedAtLeast(now, stamps[head], window) do head += 1 end
	rateLimitTimestampCount -= head - entry.Head
	entry.Head = head
	if head > #stamps then
		entry.Timestamps, entry.Head = {}, 1
	elseif head > 64 then
		local kept: {number} = {}
		for i = head, #stamps do table.insert(kept, stamps[i]) end
		entry.Timestamps, entry.Head = kept, 1
	end
end
local function removeRateEntry(key: string)
	local entry = rateLimitEntries[key]
	if entry then
		rateLimitTimestampCount -= getActiveRateCount(entry)
		rateLimitKeyCount -= 1
		rateLimitEntries[key] = nil
	end
end

local function watchdogHealthy(): boolean
	local handle = watchdogThread
	return running and handle ~= nil and coroutine.status(handle) ~= "dead"
end

local function ensureStarted(): boolean
	if watchdogHealthy() then return true end
	return startWatchdog()
end

-- Retorna:
--   limited, errorCode?
--
-- Ante configuración inválida falla de forma cerrada:
-- devuelve true para no desactivar accidentalmente la protección.
function GuardUtils.isRateLimited(key: any, limit: any?, window: any?): (boolean, string?)
	if not validateRateLimitKey(key) then return true, "INVALID_KEY" end
	if limit == nil then limit = CONFIG.MAX_REQUESTS_PER_WINDOW end
	if window == nil then window = CONFIG.DEFAULT_RATE_LIMIT_WINDOW end
	if not validateRateLimitConfig(limit, window) then return true, "INVALID_RATE_LIMIT_CONFIG" end
	if not ensureStarted() then return true, "WATCHDOG_UNAVAILABLE" end
	local now = readClock()
	local entry = rateLimitEntries[key]
	if entry then
		if entry.WindowSeconds ~= window or entry.Limit ~= limit then return true, "RATE_LIMIT_POLICY_MISMATCH" end
		cleanupRateEntry(entry, now, window)
		entry.LastSeen = now
		if getActiveRateCount(entry) >= limit then return true, nil end
	elseif rateLimitKeyCount >= CONFIG.MAX_RATE_LIMIT_KEYS then
		return true, "RATE_LIMIT_CAPACITY_REACHED"
	end
	if rateLimitTimestampCount >= CONFIG.MAX_RATE_TIMESTAMPS then return true, "RATE_LIMIT_TIMESTAMP_CAPACITY_REACHED" end
	if not entry then
		local created: RateEntry = {Timestamps = {}, Head = 1, LastSeen = now, WindowSeconds = window, Limit = limit}
		rateLimitEntries[key] = created
		entry = created
		rateLimitKeyCount += 1
	end
	if not entry then return true, "RATE_LIMIT_STATE_LOST" end
	table.insert(entry.Timestamps, now)
	rateLimitTimestampCount += 1
	return false, nil
end
function GuardUtils.cleanupRateLimit(key: any): (boolean, string?)
	if not validateRateLimitKey(key) then return false, "INVALID_KEY" end
	removeRateEntry(key)
	return true, nil
end
function GuardUtils.cleanupRateLimitPrefix(prefix: any): (boolean, string?)
	if not validateRateLimitKey(prefix) then return false, "INVALID_PREFIX" end
	for key in pairs(rateLimitEntries) do
		if key:sub(1, #prefix) == prefix then removeRateEntry(key) end
	end
	return true, nil
end

-- ==========================================================================
-- MUTEX CON TOKEN DE PROPIETARIO
-- ==========================================================================

-- The caller's table is an identity only. Authoritative records never escape this module.
local function validateMutexTable(namespace: any): boolean
	return type(namespace) == "table"
end

local function validateMutexTimeout(timeout: any): boolean
	return isFiniteNumber(timeout) and timeout > 0 and timeout <= CONFIG.MAX_MUTEX_TIMEOUT
end

local function getRegistration(namespace: any): (Registration?, string?)
	local id = mutexRegistrationIdsByTable[namespace]
	local registration = if id then mutexRegistrations[id] else nil
	if id and not registration then mutexRegistrationIdsByTable[namespace] = nil end
	return registration, id
end

local function dropLock(registration: Registration, key: any)
	if registration.Locks[key] then
		registration.Locks[key] = nil
		registration.Count -= 1
		mutexRecordCount -= 1
	end
end

local function pruneExpired(registration: Registration, now: number)
	for key, lock in pairs(registration.Locks) do
		if lock and leaseExpired(lock, now) then dropLock(registration, key) end
	end
end

local function dropRegistration(id: string, registration: Registration)
	local namespace = registration.MutexRef.Value
	if namespace and mutexRegistrationIdsByTable[namespace] == id then
		mutexRegistrationIdsByTable[namespace] = nil
	end
	mutexRecordCount -= registration.Count
	mutexRegistrationCount -= 1
	mutexRegistrations[id] = nil
end

function GuardUtils.registerMutexTable(namespace: any, timeout: any?): (string?, string?)
	if not validateMutexTable(namespace) then return nil, "INVALID_MUTEX_TABLE" end
	if timeout == nil then timeout = CONFIG.DEFAULT_MUTEX_TIMEOUT end
	if not validateMutexTimeout(timeout) then return nil, "INVALID_TIMEOUT" end
	if not ensureStarted() then return nil, "WATCHDOG_UNAVAILABLE" end
	local registration, id = getRegistration(namespace)
	if registration then
		registration.Timeout = timeout
		return id, nil
	end
	if mutexRegistrationCount >= CONFIG.MAX_MUTEX_REGISTRATIONS then
		for oldId, old in pairs(mutexRegistrations) do
			if old and old.MutexRef.Value == nil then dropRegistration(oldId, old) end
		end
		if mutexRegistrationCount >= CONFIG.MAX_MUTEX_REGISTRATIONS then
			return nil, "MUTEX_REGISTRATION_CAPACITY_REACHED"
		end
	end
	local newId: string = HttpService:GenerateGUID(false)
	mutexRegistrations[newId] = {
		MutexRef = createWeakValueReference(namespace),
		Timeout = timeout,
		Locks = {},
		Count = 0,
	}
	mutexRegistrationIdsByTable[namespace] = newId
	mutexRegistrationCount += 1
	return newId, nil
end

function GuardUtils.unregisterMutexTable(identifier: any): (boolean, string?)
	local id: string? = nil
	if type(identifier) == "string" then
		id = identifier
	elseif type(identifier) == "table" then
		id = mutexRegistrationIdsByTable[identifier]
	else
		return false, "INVALID_IDENTIFIER"
	end
	if id == nil then return false, "NOT_REGISTERED" end
	local registration = mutexRegistrations[id]
	if not registration then return false, "NOT_REGISTERED" end
	pruneExpired(registration, readClock())
	if registration.Count > 0 then return false, "ACTIVE_LEASES" end
	dropRegistration(id, registration)
	return true, nil
end

-- A timeout override belongs only to this acquisition/renewal, never to the namespace policy.
function GuardUtils.acquireMutex(namespace: any, key: any, timeout: any?): (string?, string?)
	if not validateMutexTable(namespace) then return nil, "INVALID_MUTEX_TABLE" end
	if not isValidMutexKey(key) then return nil, "INVALID_KEY" end
	if timeout ~= nil and not validateMutexTimeout(timeout) then return nil, "INVALID_TIMEOUT" end
	if not ensureStarted() then return nil, "WATCHDOG_UNAVAILABLE" end
	local registration = getRegistration(namespace)
	if not registration then
		-- Failed acquisitions must not consume namespace slots.
		if mutexRecordCount >= CONFIG.MAX_MUTEX_RECORDS then return nil, "MUTEX_RECORD_CAPACITY_REACHED" end
		local id, err = GuardUtils.registerMutexTable(namespace)
		if not id then return nil, err end
		registration = mutexRegistrations[id]
	end
	if not registration then return nil, "REGISTRATION_LOST" end
	local duration = timeout or registration.Timeout
	local now = readClock()
	local old = registration.Locks[key]
	if old then
		if not leaseExpired(old, now) then return nil, "LOCKED" end
		dropLock(registration, key)
	end
	if registration.Count >= CONFIG.MAX_MUTEX_KEYS_PER_REGISTRATION then
		pruneExpired(registration, now)
		if registration.Count >= CONFIG.MAX_MUTEX_KEYS_PER_REGISTRATION then
			return nil, "MUTEX_NAMESPACE_CAPACITY_REACHED"
		end
	end
	if mutexRecordCount >= CONFIG.MAX_MUTEX_RECORDS then return nil, "MUTEX_RECORD_CAPACITY_REACHED" end
	local token: string = HttpService:GenerateGUID(false)
	registration.Locks[key] = {Token = token, StartedAt = now, Duration = duration}
	registration.Count += 1
	mutexRecordCount += 1
	return token, nil
end

local function getOwnedLock(namespace: any, key: any, token: any): (Registration?, Lease?, string?)
	if not validateMutexTable(namespace) then return nil, nil, "INVALID_MUTEX_TABLE" end
	if not isValidMutexKey(key) then return nil, nil, "INVALID_KEY" end
	if type(token) ~= "string" or token == "" then return nil, nil, "INVALID_TOKEN" end
	local registration = getRegistration(namespace)
	if not registration then return nil, nil, "NOT_LOCKED" end
	local lock = registration.Locks[key]
	if not lock then return nil, nil, "NOT_LOCKED" end
	if lock.Token ~= token then return nil, nil, "NOT_OWNER" end
	return registration, lock, nil
end

function GuardUtils.releaseMutex(namespace: any, key: any, token: any): (boolean, string?)
	local registration, lock, err = getOwnedLock(namespace, key, token)
	if not registration or not lock then return false, err end
	local expired = leaseExpired(lock, readClock())
	dropLock(registration, key)
	if expired then return false, "LOCK_EXPIRED" end
	return true, nil
end

function GuardUtils.renewMutex(namespace: any, key: any, token: any, timeout: any?): (boolean, string?)
	if timeout ~= nil and not validateMutexTimeout(timeout) then return false, "INVALID_TIMEOUT" end
	local registration, lock, err = getOwnedLock(namespace, key, token)
	if not registration or not lock then return false, err end
	local now = readClock()
	if leaseExpired(lock, now) then
		dropLock(registration, key)
		return false, "LOCK_EXPIRED"
	end
	lock.StartedAt = now
	lock.Duration = timeout or registration.Timeout
	return true, nil
end

function GuardUtils.ownsMutex(namespace: any, key: any, token: any): boolean
	local _, lock = getOwnedLock(namespace, key, token)
	return lock ~= nil and not leaseExpired(lock, readClock())
end

function GuardUtils.isMutexLocked(namespace: any, key: any): boolean
	if not validateMutexTable(namespace) or not isValidMutexKey(key) then return false end
	local registration = getRegistration(namespace)
	local lock = if registration then registration.Locks[key] else nil
	return lock ~= nil and not leaseExpired(lock, readClock())
end

-- Synchronous only. Existing side effects cannot be undone when a callback fails.
function GuardUtils.withMutex(namespace: any, key: any, callback: any, timeout: any?): (boolean, ...any)
	if type(callback) ~= "function" then return false, "INVALID_CALLBACK" end
	local token, acquireError = GuardUtils.acquireMutex(namespace, key, timeout)
	if not token then return false, acquireError end
	local thread = coroutine.create(callback)
	local result = table.pack(coroutine.resume(thread, token)) :: { [number]: any, n: number }
	local suspended = coroutine.status(thread) == "suspended"
	if suspended then
		-- task.wait may have registered this coroutine with Roblox's scheduler.
		-- Cancel the scheduled resume first, then close any still-suspended thread.
		pcall(task.cancel, thread)
		if coroutine.status(thread) == "suspended" then pcall(coroutine.close, thread) end
	end
	local released, releaseError = GuardUtils.releaseMutex(namespace, key, token)
	if not result[1] then return false, "CALLBACK_ERROR", result[2] end
	if suspended then return false, "CALLBACK_YIELDED" end
	if not released then return false, "LOCK_OWNERSHIP_LOST", releaseError end
	return true, table.unpack(result, 2, result.n)
end

-- ==========================================================================
-- WATCHDOG Y LIMPIEZA
-- ==========================================================================

local function cleanupRateLimits(now: number)
	for key, entry in pairs(rateLimitEntries) do
		if not entry then continue end
		cleanupRateEntry(entry, now, entry.WindowSeconds)
		if getActiveRateCount(entry) <= 0 and elapsedAtLeast(now, entry.LastSeen, CONFIG.RATE_LIMIT_KEY_TTL) then
			removeRateEntry(key)
		end
	end
end

local function cleanupMutexRegistration(id: string, registration: Registration, now: number)
	-- Weak identity collection drops unreachable registrations and their accounting.
	if registration.MutexRef.Value == nil then
		dropRegistration(id, registration)
	else
		pruneExpired(registration, now)
	end
end

-- Puede llamarse manualmente en pruebas.
function GuardUtils.runMaintenance()
	local now = readClock()
	local allSucceeded, rateError = xpcall(function() cleanupRateLimits(now); return "" end, function(err: any): string return debug.traceback(tostring(err)) end)
	if not allSucceeded then warn("[GuardUtils] Rate maintenance:", rateError) end
	for registrationId, registration in pairs(mutexRegistrations) do
		if not registration then continue end
		local succeeded, err = xpcall(function()
			cleanupMutexRegistration(registrationId, registration, now)
			return ""
		end, function(problem: any): string return debug.traceback(tostring(problem)) end)
		if not succeeded then
			allSucceeded = false
			warn("[GuardUtils] Mutex maintenance:", registrationId, err)
		end
	end
	return allSucceeded
end

function GuardUtils.Start(): boolean
	if watchdogHealthy() then return true end
	watchdogThread = nil
	running = true
	watchdogGeneration += 1
	local generation = watchdogGeneration
	local ok, handle = pcall(task.spawn, function()
		while running and watchdogGeneration == generation do
			task.wait(CONFIG.WATCHDOG_INTERVAL)
			if not running or watchdogGeneration ~= generation then break end
			GuardUtils.runMaintenance()
		end
	end)
	if not ok or type(handle) ~= "thread" or coroutine.status(handle) == "dead" then
		running = false
		watchdogGeneration += 1
		warn("[GuardUtils] Watchdog start failed")
		return false
	end
	watchdogThread = handle
	return true
end
startWatchdog = GuardUtils.Start

-- clearState:
--   nil / true -> limpia estado interno sin modificar las tablas del llamador.
--   false      -> detiene el watchdog pero conserva el estado.
function GuardUtils.Stop(clearState: any?): (boolean, string?)
	if clearState ~= nil and type(clearState) ~= "boolean" then return false, "INVALID_CLEAR_STATE" end
	running = false
	watchdogGeneration += 1
	local handle = watchdogThread
	watchdogThread = nil
	if handle and coroutine.status(handle) ~= "dead" then
		local ok, err = pcall(task.cancel, handle)
		if not ok then warn("[GuardUtils] Watchdog cancellation failed:", err) end
	end
	if clearState == false then return true, nil end
	table.clear(rateLimitEntries)
	rateLimitKeyCount = 0
	rateLimitTimestampCount = 0
	-- The namespace tables belong to callers; never clear or mutate them.
	table.clear(mutexRegistrations)
	table.clear(mutexRegistrationIdsByTable)
	mutexRegistrationCount = 0
	mutexRecordCount = 0
	lastClock = 0
	return true, nil
end

GuardUtils.Destroy =
	GuardUtils.Stop

function GuardUtils.GetStats()
	local active = 0
	local now = readClock()
	for _, registration in pairs(mutexRegistrations) do
		if registration and registration.MutexRef.Value ~= nil then
			for _, lock in pairs(registration.Locks) do
				if lock and not leaseExpired(lock, now) then active += 1 end
			end
		end
	end
	return {
		Running = watchdogHealthy(),
		RateLimitKeys = rateLimitKeyCount,
		RateLimitTimestamps = rateLimitTimestampCount,
		MutexRegistrations = mutexRegistrationCount,
		MutexRecords = mutexRecordCount,
		ActiveMutexes = active,
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
function GuardUtils.deepCopy(original: any): (any, string?)
	if type(original) ~= "table" then return original, nil end
	local root = {}
	local seen: {[any]: any} = {[original] = root}
	local pending: {any} = {original}
	local cursor, edges = 1, 0
	local function intern(value: any): (any, string?)
		if type(value) ~= "table" then return value, nil end
		if seen[value] then return seen[value], nil end
		if #pending >= CONFIG.HARD_MAX_NODES then return nil, "COPY_TABLE_LIMIT" end
		local copy = {}
		seen[value] = copy
		table.insert(pending, value)
		return copy, nil
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
	return root, nil
end

function GuardUtils.generarId(prefijo: any?): string
	local prefix = if type(prefijo) == "string" then string.sub(prefijo :: string, 1, 40) else "id"
	prefix = prefix:gsub("[^%w_%-]", "_")
	if prefix == "" then prefix = "id" end
	return prefix .. "_" .. HttpService:GenerateGUID(false)
end

return table.freeze(GuardUtils)
