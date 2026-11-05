#ifndef GameLogic_h
#define GameLogic_h

#import "MemoryUtils.h"
#import "UnityMath.h"
#import "DebugLogger.h"
#import "OffsetScanner.h"

#pragma mark - Global RVA (healable at runtime)

// Current best RVA for GameFacade TypeInfo (Module_Base + RVA -> TypeInfo).
// OLD value 0x9985B70 is INVALID for 1.132.1. Set to 0 to trigger auto-heal
// (ESPFindGameFacadeGlobal + ESPScanGameFacadeStatic on first probe failure).
// To heal: put candidate RVAs from dump.cs of the exact build here, or let the
// scanner find it (ESPProbeChain -> ESPScanGameFacadeStatic).
extern uint64_t gGameFacadeGlobalRVA; // defined in GameLogic.mm, default 0x9985B70 (old)

// Candidate RVAs tried by the healer before falling back to pointer scan.
// Add new builds' RVAs here as they are discovered.
extern const uint64_t kGameFacadeCandidates[];
extern const size_t kGameFacadeCandidatesCount;

#pragma mark - Function Game

uint64_t getMatchGame(uint64_t Moudule_Base);
uint64_t getMatch(uint64_t matchgame);
uint64_t CameraMain(uint64_t matchgame);
float* GetViewMatrix(uint64_t cameraMain);
uint64_t getTransNode(uint64_t BodyPart);
uint64_t getHead(uint64_t player);
uint64_t getRightToeNode(uint64_t player);
uint64_t getLocalPlayer(uint64_t match);
int GetDataUInt16(uint64_t player, int varID);
int get_CurHP(uint64_t Player);
int get_MaxHP(uint64_t Player);
bool isLocalTeamMate(uint64_t localPlayer, uint64_t Player);

#endif
