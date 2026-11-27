# GuardUtils for Roblox

**Small, dependency-free defensive utilities for server-side Luau.**

[![CI](https://github.com/UniversoGalactico/GuardUtilsRoblox/actions/workflows/regression.yml/badge.svg)](https://github.com/UniversoGalactico/GuardUtilsRoblox/actions/workflows/regression.yml) [Release v3.0.0](https://github.com/UniversoGalactico/GuardUtilsRoblox/releases/tag/v3.0.0) · MIT

GuardUtils helps reject malformed inputs, limit repeated requests, protect local critical sections and copy table graphs. It is not an anti-cheat or a replacement for server-authoritative game logic.

## Install

1. Download [GuardUtilsRoblox.lua](GuardUtilsRoblox.lua).
2. Create a ModuleScript named `GuardUtils` in `ServerScriptService` and paste the code.
3. Require it from a server Script:

```lua
local Guard = require(game.ServerScriptService.GuardUtils)
```

No packages, settings, or network access needed.

## Quick example

```lua
local Guard = require(game.ServerScriptService.GuardUtils)
local locks = {} -- persistent server-side namespace

local function processRequest(player, payload)
    if not Guard.jugadorValido(player) then return end
    if Guard.isRateLimited("purchase:" .. player.UserId, 5, 1) then return end

    local valid, code, path = Guard.validateData(payload)
    if not valid then return end

    -- Check your game's schema, permissions and authoritative balance here.
    local ok, result = Guard.withMutex(locks, player.UserId, function()
        -- Non-yielding local work only.
        return true
    end)
    if not ok then warn(result) end
end
```

## What it provides

| Need | API |
| --- | --- |
| Validate values and table shapes | `validateData`, `isValidData`, `isDataStoreSafe` |
| Clean strings / constrain numbers | `sanitizeString`, `sanitizeNumber` |
| Throttle requests | `isRateLimited`, `cleanupRateLimit` |
| Protect local critical sections | `withMutex`, `acquireMutex`, `ownsMutex`, `renewMutex`, `releaseMutex` |
| Copy cyclic/shared table graphs | `deepCopy` |
| Player checks and IDs | `jugadorValido`, `datosCargados`, `generarId` |
| Lifecycle and diagnostics | `Start`, `Stop`, `GetStats` |

**Important:** `isRateLimited` returns **true** when blocked. Mutex acquisition returns an owner token, not a boolean. `withMutex` must not yield or spawn asynchronous work. See [API reference](docs/API.md) for exact signatures, errors, limits and migration.

## Testing and scope

- 36 regression suites and 600,000 mixed-state transitions across Luau O0/O1/O2.
- Strict Luau analysis in CI; Roblox Studio smoke test: 10/10 reported by the maintainer on rc.8 (same implementation as 3.0.0 except version string).
- The earlier rc.7 numerical audit with LuauProof recorded 2,066,392 successful checks, including repeated VM configurations. Evidence is pinned to that candidate, not a formal proof of this release.

See [Testing and evidence](docs/TESTING.md) for reproduction commands and limitations.

**Production boundaries:** server-side, per Luau VM; no distributed or cross-Actor locks. Validation is structural, not game-specific authorization or a guarantee of DataStore acceptance. Expiring leases do not cancel old owners. No production load or memory certification.

## More

[API and migration](docs/API.md) · [Testing](docs/TESTING.md) · [AI integration guide](AGENTS.md) · [Changelog](CHANGELOG.md) · [License](LICENSE)

## Español

Biblioteca defensiva para Roblox, sin dependencias. Instala el ModuleScript en ServerScriptService. Valida datos, limita solicitudes y protege secciones críticas locales. Las funciones de mutex no sustituyen transacciones distribuidas y `withMutex` no puede ceder ejecución. Consulta la referencia para integrar el módulo correctamente.
