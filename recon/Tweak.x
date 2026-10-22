#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

// ============================================================================
// ArrowGameAuto — 极简自动版（只有一个按钮）
//
// 注入到重签名后的支付宝。进到箭头小游戏关卡，点悬浮球「自动」，它自己通关；
// 再点一下变成「停止」。球可以拖动到任意位置。
//
// 节奏与动画：
//   游戏 onArrowTouchStart 里，主滑动画结束后还有一条**硬编码 1 秒**的尾动画，
//   之后才把杆节点置为 inactive。等它就必然一步一秒。
//   但 clearLinePos(i)（清占用表）在动画**开始之前**就同步跑完了，所以"逻辑上
//   这条线已经空了"，只是画面上还在滑。
//   所以本版不碰动画：点完就让它滑，我们只在自己的 done 表里记下"这条已点过"，
//   算占用、挑下一条时把它排除 —— 既不撞格，也能看到正常的滑动效果。
//   只有当游戏意外没在尾动画后置 inactive 时，1.7 秒兜底接管。
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
static const NSInteger kMaxVerifyRetry = 8;     // checkPathPass 不一致时的重试次数

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

// 在游戏帧内自驱动：求解 -> 游戏自检 -> 调 onArrowTouchStart -> 下一步
//
// 关键：**不再手动 kill**。点完就交给游戏自己的 1 秒尾动画去播，滑出去、自己置
// inactive。我们只维护自己的 done 表：算占用/挑下一条时把"已点过的"排除掉。
// 这样视觉上是正常的一条条滑走，而求解节奏仍然是 DELAY 一步。
// （游戏 clearLinePos 在 onArrowTouchStart 里同步执行，所以它那边的占用早已释放，
//   我们的 done 表和它的真实状态是一致的 —— 不会撞格。）
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
    @"var st={running:1,step:0,alive:0,wait:0,lastIdx:-1,msg:'start',delay:DELAY};W.__reconAuto=st;"
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
    @"var done={},kt={},tries=0;"
    // 兜底：正常路径下游戏会在「滑动 k 秒 + 尾动画 1 秒」后自己置 inactive。
    // 万一动画被掐掉/掉帧，2.6 秒后我们收杆，避免残影一直挂在画面上。
    @"function watch(i){if(kt[i])return;kt[i]=1;W.setTimeout(function(){if(live(i))kill(i)},2600);}"
    @"var step=function(){"
    @"if(!st.running){st.msg='stopped';return;}"
    @"if(st.step>MAXSTEP){st.running=0;st.msg='stepcap';return;}"
    // 换关卡时 ArrowSystem 重新生成数组 —— 引用一变就清空 done，避免把新关卡的箭头当成旧账。
    @"try{if(as.arrowAllPointList!==A){A=as.arrowAllPointList||[];N=as.arrowNodeList||[];done={};kt={};st.wait=0;}}catch(e){}"
    @"var al=[],occ={},anim=0;"
    @"for(var i=0;i<A.length;i++){"
    @"if(done[i]){if(live(i))anim++;continue;}"
    @"if(!live(i))continue;"
    @"al.push(i);var cs=A[i];for(var j=0;j<cs.length;j++)occ[cs[j]]=1;}"
    @"st.alive=al.length;"
    // 全部点完：最后一两条可能还在滑，等尾动画播完再判胜负（最多 12*200ms）
    @"if(!al.length){"
    @"if(anim>0&&st.wait<12){st.wait++;st.msg='wait '+anim;W.setTimeout(step,200);return;}"
    @"try{as.checkGameWin()}catch(e){}"
    @"st.running=0;st.msg='cleared';return;}"
    @"var pick=-1;"
    @"for(var q=0;q<al.length;q++){if(ok(al[q],occ)){pick=al[q];break;}}"
    @"if(pick<0){st.running=0;st.msg='stuck alive='+al.length;return;}"
    @"var vd=-99;try{vd=as.checkPathPass(N[pick])}catch(e){vd=-98;}"
    // checkPathPass 读的是网格占用表（clearLinePos 已同步清空），所以走到这里的不一致是
    // 真实冲突（比如特殊箭头的连锁自动通过正在改表），重试几拍再看，别急着点。
    @"if(vd!==-1){tries++;"
    @"if(tries<=MAXTRY){W.setTimeout(step,90);return;}"
    @"st.running=0;st.msg='verifyfail i='+pick+' v='+vd;return;}"
    @"tries=0;"
    @"try{as.onArrowTouchStart(N[pick],pick,false)}catch(e){st.running=0;st.msg='callerr '+e;return;}"
    @"done[pick]=1;watch(pick);"
    @"st.step++;st.lastIdx=pick;st.wait=0;st.msg='moved '+pick;"
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

// ---- 尺寸与吸边 ------------------------------------------------------------
static const CGFloat kIdleD   = 34.0;    // 待机直径（缩到这么小，贴边不挡手）
static const CGFloat kRunD    = 58.0;    // 运行 / 拖动时直径
static const CGFloat kIdlePad = 6.0;     // 待机时距屏幕边缘
static const CGFloat kRunPad  = 10.0;    // 运行时距屏幕边缘
static const CGFloat kStatH   = 28.0;    // 球下面那两行状态字的高度

static UIWindow *gWin = nil;
static UIView   *gBox = nil;
static UIButton *gBtn = nil;
static UILabel  *gStat = nil;
static BOOL      gRunning = NO;
static BOOL      gOpen = NO;             // 拖动中临时展开
static NSTimeInterval gHoldUntil = 0.0;  // 结束后保持展开、把结果给人看清的截止时间
static dispatch_source_t gPoll = nil;

static inline BOOL nearF(CGFloat a, CGFloat b) {
    CGFloat d = a - b;
    return (d > -0.5 && d < 0.5);
}

// 待机的球只有 34pt，手指容易点偏。把热区向外扩 6pt，但视觉尺寸不变 ——
// 扩出来的那圈仍然返回球本身，别的地方照旧漏给游戏。
@interface BallBox : PassthroughView
@end

@implementation BallBox
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (gBtn && CGRectContainsPoint(CGRectInset(self.bounds, -6.0, -6.0), point)) {
        return gBtn;
    }
    return [super hitTest:point withEvent:event];
}
@end

@interface AutoController : NSObject
+ (instancetype)shared;
- (void)installUI;
- (BOOL)isOpen;
- (void)holdThenShrink:(NSTimeInterval)sec;
- (void)applyLayout:(BOOL)animated;
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

        // 托盘用 PassthroughView：球和状态字之外的空白漏给游戏，不留"点了没反应"的死区。
        // 初始就是待机小尺寸，贴在右侧偏下的位置。
        gBox = [[BallBox alloc] initWithFrame:CGRectMake(0.0, 0.0, kIdleD, kIdleD)];
        gBox.backgroundColor = [UIColor clearColor];
        gBox.center = CGPointMake(sz.width - kIdlePad - kIdleD * 0.5, sz.height * 0.62);
        [root.view addSubview:gBox];

        gBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        gBtn.frame = CGRectMake(0.0, 0.0, kIdleD, kIdleD);
        gBtn.titleLabel.numberOfLines = 2;
        gBtn.titleLabel.textAlignment = NSTextAlignmentCenter;
        gBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [gBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        gBtn.layer.cornerRadius = kIdleD * 0.5;
        gBtn.layer.masksToBounds = YES;
        gBtn.layer.borderWidth = 1.5;
        gBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
        [gBox addSubview:gBtn];

        // 点击必须走 UIControl 事件，不能靠 pan 手势的 Ended 分支：
        // UIPanGestureRecognizer 在手指几乎不移动时压根不会进 Began/Ended，直接 failed。
        [gBtn addTarget:self
                 action:@selector(onTapBtn)
       forControlEvents:UIControlEventTouchUpInside];

        // 拖动移动位置。pan 一旦识别成功会自动取消按钮的 touch，所以拖动不会误触发点击。
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        pan.cancelsTouchesInView = YES;
        [gBtn addGestureRecognizer:pan];

        gStat = [[UILabel alloc] initWithFrame:CGRectMake(0.0, kIdleD + 2.0, kIdleD, kStatH)];
        gStat.numberOfLines = 2;
        gStat.textAlignment = NSTextAlignmentCenter;
        gStat.font = [UIFont boldSystemFontOfSize:8];
        gStat.textColor = [UIColor whiteColor];
        gStat.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        gStat.layer.cornerRadius = 5.0;
        gStat.layer.masksToBounds = YES;
        gStat.userInteractionEnabled = NO;
        gStat.hidden = YES;                 // 待机时不显示，省地方
        [gBox addSubview:gStat];

        [self refreshUI:@"就绪"];
    });
}

// 展开条件：运行中、拖动中、或者刚跑完还在展示结果。
- (BOOL)isOpen {
    return (gRunning || gOpen || [NSDate timeIntervalSinceReferenceDate] < gHoldUntil);
}

// 结束后别立刻缩，留几秒把「已通关 / 卡住了 / 自检不符 / 失败:xxx」看清楚。
- (void)holdThenShrink:(NSTimeInterval)sec {
    gHoldUntil = [NSDate timeIntervalSinceReferenceDate] + sec;
    [self applyLayout:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self applyLayout:YES];
    });
}

// 球心不动，换尺寸/吸边。待机 = 小圆点贴边；运行或拖动 = 展开。
- (void)applyLayout:(BOOL)animated {
    if (!gBox || !gBtn || !gBox.superview) return;
    UIView *host = gBox.superview;
    CGFloat w = host.bounds.size.width, h = host.bounds.size.height;

    BOOL open = [self isOpen];
    CGFloat d = open ? kRunD : kIdleD;
    CGFloat pad = open ? kRunPad : kIdlePad;
    CGFloat boxH = open ? (d + kStatH + 2.0) : d;

    // 以球的圆心为锚点：展开/收起时球本身不跳位置
    CGFloat ballCY = gBox.frame.origin.y + gBtn.bounds.size.height * 0.5;
    ballCY = MAX(d * 0.5 + 26.0, MIN(h - d * 0.5 - 26.0, ballCY));

    BOOL onLeft = (gBox.center.x < w * 0.5);
    CGFloat cx = onLeft ? (pad + d * 0.5) : (w - pad - d * 0.5);

    CGRect nf = CGRectMake(cx - d * 0.5, ballCY - d * 0.5, d, boxH);
    CGRect bf = CGRectMake(0.0, 0.0, d, d);
    CGRect sf = CGRectMake(0.0, d + 2.0, d, kStatH);
    CGFloat alpha = open ? 1.0 : 0.92;

    gStat.hidden = !open;
    gBox.alpha = alpha;

    CGRect cf = gBox.frame;
    if (nearF(cf.origin.x, nf.origin.x) && nearF(cf.origin.y, nf.origin.y) &&
        nearF(cf.size.width, nf.size.width) && nearF(cf.size.height, nf.size.height)) {
        return;   // 已经在目标状态，别每 250ms 重复起动画
    }

    void (^blk)(void) = ^{
        gBox.frame = nf;
        gBtn.frame = bf;
        gBtn.layer.cornerRadius = d * 0.5;
        gStat.frame = sf;
        gBox.alpha = alpha;
    };
    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:blk
                         completion:nil];
    } else {
        blk();
    }
}

// 拖动：按下先展开（手指好抓），移动跟手，松手吸附最近的左右边。
- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *host = gBox.superview;
    if (!host) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        gOpen = YES;
        [self applyLayout:YES];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:host];
        CGPoint c = gBox.center;
        CGFloat w = host.bounds.size.width, h = host.bounds.size.height;
        CGFloat d = gBtn.bounds.size.width;
        c.x += t.x;
        c.y += t.y;
        c.x = MAX(d * 0.5 + 2.0, MIN(w - d * 0.5 - 2.0, c.x));
        c.y = MAX(46.0, MIN(h - 70.0, c.y));
        gBox.center = c;
        [g setTranslation:CGPointZero inView:host];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        gOpen = NO;                    // 松手就归位：未运行的话顺势缩回小圆点
        [self applyLayout:YES];
    }
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
        BOOL open = [self isOpen];
        if (gRunning) {
            [gBtn setTitle:@"停止" forState:UIControlStateNormal];
            gBtn.backgroundColor = [UIColor colorWithRed:0.86 green:0.20 blue:0.16 alpha:0.94];
        } else {
            // 缩成小圆点时只留一个 ▶，看得懂又不占字宽
            [gBtn setTitle:(open ? @"自动" : @"▶") forState:UIControlStateNormal];
            gBtn.backgroundColor = [UIColor colorWithRed:0.10 green:0.55 blue:0.32 alpha:0.94];
        }
        if (gStat) gStat.text = sub ?: @"";
        [self applyLayout:YES];
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
                [self holdThenShrink:4.0];
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
            [self holdThenShrink:3.5];
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
