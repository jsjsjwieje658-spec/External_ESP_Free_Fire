# Free Fire TH iOS 1.132.1 — Offset Update Report
## Source: `com.dts.freefireth_1.132.1_decrypted.ipa` (475MB, 2026-09-02)
## Method: Il2CppDumper dump.cs (fields-only, 32MB, 43417 TypeDefs) + Mach-O parse

### Files analyzed
- `Payload/FreeFire.app/Frameworks/UnityFramework.framework/UnityFramework` (199MB, Mach-O arm64)
- `Payload/FreeFire.app/Data/Managed/Metadata/global-metadata.dat` (55MB, metadata v31, magic 0xFAB11BAF)
- `dump.cs` generated with Il2CppDumper v6.7.46 (net6, dotnet 6.0.428 on aarch64)
  - Config: DumpField=true, DumpFieldOffset=true, DumpMethod=false (DumpMethod triggered GetMethodPointer IndexOutOfRange for Assembly-CSharp due to obfuscation — field offsets still 100% valid)
  - CodeRegistration RVA 0xb252a08, MetadataRegistration RVA 0xb3fd6c8 (from Il2CppDumper)
  - Mach-O segments: __TEXT 0x0-0xb1c8000, __DATA 0xb1c8000-0xc388000, __LINKEDIT 0xc388000+

### Class hierarchy (confirmed from dump.cs)
| Role | Class (obfuscated → real) | TypeDef | Namespace |
|------|---------------------------|---------|-----------|
| Game manager | `GameFacade` | 12379 | COW |
| Match game | `MatchGame` : COWGameBase | 12386 | COW |
| Match | `JMAGGLCNGIG` (= Match) | 32076 | COW.GamePlay |
| Player | `Player` : AttackableEntity | 31767 | COW/GamePlay |
| Attackable | `AttackableEntity` : COWReplicationEntity | 31854 | COW.GamePlay |
| Replication | `ReplicationEntity` : Entity | 36245 | (root) |
| Entity | `Entity` : MonoBehaviour | 36241 | (root) |
| Camera mgr | `CameraControllerManager` : MonoBehaviour | 31945 | COW/GamePlay |
| PlayerID | `BEADLMGGGGL` (= COW_GamePlay_PlayerID_o) | 34508 | COW.GamePlay |

### Complete offset comparison

| # | Chain | Old offset | New offset (1.132.1) | Status | Evidence in dump.cs |
|---|-------|------------|----------------------|--------|----------------------|
| 1 | `GameFacade` static block + CurrentMatchGame | `+0x0` | `+0x8` | **CHANGED** | `CurrentGame 0x0, CurrentMatchGame 0x8, KEY_IS_BLACK_BLOOD 0x10` |
| 1b | Global RVA (Module_Base + X → TypeInfo) | `0x9985B70` | **INVALID — must re-find** | **BROKEN** | `0x9985B70` in new binary is `__text` code bytes `a1af00d0214c...` (ARM64 instructions, not a pointer). `__DATA` now at `0xb1c8000`. Use IDA/Ghidra with MetadataRegistration anchor `0xb3fd6c8` |
| 2 | `MatchGame → m_Match (Match)` | `0x90` | `0x90` | KEEP | `MatchGame.m_Match JMAGGLCNGIG 0x90` |
| 3 | `MatchGame → m_CameraControllerManager` | `0xD8` | `0xD8` | KEEP | `m_CameraControllerManager 0xD8` |
| 4 | `CameraControllerManager → Camera` | `0x18` | `0x20` | **CHANGED** | `EKIPKGNKILM Camera 0x20, LBHAFMEPGCO Camera 0x28` |
| 5 | `Camera → view matrix` (`+0x10` → `+0xD8`) | `0x10/0xD8` | `0x10/0xD8` | KEEP* | `UnityEngine.Camera` has no managed fields (native-only, TypeDef 40715). Native layout stable. *Verify at runtime: matrix floats in [-1,1], w ≠ 0 |
| 6 | `Match → LocalPlayer` | `0x58` | `0xD8` | **CHANGED** | `JMAGGLCNGIG.MHJCLOPOBAA Player 0xD8` (first Player-typed field) |
| 7 | `Match → player list` | `0xC8→+0x28→array` | `0x158 List<Player> → +0x10 items, +0x18 size` (fallback `0x160`) | **CHAIN BROKEN** | `LMOIPODCHOL List<Player> 0x158, DPFFPGAFGDK 0x160`; old `0xC8` now `bool JPLFOEAANDA`. List/SzArray layout unchanged (items `+0x20+i*8`, count `+0x18`) |
| 8 | `Player → MainCameraTransform` | `0x2B0` | `0x3E8` | **CHANGED** | `Player.MainCameraTransform Transform 0x3E8`; old `0x2B0` now `GameObject MNMEALNFGML` |
| 9 | `Player → PlayerID (TeamID)` | `0x2D0` | `0x408` | **CHANGED** | `Player.MHGFKKALMDK BEADLMGGGGL 0x408`; old `0x2D0` now `Dictionary<int,uint>`. Struct layout identical: TeamID byte at `+0x8` |
| 10 | `Player → IPRIDataPool` | `0x68` | `0x70` | **CHANGED (+8)** | `ReplicationEntity.m_PRIDataPool 0x70`, `m_IsPRIRecivedFirstTime 0x68` (inserted field) |
| 11 | `Player → NickName` | `0x358` | `0x498 (OriginalNickName)` | **CHANGED** | `Player.OriginalNickName string 0x498`; old `0x358` now `Action CNGMGEJHJKM`. Fallbacks: `0x490 BDHGDLFDHAL`, `0x460/0x468` |
| 12 | `Player → Head bone` | `0x550` | **INVALID → scan ITransformNodes** | **BROKEN** | Old `0x550` now `Quaternion GHPHCGIIHON` (not a bone). Head is one of 28+ `ITransformNode` fields `0x698+` (obfuscated names). Patched code scans by max Y |
| 13 | `Player → RightToe bone` | `0x5A0` | **INVALID → scan ITransformNodes** | **BROKEN** | Old `0x5A0` now `ResourceID DPGLODLEAIC` (not a bone). Same scan approach (min Y) |
| 14 | `Bone → Transform`, `Transform` internals | `0x10 / 0x38/0x40/0x18/0x20` | same | KEEP | Unity `Transform` internals stable across versions |

### PlayerID struct (BEADLMGGGGL, TypeDef 34508) — layout identical to old
```
EOKFPKOEDDJ uint 0x0   (= m_Value)
DDJGLLGPBJD uint 0x4   (= m_ID)
JLIDCJLKLBD byte 0x8   (= m_TeamID)  <-- compare this byte
JHHPHPJMFNG byte 0x9   (= m_ShortID)
IKNFNCJNLH ulong 0x10  (= m_IDMask)
```
Old `COW_GamePlay_PlayerID_o` in `UnityMath.h` already matches — no struct change needed.

### What still needs IDA/Ghidra (cannot be done from dump.cs alone)
1. **Global RVA for GameFacade TypeInfo** (replaces `0x9985B70`). Steps:
   - Open `UnityFramework` in IDA/Ghidra (Mach-O arm64, 199MB)
   - Import `script.json` if you can generate it (Il2CppDumper with DumpMethod fails on this build — see note below), or search strings for `GameFacade`
   - Find `get_CurrentMatchGame` method (should load static field at static-block+`0x8`)
   - Trace its `ADRP`/`ADD` to the static data address in `__DATA` → subtract module base → RVA
   - Anchor: MetadataRegistration is at RVA `0xb3fd6c8` (file offset == RVA since `__DATA` fileoff == vmaddr)
2. **Exact Head/Toe bone indices**. Patched code uses Y-scan (robust, good for box ESP). For pixel-perfect head (e.g. aimbot), identify:
   - Log all candidate world positions once in-game, find which offset stays at head height during crouch/jump
   - Or reverse `Player` skeleton init in IDA (avatar bone assignment)
3. **Verify List<Player> at `0x158` vs `0x160`**. Patched code tries `0x158` then falls back to `0x160`. Check `NSLog Count` — if 0, the active list is the dictionary at `0x128`/`0x130` instead (needs dictionary enumeration, not implemented).

### Why DumpMethod fails (and why it doesn't matter for fields)
Il2CppDumper with `DumpMethod=true` prints `GetMethodPointer IndexOutOfRange` for nearly every Assembly-CSharp type and truncates `dump.cs` to 49KB (141 types). With `DumpMethod=false`, dump succeeds fully (32MB, 43417 types, all field offsets). Root cause: obfuscated method table / generic method spec indices out of range for this build. Field offsets do not depend on method pointers, so they are trustworthy. Method RVAs (needed for global offset via method xref) must come from IDA/Ghidra instead.

### Files patched (in `ipa_work/patched/`)
- `esp/Core/GameLogic.mm` — full rewrite of offset constants + head/toe Y-scan + comments
- `esp/Core/UnityMath.mm` — `GetNickName` `0x358` → `0x498` only (struct + WorldToScreen + getPositionExt unchanged)
- `esp/drawing_view/esp.mm` — `MainCameraTransform` `0x2B0` → `0x3E8`, player list `0xC8` chain → `0x158` List logic
- `esp/Core/UnityMath.h`, `GameLogic.h`, `MemoryUtils.*`, `esp.h` — copied unchanged (no offset changes needed)

### Runtime verification checklist (on iPhone with TrollStore)
1. `Moudule_Base` ≠ 0 and `getMatchGame` returns valid ptr (after fixing global RVA #1)
2. `NSLog [Flork] Count:` prints > 0 in-match (player list #7 working)
3. `isVaildPtr` never trips for camera/match/localPlayer (#2, #3, #6)
4. Boxes track enemies, disappear behind walls are NOT expected (no visibility check in original — expected)
5. Check `CurHP/MaxHP` via existing `get_CurHP/get_MaxHP` (unused in current render path — wire up if you want HP bars)
6. If head/toe boxes are too tall/short, tune Y-scan: head should be ~1.7m above toe; crouch should shrink box height

### dump.cs location
Full dump (32MB) at `ipa_work/dump_out/dump.cs` — grep `TypeDefIndex: 31767` for Player, `12379` for GameFacade, `32076` for Match, `36245` for ReplicationEntity.
