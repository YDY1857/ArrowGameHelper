#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

// ============================================================================
// ArrowGameRecon — reconnaissance tweak for the Alipay arrow game
// (non-jailbreak / re-signed IPA friendly: no Logos, no substrate)
//
// v3 changes (2026-10-16):
//   [BUGFIX] getMainWindow() used to pick a window by -isKeyWindow. Our own
//     overlay window becomes key, so the whole view-hierarchy dump was our own
//     RG badge and "No WKWebView detected" was meaningless. Own windows are now
//     excluded, and every window is listed (class / level / root VC).
//   [NEW] Directory tree dump of the interesting sandbox roots
//     (Library/Caches/H5CustomFiles, Documents/PYLFilemanager).
//   [NEW] Cocos-Creator-aware JS probes (window.cc / cc.director.getScene())
//     plus canvas detection.
//   [NEW] "导出缓存文本" button — concatenates every js/json/html/text file found
//     under the H5 cache into ONE shareable .txt so the game code can be read
//     offline. No zip/tar binary format involved, so nothing can corrupt.
//   [KEEP] v2 touch-passthrough fix (ReconWindow) and the silent self-check.
//
// v4 changes (2026-10-16):
//   [NEW] Recording mode. Tap "开始采集" while the game is on screen, then
//     PLAY the game normally. A 1 Hz sampler records the JS/Cocos state every
//     second, and every finger tap on the app is logged with its window
//     coordinates and the hit-test view class. Result: a timeline that lets us
//     line up "user tapped here" against "this node changed".
//     The panel hides itself while recording so it does not block play, and the
//     RG ball turns orange to show recording is live.
//
// v6 changes (2026-10-16):
//   [BUGFIX] The Cocos scene probe of v3..v5 NEVER RAN. evaluateJavaScript only
//     ever executes in the web view's MAIN frame, so every `cc` reference
//     resolved against the main frame's globals -- where there is none.
//   [NEW] All probes now read the game iframe's window object directly
//     (same-origin, proven by v5), via W.cc / W.my / W.MYGameGlobal.
//   [NEW] "深度探针" button -> Documents/arrowgame_deep.txt
//   [NEW] Per-sample game-frame heartbeat (scene / node count / viewport).
//
// v7 changes (2026-10-16):
//   The v6 deep dump answered the architecture question, so v7 goes straight
//   for the LEVEL DATA:
//   [NEW] levelJS()  -- machine-readable level export (grid transform, all 165
//     arrow polylines as flat cell lists, per-arrow active flag), plus
//     self-validation run INSIDE the browser (index-convention check, cell
//     coverage / overlap census, empty-cell list). A Python solver should be
//     able to read this one block and nothing else.
//   [NEW] compJS()   -- components deduped by class name, then every own
//     property of one representative instance. v6 burned its entire 49-hit
//     budget on 25 identical `isColorSwitch=false` rows, so the real state
//     arrays were never reached; this fixes that.
//   [NEW] Heartbeat now also reports snd=<soundIndex> arrows=<n> act=<active>,
//     the two live signals that actually change during play.
//   [CHORE] deepGameJS section D deduped by class.property and its cap raised
//     48 -> 200.
//
// v8 changes (2026-10-16):
//   v7's level dump settled the geometry (32x47 grid, 165 arrows = 651 rods,
//   board fully tiled except 64 loose empty cells) but three different movement
//   rules all failed to predict which arrows actually moved on a real tap. So
//   v8 stops guessing and reads the game's own code:
//   [NEW] funcJS()  -- `String(fn)` for checkPathPass / checkPathCanPass /
//     getCanPassLine / classificationLine / getPointsInDirection* /
//     getDirectionType / getXYIndexByIndex / checkLineType and friends. Pure
//     toString(), nothing is invoked, so it cannot touch the board.
//   [NEW] rodJS()   -- unwraps the physical model: arrowNodeList[i] is an ARRAY
//     of rod nodes (v7 wrongly treated it as a single node, which is why the
//     `active` column came out all zeros), plus the structure of one rod's
//     components and of a grid-point cell.
//   [NEW] callJS()  -- invokes ONLY read-only get/check helpers to ask the game
//     which arrows it considers passable. arrowMove / hideArrowList /
//     recoverPool / *Animation are never called.
//   [BUGFIX] Heartbeat `off=` and levelJS's liveness column now test the rod
//     ARRAY instead of the array object itself.
//   [BUGFIX] The old `sig=` hashed arrowAllPointList, which turned out to be a
//     STATIC level definition (constant across 14 successful moves). Replaced
//     with `liveCells=<active grid points>/1504`, a genuinely live signal.
//
// v9 changes (2026-10-16):
//   v8's FUNCSRC worked -- the game's rule is now known verbatim:
//     dir      = rod[0].eulerAngles.z : 0->left, 90->down, 180->right, -90->up
//     head     = arrowPointList[lineID][0]
//     corridor = gridSystem.getPointsInDirection(head, dir)   // head+1 .. edge
//     passable <=> corridor contains no occupied cell  <=>  checkPathPass()==-1
//     occupancy map = gridSystem.gridPointLineIDInfo (cell -> lineID)
//   So v9 just asks for the verdicts and the live map instead of inferring them:
//   [NEW] callJS section A: per-arrow eulerAngles.z + head cell + rod count.
//   [NEW] callJS section B: checkPathPass(nl[i]) for ALL 165 arrows -- the
//     game's own pass/fail verdict, plus getCanPassLine().lineID.
//   [NEW] callJS section C: the whole gridPointLineIDInfo occupancy map.
//   [NEW] callJS section D: direction-enum sanity with real Vec3 arguments.
//   [BUGFIX] v8's callJS passed an INDEX to checkPathPass (which wants the rod
//     array) -- every call threw. It also stringify'd getCanPassLine()'s return
//     value, whose arrowList holds cc.Nodes, so all we got was [circ].
//   [BUGFIX] ** classificationLine() is NOT read-only ** -- it calls
//     onArrowTouchStart on the three longest lines, which actually MOVES arrows.
//     v8 invoked it and perturbed the board. Removed for good.
//   [NEW] funcJS also dumps onArrowTouchStart (the move handler -- tells us how
//     far one tap moves an arrow), hideArrowList, checkGameWin, update.
//
// v10 changes (2026-10-16):  *** the helper actually works now ***
//   v9's ground truth came back and the rule matched 165/165 (per-arrow
//   checkPathPass verdict, zero mismatches; the passable set was byte-identical
//   [0,1,2,3,4,5,6,7,9,10,11,12,14,19,20,25,26,27,30,46,52]). onArrowTouchStart's
//   source also confirmed the move semantics: a correct tap runs the tail width
//   through the head rod and then does `t.forEach(t => t.active = false)`, i.e.
//   the whole arrow leaves the board; a wrong tap plays "error", resets
//   soundIndex to 0 and costs one heart (ReduceHp, at most once per line).
//   So the solver now runs on our side:
//   [NEW] solveJS() -- greedy solve from (static cell lists + live rod active
//     flags). Removal only frees cells, so the passable set is monotonically
//     non-decreasing and greedy converges order-independently. Verified on the
//     real board: 165/165 cleared, no stall.
//   [NEW] Marker overlay (level 9999, fully click-through) that paints the next
//     8 steps as numbered circles at each arrow's head cell. Screen coordinates
//     are computed from the LIVE Grid node transform (worldPosition/worldScale)
//     so panning and zooming keep working.
//   [NEW] "求解 · 标出下一步" button.
//   [NOTE] soundIndex is a success STREAK counter: ++ on a correct tap, reset to
//     0 on a wrong one. So an increment does mean "that tap worked".
//
// v11 changes (2026-10-19):  *** hands-free ***
//   v10's markers were confirmed landing in the right place, so the last step is
//   to actually do the tapping. We do NOT synthesise UITouch objects (private
//   ivars, version-fragile) -- we call the game's own tap handler instead:
//       as.onArrowTouchStart(as.arrowNodeList[i], i, false)
//   which is the exact function a finger ends up in, so all of the game's own
//   bookkeeping (hideShowArrowTouch / clearLinePos / checkGameWin / soundIndex)
//   runs normally and its state can never drift.
//   [NEW] startAutoJS() -- a self-driving setTimeout chain INSIDE the page:
//     solve -> re-verify with the game's OWN checkPathPass -> call the handler ->
//     wait until that arrow's rods go inactive -> next. ObjC only polls a short
//     status string every 500 ms, so no 165 round-trips.
//   [SAFETY] Before every single auto move we assert checkPathPass()===-1; the
//     run aborts immediately if the game disagrees with our solver, so an auto
//     move can never cost a heart.
//   [NEW] "自动通关（全自动）" toggle + "清除标注" button + a progress strip.
//   [NOTE] evalJS waits on a semaphore that only a MAIN-queue completion handler
//     signals -- so it deadlocks if called on the main thread. autoTick does its
//     web-view work on a background queue and hops to main only to paint.
// ============================================================================

static UIWindow *gReconWindow = nil;
static UITextView *gReconTextView = nil;
static UIWindow *gBadgeWindow = nil;
static UIButton *gSampleBtn = nil;

// --- sampling state -------------------------------------------------------
static BOOL gSampling = NO;
static NSInteger gSampleIdx = 0;
static NSInteger gSessionNo = 0;
static NSDate *gSessionStart = nil;
static NSMutableArray *gTapLog = nil;
static dispatch_source_t gSampleTimer = nil;
static dispatch_queue_t gSampleQueue = nil;
static const NSInteger kMaxSamples = 180;
static const double kSampleInterval = 1.0;

#define RECON_VERSION @"11"

@interface ReconOverlayController : NSObject
+ (instancetype)sharedInstance;
- (void)presentWithText:(NSString *)text;
- (void)hide;
- (void)showBadge;
- (void)showToast:(NSString *)msg;
- (void)installThreeFingerLongPress;
// Declared up front so calls made before the definition always resolve.
- (void)sampleTick:(NSInteger)idx;
- (void)startSampling;
- (void)stopSamplingAndExport;
- (void)updateSampleButton;
- (void)updateBadgeLook;
- (void)btnToggleSampling;
- (void)btnDeepProbe;
- (void)btnSolve;
- (void)btnAuto;
- (void)autoTick;
- (void)updateAutoButton;
- (void)btnClearMarks;
- (void)togglePanel;
@end

// Only captures touches that land on a real subview.
@interface PassthroughView : UIView
@end

@implementation PassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

// A bare UIWindow answers -hitTest: with itself when no subview is hit, and a
// touch delivered to a UIWindow goes nowhere. Returning nil here is what makes
// touches on empty areas reach the app underneath.
@interface ReconWindow : UIWindow
@end

@implementation ReconWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    if (hit && hit == self.rootViewController.view) return nil;
    return hit;
}
// Never steal key-window status from the app: otherwise the app's own window
// stops being key, which breaks text input focus and also made the v2 dump pick
// our overlay instead of the app's real window.
- (BOOL)canBecomeKeyWindow {
    return NO;
}
@end

static BOOL isOwnWindow(UIWindow *w) {
    return [w isKindOfClass:[ReconWindow class]];
}

static UIWindow *makeOverlayWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *s in app.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            UIWindowScene *ws = (UIWindowScene *)s;
            ReconWindow *w = [[ReconWindow alloc] initWithWindowScene:ws];
            w.frame = ws.coordinateSpace.bounds;
            return w;
        }
    }
    for (UIScene *s in app.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)s;
            ReconWindow *w = [[ReconWindow alloc] initWithWindowScene:ws];
            w.frame = ws.coordinateSpace.bounds;
            return w;
        }
    }
    return [[ReconWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
}

static NSString *sandboxDocs(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return docs ?: NSHomeDirectory();
}

static NSString *reconFilePath(void) {
    return [sandboxDocs() stringByAppendingPathComponent:@"arrowgame_recon.txt"];
}

// Every window that is NOT ours. This is the fix for v2's useless dump.
static NSArray<UIWindow *> *appWindows(void) {
    NSMutableArray *result = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (!isOwnWindow(w)) [result addObject:w];
        }
    }
    return result;
}

// Pick the window the game is actually in. Ranking by key-window status alone
// was wrong: a 44x123 BEEAlertManagedWindow was key and got picked instead of
// the full-screen game window. Now: visible, normal level, then biggest.
static UIWindow *getMainWindow(void) {
    NSArray<UIWindow *> *wins = appWindows();
    UIWindow *best = nil;
    double bestScore = -1;
    for (UIWindow *w in wins) {
        if (w.hidden) continue;
        CGRect f = w.frame;
        double area = (double)f.size.width * (double)f.size.height;
        if (area <= 0) continue;
        double sc = area;
        if (w.windowLevel == UIWindowLevelNormal) sc += 1e7;
        if (w.isKeyWindow) sc += 1e6;
        if (sc > bestScore) { bestScore = sc; best = w; }
    }
    if (best) return best;
    return wins.firstObject;
}

static NSString *dumpWindowList(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"\n=== All windows (ours marked) ===\n"];
    UIApplication *app = [UIApplication sharedApplication];
    NSInteger idx = 0;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            [out appendFormat:@"[%ld] %@ level=%.0f hidden=%@ key=%@ rootVC=%@ frame=(%.0f,%.0f,%.0f,%.0f)%@\n",
                (long)idx++,
                NSStringFromClass([w class]),
                w.windowLevel,
                w.hidden ? @"YES" : @"NO",
                w.isKeyWindow ? @"YES" : @"NO",
                NSStringFromClass([w.rootViewController class]),
                w.frame.origin.x, w.frame.origin.y, w.frame.size.width, w.frame.size.height,
                isOwnWindow(w) ? @"   <-- OURS" : @""];
        }
    }
    return out;
}

#pragma mark - View hierarchy dump

static NSInteger gNodeCount = 0;
static const NSInteger kMaxNodes = 3000;

static void dumpView(UIView *view, NSInteger depth, NSMutableString *outStr) {
    if (!view || gNodeCount > kMaxNodes) return;
    gNodeCount++;
    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    CGRect f = view.frame;
    NSString *cls = NSStringFromClass([view class]);
    NSString *imgName = @"";
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImage *img = ((UIImageView *)view).image;
        if (img) imgName = [NSString stringWithFormat:@" img=%@", img];
    }
    [outStr appendFormat:@"%@%@@(%.0f,%.0f,%.0f,%.0f) subviews=%lu%@\n",
        indent, cls, f.origin.x, f.origin.y, f.size.width, f.size.height,
        (unsigned long)view.subviews.count, imgName];

    for (UIView *sub in view.subviews) {
        dumpView(sub, depth + 1, outStr);
    }
}

#pragma mark - Class enumeration

static NSString *dumpRelevantClasses(void) {
    NSMutableString *outStr = [NSMutableString stringWithString:@"\n=== Relevant Objective-C classes ===\n"];
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return outStr;
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);
    NSArray *keywords = @[@"Nebula", @"TinyApp", @"MiniApp", @"Applet", @"Appx", @"H5WK",
                          @"H5Custom", @"Cocos", @"Game", @"Canvas", @"Arrow", @"Grid",
                          @"Puzzle", @"WebView", @"JSCore", @"Cube", @"XR"];
    NSInteger matched = 0;
    for (int i = 0; i < numClasses && matched < 400; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (!name.length) continue;
        // Skip Swift-mangled system noise and obvious unrelated frameworks.
        if ([name hasPrefix:@"_"]) continue;
        for (NSString *kw in keywords) {
            if ([name rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [outStr appendFormat:@"%@\n", name];
                matched++;
                break;
            }
        }
    }
    free(classes);
    [outStr appendFormat:@"(matched %ld classes, capped at 400)\n", (long)matched];
    return outStr;
}

#pragma mark - WKWebView probes

static void findWKWebViews(UIView *v, NSMutableArray *into, NSInteger depth) {
    if (!v || depth > 40) return;
    if ([v isKindOfClass:[WKWebView class]]) [into addObject:v];
    for (UIView *sub in v.subviews) {
        findWKWebViews(sub, into, depth + 1);
    }
}

static NSArray<WKWebView *> *allWKWebViews(void) {
    NSMutableArray *found = [NSMutableArray array];
    for (UIWindow *w in appWindows()) {
        findWKWebViews(w, found, 0);
    }
    return found;
}

// dispatch_sync onto the main queue deadlocks if we are already on it.
static void runOnMainSync(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static NSString *evalJS(WKWebView *webView, NSString *js, NSTimeInterval timeout) {
    __block NSString *val = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    runOnMainSync(^{
        [webView evaluateJavaScript:js completionHandler:^(id v, NSError *err) {
            if (err) val = [@"ERR:" stringByAppendingString:err.localizedDescription];
            else if (v == nil || [v isKindOfClass:[NSNull class]]) val = @"<null>";
            else val = [v description];
            dispatch_semaphore_signal(sem);
        }];
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        return @"<timeout>";
    }
    return val ?: @"<nil>";
}

// ---- probe suites --------------------------------------------------------

// Compact per-webview summary; cheap enough to run on every sample.
static NSString *compactJS(void) {
    return @"(function(){var o={};"
           @"try{o.href=String(location.href).slice(0,220)}catch(e){}"
           @"try{o.title=String(document.title||'').slice(0,80)}catch(e){}"
           @"try{o.frames=window.length}catch(e){}"
           @"try{o.canvas=document.querySelectorAll('canvas').length}catch(e){}"
           @"try{o.scripts=document.scripts.length}catch(e){}"
           @"try{o.ready=String(document.readyState)}catch(e){}"
           @"try{o.body=String((document.body&&document.body.innerText)||'').replace(/\\s+/g,' ').slice(0,140)}catch(e){}"
           @"var eng=[];"
           @"['cc','Laya','egret','PIXI','THREE','BABYLON','Phaser','Konva','createjs','GameGlobal','my','wx','canvas','game','Game','$'].forEach(function(k){try{if(typeof window[k]!=='undefined')eng.push(k+':'+typeof window[k])}catch(e){}});"
           @"o.eng=eng.join(',');"
           @"return JSON.stringify(o)})()";
}

// Walk the frame tree (top + up to 4 sub-frames, 2 levels) and dump every
// global whose name looks game-related.
static NSString *heavyJS(void) {
    return @"(function(){var out=[];"
           @"function scan(w,path,depth){if(depth>2)return;var ks=[];"
           @"try{for(var k in w)ks.push(k)}catch(e){out.push('### '+path+' <blocked>');return}"
           @"var fn=0;try{fn=w.length||0}catch(e){}"
           @"out.push('### '+path+'  keys='+ks.length+'  frames='+fn);"
           @"var hits=0;"
           @"for(var i=0;i<ks.length;i++){var k=ks[i];"
           @"if(/^(on|webkit|moz|MS)/.test(k))continue;"
           @"if(!/game|level|arrow|grid|puzzle|board|scene|state|model|data|cc|laya|egret|pixi|three|babylon|phaser|gameglobal|canvas|anim|node|sprite|^(my|wx)$/i.test(k))continue;"
           @"var v,t='?';try{v=w[k];t=typeof v}catch(e){t='<err>'}"
           @"var sv='';if(t!=='function'&&t!=='undefined'&&v!==null){try{sv=JSON.stringify(v)}catch(e){sv='[circ]'}if(sv===undefined)sv='[u]';if(sv.length>260)sv=sv.slice(0,260)+'...'}"
           @"out.push('  '+k+' : '+t+' = '+sv);hits++;if(hits>70)break;}"
           @"try{if(typeof cc!=='undefined'&&cc.director&&cc.director.getScene()){var sc=cc.director.getScene(),tr=[],n=0;"
           @"(function walk(nd,d){if(d>3||n>200)return;n++;var p=nd.position||{};"
           @"tr.push(new Array(d+1).join('  ')+nd.name+' <'+(nd.constructor&&nd.constructor.name)+'> xy='+Math.round(p.x||0)+','+Math.round(p.y||0)+' act='+(nd.active===false?0:1)+' op='+(nd.opacity===undefined?'-':nd.opacity));"
           @"var c=nd.children||[];for(var j=0;j<c.length;j++)walk(c[j],d+1)})(sc,0);"
           @"out.push('--- cc.director scene tree ---');out.push(tr.join('\\n'))}}catch(e){out.push('cc err '+e)}"
           @"for(var f=0;f<fn&&f<4;f++){try{scan(w.frames[f],path+'['+f+']',depth+1)}catch(e){out.push(path+'['+f+'] <blocked>')}}"
           @"}"
           @"try{scan(window,'top',0)}catch(e){out.push('ERR '+e)}"
           @"var ss=[];try{var scs=document.scripts||[];for(var i=0;i<scs.length&&i<25;i++){ss.push(String(scs[i].src||('(inline '+((scs[i].text||'').length)+'B)')))}}catch(e){ss=['<err> '+e]}"
           @"out.push('--- scripts ('+ss.length+') ---');out.push(ss.join('\\n'));"
           @"try{var ak=[];for(var q in window)ak.push(q);out.push('--- all window keys ('+ak.length+') ---');out.push(ak.slice(0,180).join('\\n'))}catch(e){}"
           @"return out.join('\\n')})()";
}

// Sub-frame URLs (cross-origin ones may be unreadable).
static NSString *framesJS(void) {
    return @"(function(){var a=[];try{for(var i=0;i<window.length;i++){try{a.push(i+'='+String(frames[i].location.href).slice(0,180))}catch(e){a.push(i+'=<blocked>')}}}catch(e){}return a.length?a.join('\\n'):'(no frames)'})()";
}

#pragma mark - v6/v7: reach INTO the game iframe

// Why v5 failed to dump the Cocos scene:
//   -[WKWebView evaluateJavaScript:] ALWAYS runs in the web view's MAIN frame.
//   Every helper therefore resolved the identifier `cc` against the MAIN
//   frame's global object, where `cc` simply does not exist (the 241-key dump
//   of the main frame lists no `cc`). So the scene block never ran, silently.
//
// v5 did prove the iframe is SAME-ORIGIN though: the frame-tree walk did
// `for (var k in frames[0])` and got `cc` / `my` / `MYGameGlobal` back, with
// `typeof` reporting real types. Same-origin means the main frame can read the
// iframe's globals directly -- so we just hand the frame's window object to a
// probe function and touch everything through it (W.cc, W.my, ...).
// No eval() and no Function() are involved, so no CSP/unsafe-eval risk.
//
// Full introspective dump of the LIVE game state, read from inside the iframe.
static NSString *deepGameJS(void) {
    return @"(function(){var out=[];"
    @"function S(s){out.push(String(s))}"
    @"var W=null;"
    @"try{for(var i=0;i<window.length;i++){try{var w=frames[i];var h=String(w.location.href);if(h.indexOf('iframe')>=0){W=w;break}}catch(e){}}}catch(e){}"
    @"if(!W){try{W=frames[0]}catch(e){}}"
    @"if(!W){return 'NO_IFRAME'}"
    @"try{S('gameFrame='+String(W.location.href))}catch(e){S('gameFrame=<blocked>')}"
    @"function P(W){"
    @"var o=[];"
    @"function S(s){o.push(String(s))}"
    @"function J(v,mx){try{var s=JSON.stringify(v);if(s===undefined)s='[u]';if(mx&&s.length>mx)s=s.slice(0,mx)+'...';return s}catch(e){return '[circ]'}}"
    @"function K(x){var a=[];try{for(var k in x)a.push(k)}catch(e){}return a}"
    @"var cc=null,mg=null;"
    @"try{cc=W.cc}catch(e){}"
    @"try{mg=W.MYGameGlobal}catch(e){}"
    @"S('--- A. game-realm globals ---');"
    @"var gm=['cc','my','MYGameGlobal','GameGlobal','hp','zsAlipayCom','wx','canvas','screencanvas','Laya','egret','PIXI','game','Game','__globalAdapter'];"
    @"for(var i=0;i<gm.length;i++){var t='<undef>';try{t=typeof W[gm[i]]}catch(e){t='<blocked>'}S('  '+gm[i]+'='+t)}"
    @"try{S('  body='+String((W.document.body&&W.document.body.innerText)||'').replace(/\\s+/g,' ').slice(0,160))}catch(e){}"
    @"try{var cv=W.document.querySelectorAll('canvas');S('  canvasCount='+cv.length+(cv.length?(' first='+cv[0].width+'x'+cv[0].height):''))}catch(e){}"
    @"try{var scs=W.document.scripts||[];var sl=[];for(var i2=0;i2<scs.length&&i2<30;i2++){sl.push(String(scs[i2].src||'(inline)'+((scs[i2].text||'').length)+'B'))}S('  gameScripts('+scs.length+')='+sl.join(' | '))}catch(e){S('  scriptsErr '+e)}"
    @"var ccjs=null,sc=null;"
    @"try{ccjs=cc&&cc.js}catch(e){}"
    @"function CN(c){try{if(ccjs&&ccjs.getClassName){var n=ccjs.getClassName(c);if(n)return n}}catch(e){}try{return (c&&c.constructor&&c.constructor.name)||'?'}catch(e){return '?'}}"
    @"function COMP(nd){var a=[];try{a=nd._components||nd.components||[]}catch(e){}return a}"
    @"S('--- B. view / resolution ---');"
    @"try{S('  ccVersion='+(cc.ENGINE_VERSION||(cc.sys&&cc.sys.version)))}catch(e){}"
    @"try{S('  winSize='+J(cc.winSize))}catch(e){}"
    @"try{S('  visibleSize='+J(cc.view.getVisibleSize()))}catch(e){}"
    @"try{S('  frameSize='+J(cc.view.getFrameSize()))}catch(e){}"
    @"try{S('  designRes='+J(cc.view.getDesignResolutionSize()))}catch(e){}"
    @"S('--- C. cc.director scene tree ---');"
    @"try{if(cc&&cc.director&&cc.director.getScene)sc=cc.director.getScene()}catch(e){S('  getSceneErr '+e)}"
    @"if(!sc){S('  NO_SCENE (cc='+(typeof cc)+')')}else{"
    @"S('  root='+sc.name);var lines=[],N=0;"
    @"(function walk(nd,d){if(!nd||d>5||N>260)return;N++;var p=nd.position||{};var a=COMP(nd);var cs=[];"
    @"for(var i=0;i<a.length;i++)cs.push(CN(a[i]));"
    @"lines.push(new Array(d+1).join('  ')+nd.name+' ['+cs.join(',')+'] xy='+Math.round(p.x||0)+','+Math.round(p.y||0)+(nd.active===false?' OFF':''));"
    @"var ch=nd.children||[];for(var j=0;j<ch.length;j++)walk(ch[j],d+1)})(sc,0);"
    @"S(lines.join('\\n'))}"
    @"S('--- D. data-bearing component props (deduped by class.prop) ---');"
    @"var hits=0,seen={};"
    @"if(sc){(function w2(nd,d){if(!nd||d>12||hits>200)return;var a=COMP(nd);"
    @"for(var i=0;i<a.length;i++){var c=a[i];if(!c)continue;var cls=CN(c);var ks=[];try{ks=Object.keys(c)}catch(e){}"
    @"for(var j=0;j<ks.length;j++){var k=ks[j];if(k.charAt(0)==='_'||k.charAt(0)==='$')continue;"
    @"var dk=cls+'.'+k;if(seen[dk])continue;var v;try{v=c[k]}catch(e){continue}"
    @"if(v===null||v===undefined)continue;var tv=typeof v;"
    @"if(tv==='object'&&typeof v.length==='number'&&v.length>=6){seen[dk]=1;S('  @'+nd.name+' <'+cls+'> .'+k+' len='+v.length+' = '+J(v,700));hits++}"
    @"else if((tv==='number'||tv==='string'||tv==='boolean')&&/level|stage|round|cur|idx|index|dir|arrow|step|move|count|progress|score|board|grid|col|row/i.test(k)){seen[dk]=1;S('  @'+nd.name+' <'+cls+'> .'+k+' = '+J(v,90));hits++}}}"
    @"var ch=nd.children||[];for(var z=0;z<ch.length;z++)w2(ch[z],d+1)})(sc,0)}"
    @"S('  hits='+hits);"
    @"S('--- E. classes / bundles ---');"
    @"try{var rb=ccjs&&ccjs._registeredClassNames;if(rb){var kk=K(rb);S('  classNameCount='+kk.length);S('  names='+kk.slice(0,300).join(','))}}catch(e){}"
    @"try{var bs=cc.assetManager&&cc.assetManager.bundles;if(bs)S('  assetBundles='+K(bs).join(','))}catch(e){}"
    @"try{var gb=cc.game&&cc.game._bundles;if(gb)S('  gameBundles='+K(gb).join(','))}catch(e){}"
    @"S('--- F. MYGameGlobal ---');"
    @"if(!mg){S('  undefined')}else{var mk=K(mg);S('  keys('+mk.length+')='+mk.join(','));"
    @"for(var i3=0;i3<mk.length&&i3<50;i3++){var k3=mk[i3];var v3;try{v3=mg[k3]}catch(e){continue}var t3=typeof v3;"
    @"if(t3==='function')continue;S('   '+k3+' : '+t3+' = '+J(v3,240));"
    @"if(v3&&t3==='object'){var k4=K(v3);if(k4.length)S('      .'+k4.slice(0,28).join('/'))}}}"
    @"S('--- G. localStorage ---');"
    @"try{var ls=W.localStorage;var n=0;var o2=[];for(var i4=0;i4<ls.length&&n<40;i4++){var k5=ls.key(i4);o2.push(k5+'='+String(ls.getItem(k5)).slice(0,90));n++}S(o2.join('\\n'))}catch(e){S('  err '+e)}"
    @"return o.join('\\n')}"
    @"var s='';try{s=P(W)}catch(e){s='PROBE_ERR '+e}"
    @"S(s);"
    @"return out.join('\\n')})()";
}

// v8: two things we learned the hard way in v7 had to be fixed here.
//   1. `arrowNodeList[i]` is NOT a node -- it is an ARRAY of rod nodes (one per
//      straight segment; 165 arrows decompose into exactly 651 rods). Testing
//      `node.active` on it therefore always failed and `off=` listed all 165.
//      Now an arrow counts as alive if ANY of its rods is active.
//   2. `arrowAllPointList` is a STATIC level definition -- its signature never
//      changed across a whole session with 14 successful moves. So the old
//      `sig=` was a constant. Replaced with liveCells: how many of the 1504
//      grid-point nodes are currently active, which IS a live signal.
static NSString *miniStateJS(void) {
    return @"(function(){var W=null;try{W=frames[0]}catch(e){}if(!W)return 'noFrame';"
           @"try{var cc=W.cc;if(!cc)return 'cc=<undef>';"
           @"if(!cc.director||!cc.director.getScene)return 'cc-no-director';"
           @"var sc=cc.director.getScene();if(!sc)return 'noScene';var n=0;"
           @"(function w2(x,d){if(!x||d>9)return;n++;var c=x.children||[];for(var i=0;i<c.length;i++)w2(c[i],d+1)})(sc,0);"
           @"var cn=cc.js&&cc.js.getClassName;"
           @"var as=W.__reconAS,gs=W.__reconGS;"
           @"if(!as||as.isValid===false||!gs||gs.isValid===false){as=null;gs=null;"
           @"(function w3(x,d){if((as&&gs)||!x||d>14)return;var a=[];try{a=x._components||x.components||[]}catch(e){}"
           @"for(var i=0;i<a.length;i++){var nm=null;try{nm=cn?cn(a[i]):null}catch(e){}"
           @"if(nm==='ArrowSystem'&&!as)as=a[i];else if(nm==='GridSystem'&&!gs)gs=a[i]}"
           @"var ch=x.children||[];for(var j=0;j<ch.length;j++)w3(ch[j],d+1)})(sc,0);W.__reconAS=as;W.__reconGS=gs}"
           @"var ex='';"
           @"try{if(as){var nl=as.arrowNodeList||[];var act=0,off=[];"
           @"for(var i=0;i<nl.length;i++){var live=0;"
           @"try{var r0=nl[i];"
           @"if(r0&&typeof r0.length==='number'){for(var z=0;z<r0.length;z++){var nd=r0[z];"
           @"if(nd&&(nd.active===true||(nd.node&&nd.node.active===true))){live=1;break}}}"
           @"else if(r0&&r0.active===true){live=1}}catch(e){}"
           @"if(live)act++;else off.push(i)}"
           @"var os=off.length>70?('('+off.length+')'+off.slice(0,70).join(',')):(off.length?off.join(','):'-');"
           @"ex+=' snd='+as.soundIndex+' arrows='+nl.length+' act='+act+' off='+os}}catch(e){ex+=' ASerr'}"
           @"try{if(gs&&gs.gridPointList){var L=gs.gridPointList,lc=0;"
           @"for(var i2=0;i2<L.length;i2++){try{if(L[i2]&&L[i2].active===true)lc++}catch(e){}}"
           @"ex+=' liveCells='+lc+'/'+L.length}}catch(e){ex+=' GSerr'}"
           @"return 'scene='+sc.name+' nodes='+n+' vp='+W.innerWidth+'x'+W.innerHeight+ex}catch(e){return 'ERR '+e}})()";
}

// Shared JS helper block, inlined verbatim into the v7 probes. Kept as literal
// text rather than a #define on purpose: the offline static checker reads the
// ObjC source, so a macro would make the helper functions invisible to it.
//
//   J(v,mx) -- JSON with a cap and a '[circ]' fallback
//   K(x)    -- own+inherited enumerable key list
//   SH(v)   -- one-line shallow summary of an arbitrary value (node-aware)

// v7 probe #1 -- the whole LEVEL, machine-readable, plus self-validation.
// Output design goal: a Python solver should be able to read this dump alone.
static NSString *levelJS(void) {
    return @"(function(){var out=[];"
    @"function S(s){out.push(String(s))}"
    @"var W=null;"
    @"try{for(var i=0;i<window.length;i++){try{var w=frames[i];var h=String(w.location.href);if(h.indexOf('iframe')>=0){W=w;break}}catch(e){}}}catch(e){}"
    @"if(!W){try{W=frames[0]}catch(e){}}"
    @"if(!W){return 'NO_IFRAME'}"
    @"function P(W){"
    @"var o=[];function S(s){o.push(String(s))}"
    @"function J(v,mx){try{var s=JSON.stringify(v);if(s===undefined)s='[u]';if(mx&&s.length>mx)s=s.slice(0,mx)+'...';return s}catch(e){return '[circ]'}}"
    @"function K(x){var a=[];try{for(var k in x)a.push(k)}catch(e){}return a}"
    @"function SH(v,dp){try{dp=dp||0;if(v===null||v===undefined)return String(v);"
    @"if(typeof v!=='object')return JSON.stringify(v);"
    @"if(typeof v.length==='number'&&dp<2)return '['+v.length+']'+(v.length?(' '+SH(v[0],dp+1)):'');"
    @"if(v.name!==undefined&&v.active!==undefined)return 'node['+v.name+',act='+(v.active?1:0)+',pos='+J(v.position,60)+']';"
    @"var ks=[],k;for(k in v){if(k.charAt(0)==='_')continue;var t=typeof v[k];if(t==='function')continue;"
    @"ks.push(k+'='+(t==='object'?'<'+t+'>':String(v[k]).slice(0,26)));if(ks.length>9)break}"
    @"return '{'+ks.join(' ')+'}'}catch(e){return '<err>'}}"
    @"var cc=W.cc;if(!cc){S('NO_CC');return o.join('\\n')}"
    @"function CN(c){try{if(cc.js&&cc.js.getClassName){var n=cc.js.getClassName(c);if(n)return n}}catch(e){}try{return (c&&c.constructor&&c.constructor.name)||'?'}catch(e){return '?'}}"
    @"var sc=null;try{sc=cc.director.getScene()}catch(e){}"
    @"if(!sc){S('NO_SCENE');return o.join('\\n')}"
    @"var gs=null,as=null,gridNode=null;"
    @"(function walk(nd,d){if(!nd||d>14)return;"
    @"var a=[];try{a=nd._components||nd.components||[]}catch(e){}"
    @"for(var i=0;i<a.length;i++){var nm=CN(a[i]);"
    @"if(nm==='GridSystem'&&!gs){gs=a[i];gridNode=nd}"
    @"else if(nm==='ArrowSystem'&&!as){as=a[i]}}"
    @"var ch=nd.children||[];for(var j=0;j<ch.length;j++)walk(ch[j],d+1)})(sc,0);"
    @"S('### META');"
    @"try{S('ccVersion='+cc.ENGINE_VERSION)}catch(e){}"
    @"try{S('winSize='+J(cc.winSize))}catch(e){}"
    @"try{S('visibleSize='+J(cc.view.getVisibleSize()))}catch(e){}"
    @"try{S('frameSize='+J(cc.view.getFrameSize()))}catch(e){}"
    @"try{S('viewScaleX='+cc.view.getScaleX()+' viewScaleY='+cc.view.getScaleY())}catch(e){}"
    @"try{S('devicePixelRatio='+W.devicePixelRatio+' sysPixelRatio='+(cc.sys&&cc.sys.pixelRatio)+' inner='+W.innerWidth+'x'+W.innerHeight)}catch(e){}"
    @"S('### GRID NODE (world transform -> cell to screen mapping)');"
    @"try{var wp=gridNode.getWorldPosition(),ws=gridNode.getWorldScale();"
    @"S('name='+gridNode.name+' worldPos='+J(wp)+' worldScale='+J(ws)+' parent='+(gridNode.parent&&gridNode.parent.name)+' children='+((gridNode.children||[]).length))}catch(e){S('gridNodeErr '+e)}"
    @"if(!gs){S('### NO_GridSystem')}else{"
    @"var gw=gs.gridWidth,gh=gs.gridHeight;"
    @"S('### GRID w='+gw+' h='+gh+' showGridNumber='+gs.showGridNumber);"
    @"S('gridOwnProps='+K(gs).join(','));"
    @"try{var gp=gs.gridPositions;"
    @"S('gridPositions rows='+gp.length+' cols='+gp[0].length);"
    @"S('gp[0][0]='+J(gp[0][0])+' gp[0][1]='+J(gp[0][1])+' gp[0][last]='+J(gp[0][gw-1]));"
    @"S('gp[1][0]='+J(gp[1]?gp[1][0]:null)+' gp[last][0]='+J(gp[gh-1]?gp[gh-1][0]:null)+' gp[last][last]='+J(gp[gh-1]?gp[gh-1][gw-1]:null));"
    @"S('gp[2][0]='+J(gp[2]?gp[2][0]:null)+' gp[3][0]='+J(gp[3]?gp[3][0]:null))}catch(e){S('gridPositionsErr '+e)}"
    @"try{var gpl=gs.gridPointList;S('gridPointList len='+gpl.length+' [0]='+SH(gpl[0])+' [1]='+SH(gpl[1])+' [32]='+SH(gpl[32])+' [1503]='+SH(gpl[1503]))}catch(e){S('gridPointListErr '+e)}"
    @"try{var gpts=gs.gridPoints;S('gridPoints len='+gpts.length+' [0]='+SH(gpts[0])+' [1]='+SH(gpts[1]))}catch(e){S('gridPointsErr '+e)}"
    @"}"
    @"if(!as){S('### NO_ArrowSystem');return o.join('\\n')}"
    @"var aal=as.arrowAllPointList,apl=as.arrowPointList,anl=as.arrowNodeList;"
    @"var n=aal?aal.length:0;"
    @"S('### ARROW SYSTEM');"
    @"S('arrowOwnProps='+K(as).join(','));"
    @"S('lens: arrowPointList='+(apl?apl.length:-1)+' arrowAllPointList='+n+' arrowNodeList='+(anl?anl.length:-1)+' soundIndex='+as.soundIndex);"
    @"var okA=0,badA=0,okB=0,badB=0;"
    @"for(var i=0;i<n;i++){var cs=aal[i];if(!cs||cs.length<2)continue;var a1=true,a2=true;"
    @"for(var k=1;k<cs.length;k++){var d=cs[k]-cs[k-1];if(Math.abs(d)!==1&&Math.abs(d)!==gw)a1=false;if(Math.abs(d)!==1&&Math.abs(d)!==gh)a2=false}"
    @"if(a1)okA++;else badA++;if(a2)okB++;else badB++}"
    @"S('INDEX_CONVENTION  row*gw+col: ok='+okA+' bad='+badA+'   |   col*gh+row: ok='+okB+' bad='+badB);"
    @"var own={},tot=0,dup=0,uniq=0,dupS=[];"
    @"for(var i=0;i<n;i++){var cs=aal[i]||[];for(var k=0;k<cs.length;k++){var id=cs[k];tot++;"
    @"if(own[id]===undefined){own[id]=i;uniq++}else{dup++;if(dupS.length<10)dupS.push(id+'('+own[id]+','+i+')')}}}"
    @"S('CELLS refs='+tot+' unique='+uniq+' overlaps='+dup+' gw*gh='+(gw*gh)+' dupSample='+dupS.join(' '));"
    @"var i0,i1,i2,nx;var uniq2=[];for(var q=0;q<gw*gh;q++){if(own[q]===undefined)uniq2.push(q)}"
    @"S('EMPTY_CELLS n='+uniq2.length+(uniq2.length?' first30='+uniq2.slice(0,30).join(','):''));"
    @"S('sample arrowPointList[0..4]='+J(apl?apl.slice(0,5):null,400));"
    @"S('### ARROW NODES (index live rodCount firstRodName)');"
    @"for(var i=0;i<(anl?anl.length:0)&&i<400;i++){var live=0,rn=anl[i]||[],nm='?';"
    @"try{if(rn.length){nm=rn[0].name||'?';for(var z=0;z<rn.length;z++){var nd=rn[z];"
    @"if(nd&&(nd.active===true||(nd.node&&nd.node.active===true))){live=1;break}}}}catch(e){nm='<err>'}"
    @"S('N'+i+' live='+live+' rods='+rn.length+' '+nm)}"
    @"S('### ARROWS '+n+'  format=<idx> <live> <nCells> <firstCell> <lastCell> <cell,cell,...>');"
    @"for(var i=0;i<n&&i<400;i++){var cs=aal[i]||[];var live=0,rn2=anl?anl[i]:null;"
    @"try{if(rn2&&rn2.length){for(var z2=0;z2<rn2.length;z2++){var nd3=rn2[z2];"
    @"if(nd3&&(nd3.active===true||(nd3.node&&nd3.node.active===true))){live=1;break}}}}catch(e){}"
    @"S(i+' '+live+' '+cs.length+' '+(cs[0]===undefined?'-':cs[0])+' '+(cs.length?cs[cs.length-1]:'-')+' '+cs.join(','))}"
    @"return o.join('\\n')}"
    @"var s='';try{s=P(W)}catch(e){s='LEVEL_ERR '+e}"
    @"S(s);return out.join('\\n')})()";
}

// v7 probe #2 -- dedup by component class name, then dump EVERY own property of
// one representative instance. v6's section D burned its whole 49-hit budget on
// 25 identical `isColorSwitch=false` rows, so the interesting state arrays were
// never reached. This is the fix.
static NSString *compJS(void) {
    return @"(function(){var out=[];"
    @"function S(s){out.push(String(s))}"
    @"var W=null;"
    @"try{for(var i=0;i<window.length;i++){try{var w=frames[i];var h=String(w.location.href);if(h.indexOf('iframe')>=0){W=w;break}}catch(e){}}}catch(e){}"
    @"if(!W){try{W=frames[0]}catch(e){}}"
    @"if(!W){return 'NO_IFRAME'}"
    @"function P(W){"
    @"var o=[];function S(s){o.push(String(s))}"
    @"function J(v,mx){try{var s=JSON.stringify(v);if(s===undefined)s='[u]';if(mx&&s.length>mx)s=s.slice(0,mx)+'...';return s}catch(e){return '[circ]'}}"
    @"function K(x){var a=[];try{for(var k in x)a.push(k)}catch(e){}return a}"
    @"function SH(v,dp){try{dp=dp||0;if(v===null||v===undefined)return String(v);"
    @"if(typeof v!=='object')return JSON.stringify(v);"
    @"if(typeof v.length==='number'&&dp<2)return '['+v.length+']'+(v.length?(' '+SH(v[0],dp+1)):'');"
    @"if(v.name!==undefined&&v.active!==undefined)return 'node['+v.name+',act='+(v.active?1:0)+',pos='+J(v.position,60)+']';"
    @"var ks=[],k;for(k in v){if(k.charAt(0)==='_')continue;var t=typeof v[k];if(t==='function')continue;"
    @"ks.push(k+'='+(t==='object'?'<'+t+'>':String(v[k]).slice(0,26)));if(ks.length>9)break}"
    @"return '{'+ks.join(' ')+'}'}catch(e){return '<err>'}}"
    @"var cc=W.cc;if(!cc){S('NO_CC');return o.join('\\n')}"
    @"function CN(c){try{if(cc.js&&cc.js.getClassName){var n=cc.js.getClassName(c);if(n)return n}}catch(e){}try{return (c&&c.constructor&&c.constructor.name)||'?'}catch(e){return '?'}}"
    @"var sc=null;try{sc=cc.director.getScene()}catch(e){}"
    @"if(!sc){S('NO_SCENE');return o.join('\\n')}"
    @"var skip={_components:1,_children:1,_parent:1,_node:1,__prefab:1,_objFlags:1,_eventProcessor:1,_enabled:1,node:1,enabled:1};"
    @"var by={};"
    @"(function walk(nd,d){if(!nd||d>14)return;var a=[];try{a=nd._components||nd.components||[]}catch(e){}"
    @"for(var i=0;i<a.length;i++){var c=a[i];if(!c)continue;var nm=CN(c);"
    @"if(!by[nm])by[nm]={n:0,f:c,node:nd.name,path:''};by[nm].n++}"
    @"var ch=nd.children||[];for(var j=0;j<ch.length;j++)walk(ch[j],d+1)})(sc,0);"
    @"var names=K(by);"
    @"S('### COMPONENT CLASSES ('+names.length+')');"
    @"for(var q=0;q<names.length;q++){var nm=names[q],e=by[nm],c=e.f;"
    @"S('['+nm+'] x'+e.n+' onNode='+e.node);"
    @"var ks=[];try{ks=Object.keys(c)}catch(err){}"
    @"for(var i=0;i<ks.length;i++){var k=ks[i];if(skip[k])continue;"
    @"var v=null;try{v=c[k]}catch(err){continue}"
    @"if(v===null||v===undefined)continue;var t=typeof v;if(t==='function')continue;"
    @"if(k.charAt(0)==='_'&&t!=='object')continue;"
    @"if(t==='object'){"
    @"if(typeof v.length==='number'){var head='';"
    @"if(v.length){if(typeof v[0]==='object'){var sh=[];for(var z=0;z<3;z++)sh.push(SH(v[z]));head=' first3='+sh.join(' | ')}else head=' val='+J(v,240)}"
    @"S('  .'+k+' array['+v.length+']'+head)}"
    @"else{var kv=[],kk=K(v);for(var z2=0;z2<kk.length&&z2<20;z2++){var k2=kk[z2],v2;try{v2=v[k2]}catch(err){continue}"
    @"var t2=typeof v2;if(t2==='function')continue;kv.push(k2+'='+(t2==='object'?'<obj>':String(v2).slice(0,26)))}"
    @"S('  .'+k+' object{'+kv.join(' ')+'}')}}"
    @"else S('  .'+k+' = '+J(v,140))}"
    @"}"
    @"return o.join('\\n')}"
    @"var s='';try{s=P(W)}catch(e){s='COMP_ERR '+e}"
    @"S(s);return out.join('\\n')})()";
}

// v8 probe #1 -- THE decisive one. Instead of guessing the movement rule from
// the geometry, print the game's own implementation. Cocos classes are plain
// ES classes in the bundle, so `fn.toString()` hands back the real source.
// This is completely side-effect free (no game method is called).
static NSString *funcJS(void) {
    return @"(function(){var out=[];"
    @"function S(s){out.push(String(s))}"
    @"var W=null;"
    @"try{for(var i=0;i<window.length;i++){try{var w=frames[i];var h=String(w.location.href);if(h.indexOf('iframe')>=0){W=w;break}}catch(e){}}}catch(e){}"
    @"if(!W){try{W=frames[0]}catch(e){}}"
    @"if(!W){return 'NO_IFRAME'}"
    @"function P(W){"
    @"var o=[];function S(s){o.push(String(s))}"
    @"var cc=W.cc;if(!cc){S('NO_CC');return o.join('\\n')}"
    @"function CN(c){try{if(cc.js&&cc.js.getClassName){var n=cc.js.getClassName(c);if(n)return n}}catch(e){}try{return (c&&c.constructor&&c.constructor.name)||'?'}catch(e){return '?'}}"
    @"var sc=null;try{sc=cc.director.getScene()}catch(e){}"
    @"if(!sc){S('NO_SCENE');return o.join('\\n')}"
    @"var gs=null,as=null;"
    @"(function walk(nd,d){if(!nd||d>14)return;var a=[];try{a=nd._components||nd.components||[]}catch(e){}"
    @"for(var i=0;i<a.length;i++){var nm=CN(a[i]);if(nm==='GridSystem'&&!gs)gs=a[i];else if(nm==='ArrowSystem'&&!as)as=a[i]}"
    @"var ch=nd.children||[];for(var j=0;j<ch.length;j++)walk(ch[j],d+1)})(sc,0);"
    @"function dump(obj,tag,names,cap){"
    @"S('##### '+tag+' #####');"
    @"if(!obj){S('  (component not found)');return}"
    @"for(var i=0;i<names.length;i++){var n=names[i],f=null;"
    @"try{f=obj[n]}catch(e){S('  -- '+n+' <read err>');continue}"
    @"if(typeof f!=='function'){S('  -- '+n+' is '+typeof f);continue}"
    @"var s='';try{s=String(f)}catch(e){s='<toString failed>';}"
    @"S('===== '+tag+'.'+n+' ('+s.length+'B) =====');S(s.slice(0,cap))}}"
    @"dump(as,'ArrowSystem',['onArrowTouchStart','arrowMove','arrowMoveRollback',"
    @"'checkPathPass','checkPathObsCount','checkLineSegmentIntersection',"
    @"'getCanPassLine','classificationLine','lineAutoPassByCount',"
    @"'onCheckCanPassLineProp','hideArrowList','getTargetPos','getAngle',"
    @"'checkGameWin','oneCheckGameWin','getProgressStr','update'],3000);"
    @"dump(gs,'GridSystem',['worldToGrid','getPointsInDirection','getPointsInDirectionByRowCol',"
    @"'getDirectionType','getXYIndexByIndex','getPointsBetween','getPointsBetweenByIndex',"
    @"'checkLineType','getGridPosition','getGridPointByIndex'],2000);"
    @"return o.join('\\n')}"
    @"var s='';try{s=P(W)}catch(e){s='FUNC_ERR '+e}"
    @"S(s);return out.join('\\n')})()";
}

// v8 probe #2 -- the physical model of one arrow. v7 taught us
// arrowNodeList[i] is an ARRAY of rod nodes (its straight segments) and that
// 165 arrows decompose into exactly 651 rods. So each rod must know its cells
// and its direction. Walk one arrow and one grid cell down to primitives.
static NSString *rodJS(void) {
    return @"(function(){var out=[];"
    @"function S(s){out.push(String(s))}"
    @"var W=null;"
    @"try{for(var i=0;i<window.length;i++){try{var w=frames[i];var h=String(w.location.href);if(h.indexOf('iframe')>=0){W=w;break}}catch(e){}}}catch(e){}"
    @"if(!W){try{W=frames[0]}catch(e){}}"
    @"if(!W){return 'NO_IFRAME'}"
    @"function P(W){"
    @"var o=[];function S(s){o.push(String(s))}"
    @"function J(v,mx){try{var s=JSON.stringify(v);if(s===undefined)s='[u]';if(mx&&s.length>mx)s=s.slice(0,mx)+'...';return s}catch(e){return '[circ]'}}"
    @"function K(x){var a=[];try{for(var k in x)a.push(k)}catch(e){}return a}"
    @"var cc=W.cc;if(!cc){S('NO_CC');return o.join('\\n')}"
    @"function CN(c){try{if(cc.js&&cc.js.getClassName){var n=cc.js.getClassName(c);if(n)return n}}catch(e){}try{return (c&&c.constructor&&c.constructor.name)||'?'}catch(e){return '?'}}"
    @"var sc=null;try{sc=cc.director.getScene()}catch(e){}"
    @"if(!sc){S('NO_SCENE');return o.join('\\n')}"
    @"var gs=null,as=null;"
    @"(function walk(nd,d){if(!nd||d>14)return;var a=[];try{a=nd._components||nd.components||[]}catch(e){}"
    @"for(var i=0;i<a.length;i++){var nm=CN(a[i]);if(nm==='GridSystem'&&!gs)gs=a[i];else if(nm==='ArrowSystem'&&!as)as=a[i]}"
    @"var ch=nd.children||[];for(var j=0;j<ch.length;j++)walk(ch[j],d+1)})(sc,0);"
    @"function dmp(v,tag,dep){"
    @"if(v===null||v===undefined){S(tag+' = '+String(v));return;}"
    @"if(typeof v!=='object'){S(tag+' = '+J(v,140));return;}"
    @"if(typeof v.length==='number'&&dep<3){"
    @"S(tag+' = array['+v.length+']');"
    @"for(var z=0;z<v.length&&z<3;z++){dmp(v[z],tag+'['+z+']',dep+1);}"
    @"return;}"
    @"S(tag+' = <'+CN(v)+'>');"
    @"var ks=K(v);"
    @"for(var z2=0;z2<ks.length;z2++){"
    @"var k=ks[z2];"
    @"if(k.charAt(0)==='_'&&k!=='_name'&&k!=='_active'&&k!=='_lpos'){continue;}"
    @"var vv=null,ok=false;"
    @"try{vv=v[k];ok=true;}catch(ee){ok=false;}"
    @"if(!ok){continue;}"
    @"var t=typeof vv;"
    @"if(t==='function'){continue;}"
    @"if(t==='object'&&vv!==null&&typeof vv.length==='number'){"
    @"S('   '+tag+'.'+k+' array['+vv.length+']'+(vv.length&&typeof vv[0]!=='object'?' '+J(vv,200):''));"
    @"}else if(t==='object'&&vv!==null){"
    @"S('   '+tag+'.'+k+' object{'+K(vv).slice(0,16).join(',')+'}');"
    @"}else{"
    @"S('   '+tag+'.'+k+' = '+J(vv,110));"
    @"}"
    @"}"
    @"}"
    @"function dumpComp(obj,tag){"
    @"if(!obj){S(tag+' = <null>');return;}"
    @"var cs=[];"
    @"try{cs=obj._components||obj.components||[];}catch(e){cs=[];}"
    @"S(tag+' name='+(obj.name||'?')+' childCount='+(((obj.children||[]).length))+' comps='+cs.length);"
    @"for(var i=0;i<cs.length;i++){"
    @"var c=cs[i];"
    @"S('  <'+CN(c)+'>');"
    @"var ks2=K(c);"
    @"for(var j=0;j<ks2.length;j++){"
    @"var k2=ks2[j];"
    @"if(k2.charAt(0)==='_'){continue;}"
    @"var v2=null,ok2=false;"
    @"try{v2=c[k2];ok2=true;}catch(e2){ok2=false;}"
    @"if(!ok2){continue;}"
    @"var t2=typeof v2;"
    @"if(t2==='function'){continue;}"
    @"if(t2==='object'&&v2!==null&&typeof v2.length==='number'){"
    @"S('    .'+k2+' array['+v2.length+']'+(v2.length&&typeof v2[0]!=='object'?' '+J(v2,200):''));"
    @"}else if(t2==='object'&&v2!==null){"
    @"S('    .'+k2+' object{'+K(v2).slice(0,14).join(',')+'}');"
    @"}else{"
    @"S('    .'+k2+' = '+J(v2,110));"
    @"}"
    @"}"
    @"}"
    @"}"
    @"S('##### ARROW 0 的三段结构 #####');"
    @"try{var ap=as.arrowPointList[0],aa=as.arrowAllPointList[0],an=as.arrowNodeList[0];"
    @"S('arrowPointList[0] len='+(ap?ap.length:-1)+' = '+J(ap,300));"
    @"S('arrowAllPointList[0] len='+(aa?aa.length:-1)+' = '+J(aa,300));"
    @"S('arrowNodeList[0] 杆数 = '+(an?an.length:-1))}catch(e){S('head err '+e)}"
    @"for(var q=0;q<3;q++){try{dmp(as.arrowNodeList[q],'arrowNodeList['+q+']',0)}catch(e){S('erl '+e)}}"
    @"S('##### 一根杆的内部结构（展开到组件属性）#####');"
    @"try{var rods=as.arrowNodeList[0];if(rods&&rods.length){dumpComp(rods[0],'rod0')}else{S('arrow0 has no rod')}}catch(e){S('rod err '+e)}"
    @"S('##### 网格单元节点的结构 #####');"
    @"try{var gpl=gs.gridPointList;S('gridPointList len='+gpl.length);"
    @"dmp(gpl[0],'gridPointList[0]',0);"
    @"dmp(gpl[1],'gridPointList[1]',0);"
    @"dmp(gpl[100],'gridPointList[100]',0)}catch(e){S('gpl err '+e)}"
    @"S('##### ArrowSystem 的几个数值字段 #####');"
    @"try{S('lineOffeset='+as.lineOffeset+' timer='+as.timer+' iswin='+as.iswin+' isUseVit='+as.isUseVit+' soundIndex='+as.soundIndex)}catch(e){}"
    @"try{S('arrowColorList='+J(as.arrowColorList,300)+' arrowSpecialList='+J(as.arrowSpecialList,300))}catch(e){}"
    @"try{S('alreadyReduceHpLineList='+J(as.alreadyReduceHpLineList,300))}catch(e){}"
    @"try{S('DragBg minScale='+as.dragBg.minScale+' maxScale='+as.dragBg.maxScale+' enableScale='+as.dragBg.enableScale)}catch(e){}"
    @"return o.join('\\n')}"
    @"var s='';try{s=P(W)}catch(e){s='ROD_ERR '+e}"
    @"S(s);return out.join('\\n')})()";
}

// v9 probe: THE ground truth. v8's FUNCSRC section handed us the game's own
// rule verbatim, so v8's callJS was both mis-targeted and subtly harmful:
//   - checkPathPass(0) / checkPathObsCount(0) were passed an INDEX, but the
//     function signature is checkPathPass(arrowList) -- it does `t[0].eulerAngles`
//     and `arrowNodeList.indexOf(t)`. Hence "undefined is not an object".
//   - getCanPassLine() returns {lineID, arrowList} where arrowList is an array
//     of cc.Nodes -> JSON.stringify hits a cycle, so all we saw was [circ].
//     The useful field is .lineID alone.
//   - getDirectionType / getXYIndexByIndex / checkLineType do NOT exist on
//     ArrowSystem (only on GridSystem) -- three wasted lines.
//   - getPointsInDirection(index, dirVec) needs a Vec3 with .clone(); passing 0
//     threw "i.clone is not a function".
//   - ** classificationLine() is NOT read-only **: it calls onArrowTouchStart on
//     the three longest lines, i.e. it actually MOVES arrows. v8 called it and
//     perturbed the board. It is never called again.
//
// The decoded rule (from FUNCSRC):
//   direction = from rod[0].eulerAngles.z:  0 -> (-1,0) left, 90 -> (0,-1) down,
//                                         180 -> (1,0) right, -90 -> (0,1) up
//   head cell = arrowPointList[lineID][0]
//   corridor  = gridSystem.getPointsInDirection(head, dir)  // head+1 .. edge
//   passable  <=> no cell in the corridor has a gridPointLineIDInfo entry
//                 (checkPathPass returns -1)
// So this probe asks the game for that verdict directly, plus the live
// occupancy map, plus each arrow's real direction angle.
static NSString *callJS(void) {
    return @"(function(){var out=[];"
    @"function S(s){out.push(String(s))}"
    @"var W=null;"
    @"try{for(var i=0;i<window.length;i++){try{var w=frames[i];var h=String(w.location.href);if(h.indexOf('iframe')>=0){W=w;break}}catch(e){}}}catch(e){}"
    @"if(!W){try{W=frames[0]}catch(e){}}"
    @"if(!W){return 'NO_IFRAME'}"
    @"function P(W){"
    @"var o=[];function S(s){o.push(String(s))}"
    @"var cc=W.cc;if(!cc){S('NO_CC');return o.join('\\n')}"
    @"function CN(c){try{if(cc.js&&cc.js.getClassName){var n=cc.js.getClassName(c);if(n)return n}}catch(e){}try{return (c&&c.constructor&&c.constructor.name)||'?'}catch(e){return '?'}}"
    @"var sc=null;try{sc=cc.director.getScene()}catch(e){}"
    @"if(!sc){S('NO_SCENE');return o.join('\\n')}"
    @"var gs=null,as=null;"
    @"(function walk(nd,d){if(!nd||d>14)return;var a=[];try{a=nd._components||nd.components||[]}catch(e){}"
    @"for(var i=0;i<a.length;i++){var nm=CN(a[i]);if(nm==='GridSystem'&&!gs)gs=a[i];else if(nm==='ArrowSystem'&&!as)as=a[i]}"
    @"var ch=nd.children||[];for(var j=0;j<ch.length;j++)walk(ch[j],d+1)})(sc,0);"
    @"if(!as){S('NO_ArrowSystem');return o.join('\\n')}"
    @"var nl=as.arrowNodeList||[];"
    @"S('### A. DIRECTION AND HEAD  format: <i> z=<eulerAngles.z> head=<cell> rods=<n> pts=<n>');"
    @"for(var i=0;i<nl.length;i++){"
    @"var z='?',hd='?',nr=0,np=0;"
    @"try{var rods=nl[i];nr=rods?rods.length:0;if(rods&&rods.length){var r0=rods[0];z=r0.eulerAngles?r0.eulerAngles.z:'na'}}catch(e){z='err'}"
    @"try{var ap=as.arrowPointList[i];np=ap?ap.length:0;hd=ap?ap[0]:'?'}catch(e){hd='err'}"
    @"S(i+' z='+z+' head='+hd+' rods='+nr+' pts='+np)}"
    @"S('### B. PASS (game verdict)  format: <i> <blockerCell|-1=canPass>');"
    @"var cp=[];var npass=0;"
    @"for(var i=0;i<nl.length;i++){"
    @"var r='?';"
    @"try{r=as.checkPathPass(nl[i])}catch(e){r='ERR'}"
    @"S(i+' '+r);"
    @"if(r===-1){npass++;cp.push(i)}}"
    @"S('CANPASS_COUNT='+npass);"
    @"S('CANPASS_LIST='+cp.join(','));"
    @"try{var g=as.getCanPassLine();S('getCanPassLine.lineID='+(g?g.lineID:'null'))}catch(e){S('getCanPassLine ERR '+e)}"
    @"S('### C. OCCUPANCY gridPointLineIDInfo  (live cell -> lineID)');"
    @"try{var m=as.gridSystem.gridPointLineIDInfo;"
    @"S('hasSize='+(m&&typeof m.size==='number')+' size='+(m?m.size:'?'));"
    @"if(m&&typeof m.forEach==='function'){var ent=[];m.forEach(function(v,k){ent.push(k+':'+v)});"
    @"S('entries='+ent.length);S(ent.join(' '))}"
    @"else{S('keys='+((m&&Object.keys(m).length)||0));S(JSON.stringify(m).slice(0,20000))}}catch(e){S('occ ERR '+e)}"
    @"S('### D. direction enum sanity (Vec3 args, read-only)');"
    @"function V3(x,y,z){try{if(cc.v3)return cc.v3(x,y,z);if(cc.Vec3)return new cc.Vec3(x,y,z)}catch(e){}return null}"
    @"try{var dirs=[V3(1,0,0),V3(-1,0,0),V3(0,1,0),V3(0,-1,0)];var tags=['+x','-x','+y','-y'];"
    @"for(var i=0;i<dirs.length;i++){if(!dirs[i]){S('  V3 unavailable');break}"
    @"var t1='?';try{t1=gs.getDirectionType(dirs[i])}catch(e){t1='ERR '+e}"
    @"S('  getDirectionType('+tags[i]+')='+t1)}}catch(e){S('  enum ERR '+e)}"
    @"try{S('  head0 corridor='+JSON.stringify(gs.getPointsInDirection(as.arrowPointList[0][0],V3(1,0,0)).slice(0,6)))}catch(e){S('  corridor ERR '+e)}"
    @"S('### E. 其它在跑的数值');"
    @"try{S('soundIndex='+as.soundIndex+' timer='+as.timer+' iswin='+as.iswin+' isUseVit='+as.isUseVit+' lineOffeset='+as.lineOffeset)}catch(e){}"
    @"try{S('alreadyReduceHpLineList='+JSON.stringify(as.alreadyReduceHpLineList))}catch(e){}"
    @"return o.join('\\n')}"
    @"var s='';try{s=P(W)}catch(e){s='CALL_ERR '+e}"
    @"S(s);return out.join('\\n')})()";
}

#pragma mark - v10: the actual solver

// The rule was verified 165/165 against the game's own checkPathPass verdicts,
// so the solver can now run entirely on OUR side -- it needs only two things
// from the game: the static arrow cell lists, and which arrows are still alive.
//
//   alive   = arrowNodeList[i] has at least one active rod node
//             (on a successful tap the game does `t.forEach(t => t.active=false)`)
//   occ     = union of the cells of all alive arrows
//   pass(i) = the corridor from cells[0] in direction (cells[0]-cells[1]) is empty
//
// Removal only ever FREES cells, so the set of passable arrows grows
// monotonically and greedy converges to an order-independent fixed point.
// If greedy clears everything, the level is solved; if it stalls, so would the
// player. Verified on the real board: 165/165, zero stalls.
//
// Screen conversion comes from the LIVE Grid node transform, so it keeps
// working when the player pans or zooms the board (DragBg allows both):
//   world = gridNode.worldPosition + gridPositions[row][col] * gridNode.worldScale
//   pt    = (world.x * K, (visibleSize.height - world.y) * K)      K = frameW / visW
static NSString *solveJS(void) {
    return @"(function(){var out=[];"
    @"function S(s){out.push(String(s))}"
    @"var W=null;"
    @"try{for(var i=0;i<window.length;i++){try{var w=frames[i];var h=String(w.location.href);if(h.indexOf('iframe')>=0){W=w;break}}catch(e){}}}catch(e){}"
    @"if(!W){try{W=frames[0]}catch(e){}}"
    @"if(!W){return 'NO_IFRAME'}"
    @"function P(W){"
    @"var o=[];function S(s){o.push(String(s))}"
    @"var cc=W.cc;if(!cc){S('NO_CC');return o.join('\\n')}"
    @"function CN(c){try{if(cc.js&&cc.js.getClassName){var n=cc.js.getClassName(c);if(n)return n}}catch(e){}try{return (c&&c.constructor&&c.constructor.name)||'?'}catch(e){return '?'}}"
    @"var sc=null;try{sc=cc.director.getScene()}catch(e){}"
    @"if(!sc){S('NO_SCENE');return o.join('\\n')}"
    @"var gs=null,as=null;"
    @"(function walk(nd,d){if(!nd||d>14)return;var a=[];try{a=nd._components||nd.components||[]}catch(e){}"
    @"for(var i=0;i<a.length;i++){var nm=CN(a[i]);if(nm==='GridSystem'&&!gs)gs=a[i];else if(nm==='ArrowSystem'&&!as)as=a[i]}"
    @"var ch=nd.children||[];for(var j=0;j<ch.length;j++)walk(ch[j],d+1)})(sc,0);"
    @"if(!gs||!as){S('ERR_NO_COMPONENT');return o.join('\\n')}"
    @"var GW=gs.gridWidth,GH=gs.gridHeight;"
    @"var A=as.arrowAllPointList||[],N=as.arrowNodeList||[];"
    @"var vs=null,fs=null;try{vs=cc.view.getVisibleSize();fs=cc.view.getFrameSize()}catch(e){}"
    @"if(!vs||!fs){S('ERR_NO_VIEW');return o.join('\\n')}"
    @"var K=fs.width/vs.width;"
    @"var gn=gs.node,gwp=gn.getWorldPosition(),gsc=gn.getWorldScale();"
    @"var GP=gs.gridPositions;"
    @"function scr(cell){var r=Math.floor(cell/GW),c=cell%GW;var p=GP[r][c];"
    @"var wx=gwp.x+p.x*gsc.x,wy=gwp.y+p.y*gsc.y;"
    @"return [wx*K,(vs.height-wy)*K]}"
    @"var aliveSet={},aliveN=0;"
    @"for(var i=0;i<A.length;i++){var rods=N[i],on=0;"
    @"if(rods&&rods.length){for(var z=0;z<rods.length;z++){var nd=rods[z];"
    @"if(nd&&(nd.active===true||(nd.node&&nd.node.active===true))){on=1;break}}}"
    @"if(on){aliveSet[i]=1;aliveN++}}"
    @"var occ={};for(var i in aliveSet){var cs=A[i]||[];for(var j=0;j<cs.length;j++)occ[cs[j]]=1}"
    @"function dirOf(cs){var r0=Math.floor(cs[0]/GW),c0=cs[0]%GW;var r1=Math.floor(cs[1]/GW),c1=cs[1]%GW;return [r0-r1,c0-c1]}"
    @"function corridor(head,d){var r=Math.floor(head/GW),c=head%GW;var o2=[];"
    @"r+=d[0];c+=d[1];"
    @"while(r>=0&&r<GH&&c>=0&&c<GW){o2.push(r*GW+c);r+=d[0];c+=d[1]}"
    @"return o2}"
    @"function canPass(i){var cs=A[i];if(!cs||cs.length<2)return false;"
    @"var cor=corridor(cs[0],dirOf(cs));"
    @"for(var j=0;j<cor.length;j++){if(occ[cor[j]])return false}"
    @"return true}"
    @"var order=[];var guard=0;"
    @"while(guard++<1000){var f=-1;"
    @"for(var q=0;q<A.length;q++){if(!aliveSet[q])continue;if(canPass(q)){f=q;break}}"
    @"if(f<0)break;"
    @"var cs=A[f]||[];for(var j=0;j<cs.length;j++){delete occ[cs[j]]}"
    @"delete aliveSet[f];order.push(f)}"
    @"var remain=0,remainList=[];"
    @"for(var q=0;q<A.length;q++){if(aliveSet[q]){remain++;if(remainList.length<20)remainList.push(q)}}"
    @"S('### PLAN alive='+aliveN+' solvable='+order.length+' remain='+remain+' total='+A.length+' K='+K.toFixed(5));"
    @"var DC={'-1,0':'D','1,0':'U','0,-1':'L','0,1':'R'};"
    @"S('### STEPS <step> <arrowIdx> <xPt> <yPt> <dir> <nCells>');"
    @"for(var s=0;s<order.length&&s<220;s++){var i2=order[s];var cs2=A[i2]||[];"
    @"var d=dirOf(cs2);var sp=scr(cs2[0]);"
    @"S((s+1)+' '+i2+' '+sp[0].toFixed(1)+' '+sp[1].toFixed(1)+' '+(DC[d[0]+','+d[1]]||'?')+' '+cs2.length)}"
    @"if(remain>0)S('### STUCK n='+remain+' first='+remainList.join(','));"
    @"return o.join('\\n')}"
    @"var s2='';try{s2=P(W)}catch(e){s2='SOLVE_ERR '+e}"
    @"S(s2);return out.join('\\n')})()";
}

// ---- marker layer -------------------------------------------------------
// Sits UNDER the recon panel (level 9999 vs 10000) and is fully click-through:
// the marker labels have userInteractionEnabled = NO, and ReconWindow turns a
// hitTest that lands on the bare root view into nil, so the game keeps
// receiving every touch.
static UIWindow *gSolverWindow = nil;

// Call on the main thread only.
static UIView *ensureSolverWindow(void) {
    if (!gSolverWindow) {
        gSolverWindow = makeOverlayWindow();
        gSolverWindow.windowLevel = 9999;
        gSolverWindow.backgroundColor = [UIColor clearColor];
        UIViewController *r = [[UIViewController alloc] init];
        r.view = [[PassthroughView alloc] initWithFrame:gSolverWindow.bounds];
        r.view.backgroundColor = [UIColor clearColor];
        r.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        gSolverWindow.rootViewController = r;
    }
    gSolverWindow.hidden = NO;
    return gSolverWindow.rootViewController.view;
}

// Progress strip for auto-play (tag 7003). Kept separate from the step markers
// (7001/7002) so polling every 500 ms does not wipe them.
static void updateAutoHud(NSString *text) {
    runOnMainSync(^{
        UIView *root = ensureSolverWindow();
        UILabel *l = nil;
        for (UIView *v in root.subviews) {
            if (v.tag == 7003 && [v isKindOfClass:[UILabel class]]) { l = (UILabel *)v; break; }
        }
        if (!l) {
            l = [[UILabel alloc] initWithFrame:CGRectMake(8, 40, root.bounds.size.width - 16, 24)];
            l.tag = 7003;
            l.textAlignment = NSTextAlignmentCenter;
            l.font = [UIFont boldSystemFontOfSize:12];
            l.textColor = [UIColor whiteColor];
            l.layer.cornerRadius = 7;
            l.layer.masksToBounds = YES;
            l.userInteractionEnabled = NO;
            [root addSubview:l];
        }
        l.backgroundColor = [UIColor colorWithRed:0.80 green:0.42 blue:0.05 alpha:0.92];
        l.text = text;
    });
}

static void hideAutoHud(void) {
    runOnMainSync(^{
        if (!gSolverWindow) return;
        UIView *root = gSolverWindow.rootViewController.view;
        for (UIView *v in [root.subviews copy]) {
            if (v.tag == 7003) [v removeFromSuperview];
        }
    });
}

static void clearSolverMarkers(void) {
    if (!gSolverWindow) return;
    UIView *root = gSolverWindow.rootViewController.view;
    for (UIView *v in [root.subviews copy]) {
        if (v.tag == 7001 || v.tag == 7002) [v removeFromSuperview];
    }
}

static void hideSolverMarkers(void) {
    runOnMainSync(^{
        clearSolverMarkers();
        if (gSolverWindow) gSolverWindow.hidden = YES;
    });
}

static void showSolverPlan(NSArray<NSDictionary *> *steps, NSString *hud) {
    runOnMainSync(^{
        UIView *root = ensureSolverWindow();
        clearSolverMarkers();

        UILabel *h = [[UILabel alloc] initWithFrame:CGRectMake(8, 8, root.bounds.size.width - 16, 26)];
        h.tag = 7001;
        h.text = hud;
        h.textAlignment = NSTextAlignmentCenter;
        h.font = [UIFont boldSystemFontOfSize:12];
        h.textColor = [UIColor whiteColor];
        h.backgroundColor = [UIColor colorWithRed:0.10 green:0.42 blue:0.20 alpha:0.90];
        h.layer.cornerRadius = 8;
        h.layer.masksToBounds = YES;
        h.userInteractionEnabled = NO;
        [root addSubview:h];

        NSUInteger n = steps.count;
        for (NSUInteger k = 0; k < n; k++) {
            NSDictionary *st = steps[k];
            CGFloat x = [st[@"x"] doubleValue];
            CGFloat y = [st[@"y"] doubleValue];
            BOOL first = (k == 0);
            CGFloat d = first ? 42.0 : 30.0;
            UILabel *m = [[UILabel alloc] initWithFrame:CGRectMake(x - d / 2.0, y - d / 2.0, d, d)];
            m.tag = 7002;
            m.text = [NSString stringWithFormat:@"%lu", (unsigned long)(k + 1)];
            m.textAlignment = NSTextAlignmentCenter;
            m.font = [UIFont boldSystemFontOfSize:(first ? 19 : 14)];
            m.textColor = [UIColor whiteColor];
            m.backgroundColor = first ? [UIColor colorWithRed:0.88 green:0.15 blue:0.15 alpha:0.94]
                                      : [UIColor colorWithRed:0.10 green:0.45 blue:0.85 alpha:0.82];
            m.layer.cornerRadius = d / 2.0;
            m.layer.masksToBounds = YES;
            m.layer.borderWidth = first ? 3.0 : 2.0;
            m.layer.borderColor = [UIColor whiteColor].CGColor;
            m.userInteractionEnabled = NO;
            [root addSubview:m];
        }
        gSolverWindow.hidden = NO;
    });
}

#pragma mark - v11: auto-play

// Instead of synthesising UITouch objects (private ivars, version-fragile), we
// call the game's OWN tap handler from its JS realm:
//
//     as.onArrowTouchStart(as.arrowNodeList[i], i, false)
//
// That is literally the function a finger ends up in, so it does all the normal
// bookkeeping itself: hideShowArrowTouch, checkPathPass, clearLinePos,
// checkGameWin, soundIndex. The game can never end up in an inconsistent state.
//
// Safety: right before every call we re-verify with the game's OWN
// checkPathPass() and abort the whole run if it disagrees with our solver -- so
// an auto move can never cost a heart.
//
// The loop lives inside the page (setTimeout chain) so ObjC only polls a tiny
// status string once every 500 ms instead of driving 165 round-trips.
static NSString *startAutoJS(void) {
    return @"(function(){var W=null;"
    @"try{for(var i=0;i<window.length;i++){try{var w=frames[i];var h=String(w.location.href);if(h.indexOf('iframe')>=0){W=w;break}}catch(e){}}}catch(e){}"
    @"if(!W){try{W=frames[0]}catch(e){}}"
    @"if(!W)return 'NO_IFRAME';"
    @"try{if(W.__reconAuto)W.__reconAuto.running=0}catch(e){}"
    @"var cc=W.cc;if(!cc)return 'NO_CC';"
    @"function CN(c){try{if(cc.js&&cc.js.getClassName){var n=cc.js.getClassName(c);if(n)return n}}catch(e){}try{return (c&&c.constructor&&c.constructor.name)||'?'}catch(e){return '?'}}"
    @"var sc=null;try{sc=cc.director.getScene()}catch(e){}"
    @"if(!sc)return 'NO_SCENE';"
    @"var gs=null,as=null;"
    @"(function walk(nd,d){if(!nd||d>14)return;var a=[];try{a=nd._components||nd.components||[]}catch(e){}"
    @"for(var i=0;i<a.length;i++){var nm=CN(a[i]);if(nm==='GridSystem'&&!gs)gs=a[i];else if(nm==='ArrowSystem'&&!as)as=a[i]}"
    @"var ch=nd.children||[];for(var j=0;j<ch.length;j++)walk(ch[j],d+1)})(sc,0);"
    @"if(!gs||!as)return 'NO_COMPONENT';"
    @"var GW=gs.gridWidth,GH=gs.gridHeight,A=as.arrowAllPointList||[],N=as.arrowNodeList||[];"
    @"if(!A.length)return 'NO_ARROWS';"
    @"var st={running:1,step:0,alive:0,lastIdx:-1,msg:'start',delay:140};W.__reconAuto=st;"
    @"function live(i){var r=null;try{r=N[i]}catch(e){return 0}"
    @"if(!r||!r.length)return 0;"
    @"for(var z=0;z<r.length;z++){var nd=r[z];if(nd&&(nd.active===true||(nd.node&&nd.node.active===true)))return 1}"
    @"return 0}"
    @"function dirOf(cs){var r0=Math.floor(cs[0]/GW),c0=cs[0]%GW;var r1=Math.floor(cs[1]/GW),c1=cs[1]%GW;return [r0-r1,c0-c1]}"
    @"function ok(i,occ){var cs=A[i];if(!cs||cs.length<2)return false;"
    @"var d=dirOf(cs);var r=Math.floor(cs[0]/GW),c=cs[0]%GW;"
    @"r+=d[0];c+=d[1];"
    @"while(r>=0&&r<GH&&c>=0&&c<GW){if(occ[r*GW+c])return false;r+=d[0];c+=d[1]}"
    @"return true}"
    @"var loop=function(){"
    @"if(!st.running){st.msg='stopped';return;}"
    @"if(st.step>420){st.running=0;st.msg='stepcap';return;}"
    @"var al=[],occ={};"
    @"for(var i=0;i<A.length;i++){if(!live(i))continue;al.push(i);var cs=A[i];for(var j=0;j<cs.length;j++)occ[cs[j]]=1;}"
    @"st.alive=al.length;"
    @"if(!al.length){st.running=0;st.msg='cleared';return;}"
    @"var pick=-1;"
    @"for(var q=0;q<al.length;q++){if(ok(al[q],occ)){pick=al[q];break;}}"
    @"if(pick<0){st.running=0;st.msg='stuck alive='+al.length;return;}"
    @"var vd=-99;try{vd=as.checkPathPass(N[pick]);}catch(e){vd=-98;}"
    @"if(vd!==-1){st.running=0;st.msg='verifyfail i='+pick+' v='+vd;return;}"
    @"try{as.onArrowTouchStart(N[pick],pick,false);}catch(e){st.running=0;st.msg='callerr '+e;return;}"
    @"st.step++;st.lastIdx=pick;st.msg='moved '+pick;"
    @"var wt=0;"
    @"var chk=function(){"
    @"if(!st.running)return;"
    @"wt+=140;"
    @"if(!live(pick)&&wt>=280){W.setTimeout(loop,140);return;}"
    @"if(wt>3200){W.setTimeout(loop,140);return;}"
    @"W.setTimeout(chk,140);};"
    @"W.setTimeout(chk,160);};"
    @"W.setTimeout(loop,350);"
    @"return 'AUTO_START total='+A.length;})()";
}

static NSString *autoStatusJS(void) {
    return @"(function(){var W=null;"
    @"try{for(var i=0;i<window.length;i++){try{var w=frames[i];var h=String(w.location.href);if(h.indexOf('iframe')>=0){W=w;break}}catch(e){}}}catch(e){}"
    @"if(!W){try{W=frames[0]}catch(e){}}"
    @"if(!W)return 'NO_IFRAME';"
    @"var s=null;try{s=W.__reconAuto}catch(e){}"
    @"if(!s)return 'no-auto';"
    @"return 'run='+s.running+' step='+s.step+' alive='+s.alive+' last='+s.lastIdx+' msg='+s.msg;})()";
}

static NSString *stopAutoJS(void) {
    return @"(function(){var W=null;"
    @"try{for(var i=0;i<window.length;i++){try{var w=frames[i];var h=String(w.location.href);if(h.indexOf('iframe')>=0){W=w;break}}catch(e){}}}catch(e){}"
    @"if(!W){try{W=frames[0]}catch(e){}}"
    @"if(!W)return 'NO_IFRAME';"
    @"try{if(W.__reconAuto){W.__reconAuto.running=0;return 'STOPPED step='+W.__reconAuto.step;}}catch(e){}"
    @"return 'NO_AUTO';})()";
}

// Higher score = more likely to be the game's JS host.
static NSInteger scoreWebView(WKWebView *w) {
    NSString *url = [[w.URL absoluteString] lowercaseString] ?: @"";
    NSInteger s = 0;
    if ([url containsString:@"antgame"]) s += 100;
    if ([url containsString:@"game"]) s += 40;
    if ([url containsString:@"framework"]) s -= 30;
    if ([url containsString:@"paladin"]) s += 5;
    CGSize sz = w.frame.size;
    // A zero-size web view is a JS-only host (the XR game engine style).
    if (sz.width < 1.0 || sz.height < 1.0) s += 60;
    return s;
}

static NSString *frameDesc(WKWebView *w) {
    CGRect f = w.frame;
    return [NSString stringWithFormat:@"%@ (%.0f,%.0f,%.0f,%.0f) score=%ld",
            NSStringFromClass([w class]),
            f.origin.x, f.origin.y, f.size.width, f.size.height,
            (long)scoreWebView(w)];
}

// All web views + their descriptions, gathered on the main thread.
static NSArray<WKWebView *> *webViewsWithInfo(NSArray<NSString *> **outDesc, NSInteger *outBest) {
    __block NSArray<WKWebView *> *all = nil;
    __block NSArray<NSString *> *desc = nil;
    __block NSInteger best = -1;
    runOnMainSync(^{
        NSArray<WKWebView *> *a = allWKWebViews();
        NSMutableArray *d = [NSMutableArray array];
        NSInteger bi = -1, bs = NSIntegerMin;
        for (NSUInteger i = 0; i < a.count; i++) {
            NSInteger sc = scoreWebView(a[i]);
            [d addObject:frameDesc(a[i])];
            if (sc > bs) { bs = sc; bi = (NSInteger)i; }
        }
        all = a; desc = d; best = bi;
    });
    if (outDesc) *outDesc = desc;
    if (outBest) *outBest = best;
    return all ?: @[];
}

// One-shot deep probe of EVERY web view in the app.
static NSString *probeAllWebViews(void) {
    NSMutableString *r = [NSMutableString stringWithString:@"\n=== WebView probe ===\n"];
    NSArray<NSString *> *descs = nil;
    NSInteger best = -1;
    NSArray<WKWebView *> *wes = webViewsWithInfo(&descs, &best);
    if (!wes.count) {
        [r appendString:@"No WKWebView found in the app's windows.\n"];
        return r;
    }
    [r appendFormat:@"Found %lu WKWebView(s); best index = %ld\n",
        (unsigned long)wes.count, (long)best];
    for (NSUInteger i = 0; i < wes.count && i < 6; i++) {
        WKWebView *w = wes[i];
        [r appendFormat:@"\n--- wv[%lu] %@ ---\n", (unsigned long)i, descs[i]];
        [r appendFormat:@"compact: %@\n", evalJS(w, compactJS(), 2.0)];
        [r appendFormat:@"frames:\n%@\n", evalJS(w, framesJS(), 2.0)];
        [r appendFormat:@"heavy:\n%@\n", evalJS(w, heavyJS(), 3.0)];
        if ((NSInteger)i == best) {
            [r appendFormat:@"state: %@\n", evalJS(w, miniStateJS(), 2.0)];
            [r appendFormat:@"DEEP:\n%@\n", evalJS(w, deepGameJS(), 5.0)];
            [r appendFormat:@"LEVEL:\n%@\n", evalJS(w, levelJS(), 6.0)];
            [r appendFormat:@"COMPONENTS:\n%@\n", evalJS(w, compJS(), 6.0)];
            [r appendFormat:@"FUNCSRC (游戏的判定函数源码):\n%@\n", evalJS(w, funcJS(), 8.0)];
            [r appendFormat:@"ROD (杆/单元结构):\n%@\n", evalJS(w, rodJS(), 8.0)];
            [r appendFormat:@"CALLS (只读查询):\n%@\n", evalJS(w, callJS(), 8.0)];
        }
    }
    return r;
}

#pragma mark - Sandbox directory tree

static void treeRecurse(NSString *root, NSString *rel, NSInteger depth, NSInteger maxDepth,
                        NSMutableString *out, NSInteger *lines) {
    if (*lines > 400 || depth > maxDepth) return;
    NSString *dir = rel.length ? [root stringByAppendingPathComponent:rel] : root;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *items = [fm contentsOfDirectoryAtPath:dir error:NULL];
    if (!items) return;

    unsigned long long totalBytes = 0;
    NSMutableArray *subdirs = [NSMutableArray array];
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *it in items) {
        NSString *full = [dir stringByAppendingPathComponent:it];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) {
            [subdirs addObject:it];
        } else {
            NSDictionary *a = [fm attributesOfItemAtPath:full error:NULL];
            totalBytes += [a[NSFileSize] unsignedLongLongValue];
            [files addObject:it];
        }
    }

    NSMutableString *indent = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [indent appendString:@"  "];
    [out appendFormat:@"%@%@/  (%lu files, %.1f KB)\n",
        indent, rel.length ? rel : @"<root>",
        (unsigned long)files.count, totalBytes / 1024.0];
    (*lines)++;

    if (depth >= maxDepth) {
        NSInteger shown = 0;
        for (NSString *f in [files sortedArrayUsingSelector:@selector(compare:)]) {
            if (shown >= 8) break;
            [out appendFormat:@"%@  - %@\n", indent, f];
            (*lines)++; shown++;
        }
        if ((NSInteger)files.count > shown) {
            [out appendFormat:@"%@  ... (%ld more)\n", indent, (long)(files.count - shown)];
            (*lines)++;
        }
        return;
    }
    for (NSString *sd in [subdirs sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *childRel = rel.length ? [rel stringByAppendingPathComponent:sd] : sd;
        treeRecurse(root, childRel, depth + 1, maxDepth, out, lines);
    }
}

static NSString *dumpSandboxTrees(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"\n=== Sandbox directory tree ===\n"];
    NSArray *roots = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/H5CustomFiles"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/PYLFilemanager"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"]
    ];
    NSArray *depths = @[@3, @3, @1];
    for (NSInteger i = 0; i < (NSInteger)roots.count; i++) {
        NSInteger lines = 0;
        [out appendFormat:@"\n--- %@ ---\n", roots[i]];
        treeRecurse(roots[i], @"", 0, [depths[i] integerValue], out, &lines);
    }
    return out;
}

#pragma mark - Text dump of the H5 cache (shareable as ONE .txt)

static NSString *h5DumpPath(void) {
    return [sandboxDocs() stringByAppendingPathComponent:@"arrowgame_h5dump.txt"];
}

static NSString *buildTextDump(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = h5DumpPath();
    [fm removeItemAtPath:path error:NULL];
    [fm createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return nil;

    NSArray *roots = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/H5CustomFiles"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/PYLFilemanager"]
    ];
    NSSet *exts = [NSSet setWithArray:@[@"js", @"json", @"html", @"htm", @"txt", @"plist",
                                        @"xml", @"css", @"ts", @"map", @"wxml", @"wxss", @"vue"]];
    NSArray *skipParts = @[@"res/native/", @"/tmp/", @".tmp/", @"/.cache/"];

    const unsigned long long kCap = 12ULL * 1024 * 1024;
    const unsigned long long kMaxFile = 2ULL * 1024 * 1024;
    unsigned long long total = 0;
    NSInteger taken = 0, skippedExt = 0, skippedBig = 0, skippedBin = 0;

    for (NSString *root in roots) {
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
        NSString *rel;
        while ((rel = [en nextObject])) {
            if (total >= kCap) break;
            NSString *full = [root stringByAppendingPathComponent:rel];
            NSString *low = [full lowercaseString];
            BOOL skip = NO;
            for (NSString *sp in skipParts) {
                if ([low rangeOfString:sp].location != NSNotFound) { skip = YES; break; }
            }
            if (skip) continue;

            NSString *ext = [full pathExtension].lowercaseString;
            if (![exts containsObject:ext]) { skippedExt++; continue; }

            NSDictionary *a = [fm attributesOfItemAtPath:full error:NULL];
            if (!a) continue;
            unsigned long long sz = [a[NSFileSize] unsignedLongLongValue];
            if (sz == 0 || sz > kMaxFile) { skippedBig++; continue; }
            if (total + sz > kCap) continue;

            NSData *d = [NSData dataWithContentsOfFile:full];
            if (!d) continue;
            NSString *txt = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            if (!txt) { skippedBin++; continue; }

            [fh writeData:[[NSString stringWithFormat:@"\n\n===== FILE: %@ (%llu bytes) =====\n", full, sz]
                           dataUsingEncoding:NSUTF8StringEncoding]];
            [fh writeData:d];
            total += sz;
            taken++;
        }
    }

    NSString *summary = [NSString stringWithFormat:
        @"===== ArrowGameRecon H5 text dump =====\n"
        @"version: %@\ndate: %@\n"
        @"included files: %ld\ntotal bytes: %llu (cap 12 MB)\n"
        @"skipped (extension): %ld\nskipped (>2MB): %ld\nskipped (binary): %ld\n"
        @"Tip: search this file for 'arrow', 'level', 'direction', 'grid', 'config'.\n",
        RECON_VERSION, [NSDate date], (long)taken, total,
        (long)skippedExt, (long)skippedBig, (long)skippedBin];
    [fh writeData:[summary dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
    return path;
}

#pragma mark - Recording mode (sample the game while the user plays)

static NSString *samplesFilePath(void) {
    return [sandboxDocs() stringByAppendingPathComponent:@"arrowgame_samples.txt"];
}

static void appendTextToFile(NSString *path, NSString *text) {
    if (!text.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *e) {
        NSLog(@"[ArrowGameRecon] append failed: %@", e);
    } @finally {
        [fh closeFile];
    }
}

// Windows + full view tree of the app's main window.
static NSString *snapshotFullState(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendString:dumpWindowList()];
    UIWindow *keyWin = getMainWindow();
    [s appendFormat:@"\n--- View hierarchy (%@) ---\n",
        keyWin ? NSStringFromClass([keyWin class]) : @"<none>"];
    gNodeCount = 0;
    if (keyWin) {
        dumpView(keyWin, 0, s);
    } else {
        [s appendString:@"No app window found.\n"];
    }
    return s;
}

// Runs on the sampler queue. Returns the text block for one sample.
static NSString *captureSampleNow(NSInteger idx) {
    NSDate *t0 = [NSDate date];

    NSArray<NSString *> *descs = nil;
    NSInteger best = -1;
    NSArray<WKWebView *> *wes = webViewsWithInfo(&descs, &best);

    NSMutableArray *taps = nil;
    @synchronized(gTapLog) {
        taps = [gTapLog copy];
        [gTapLog removeAllObjects];
    }

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"\n----- SAMPLE %ld | +%.2fs | %@ -----\n",
        (long)idx,
        gSessionStart ? [t0 timeIntervalSinceDate:gSessionStart] : 0.0,
        t0];
    [s appendFormat:@"webviews=%lu best=%ld\n", (unsigned long)wes.count, (long)best];
    if (taps.count) {
        [s appendFormat:@"TAPS:\n  %@\n", [taps componentsJoinedByString:@"\n  "]];
    }
    if (!wes.count) {
        [s appendString:@"JS: <no webview>\n"];
        return s;
    }
    for (NSUInteger i = 0; i < wes.count && i < 4; i++) {
        [s appendFormat:@"  wv[%lu] %@\n    %@\n", (unsigned long)i, descs[i],
            evalJS(wes[i], compactJS(), 1.5)];
    }
    if (best >= 0 && (NSUInteger)best < wes.count) {
        // Cheap 1 Hz heartbeat: does the game frame expose a live Cocos scene,
        // and how many nodes does it have? Lets us line state changes up with taps.
        [s appendFormat:@"  state: %@\n", evalJS(wes[best], miniStateJS(), 1.5)];
        if (idx % 5 == 0) {
            [s appendFormat:@"  HEAVY wv[%ld] frames:\n%@\n", (long)best,
                evalJS(wes[best], framesJS(), 2.0)];
            [s appendFormat:@"  HEAVY dump:\n%@\n", evalJS(wes[best], heavyJS(), 3.0)];
            [s appendFormat:@"  DEEP dump:\n%@\n", evalJS(wes[best], deepGameJS(), 5.0)];
        }
    }
    return s;
}

#pragma mark - Run recon

static void runRecon(BOOL showPanel) {
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"ArrowGameRecon report v%@ @ %@\n", RECON_VERSION, [NSDate date]];
    [report appendFormat:@"App bundle: %@\n", [NSBundle mainBundle].bundleIdentifier];
    [report appendFormat:@"Trigger: %@\n", showPanel ? @"manual (panel shown)" : @"launch self-check (silent)"];

    [report appendString:dumpWindowList()];

    UIWindow *keyWin = getMainWindow();
    gNodeCount = 0;
    [report appendFormat:@"\n=== View hierarchy (main window: %@) ===\n",
        keyWin ? NSStringFromClass([keyWin class]) : @"<none>"];
    if (keyWin) {
        dumpView(keyWin, 0, report);
    } else {
        [report appendString:@"No app window found.\n"];
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [report appendString:dumpRelevantClasses()];
        [report appendString:probeAllWebViews()];
        [report appendString:dumpSandboxTrees()];

        NSString *path = reconFilePath();
        NSError *err = nil;
        [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
        NSLog(@"[ArrowGameRecon] report %@ (%@)", err ? @"FAILED" : @"written", path);

        dispatch_async(dispatch_get_main_queue(), ^{
            ReconOverlayController *c = [ReconOverlayController sharedInstance];
            if (showPanel) {
                [c presentWithText:report];
            } else {
                [c showToast:@"侦察完成（静默）：报告已写入 Documents/arrowgame_recon.txt"];
            }
        });
    });
}

#pragma mark - Overlay + retrieval controller

@implementation ReconOverlayController

+ (instancetype)sharedInstance {
    static ReconOverlayController *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[ReconOverlayController alloc] init]; });
    return inst;
}

- (void)presentWithText:(NSString *)text {
    if (!gReconWindow) {
        gReconWindow = makeOverlayWindow();
        gReconWindow.windowLevel = 10000;
        gReconWindow.backgroundColor = [UIColor clearColor];

        UIViewController *root = [[UIViewController alloc] init];
        root.view = [[PassthroughView alloc] initWithFrame:gReconWindow.bounds];
        root.view.backgroundColor = [UIColor clearColor];
        root.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        gReconWindow.rootViewController = root;

        CGFloat w = root.view.bounds.size.width;
        CGFloat h = root.view.bounds.size.height;

        CGFloat cardX = 10.0, cardY = 46.0;
        CGFloat cardW = w - 20.0, cardH = h - cardY - 96.0;
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
        card.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.95];
        card.layer.cornerRadius = 14;
        card.layer.masksToBounds = YES;
        card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [root.view addSubview:card];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 7, cardW - 28, 20)];
        title.text = [NSString stringWithFormat:@"ArrowGameRecon v%@ · 侦察报告", RECON_VERSION];
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:13];
        [card addSubview:title];

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(14, 25, cardW - 28, 15)];
        hint.text = @"退出：点「关闭」或点 RG 小球。下半屏仍可操作 App";
        hint.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
        hint.font = [UIFont systemFontOfSize:10];
        [card addSubview:hint];

        CGFloat pad = 8.0, gap = 6.0, bh = 32.0;
        CGFloat bw = (cardW - pad * 2 - gap) / 2.0;
        CGFloat row1 = 45.0, row2 = row1 + bh + gap;

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(pad, row1, bw, bh);
        [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        closeBtn.backgroundColor = [UIColor colorWithRed:0.72 green:0.20 blue:0.20 alpha:1.0];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        closeBtn.layer.cornerRadius = 7;
        [closeBtn addTarget:self action:@selector(btnClose) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:closeBtn];

        UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        copyBtn.frame = CGRectMake(pad + bw + gap, row1, bw, bh);
        [copyBtn setTitle:@"复制报告" forState:UIControlStateNormal];
        [copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        copyBtn.backgroundColor = [UIColor colorWithRed:0.11 green:0.55 blue:0.40 alpha:1.0];
        copyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        copyBtn.layer.cornerRadius = 7;
        [copyBtn addTarget:self action:@selector(btnCopy) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:copyBtn];

        UIButton *shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        shareBtn.frame = CGRectMake(pad, row2, bw, bh);
        [shareBtn setTitle:@"分享报告" forState:UIControlStateNormal];
        [shareBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        shareBtn.backgroundColor = [UIColor colorWithRed:0.24 green:0.34 blue:0.52 alpha:1.0];
        shareBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        shareBtn.layer.cornerRadius = 7;
        [shareBtn addTarget:self action:@selector(btnShare) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:shareBtn];

        UIButton *dumpBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        dumpBtn.frame = CGRectMake(pad + bw + gap, row2, bw, bh);
        [dumpBtn setTitle:@"导出缓存文本" forState:UIControlStateNormal];
        [dumpBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        dumpBtn.backgroundColor = [UIColor colorWithRed:0.62 green:0.40 blue:0.10 alpha:1.0];
        dumpBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        dumpBtn.layer.cornerRadius = 7;
        [dumpBtn addTarget:self action:@selector(btnExportDump) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:dumpBtn];

        // Row 3: deep probe (left) + recording toggle (right)
        CGFloat row3 = row2 + bh + gap;
        CGFloat probeW = 92.0;

        UIButton *probeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        probeBtn.frame = CGRectMake(pad, row3, probeW, bh);
        [probeBtn setTitle:@"深度探针" forState:UIControlStateNormal];
        [probeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        probeBtn.backgroundColor = [UIColor colorWithRed:0.30 green:0.30 blue:0.62 alpha:1.0];
        probeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        probeBtn.layer.cornerRadius = 7;
        [probeBtn addTarget:self action:@selector(btnDeepProbe) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:probeBtn];

        gSampleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        gSampleBtn.frame = CGRectMake(pad + probeW + gap, row3, cardW - pad * 2 - probeW - gap, bh);
        [gSampleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        gSampleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        gSampleBtn.layer.cornerRadius = 7;
        [gSampleBtn addTarget:self action:@selector(btnToggleSampling) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:gSampleBtn];
        [self updateSampleButton];

        // Row 4: the solver itself (full width)
        CGFloat row4 = row3 + bh + gap;
        UIButton *solveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        solveBtn.frame = CGRectMake(pad, row4, cardW - pad * 2, bh);
        [solveBtn setTitle:@"求解 · 标出下一步" forState:UIControlStateNormal];
        [solveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        solveBtn.backgroundColor = [UIColor colorWithRed:0.10 green:0.50 blue:0.30 alpha:1.0];
        solveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        solveBtn.layer.cornerRadius = 7;
        [solveBtn addTarget:self action:@selector(btnSolve) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:solveBtn];

        // Row 5: auto-play toggle + clear markers
        CGFloat row5 = row4 + bh + gap;
        gAutoBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        gAutoBtn.frame = CGRectMake(pad, row5, bw, bh);
        [gAutoBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        gAutoBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        gAutoBtn.layer.cornerRadius = 7;
        [gAutoBtn addTarget:self action:@selector(btnAuto) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:gAutoBtn];
        [self updateAutoButton];

        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearBtn.frame = CGRectMake(pad + bw + gap, row5, bw, bh);
        [clearBtn setTitle:@"清除标注" forState:UIControlStateNormal];
        [clearBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        clearBtn.backgroundColor = [UIColor colorWithRed:0.26 green:0.28 blue:0.34 alpha:1.0];
        clearBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        clearBtn.layer.cornerRadius = 7;
        [clearBtn addTarget:self action:@selector(btnClearMarks) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:clearBtn];

        CGFloat ty = row5 + bh + 8.0;
        gReconTextView = [[UITextView alloc] initWithFrame:CGRectMake(pad, ty, cardW - pad * 2, cardH - ty - pad)];
        gReconTextView.editable = NO;
        gReconTextView.font = [UIFont fontWithName:@"Menlo" size:9];
        gReconTextView.textColor = [UIColor colorWithRed:0.35 green:0.95 blue:0.45 alpha:1.0];
        gReconTextView.backgroundColor = [UIColor blackColor];
        gReconTextView.layer.cornerRadius = 6;
        gReconTextView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [card addSubview:gReconTextView];
    }
    gReconTextView.text = text;
    gReconWindow.hidden = NO;
}

- (void)hide {
    if (gReconWindow) gReconWindow.hidden = YES;
}

- (UIViewController *)presenter {
    UIViewController *vc = [getMainWindow() rootViewController];
    if (vc) return vc;
    return gReconWindow.rootViewController;
}

- (void)presentActivityWithItems:(NSArray *)items {
    UIViewController *p = [self presenter];
    if (!p) return;
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:items
                                                                    applicationActivities:nil];
    avc.popoverPresentationController.sourceView = gReconWindow;
    [p presentViewController:avc animated:YES completion:nil];
}

- (void)btnClose {
    [self hide];
}

// Tap-the-ball / three-finger behaviour: hide if visible; if we are recording
// and the panel is hidden, just bring it back (re-running a full recon here
// would make the user wait two seconds before they can hit "stop").
- (void)togglePanel {
    if (gReconWindow && !gReconWindow.hidden) {
        [self hide];
    } else if (gReconWindow && gSampling) {
        gReconWindow.hidden = NO;
        [self updateSampleButton];
    } else {
        runRecon(YES);
    }
}

- (void)btnCopy {
    if (gReconTextView.text.length) {
        [UIPasteboard generalPasteboard].string = gReconTextView.text;
        [self showToast:@"报告已复制到剪贴板"];
    }
}

- (void)btnShare {
    NSString *path = reconFilePath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self presentActivityWithItems:@[[NSURL fileURLWithPath:path]]];
    } else {
        [self presentActivityWithItems:@[gReconTextView.text ?: @""]];
    }
}

// Build a single .txt containing every js/json/html/text file in the H5 cache,
// then hand it to the share sheet. All of it happens on a background queue.
- (void)btnExportDump {
    [self showToast:@"正在导出缓存文本…"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *path = buildTextDump();
        unsigned long long size = 0;
        if (path) {
            NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
            size = [a[NSFileSize] unsignedLongLongValue];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (path && size > 0) {
                [self showToast:[NSString stringWithFormat:@"已导出 %.1f MB，正在打开分享…", size / 1048576.0]];
                [self presentActivityWithItems:@[[NSURL fileURLWithPath:path]]];
            } else {
                [self showToast:@"导出失败：H5 缓存里没有可读文本文件"];
            }
        });
    });
}

// v6: the button that actually matters. Run it WHILE YOU ARE INSIDE A LEVEL.
// It reaches into the game iframe's realm and dumps the live Cocos scene,
// every component property that looks like board/level data, MYGameGlobal,
// the bundled class names and localStorage. Then it shares the file.
- (void)btnDeepProbe {
    [self showToast:@"正在深度探测游戏帧…"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableString *r = [NSMutableString string];
        [r appendFormat:@"ArrowGameRecon DEEP probe v%@ @ %@\n", RECON_VERSION, [NSDate date]];
        [r appendString:@"Trigger: 深度探针按钮\n"];
        [r appendString:dumpWindowList()];
        [r appendString:probeAllWebViews()];
        NSString *path = [sandboxDocs() stringByAppendingPathComponent:@"arrowgame_deep.txt"];
        NSError *err = nil;
        [r writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!err) {
                if (gReconTextView) gReconTextView.text = r;
                [self showToast:@"深度探测完成，正在打开分享…"];
                [self presentActivityWithItems:@[[NSURL fileURLWithPath:path]]];
            } else {
                [self showToast:@"深度探测写入失败"];
            }
        });
    });
}

// v10: compute the solution and draw it straight onto the board.
// Reads the static layout + which arrows are alive, runs the greedy solve in
// JS, then places numbered markers at each arrow's head cell. The first marker
// is big and red; the next seven are smaller and blue. Do them in order, then
// press the button again for the next batch (or after a zoom/pan, so the
// markers get recomputed against the new transform).
- (void)btnSolve {
    [self showToast:@"正在计算…"];
    hideSolverMarkers();          // 清掉上一次的标注，避免和新结果叠在一起
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger best = -1;
        NSArray<WKWebView *> *wes = webViewsWithInfo(NULL, &best);
        NSString *txt = nil;
        if (wes.count && best >= 0 && (NSUInteger)best < wes.count) {
            txt = evalJS(wes[best], solveJS(), 12.0);
        }
        NSMutableArray<NSDictionary *> *steps = [NSMutableArray array];
        NSString *plan = nil;
        if (txt.length) {
            for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
                if ([line hasPrefix:@"### PLAN"]) { plan = line; continue; }
                if (!line.length) continue;
                unichar c0 = [line characterAtIndex:0];
                if (!(c0 >= '0' && c0 <= '9')) continue;
                NSArray *f = [line componentsSeparatedByString:@" "];
                if (f.count < 6) continue;
                [steps addObject:@{ @"i": f[1],
                                    @"x": @([f[2] doubleValue]),
                                    @"y": @([f[3] doubleValue]),
                                    @"d": f[4],
                                    @"n": f[5] }];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (steps.count) {
                NSUInteger show = MIN((NSUInteger)8, steps.count);
                NSArray *head = [steps subarrayWithRange:NSMakeRange(0, show)];
                NSMutableString *hud = [NSMutableString string];
                if (plan.length) {
                    [hud appendString:[plan stringByReplacingOccurrencesOfString:@"### PLAN " withString:@""]];
                } else {
                    [hud appendFormat:@"共 %lu 步", (unsigned long)steps.count];
                }
                showSolverPlan(head, hud);
                [self hide];
                [self showToast:@"已标注：按号码顺序点，再按一次看下一批"];
            } else if (txt.length) {
                NSString *msg = txt.length > 120 ? [txt substringToIndex:120] : txt;
                [self showToast:msg];
            } else {
                [self showToast:@"求解失败：先进到关卡里再点"];
            }
        });
    });
}

// ---- auto-play driver ---------------------------------------------------
static BOOL gAutoOn = NO;
static dispatch_source_t gAutoTimer = nil;
static UIButton *gAutoBtn = nil;

- (void)updateAutoButton {
    if (!gAutoBtn) return;
    if (gAutoOn) {
        [gAutoBtn setTitle:@"停止自动" forState:UIControlStateNormal];
        gAutoBtn.backgroundColor = [UIColor colorWithRed:0.72 green:0.16 blue:0.16 alpha:1.0];
    } else {
        [gAutoBtn setTitle:@"自动通关（全自动）" forState:UIControlStateNormal];
        gAutoBtn.backgroundColor = [UIColor colorWithRed:0.62 green:0.36 blue:0.05 alpha:1.0];
    }
}

- (void)startAutoPoll {
    if (gAutoTimer) return;
    gAutoTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gAutoTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                              (uint64_t)(0.5 * NSEC_PER_SEC), 0);
    __weak __typeof(self) wk = self;
    dispatch_source_set_event_handler(gAutoTimer, ^{ [wk autoTick]; });
    dispatch_resume(gAutoTimer);
}

- (void)stopAutoPoll {
    if (!gAutoTimer) return;
    dispatch_source_cancel(gAutoTimer);
    gAutoTimer = nil;
}

// NOTE: evalJS blocks on a semaphore that a main-queue completion handler has to
// signal -- so it must never run ON the main thread or it deadlocks instantly.
// autoTick therefore does its web-view work on a background queue and only hops
// back to main to paint the HUD.
- (void)autoTick {
    if (!gAutoOn) { [self stopAutoPoll]; return; }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger best = -1;
        NSArray<WKWebView *> *wes = webViewsWithInfo(NULL, &best);
        if (!wes.count || best < 0 || (NSUInteger)best >= wes.count) return;
        NSString *st = evalJS(wes[best], autoStatusJS(), 1.5);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!gAutoOn) return;
            updateAutoHud([NSString stringWithFormat:@"自动：%@", st]);
            if ([st rangeOfString:@"run=0"].location != NSNotFound ||
                [st isEqualToString:@"no-auto"] ||
                [st hasPrefix:@"NO_"]) {
                gAutoOn = NO;
                [self stopAutoPoll];
                [self updateAutoButton];
                if ([st rangeOfString:@"cleared"].location != NSNotFound) {
                    [self showToast:@"这一关清完了！"];
                } else if ([st rangeOfString:@"stuck"].location != NSNotFound) {
                    [self showToast:[NSString stringWithFormat:@"卡住：%@", st]];
                } else if ([st rangeOfString:@"verifyfail"].location != NSNotFound) {
                    [self showToast:[NSString stringWithFormat:@"自检不一致，已停：%@", st]];
                } else {
                    [self showToast:[NSString stringWithFormat:@"自动结束：%@", st]];
                }
            }
        });
    });
}

- (void)stopAuto {
    gAutoOn = NO;
    [self stopAutoPoll];
    [self updateAutoButton];
    hideAutoHud();
    [self showToast:@"已停止自动"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger best = -1;
        NSArray<WKWebView *> *wes = webViewsWithInfo(NULL, &best);
        if (wes.count && best >= 0 && (NSUInteger)best < wes.count) {
            evalJS(wes[best], stopAutoJS(), 3.0);
        }
    });
}

- (void)btnAuto {
    if (gAutoOn) { [self stopAuto]; return; }
    [self showToast:@"启动自动…"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger best = -1;
        NSArray<WKWebView *> *wes = webViewsWithInfo(NULL, &best);
        NSString *res = @"需要在游戏关卡里";
        if (wes.count && best >= 0 && (NSUInteger)best < wes.count) {
            res = evalJS(wes[best], startAutoJS(), 8.0);
        }
        NSString *r = res ?: @"无返回";
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([r hasPrefix:@"AUTO_START"]) {
                gAutoOn = YES;
                [self updateAutoButton];
                [self startAutoPoll];
                updateAutoHud(@"自动：启动中…");
                [self hide];
                [self showToast:@"自动运行中。要停：点 RG 小球 → 点「停止自动」"];
            } else {
                [self showToast:[NSString stringWithFormat:@"启动失败：%@", r]];
            }
        });
    });
}

// 「清除标注」：顺手把自动也停掉，避免盘面上留着过期的圈
- (void)btnClearMarks {
    if (gAutoOn) [self stopAuto];
    hideSolverMarkers();
    hideAutoHud();
    [self showToast:@"已清除标注"];
}

#pragma mark - Recording: start / stop

- (void)btnToggleSampling {
    if (gSampling) {
        [self stopSamplingAndExport];
    } else {
        [self startSampling];
    }
}

- (void)updateSampleButton {
    if (!gSampleBtn) return;
    if (gSampling) {
        [gSampleBtn setTitle:[NSString stringWithFormat:@"停止并导出 · 已采 %ld 次", (long)gSampleIdx]
                    forState:UIControlStateNormal];
        gSampleBtn.backgroundColor = [UIColor colorWithRed:0.78 green:0.33 blue:0.10 alpha:1.0];
    } else {
        [gSampleBtn setTitle:@"开始采集（先进关卡，再点这里）" forState:UIControlStateNormal];
        gSampleBtn.backgroundColor = [UIColor colorWithRed:0.18 green:0.46 blue:0.26 alpha:1.0];
    }
}

- (void)updateBadgeLook {
    UIView *badge = [gBadgeWindow.rootViewController.view viewWithTag:9001];
    if (![badge isKindOfClass:[UILabel class]]) return;
    UILabel *b = (UILabel *)badge;
    if (gSampling) {
        b.text = @"REC";
        b.font = [UIFont boldSystemFontOfSize:12];
        b.backgroundColor = [UIColor colorWithRed:0.95 green:0.55 blue:0.05 alpha:0.92];
    } else {
        b.text = @"RG";
        b.font = [UIFont boldSystemFontOfSize:15];
        b.backgroundColor = [UIColor colorWithRed:0.92 green:0.12 blue:0.12 alpha:0.78];
    }
}

- (void)startSampling {
    if (gSampling) return;
    if (!gTapLog) gTapLog = [NSMutableArray array];

    gSampling = YES;
    gSampleIdx = 0;
    gSessionNo++;
    gSessionStart = [NSDate date];
    @synchronized(gTapLog) { [gTapLog removeAllObjects]; }

    NSMutableString *head = [NSMutableString string];
    [head appendFormat:@"\n\n########## SESSION %ld START @ %@ (interval %.1fs, max %ld) ##########\n",
        (long)gSessionNo, gSessionStart, kSampleInterval, (long)kMaxSamples];
    [head appendString:snapshotFullState()];
    appendTextToFile(samplesFilePath(), head);

    if (gSampleTimer) {
        dispatch_source_cancel(gSampleTimer);
        gSampleTimer = nil;
    }
    gSampleQueue = dispatch_queue_create("arrowgame.recon.sample", DISPATCH_QUEUE_SERIAL);
    gSampleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gSampleQueue);
    dispatch_source_set_timer(gSampleTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(kSampleInterval * NSEC_PER_SEC),
                              (uint64_t)(0.05 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gSampleTimer, ^{
        if (!gSampling) return;
        NSInteger idx = gSampleIdx++;
        NSString *block = captureSampleNow(idx);
        appendTextToFile(samplesFilePath(), block);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[ReconOverlayController sharedInstance] sampleTick:idx];
        });
    });
    dispatch_resume(gSampleTimer);

    [self updateSampleButton];
    [self updateBadgeLook];
    [self hide];   // get out of the way so the game stays playable
    [self showToast:@"采样中（小球变橙色）：去玩几局，玩完点小球 → 停止并导出"];
    NSLog(@"[ArrowGameRecon] sampling started, session %ld", (long)gSessionNo);
}

- (void)sampleTick:(NSInteger)idx {
    [self updateSampleButton];
    if (idx + 1 >= kMaxSamples) {
        [self stopSamplingAndExport];
    }
}

- (void)stopSamplingAndExport {
    if (!gSampling) return;
    gSampling = NO;
    if (gSampleTimer) {
        dispatch_source_cancel(gSampleTimer);
        gSampleTimer = nil;
    }
    gSampleQueue = nil;

    NSMutableString *foot = [NSMutableString string];
    [foot appendString:snapshotFullState()];
    [foot appendFormat:@"\n########## SESSION %ld END @ %@ (samples=%ld) ##########\n",
        (long)gSessionNo, [NSDate date], (long)gSampleIdx];
    appendTextToFile(samplesFilePath(), foot);

    [self updateSampleButton];
    [self updateBadgeLook];

    NSString *path = samplesFilePath();
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    double mb = [a[NSFileSize] unsignedLongLongValue] / 1048576.0;
    [self showToast:[NSString stringWithFormat:@"采样结束：%ld 次，%.2f MB。正在打开分享…",
                     (long)gSampleIdx, mb]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self presentActivityWithItems:@[[NSURL fileURLWithPath:path]]];
    });
    NSLog(@"[ArrowGameRecon] sampling stopped, %ld samples -> %@", (long)gSampleIdx, path);
}

#pragma mark - Floating badge

- (void)ensureBadgeOnMain {
    if (!gBadgeWindow) {
        CGFloat side = 46;
        gBadgeWindow = makeOverlayWindow();
        gBadgeWindow.windowLevel = 10001;
        gBadgeWindow.backgroundColor = [UIColor clearColor];
        UIViewController *root = [[UIViewController alloc] init];
        root.view = [[PassthroughView alloc] initWithFrame:gBadgeWindow.bounds];
        root.view.backgroundColor = [UIColor clearColor];
        root.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        gBadgeWindow.rootViewController = root;

        CGSize sc = gBadgeWindow.bounds.size;
        UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(sc.width - side - 8, sc.height * 0.55, side, side)];
        badge.text = @"RG";
        badge.textAlignment = NSTextAlignmentCenter;
        badge.font = [UIFont boldSystemFontOfSize:15];
        badge.textColor = [UIColor whiteColor];
        badge.backgroundColor = [UIColor colorWithRed:0.92 green:0.12 blue:0.12 alpha:0.78];
        badge.layer.cornerRadius = side / 2;
        badge.layer.masksToBounds = YES;
        badge.userInteractionEnabled = YES;
        badge.tag = 9001;
        badge.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [root.view addSubview:badge];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(badgeTapped)];
        [badge addGestureRecognizer:tap];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(badgePanned:)];
        [badge addGestureRecognizer:pan];

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            [self installThreeFingerLongPress];
        }];
    }
    gBadgeWindow.hidden = NO;
    [self installThreeFingerLongPress];
}

- (void)showBadge {
    dispatch_async(dispatch_get_main_queue(), ^{ [self ensureBadgeOnMain]; });
}

- (void)showToast:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureBadgeOnMain];
        UIView *host = gBadgeWindow.rootViewController.view;
        if (!host) return;
        [[host viewWithTag:9002] removeFromSuperview];
        CGFloat w = host.bounds.size.width;
        UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(20, 54, w - 40, 36)];
        toast.tag = 9002;
        toast.text = msg;
        toast.numberOfLines = 2;
        toast.textAlignment = NSTextAlignmentCenter;
        toast.font = [UIFont boldSystemFontOfSize:11];
        toast.textColor = [UIColor whiteColor];
        toast.backgroundColor = [UIColor colorWithRed:0.10 green:0.52 blue:0.36 alpha:0.93];
        toast.layer.cornerRadius = 8;
        toast.layer.masksToBounds = YES;
        toast.userInteractionEnabled = NO;
        toast.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [host addSubview:toast];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [toast removeFromSuperview];
        });
    });
}

- (void)badgeTapped {
    [self togglePanel];
}

- (void)badgePanned:(UIPanGestureRecognizer *)gr {
    UIView *badge = gr.view;
    CGPoint t = [gr translationInView:badge.superview];
    badge.center = CGPointMake(badge.center.x + t.x, badge.center.y + t.y);
    [gr setTranslation:CGPointZero inView:badge.superview];
}

- (void)installThreeFingerLongPress {
    static BOOL installed = NO;
    if (installed) return;
    UIWindow *w = getMainWindow();
    if (!w) return;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(threeFingerLongPress:)];
    lp.numberOfTouchesRequired = 3;
    lp.minimumPressDuration = 0.4;
    lp.cancelsTouchesInView = NO;
    [w addGestureRecognizer:lp];
    installed = YES;
}

- (void)threeFingerLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    [self togglePanel];
}

@end

#pragma mark - Hook via Objective-C runtime (no substrate)

static IMP gOrigSendEvent = NULL;

static void reconSendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    if (gOrigSendEvent) {
        ((void (*)(id, SEL, id))gOrigSendEvent)(self, _cmd, event);
    }
    if (event.type != UIEventTypeTouches) return;

    // Recording mode: log every finger-up that landed on the app's own UI, with
    // the hit-test view class — this is what lets us line a tap up against the
    // state change it caused.
    if (gSampling && gTapLog) {
        NSMutableArray *recs = nil;
        for (UITouch *t in event.allTouches) {
            if (t.phase != UITouchPhaseEnded) continue;
            UIWindow *tw = t.window;
            if (!tw || isOwnWindow(tw)) continue;
            CGPoint p = [t locationInView:nil];
            if (!recs) recs = [NSMutableArray array];
            [recs addObject:[NSString stringWithFormat:
                @"%.3f TAP(%.0f,%.0f) tapCount=%ld view=%@ win=%@",
                [[NSDate date] timeIntervalSince1970], p.x, p.y,
                (long)t.tapCount,
                t.view ? NSStringFromClass([t.view class]) : @"<nil>",
                NSStringFromClass([tw class])]];
        }
        if (recs.count) {
            @synchronized(gTapLog) { [gTapLog addObjectsFromArray:recs]; }
        }
    }

    NSSet *touches = event.allTouches;
    if (touches.count != 3) return;
    BOOL allThreeFingerTap = YES;
    for (UITouch *t in touches) {
        if (t.tapCount != 1 || t.phase != UITouchPhaseEnded) allThreeFingerTap = NO;
    }
    if (!allThreeFingerTap) return;

    [[ReconOverlayController sharedInstance] togglePanel];
}

__attribute__((constructor))
static void ArrowGameReconInit(void) {
    Class cls = [UIApplication class];
    Method m = class_getInstanceMethod(cls, sel_registerName("sendEvent:"));
    if (m) {
        gOrigSendEvent = method_getImplementation(m);
        method_setImplementation(m, (IMP)reconSendEvent);
        NSLog(@"[ArrowGameRecon] sendEvent: hooked (no substrate)");
    }

    NSString *marker = [[reconFilePath() stringByDeletingLastPathComponent]
                        stringByAppendingPathComponent:@"_recon_loaded.txt"];
    NSString *info = [NSString stringWithFormat:@"loaded @ %@\nbundle=%@\nhooked=%s\nversion=%@\n",
                      [NSDate date], [NSBundle mainBundle].bundleIdentifier,
                      m ? "yes" : "no", RECON_VERSION];
    [info writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[ReconOverlayController sharedInstance] showBadge];
    });

    // Silent launch self-check: writes the report and shows a short toast only.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        static BOOL ran = NO;
        if (ran) return;
        ran = YES;
        runRecon(NO);
    });
}
