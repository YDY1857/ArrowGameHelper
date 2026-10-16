#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

// ============================================================================
// ArrowGameRecon (non-jailbreak / re-signed IPA friendly version)
//
// - No Logos, no CydiaSubstrate: the hook is installed with the Objective-C
//   runtime directly, so the dylib loads in a re-signed app with no jailbreak
//   runtime present.
// - The report is written into the app's OWN sandbox (Documents) — the only
//   place a non-jailbroken app is allowed to write.
//
// v2 changes (2026-10-16) — fixes "panel popped up and the whole app went dead":
//   1. The overlay windows are now ReconWindow (a UIWindow subclass whose
//      -hitTest: returns nil for empty areas). Root cause of the freeze: a
//      plain UIWindow answers -hitTest: with *itself* when no subview claims
//      the point, so the PassthroughView trick never actually fired and every
//      touch was swallowed by the overlay window.
//   2. The panel is no longer full-screen: it is a card that leaves a
//      transparent strip at the bottom, and it has an explicit 关闭 button.
//   3. The 8s launch self-check no longer hijacks the screen — it runs
//      silently (writes the file only) and shows a 2.5s non-blocking toast.
//   4. The "三指轻点关闭" hint is gone (three-finger tap is unreliable).
//      Panel exit: tap 关闭, or tap the RG ball.
// ============================================================================

static UIWindow *gReconWindow = nil;
static UITextView *gReconTextView = nil;
static UIWindow *gBadgeWindow = nil;

// Overlay controller (implementation is further below)
@interface ReconOverlayController : NSObject
+ (instancetype)sharedInstance;
- (void)presentWithText:(NSString *)text;
- (void)hide;
// Floating badge: visible proof the dylib loaded + a reliable trigger.
- (void)showBadge;
- (void)showToast:(NSString *)msg;
- (void)installThreeFingerLongPress;
@end

// A root view that only captures touches which land on a real subview, so the
// full-screen badge window lets everything else fall through to the app below.
@interface PassthroughView : UIView
@end

@implementation PassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

// ---------------------------------------------------------------------------
// The real fix for touch pass-through.
//
// A bare UIWindow returns *itself* from -hitTest: when no subview is hit, and a
// touch delivered to a UIWindow goes nowhere — it does NOT continue down to the
// windows below. Returning nil here is what lets an empty area of the overlay
// reach the app underneath.
// ---------------------------------------------------------------------------
@interface ReconWindow : UIWindow
@end

@implementation ReconWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    if (hit && hit == self.rootViewController.view) return nil;
    return hit;
}
@end

// iOS 13+ rework: a UIWindow must be attached to the active UIWindowScene,
// otherwise it is never shown in a scene-based app (like Alipay).
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
    // Fallback: attach to any window scene, else legacy init.
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

// ---------------------------------------------------------------------------
// Sandbox-safe output path
// ---------------------------------------------------------------------------
static NSString *reconFilePath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docs) docs = NSHomeDirectory();
    return [docs stringByAppendingPathComponent:@"arrowgame_recon.txt"];
}

// iOS 13+: keyWindow is deprecated; use the scene API, fall back to runtime call.
static UIWindow *getMainWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSSet<UIScene *> *scenes = app.connectedScenes;
    for (UIScene *scene in scenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            UIWindow *found = nil;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { found = w; break; }
            }
            if (!found) found = ws.windows.firstObject;
            if (found) return found;
        }
    }
    SEL kw = NSSelectorFromString(@"keyWindow");
    if ([app respondsToSelector:kw]) {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[app methodSignatureForSelector:kw]];
        inv.target = app;
        inv.selector = kw;
        [inv invoke];
        __unsafe_unretained UIWindow *win = nil;
        [inv getReturnValue:&win];
        return win;
    }
    return nil;
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
    NSArray *keywords = @[@"Arrow", @"Game", @"Level", @"Grid", @"Puzzle", @"Stage",
                          @"Board", @"Sprite", @"Node", @"Scene", @"Canvas", @"MiniApp",
                          @"TinyApp", @"H5", @"WebView", @"Render"];
    NSInteger matched = 0;
    for (int i = 0; i < numClasses; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        for (NSString *kw in keywords) {
            if ([name rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [outStr appendFormat:@"%@\n", name];
                matched++;
                break;
            }
        }
    }
    free(classes);
    [outStr appendFormat:@"(matched %ld classes)\n", (long)matched];
    return outStr;
}

#pragma mark - WKWebView JS probe

// Plain recursive function (a recursive block would trip -Werror warnings).
static WKWebView *findWKWebView(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[WKWebView class]]) return (WKWebView *)v;
    for (UIView *sub in v.subviews) {
        WKWebView *found = findWKWebView(sub);
        if (found) return found;
    }
    return nil;
}

// dispatch_sync onto the main queue DEADLOCKS if we are already on it. Always
// go through this helper so probeWebView can never hang the app.
static void runOnMainSync(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static NSString *probeWebView(WKWebView *webView) {
    NSMutableString *result = [NSMutableString stringWithString:@""];

    if (!webView) {
        return @"\n=== WebView probe ===\nNo WKWebView detected (game is likely native or canvas).\n";
    }

    [result appendString:@"\n=== WebView probe ===\nDetected WKWebView surface.\n"];

    NSArray *jsProbes = @[
        @"typeof window!=='undefined'?Object.keys(window).filter(function(k){return /game|level|arrow|grid|puzzle|stage|board/i.test(k)}).join(','):'no-window'",
        @"document&&document.body?document.body.innerText.slice(0,500):'no-body'",
        @"(function(){var s='';for(var k in window){if(/game|level|arrow|grid|puzzle|stage|board/i.test(k)){try{s+=k+'='+JSON.stringify(window[k]).slice(0,200)+'\\n'}catch(e){s+=k+'=[unserializable]\\n'}}}return s})()"
    ];

    for (NSString *js in jsProbes) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSString *val = nil;
        // WKWebView evaluateJavaScript must run on the main thread.
        runOnMainSync(^{
            [webView evaluateJavaScript:js completionHandler:^(id v, NSError *err) {
                if (err) val = [@"ERR:" stringByAppendingString:err.localizedDescription];
                else val = [v description];
                dispatch_semaphore_signal(sem);
            }];
        });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        [result appendFormat:@"JS[%@] => %@\n", js, val];
    }
    return result;
}

#pragma mark - Filesystem scan (inside the app sandbox)

static NSString *scanMiniProgramFiles(void) {
    NSMutableString *outStr = [NSMutableString stringWithString:@"\n=== Mini-program / game files ===\n"];
    NSArray *dirs = @[
        NSHomeDirectory(),
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"],
        [NSBundle mainBundle].bundlePath
    ];
    NSArray *exts = @[@"js", @"json", @"wasm", @"html", @"game", @"bundle"];
    NSInteger found = 0;
    for (NSString *dir in dirs) {
        NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:dir];
        NSString *file;
        while ((file = [en nextObject]) && found < 300) {
            NSString *lower = [file lowercaseString];
            BOOL match = NO;
            for (NSString *ext in exts) {
                if ([lower hasSuffix:[@"." stringByAppendingString:ext]]) match = YES;
            }
            if (match && ([lower containsString:@"game"] || [lower containsString:@"arrow"] ||
                         [lower containsString:@"miniapp"] || [lower containsString:@"tinyapp"] ||
                         [lower containsString:@"level"] || [lower containsString:@"puzzle"] ||
                         [lower hasSuffix:@".game"])) {
                [outStr appendFormat:@"%@/%@\n", dir, file];
                found++;
            }
        }
    }
    [outStr appendFormat:@"(found %ld candidate files)\n", (long)found];
    return outStr;
}

#pragma mark - Run recon
//
// showPanel == NO  -> silent run: write the file, show a short toast, no panel.
// showPanel == YES -> show the report card on screen.

static void runRecon(BOOL showPanel) {
    // Called on the main thread, so capture UI synchronously.
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"ArrowGameRecon report @ %@\n", [NSDate date]];
    [report appendFormat:@"App bundle: %@\n", [NSBundle mainBundle].bundleIdentifier];
    [report appendFormat:@"Trigger: %@\n", showPanel ? @"manual (panel shown)" : @"launch self-check (silent)"];

    UIWindow *keyWin = getMainWindow();

    gNodeCount = 0;
    [report appendString:@"\n=== View hierarchy (keyWindow) ===\n"];
    if (keyWin) {
        dumpView(keyWin, 0, report);
    } else {
        [report appendString:@"No key window found.\n"];
    }

    // Resolve the WKWebView on the main thread (view traversal off-main is unsafe).
    WKWebView *webView = keyWin ? findWKWebView(keyWin) : nil;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [report appendString:dumpRelevantClasses()];
        [report appendString:probeWebView(webView)];
        [report appendString:scanMiniProgramFiles()];

        NSString *path = reconFilePath();
        NSError *err = nil;
        [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
        if (err) {
            NSLog(@"[ArrowGameRecon] write error: %@", err);
        } else {
            NSLog(@"[ArrowGameRecon] report written to %@", path);
        }

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
        gReconWindow.windowLevel = 10000; // above alert (2000)
        gReconWindow.backgroundColor = [UIColor clearColor];

        UIViewController *root = [[UIViewController alloc] init];
        root.view = [[PassthroughView alloc] initWithFrame:gReconWindow.bounds];
        root.view.backgroundColor = [UIColor clearColor];
        root.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        gReconWindow.rootViewController = root;

        CGFloat w = root.view.bounds.size.width;
        CGFloat h = root.view.bounds.size.height;

        // Card instead of full screen: the strip at the bottom stays see-through
        // so you can see the app is still alive and reach it.
        CGFloat cardX = 10.0, cardY = 46.0;
        CGFloat cardW = w - 20.0, cardH = h - cardY - 96.0;
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(cardX, cardY, cardW, cardH)];
        card.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.95];
        card.layer.cornerRadius = 14;
        card.layer.masksToBounds = YES;
        card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [root.view addSubview:card];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, cardW - 28, 20)];
        title.text = @"ArrowGameRecon · 侦察报告";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:13];
        title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [card addSubview:title];

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(14, 27, cardW - 28, 15)];
        hint.text = @"退出：点「关闭」，或点屏幕上的 RG 小球。下半屏仍可正常操作 App";
        hint.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
        hint.font = [UIFont systemFontOfSize:10];
        hint.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [card addSubview:hint];

        // Three buttons: 关闭 / 复制全部 / 分享 / 存文件
        CGFloat by = 46.0, bh = 32.0, gap = 6.0, pad = 8.0;
        CGFloat bw = (cardW - pad * 2 - gap * 2) / 3.0;

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(pad, by, bw, bh);
        [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        closeBtn.backgroundColor = [UIColor colorWithRed:0.72 green:0.20 blue:0.20 alpha:1.0];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        closeBtn.layer.cornerRadius = 7;
        closeBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleRightMargin;
        [closeBtn addTarget:self action:@selector(btnClose) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:closeBtn];

        UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        copyBtn.frame = CGRectMake(pad + bw + gap, by, bw, bh);
        [copyBtn setTitle:@"复制全部" forState:UIControlStateNormal];
        [copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        copyBtn.backgroundColor = [UIColor colorWithRed:0.11 green:0.55 blue:0.40 alpha:1.0];
        copyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        copyBtn.layer.cornerRadius = 7;
        copyBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
        [copyBtn addTarget:self action:@selector(btnCopy) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:copyBtn];

        UIButton *shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        shareBtn.frame = CGRectMake(pad + (bw + gap) * 2, by, bw, bh);
        [shareBtn setTitle:@"分享 / 存文件" forState:UIControlStateNormal];
        [shareBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        shareBtn.backgroundColor = [UIColor colorWithRed:0.30 green:0.34 blue:0.38 alpha:1.0];
        shareBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        shareBtn.layer.cornerRadius = 7;
        shareBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
        [shareBtn addTarget:self action:@selector(btnShare) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:shareBtn];

        CGFloat ty = by + bh + 8.0;
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

- (void)btnClose {
    [self hide];
}

- (void)btnCopy {
    if (gReconTextView.text.length) {
        [UIPasteboard generalPasteboard].string = gReconTextView.text;
        [self showToast:@"已复制到剪贴板"];
    }
}

- (void)btnShare {
    NSString *path = reconFilePath();
    UIViewController *presenter = [getMainWindow() rootViewController] ?: gReconWindow.rootViewController;
    if (!presenter) return;
    UIActivityViewController *avc = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        avc = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                                                applicationActivities:nil];
    } else {
        avc = [[UIActivityViewController alloc] initWithActivityItems:@[gReconTextView.text ?: @""]
                                                applicationActivities:nil];
    }
    avc.popoverPresentationController.sourceView = gReconWindow;
    [presenter presentViewController:avc animated:YES completion:nil];
}

#pragma mark - Floating badge (load proof + trigger)

// MUST be called on the main thread.
- (void)ensureBadgeOnMain {
    if (!gBadgeWindow) {
        CGFloat side = 46;
        gBadgeWindow = makeOverlayWindow();
        gBadgeWindow.windowLevel = 10001; // above the report card
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

// Short, non-blocking confirmation banner. Never intercepts touches.
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
    if (gReconWindow && !gReconWindow.hidden) {
        [self hide];
    } else {
        runRecon(YES);
    }
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
    if (gReconWindow && !gReconWindow.hidden) {
        [self hide];
    } else {
        runRecon(YES);
    }
}

@end

static void hideReconOverlay(void) {
    [[ReconOverlayController sharedInstance] hide];
}

#pragma mark - Hook via Objective-C runtime (no substrate)

static IMP gOrigSendEvent = NULL;

static void reconSendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    if (gOrigSendEvent) {
        ((void (*)(id, SEL, id))gOrigSendEvent)(self, _cmd, event);
    }
    if (event.type != UIEventTypeTouches) return;
    NSSet *touches = event.allTouches;
    if (touches.count != 3) return;
    BOOL allThreeFingerTap = YES;
    for (UITouch *t in touches) {
        if (t.tapCount != 1 || t.phase != UITouchPhaseEnded) allThreeFingerTap = NO;
    }
    if (!allThreeFingerTap) return;

    // Three-finger tap is kept as a bonus trigger only — it is unreliable
    // (three fingers rarely all sit in the Ended phase at the same instant),
    // which is why the panel now has its own 关闭 button.
    if (gReconWindow && !gReconWindow.hidden) {
        hideReconOverlay();
    } else {
        runRecon(YES);
    }
}

__attribute__((constructor))
static void ArrowGameReconInit(void) {
    Class cls = [UIApplication class];
    Method m = class_getInstanceMethod(cls, sel_registerName("sendEvent:"));
    if (m) {
        gOrigSendEvent = method_getImplementation(m);
        method_setImplementation(m, (IMP)reconSendEvent);
        NSLog(@"[ArrowGameRecon] sendEvent: hooked (no substrate)");
    } else {
        NSLog(@"[ArrowGameRecon] failed to find -[UIApplication sendEvent:]");
    }

    // Write a marker file so we can tell the dylib actually loaded, then show
    // the floating badge (visible proof + tap-to-run).
    NSString *marker = [[reconFilePath() stringByDeletingLastPathComponent]
                        stringByAppendingPathComponent:@"_recon_loaded.txt"];
    NSString *info = [NSString stringWithFormat:@"loaded @ %@\nbundle=%@\nhooked=%s\nversion=2\n",
                      [NSDate date], [NSBundle mainBundle].bundleIdentifier, m ? "yes" : "no"];
    [info writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[ReconOverlayController sharedInstance] showBadge];
    });

    // Launch self-check ~8s after start. SILENT: it only writes the report and
    // shows a short toast — it must NOT steal the screen while you are using
    // the app or navigating into the mini-program.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        static BOOL ran = NO;
        if (ran) return;
        ran = YES;
        runRecon(NO);
    });
}
