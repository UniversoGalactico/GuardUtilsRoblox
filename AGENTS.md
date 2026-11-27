# GuardUtils integration guide for humans and AI agents

Read [README.md](README.md) first. Use [docs/API.md](docs/API.md) for complete signatures and [docs/TESTING.md](docs/TESTING.md) for evidence.

## Invariants

- `GuardUtilsRoblox.lua` is the single runtime dependency. Install as a server ModuleScript; API is frozen.
- Treat all remote input as untrusted; validate domain schema and authorization separately. Use server-derived rate keys, limits and resets. A true rate-limit result means deny.
- Keep a persistent namespace table for mutex operations. Acquire returns token or nil; release/renew require the same token. Never inspect namespace entries directly.
- `withMutex` is synchronous; no yielding or asynchronous side effects. Explicit leases may span yielding work, but stale owners must not commit; external writes need independent atomic fencing.
- No cross-Actor, cross-server or distributed guarantees. Do not assume leases cancel old tasks.
- Do not call Stop or reset rate limits from client-controlled paths. Stop() clears internal state.
- Structural validation is bounded, not a complete DataStore serializer or schema validator. Handle nil/error returns from sanitizers and deepCopy.

## When changing the library

Update tests and docs with any API change. Run standard regressions, stateful checks, strict analysis and isolated Studio smoke tests. Do not equate a finite fuzz campaign with formal verification. Preserve hash-bound historical evidence; label results by tested version.
