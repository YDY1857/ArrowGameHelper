#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

// ============================================================================
// ArrowGameAuto — 极简自动版（只有一个按钮）
//
// 注入到重签名后的支付宝。进到箭头小游戏关卡，点悬浮球「自动」，它自己通关；
// 再点一下变成「停止」。球可以拖动到任意位置。
//
// 为什么快：
//   游戏 onArrowTouchStart 里，主滑动画结束后还有一条**硬编码 1 秒**的尾动画，
//   之后才把杆节点置为 inactive —— 等它就必然一步一秒。
//   但 clearLinePos(i)（清占用表）和 oneCheckGameWin() 都在动画**开始之前**
//   就同步执行完了，所以点完立刻自己把杆置为 inactive 即可，不必等尾动画。
//   间隔由 kAutoDelayMs 控制，当前 500ms —— 约 0.5 秒点一下。
//
// 为什么这么点：
//   没有伪造 UITouch。onArrowTouchStart(arrowList, lineID, auto) 就是触摸层
//   最终调用的函数，直接调它，游戏自己的状态维护（clearLinePos / checkGameWin
//   / soundIndex）全部照常执行，内部状态不会漂移。
//
// 安全：
//   每一步动手前，先用游戏自己的 checkPathPass() 复核。只要它和本求解器
//   有一个不一致，就等几拍重试；仍不一致立刻停手并在球下提示 —— 不会因为
//   点错扣心。
//
// 完整侦察/调试版在 recon/archive/Tweak.full-v11.x（子目录不参与编译）。
// 需要深度探针、PASS 判决、标号模式时再换回去。
// ============================================================================

// ---- 可调参数 --------------------------------------------------------------
static const NSInteger kAutoDelayMs    = 500;   // 两次点击之间的间隔（毫秒）。500 ≈ 0.5 秒一下
static const NSInteger kAutoMaxSteps   = 420;   // 单次自动的步数上限（防跑飞）
static const NSInteger kMaxVerifyRetry = 6;     // checkPathPass 不一致时的重试次数

// ---- 触摸穿透 --------------------------------------------------------------
// 只有真正命中子视图才吃触摸，空白区一律放行给下面的 App。
@interface PassthroughView : UIView
@end

@implementation PassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

// 裸 UIWindow 在没命中子视图时 hitTest 会返回它自己，于是触摸被吞掉。
// 返回 nil 才能让空白区的触摸落到游戏上。同时不抢 key window。
@interface AutoWindow : UIWindow
@end

@implementation AutoWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    if (hit && hit == self.rootViewController.view) return nil;
    return hit;
}
- (BOOL)canBecomeKeyWindow {
    return NO;
}
@end

static BOOL isOwnWindow(UIWindow *w) {
    return [w isKindOfClass:[AutoWindow class]];
}

// 关键：必须抬高 windowLevel。默认是 UIWindowLevelNormal(0)，和支付宝/游戏窗口
// 同层级，触摸会先被游戏所在的窗口吃掉 —— 表现就是"球看得见，但点不动"。
// v11 的求解面板用的是 9999/10000/10001，这里沿用 10000。
static const UIWindowLevel kOverlayLevel = 10000.0;

static UIWindow *makeOverlayWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *s in app.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            UIWindowScene *ws = (UIWindowScene *)s;
            AutoWindow *w = [[AutoWindow alloc] initWithWindowScene:ws];
            w.frame = ws.coordinateSpace.bounds;
            w.windowLevel = kOverlayLevel;
            return w;
        }
    }
    for (UIScene *s in app.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene *ws = (UIWindowScene *)s;
            AutoWindow *w = [[AutoWindow alloc] initWithWindowScene:ws];
            w.frame = ws.coordinateSpace.bounds;
            w.windowLevel = kOverlayLevel;
            return w;
        }
    }
    AutoWindow *w = [[AutoWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = kOverlayLevel;
    return w;
}

// dispatch_sync 到主队列，如果已经在主队列上会死锁。
static void runOnMainSync(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

// ---- 找游戏 WebView --------------------------------------------------------
static void findWKWebViews(UIView *v, NSMutableArray *into, NSInteger depth) {
    if (!v || depth > 40) return;
    if ([v isKindOfClass:[WKWebView class]]) [into addObject:v];
    for (UIView *sub in v.subviews) findWKWebViews(sub, into, depth + 1);
}

static NSArray<WKWebView *> *gameWebViews(void) {
    NSMutableArray *found = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (isOwnWindow(w)) continue;
            findWKWebViews(w, found, 0);
        }
    }
    return found;
}

// 优先取 URL 里带 antgame 的那个（就是小游戏的 JS 宿主），
// 退化到零尺寸的 JS 宿主，再退化到第一个。
static WKWebView *gameWebView(void) {
    __block WKWebView *best = nil;
    runOnMainSync(^{
        NSArray<WKWebView *> *all = gameWebViews();
        for (WKWebView *w in all) {
            NSString *u = [[[w URL] absoluteString] lowercaseString] ?: @"";
            if ([u containsString:@"antgame"]) { best = w; return; }
        }
        for (WKWebView *w in all) {
            CGSize s = w.frame.size;
            if (s.width < 1.0 || s.height < 1.0) { best = w; return; }
        }
        if (all.count) best = all.firstObject;
    });
    return best;
}

// 注意：completion handler 派发回主队列，所以**绝不能在主线程调这个函数**，
// 否则主线程在信号量上等自己，立刻死锁。调用方一律走后台队列。
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

#pragma mark - 自动循环（JS）

// 在游戏帧内自驱动：求解 -> 游戏自检 -> 调 onArrowTouchStart -> 立刻收杆 -> 下一步
static NSString *startAutoJS(NSInteger delayMs, NSInteger maxSteps, NSInteger maxRetry) {
    return [NSString stringWithFormat:
    @"(function(){var W=null;"
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
    @"var DELAY=%ld,MAXSTEP=%ld,MAXTRY=%ld;"
    @"var st={running:1,step:0,alive:0,lastIdx:-1,msg:'start',delay:DELAY};W.__reconAuto=st;"
    @"function live(i){var r=null;try{r=N[i]}catch(e){return 0}"
    @"if(!r||!r.length)return 0;"
    @"for(var z=0;z<r.length;z++){var nd=r[z];if(nd&&(nd.active===true||(nd.node&&nd.node.active===true)))return 1}"
    @"return 0}"
    @"function kill(i){try{var r=N[i]||[];for(var z=0;z<r.length;z++){var nd=r[z];if(!nd)continue;"
    @"if(nd.node&&nd.node.active!==undefined)nd.node.active=false;else nd.active=false}}catch(e){}}"
    @"function dirOf(cs){var r0=Math.floor(cs[0]/GW),c0=cs[0]%%GW;var r1=Math.floor(cs[1]/GW),c1=cs[1]%%GW;return [r0-r1,c0-c1]}"
    @"function ok(i,occ){var cs=A[i];if(!cs||cs.length<2)return false;"
    @"var d=dirOf(cs);var r=Math.floor(cs[0]/GW),c=cs[0]%%GW;"
    @"r+=d[0];c+=d[1];"
    @"while(r>=0&&r<GH&&c>=0&&c<GW){if(occ[r*GW+c])return false;r+=d[0];c+=d[1]}"
    @"return true}"
    @"var tries=0;"
    @"var step=function(){"
    @"if(!st.running){st.msg='stopped';return;}"
    @"if(st.step>MAXSTEP){st.running=0;st.msg='stepcap';return;}"
    @"var al=[],occ={};"
    @"for(var i=0;i<A.length;i++){if(!live(i))continue;al.push(i);var cs=A[i];for(var j=0;j<cs.length;j++)occ[cs[j]]=1;}"
    @"st.alive=al.length;"
    @"if(!al.length){try{as.checkGameWin()}catch(e){};st.running=0;st.msg='cleared';return;}"
    @"var pick=-1;"
    @"for(var q=0;q<al.length;q++){if(ok(al[q],occ)){pick=al[q];break;}}"
    @"if(pick<0){st.running=0;st.msg='stuck alive='+al.length;return;}"
    @"var vd=-99;try{vd=as.checkPathPass(N[pick])}catch(e){vd=-98;}"
    @"if(vd!==-1){tries++;if(tries<=MAXTRY){W.setTimeout(step,90);return;}"
    @"st.running=0;st.msg='verifyfail i='+pick+' v='+vd;return;}"
    @"tries=0;"
    @"try{as.onArrowTouchStart(N[pick],pick,false)}catch(e){st.running=0;st.msg='callerr '+e;return;}"
    @"kill(pick);"
    @"st.step++;st.lastIdx=pick;st.msg='moved '+pick;"
    @"W.setTimeout(step,DELAY);};"
    @"W.setTimeout(step,120);"
    @"return 'AUTO_START total='+A.length+' delay='+DELAY;})()",
    (long)delayMs, (long)maxSteps, (long)maxRetry];
}

// 返回 step|alive|running|msg
static NSString *autoStatusJS(void) {
    return @"(function(){var W=null;"
    @"try{for(var i=0;i<window.length;i++){try{var w=frames[i];var h=String(w.location.href);if(h.indexOf('iframe')>=0){W=w;break}}catch(e){}}}catch(e){}"
    @"if(!W){try{W=frames[0]}catch(e){}}"
    @"if(!W)return 'NO_IFRAME';"
    @"var s=null;try{s=W.__reconAuto}catch(e){}"
    @"if(!s)return 'no-auto';"
    @"return s.step+'|'+s.alive+'|'+s.running+'|'+s.msg;})()";
}

static NSString *stopAutoJS(void) {
    return @"(function(){var W=null;"
    @"try{for(var i=0;i<window.length;i++){try{var w=frames[i];var h=String(w.location.href);if(h.indexOf('iframe')>=0){W=w;break}}catch(e){}}}catch(e){}"
    @"if(!W){try{W=frames[0]}catch(e){}}"
    @"if(!W)return 'NO_IFRAME';"
    @"try{if(W.__reconAuto){W.__reconAuto.running=0;return 'STOPPED step='+W.__reconAuto.step;}}catch(e){}"
    @"return 'NO_AUTO';})()";
}

#pragma mark - 悬浮按钮

static UIWindow *gWin = nil;
static UIView   *gBox = nil;
static UIButton *gBtn = nil;
static UILabel  *gStat = nil;
static BOOL      gRunning = NO;
static dispatch_source_t gPoll = nil;

@interface AutoController : NSObject
+ (instancetype)shared;
- (void)installUI;
- (void)onPan:(UIPanGestureRecognizer *)g;
- (void)onTapBtn;
- (void)toggleAuto;
- (void)startAuto;
- (void)stopAuto;
- (void)refreshUI:(NSString *)sub;
- (void)startPoll;
- (void)stopPoll;
- (void)pollTick;
@end

@implementation AutoController

+ (instancetype)shared {
    static AutoController *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[AutoController alloc] init]; });
    return inst;
}

- (void)installUI {
    runOnMainSync(^{
        if (gWin) return;
        UIWindow *w = makeOverlayWindow();
        if (!w) return;
        gWin = w;

        UIViewController *root = [[UIViewController alloc] init];
        root.view = [[PassthroughView alloc] initWithFrame:gWin.bounds];
        root.view.backgroundColor = [UIColor clearColor];
        root.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        gWin.rootViewController = root;
        gWin.hidden = NO;

        CGSize sz = root.view.bounds.size;
        // 用 PassthroughView 当托盘：球和状态字之外的那几像素空白也会漏给游戏，
        // 不会在球边上形成一小块"点了没反应"的死区。
        gBox = [[PassthroughView alloc] initWithFrame:CGRectMake(sz.width - 74.0, sz.height * 0.60, 66.0, 92.0)];
        gBox.backgroundColor = [UIColor clearColor];
        gBox.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
        [root.view addSubview:gBox];

        gBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        gBtn.frame = CGRectMake(4.0, 0.0, 58.0, 58.0);
        gBtn.titleLabel.numberOfLines = 2;
        gBtn.titleLabel.textAlignment = NSTextAlignmentCenter;
        gBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [gBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        gBtn.layer.cornerRadius = 29.0;
        gBtn.layer.masksToBounds = YES;
        gBtn.layer.borderWidth = 2.0;
        gBtn.layer.borderColor = [UIColor whiteColor].CGColor;
        [gBox addSubview:gBtn];

        // 点击必须走 UIControl 事件，不能靠 pan 手势的 Ended 分支：
        // UIPanGestureRecognizer 在手指几乎不移动时压根不会进 Began/Ended，
        // 而是直接 failed —— 于是"轻点球"永远不触发，表现就是点不动。
        [gBtn addTarget:self
                 action:@selector(onTapBtn)
       forControlEvents:UIControlEventTouchUpInside];

        // 拖动移动位置。pan 一旦识别成功会自动取消按钮的 touch，
        // 所以"拖动"不会误触发"点击"，两者互不干扰。
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        pan.cancelsTouchesInView = YES;
        [gBtn addGestureRecognizer:pan];

        gStat = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 62.0, 66.0, 30.0)];
        gStat.numberOfLines = 2;
        gStat.textAlignment = NSTextAlignmentCenter;
        gStat.font = [UIFont boldSystemFontOfSize:8];
        gStat.textColor = [UIColor whiteColor];
        gStat.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        gStat.layer.cornerRadius = 5.0;
        gStat.layer.masksToBounds = YES;
        gStat.userInteractionEnabled = NO;
        [gBox addSubview:gStat];

        [self refreshUI:@"就绪"];
    });
}

// 只负责拖动。点击交给 UIControlEventTouchUpInside（见 onTapBtn）。
- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *host = gBox.superview;
    if (!host) return;
    if (g.state != UIGestureRecognizerStateChanged) return;
    CGPoint t = [g translationInView:host];
    CGFloat w = host.bounds.size.width, h = host.bounds.size.height;
    CGFloat nx = gBox.center.x + t.x, ny = gBox.center.y + t.y;
    nx = MAX(34.0, MIN(w - 34.0, nx));
    ny = MAX(48.0, MIN(h - 46.0, ny));
    gBox.center = CGPointMake(nx, ny);
    [g setTranslation:CGPointZero inView:host];
}

- (void)onTapBtn {
    [self toggleAuto];
}

- (void)toggleAuto {
    if (gRunning) [self stopAuto];
    else [self startAuto];
}

- (void)refreshUI:(NSString *)sub {
    runOnMainSync(^{
        if (!gBtn) return;
        if (gRunning) {
            [gBtn setTitle:@"停止" forState:UIControlStateNormal];
            gBtn.backgroundColor = [UIColor colorWithRed:0.86 green:0.20 blue:0.16 alpha:0.94];
        } else {
            [gBtn setTitle:@"自动" forState:UIControlStateNormal];
            gBtn.backgroundColor = [UIColor colorWithRed:0.10 green:0.55 blue:0.32 alpha:0.94];
        }
        if (gStat) gStat.text = sub ?: @"";
    });
}

- (void)startAuto {
    gRunning = YES;
    [self refreshUI:@"启动…"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        WKWebView *w = gameWebView();
        NSString *r = w ? evalJS(w, startAutoJS(kAutoDelayMs, kAutoMaxSteps, kMaxVerifyRetry), 8.0)
                        : @"没找到游戏网页";
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([r hasPrefix:@"AUTO_START"]) {
                [self startPoll];
                [self refreshUI:@"启动中"];
            } else {
                gRunning = NO;
                NSString *m = r.length > 22 ? [r substringToIndex:22] : r;
                [self refreshUI:[NSString stringWithFormat:@"失败:%@", m]];
            }
        });
    });
}

- (void)stopAuto {
    gRunning = NO;
    [self stopPoll];
    [self refreshUI:@"已停止"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        WKWebView *w = gameWebView();
        if (w) evalJS(w, stopAutoJS(), 3.0);
    });
}

- (void)startPoll {
    if (gPoll) return;
    gPoll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gPoll,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                              (uint64_t)(0.25 * NSEC_PER_SEC), 0);
    __weak __typeof(self) wk = self;
    dispatch_source_set_event_handler(gPoll, ^{ [wk pollTick]; });
    dispatch_resume(gPoll);
}

- (void)stopPoll {
    if (!gPoll) return;
    dispatch_source_cancel(gPoll);
    gPoll = nil;
}

// 必须在后台队列做 evalJS（见上面的死锁说明），只回主线程刷 UI。
- (void)pollTick {
    if (!gRunning) { [self stopPoll]; return; }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        WKWebView *w = gameWebView();
        if (!w) return;
        NSString *s = evalJS(w, autoStatusJS(), 1.5);
        NSArray *f = [s componentsSeparatedByString:@"|"];
        NSInteger step = 0, alive = 0, running = 1;
        NSString *msg = s;
        if (f.count >= 4) {
            step = [f[0] integerValue];
            alive = [f[1] integerValue];
            running = [f[2] integerValue];
            msg = [[f subarrayWithRange:NSMakeRange(3, f.count - 3)]
                   componentsJoinedByString:@" "];
        }
        BOOL done = (f.count < 4) || (running == 0);
        NSString *line = [NSString stringWithFormat:@"%ld步\n剩%ld", (long)step, (long)alive];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!gRunning) return;
            if (!done) {
                [self refreshUI:line];
                return;
            }
            gRunning = NO;
            [self stopPoll];
            if ([msg rangeOfString:@"cleared"].location != NSNotFound) {
                [self refreshUI:@"已通关"];
            } else if ([msg rangeOfString:@"stuck"].location != NSNotFound) {
                [self refreshUI:@"卡住了"];
            } else if ([msg rangeOfString:@"verifyfail"].location != NSNotFound) {
                [self refreshUI:@"自检不符"];
            } else if ([msg rangeOfString:@"stopped"].location != NSNotFound) {
                [self refreshUI:@"已停止"];
            } else {
                NSString *shortMsg = msg.length > 24 ? [msg substringToIndex:24] : msg;
                [self refreshUI:shortMsg];
            }
        });
    });
}

@end

#pragma mark - 入口

__attribute__((constructor))
static void ArrowGameAutoInit(void) {
    // 场景连接有快有慢，多试几次；installUI 自己幂等。
    for (int i = 1; i <= 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[AutoController shared] installUI];
        });
    }
}
