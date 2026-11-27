# GuardUtils for Roblox

Defensive Luau utilities for server-side validation, sanitization, rate limiting, lease ownership and graph copying.

**3.0.0-rc.8 — review candidate; not a production certification.** MIT. No external runtime dependencies.

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
| sanitizeString(value, maxLength?) | String or nil, error; rejects malformed original UTF-8, removes ASCII controls, trims, rejects overlong/empty input |
| sanitizeNumber(value, min?, max?, options?) | Number or nil, error; floors by default; checks raw input bounds before flooring unless Clamp=true; Integer=false allows fractions |
| isRateLimited(key, limit?, window?) | True when limited or invalid; optional error code |
| cleanupRateLimit(key), cleanupRateLimitPrefix(prefix) | Trusted-server reset |
| registerMutexTable(locks, timeout?), unregisterMutexTable(idOrTable) | Register a table identity as namespace; unregister refuses live leases |
| acquireMutex(locks, key, timeout?) | Opaque token or nil, error |
| ownsMutex(locks, key, token) | True only for current unexpired owner |
| renewMutex(locks, key, token, timeout?) | Boolean, optional error; cannot revive expired lease |
| releaseMutex(locks, key, token) | Boolean, optional error; only matching owner |
| isMutexLocked(locks, key) | Boolean for live lease |
| withMutex(locks, key, callback, timeout?) | true, callback results or false, code, detail; callback must not yield |
| deepCopy(value) | Copy preserving cycles, aliases and table keys, or nil, error on graph budget; no metatables; non-table values are returned by identity |
| jugadorValido(player), datosCargados(player, predicate) | Player membership / protected load predicate |
| generarId(prefix?) | Prefixed GUID |
| Start(), Stop(clearState?), Destroy(clearState?), runMaintenance(), GetStats() | Lifecycle and diagnostics |

## Resource budgets and security contracts

Validation defaults: 100 keys per table, 10,000 visited values, table depth 16, 10,000 characters per string, 4 MiB cumulative string bytes (including keys). Hard ceilings: 10,000 keys/table, 100,000 values, depth 64, 65,536 bytes/string, 16 MiB total string bytes. Options: MaxKeysPerTable, MaxTotalNodes, MaxDepth, MaxStringLength, MaxTotalBytes, RejectMetatables, RequireUtf8, RejectNullBytes, RequireArrayOrDictionary, RequireContiguousArrays. Unrecognized option keys fail closed (`UNKNOWN_VALIDATION_OPTION` or `UNKNOWN_NUMBER_OPTION`) rather than silently falling back to defaults. The DataStore wrapper forces all five flags true. Numeric magnitude is limited to 2^50; string budgets do not estimate exact serialized size. Diagnostics preview long keys (64 bytes) and render paths only when validation fails.

Rate limit: fixed policy per key, exact comparison of represented binary64 clock values for sliding-window expiry, defaults 10 events/second. Maximum 1,000 events per window, 3,600 seconds per window, 10,000 keys and 100,000 accounted active timestamps. Expired prefixes of arrays are also bounded by compaction. Full capacity or policy mismatch fails closed. An empty idle key is collected after 120 seconds. Keys/policies/resets must be controlled by the server, never by arbitrary client input. Limits are per VM.

Mutexes are expiring leases; expiry never cancels an old coroutine. Use a stable table as a namespace identity; frozen tables and metatables are supported because table contents are never inspected. Authoritative records are private and the module never reads or modifies the namespace contents. Up to 1,024 namespaces, 1,024 retained locks per namespace and 32,768 retained lock records globally; string keys are at most 200 bytes. Expired records are collected lazily or by maintenance. Unregistering a namespace with live leases fails. withMutex attempts to cancel a scheduled yielded callback and closes it if still suspended; previously completed side effects cannot be undone, and asynchronous side effects must not be spawned in critical sections. Stop() invalidates internal leases and clears rate limits without touching caller tables; Stop(false) pauses maintenance and cancels its scheduled watchdog; repeated Start/Stop does not accumulate sleeping watchdogs. Valid rate and acquisition requests restart maintenance even if denied. Do not stop while owners are working. If the watchdog cannot start, new admissions and lease acquisitions fail closed with `WATCHDOG_UNAVAILABLE`. Dead watchdog handles are detected and restarted on subsequent valid requests. Clock reads are monotonic-clamped, ignoring negative, regressing or non-finite values until a full reset. Lease expiry is computed from start and duration, not a rounded absolute deadline; time comparisons recover the rounding residual at equality. This is exact for the represented finite nonnegative binary64 timestamps, not a guarantee of clock resolution or physical elapsed time.

## Migration notes

The previous README omitted required owner tokens. Always pass them to releaseMutex and renewMutex. A changed rate policy now fails closed until a trusted explicit reset. withMutex is synchronous only; use explicit leases for yielding work. Validation enforces cumulative resource limits and counts shared subtrees per path. Handle deepCopy budget errors. Multi-result APIs now return explicit trailing nil error slots on success; withMutex preserves callback return arity. Direct reads/writes of old mutex table entries must migrate to ownsMutex/isMutexLocked; the caller table is now an identity only. Timeout overrides apply to individual acquisitions/renewals; registerMutexTable sets the default. Unregister refuses live leases.

**rc.7 compatibility changes:** unknown option keys are rejected; `sanitizeNumber` rejects raw out-of-range values before rounding unless `Clamp=true`; malformed UTF-8 is rejected before stripping controls. The module API is frozen; callers must not monkeypatch it. Expiry boundary behavior now follows the exact represented clock values. Existing callers using the documented options and valid inputs retain the same API.

## Tests

Run `python3 tests/run.py --luau /path/to/luau`. The harness runs actual module source with a deterministic clock, cooperative watchdog scheduler and minimal Roblox service doubles. Run `python3 tests/run.py --luau /path/to/luau --stateful --optimization 2` for 200,000 mixed state transitions checked against an independent tick-based model. CI runs both suites at optimization levels 0, 1 and 2. The regression suite includes independent breadth-first validation decisions, sliding-window and lease models, graph-copy identity checks, scheduler-generation tests and global capacity boundaries. The module uses strict Luau annotations for internal state; boundary functions intentionally accept any malformed runtime input. Run `python3 tests/typecheck.py --analyzer /path/to/luau-analyze` for standalone strict analysis with Roblox globals stubbed. It does not certify Studio's real scheduler, network services or distributed behavior.

### LuauProof adversarial audit (optional external toolkit)

The rc.7 audit uses the original pinned LuauProof 3.20 binary64 grammar, rational oracle, operand generator and bundled Luau VM, obtained from the owner's separate project. No private toolkit source or executable is bundled in GuardUtils. Extract LuauProof 3.20 separately, then run:

```sh
python3 tests/luauproof_attack.py --luauproof /path/to/extracted/luauproof \
  --source GuardUtilsRoblox.lua --runner tests/run.py \
  --seed 3182026 --programs 240 --inputs 512 --timing 8000 --utf8 16000 \
  --codegen --out audit.json
```

[Audit evidence](tests/evidence/rc7/) records the target hash, original toolkit hashes, seeds, exact expected category counts, results and elapsed execution time. The matched comparison of rc.6 and rc.7 runs 303,258 checks each; the extended campaign runs 2,066,392 checks across four VM configurations. These counts are repeated observations across optimization modes, including checks of the numerical oracle; they are not distinct vulnerabilities, independent attack payloads or formal proofs. The external toolkit is not needed to run the standard CI suites. Neither the test harness nor this audit replaces tests in Roblox Studio, DataStore, or the actual Roblox scheduler.

## Quick Roblox Studio smoke test

In a blank place, create a Folder in ServerScriptService with a ModuleScript named `GuardUtils` containing the module and a Script containing [studio_smoke.server.lua](tests/studio_smoke.server.lua). Press Play and inspect Output for 10/10 PASS. The test intentionally uses an isolated module because it calls Stop() and clears state. It exercises the real scheduler, including task.wait cancellation, but does not cover production load or DataStore writes. rc.8 adjusts strict annotations and watchdog initialization without changing the tested rc.7 numerical algorithm; the recorded rc.7 fuzz evidence remains bound to the original source hash.

## Benchmark

Run `python3 tests/run.py --luau /path/to/luau --benchmark` for five-sample median microbenchmarks. CI runs the same benchmark against the original public commit and current module. These are controlled local VM diagnostics, not Roblox production latency or memory measurements. CI uses official Luau 0.734 with the published SHA-256 pinned.

## Español

Biblioteca defensiva para Roblox. La versión candidata limita recursos, valida referencias compartidas, mantiene políticas de rate limiting estables y distingue propiedad temporal de exclusión distribuida. No usar withMutex para callbacks que cedan ejecución. No sustituye pruebas de integración en Studio.

MIT — [LICENSE](LICENSE).
