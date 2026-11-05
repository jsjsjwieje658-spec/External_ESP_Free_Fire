// OffsetScanner.h — runtime offset validation + auto re-discovery (heal) layer.
// Probes every pointer in the ESP chain, logs each hop, and when a hop fails
// tries documented fallback offsets (from dump.cs of newer builds) before
// declaring the chain dead. Also provides a brute-force fallback for the
// GameFacade global when the hardcoded RVA goes stale (common after update).
#ifndef OffsetScanner_h
#define OffsetScanner_h

#include <stdint.h>
#include <stddef.h>
#include <vector>

#ifdef __cplusplus
extern "C" {
#endif

struct ESPChainSnapshot {
    uint64_t moduleBase;
    uint64_t typeInfo;
    uint64_t staticBlock;
    uint64_t matchGame;
    uint64_t camMgr;
    uint64_t camera;
    uint64_t match;
    uint64_t localPlayer;
    uint64_t listObj;
    uint64_t itemsArray;
    int playerCount;
    bool mainOk;          // core chain (game->match->local) valid
    bool listOk;          // player list valid
    bool cameraOk;        // camera + matrix valid
    bool matrixValid;
};

// Validate full chain with current offsets. Logs every hop. Returns snapshot;
// check snapshot.mainOk/listOk/cameraOk to decide fallback strategy.
ESPChainSnapshot ESPProbeChain(uint64_t moduleBase, uint64_t globalRVA);

// Try fallback GameFacade global RVAs (history across builds). Each candidate
// is validated: TypeInfo->+0xB8->+0x8 must yield a plausible MatchGame whose
// +0x90 (Match) and +0xD8 (CameraMgr) look like objects. Returns 0 if none.
uint64_t ESPFindGameFacadeGlobal(uint64_t moduleBase, const uint64_t *candidates, size_t count);

// AOB fallback for GameFacade when RVA list is exhausted: finds TypeInfo via
// pointer scan for the static-block signature. See .mm for method.
// `searchSize` is bytes to scan from moduleBase (default: 200MB UnityFramework).
uint64_t ESPScanGameFacadeStatic(uint64_t moduleBase, uint64_t searchSize);

// Bone auto-identification: scan ITransformNode candidates, log all Y positions,
// pick head (max Y) / toe (min Y). Returns world pos for chosen bone (and logs
// the winning offset so it can be hardcoded later).
struct ESPBoneResult { uint64_t transNode; float y; int offset; };
// Forward-declare Vector3 dependency via GameLogic.h inclusion in .mm.
// Exposed here as plain function taking player ptr, returning offset via out param.
bool ESPIdentifyBones(uint64_t player, int *headOffset, int *toeOffset);

#ifdef __cplusplus
}
#endif

#endif
