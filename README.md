# ArrowGameHelper

支付宝小程序里“箭头滑出”类小游戏的辅助插件。采用**两阶段开发**：先用侦察版插件采集支付宝小游戏的运行时信息，再根据真实数据写精准的自动求解版。

> ⚠️ 本插件仅供技术学习交流，仅用于自己的越狱设备，请勿用于破解他人账号或商业用途。

---

## 目录

1. [两阶段开发路线](#两阶段开发路线)
2. [当前限制](#当前限制)
3. [文件说明](#文件说明)
4. [Windows 端推到 GitHub 编译](#windows-端推到-github-编译)
5. [安装 deb](#安装-deb)
6. [侦察版（Recon）用法](#侦察版recon用法)
7. [求解版（Helper）用法](#求解版helper用法)
8. [从手动到自动：逆向思路](#从手动到自动逆向思路)
9. [常见问题](#常见问题)

---

## 两阶段开发路线

因为从外部无法直接拿到支付宝小程序内部的关卡数据结构，我把它拆成两步，避免瞎猜：

- **阶段一（已做好）· 侦察版 `recon/`**：注入支付宝，你跑一遍游戏，**点屏幕上的红色「RG」小球**触发。它会把当前界面的视图层级、相关类名、WebView 里的 JS 全局变量、以及小程序包路径全部 dump 成 App 沙盒里的 `Documents/arrowgame_recon.txt`，并在屏幕上显示摘要。
- **阶段二（待你数据）· 求解版 `ArrowGameHelper/`**：你把我采集到的信息发给我，我据此找到箭头真正的数据来源（原生 View / Cocos 节点 / WebView JS 状态），把自动抓取逻辑写进 Tweak，替换掉现在手动输入 grid 的部分。

> 阶段一现在就能编译、安装、出数据；阶段二依赖你采集到的真实信息，所以我没法提前写死。

---

## 当前限制

求解版目前是**手动输入盘面**模式：你先把 grid 写进 plist，插件负责求解和显示。等侦察版拿到数据后，我再把它升级成全自动。

---

## 文件说明

```
ArrowGameHelperTweak/
├── Makefile / control / ArrowGameHelper.plist / Tweak.x   # 早期求解版（Logos，未在当前环境使用）
├── Solver.h / Solver.m                                   # 核心回溯求解器
├── recon/                                                # ★ 现在用的就是这个
│   ├── Makefile / control / ArrowGameRecon.plist
│   ├── Tweak.x                                           # v12 极简自动版（617 行，只有一个悬浮球）
│   └── archive/Tweak.full-v11.x                           # 完整侦察版（不参与编译，排查问题时换回来）
├── .github/workflows/build.yml                           # 一次编译出两个 deb
└── README.md
```

> **编译产物**：注入用的是 `recon/` 这个 target 产出的 `ArrowGameRecon.dylib`。
> 名字虽然还叫 Recon，但 v12 起内容已经是纯自动版了 —— 改名会让注入工具的路径失效，所以没动。

---

## Windows 端推到 GitHub 编译

### 1. 准备 GitHub 仓库

1. 打开 [github.com/new](https://github.com/new)，新建一个空仓库，比如 `ArrowGameHelper`。
2. 不要勾选 “Add README” 或 “Add .gitignore”，保持空仓库。
3. 复制仓库地址，例如 `https://github.com/你的用户名/ArrowGameHelper.git`。

### 2. 在 Windows 上初始化并推送

下载安装 [Git for Windows](https://git-scm.com/download/win)，然后打开 Git Bash：

```bash
# 进入项目目录（路径按你实际位置）
cd "/e/WorkBuddy生成储存文件夹/ArrowGameHelperTweak"

# 初始化
git init

# 添加远程仓库（把地址换成你的）
git remote add origin https://github.com/你的用户名/ArrowGameHelper.git

# 提交
git add .
git commit -m "Initial ArrowGameHelper tweak"

# 推送到 main 分支
git branch -M main
git push -u origin main
```

> 如果推送时要求登录，按 GitHub 提示用个人访问令牌（PAT）或浏览器授权登录。

### 3. 触发 GitHub Actions 编译

1. 推送成功后，打开 GitHub 仓库页面。
2. 点击 **Actions → Build ArrowGameHelper Tweak**。
3. 首次需要点击 **I understand my workflows, go ahead and enable them** 启用 Actions。
4. 选中工作流，点击右上角 **Run workflow → Run workflow**。
5. 等待几分钟，直到变绿完成。
6. 点击该次运行结果，最下方 **Artifacts** 里下载 `ArrowGameHelper-N.deb`。

---

## 网页端手动创建与上传（不使用 Git 命令行）

如果你不想装 Git，全程在 GitHub 网页上点也能完成。

### A. 创建仓库

1. 登录 GitHub，右上角 **“+” → New repository**。
2. **Repository name**：填 `ArrowGameHelper`（或你喜欢的名字，英文、连字符、下划线均可）。
3. **Description**：可留空或写 “Alipay arrow game helper tweak”。
4. **Visibility**：默认建议选 **Private**（代码只有你能看）。
   - ⚠️ 提醒：GitHub **Public** 仓库 Actions 免费额度更宽；Private 也有免费额度（Ubuntu runner 也在免费范围内），正常编译一个 tweak 绰绰有余。Public 代码完全公开，介意就选 Private。
5. **不要**勾选 “Add a README file”、“Add .gitignore”、“Choose a license”——保持空仓库，否则初始化提交会和后面的文件冲突。
6. 点击绿色 **Create repository**。

### B. 上传文件（保持目录结构）

**最简单：拖文件夹。** 在仓库空页面点 **Add file → Upload files**，把本地 `ArrowGameHelperTweak` 文件夹里的**全部内容**（注意是内容，不是文件夹本身）拖进上传区。GitHub 网页会**自动保留子目录**，所以 `.github/workflows/build.yml` 会落到正确的位置。拖完拉到底点 **Commit changes**。

**逐个建文本文件（备选）：**

- 文本/小文件：点 **Add file → Create new file**。
- 在顶部 “Name your file…” 里**输入完整路径和文件名**，例如：
  - `Makefile`
  - `control`
  - `ArrowGameHelper.plist`
  - `Tweak.x`
  - `Solver.h`
  - `Solver.m`
  - `recon/Makefile`
  - `recon/control`
  - `recon/ArrowGameRecon.plist`
  - `recon/Tweak.x`
  - `.github/workflows/build.yml`  ← 必须带前面的 `.github/workflows/`，GitHub 会自动建好这几层目录
  - `README.md`（可选）
  - `.gitignore`（可选）
- 在下方文本框粘贴对应内容，拉到底点 **Commit changes**。
- 二进制/已有文件：点 **Add file → Upload files** 单独传。本项目没有二进制，都是文本，用上面 Create new file 即可。

**上传顺序建议：** 先传根目录的普通文件（`Makefile`、`control`、`ArrowGameHelper.plist`、`Tweak.x`、`Solver.h`、`Solver.m`、`README.md`、`.gitignore`），再传 `recon/` 下的四个文件，最后传 `.github/workflows/build.yml`。顺序不影响编译，但最后传 workflow 能确保一传完就具备自动触发条件。

> 注意：`build.yml` 放在 `.github/workflows/` 目录下才会被 GitHub 识别为 Actions 工作流；路径写错（比如放到根目录或写成 `github/workflows/`）就不会触发。

### C. 触发编译

- **方式一（自动）**：只要 `.github/workflows/build.yml` 被提交到 `main`/`master` 分支，GitHub 会**自动触发**一次编译，无需手动。
- **方式二（手动）**：进仓库点 **Actions**，左侧选 **Build ArrowGameHelper Tweak**，右上角 **Run workflow → Run workflow**。
- 等待状态变绿（✓），点进该次运行，右侧 **Artifacts** 下载 `ArrowGameHelper-N.deb`（里面包含两个 deb：求解版 + 侦察版）。

---

## 安装 deb

把下载到的 `.deb` 传到 iPhone：

- 方式 A：用 AirDrop、微信文件传输到手机，再用 Filza 打开安装。
- 方式 B：用 `scp` 发到越狱设备，然后 SSH 进去执行：
  ```bash
  dpkg -i /var/mobile/ArrowGameHelper_0.0.1_iphoneos-arm.deb
  killall -9 AlipayWallet
  ```

> Actions 一次会打出两个 deb：`ArrowGameHelper`（求解版）和 `ArrowGameRecon`（侦察版）。两个都装上也行，互不冲突。

---

## 侦察版（Recon）用法

这一步是给**我**采集数据的，跑完把结果发我就行。

1. 安装 `ArrowGameRecon`（越狱用 deb；非越狱见下面「非越狱注入」章节）。
2. 杀掉并重新打开支付宝。
3. **开屏约 3 秒后，屏幕右侧会出现一个红色「RG」小球** —— 这就是 dylib 加载成功的可视证据。小球可拖动。
4. **开屏约 8 秒后会跑一次自检，但不会弹面板** —— 只在顶部闪一条绿色提示条（约 2.5 秒后自动消失），报告同时写入文件。这样就不会打断你的操作。
5. 平时使用：**点一下「RG」小球**即可触发侦察并弹出报告卡片；三指长按 0.4 秒也可触发。
6. 进到箭头小游戏的关卡界面，再点小球触发一次，报告反映的才是游戏界面。
7. 报告卡片只占上半屏，**底部留了一条透明区**，下半屏的 App 仍然可以正常点（触摸不会被卡片吃掉）。
8. 卡片上有五个按钮（三排）：
   - **关闭** / **复制报告** / **分享报告** / **导出缓存文本**（见上一节）
   - **开始采集**（跨整行，绿色）→ **核心功能**，见下一节
9. 也可以直接**再点一下「RG」小球**关闭面板。

---

## 深度探针（v9，首要用法）

> ⚠ **v12 起 `recon/Tweak.x` 已精简为纯自动版，下面这些侦察功能全部移到 `recon/archive/Tweak.full-v11.x`。**
> 需要深度探针 / PASS 判决 / 标号模式时，把两个文件名对调再编译即可。

引擎已经确认是 **Cocos Creator 3.8.4**，游戏跑在 `PLDWebView` 里一个**同源 iframe** (`game-iframe.html`) 中，
`cc` / `my` / `MYGameGlobal` 都挂在那个 iframe 的 window 上。所以**游戏状态可以直接读**：

1. 进入箭头游戏关卡，看到盘面（**必须在关卡里**，否则读不到）
2. **越早按越好** —— 点 RG 小球 → 面板出现 → 点蓝色的 **「深度探针」**
3. 等 1~2 秒 → 自动弹分享面板 → 导出 `arrowgame_deep.txt`

文件里有十二段：游戏帧的全局变量与已加载 JS、Cocos 版本与设计分辨率、**完整场景树**、数据型组件属性（去重后）、
Cocos 注册类名与 bundle、`MYGameGlobal` 结构、localStorage、
**`LEVEL:` 机器可读的关卡数据**（网格变换 + 165 条箭头的完整格子序列 + 空格清单 + 就地自校验）、
**`COMPONENTS:` 按类名去重后的全属性 dump**、
**`FUNCSRC:` 游戏自己的判定函数源码**（27 个方法的 `toString()`，纯读不调用）、
**`ROD:` 一根杆/一个网格单元的内部结构**，
以及 v9 重写的 **`CALLS:`** —— 五部分：逐条 `eulerAngles.z` + 头格、
**`checkPathPass` 对全部 165 条箭头的判决（标准答案）**、
**完整 `gridPointLineIDInfo` 实时占用表**、方向枚举自检、运行数值。

---

## 录制模式（v4，配合深度探针使用）

一次性的快照只能看到"某一刻"，而关卡数据的变化规律要**看你操作前后**才看得出来。所以 v4 加了录制：

1. 进入箭头游戏关卡，看到盘面
2. 点 RG 小球 → 面板出现 → 点绿色的 **「开始采集」**
3. **面板会自动收起**（不挡你玩），顶部提示条一闪，**RG 小球变成橙色的「REC」** = 正在录
4. **慢慢点 3~5 个箭头**：每点一下停 1~2 秒再点下一个（上限 180 秒，1 秒采一次）。
   **不要狂点** —— 采样是 1 Hz，点太快则"点之前/点之后"落不进不同样本，因果就丢了
5. 玩完点一下小球 → 面板回来 → 点 **「停止并导出」**
6. 弹分享面板 → 发微信/存文件 → 把 `arrowgame_samples.txt` 发我

采集了什么：

- 每 1 秒一次的 **JS/Cocos 状态快照**（场景节点树、坐标、可见性、opacity、canvas 尺寸、全局变量）
- 每秒一行 **游戏帧心跳** `state: scene=<场景名> nodes=<节点数> vp=<视口>`，用来观察盘面是否随操作变化
- 每 5 秒一次 **DEEP 块**（完整场景树 + 棋盘数组 + `MYGameGlobal`），把"哪一步盘面变了"钉死
- **你每一次点击的坐标 + 命中的视图类名**（这是关键：能把"你点哪儿"和"状态怎么变"对上）
- 开始和结束各一次完整视图层级

> 上限 180 次会**自动停止**并弹分享，不用担心文件失控。

---

## 诊断对照表

- 看到 RG 小球 → dylib 已加载，注入成功。
- 看不到 RG 小球 → dylib 没加载（注入问题）：检查 Actions 日志是否有 `OK: no substrate symbols`；确认注入的是 `ArrowGameRecon.dylib`；或换用 deb 注入；确认重签名后支付宝仍能正常启动。

> **版本演进**
>
> **v2（2026-10-16）** 修了「面板一弹出整个 App 就点不动」。根因：**普通 `UIWindow` 在空白处 `hitTest:` 会返回窗口自己**，导致穿透逻辑从未生效，全屏触摸被覆盖层吃掉。改法：`ReconWindow`（空白区返回 `nil`）+ 面板卡片化 + 明确「关闭」按钮 + 8 秒自检改为静默。
>
> **v3（2026-10-16）** 修了「采错对象」并大幅扩容采集：
> - **[BUGFIX]** `getMainWindow()` 原来按 `isKeyWindow` 取窗口，结果取到了**我们自己的悬浮球窗口**，整份视图层级 dump 全是自己的覆盖层，「No WKWebView detected」也就毫无意义。现在排除自有窗口，并**列出所有窗口**（类名 / level / rootVC），另外不再抢 key 窗口（`canBecomeKeyWindow` 返回 `NO`）。
> - **[NEW]** 沙盒**目录树**dump：`Library/Caches/H5CustomFiles`、`Documents/PYLFilemanager`。
> - **[NEW]** **Cocos Creator 感知的 JS 探测**：`window.cc`、`cc.director.getScene()` 节点树、canvas 数量。
> - **[NEW]** 「导出缓存文本」：把 H5 缓存里的 js/json/html 拼成一个 `.txt`。**纯文本拼接，不用 zip/tar，零二进制格式风险。**
>
> **v4（2026-10-16）** 加了**录制模式**：1 Hz 采样 + 记录每次点击的坐标与命中视图，用来对齐"操作 ↔ 状态变化"。采集期间面板自动收起，小球变橙色 `REC`。
>
> **v5（2026-10-16）** 依据第 2 轮实测数据修正与扩容：
> - **[BUGFIX]** 窗口选择原来"key window 优先"，而启动瞬间 key 是一个 **44×123 的 `BEEAlertManagedWindow`**，于是整份层级 dump 采到了那个小窗。现在改为"可见 + normal level + 面积最大"打分排序。
> - **[BUGFIX]** WebView 探测原来只取**第一个**，而第一个是个无关的广告小窗，28 个样本全是同一页无关数据。现在**遍历全部 WebView**，按 URL/尺寸打分挑出最可能是游戏宿主的那一个。
> - **[NEW]** **递归走 frame 树**（top + 4 个子 frame × 2 层）dump 游戏状态全局变量 —— 因为顶层窗口的 `window.length = 1`，真正的游戏内容很可能在 iframe 里。
> - **[NEW]** heavy 探测额外输出**页面 script 源地址**与**未过滤的 window 键名**，用于定位游戏 JS 包并兜底关键词遗漏。
> - 实测确认架构：`XRNativeGameContentView → PLDOpenGLView → PLDJITRenderPlus → AntEAGLView`（OpenGL 渲染）+ `PLDJITRender → PLDWebView`（**零尺寸的 JS 宿主 WebView**）。即支付宝 XR 原生游戏引擎。
>
> **v6（2026-10-16）** 依据第 3 轮实测数据，打通「读出实时游戏状态」这条路：
> - **[BUGFIX 关键]** v3~v5 的 Cocos 场景树探测**一行都没执行过**。根因：`-[WKWebView evaluateJavaScript:]` **永远只在 WebView 的 main frame 执行**，所以探针里所有 `cc` 都解析到 main frame 的全局对象上 —— 而 main frame 根本没有 `cc`（实测 241 个 window key 里确实没有），`typeof cc !== 'undefined'` 直接为假，**静默跳过**。
> - **[NEW]** 探针改为**跨 frame 读取**：把游戏 iframe 的 window 对象当参数传进探针函数，一切走 `W.cc` / `W.my` / `W.MYGameGlobal`。第 2 轮已经实测证明两个 frame **同源**（`for (var k in frames[0])` 能读出 `cc`/`my`/`MYGameGlobal` 并拿到真实类型），所以主 frame 可以直接读。**不使用 `eval` / `Function`，避开 CSP 与 `unsafe-eval` 风险。**
> - **[NEW]** 新增**「深度探针」按钮**（面板第 3 行左侧），进关卡后一键导出 `arrowgame_deep.txt`。
> - **[NEW]** 深度探测分七段：游戏帧全局与已加载 JS、Cocos 版本/设计分辨率/适配、**完整场景树（节点名 + 组件类名 + 坐标 + active）**、**所有 length ≥ 6 的数组属性与名字像关卡号的标量**（棋盘数据探测器）、Cocos 注册类名与 bundle 列表、`MYGameGlobal` 结构、localStorage。
> - **[NEW]** 采样里每秒加一行 **游戏帧心跳** `state: scene=… nodes=… vp=WxH`（1 Hz 成本极低），每 5 个样本追加一次 **DEEP dump**，用于把点击与盘面变化对齐。
> - **[CHORE]** 修掉若干 `/n` 手误（本该是换行却写成了字面量 `/n`）。另：**实测确认 `arrowgame_h5dump.txt` 里没有箭头游戏的文件**（是另几个小游戏的龙骨动画与 Unity 日志），缓存导出这条路作废。
> - 附：截图量测棋盘点位 `x 33.7→406 pt`、`y 200.8→755 pt`，格距 `≈12.0 pt`，约 **32 列 × 46 行** —— 留作 Plan B（截图识别）备用。
>
> **v7（2026-10-16）** v6 打通了读取通道并一次成功，于是 v7 直奔**关卡数据**：
> - **[NEW]** `levelJS()` —— **机器可读的关卡导出**：网格变换、165 条箭头的完整格子序列（`arrowAllPointList`）、每条箭头的 active 标志、覆盖/重叠普查、空格清单，并**在浏览器里就地做自校验**（索引约定判定 `row*gw+col` vs `col*gh+row`、格子覆盖率、重复占用样本）。目标：Python 求解器只读这一段就够了。
> - **[NEW]** `compJS()` —— 按**组件类名去重**，每个类只 dump 一个代表实例的**全部自有属性**。v6 的 D 段把 49 条额度全烧在 25 行一模一样的 `isColorSwitch=false` 上，真正有状态的数组根本没轮到；v7 修了这一点。
> - **[NEW]** 心跳扩展为 `scene=… nodes=… snd=<soundIndex> arrows=165 act=<在场数> off=<已消除索引表>`。`soundIndex` 只在成功移动时增长，`off` 是完整盘面状态 —— 1 Hz 时间线因此可以精确地把「点击坐标 ↔ 被消除的箭头」对上，用来反推求解规则。
> - **[CHORE]** `deepGameJS` 的 D 段按 `class.property` 去重，额度 48 → 200。
> - **[CHORE]** v7 实测确认的关卡参数：Cocos Creator **3.8.4**、fitWidth（设计 750×1334 → 逻辑 750×1629.55）、棋盘 **32×47 = 1504 格**、格距 30 设计单位 = 12.0pt、**165 条折线箭头**。格子→屏幕映射 `screen = (220,478) + design×(0.4,-0.4)`，与截图实测误差 < 2pt。
> - **踩坑记录**：v7 一度把公共 JS helper 写成 `#define` 宏复用，被离线静态校验器立刻抓出 `K is not defined` —— 宏在预处理阶段展开，校验器读的是原始 ObjC 源码，于是 helper 对它不可见，**校验形同失效**。改为显式内联。这类"能编译但让工具失效"的写法不值得为省几行而用。
>
> **v8（2026-10-16）** v7 的关卡导出把几何彻底钉死（32×47、165 条箭头 = 651 根杆、`row*32+col` 索引、`overlaps=0`），但三种通行判据**全部无法解释真实的点击成功/失败**。复盘发现根因不在规则而在模型：
>
> - **[BUGFIX 关键]** **箭头端搞反了**。v7 假定箭头在 `cells[-1]`，实际在 **`cells[0]`**，方向 = `cells[0] − cells[1]`。这是**量出来的**：对全部箭头逐格统计截图深色像素，`cells[0]` 平均 224.8（比邻居 +38.6），`cells[-1]` 平均 136.0（比邻居 −45.0，那是线头收尾）；84 条可测箭头里 **70 条首端有墨量尖峰、0 条末端有**。用修正后的朝向重新标注，红色标记与游戏画的箭头**完全重合**。
> - **[BUGFIX]** `arrowNodeList[i]` **不是节点，是"杆"数组**（箭头 0 有 5 根杆 ↔ 其 6 个转折点）。v7 拿它当节点测 `.active`，所以心跳里 `act=`/`off=` 全错（`off` 恒为全部 165 条）。
> - **[BUGFIX]** 旧 `sig=` 哈希的是 `arrowAllPointList`，而它是**静态关卡定义** —— 65 个样本、14 次成功移动期间**纹丝不动**。换成 `liveCells=<仍被占用的格数>/1504`。
> - **[NEW] `funcJS()`** —— 用 `String(fn)` 导出游戏自己的判定实现：`checkPathPass` / `checkPathObsCount` / `checkLineSegmentIntersection` / `getCanPassLine` / `classificationLine` / `getPointsInDirection*` / `getDirectionType` / `getXYIndexByIndex` / `checkLineType` / `lineAutoPassByCount` / `onCheckCanPassLineProp` / `arrowMove` / `arrowMoveRollback` / `getTargetPos` / `getAngle`，外加 GridSystem 的 `worldToGrid` 等，共 26 个。**纯 toString，一个方法都不调用，零副作用。**
> - **[NEW] `rodJS()`** —— 展开物理模型：`arrowNodeList[i]` 的杆结构（节点名 `gan`）、一根杆的全部组件属性、`gridPointList[i]` 单元结构。
> - **[NEW] `callJS()`** —— **只调用 get/check 类只读方法**，直接问游戏"现在哪些线能通行"。`arrowMove` / `hideArrowList` / `recoverPool` / `*Animation` **绝不调用**；`classificationLine()` 排在最后，万一它真会改状态，前面的数据也已经落盘。
> - **坐标映射锁定**：`Grid` 节点 `worldPos={375,814.7727}`、`worldScale=0.6770842999`，`viewScale=1.76`（=440×3/750） → `screen = (220,478) + design×(0.39722, −0.39722)`，推算棋盘外框与截图实测**误差 < 2pt**。
>   ⚠ `DragBg` 有 `enableScale=true / minScale=0.677 / maxScale=2.45 / enableInertia` —— **盘面可拖动缩放**，叠加方案必须每帧读 `Grid` 的实时变换，不能写死。
> - **修正箭头端后**，判据「箭头前方一格为空」推出初始 **54/165 条可动**，而用户**第一次点击**的 A22 正好在其中（头 (3,28) 朝右、前方 (3,29) 为空）→ 自洽。
> - **踩坑记录**：v8 的 `rodJS` 首次提交时括号不平衡（`else{...}}` 多一个 `}`），被静态校验器第 6 项（真跑 JS）当场抓出 `Unexpected token 'catch'`，重写为结构清晰的分支后通过。
>
> **v9（2026-10-16）** v8 的 `FUNCSRC` 一次成功 —— **规则不再是猜的，是游戏源码原文**：
>
> ```js
> // checkPathPass(arrowList)
> 方向 = rod[0].eulerAngles.z : 0→左  90→下  180→右  -90→上
> 头格 = arrowPointList[lineID][0]
> 走廊 = gridSystem.getPointsInDirection(头格, 方向)   // 头格之外直到边界
> 通行 ⇔ 走廊上一个占用格子都没有  ⇔ return -1
> 占用表 = gridSystem.gridPointLineIDInfo (cell → lineID)
> ```
>
> - **几何二次闭环**：`rod.startWidth = 跨度格数 × cellWidth + lineOffeset`。A0 的 124.5 = 4×30+4.5、A1 的 34.5 = 1×30+4.5、A2 的 64.5 = 2×30+4.5，逐个精确吻合。
> - **头格位置双路印证**：源码里的 `arrowPointList[lineID][0]` 与上一轮纯靠截图墨量测出的 `cells[0]` 完全一致。
> - **求解器已跑通**：按该规则实现贪心，本关 **165/165 全部清空、无卡死**。因为移除箭头只会释放格子，可通行集合单调不减 —— 规则若错必然中途卡死，所以这是一次强验证。初始可通行 **21 条**，与此前独立算出的「走廊全空 = 21」一致。
> - **[BUGFIX]** v8 的 `checkPathPass(0)` 传的是**索引**，而函数签名要**杆数组**（内部 `t[0].eulerAngles`、`arrowNodeList.indexOf(t)`）→ 165 次调用全抛异常。
> - **[BUGFIX]** v8 把 `getCanPassLine()` 整体 `JSON.stringify`，其返回值里 `arrowList` 是 cc.Node 数组 → 循环引用，只剩 `[circ]`，`lineID` 丢失。v9 只取 `.lineID`。
> - **[BUGFIX 安全性]** **`classificationLine()` 不是只读的**：它会对最长的三条线调用 `onArrowTouchStart`，**真的会移动箭头**。v8 调用了它并扰动了盘面，v9 起永久不再调用。
> - **[CHORE]** 删掉 `getDirectionType` / `getXYIndexByIndex` / `checkLineType` 在 ArrowSystem 上的调用（这些方法只在 GridSystem 上存在）；`getPointsInDirection` 改为传真正的 Vec3（传数字会报 `i.clone is not a function`）。
> - **[NEW]** `CALLS` 段五部分：逐条 `eulerAngles.z` + 头格、**`checkPathPass` 对全部 165 条的判决**、**完整 `gridPointLineIDInfo` 实时占用表**、方向枚举自检、运行数值。
> - **[NEW]** `FUNCSRC` 追加 `onArrowTouchStart`（一次点击滑多远，模拟的最后一块拼图）、`hideArrowList`、`checkGameWin`、`update`。
> - **纠正**：v9 时按真规则 A22 初始不可通行，而它被点时 `snd` 照样涨，于是误判"`soundIndex` 不是成功标志"。**v10 读到 `onArrowTouchStart` 源码后结论反转**：成功时 `soundIndex++`、失败时播 error 音并把 `soundIndex` 重置为 0（还扣一颗心），所以它涨确实代表那一下点对了。唯一标准答案仍是 `checkPathPass`，但 `snd` 的语义这下清楚了。
> - **[NEW v10]** `solveJS()` 贪心求解器 + 可穿透的编号标记层 + 「求解 · 标出下一步」按钮（详见下面「求解器」一节）。

## 求解器（v10，现在的主角）

v9 的标准答案回来了，规则与实现**逐条对得上**：

```
逐条判决（checkPathPass vs 我的实现）   一致 165 / 165，不一致 0
可通行集合                              完全相同
方向（eulerAngles.z vs cells[0]-cells[1]） 165 / 165 一致
头格（arrowPointList[0] vs arrowAllPointList[0]） 165 / 165 一致
```

游戏给出的初始可通行集合 `0,1,2,3,4,5,6,7,9,10,11,12,14,19,20,25,26,27,30,46,52`（21 条），我算的一模一样。

`onArrowTouchStart` 的源码也确认了动作语义：**点对了整条箭头滑出棋盘**（末尾 `t.forEach(t => t.active = false)`），
**点错了播 error 音、`soundIndex` 归 0、扣一颗心**（`ReduceHp`，同一条线只扣一次）。
顺带纠正：`soundIndex` 是**成功连击数**（成功 +1、失败归 0），所以它涨确实代表那一下点对了。

### 算法

`alive` = `arrowNodeList[i]` 里还有 active 的杆；`occ` = 所有 alive 箭头占的格子并集；
`pass(i)` = 从 `cells[0]` 沿 `cells[0]-cells[1]` 方向到边界的走廊全空。
**移除只释放格子** → 可通行集合单调不减 → 贪心一遍到底且与顺序无关。本关实测 **165/165 清空、零卡死**。

### 用法

进关卡 → 点 RG 小球 → 点绿色 **「求解 · 标出下一步」** → 盘面上出现编号圆圈，按 1、2、3… 点。
大红色圈是第一个，后面 7 个是蓝色。一批点完再按一次。

屏幕坐标来自 **Grid 节点的实时 `worldPosition`/`worldScale`**：
```
world = gridNode.worldPosition + gridPositions[row][col] * gridNode.worldScale
pt    = (world.x * K, (visibleSize.height - world.y) * K)        K = frameSize.width / visibleSize.width
```
所以拖动/缩放后重按一次就能重新对齐（`DragBg` 允许 `minScale=0.677 ~ maxScale=2.45` 并可惯性拖动）。
标记层在 `windowLevel 9999`（低于面板的 10000），标签 `userInteractionEnabled = NO`，
配合 `ReconWindow` 的 `hitTest` 返回 `nil`，**完全不挡触摸**。

**报告文件路径**（跟随运行环境自动选择）：

- 非越狱 / 重签名 IPA：`<支付宝沙盒>/Documents/arrowgame_recon.txt`
- 越狱：同样是 App 沙盒内的 `Documents`（用 Filza 进容器取）

同目录下还会生成：`arrowgame_deep.txt`（深度探针）、`arrowgame_samples.txt`（录制）、`arrowgame_h5dump.txt`（缓存导出）。

侦察报告包含五块：

- `=== All windows ===`：当前所有窗口（类名 / windowLevel / 是否 key / rootViewController），我们自己的覆盖层会标 `<-- OURS`。用来确认到底 dump 的是谁的界面。
- `=== View hierarchy ===`：支付宝**主窗口**从根往下每一层 View 的类名和位置。用来判断游戏是原生 UIView、Cocos/Unity 的 GL 层、还是包在 WKWebView 里。
- `=== Relevant Objective-C classes ===`：类名里带 `Nebula/TinyApp/MiniApp/Applet/H5WK/Cocos/Game/Canvas/Arrow/Grid/Puzzle/WebView/JSCore/Cube/XR` 的类（上限 400 条），是后续 hook 的候选。
- `=== WebView probe ===`：**遍历 App 里每一个 WKWebView**（不只第一个），逐个输出类名/坐标/尺寸/评分，以及三层探测：
  - `compact`：URL、title、frame 数、canvas 数、script 数、引擎特征（`cc`/`Laya`/`egret`/`PIXI`/`THREE`/`my`/`wx` 等）
  - `frames`：各子 frame 的 URL
  - `heavy`：**递归走 frame 树（top + 最多 4 个子 frame × 2 层）**，dump 所有名字像游戏状态的全局变量（带 JSON 值）、Cocos 场景树、**页面加载的 script 源地址**、以及**未过滤的 window 键名**（前 180 个）
- `=== Sandbox directory tree ===`：`Library/Caches/H5CustomFiles`、`Documents/PYLFilemanager`、`Library/Caches` 的目录树（深度 3，带文件数与体积）。实际观测到的 `H5CustomFiles/usr/<uid>/gamecaches/` 结构和 `res/import/xx/`（Cocos 资源布局）就是从这里看出来的。
- `=== Mini-program / game files ===`：旧版按关键词列文件，v3 已被上面的目录树取代。

另外面板上的「导出缓存文本」会生成 `Documents/arrowgame_h5dump.txt`（最多 12 MB），内容是 H5 缓存里所有 js/json/html/text 的拼接，给我做离线逆向用。

把这份报告发我之后，我就能判断该 hook 哪一层、数据从哪拿，然后升级求解版。

---

## 全自动（v12，极简版：只有一个球）

v10 的标号位置被实测确认后，v11 接管了"点"，v12 又做了两件事：**提速 15 倍** + **砍到只剩一个按钮**。

### 为什么快

游戏 `onArrowTouchStart` 里，主滑动画之后还有一条**硬编码 1 秒**的收尾动画，之后才 `t.forEach(t => t.active = false)`。
v11 是"等杆变 inactive 再点下一条"，所以每步必然被这 1 秒卡住。

关键发现：**`clearLinePos(i)`（清占用表）在动画开始之前同步执行完了。**
调用返回的瞬间，这条线在游戏内部**逻辑上已经空了**，剩下的 1 秒纯是画面表演。

所以 v12 最终版不碰动画、也不 kill 任何节点，改成**自己记账**：

```js
as.onArrowTouchStart(N[pick], pick, false);   // 同步部分完成，线已释放
done[pick] = 1;                                // 自己记下"这条点过了"
setTimeout(step, 500);                         // 0.5 秒后点下一条
```

算占用表 / 挑下一条时把 `done` 里的箭头排除，箭头本身交给游戏尾动画照原样滑走、
自己在 1 秒后置 inactive —— **画面上是正常滑出，不是"啪"一下消失**。

三个配套兜底：点完 1.7 秒仍未 inactive 就自己收杆；最后一两条还在滑时等动画播完
（最多 2.4 秒）再判胜负；换关卡后箭头数组引用变了就清空 `done`。

间隔做成常量了，默认 **500ms（0.5 秒一下）**，一关 165 条约 **80 秒**（v11 那套近 3 分钟）。
文件顶部：`static const NSInteger kAutoDelayMs = 500;` —— 300 更快，800/1200 更慢。

### 为什么稳

仍然**不伪造触摸** —— `onArrowTouchStart(arrowList, lineID, auto)` 就是触摸层最终调用的函数，
`clearLinePos` / `checkGameWin` / `soundIndex` 全部由游戏自己维护，状态不会漂移。

仍然是**每步自检**：动手前用游戏自己的 `checkPathPass()` 复核，不一致就重试（有动画在播时等 140ms，否则 90ms，最多 8 次），
仍不一致则立刻停手并提示「自检不符」—— 不会因为点错扣心。

### 界面：待机缩到边上

待机时是个 **34pt 的小绿圆点（▶）**，贴边 6pt，不挡视野；操作时才展开成 58pt。

| 阶段 | 球 | 尺寸 / 位置 |
|---|---|---|
| 待机 | 绿「▶」，半透明 | 34pt，自动吸附最近一侧边缘，不显示状态字 |
| 运行中 | 红「停止」+ 两行状态 | 58pt，仍在边缘 |
| 拖动中 | 绿「自动」 | 按下就展开成 58pt，松手吸附并缩回 |
| 刚跑完 | 保留结果显示 | 保持 58pt 约 3.5 秒，再缩回小圆点 |

球下面是 `37步 / 剩128`，结束显示 `已通关` / `卡住了` / `自检不符` / `已停止`。

实现要点：`applyLayout:` 以**球的圆心**为锚点换尺寸，所以展开/缩回时球不跳位置；
待机热区向外扩 6pt（`BallBox` 的 `hitTest`），视觉不变但更好点；
`isOpen` 决定展开与否，`holdThenShrink:` 负责跑完后延迟收起。

### 精简结果

| | v11 | v12 |
|---|---|---|
| 代码量 | 2320 行 / 116 KB | **617 行 / 26 KB** |
| 按钮 | 面板 7 个 | **1 个悬浮球** |

深度探针 / 录制 / 标号 / 缓存导出 / 报告分享全部移出主文件，
完整版归档在 **`recon/archive/Tweak.full-v11.x`**（`recon/Makefile` 里 `ArrowGameRecon_FILES = Tweak.x`，
只编译根目录那一个，子目录不参与构建）。要排查问题时把两边文件名换一下即可。

### 注意

- **这是自动化操作**，0.5 秒一步、一关一分多钟，仍比手点快，风控上和手动玩不一样 —— **别挂着连刷几十关**。
- 过关后**不会自动进下一关**（要自己点"下一关"）。要自动连关说一声，加几行就行。
- 全自动**不依赖屏幕坐标**（直接调函数），缩放/拖动完全不影响。

---

## 非越狱 / 重签名 IPA 注入（个人证书方案）

侦察版已改造为**不依赖 CydiaSubstrate**（纯 Objective-C runtime swizzling），因此可以注入到用个人证书重签名的支付宝 IPA 里。求解版将在阶段二一并改造。

### 关键前提

1. **不需要越狱**，但需要把 dylib 注入 IPA 并用你的证书重新签名。
2. 报告写在 App 自己的沙盒里，**不要去读 `/var/mobile/`**（非越狱没权限）。
3. ⚠️ 支付宝有安全风控 / 重签名检测，注入后可能报「环境异常」或闪退。先用侦察版实测，能进游戏就有戏。

### 注入步骤（Windows）

**方式一：Sideloadly（推荐，能直接注入 deb/dylib）**

1. 下载安装 [Sideloadly](https://sideloadly.io)，装好 iTunes / iCloud 驱动。
2. 把 `ArrowGameRecon_0.0.1_iphoneos-arm.deb`（或 CI 产出的 `ArrowGameRecon.dylib`）放进 `Sideloadly` 的 **Inject dylib/deb** 框。
3. IPA 选原版支付宝 ipa，Apple ID 登录个人证书，开始签名安装。
4. 装好后在 iPhone「设置 → 通用 → VPN与设备管理」信任证书。

**方式二：轻松签 / ESign / Azule 等国内工具**

1. 导入支付宝 ipa。
2. 在「注入 dylib / 注入 deb」里加入侦察版 deb 或 dylib。
3. 用自己的证书签名安装。

### 让报告文件能在「文件」App 里看到（可选，最省事）

重签名的 IPA 里，编辑 `Payload/AlipayWallet.app/Info.plist`，加上：

```xml
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
```

装好后打开 iPhone 的「文件」App → 我的 iPhone → 支付宝 → 就能看到 `arrowgame_recon.txt`，直接拷贝出来。

不加上面两行也行，用面板上的「复制全部 / 分享」按钮一样能拿到报告。

---

## 求解版（Helper）用法

> 在拿到侦察数据、升级成全自动之前，求解版先用**手动输入盘面**的方式跑通整个流程。

### 1. 编写盘面数据

用 Filza 创建或编辑：

```
/var/mobile/Library/Preferences/com.yourname.arrowgamehelper.plist
```

内容示例：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>grid</key>
    <array>
        <array>
            <integer>4</integer>
            <integer>2</integer>
            <integer>0</integer>
        </array>
        <array>
            <integer>3</integer>
            <integer>1</integer>
            <integer>2</integer>
        </array>
        <array>
            <integer>0</integer>
            <integer>4</integer>
            <integer>1</integer>
        </array>
    </array>
</dict>
</plist>
```

数字含义：

| 数字 | 含义   |
|------|--------|
| 0    | 空     |
| 1    | 上 ↑   |
| 2    | 下 ↓   |
| 3    | 左 ←   |
| 4    | 右 →   |

数组形状不必是正方形，按实际行列写。上图示例是 3×3，你自己按关卡尺寸扩展。

> 如果盘面在屏幕上只占中间一小块，可以在 plist 里再加一个 `boardRect`，让标记位置更准确：
> ```xml
> <key>boardRect</key>
> <dict>
>     <key>x</key><real>30</real>
>     <key>y</key><real>120</real>
>     <key>width</key><real>350</real>
>     <key>height</key><real>500</real>
> </dict>
> ```
> 不写的话默认用整个屏幕。

### 2. 启动游戏并触发

1. 打开支付宝，进入箭头小游戏关卡。
2. 确保游戏界面已经完整显示箭头盘面。
3. 用三根手指快速点击屏幕三次（或者同一位置连续点三下）。
4. 如果 plist 正确，屏幕会出现红色圆圈，圈上标着 1、2、3……就是点击顺序。
5. 再点三下可以关闭覆盖层。

---

## 从手动到自动：下一步逆向思路

全自动识别需要拿到支付宝小游戏内部的关卡数据。下面给出 iOS 端常见做法：

1. **确定运行环境**
   - 支付宝小程序在 iOS 端通常跑在 `com.alipay.iphoneclient` 进程内。
   - 小游戏引擎可能是 Cocos2d-x、Unity 小游戏运行时，或者支付宝自研的轻量引擎。

2. **定位数据**
   - 设备上安装 [Frida](https://frida.re) + [Flex 3](https://www.ios-repo-updates.com/repository/bigboss/package/flex3/) 或 [LookinLoader](https://github.com/cyanzhong/lookin-loader)。
   - 用 Frida 脚本 dump 内存中可疑的字符串，搜索关卡 JSON 里常见的字段名，例如 `level`、`arrow`、`direction`、`grid` 等。
   - 用 Flex 查看当前视图层级，找到游戏主 View 的类名。

3. ** hook 点候选**
   - 如果是原生 UI：hook 游戏主 View 的 `- (void)layoutSubviews` 或 `- (void)drawRect:`，遍历 subviews 找箭头 UIImageView / CAShapeLayer。
   - 如果是 Cocos2d-x：找 `cocos2d::Node` 派生类，读 `m_children` 与 `m_position`。
   - 如果是 WebView / 小程序 Canvas：用 `WKUserContentController` 注入 JS，读 DOM 或 Canvas 指令。

4. **反向填充 grid**
   - 一旦确定每个箭头的屏幕坐标和方向，按行列映射到网格，调用本项目的 `ArrowGameSolver`。
   - 把结果传给 `showSolutionOverlay:solution:boardRect:rows:cols:`。

5. **修改 Tweak.x**
   - 把 `loadManualGrid()` 替换为你的自动抓取函数。
   - 用 `saveDetectedGrid:` 调试时可以把识别到的 grid 写回 plist 核对。

---

## 常见问题

**Q: 编译失败，提示 SDK 找不到？**  
A: `build.yml` 里已经写了官方 tarball + sparse-clone 双保险。如果还是失败，多半是 GitHub 网络波动，重新 Run workflow。

**Q: 注入后支付宝闪退？**  
A: 检查 `ArrowGameHelper.plist` 里的 Bundle ID 是否准确；另外 hook 了 `UIApplication` 的 `sendEvent:`，某些 Alipay 自定义事件分发可能冲突，可换成 `UIWindow` 的 `- (void)motionBegan:withEvent:` 或长按手势触发。

**Q: 不显示覆盖层？**  
A: 先确认 plist 路径和 `grid` 键名写对；再用 Xcode/Console.app 查看 iOS 系统日志里 `[ArrowGameHelper]` 开头的日志。

**Q: 求解结果不对？**  
A: 检查 `grid` 的行列尺寸是否与实际关卡一致，方向数字有没有写反。本求解器假设所有箭头形状占 1 格；如果游戏里有长条形箭头，需要改 Solver 把每个箭头占用的格子一起处理。

---

## 许可证

MIT / 仅供学习交流。
