# GuardUtils 3.0.0

Dependency-free server-side Luau utilities for Roblox. Download **GuardUtilsRoblox.lua** and install it as a ModuleScript in ServerScriptService.

- Bounded validation and sanitization, sliding-window rate limiting, token-owned local mutex leases, cycle-aware graph copying.
- 36 regression suites, 600,000 mixed-state transitions, strict analysis; maintainer reported Studio smoke test 10/10 on rc.8.
- Runtime implementation unchanged from rc.8 except version string. Earlier rc.7 fuzz results remain pinned to that source.

[Quick start](https://github.com/UniversoGalactico/GuardUtilsRoblox#install) · [API and migration](https://github.com/UniversoGalactico/GuardUtilsRoblox/blob/main/docs/API.md)

Per VM only; no cross-server locks or production-load certification. MIT.
