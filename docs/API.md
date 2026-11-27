# API reference and migration

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

**Additional 3.0 compatibility changes:** unknown option keys are rejected; `sanitizeNumber` rejects raw out-of-range values before rounding unless `Clamp=true`; malformed UTF-8 is rejected before stripping controls. The module API is frozen; callers must not monkeypatch it. Expiry boundary behavior now follows the exact represented clock values. Existing callers using the documented options and valid inputs retain the same API.


