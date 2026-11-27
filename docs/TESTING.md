# Testing and evidence

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

[Audit evidence](../tests/evidence/rc7/) records the target hash, original toolkit hashes, seeds, exact expected category counts, results and elapsed execution time. The matched comparison of rc.6 and rc.7 runs 303,258 checks each; the extended campaign runs 2,066,392 checks across four VM configurations. These counts are repeated observations across optimization modes, including checks of the numerical oracle; they are not distinct vulnerabilities, independent attack payloads or formal proofs. The external toolkit is not needed to run the standard CI suites. Neither the test harness nor this audit replaces tests in Roblox Studio, DataStore, or the actual Roblox scheduler.

## Quick Roblox Studio smoke test

In a blank place, create a Folder in ServerScriptService with a ModuleScript named `GuardUtils` containing the module and a Script containing [studio_smoke.server.lua](../tests/studio_smoke.server.lua). Press Play and inspect Output for 10/10 PASS. The test intentionally uses an isolated module because it calls Stop() and clears state. It exercises the real scheduler, including task.wait cancellation, but does not cover production load or DataStore writes. rc.8 (the implementation promoted to 3.0.0 with only the version string changed) adjusts strict annotations and watchdog initialization without changing the tested rc.7 numerical algorithm; the recorded rc.7 fuzz evidence remains bound to the original source hash.

## Benchmark

Run `python3 tests/run.py --luau /path/to/luau --benchmark` for five-sample median microbenchmarks. CI runs the same benchmark against the original public commit and current module. These are controlled local VM diagnostics, not Roblox production latency or memory measurements. CI uses official Luau 0.734 with the published SHA-256 pinned.


## Studio result

The maintainer reported 10/10 smoke checks passing in Roblox Studio on rc.8. This is a maintainer-reported result, not a hosted CI run. No production load or memory certification is claimed. Use an isolated module for the smoke test; it clears internal state.
