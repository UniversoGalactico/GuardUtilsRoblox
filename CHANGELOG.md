# Changelog

## 3.0.0

Promotes 3.0.0-rc.8 after passing CI and the maintainer's reported Studio smoke test. Runtime change from rc.8: version string only.

- Bounded validation, strict DataStore shape checks and sanitized input handling.
- Sliding-window rate limiting with stable server-owned policy and resource caps.
- Private token-owned lease namespaces, exact binary64 expiry comparisons and watchdog recovery.
- Graph copy preserving aliases and cycles; immutable API.
- Regression, adversarial, type-analysis and Studio smoke-test tooling.

**Breaking changes from the old public version:** token required for release/renew; namespace table contents no longer contain locks; `withMutex` must not yield; rate policy changes require trusted reset; unknown options and malformed UTF-8 rejected; out-of-range raw numbers rejected unless Clamp=true; copying may return a budget error. See [migration notes](docs/API.md#migration-notes).

No distributed lock or production-load guarantee.
