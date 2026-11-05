#import "esp.h"
#import "../Core/DebugLogger.h"
#import "../Core/MemoryRegions.h"
#import "../Core/AOBScanner.h"

#define sWidth  [UIScreen mainScreen].bounds.size.width
#define sHeight [UIScreen mainScreen].bounds.size.height

@interface ESP_View ()
@property (nonatomic, strong) NSMutableArray<CALayer *> *layers;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) CADisplayLink *displayLinkDATA;
@property (nonatomic, strong) NSArray<NSValue *> *boxesData;
@end

uint64_t Moudule_Base = -1;

@implementation ESP_View

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.layers = [NSMutableArray array];
        self.backgroundColor = [UIColor clearColor];

        // --- Debug logger setup (DEBUG + file mirror) ---
        ESPSetLogLevel(ESPLogLevelDebug); // change to Info in release
        ESPLogToFile(YES); // persist Documents/esp_debug.log (NSHomeDirectory)
        ESP_LOG_INFO(@"[ESP] ESP_View init start screen=%.0fx%.0f", sWidth, sHeight);
        auto Tinit = ESPScopedTimerBegin("ESP_View init", YES);

        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            ESP_LOG_INFO(@"[ESP] resolving module base (once)...");
            Moudule_Base = (uint64_t)GetGameModule_Base((char*)"freefireth");
            ESP_LOG_INFO(@"[ESP] Moudule_Base=0x%llx pid=%d", (unsigned long long)Moudule_Base, ESPGetTargetPid());
            if (Moudule_Base == 0) {
                ESP_LOG_ERROR(@"[ESP] Module_Base=0 — game not running or task_for_pid failed. Will retry in update_data every ~2s...");
                // update_data now retries periodically (was: single +2s retry then gave up forever).
            } else {
                // Dump readable regions once for debugging (DEBUG).
                ESPDumpRegions(ESPGetTargetTask(), "ESP_View init");
                // Probe chain once to validate offsets before first frame.
                ESPChainSnapshot snap = ESPProbeChain(Moudule_Base, gGameFacadeGlobalRVA);
                ESP_LOG_INFO(@"[ESP] initial probe mainOk=%d listOk=%d camOk=%d players=%d",
                    snap.mainOk, snap.listOk, snap.cameraOk, snap.playerCount);
                if (snap.mainOk && !snap.cameraOk && !snap.listOk) {
                    // Chain resolves (MatchGame/Match/LocalPlayer valid) but camera+list null.
                    // Verified 2026-11-05 log: camera 0x0 at +0x20/+0x28 and empty list in lobby.
                    ESP_LOG_INFO(@"[ESP] probe mainOk but camera/list empty — likely LOBBY. Enter a match and ESP will start.");
                }
                if (!snap.mainOk) {
                    ESP_LOG_WARN(@"[ESP] initial probe FAILED — attempting heal (candidates + scan)...");
                    uint64_t healed = 0;
                    if (kGameFacadeCandidatesCount > 0) {
                        healed = ESPFindGameFacadeGlobal(Moudule_Base, kGameFacadeCandidates, kGameFacadeCandidatesCount);
                    }
                    if (!healed) {
                        ESP_LOG_WARN(@"[ESP] candidate heal failed, trying pointer scan (may take ~1-3s)...");
                        // 256MB covers __DATA for UnityFramework 1.132.1 (DATA at 0xb1c8000, size ~0x11c0000).
                        // Scan from moduleBase+0x8000000ish would be faster, but full scan is safest.
                        healed = ESPScanGameFacadeStatic(Moudule_Base, 0xC000000); // 192MB
                    }
                    if (healed) {
                        uint64_t old = gGameFacadeGlobalRVA;
                        gGameFacadeGlobalRVA = healed;
                        ESPChainSnapshot snap2 = ESPProbeChain(Moudule_Base, gGameFacadeGlobalRVA);
                        ESP_LOG_INFO(@"[ESP] healed global RVA=0x%llx (was 0x%llx) post-heal mainOk=%d players=%d",
                            (unsigned long long)healed, (unsigned long long)old, snap2.mainOk, snap2.playerCount);
                        if (!snap2.mainOk) {
                            // Do not keep a heal that fails full validation (log 2026-11-05 false positive).
                            ESP_LOG_ERROR(@"[ESP] healed RVA failed re-probe — reverting to 0x%llx. Need IDA/Ghidra or wider scan.", (unsigned long long)old);
                            gGameFacadeGlobalRVA = old;
                        }
                    } else {
                        ESP_LOG_ERROR(@"[ESP] HEAL FAILED — check AUTO_SCAN.md; global RVA must be found via IDA/Ghidra");
                    }
                }
            }
        });
        ESPScopedTimerEnd(&Tinit);

        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateBoxes)];
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        
        self.displayLinkDATA = [CADisplayLink displayLinkWithTarget:self selector:@selector(update_data)];
        [self.displayLinkDATA addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.superview) {
        self.frame = self.superview.bounds;
    }
    [self updateBoxes];
}

- (void)setBoxes:(NSArray<NSValue *> *)boxes
{
    _boxesData = [boxes copy];
    [self updateBoxes];
}

- (void)updateBoxes {
    if (!self.window) return;
    NSUInteger count = self.boxesData.count;
    
    if (count == 0)
    {
        for (CALayer *layer in self.layers)
        {
            [layer removeFromSuperlayer];
        }
        [self.layers removeAllObjects];
        return;
    }
    
    while (self.layers.count < count)
    {
        CALayer *layer = [CALayer layer];
        layer.borderColor = [UIColor colorWithRed:1 green:0 blue:0 alpha:0.8].CGColor;
        layer.borderWidth = 2.0;
        layer.cornerRadius = 3.0;
        [self.layer addSublayer:layer];
        [self.layers addObject:layer];
    }

    for (NSUInteger i = 0; i < self.layers.count; i++)
    {
        CALayer *layer = self.layers[i];

        if (i < count)
        {
            ESPBox box;
            [self.boxesData[i] getValue:&box];
            layer.hidden = NO;
            
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            layer.frame = CGRectMake(box.pos.x, box.pos.y, box.width, box.height);
            [CATransaction commit];

        } else {
            layer.hidden = YES;
        }
    }
}

- (void)dealloc {
    [self.displayLink invalidate];
    [self.displayLinkDATA invalidate];
    self.displayLink = nil;
    self.displayLinkDATA = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)update_data
{
    auto Tframe = ESPScopedTimerBegin("update_data", NO); // log only at DEBUG via manual end below
    static int sConsecutiveFails = 0;
    CFTimeInterval t = CACurrentMediaTime();
    CGSize size = self.bounds.size;
    ESP_LOG_DEBUG_THROTTLED(@"[ESP] update_data frame start bounds=%.0fx%.0f", size.width, size.height);
    
    const NSInteger boxCount = 10;
    const CGFloat baseWidth = 60.0;
    const CGFloat baseHeight = 120.0;

    NSMutableArray<NSValue *> *boxesMutable = [NSMutableArray arrayWithCapacity:boxCount];
    int countObject = 0;

    // Fix (log 2026-11-05): Moudule_Base is uint64_t; failure value is 0, NOT -1 (signed compare never fires).
    // Also retry base resolution periodically so opening HUD before the game still recovers.
    if (Moudule_Base == 0 || Moudule_Base == (uint64_t)-1) {
        static int sBaseRetryTicks = 0;
        if ((++sBaseRetryTicks % 120) == 0) { // ~2s at 60fps
            ESP_LOG_INFO(@"[ESP] base still 0 — retrying GetGameModule_Base...");
            Moudule_Base = (uint64_t)GetGameModule_Base((char*)"freefireth");
            ESP_LOG_INFO(@"[ESP] base retry Moudule_Base=0x%llx pid=%d", (unsigned long long)Moudule_Base, ESPGetTargetPid());
        }
        return; // skip chain; avoids 100+ identical ERROR lines per second (was 9600 lines in log)
    }

    uint64_t matchGame = getMatchGame(Moudule_Base);
    uint64_t camera = CameraMain(matchGame);
    if (!isVaildPtr(camera)) return;

    uint64_t match = getMatch(matchGame);
    if (!isVaildPtr(match)) return;

    uint64_t myPawnObject = getLocalPlayer(match);
    if (!isVaildPtr(myPawnObject)) return;
    
    // CHANGED for 1.132.1: MainCameraTransform 0x2B0 -> 0x3E8 (Player.MainCameraTransform)
    uint64_t mainCameraTransform = ReadAddr<uint64_t>(myPawnObject + 0x3E8);
    Vector3 myLocation = getPositionExt(mainCameraTransform);
    
    // CHANGED for 1.132.1: Player list OLD Match+0xC8 -> holder+0x28 -> array CHAIN BROKEN.
    // NEW: Match (JMAGGLCNGIG) has List<Player> at +0x158 (LMOIPODCHOL).
    // IL2CPP List<T> layout (generic instantiation): _items at +0x10, _size at +0x18.
    // SzArray layout: length at +0x18, elements at +0x20 + i*8 (same as old array part).
    // Fallback: +0x160 (DPFFPGAFGDK List<Player>) if 0x158 empty.
    // Also available: Dictionaries at 0x128/0x130/0x140/0x150 (harder to enumerate).
    uint64_t listObj = ReadAddr<uint64_t>(match + 0x158);
    if (!isVaildPtr(listObj) || ReadAddr<int>(listObj + 0x18) == 0) {
        listObj = ReadAddr<uint64_t>(match + 0x160);
    }
    if (!isVaildPtr(listObj)) return;
    uint64_t tValue = ReadAddr<uint64_t>(listObj + 0x10); // _items array
    if (!isVaildPtr(tValue)) return;
    int coutValue = ReadAddr<int>(listObj + 0x18); // _size (same as array length)
    // Cross-check with array length; use min to stay safe
    int arrLen = ReadAddr<int>(tValue + 0x18);
    if (arrLen > 0 && arrLen < coutValue) coutValue = arrLen;
    if (coutValue <= 0 || coutValue > 200) {
        // Sanity: Free Fire max players ~ 50-100; log and bail if insane
        NSLog(@"[Flork] Invalid player count %d (listObj=%llx tValue=%llx)", coutValue, listObj, tValue);
        return;
    }
    
    float *matrix = GetViewMatrix(camera);

    for (int i = 0; i < coutValue; i++) {
        uint64_t PawnObject = ReadAddr<uint64_t>(tValue + 0x20 + 8 * i);
        if (!isVaildPtr(PawnObject)) continue;

        bool isLocalTeam = isLocalTeamMate(myPawnObject, PawnObject);
        if (isLocalTeam) continue;
        
        NSString *Name = GetNickName(PawnObject);
        if (Name.length == 0) continue;

        int CurHP = get_CurHP(PawnObject);
        int MaxHP = get_MaxHP(PawnObject);

        Vector3 HeadLocation     = getPositionExt(getHead(PawnObject));
        HeadLocation.y           += 0.2f;

        Vector3 RightToePos      = getPositionExt(getRightToeNode(PawnObject));
        
        Vector3 w2sHeadLocation  = WorldToScreen(HeadLocation, matrix, sWidth, sHeight);
        Vector3 w2sRightToePos   = WorldToScreen(RightToePos, matrix, sWidth, sHeight);
        
        float dis = Vector3::Distance(myLocation, HeadLocation);
        if (dis > 220.0f) continue;
        
        countObject++;

        float boxHeight = abs(w2sHeadLocation.y - w2sRightToePos.y);
        float boxWidth = boxHeight * 0.5f;
        float x = w2sHeadLocation.x - boxWidth * 0.5f;
        float y = w2sHeadLocation.y;
        CGRect box = CGRectMake(x, y, boxWidth, boxHeight);

        ESPBox espBox;
        espBox.pos.x = x;
        espBox.pos.y = y;
        espBox.width = boxWidth;
        espBox.height = boxHeight;
        
        NSValue *val = [NSValue valueWithBytes:&espBox objCType:@encode(ESPBox)];
        [boxesMutable addObject:val];
    }

    if (countObject == 0 && (Moudule_Base != 0)) {
        sConsecutiveFails++;
        ESP_LOG_DEBUG_THROTTLED(@"[ESP] zero-count frame #%d (fails=%d)", countObject, sConsecutiveFails);
        if (sConsecutiveFails == 60) {
            ESP_LOG_WARN(@"[ESP] 60 consecutive zero-count frames — re-probing chain (RVA may be stale)...");
            ESPChainSnapshot snap = ESPProbeChain(Moudule_Base, gGameFacadeGlobalRVA);
            if (!snap.mainOk) {
                uint64_t healed = ESPFindGameFacadeGlobal(Moudule_Base, kGameFacadeCandidates, kGameFacadeCandidatesCount);
                if (!healed) healed = ESPScanGameFacadeStatic(Moudule_Base, 0xC000000);
                if (healed && healed != gGameFacadeGlobalRVA) {
                    ESP_LOG_INFO(@"[ESP] runtime heal: RVA 0x%llx -> 0x%llx", (unsigned long long)gGameFacadeGlobalRVA, (unsigned long long)healed);
                    gGameFacadeGlobalRVA = healed;
                } else if (!healed) {
                    ESP_LOG_ERROR(@"[ESP] runtime heal failed — manual IDA step required (AUTO_SCAN.md)");
                }
            }
            sConsecutiveFails = 0;
        }
    } else {
        sConsecutiveFails = 0;
    }
    NSLog(@"[Flork] Count: %d", countObject);
    ESP_LOG_INFO_ONCE(@"[ESP] first Count=%d boxes=%lu", countObject, boxesMutable.count);
    ESP_LOG_DEBUG_THROTTLED(@"[ESP] frame end count=%d boxes=%lu t=%.3f", countObject, boxesMutable.count, CACurrentMediaTime() - t);
    ESPScopedTimerEnd(&Tframe);
    self.boxes = boxesMutable;
    [self setNeedsDisplay];
}


@end
