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
// - Retrieval: on-screen overlay (screenshot), copy-to-clipboard, and a share
//   sheet (WeChat / AirDrop / Save to Files).
// ============================================================================

static UIWindow *gReconWindow = nil;
static UITextView *gReconTextView = nil;

// Overlay controller (implementation is further below)
@interface ReconOverlayController : NSObject
+ (instancetype)sharedInstance;
- (void)presentWithText:(NSString *)text;
- (void)hide;
@end

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
        dispatch_sync(dispatch_get_main_queue(), ^{
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

static void runRecon(void) {
    // Called on the main thread (swizzled sendEvent), so capture UI synchronously.
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"ArrowGameRecon report @ %@\n", [NSDate date]];
    [report appendFormat:@"App bundle: %@\n", [NSBundle mainBundle].bundleIdentifier];

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
            [[ReconOverlayController sharedInstance] presentWithText:report];
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
        gReconWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gReconWindow.windowLevel = 10000; // above alert (2000)
        gReconWindow.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.92];
        UIViewController *root = [[UIViewController alloc] init];
        root.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.92];
        gReconWindow.rootViewController = root;

        CGFloat w = gReconWindow.bounds.size.width;
        CGFloat h = gReconWindow.bounds.size.height;

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 44, w, 22)];
        hint.text = @"ArrowGameRecon · 三指轻点关闭";
        hint.textColor = [UIColor whiteColor];
        hint.textAlignment = NSTextAlignmentCenter;
        hint.font = [UIFont boldSystemFontOfSize:13];
        [root.view addSubview:hint];

        UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        copyBtn.frame = CGRectMake(20, 74, (w - 60) / 2, 34);
        [copyBtn setTitle:@"复制全部" forState:UIControlStateNormal];
        [copyBtn addTarget:self action:@selector(btnCopy) forControlEvents:UIControlEventTouchUpInside];
        [root.view addSubview:copyBtn];

        UIButton *shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        shareBtn.frame = CGRectMake(40 + (w - 60) / 2, 74, (w - 60) / 2, 34);
        [shareBtn setTitle:@"分享 / 存文件" forState:UIControlStateNormal];
        [shareBtn addTarget:self action:@selector(btnShare) forControlEvents:UIControlEventTouchUpInside];
        [root.view addSubview:shareBtn];

        gReconTextView = [[UITextView alloc] initWithFrame:CGRectMake(12, 118, w - 24, h - 140)];
        gReconTextView.editable = NO;
        gReconTextView.font = [UIFont fontWithName:@"Menlo" size:9];
        gReconTextView.textColor = [UIColor greenColor];
        gReconTextView.backgroundColor = [UIColor blackColor];
        [root.view addSubview:gReconTextView];
    }
    gReconTextView.text = text;
    gReconWindow.hidden = NO;
}

- (void)hide {
    gReconWindow.hidden = YES;
}

- (void)btnCopy {
    if (gReconTextView.text.length) {
        [UIPasteboard generalPasteboard].string = gReconTextView.text;
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

    if (gReconWindow && !gReconWindow.hidden) {
        hideReconOverlay();
    } else {
        runRecon();
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
}
