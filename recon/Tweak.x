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

#define RECON_VERSION @"7"

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

// v7: the level data is now CONFIRMED -- 32 x 47 grid, 165 polyline "arrows"
// that completely tile the 1504 cells (gridPointList.length === 32*47).
// So the heartbeat additionally tracks the two live signals we found:
//   soundIndex  -- increments on every successful move
//   arrowNodeList length / active count -- which arrows are still on the board
static NSString *miniStateJS(void) {
    return @"(function(){var W=null;try{W=frames[0]}catch(e){}if(!W)return 'noFrame';"
           @"try{var cc=W.cc;if(!cc)return 'cc=<undef>';"
           @"if(!cc.director||!cc.director.getScene)return 'cc-no-director';"
           @"var sc=cc.director.getScene();if(!sc)return 'noScene';var n=0;"
           @"(function w2(x,d){if(!x||d>9)return;n++;var c=x.children||[];for(var i=0;i<c.length;i++)w2(c[i],d+1)})(sc,0);"
           @"var ex='';"
           @"try{var as=W.__reconAS;var cn=cc.js&&cc.js.getClassName;"
           @"if(!as||as.isValid===false){as=null;"
           @"(function w3(x,d){if(as||!x||d>14)return;var a=[];try{a=x._components||x.components||[]}catch(e){}"
           @"for(var i=0;i<a.length;i++){var nm=null;try{nm=cn?cn(a[i]):null}catch(e){}if(nm==='ArrowSystem'){as=a[i];break}}"
           @"var ch=x.children||[];for(var j=0;j<ch.length;j++)w3(ch[j],d+1)})(sc,0);W.__reconAS=as}"
           @"if(as){var nl=as.arrowNodeList||[];var act=0,off=[];"
           @"for(var i=0;i<nl.length;i++){try{var nd=nl[i];if(nd&&(nd.active===true||(nd.node&&nd.node.active===true)))act++;else off.push(i)}catch(e){}}"
           @"var all=as.arrowAllPointList||[];var h1=0,h2=0;"
           @"for(var q=0;q<all.length;q++){var cs=all[q]||[];h1=(h1+(q+1)*cs.length)%1000003;h2=(h2+((cs[0]||0)+1)*(q+7))%1000003}"
           @"ex=' snd='+as.soundIndex+' arrows='+nl.length+' act='+act"
           @"+' off='+(off.length?off.join(','):'-')"
           @"+' sig='+all.length+'/'+h1+'/'+h2}}catch(e){ex=' stateErr'}"
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
    @"S('### ARROW NODES (index active nodeName)');"
    @"for(var i=0;i<(anl?anl.length:0)&&i<400;i++){var nd=null,act=-1,nm='?',pos='';"
    @"try{nd=anl[i];if(nd){nm=nd.name;act=(nd.active===true||(nd.node&&nd.node.active===true))?1:0;pos=J(nd.position,60)}}catch(e){nm='<err>'}S('N'+i+' '+act+' '+nm+' '+pos)}"
    @"S('### ARROWS '+n+'  format=<idx> <active> <nCells> <firstCell> <lastCell> <cell,cell,...>');"
    @"for(var i=0;i<n&&i<400;i++){var cs=aal[i]||[];var act=1;"
    @"try{var nd2=anl?anl[i]:null;if(nd2&&!(nd2.active===true||(nd2.node&&nd2.node.active===true)))act=0}catch(e){}"
    @"S(i+' '+act+' '+cs.length+' '+(cs[0]===undefined?'-':cs[0])+' '+(cs.length?cs[cs.length-1]:'-')+' '+cs.join(','))}"
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

        CGFloat ty = row3 + bh + 8.0;
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
