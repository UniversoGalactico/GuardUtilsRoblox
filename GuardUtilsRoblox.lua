-- GuardUtils.lua | ModuleScript (ServerScriptService.ServerModules)
-- Responsabilidad única: Funciones de validación, sanitización y rate limiting reutilizables.
-- Dependencia común para todo el ecosistema Universo.

local GuardUtils = {}
local Players = game:GetService("Players")

local CONFIG = table.freeze({
    MAX_STATEDATA_KEYS = 100,
    MAX_REQUESTS_PER_SECOND = 10,
    MAX_SAFE_INTEGER = 2 ^ 50,
    WATCHDOG_INTERVAL = 60,         -- segundos entre limpiezas
    MAX_KEY_AGE_SECONDS = 120,      -- tiempo máximo sin uso antes de limpiar una clave de rate limiting
})

-- Estado interno para rate limiting
local rateLimitTimestamps = {}

-- ================================================================
-- VALIDACIÓN DE TIPOS
-- ================================================================

-- 1. isValidData con límite de claves configurable.
function GuardUtils.isValidData(value, maxKeys)
    if value == nil then return false end
    local t = type(value)
    if t == "function" or t == "userdata" or t == "thread" then return false end
    if typeof(value) == "Instance" then return false end
    if t == "number" and value ~= value then return false end
    if t == "table" then
        local count = 0
        local limit = maxKeys or CONFIG.MAX_STATEDATA_KEYS
        for k, v in pairs(value) do
            count += 1
            if count > limit then return false end
            if not GuardUtils.isValidData(k, maxKeys) or not GuardUtils.isValidData(v, maxKeys) then
                return false
            end
        end
    end
    return true
end

-- 2. jugadorValido verifica que sea un Player real.
function GuardUtils.jugadorValido(player)
    if not player or not player:IsA("Player") or not player.Parent then
        return false
    end
    return player:IsDescendantOf(Players)
end

-- 3. datosCargados (CORREGIDO: sin fallback automático).
--    Si no se pasa isLoadedFunc, retorna false para evitar falsos positivos.
function GuardUtils.datosCargados(player, isLoadedFunc)
    if type(isLoadedFunc) == "function" then
        return isLoadedFunc(player)
    end
    -- Sin función de verificación, no podemos confirmar que los datos estén listos.
    return false
end

-- ================================================================
-- SANITIZACIÓN
-- ================================================================

-- 4. sanitizeString (CORREGIDO: solo elimina null bytes, no caracteres de control).
function GuardUtils.sanitizeString(value, maxLength)
    if type(value) ~= "string" then return nil end
    -- Eliminar bytes nulos
    local cleaned = value:gsub("%z", "")
    -- Limitar longitud
    local limit = maxLength or 1000
    if #cleaned > limit then return nil end
    -- Recortar espacios extremos
    cleaned = cleaned:match("^%s*(.-)%s*$")
    if cleaned == "" then return nil end
    return cleaned
end

-- 5. sanitizeNumber con límites configurables.
function GuardUtils.sanitizeNumber(value, min, max)
    if type(value) ~= "number" then return nil end
    if value ~= value then return nil end
    if value == math.huge or value == -math.huge then return nil end
    local minVal = min or 0
    local maxVal = max or CONFIG.MAX_SAFE_INTEGER
    return math.clamp(math.floor(value), minVal, maxVal)
end

-- ================================================================
-- RATE LIMITING
-- ================================================================

-- 6. isRateLimited (CORREGIDO: solo acepta strings; otros tipos no se bloquean pero avisan).
function GuardUtils.isRateLimited(key, maxRequestsPerSecond)
    if type(key) ~= "string" then
        warn("[GuardUtils] isRateLimited recibió una clave no string (" .. typeof(key) .. "). Retornando false.")
        return false
    end
    if #key == 0 then
        warn("[GuardUtils] isRateLimited recibió una clave vacía. Retornando false.")
        return false
    end

    local now = os.clock()
    rateLimitTimestamps[key] = rateLimitTimestamps[key] or {}
    local ts = rateLimitTimestamps[key]
    local i = 1
    while ts[i] and (now - ts[i]) > 1.0 do
        table.remove(ts, i)
    end
    local limit = maxRequestsPerSecond or CONFIG.MAX_REQUESTS_PER_SECOND
    if #ts >= limit then
        return true
    end
    table.insert(ts, now)
    return false
end

-- 7. cleanupRateLimit segura contra claves nil.
function GuardUtils.cleanupRateLimit(key)
    if type(key) == "string" then
        rateLimitTimestamps[key] = nil
    end
end

-- 8. Watchdog con límite de edad configurable.
task.spawn(function()
    while true do
        task.wait(CONFIG.WATCHDOG_INTERVAL)
        local now = os.clock()
        for key, timestamps in pairs(rateLimitTimestamps) do
            local i = 1
            while timestamps[i] and (now - timestamps[i]) > 1.0 do
                table.remove(timestamps, i)
            end
            if #timestamps == 0 then
                rateLimitTimestamps[key] = nil
            end
        end
    end
end)

-- ================================================================
-- UTILIDADES ADICIONALES
-- ================================================================

-- 9. deepCopy segura contra ciclos.
--    NOTA: El marcador { __cyclic = true } es seguro para copias en memoria,
--    pero NO debe guardarse directamente en DataStore. Usá isDataStoreSafe para validar.
function GuardUtils.deepCopy(original)
    if type(original) ~= "table" then return original end
    local seen = {}
    local function _deepCopy(orig)
        if type(orig) ~= "table" then return orig end
        if seen[orig] then return { __cyclic = true } end
        seen[orig] = true
        local copy = {}
        for k, v in pairs(orig) do
            copy[_deepCopy(k)] = _deepCopy(v)
        end
        return copy
    end
    return _deepCopy(original)
end

-- 10. isDataStoreSafe: verifica que un valor no contenga marcadores cíclicos.
--     Retorna true si es seguro guardarlo en DataStore.
function GuardUtils.isDataStoreSafe(value)
    if type(value) ~= "table" then return true end
    for k, v in pairs(value) do
        if type(v) == "table" and v.__cyclic then
            return false
        end
        if not GuardUtils.isDataStoreSafe(k) or not GuardUtils.isDataStoreSafe(v) then
            return false
        end
    end
    return true
end

-- 11. generarId único para claves de rate limiting o logs.
local idCounter = 0
function GuardUtils.generarId(prefijo)
    idCounter = (idCounter % 100000) + 1
    return (prefijo or "id") .. "_" .. os.time() .. "_" .. idCounter
end

return GuardUtils
