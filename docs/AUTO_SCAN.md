# AUTO_SCAN — Offset auto-discovery, debug logging & fix guide

## What was added (patched/)
| File | Purpose |
|------|---------|
| `esp/Core/DebugLogger.h/.mm` | Levels (DEBUG/INFO/WARN/ERROR), timestamps, file mirror, scoped timers, throttling. `ESP_LOG_DEBUG/INFO/WARN/ERROR`, `ESP_LOG_DEBUG_THROTTLED` (1/30 frames), `ESP_LOG_INFO_ONCE`, `ESPScopedTimerBegin/End` |
| `esp/Core/MemoryRegions.h/.mm` | `ESPEnumerateRegions(task)` via `mach_vm_region_recurse`, `ESPDumpRegions` (vmmap-style DEBUG dump) |
| `esp/Core/AOBScanner.h/.mm` | AOB pattern `"48 8B ?? ?? 90 ??"` → `ESParsePattern`, chunked `ESScanRegion` (64KB chunks + progress), `ESScanTask` (all readable regions in range) |
| `esp/Core/OffsetScanner.h/.mm` | `ESPProbeChain(base,RVA)` validates every hop with logs; `ESPFindGameFacadeGlobal(candidates)` tries known RVAs; `ESScanGameFacadeStatic` pointer-scan fallback; `ESPIdentifyBones` stub (real scan in GameLogic) |
| `esp/Core/MemoryUtils.*` | `sysctl`/`task_for_pid`/`mach_vm_region_recurse`/`vm_read` now log errors with `mach_error_string`; new `ESPGetTargetTask()/ESPGetTargetPid()` (fixes pre-existing per-TU `static get_task` bug where esp.mm's copy was always NULL) |
| `esp/Core/GameLogic.*` | All chain funcs log hops; `getHead/getRightToeNode` Y-scan logs every candidate + winner offset; `gGameFacadeGlobalRVA` + `kGameFacadeCandidates[]` heal state |
| `esp/Core/UnityMath.mm` | `WorldToScreen` NaN/w checks, `getPositionExt` pointer guards + chain-loop guard (128), `GetNickName` fallback offsets `0x490/0x460/0x468` |
| `esp/drawing_view/esp.mm` | Init: DEBUG level, file-log toggle, region dump, initial `ESPProbeChain`, auto-heal (candidates → pointer scan). Per-frame: 60-zero-frame runtime re-probe + heal. First-frame INFO |

## How to use

### Build
No makefile change needed — `$(wildcard esp/Core/*.mm)` already picks up the 4 new `.mm` files. Build as before:
```bash
make clean package
# → packages/TrollSpeed.tipa
```

### Enable verbose debug (on iPhone)
In `esp.mm` init (already set):
```objc
ESPSetLogLevel(ESPLogLevelDebug);  // DEBUG = per-hop + per-bone logs
ESPLogToFile(NO);                  // set YES for Documents/esp_debug.log
```
- Console: stream via `idevicesyslog | grep -i "esp\|flork"` or Xcode device log.
- File (if enabled): `Documents/esp_debug.log` in the HUD app sandbox (read with Filza/TrollStore).
- Production: set `ESPLogLevelInfo` (hides DEBUG) — WARN/ERROR always show.

### Read the logs (what each stage prints)
```
[MEM] found 'freefireth' pid=12345
[MEM] task_for_pid(self, 12345) -> kr=0 (success) task=0x...
[MEM] module base=0x... (first region) pid=12345
[MEMMAP] 0x... +0x... prot=... name=...   (full region list at DEBUG)
[PROBE] TypeInfo @... = ... valid=1
[PROBE] StaticBlock = ...
[PROBE] MatchGame @Static+0x8 = ...
[PROBE] Match / CameraMgr / Camera / LocalPlayer / List / matrix ...
[PROBE] done mainOk=1 listOk=1 cameraOk=1 players=12
[W2S] obj=(...) w=...
[POS] transObj2=... matrix=... index=...
[BONES] player=... cand[0] off=0x698 node=... pos=(...)
[BONES] winner off=0x... y=...
[Flork] Count: 8
[TIMER] update_data took ... ms  (DEBUG)
```
- `mainOk=0` + FAIL stage → that stage's offset is stale. See "Fix a stale offset" below.
- `listOk=0` → player list moved (tried `0x158`/`0x160`). Check dump.cs for new `List<Player>` offsets.
- `matrixValid=0` → camera matrix at `+0x10/+0xD8` broke (unlikely — Unity stable). Check camera `+0x20` vs `+0x28`.
- Bone winner offset changing per frame → wrong candidates; tighten `kITransformNodeOffsets[]` to the logged winner once stable.

## Auto-heal behavior (no IDA needed for most updates)

### 1. GameFacade global RVA (most fragile — changes every build)
`getMatchGame` reads `Module_Base + gGameFacadeGlobalRVA`. On first probe failure the app tries, in order:
1. **Candidates list** (`kGameFacadeCandidates` in GameLogic.mm) — add discovered RVAs here as you find them, newest first. Zero-config if you pre-populate.
2. **Pointer scan** (`ESScanGameFacadeStatic`, 192MB): scans for any pointer `P` where `*(P+0xB8)` → static block and `*(sb+0x8)` → object with valid `+0x90`/`+0xD8`. Found RVA is written to `gGameFacadeGlobalRVA` and logged as `[HEAL] found GameFacade global RVA=0x...`. Works without IDA but costs ~1–3s and can false-positive on other singletons with the same shape — always confirm with a second probe (app does this automatically).
3. Runtime re-heal: after 60 consecutive zero-count frames, re-probes and re-heals (covers match transitions / lobby→game).

> To use heal immediately after a Free Fire update: launch HUD in lobby, then enter a match. If `Count` stays 0 for ~1s you'll see `[ESP] 60 consecutive zero-count` → `[HEAL]`. If heal succeeds, boxes appear without rebuilding.

### 2. Field offsets (Match/Player/Camera)
These come from `dump.cs` field offsets — they survive minor builds but can shift when fields are added (as happened: camera `0x18→0x20`, LocalPlayer `0x58→0xD8`, etc.). The healer does **not** brute-force these automatically (too many candidates, high false-positive rate). Instead:
- Probe logs tell you *which hop* failed (`[PROBE] FAIL stage=Match` etc.).
- Re-dump with Il2CppDumper (fields-only mode — see below), grep the new dump.cs for the class, update the constant, rebuild.
- Bone offsets are already self-healing (Y-scan picks head/toe automatically; only the candidate list `kITransformNodeOffsets[]` needs extending if Player grows new transform fields).

### 3. AOB scans (for code patterns, not pointers)
`ESScanTask(task, rangeStart, rangeEnd, "48 8B ?? ?? 90 ??", max)` finds byte patterns in readable regions. Useful to find functions (e.g. `get_CurrentMatchGame` body) whose bytes are stable across builds, then derive the data address from its `ADRP`/`ADD`. To get the pattern:
- In IDA/Ghidra, open `UnityFramework`, find the method, copy first ~8 bytes, mask volatile operands with `??`.
- Pass the module range (`moduleBase .. moduleBase+0xC000000`) to `ESScanTask` at runtime (or offline with a small Python/vm_read tool).
This is the "Get New Offset with Pattern Scan" workflow used by the PC/Android community (MikaCybertron/Get-New-Offset-with-Pattern-Scan): dump old bytes from IDA, scan new build, read new address.

## Re-dump after update (fields-only — DumpMethod is broken on this build)
```bash
# Install dotnet 6 (arm64) + Il2CppDumper v6.7.46 net6 (see OFFSETS_1.132.1.md for exact URLs)
cat > /tmp/il2cppdumper/config.json << 'EOF'
{ "DumpMethod": false, "DumpField": true, "DumpProperty": false,
  "DumpAttribute": false, "DumpFieldOffset": true, "DumpMethodOffset": false,
  "DumpTypeDefIndex": true, "GenerateDummyDll": false, "GenerateStruct": false,
  "DummyDllAddToken": true, "RequireAnyKey": false, "ForceIl2CppVersion": false,
  "ForceVersion": 16, "ForceDump": false, "NoRedirectedPointer": false }
EOF
/tmp/dotnet/dotnet Il2CppDumper.dll UnityFramework global-metadata.dat dump_out
grep -n "TypeDefIndex: 12379" dump_out/dump.cs
grep -n "TypeDefIndex: 31767" dump_out/dump.cs
grep -n "TypeDefIndex: 32076" dump_out/dump.cs
grep -n "TypeDefIndex: 36245" dump_out/dump.cs
grep -n "TypeDefIndex: 34508" dump_out/dump.cs
```

Note: DumpMethod=true fails on Free Fire obfuscation (GetMethodPointer IndexOutOfRange, dump truncates to 49KB). Field offsets are unaffected — use fields-only (32MB dump, all 43417 types).

## Fix a stale offset (step-by-step)
1. Set log level to DEBUG, enable file log, build, run one match. Save the log.
2. Find the first PROBE FAIL stage=X or GameLogic X failed line. X is the broken hop.
3. Re-dump dump.cs from the current IPA (command above). Grep the class for field X, note the new offset.
4. Update the constant in GameLogic.mm / UnityMath.mm / esp.mm (search the old hex). Add a CHANGED comment with old -> new and TypeDef number.
5. If the broken hop is the GameFacade global (stage=TypeInfo): either add the new RVA to kGameFacadeCandidates (after finding it via IDA or heal log) or let the pointer-scan heal find it (check HEAL/SCAN lines).
6. Rebuild, re-run, confirm PROBE mainOk=1 and Count > 0.

## Known limitations
- Pointer-scan heal for the global can false-positive if another singleton shares the +0xB8/+0x8/+0x90/+0xD8 shape. Mitigation: app re-probes after heal and continues scanning only if probe still fails (it returns the first validated hit — confirm players>0).
- Head/toe Y-scan is a proxy (highest/lowest bone), not the exact Unity head bone. Good for box ESP; for aimbot-precision, hardcode the logged winner offset after one stable session.
- vm_read_overwrite cannot read guard/unreadable pages; scans skip non-readable regions (logged as MEMMAP). task_for_pid requires TrollStore entitlements — if task_for_pid FAILED appears, fix signing, not offsets.
- isVaildPtr range 0x100000000-0x1600000000 is from the original code; if ASLR base lands outside (unlikely on arm64 iPhone), widen it — the probe logs will show valid=0 for every pointer including the module base itself.

## Verification
- [x] grep -c ESP_LOG over patched files is > 60 (every stage logs).
- [x] New files compile conceptually (ObjC++ .mm, C++17, Foundation/QuartzCore available via existing frameworks in makefile).
- [x] No makefile change needed (esp/Core/*.mm wildcard).
- [ ] On-device: initial probe mainOk=1, heal log on stale RVA, Count > 0 in match (requires iPhone — cannot verify here).
