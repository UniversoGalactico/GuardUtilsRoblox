# GuardUtils for Roblox

Defensive Luau utilities for server-side validation, sanitization, rate limiting, lease ownership and graph copying.

**3.0.0-rc.1 — review candidate; not a production certification.** MIT. No external runtime dependencies.

## Install

Create a ModuleScript named `GuardUtils` in ServerScriptService and paste [GuardUtilsRoblox.lua](GuardUtilsRoblox.lua). This is a singleton per Luau VM, not a cross-Actor or distributed lock.

```lua
local Guard = require(script.Parent.GuardUtils)
local locks = {} -- Keep this table for the lifetime of the protected resource.

local ok, code, path = Guard.isDataStoreSafe({Coins = 100, Inventory = {"Sword"}})
if not ok then warn(code, path); return end
if Guard.isRateLimited("purchase:" .. player.UserId, 5, 1) then return end

local success, result = Guard.withMutex(locks, player.UserId, function()
    -- Non-yielding work only.
    return 42
end)
if not success then warn(result) end

local token, err = Guard.acquireMutex(locks, player.UserId, 30)
if token then
    -- For yielding work, check ownership before synchronous local commits.
    if Guard.ownsMutex(locks, player.UserId, token) then
        -- External writes need independent atomic fencing.
    end
    Guard.releaseMutex(locks, player.UserId, token)
end
```

## API

| Function | Contract |
| --- | --- |
| validateData(value, options?) | true or false, error code, path; rejects cycles, counts aliases by occurrence |
| isValidData(value, maxKeysOrOptions?) | Boolean wrapper |
| isDataStoreSafe(value, options?) | Rejects sparse/mixed tables, invalid UTF-8, cycles and metatables; not a guarantee of DataStore acceptance |
| sanitizeString(value, maxLength?) | String or nil, error; removes controls, trims, rejects overlong/empty input |
| sanitizeNumber(value, min?, max?, options?) | Number or nil, error; floors by default; Integer=false allows fractions; Clamp=true opts into clamping |
| isRateLimited(key, limit?, window?) | True when limited or invalid; optional error code |
| cleanupRateLimit(key), cleanupRateLimitPrefix(prefix) | Trusted-server reset |
| registerMutexTable(locks, timeout?), unregisterMutexTable(idOrTable) | Track dedicated plain mutable lock tables; unregister does not release locks |
| acquireMutex(locks, key, timeout?) | Opaque token or nil, error |
| ownsMutex(locks, key, token) | True only for current unexpired owner |
| renewMutex(locks, key, token, timeout?) | Boolean, optional error; cannot revive expired lease |
| releaseMutex(locks, key, token) | Boolean, optional error; only matching owner |
| isMutexLocked(locks, key) | Boolean for live lease |
| withMutex(locks, key, callback, timeout?) | true, callback results or false, code, detail; callback must not yield |
| deepCopy(value) | Copy preserving cycles, aliases and table keys, or nil, error on graph budget; no metatables |
| jugadorValido(player), datosCargados(player, predicate) | Player membership / protected load predicate |
| generarId(prefix?) | Prefixed GUID |
| Start(), Stop(clearState?), Destroy(clearState?), runMaintenance(), GetStats() | Lifecycle and diagnostics |

## Resource budgets and security contracts

Validation defaults: 100 keys per table, 10,000 visited values, table depth 16, 10,000 characters per string, 4 MiB cumulative string bytes (including keys). Hard ceilings: 10,000 keys/table, 100,000 values, depth 64, 65,536 bytes/string, 16 MiB total string bytes. Options: MaxKeysPerTable, MaxTotalNodes, MaxDepth, MaxStringLength, MaxTotalBytes, RejectMetatables, RequireUtf8, RejectNullBytes, RequireArrayOrDictionary, RequireContiguousArrays. DataStore wrapper forces all five flags true. Numeric magnitude is limited to 2^50; string budgets do not estimate exact serialized size.

Rate limit: fixed policy per key, exact sliding window, defaults 10 events/second. Maximum 1,000 events per window, 3,600 seconds per window, 10,000 keys and 100,000 accounted active timestamps. Expired prefixes of arrays are also bounded by compaction. Full capacity or policy mismatch fails closed. An empty idle key is collected after 120 seconds. Keys/policies/resets must be controlled by the server, never by arbitrary client input. Limits are per VM.

Mutexes are expiring leases; expiry never cancels an old coroutine. Use dedicated, trusted, mutable plain lock tables, and do not modify records directly. Up to 1,024 registered tables. The watchdog scans those tables. withMutex closes a yielded callback; previously completed side effects cannot be undone, and asynchronous side effects must not be spawned in critical sections. Stop() clears state and registered lock tables; Stop(false) pauses maintenance. Do not stop while owners are working.

## Migration notes

The previous README omitted required owner tokens. Always pass them to releaseMutex and renewMutex. A changed rate policy now fails closed until a trusted explicit reset. withMutex is synchronous only; use explicit leases for yielding work. Validation enforces cumulative resource limits and counts shared subtrees per path. Handle deepCopy budget errors.

## Tests

Run `python3 tests/run.py --luau /path/to/luau`. The harness runs actual module source with a deterministic clock and minimal Roblox service doubles. It does not certify Studio or distributed behavior.

## Español

Biblioteca defensiva para Roblox. La versión candidata limita recursos, valida referencias compartidas, mantiene políticas de rate limiting estables y distingue propiedad temporal de exclusión distribuida. No usar withMutex para callbacks que cedan ejecución. No sustituye pruebas de integración en Studio.

MIT — [LICENSE](LICENSE).
