# GuardUtils – Validation, Sanitization & Rate Limiting

Dependency‑free utility for Roblox.

---

## API

| Function | Description |
| :--- | :--- |
| `isValidData(value, maxKeys)` | Recursively validates DataStore‑safe values. |
| `sanitizeNumber(value, min, max)` | Rejects NaN, Infinity; clamps to range. |
| `sanitizeString(value, maxLength)` | Removes null bytes, trims, limits length. |
| `jugadorValido(player)` | Checks if player is still valid. |
| `datosCargados(player, isLoadedFunc)` | Generic data load check. |
| `isRateLimited(key, maxRequestsPerSecond)` | Sliding‑window rate limiter. |
| `deepCopy(original)` | Cycle‑safe deep copy. |
| `isDataStoreSafe(value)` | Checks if value is safe for DataStore. |
| `generarId(prefijo)` | Generates unique IDs. |

### Mutex + Watchdog (Enterprise)

```lua
GuardUtils.registerMutexTable(mutexTable, timeout)
GuardUtils.acquireMutex(mutexTable, key)
GuardUtils.releaseMutex(mutexTable, key)
Auto‑releases locks after timeout (configurable watchdog).

Quick Example
lua
local GuardUtils = require(script.Parent.GuardUtils)

-- Validate data before saving
if GuardUtils.isValidData(data) then
    DataStore:SetAsync(key, data)
end

-- Rate limit commands
if GuardUtils.isRateLimited("cmd_" .. userId, 5) then
    return -- too many requests
end

-- Mutex for critical section
if GuardUtils.acquireMutex(mutex, userId) then
    -- do work
    GuardUtils.releaseMutex(mutex, userId)
end
