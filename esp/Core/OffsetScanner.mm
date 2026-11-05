#import "OffsetScanner.h"
#import "DebugLogger.h"
#import "MemoryUtils.h"
#import "GameLogic.h"
#import "AOBScanner.h"
#include <mach/mach.h>
#include <initializer_list>
#include <math.h>

// --- small helpers (forward decls from GameLogic.h) ---
// getMatch / CameraMain / getLocalPlayer / GetViewMatrix are already declared there.

static bool ESPIsPlausibleObject(uint64_t ptr) {
    return isVaildPtr((long)ptr);
}

static bool ESPMatrixLooksValid(float *m) {
    if (!m) return false;
    // View-projection matrix: all finite, last row not all zero, |m[15]| sane.
    // Tightened 2026-11-05: false positive had m[1]=1.7e22, m[3]=1.8e31, m[15]=7.2e31 —
    // finite and nonzero, so old check passed. Real view-proj entries are bounded:
    // rotation ~[-2,2], translation up to ~1e5 for Free Fire maps.
    for (int i = 0; i < 16; i++) {
        if (isnan(m[i]) || isinf(m[i])) return false;
        if (fabsf(m[i]) > 1e6f) return false;
    }
    if (fabsf(m[15]) < 0.001f) return false; // w row should be ~1 for perspective
    return true;
}

extern "C" ESPChainSnapshot ESPProbeChain(uint64_t moduleBase, uint64_t globalRVA) {
    ESPChainSnapshot s{}; s.moduleBase = moduleBase;
    ESP_LOG_INFO(@"[PROBE] start moduleBase=0x%llx globalRVA=0x%llx",
        (unsigned long long)moduleBase, (unsigned long long)globalRVA);
    auto T0 = ESPScopedTimerBegin("ESPProbeChain", YES);

    s.typeInfo = ReadAddr<uint64_t>(moduleBase + globalRVA);
    ESP_LOG_DEBUG(@"[PROBE] TypeInfo @0x%llx = 0x%llx valid=%d",
        (unsigned long long)(moduleBase+globalRVA), (unsigned long long)s.typeInfo,
        ESPIsPlausibleObject(s.typeInfo));
    if (!ESPIsPlausibleObject(s.typeInfo)) { ESP_LOG_ERROR(@"[PROBE] FAIL stage=TypeInfo"); goto done; }

    s.staticBlock = ReadAddr<uint64_t>(s.typeInfo + 0xB8);
    ESP_LOG_DEBUG(@"[PROBE] StaticBlock @TypeInfo+0xB8 = 0x%llx valid=%d",
        (unsigned long long)s.staticBlock, ESPIsPlausibleObject(s.staticBlock));
    if (!ESPIsPlausibleObject(s.staticBlock)) { ESP_LOG_ERROR(@"[PROBE] FAIL stage=StaticBlock"); goto done; }

    s.matchGame = ReadAddr<uint64_t>(s.staticBlock + 0x8); // CurrentMatchGame (was +0x0 pre-1.132)
    ESP_LOG_DEBUG(@"[PROBE] MatchGame @Static+0x8 = 0x%llx valid=%d",
        (unsigned long long)s.matchGame, ESPIsPlausibleObject(s.matchGame));
    if (!ESPIsPlausibleObject(s.matchGame)) { ESP_LOG_ERROR(@"[PROBE] FAIL stage=MatchGame"); goto done; }

    s.match = getMatch(s.matchGame); // +0x90
    ESP_LOG_DEBUG(@"[PROBE] Match @MatchGame+0x90 = 0x%llx valid=%d",
        (unsigned long long)s.match, ESPIsPlausibleObject(s.match));
    if (!ESPIsPlausibleObject(s.match)) { ESP_LOG_ERROR(@"[PROBE] FAIL stage=Match"); goto done; }

    s.camMgr = ReadAddr<uint64_t>(s.matchGame + 0xD8);
    ESP_LOG_DEBUG(@"[PROBE] CameraMgr @MatchGame+0xD8 = 0x%llx valid=%d",
        (unsigned long long)s.camMgr, ESPIsPlausibleObject(s.camMgr));
    s.camera = s.camMgr ? CameraMain(s.matchGame) : 0; // +0x20
    ESP_LOG_DEBUG(@"[PROBE] Camera @CamMgr+0x20 = 0x%llx valid=%d",
        (unsigned long long)s.camera, ESPIsPlausibleObject(s.camera));
    s.cameraOk = ESPIsPlausibleObject(s.camera);

    s.localPlayer = getLocalPlayer(s.match); // +0xD8
    ESP_LOG_DEBUG(@"[PROBE] LocalPlayer @Match+0xD8 = 0x%llx valid=%d",
        (unsigned long long)s.localPlayer, ESPIsPlausibleObject(s.localPlayer));
    if (!ESPIsPlausibleObject(s.localPlayer)) { ESP_LOG_ERROR(@"[PROBE] FAIL stage=LocalPlayer"); goto done; }

    // Player list: 0x158 primary, 0x160 fallback, 0x570 third candidate.
    // dump.cs Match (JMAGGLCNGIG) has THREE List<Player> fields: 0x158, 0x160,
    // and DNCDEEJNHIA at 0x570. Log #8 showed 0x158/0x160 null in-match;
    // 0x570 was never tried (dump loop capped at 0x300). Also: List size check
    // relaxed — a freshly-spawned match may have size 0 legitimately; array
    // length alone decides list plausibility.
    s.listOk = false;
    for (uint64_t listOff : { (uint64_t)0x158, (uint64_t)0x160, (uint64_t)0x570 }) {
        uint64_t lo = ReadAddr<uint64_t>(s.match + listOff);
        if (!ESPIsPlausibleObject(lo)) continue;
        uint64_t arr = ReadAddr<uint64_t>(lo + 0x10);
        if (!ESPIsPlausibleObject(arr)) {
            // List object with null _items (possible when empty) — treat as ok
            // only if _size also plausible (0..200). Log for diagnosis.
            int sz0 = ReadAddr<int>(lo + 0x18);
            ESP_LOG_DEBUG(@"[PROBE] List@0x%llx obj=0x%llx _items NULL size=%d (empty list? accepted as candidate)",
                (unsigned long long)listOff, (unsigned long long)lo, sz0);
            if (sz0 < 0 || sz0 > 1000) continue;
            s.listObj = lo; s.itemsArray = 0; s.playerCount = 0;
            s.listOk = true;
            ESP_LOG_INFO(@"[PROBE] List@0x%llx EMPTY (items null, size=%d) — count 0 but listOk=1", (unsigned long long)listOff, sz0);
            break;
        }
        int sz = ReadAddr<int>(lo + 0x18);
        int alen = ReadAddr<int>(arr + 0x18);
        ESP_LOG_DEBUG(@"[PROBE] List@0x%llx obj=0x%llx size=%d arr=0x%llx arrLen=%d",
            (unsigned long long)listOff, (unsigned long long)lo, sz,
            (unsigned long long)arr, alen);
        if (alen <= 0 || alen > 500) continue;
        s.listObj = lo; s.itemsArray = arr; s.playerCount = (alen > 0 && alen < sz) ? alen : sz;
        s.listOk = true;
        break;
    }
    if (!s.listOk) ESP_LOG_WARN(@"[PROBE] player list not found (tried 0x158, 0x160, 0x570)");

    // Diagnostic: dump raw qwords at key objects when camera/list missing in-match,
    // so the true camera/list offsets can be read off the log (log 2026-11-05 #6:
    // chain stable (MatchGame/Match/LocalPlayer) but camera 0x0 and list empty even
    // minutes into the session; offsets verified in dump.cs, so objects may be
    // different instances — dump neighbourhoods to locate the real fields).
    // NOTE: s.mainOk is computed AFTER this block (line ~139) — use direct checks here.
    if (ESPIsPlausibleObject(s.matchGame) && ESPIsPlausibleObject(s.localPlayer) && (!s.cameraOk || !s.listOk)) {
        ESP_LOG_INFO(@"[DUMP] --- Match 0x%llx ---", (unsigned long long)s.match);
        for (uint64_t o = 0x10; o <= 0x600; o += 8) {
            uint64_t v = ReadAddr<uint64_t>(s.match + o);
            if (ESPIsPlausibleObject(v)) {
                int sz18 = 0;
                uint64_t arr = ReadAddr<uint64_t>(v + 0x10);
                if (ESPIsPlausibleObject(arr)) sz18 = ReadAddr<int>(arr + 0x18);
                ESP_LOG_INFO(@"[DUMP] Match+0x%llx = 0x%llx (asList? arr=0x%llx arrLen=%d)",
                    (unsigned long long)o, (unsigned long long)v,
                    (unsigned long long)arr, sz18);
            }
        }
        ESP_LOG_INFO(@"[DUMP] --- MatchGame 0x%llx (camera candidates) ---", (unsigned long long)s.matchGame);
        for (uint64_t o = 0x10; o <= 0x300; o += 8) {
            uint64_t v = ReadAddr<uint64_t>(s.matchGame + o);
            if (!ESPIsPlausibleObject(v)) continue;
            uint64_t m20 = ReadAddr<uint64_t>(v + 0x20);
            uint64_t m28 = ReadAddr<uint64_t>(v + 0x28);
            // Content test: either entry yields a camera whose view matrix is valid.
            uint64_t camCand = 0;
            if (ESPIsPlausibleObject(m20)) {
                float *x = GetViewMatrix(m20);
                if (ESPMatrixLooksValid(x)) camCand = m20;
            }
            if (!camCand && ESPIsPlausibleObject(m28)) {
                float *x = GetViewMatrix(m28);
                if (ESPMatrixLooksValid(x)) camCand = m28;
            }
            if (ESPIsPlausibleObject(m20) || ESPIsPlausibleObject(m28)) {
                ESP_LOG_INFO(@"[DUMP] MatchGame+0x%llx = 0x%llx (+0x20=0x%llx +0x28=0x%llx) %s",
                    (unsigned long long)o, (unsigned long long)v,
                    (unsigned long long)m20, (unsigned long long)m28,
                    camCand ? [NSString stringWithFormat:@"*** CAMERA FOUND @0x%llx (matrix valid)", (unsigned long long)camCand] : @"");
            }
        }
        ESP_LOG_INFO(@"[DUMP] --- CameraMgr 0x%llx ---", (unsigned long long)s.camMgr);
        if (ESPIsPlausibleObject(s.camMgr)) {
            for (uint64_t o = 0x10; o <= 0x100; o += 8) {
                uint64_t v = ReadAddr<uint64_t>(s.camMgr + o);
                if (ESPIsPlausibleObject(v)) {
                    ESP_LOG_INFO(@"[DUMP] CamMgr+0x%llx = 0x%llx", (unsigned long long)o, (unsigned long long)v);
                }
            }
        }
    }

    // Camera matrix sanity
    if (s.cameraOk) {
        float *m = GetViewMatrix(s.camera);
        s.matrixValid = ESPMatrixLooksValid(m);
        ESP_LOG_DEBUG(@"[PROBE] matrix valid=%d m[0..3]=%f %f %f %f m[15]=%f",
            s.matrixValid, m[0], m[1], m[2], m[3], m[15]);
    }

    s.mainOk = ESPIsPlausibleObject(s.matchGame) && ESPIsPlausibleObject(s.localPlayer);
    ESP_LOG_INFO(@"[PROBE] done mainOk=%d listOk=%d cameraOk=%d matrixValid=%d players=%d",
        s.mainOk, s.listOk, s.cameraOk, s.matrixValid, s.playerCount);
done:
    ESPScopedTimerEnd(&T0);
    return s;
}

extern "C" uint64_t ESPFindGameFacadeGlobal(uint64_t moduleBase, const uint64_t *candidates, size_t count) {
    ESP_LOG_INFO(@"[HEAL] trying %zu GameFacade global candidates", count);
    for (size_t i = 0; i < count; i++) {
        uint64_t rva = candidates[i];
        uint64_t ti = ReadAddr<uint64_t>(moduleBase + rva);
        if (!ESPIsPlausibleObject(ti)) { ESP_LOG_DEBUG(@"[HEAL] cand[%zu] 0x%llx TypeInfo invalid", i, (unsigned long long)rva); continue; }
        uint64_t sb = ReadAddr<uint64_t>(ti + 0xB8);
        if (!ESPIsPlausibleObject(sb)) { ESP_LOG_DEBUG(@"[HEAL] cand[%zu] StaticBlock invalid", i); continue; }
        uint64_t mg = ReadAddr<uint64_t>(sb + 0x8);
        if (!ESPIsPlausibleObject(mg)) { ESP_LOG_DEBUG(@"[HEAL] cand[%zu] MatchGame invalid", i); continue; }
        uint64_t m = ReadAddr<uint64_t>(mg + 0x90);
        uint64_t cm = ReadAddr<uint64_t>(mg + 0xD8);
        if (!ESPIsPlausibleObject(m) || !ESPIsPlausibleObject(cm)) {
            ESP_LOG_DEBUG(@"[HEAL] cand[%zu] Match/CamMgr invalid", i); continue;
        }
        // Full-chain validation (log 2026-11-05 false positive 0x1047b8 passed the shallow checks).
        // Require LocalPlayer plausibility + camera matrix sanity to accept.
        uint64_t lp = getLocalPlayer(m);
        if (!ESPIsPlausibleObject(lp)) {
            ESP_LOG_DEBUG(@"[HEAL] cand[%zu] 0x%llx LocalPlayer invalid (lp=0x%llx) — rejecting",
                i, (unsigned long long)rva, (unsigned long long)lp);
            continue;
        }
        uint64_t cam = CameraMain(mg);
        if (ESPIsPlausibleObject(cam)) {
            float *mx = GetViewMatrix(cam);
            if (ESPMatrixLooksValid(mx)) {
                ESP_LOG_INFO(@"[HEAL] found GameFacade global RVA=0x%llx (candidate %zu, LocalPlayer+matrix OK)", (unsigned long long)rva, i);
                return rva;
            }
            ESP_LOG_DEBUG(@"[HEAL] cand[%zu] matrix invalid — rejecting", i);
            continue;
        }
        ESP_LOG_INFO(@"[HEAL] found GameFacade global RVA=0x%llx (candidate %zu, LocalPlayer OK)", (unsigned long long)rva, i);
        return rva;
    }
    ESP_LOG_WARN(@"[HEAL] no candidate matched");
    return 0;
}

extern "C" uint64_t ESPScanGameFacadeStatic(uint64_t moduleBase, uint64_t searchSize) {
    // Strategy: find TypeInfo by scanning __DATA for a pointer whose +0xB8
    // points to a static block whose +0x8 yields a valid MatchGame.
    // Full pointer scan is O(N) reads; cap to first 256MB of module (DATA-heavy area).
    // NOTE: This is a best-effort fallback — prefer ESPFindGameFacadeGlobal with
    // known RVAs from dump.cs of the exact build. AOB on code (get_CurrentMatchGame)
    // needs a byte-pattern from IDA and is more precise; see AUTO_SCAN.md.
    //
    // Mach-O 1.132.1 UnityFramework: __TEXT = 0x0-0xB1C8000, __DATA = 0xB1C8000-0xC388000
    // (verified from LoadCommands). Real globals (TypeInfo ptr) live in __DATA.
    // Log 2026-11-05: scanning from moduleBase found __TEXT literal-pool false
    // positives (+0x1047b8, +0x252d1d8 volatile heap data that changed within seconds,
    // garbage camera 0x14FFFFFFFF / matrix 1e22 and 1e31) and returned before
    // ever reaching __DATA. Restrict to __DATA.
    const uint64_t kDataStartRVA = 0xB1C8000;
    const uint64_t kDataEndRVA = 0xC388000; // == __DATA vmaddr+vmsize (0xB1C8000+0x11C0000)
    uint64_t scanStart = moduleBase + kDataStartRVA;
    uint64_t dataEnd = moduleBase + kDataEndRVA;
    uint64_t end = moduleBase + searchSize;
    if (end > dataEnd) {
        end = dataEnd;
        ESP_LOG_INFO(@"[SCAN] narrowing scan to __DATA [0x%llx, 0x%llx) (searchSize capped)",
            (unsigned long long)kDataStartRVA, (unsigned long long)kDataEndRVA);
    }
    ESP_LOG_INFO(@"[SCAN] GameFacade static-block pointer scan start base=0x%llx DATA=[0x%llx, 0x%llx)",
        (unsigned long long)moduleBase, (unsigned long long)scanStart, (unsigned long long)end);
    mach_port_t task = ESPGetTargetTask(); // via accessor (header static is per-TU)
    if (task == MACH_PORT_NULL) { ESP_LOG_ERROR(@"[SCAN] null task — GetGameModule_Base not yet called?"); return 0; }
    const uint64_t chunk = 1 << 20; // 1MB
    std::vector<uint64_t> chunkBuf(chunk / 8);
    for (uint64_t cur = scanStart; cur < end; cur += chunk) {
        uint64_t toRead = end - cur; if (toRead > chunk) toRead = chunk;
        vm_size_t sz = 0;
        kern_return_t kr = vm_read_overwrite(task, (vm_address_t)cur,
                                             (vm_size_t)toRead, (vm_address_t)chunkBuf.data(), &sz);
        if (kr != KERN_SUCCESS || sz == 0) continue;
        size_t n = (size_t)sz / 8;
        for (size_t i = 0; i < n; i++) {
            uint64_t candTypeInfo = chunkBuf[i];
            if (!ESPIsPlausibleObject(candTypeInfo)) continue;
            uint64_t sb = ReadAddr<uint64_t>(candTypeInfo + 0xB8);
            if (!ESPIsPlausibleObject(sb)) continue;
            uint64_t mg = ReadAddr<uint64_t>(sb + 0x8);
            if (!ESPIsPlausibleObject(mg)) continue;
            uint64_t m = ReadAddr<uint64_t>(mg + 0x90);
            if (!ESPIsPlausibleObject(m)) continue;
            if (!ESPIsPlausibleObject(ReadAddr<uint64_t>(mg + 0xD8))) continue;
            // Full-chain validation + continue scanning on failure (was: return first shallow hit).
            // Log 2026-11-05: shallow hit at +0x1047b8 was a TEXT literal-pool false positive
            // (StaticBlock==MatchGame==0x2c000000f garbage, Camera=0x14FFFFFFFF poison).
            uint64_t lp = getLocalPlayer(m);
            if (!ESPIsPlausibleObject(lp)) {
                ESP_LOG_DEBUG(@"[SCAN] shallow hit 0x%llx rejected (LocalPlayer=0x%llx)",
                    (unsigned long long)((cur + i * 8) - moduleBase), (unsigned long long)lp);
                continue;
            }
            uint64_t cam = CameraMain(mg);
            if (ESPIsPlausibleObject(cam)) {
                float *mx = GetViewMatrix(cam);
                if (!ESPMatrixLooksValid(mx)) {
                    ESP_LOG_DEBUG(@"[SCAN] shallow hit 0x%llx rejected (matrix invalid)",
                        (unsigned long long)((cur + i * 8) - moduleBase));
                    continue;
                }
            }
            uint64_t rva = (cur + i * 8) - moduleBase;
            ESP_LOG_INFO(@"[SCAN] found TypeInfo RVA=0x%llx (mem 0x%llx, full-chain OK)",
                (unsigned long long)rva, (unsigned long long)(cur + i * 8));
            return rva;
        }
        ESP_LOG_DEBUG_THROTTLED(@"[SCAN] scanned to 0x%llx", (unsigned long long)(cur + chunk));
    }
    ESP_LOG_WARN(@"[SCAN] GameFacade static-block not found in range");
    return 0;
}

// Bone identification is implemented in GameLogic.mm via getPositionExt which
// needs full UnityMath; this stub logs and defers to FindBoneByY there.
// Kept for API symmetry / future use.
extern "C" bool ESPIdentifyBones(uint64_t player, int *headOffset, int *toeOffset) {
    ESP_LOG_INFO(@"[BONES] ESPIdentifyBones player=0x%llx — see FindBoneByY in GameLogic.mm for Y-scan",
        (unsigned long long)player);
    // Actual scan runs inside getHead()/getRightToeNode() (they log winner).
    (void)headOffset; (void)toeOffset;
    return true;
}
