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

local GuardUtils = { VERSION = "3.0.0-rc.3" }

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

local rateLimitEntries = {}
local rateLimitKeyCount = 0
local rateLimitTimestampCount = 0

-- [registrationId] = { MutexRef = weakValueReference, Timeout = number, Locks = privateMap, Count = number }
local mutexRegistrations = {}
local mutexRegistrationCount = 0
local mutexRecordCount = 0

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
		return key ~= "" and #key <= CONFIG.MAX_MUTEX_KEY_BYTES
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

-- Shared immutable default policies avoid rebuilding option maps on every request.
local VALIDATION_BOUNDS = table.freeze({
	MaxKeysPerTable = {CONFIG.MAX_KEYS_PER_TABLE, CONFIG.HARD_MAX_KEYS},
	MaxTotalNodes = {CONFIG.MAX_TOTAL_NODES, CONFIG.HARD_MAX_NODES},
	MaxDepth = {CONFIG.MAX_DEPTH, CONFIG.HARD_MAX_DEPTH},
	MaxStringLength = {CONFIG.MAX_STRING_LENGTH, CONFIG.HARD_MAX_STRING_BYTES},
	MaxTotalBytes = {CONFIG.MAX_TOTAL_BYTES, CONFIG.HARD_MAX_TOTAL_BYTES},
})
local VALIDATION_FLAGS = table.freeze({
	RejectMetatables = true,
	RequireUtf8 = true,
	RejectNullBytes = true,
	RequireArrayOrDictionary = false,
	RequireContiguousArrays = false,
})

local function defaultValidationPolicy(strict)
	local policy = {}
	for name, bound in pairs(VALIDATION_BOUNDS) do policy[name] = bound[1] end
	for name, default in pairs(VALIDATION_FLAGS) do policy[name] = strict or default end
	return table.freeze(policy)
end

local GENERIC_DEFAULTS = defaultValidationPolicy(false)
local STRICT_DEFAULTS = defaultValidationPolicy(true)

local function normalizeValidationOptions(options, strict)
	if options == nil then return if strict then STRICT_DEFAULTS else GENERIC_DEFAULTS end
	if type(options) ~= "table" or getmetatable(options) ~= nil then
		return nil, "INVALID_VALIDATION_OPTIONS"
	end
	local normalized = {}
	for name, bound in pairs(VALIDATION_BOUNDS) do
		local value = rawget(options, name)
		if value == nil then value = bound[1] end
		if not isPositiveInteger(value) or value > bound[2] then return nil, "INVALID_VALIDATION_OPTIONS" end
		normalized[name] = value
	end
	for name, default in pairs(VALIDATION_FLAGS) do
		local value = rawget(options, name)
		if value == nil then value = default end
		if type(value) ~= "boolean" then return nil, "INVALID_VALIDATION_OPTIONS" end
		normalized[name] = strict or value
	end
	return normalized
end

local function validateStringValue(value, options, state)
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
	return true
end

local function validateTableKey(key, options, state)
	local kind = type(key)
	if kind == "string" then
		local ok, code = validateStringValue(key, options, state)
		if not ok then return false, "INVALID_KEY_" .. code end
		return true, "STRING"
	elseif kind == "number" then
		if not isPositiveInteger(key) or key > CONFIG.MAX_SAFE_INTEGER then return false, "INVALID_NUMERIC_KEY" end
		return true, "NUMBER"
	end
	return false, "INVALID_KEY_TYPE"
end

-- Track keys, not concatenated paths. Render a bounded diagnostic only on failure.
local function validationError(state, code, extraKey)
	local path = "$"
	for _, key in ipairs(state.Path) do path = makePath(path, key) end
	if extraKey ~= nil then path = makePath(path, extraKey) end
	return false, code, path
end

local function validateValue(value, options, state, depth)
	state.TotalNodes += 1
	if state.TotalNodes > options.MaxTotalNodes then return validationError(state, "MAX_TOTAL_NODES_EXCEEDED") end

	local kind = type(value)
	if kind == "boolean" then return true end
	if kind == "number" then
		if not isFiniteNumber(value) then return validationError(state, "INVALID_NUMBER") end
		if math.abs(value) > CONFIG.MAX_SAFE_INTEGER then return validationError(state, "NUMBER_OUT_OF_SAFE_RANGE") end
		return true
	end
	if kind == "string" then
		local ok, code = validateStringValue(value, options, state)
		if not ok then return validationError(state, code) end
		return true
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
		if not validKey then return validationError(state, keyKind, key) end
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
	return true
end

local function validateRoot(value, options, strict)
	if value == nil then return false, "NIL_ROOT", "$" end
	local policy, code = normalizeValidationOptions(options, strict)
	if not policy then return false, code, "$" end
	local state = {TotalNodes = 0, TotalBytes = 0, ActiveTables = {}, Path = {}}
	return validateValue(value, policy, state, 1)
end

function GuardUtils.validateData(value, options)
	return validateRoot(value, options, false)
end

function GuardUtils.isValidData(value, maxKeys)
	if maxKeys == nil then return GuardUtils.validateData(value) == true end
	if type(maxKeys) == "number" then return GuardUtils.validateData(value, {MaxKeysPerTable = maxKeys}) == true end
	if type(maxKeys) == "table" then return GuardUtils.validateData(value, maxKeys) == true end
	return false
end

function GuardUtils.isDataStoreSafe(value, options)
	return validateRoot(value, options, true)
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

local function validateRateLimitConfig(limit, window)
	return isPositiveInteger(limit) and limit <= CONFIG.MAX_RATE_REQUESTS
		and isFiniteNumber(window) and window > 0 and window <= CONFIG.MAX_RATE_WINDOW
end
local function getActiveRateCount(entry)
	return #entry.Timestamps - entry.Head + 1
end
local function cleanupRateEntry(entry, now, window)
	local stamps, head = entry.Timestamps, entry.Head
	while stamps[head] and now - stamps[head] >= window do head += 1 end
	rateLimitTimestampCount -= head - entry.Head
	entry.Head = head
	if head > #stamps then
		entry.Timestamps, entry.Head = {}, 1
	elseif head > 64 then
		local kept = {}
		for i = head, #stamps do table.insert(kept, stamps[i]) end
		entry.Timestamps, entry.Head = kept, 1
	end
end
local function removeRateEntry(key)
	local entry = rateLimitEntries[key]
	if entry then
		rateLimitTimestampCount -= getActiveRateCount(entry)
		rateLimitKeyCount -= 1
		rateLimitEntries[key] = nil
	end
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
function GuardUtils.isRateLimited(key, limit, window)
	if not validateRateLimitKey(key) then return true, "INVALID_KEY" end
	if limit == nil then limit = CONFIG.MAX_REQUESTS_PER_WINDOW end
	if window == nil then window = CONFIG.DEFAULT_RATE_LIMIT_WINDOW end
	if not validateRateLimitConfig(limit, window) then return true, "INVALID_RATE_LIMIT_CONFIG" end
	ensureStarted()
	local now = os.clock()
	local entry = rateLimitEntries[key]
	if entry then
		if entry.WindowSeconds ~= window or entry.Limit ~= limit then return true, "RATE_LIMIT_POLICY_MISMATCH" end
		cleanupRateEntry(entry, now, window)
		entry.LastSeen = now
		if getActiveRateCount(entry) >= limit then return true end
	elseif rateLimitKeyCount >= CONFIG.MAX_RATE_LIMIT_KEYS then
		return true, "RATE_LIMIT_CAPACITY_REACHED"
	end
	if rateLimitTimestampCount >= CONFIG.MAX_RATE_TIMESTAMPS then return true, "RATE_LIMIT_TIMESTAMP_CAPACITY_REACHED" end
	if not entry then
		entry = {Timestamps = {}, Head = 1, LastSeen = now, WindowSeconds = window, Limit = limit}
		rateLimitEntries[key] = entry
		rateLimitKeyCount += 1
	end
	table.insert(entry.Timestamps, now)
	rateLimitTimestampCount += 1
	return false
end
function GuardUtils.cleanupRateLimit(key)
	if not validateRateLimitKey(key) then return false, "INVALID_KEY" end
	removeRateEntry(key)
	return true
end
function GuardUtils.cleanupRateLimitPrefix(prefix)
	if not validateRateLimitKey(prefix) then return false, "INVALID_PREFIX" end
	for key in pairs(rateLimitEntries) do
		if key:sub(1, #prefix) == prefix then removeRateEntry(key) end
	end
	return true
end

-- ==========================================================================
-- MUTEX CON TOKEN DE PROPIETARIO
-- ==========================================================================

-- The caller's table is an identity only. Authoritative records never escape this module.
local function validateMutexTable(namespace)
	return type(namespace) == "table" and getmetatable(namespace) == nil and not table.isfrozen(namespace)
end

local function validateMutexTimeout(timeout)
	return isFiniteNumber(timeout) and timeout > 0 and timeout <= CONFIG.MAX_MUTEX_TIMEOUT
end

local function getRegistration(namespace)
	local id = mutexRegistrationIdsByTable[namespace]
	local registration = id and mutexRegistrations[id]
	if id and not registration then mutexRegistrationIdsByTable[namespace] = nil end
	return registration, id
end

local function dropLock(registration, key)
	if registration.Locks[key] then
		registration.Locks[key] = nil
		registration.Count -= 1
		mutexRecordCount -= 1
	end
end

local function pruneExpired(registration, now)
	for key, lock in pairs(registration.Locks) do
		if now >= lock.ExpiresAt then dropLock(registration, key) end
	end
end

local function dropRegistration(id, registration)
	local namespace = registration.MutexRef.Value
	if namespace and mutexRegistrationIdsByTable[namespace] == id then
		mutexRegistrationIdsByTable[namespace] = nil
	end
	mutexRecordCount -= registration.Count
	mutexRegistrationCount -= 1
	mutexRegistrations[id] = nil
end

function GuardUtils.registerMutexTable(namespace, timeout)
	if not validateMutexTable(namespace) then return nil, "INVALID_MUTEX_TABLE" end
	if timeout == nil then timeout = CONFIG.DEFAULT_MUTEX_TIMEOUT end
	if not validateMutexTimeout(timeout) then return nil, "INVALID_TIMEOUT" end
	local registration, id = getRegistration(namespace)
	if registration then
		registration.Timeout = timeout
		ensureStarted()
		return id
	end
	if mutexRegistrationCount >= CONFIG.MAX_MUTEX_REGISTRATIONS then
		for oldId, old in pairs(mutexRegistrations) do
			if old.MutexRef.Value == nil then dropRegistration(oldId, old) end
		end
		if mutexRegistrationCount >= CONFIG.MAX_MUTEX_REGISTRATIONS then
			return nil, "MUTEX_REGISTRATION_CAPACITY_REACHED"
		end
	end
	id = HttpService:GenerateGUID(false)
	mutexRegistrations[id] = {
		MutexRef = createWeakValueReference(namespace),
		Timeout = timeout,
		Locks = {},
		Count = 0,
	}
	mutexRegistrationIdsByTable[namespace] = id
	mutexRegistrationCount += 1
	ensureStarted()
	return id
end

function GuardUtils.unregisterMutexTable(identifier)
	local id
	if type(identifier) == "string" then
		id = identifier
	elseif type(identifier) == "table" then
		id = mutexRegistrationIdsByTable[identifier]
	else
		return false, "INVALID_IDENTIFIER"
	end
	local registration = id and mutexRegistrations[id]
	if not registration then return false, "NOT_REGISTERED" end
	pruneExpired(registration, os.clock())
	if registration.Count > 0 then return false, "ACTIVE_LEASES" end
	dropRegistration(id, registration)
	return true
end

-- A timeout override belongs only to this acquisition/renewal, never to the namespace policy.
function GuardUtils.acquireMutex(namespace, key, timeout)
	if not validateMutexTable(namespace) then return nil, "INVALID_MUTEX_TABLE" end
	if not isValidMutexKey(key) then return nil, "INVALID_KEY" end
	if timeout ~= nil and not validateMutexTimeout(timeout) then return nil, "INVALID_TIMEOUT" end
	local registration = getRegistration(namespace)
	if not registration then
		local id, err = GuardUtils.registerMutexTable(namespace)
		if not id then return nil, err end
		registration = mutexRegistrations[id]
	end
	local duration = timeout or registration.Timeout
	local now = os.clock()
	local old = registration.Locks[key]
	if old then
		if now < old.ExpiresAt then return nil, "LOCKED" end
		dropLock(registration, key)
	end
	if registration.Count >= CONFIG.MAX_MUTEX_KEYS_PER_REGISTRATION then
		pruneExpired(registration, now)
		if registration.Count >= CONFIG.MAX_MUTEX_KEYS_PER_REGISTRATION then
			return nil, "MUTEX_NAMESPACE_CAPACITY_REACHED"
		end
	end
	if mutexRecordCount >= CONFIG.MAX_MUTEX_RECORDS then return nil, "MUTEX_RECORD_CAPACITY_REACHED" end
	local token = HttpService:GenerateGUID(false)
	registration.Locks[key] = {Token = token, ExpiresAt = now + duration}
	registration.Count += 1
	mutexRecordCount += 1
	ensureStarted()
	return token
end

local function getOwnedLock(namespace, key, token)
	if not validateMutexTable(namespace) then return nil, nil, "INVALID_MUTEX_TABLE" end
	if not isValidMutexKey(key) then return nil, nil, "INVALID_KEY" end
	if type(token) ~= "string" or token == "" then return nil, nil, "INVALID_TOKEN" end
	local registration = getRegistration(namespace)
	local lock = registration and registration.Locks[key]
	if not lock then return nil, nil, "NOT_LOCKED" end
	if lock.Token ~= token then return nil, nil, "NOT_OWNER" end
	return registration, lock
end

function GuardUtils.releaseMutex(namespace, key, token)
	local registration, lock, err = getOwnedLock(namespace, key, token)
	if not lock then return false, err end
	local expired = os.clock() >= lock.ExpiresAt
	dropLock(registration, key)
	if expired then return false, "LOCK_EXPIRED" end
	return true
end

function GuardUtils.renewMutex(namespace, key, token, timeout)
	if timeout ~= nil and not validateMutexTimeout(timeout) then return false, "INVALID_TIMEOUT" end
	local registration, lock, err = getOwnedLock(namespace, key, token)
	if not lock then return false, err end
	local now = os.clock()
	if now >= lock.ExpiresAt then
		dropLock(registration, key)
		return false, "LOCK_EXPIRED"
	end
	lock.ExpiresAt = now + (timeout or registration.Timeout)
	return true
end

function GuardUtils.ownsMutex(namespace, key, token)
	local _, lock = getOwnedLock(namespace, key, token)
	return lock ~= nil and os.clock() < lock.ExpiresAt
end

function GuardUtils.isMutexLocked(namespace, key)
	if not validateMutexTable(namespace) or not isValidMutexKey(key) then return false end
	local registration = getRegistration(namespace)
	local lock = registration and registration.Locks[key]
	return lock ~= nil and os.clock() < lock.ExpiresAt
end

-- Synchronous only. Existing side effects cannot be undone when a callback fails.
function GuardUtils.withMutex(namespace, key, callback, timeout)
	if type(callback) ~= "function" then return false, "INVALID_CALLBACK" end
	local token, acquireError = GuardUtils.acquireMutex(namespace, key, timeout)
	if not token then return false, acquireError end
	local thread = coroutine.create(callback)
	local result = table.pack(coroutine.resume(thread, token))
	local suspended = coroutine.status(thread) == "suspended"
	if suspended then pcall(coroutine.close, thread) end
	local released, releaseError = GuardUtils.releaseMutex(namespace, key, token)
	if not result[1] then return false, "CALLBACK_ERROR", result[2] end
	if suspended then return false, "CALLBACK_YIELDED" end
	if not released then return false, "LOCK_OWNERSHIP_LOST", releaseError end
	return true, table.unpack(result, 2, result.n)
end

-- ==========================================================================
-- WATCHDOG Y LIMPIEZA
-- ==========================================================================

local function cleanupRateLimits(now)
	for key, entry in pairs(rateLimitEntries) do
		cleanupRateEntry(entry, now, entry.WindowSeconds)
		if getActiveRateCount(entry) <= 0 and now - entry.LastSeen >= CONFIG.RATE_LIMIT_KEY_TTL then
			removeRateEntry(key)
		end
	end
end

local function cleanupMutexRegistration(id, registration, now)
	-- Weak identity collection drops unreachable registrations and their accounting.
	if registration.MutexRef.Value == nil then
		dropRegistration(id, registration)
	else
		pruneExpired(registration, now)
	end
end

-- Puede llamarse manualmente en pruebas.
function GuardUtils.runMaintenance()
	local now = os.clock()
	local allSucceeded, rateError = xpcall(function() cleanupRateLimits(now) end, debug.traceback)
	if not allSucceeded then warn("[GuardUtils] Rate maintenance:", rateError) end
	for registrationId, registration in pairs(mutexRegistrations) do
		local succeeded, err = xpcall(function()
			cleanupMutexRegistration(registrationId, registration, now)
		end, debug.traceback)
		if not succeeded then
			allSucceeded = false
			warn("[GuardUtils] Mutex maintenance:", registrationId, err)
		end
	end
	return allSucceeded
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
--   nil / true -> limpia estado interno sin modificar las tablas del llamador.
--   false      -> detiene el watchdog pero conserva el estado.
function GuardUtils.Stop(clearState)
	running = false
	watchdogGeneration += 1
	if clearState == false then return true end
	table.clear(rateLimitEntries)
	rateLimitKeyCount = 0
	rateLimitTimestampCount = 0
	-- The namespace tables belong to callers; never clear or mutate them.
	table.clear(mutexRegistrations)
	table.clear(mutexRegistrationIdsByTable)
	mutexRegistrationCount = 0
	mutexRecordCount = 0
	return true
end

GuardUtils.Destroy =
	GuardUtils.Stop

function GuardUtils.GetStats()
	local active = 0
	local now = os.clock()
	for _, registration in pairs(mutexRegistrations) do
		if registration.MutexRef.Value ~= nil then
			for _, lock in pairs(registration.Locks) do
				if now < lock.ExpiresAt then active += 1 end
			end
		end
	end
	return {
		Running = running,
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
