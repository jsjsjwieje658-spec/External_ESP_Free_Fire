#import "GameLogic.h"
#include <math.h>

// ============================================================================
// UPDATED OFFSETS for Free Fire TH 1.132.1 (iOS, UnityFramework)
// Source: Il2CppDumper dump.cs from com.dts.freefireth_1.132.1_decrypted.ipa
//   - global-metadata.dat (55MB, metadata v31)
//   - UnityFramework (199MB, Mach-O arm64)
//   - dump.cs (32MB, 43417 TypeDefs, fields-only mode)
// Date: 2026-11-05
// ============================================================================
// CLASS HIERARCHY (confirmed):
//   GameFacade (TypeDef 12379, COW) - static fields
//   MatchGame : COWGameBase (12386)
//     m_Match : JMAGGLCNGIG = Match (32076) at 0x90
//   Player : AttackableEntity (31854) : COWReplicationEntity (31855)
//            : ReplicationEntity (36245) : Entity (36241) : MonoBehaviour
//   CameraControllerManager : MonoBehaviour (31945)
// ============================================================================
// CHANGES vs original source (old version, unknown build):
//   [1] GameFacade.CurrentMatchGame static offset: 0x0 -> 0x8 (now 2nd static field)
//       Global RVA 0x9985B70 INVALID (points into __text in new binary).
//       AUTO-HEAL: gGameFacadeGlobalRVA starts at 0x9985B70 (legacy) — on first
//       probe failure ESPProbeChain triggers ESPFindGameFacadeGlobal(candidates)
//       then ESPScanGameFacadeStatic pointer scan. See AUTO_SCAN.md.
//   [2] MatchGame.m_Match: 0x90 KEEP
//   [3] MatchGame.m_CameraControllerManager: 0xD8 KEEP
//   [4] CameraControllerManager.Camera: 0x18 -> 0x20 (EKIPKGNKILM at 0x20)
//   [5] Camera view matrix (0x10 / 0xD8): KEEP (native Unity internals, stable)
//   [6] Match.LocalPlayer: 0x58 -> 0xD8 (MHJCLOPOBAA Player at 0xD8 in JMAGGLCNGIG)
//   [7] Match player list: OLD 0xC8 chain BROKEN -> NEW Match+0x158 List<Player>
//       (see esp.mm update_data for new enumeration logic)
//   [8] Player.MainCameraTransform: 0x2B0 -> 0x3E8 (confirmed in dump.cs)
//   [9] Player.PlayerID: 0x2D0 -> 0x408 (MHGFKKALMDK BEADLMGGGGL at 0x408)
//       BEADLMGGGGL struct (TypeDef 34508, = old COW_GamePlay_PlayerID_o):
//         EOKFPKOEDDJ uint  0x0, DDJGLLGPBJD uint 0x4,
//         JLIDCJLKLBD byte  0x8 (TeamID - first byte field), JHHPHPJMFNG byte 0x9, IKNFINCJNLH ulong 0x10
//   [10] ReplicationEntity.m_PRIDataPool: 0x68 -> 0x70 (m_IsPRIRecivedFirstTime inserted at 0x68)
//   [11] Player.OriginalNickName: 0x358 -> 0x498 (string field at 0x498)
//   [12] Player.Head bone: 0x550 INVALID (now Quaternion GHPHCGIIHON at 0x550)
//        -> Must scan ITransformNode fields (0x698+) - see getHead() below
//   [13] Player.RightToe: 0x5A0 INVALID (now ResourceID DPGLODLEAIC at 0x5A0)
//        -> Must scan ITransformNode fields (0x698+) - see getRightToeNode() below
//   [14] Transform internals (0x10 / 0x38 / 0x40 / 0x18 / 0x20): KEEP (Unity stable)
// ============================================================================
// DEBUG: every public function now logs entry/exit + pointer validity at DEBUG,
// and ERROR at stage failure. Per-frame paths use THROTTLED logs to avoid syslog
// flood. Set log level to DEBUG via ESPSetLogLevel(ESPLogLevelDebug) in esp.mm init.
// ============================================================================

#pragma mark - Global RVA state

uint64_t gGameFacadeGlobalRVA = 0x9985B70; // legacy default; healer updates on failure

// Candidate RVAs to try when the primary fails. EMPTY for now — populate from
// IDA/Ghidra once the 1.132.1 TypeInfo RVA is found (see AUTO_SCAN.md).
// Example: { 0x9AABBCC, 0x11223344 }.
const uint64_t kGameFacadeCandidates[] = {
    // PLACEHOLDER: add discovered RVAs here, newest first.
};
const size_t kGameFacadeCandidatesCount = sizeof(kGameFacadeCandidates)/sizeof(uint64_t);

#pragma mark - Function Game

uint64_t getMatchGame(uint64_t Moudule_Base) {
    if (!isVaildPtr((long)Moudule_Base)) {
        ESP_LOG_ERROR(@"[GameLogic] getMatchGame: invalid Module_Base=0x%llx", (unsigned long long)Moudule_Base);
        return 0;
    }
    ESP_LOG_DEBUG_THROTTLED(@"[GameLogic] getMatchGame base=0x%llx rva=0x%llx",
        (unsigned long long)Moudule_Base, (unsigned long long)gGameFacadeGlobalRVA);
    uint64_t GameFacade_TypeInfo = ReadAddr<uint64_t>(Moudule_Base + gGameFacadeGlobalRVA);
    ESP_LOG_DEBUG(@"[GameLogic] TypeInfo @0x%llx = 0x%llx valid=%d",
        (unsigned long long)(Moudule_Base+gGameFacadeGlobalRVA),
        (unsigned long long)GameFacade_TypeInfo, isVaildPtr((long)GameFacade_TypeInfo));
    if (!isVaildPtr((long)GameFacade_TypeInfo)) {
        ESP_LOG_ERROR(@"[GameLogic] getMatchGame: TypeInfo invalid — global RVA 0x%llx stale? Trigger heal.",
            (unsigned long long)gGameFacadeGlobalRVA);
        return 0;
    }
    uint64_t GameFacade_Static = ReadAddr<uint64_t>(GameFacade_TypeInfo + 0xB8);
    ESP_LOG_DEBUG(@"[GameLogic] StaticBlock = 0x%llx valid=%d", (unsigned long long)GameFacade_Static, isVaildPtr((long)GameFacade_Static));
    if (!isVaildPtr((long)GameFacade_Static)) {
        ESP_LOG_ERROR(@"[GameLogic] getMatchGame: StaticBlock invalid (TypeInfo+0xB8)");
        return 0;
    }
    uint64_t result = ReadAddr<uint64_t>(GameFacade_Static + 0x8); // CHANGED: 0x0 -> 0x8
    ESP_LOG_DEBUG(@"[GameLogic] MatchGame @Static+0x8 = 0x%llx valid=%d",
        (unsigned long long)result, isVaildPtr((long)result));
    if (!isVaildPtr((long)result)) {
        ESP_LOG_ERROR(@"[GameLogic] getMatchGame: MatchGame invalid (Static+0x8) — try Static+0x0 fallback");
        // Fallback: some builds still use +0x0 (CurrentGame). Log only; caller will heal.
    }
    return result;
}

uint64_t getMatch(uint64_t matchgame) {
    if (!isVaildPtr((long)matchgame)) { ESP_LOG_ERROR(@"[GameLogic] getMatch: invalid matchgame=0x%llx", (unsigned long long)matchgame); return 0; }
    uint64_t result = ReadAddr<uint64_t>(matchgame + 0x90); // UNCHANGED
    ESP_LOG_DEBUG_THROTTLED(@"[GameLogic] Match @MatchGame+0x90 = 0x%llx valid=%d",
        (unsigned long long)result, isVaildPtr((long)result));
    if (!isVaildPtr((long)result)) ESP_LOG_ERROR(@"[GameLogic] getMatch failed");
    return result;
}

uint64_t CameraMain(uint64_t matchgame) {
    if (!isVaildPtr((long)matchgame)) { ESP_LOG_ERROR(@"[GameLogic] CameraMain: invalid matchgame"); return 0; }
    uint64_t CameraControllerManager = ReadAddr<uint64_t>(matchgame + 0xD8); // UNCHANGED
    ESP_LOG_DEBUG_THROTTLED(@"[GameLogic] CameraMgr = 0x%llx valid=%d",
        (unsigned long long)CameraControllerManager, isVaildPtr((long)CameraControllerManager));
    if (!isVaildPtr((long)CameraControllerManager)) { ESP_LOG_ERROR(@"[GameLogic] CameraMain: CameraMgr invalid"); return 0; }
    // CHANGED: 0x18 -> 0x20 (CameraControllerManager.EKIPKGNKILM Camera at 0x20)
    uint64_t cam = ReadAddr<uint64_t>(CameraControllerManager + 0x20);
    ESP_LOG_DEBUG_THROTTLED(@"[GameLogic] Camera @Mgr+0x20 = 0x%llx valid=%d",
        (unsigned long long)cam, isVaildPtr((long)cam));
    if (!isVaildPtr((long)cam)) {
        ESP_LOG_WARN(@"[GameLogic] CameraMain: +0x20 invalid, trying backup +0x28 (LBHAFMEPGCO)");
        cam = ReadAddr<uint64_t>(CameraControllerManager + 0x28);
        ESP_LOG_WARN(@"[GameLogic] CameraMain backup +0x28 = 0x%llx valid=%d", (unsigned long long)cam, isVaildPtr((long)cam));
    }
    return cam;
}

float* GetViewMatrix(uint64_t cameraMain) {
    if (!isVaildPtr((long)cameraMain)) { ESP_LOG_ERROR(@"[GameLogic] GetViewMatrix: invalid camera"); static float zero[16] = {0}; return zero; }
    uint64_t v1 = ReadAddr<uint64_t>(cameraMain + 0x10); // native ptr - UNCHANGED
    ESP_LOG_DEBUG_THROTTLED(@"[GameLogic] ViewMatrix native=0x%llx valid=%d",
        (unsigned long long)v1, isVaildPtr((long)v1));
    if (!isVaildPtr((long)v1)) { ESP_LOG_ERROR(@"[GameLogic] GetViewMatrix: native ptr invalid"); static float zero[16] = {0}; return zero; }
    static float matrix[16];
    for (int i = 0; i < 16; i++) {
        matrix[i] = ReadAddr<float>(v1 + 0xD8 + i * 0x4); // UNCHANGED
    }
    ESP_LOG_DEBUG_THROTTLED(@"[GameLogic] matrix[0]=%f [5]=%f [10]=%f [15]=%f",
        matrix[0], matrix[5], matrix[10], matrix[15]);
    return matrix;
}

uint64_t getTransNode(uint64_t BodyPart) {
    if (!isVaildPtr((long)BodyPart)) return 0;
    uint64_t result = ReadAddr<uint64_t>(BodyPart + 0x10); // UNCHANGED
    return result;
}

// ============================================================================
// HEAD / TOE BONES - OBFUSCATED, NEED RUNTIME IDENTIFICATION
// (see header comment: old 0x550/0x5A0 invalid, scan ITransformNodes 0x698+)
// ============================================================================

// Candidate ITransformNode offsets in Player (from dump.cs, TypeDef 31767)
// Only first block is listed; full list extends to 0x2178+.
static const int kITransformNodeOffsets[] = {
    0x698, 0x6A0, 0x6A8, 0x6B0, 0x6B8, 0x6C0, 0x6C8, 0x6D0,
    0x6D8, 0x6E0, 0x6E8, 0x6F0, 0x6F8, 0x708, 0x710, 0x718,
    0x720, 0x728, 0x730,
};
static const int kITransformNodeCount = sizeof(kITransformNodeOffsets)/sizeof(int);

// Helper: find bone with max/min Y among candidates (world space via getPositionExt)
static uint64_t FindBoneByY(uint64_t player, bool wantMax, int *outOffset) {
    float bestY = wantMax ? -1e9f : 1e9f;
    uint64_t bestNode = 0;
    int bestOff = 0;
    int validCount = 0;
    for (int i = 0; i < kITransformNodeCount; i++) {
        uint64_t node = ReadAddr<uint64_t>(player + kITransformNodeOffsets[i]);
        if (!isVaildPtr((long)node)) continue;
        uint64_t trans = getTransNode(node); // +0x10 (same as old BodyPart->Transform)
        if (!isVaildPtr((long)trans)) continue;
        Vector3 pos = getPositionExt(trans);
        // Filter implausible positions (NaN, huge)
        if (pos.x != pos.x || pos.y != pos.y || pos.z != pos.z) continue;
        if (fabsf(pos.x) > 10000 || fabsf(pos.y) > 10000 || fabsf(pos.z) > 10000) continue;
        validCount++;
        // Verbose per-bone log at DEBUG so you can identify head/toe manually.
        // Throttled by ESP_LOG_DEBUG_THROTTLED semantics in practice (called per-frame per-player,
        // but only logs winner summary below — per-candidate lines are DEBUG and will flood,
        // so we log them only when playerCount small or on first frames. Use direct DEBUG for now;
        // filter with log level in production.)
        ESP_LOG_DEBUG(@"[BONES] player=0x%llx cand[%d] off=0x%x node=0x%llx pos=(%.2f,%.2f,%.2f)",
            (unsigned long long)player, i, kITransformNodeOffsets[i], (unsigned long long)node,
            pos.x, pos.y, pos.z);
        if (wantMax ? (pos.y > bestY) : (pos.y < bestY)) {
            bestY = pos.y;
            bestNode = node;
            bestOff = kITransformNodeOffsets[i];
        }
    }
    ESP_LOG_DEBUG(@"[BONES] player=0x%llx wantMax=%d valid=%d/%d winner off=0x%x y=%.2f",
        (unsigned long long)player, wantMax, validCount, kITransformNodeCount, bestOff, bestY);
    if (outOffset) *outOffset = bestOff;
    return bestNode;
}

uint64_t getHead(uint64_t player) {
    if (!isVaildPtr((long)player)) { ESP_LOG_ERROR(@"[BONES] getHead: invalid player"); return 0; }
    int off = 0;
    uint64_t node = FindBoneByY(player, true, &off);
    ESP_LOG_DEBUG_THROTTLED(@"[BONES] getHead player=0x%llx -> node=0x%llx off=0x%x",
        (unsigned long long)player, (unsigned long long)node, off);
    return node ? getTransNode(node) : 0;
}

uint64_t getRightToeNode(uint64_t player) {
    if (!isVaildPtr((long)player)) { ESP_LOG_ERROR(@"[BONES] getRightToe: invalid player"); return 0; }
    int off = 0;
    uint64_t node = FindBoneByY(player, false, &off);
    ESP_LOG_DEBUG_THROTTLED(@"[BONES] getRightToe player=0x%llx -> node=0x%llx off=0x%x",
        (unsigned long long)player, (unsigned long long)node, off);
    return node ? getTransNode(node) : 0;
}

uint64_t getLocalPlayer(uint64_t match) {
    if (!isVaildPtr((long)match)) { ESP_LOG_ERROR(@"[GameLogic] getLocalPlayer: invalid match"); return 0; }
    // CHANGED: 0x58 -> 0xD8 (JMAGGLCNGIG.MHJCLOPOBAA Player at 0xD8)
    uint64_t result = ReadAddr<uint64_t>(match + 0xD8);
    ESP_LOG_DEBUG_THROTTLED(@"[GameLogic] LocalPlayer @Match+0xD8 = 0x%llx valid=%d",
        (unsigned long long)result, isVaildPtr((long)result));
    if (!isVaildPtr((long)result)) ESP_LOG_ERROR(@"[GameLogic] getLocalPlayer failed");
    return result;
}

bool isLocalTeamMate(uint64_t localPlayer, uint64_t Player) {
    // CHANGED: 0x2D0 -> 0x408 (Player.MHGFKKALMDK BEADLMGGGGL at 0x408)
    COW_GamePlay_PlayerID_o myPlayerID = ReadAddr<COW_GamePlay_PlayerID_o>(localPlayer + 0x408);
    COW_GamePlay_PlayerID_o PlayerID = ReadAddr<COW_GamePlay_PlayerID_o>(Player + 0x408);
    
    int myTeamID = myPlayerID.m_TeamID;
    int TeamID = PlayerID.m_TeamID;
    
    ESP_LOG_DEBUG_THROTTLED(@"[GameLogic] team check me=%d other=%d (me=0x%llx p=0x%llx)",
        myTeamID, TeamID, (unsigned long long)localPlayer, (unsigned long long)Player);
    return myTeamID == TeamID;
}

int GetDataUInt16(uint64_t player, int varID) {
    // CHANGED: 0x68 -> 0x70 (ReplicationEntity.m_PRIDataPool at 0x70)
    uint64_t IPRIDataPool = ReadAddr<uint64_t>(player + 0x70);
    ESP_LOG_DEBUG_THROTTLED(@"[GameLogic] IPRIPool player=0x%llx pool=0x%llx valid=%d varID=%d",
        (unsigned long long)player, (unsigned long long)IPRIDataPool, isVaildPtr((long)IPRIDataPool), varID);
    if (isVaildPtr((long)IPRIDataPool)) {
        uint64_t v2 = ReadAddr<uint64_t>(IPRIDataPool + 0x10);
        uint64_t v4 = ReadAddr<uint64_t>(v2 + 0x8 * varID + 0x20);
        int v6 = ReadAddr<int>(v4 + 0x18);
        ESP_LOG_DEBUG_THROTTLED(@"[GameLogic] HP varID=%d pool->0x10=0x%llx ->+0x20+var=0x%llx val=%d",
            varID, (unsigned long long)v2, (unsigned long long)v4, v6);
        return v6;
    }
    ESP_LOG_WARN(@"[GameLogic] GetDataUInt16: pool invalid player=0x%llx", (unsigned long long)player);
    return 0;
}

int get_CurHP(uint64_t Player) {
    return GetDataUInt16(Player, 0);
}

int get_MaxHP(uint64_t Player) {
    return GetDataUInt16(Player, 1);
}
