#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#define RECON_PATH @"/var/mobile/arrowgame_recon.txt"

// Forward declarations (definitions appear further below)
static void showReconOverlay(NSString *text);
static void hideReconOverlay(void);

static UIWindow *gReconWindow = nil;
static UITextView *gReconTextView = nil;

// iOS 13+: keyWindow is deprecated; use the scene API instead.
// Falls back to a runtime keyWindow call on older systems (no compile-time deprecation).
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

// Recursive helper as a plain C function (a recursive block would trigger
// -Wuninitialized without __block and -Warc-retain-cycles with it).
static WKWebView *findWKWebView(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[WKWebView class]]) return (WKWebView *)v;
    for (UIView *sub in v.subviews) {
        WKWebView *found = findWKWebView(sub);
        if (found) return found;
    }
    return nil;
}

static NSString *probeWebView(UIView *root) {
    __block NSMutableString *result = [NSMutableString stringWithString:@""];

    // WKWebView is a UIView subclass; find the first WKWebView in the hierarchy.
    WKWebView *webView = findWKWebView(root);

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

#pragma mark - Filesystem scan

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
                         [exts containsObject:@"wasm"] || [lower hasSuffix:@".game"])) {
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
    // sendEvent runs on the main thread, so capture UI data synchronously here
    // (reading the view tree off the main thread is unsafe in UIKit).
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

    // Heavy / async-JS work goes to a background queue.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *classes = dumpRelevantClasses();
        [report appendString:classes];

        if (keyWin) {
            NSString *web = probeWebView(keyWin);
            [report appendString:web];
        }

        NSString *files = scanMiniProgramFiles();
        [report appendString:files];

        NSError *err = nil;
        [report writeToFile:RECON_PATH atomically:YES encoding:NSUTF8StringEncoding error:&err];
        if (err) {
            NSLog(@"[ArrowGameRecon] write error: %@", err);
        } else {
            NSLog(@"[ArrowGameRecon] report written to %@", RECON_PATH);
        }

        // Show summary overlay back on the main thread.
        dispatch_async(dispatch_get_main_queue(), ^{
            showReconOverlay(report);
        });
    });
}

#pragma mark - Overlay

static void showReconOverlay(NSString *text) {
    if (!gReconWindow) {
        gReconWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gReconWindow.windowLevel = 10000; // above alert (2000), avoids deprecated UIWindowLevelAlert
        gReconWindow.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.85];
    }
    if (!gReconTextView) {
        gReconTextView = [[UITextView alloc] initWithFrame:CGRectInset(gReconWindow.bounds, 20, 60)];
        gReconTextView.editable = NO;
        gReconTextView.font = [UIFont fontWithName:@"Menlo" size:10];
        gReconTextView.textColor = [UIColor greenColor];
        gReconTextView.backgroundColor = [UIColor blackColor];
        [gReconWindow addSubview:gReconTextView];

        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(0, 20, gReconWindow.bounds.size.width, 30)];
        hint.text = @"ArrowGameRecon - 3指轻点关闭 / 截图发给我";
        hint.textColor = [UIColor whiteColor];
        hint.textAlignment = NSTextAlignmentCenter;
        hint.font = [UIFont boldSystemFontOfSize:13];
        [gReconWindow addSubview:hint];
    }
    gReconTextView.text = text;
    gReconWindow.hidden = NO;
}

static void hideReconOverlay(void) {
    gReconWindow.hidden = YES;
}

#pragma mark - Trigger

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type == UIEventTypeTouches) {
        NSSet *touches = event.allTouches;
        if (touches.count == 3) {
            BOOL allThreeFingerTap = YES;
            for (UITouch *t in touches) {
                if (t.tapCount != 1 || t.phase != UITouchPhaseEnded) {
                    allThreeFingerTap = NO;
                }
            }
            if (allThreeFingerTap) {
                if (gReconWindow && !gReconWindow.hidden) {
                    hideReconOverlay();
                } else {
                    runRecon();
                }
            }
        }
    }
}

%end

%ctor {
    NSLog(@"[ArrowGameRecon] loaded into Alipay");
}
