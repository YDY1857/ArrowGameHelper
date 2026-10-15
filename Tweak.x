#import <UIKit/UIKit.h>
#import "Solver.h"

#define PREF_PATH @"/var/mobile/Library/Preferences/com.yourname.arrowgamehelper.plist"

static UIWindow *gOverlayWindow = nil;
static UIView *gMarkerContainer = nil;

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

// Helper to load a manually-entered grid from a plist.
// Expected format under key "grid": array of rows, each row an array of integers
// 0 = empty, 1 = up, 2 = down, 3 = left, 4 = right
static NSArray<NSArray<NSNumber *> *> *loadManualGrid(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREF_PATH];
    id grid = prefs[@"grid"];
    if (![grid isKindOfClass:[NSArray class]]) return nil;
    return grid;
}

// Load optional board rect from plist for accurate marker placement.
// Expected format under key "boardRect": {x, y, width, height}
static CGRect loadBoardRect(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREF_PATH];
    id rectDict = prefs[@"boardRect"];
    if ([rectDict isKindOfClass:[NSDictionary class]]) {
        CGFloat x = [rectDict[@"x"] doubleValue];
        CGFloat y = [rectDict[@"y"] doubleValue];
        CGFloat w = [rectDict[@"width"] doubleValue];
        CGFloat h = [rectDict[@"height"] doubleValue];
        return CGRectMake(x, y, w, h);
    }
    return [UIScreen mainScreen].bounds;
}

// Create a marker view showing a number at a given screen position.
static UIView *makeMarker(NSString *text, CGPoint center) {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    v.center = center;
    v.backgroundColor = [UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:0.8];
    v.layer.cornerRadius = 15;
    v.layer.borderWidth = 2;
    v.layer.borderColor = [UIColor whiteColor].CGColor;

    UILabel *label = [[UILabel alloc] initWithFrame:v.bounds];
    label.text = text;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont boldSystemFontOfSize:14];
    label.textAlignment = NSTextAlignmentCenter;
    [v addSubview:label];
    return v;
}

// Show overlay with numbered steps.
static void showSolutionOverlay(NSArray<ArrowCell *> *solution, CGRect boardRect, NSInteger rows, NSInteger cols) {
    if (!gOverlayWindow) {
        gOverlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gOverlayWindow.windowLevel = 10000; // above alert (2000), avoids deprecated UIWindowLevelAlert
        gOverlayWindow.userInteractionEnabled = NO;
        gOverlayWindow.hidden = NO;
    }

    [gMarkerContainer removeFromSuperview];
    gMarkerContainer = [[UIView alloc] initWithFrame:gOverlayWindow.bounds];
    gMarkerContainer.userInteractionEnabled = NO;
    [gOverlayWindow addSubview:gMarkerContainer];

    CGFloat cellW = boardRect.size.width / cols;
    CGFloat cellH = boardRect.size.height / rows;

    NSInteger index = 1;
    for (ArrowCell *cell in solution) {
        CGFloat x = boardRect.origin.x + cell.col * cellW + cellW / 2.0;
        CGFloat y = boardRect.origin.y + cell.row * cellH + cellH / 2.0;
        UIView *marker = makeMarker([@(index) stringValue], CGPointMake(x, y));
        [gMarkerContainer addSubview:marker];
        index++;
    }
}

static void hideOverlay(void) {
    [gMarkerContainer removeFromSuperview];
    gMarkerContainer = nil;
    gOverlayWindow.hidden = YES;
    gOverlayWindow = nil;
}

// Run the solver and display result.
static void runSolver(void) {
    NSArray<NSArray<NSNumber *> *> *grid = loadManualGrid();
    if (!grid) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ArrowGameHelper"
                                                                       message:@"未读取到 grid 数据。请在 /var/mobile/Library/Preferences/com.yourname.arrowgamehelper.plist 的 grid 键中写入盘面。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *root = getMainWindow().rootViewController;
        [root presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSInteger rows = grid.count;
    NSInteger cols = grid[0].count;
    NSArray<ArrowCell *> *solution = [ArrowGameSolver solveGrid:grid];

    if (!solution || solution.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ArrowGameHelper"
                                                                       message:@"当前盘面无可行解，请检查 grid 数据。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *root = getMainWindow().rootViewController;
        [root presentViewController:alert animated:YES completion:nil];
        return;
    }

    CGRect boardRect = loadBoardRect();
    showSolutionOverlay(solution, boardRect, rows, cols);
}

// Hook UIApplication to listen for a triple-tap anywhere.
%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            if (touch.tapCount == 3 && touch.phase == UITouchPhaseEnded) {
                if (gOverlayWindow) {
                    hideOverlay();
                } else {
                    runSolver();
                }
            }
        }
    }
}

%end

%ctor {
    NSLog(@"[ArrowGameHelper] loaded into Alipay");
}
