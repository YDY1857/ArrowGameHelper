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

- **阶段一（已做好）· 侦察版 `recon/`**：注入支付宝，你跑一遍游戏，**三指轻点**触发。它会把当前界面的视图层级、相关类名、WebView 里的 JS 全局变量、以及小程序包路径全部 dump 成 `/var/mobile/arrowgame_recon.txt`，并在屏幕上显示摘要。
- **阶段二（待你数据）· 求解版 `ArrowGameHelper/`**：你把我采集到的信息发给我，我据此找到箭头真正的数据来源（原生 View / Cocos 节点 / WebView JS 状态），把自动抓取逻辑写进 Tweak，替换掉现在手动输入 grid 的部分。

> 阶段一现在就能编译、安装、出数据；阶段二依赖你采集到的真实信息，所以我没法提前写死。

---

## 当前限制

求解版目前是**手动输入盘面**模式：你先把 grid 写进 plist，插件负责求解和显示。等侦察版拿到数据后，我再把它升级成全自动。

---

## 文件说明

```
ArrowGameHelperTweak/
├── Makefile / control / ArrowGameHelper.plist / Tweak.x   # 求解版（手动网格 + 求解 + 覆盖层）
├── Solver.h / Solver.m                                   # 核心回溯求解器
├── recon/                                                # 侦察版（采集运行时信息）
│   ├── Makefile / control / ArrowGameRecon.plist / Tweak.x
├── .github/workflows/build.yml                           # 一次编译出两个 deb
└── README.md
```

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

1. 安装 `ArrowGameRecon` 的 deb，杀掉并重新打开支付宝。
2. 进到箭头小游戏的关卡界面，确保箭头盘面已经完整显示。
3. **三指同时轻点屏幕**触发侦察（不是三下，是三根手指一起点一下）。
4. 屏幕会弹出一个黑底绿字的滚动文本框，显示视图层级摘要；同时完整报告已写入 `/var/mobile/arrowgame_recon.txt`。
5. 用 Filza 打开这个 txt，全选复制，或者 AirDrop 传回电脑发给我。
6. 再三指轻点一下可关闭文本框。

侦察报告包含四块：

- `=== View hierarchy ===`：整个界面从 keyWindow 往下每一层 View 的类名和位置。用来判断游戏是原生 UIView、Cocos/Unity 的 GL 层、还是包在 WKWebView 里。
- `=== Relevant Objective-C classes ===`：所有类名里带 `Arrow/Game/Level/Grid/Puzzle/Sprite/Node/Canvas/MiniApp/...` 的类，是后续 hook 的候选。
- `=== WebView probe ===`：如果界面里有 WKWebView，会尝试 dump 出 JS 里跟 `game/level/arrow/grid` 相关的全局变量和页面文本。小程序游戏大多走这条路。
- `=== Mini-program / game files ===`：支付宝容器里名字带 `game/arrow/miniapp/level/puzzle` 的文件路径，方便我们定位小程序的 JS 主包。

把这份报告发我之后，我就能判断该 hook 哪一层、数据从哪拿，然后给你升级求解版。

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
