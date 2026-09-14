# deepseek-harness-termux

**在 Android / Termux 上运行完整的 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)(`@deepseek-ai/dsh`)— 核心功能完整全部可用。**

[English](README.md) | 简体中文

---

> [!NOTE]
> **本仓库是 [Vengisk/deepseek-harness-termux](https://github.com/Vengisk/deepseek-harness-termux) 的 fork。**
> 原项目已在下方致谢;本页所有 clone / 安装命令均指向**本 fork**,以获得本文档所述的补丁流水线。
> `upstream` 远程已指向原仓库,可用 `git fetch upstream && git merge upstream/main` 合入其改动。

---

`deepseek-harness-termux` 是一个社区维护的兼容层,将官方 [`@deepseek-ai/dsh`](https://github.com/deepseek-ai/deepseek-harness) 智能体框架移植到基于 [Termux](https://termux.com/) 的 Android 环境。官方 npm 包面向 glibc 系的 Linux 发行版构建,依赖的原生模块在 Android 的 Bionic libc 上要么编译失败、要么行为异常。本项目做法是直接修改关键源码以适配原生 Android 层,而不是禁用依赖这些模块的插件,让每个功能在 Termux 上都真实可用。

所有修复由单一的、基于锚点的补丁集合 —— `scripts/apply-termux-fixes.mjs` —— 应用于干净的上游安装。它可重复执行，且当上游代码变动时**直接报错**，绝不会静默失效。修复的有序清单见 [`TERMUX-PATCHES.md`](TERMUX-PATCHES.md)。

## 功能状态

Termux 构建中所有插件均启用并可用:

| 组件 | 状态 | 说明 |
|---|---|---|
| `dsh web` | ✅ 正常 | 服务运行于 `http://127.0.0.1:3080` |
| `dsh headless` | ✅ 正常 | 单会话无头模式 |
| `dsh plugin` | ✅ 正常 | 插件管理 |
| HMR(热重载) | ✅ 正常 | 以 `--expose-internals` 启动 |
| 子进程 (Subprocess) | ✅ 正常 | `node-pty` 已针对 Termux bionic 环境编译 |
| Bash 沙箱 | ⚠️ 有限 | `node-pty` 正常;`bubblewrap` 在运行时被 Android sepolicy 拦截,安全降级为 `SandboxUnavailableError`,不崩溃 |
| 权限系统 (Permission) | ✅ 正常 | 随 `node-pty` 一并恢复 |
| 会话持久化 | ✅ 已修复 | Android sepolicy 下 `link(2)` 回退为 `rename(2)` |
| 文件工具 (`write` / `edit`) | ✅ 已修复 | `dsh-fs-local` 中 `link(2)` → `rename(2)` —— 否则每次写文件都会被 Android sepolicy 拒绝 |
| 文件上传 / 附件 | ✅ 已修复 | `dsh-attachment-local` 中 `link(2)` → `rename(2)` / `copyFile()` |
| 图像处理 | ✅ 正常 | 真实 `sharp` + 官方 `@img/sharp-wasm32` 回退（无 android-arm64 原生二进制，但无需 stub） |
| Bash 终端 (PTY) | ✅ 已修复 | 在 Termux 上正确解析默认 shell 路径(`/usr/bin/bash`) |
| 移动端 UI 适配 | ✅ 自动安装 | 窄屏(<1024px)隐藏侧栏、目录变抽屉、会话全宽;宽屏无影响 |

## 系统要求

- **Android 8+** 推荐(更早版本可能可运行,但未经测试)
- **Termux** — 请从 [F-Droid](https://f-droid.org/en/packages/com.termux/) 安装(Play Store 版本不受支持且已过时)
- **Node.js >= 24**、**npm**、以及原生模块构建工具链:
  ```bash
  pkg update -y && pkg upgrade -y
  pkg install -y nodejs-lts binutils make pkg-config clang python cmake patch git proot which ndk-multilib libandroid-spawn
  ```
  (`ndk-multilib` 提供多 ABI NDK 工具链,`libandroid-spawn` 提供 `posix_spawn()`
  兼容层——两者对低版本 Android 设备很有帮助。`install.sh` 会自动安装这些,
  所以直接运行安装脚本时也可跳过本手动步骤。)
- **网络连接** — 用于下载依赖包

## 安装

> [!IMPORTANT]
> **受支持的 dsh 版本:`0.1.5-rc.2`(默认)。** 补丁器按精确锚点匹配上游代码,
> 因此默认安装一个经过端到端验证的**固定版本**,而不是会变动的标签。
>
> 注意:npm 的 `latest` 标签当前是 `0.1.5-rc.1`,而最新的已发布预发布版是
> `0.1.5-rc.2`(标签 `next`)——**`latest` 并不是最新的**。这个固定版本是出于
> 可复现性,而非绕过某个缺陷:在干净环境中,完整补丁集对 **rc.1 与 rc.2 两者**
> 都能全部应用(0 missing / 0 failed)。
> 若指定其他版本且上游代码已变动,补丁器会**直接报错**,而不会留下半打补丁的安装。

两种部署方式:

### 方案一 — 本机编译(install.sh)

完全可控,适用于任意 arm64 Termux;需一次性编译 `node-pty`/`koffi`(需要 clang + cmake + NDK sysroot,约 5–10 分钟):

```bash
# 克隆本 fork
git clone https://github.com/ThinkForge-core/deepseek-harness-termux.git
cd deepseek-harness-termux

# 运行自动化安装脚本(安装 dsh、应用补丁、编译 node-pty)
bash install.sh

# ...或显式指定:其他固定版本,或不固定的 npm 标签
bash install.sh 0.1.5-rc.1
bash install.sh latest
```

安装脚本是幂等的 —— 重复执行时会跳过已应用的补丁和已构建的产物。

安装完成后 `dsh` 直接可用:已安装的 `bin.js` shebang 会被补上
`--expose-internals`(任何 shell 里 npm 的 `dsh` 命令都能直接用),同时自动
向 `~/.bashrc` 追加 `dsh` 别名(不存在则创建;zsh 用户用 `~/.zshrc`)——
不会覆盖你已有的 shell 配置。

### 安装脚本原理

1. **全局安装** `@deepseek-ai/dsh`。
2. **应用 Android 运行时修复**（`scripts/apply-termux-fixes.mjs`，幂等、基于锚点 —— 见 [`TERMUX-PATCHES.md`](TERMUX-PATCHES.md)）。
3. **编译原生模块** (`koffi`、`node-pty`):基于 Termux bionic 环境编译——编译**之前**先准备好构建环境(node 头文件、`GYP_DEFINES`、`common.gypi` 修复)并应用源码补丁。
4. **修补 `koffi`**:在 Android 上剔除不支持的 `statx()` 系统调用(Bionic 中不存在,回退到 POSIX `stat()`/`fstat()`)。
5. **安装 `@img/sharp-wasm32`** 作为图像处理的可移植 WebAssembly 回退方案(无需原生编译)。
6. **安装移动端 UI 插件** [`dsh-web-mobile`](https://github.com/mexiaosqwq/dsh-web-mobile)(by @mexiaosqwq)——窄屏自动隐藏侧栏、目录变抽屉、会话全宽。
7. **冒烟测试**:验证 `node-pty` 可以加载、默认 shell 可以解析。

### 方案二 — 预编译原生模块(无需编译)

完全不需要编译:`node-pty` 和 `koffi` 已为 android-arm64 预编译(N-API,跨 Node 版本 ABI 稳定),源码也已打好转,安装就是纯下载 + 解压。

> [!IMPORTANT]
> **本 fork 尚未发布预编译 release 产物** —— Releases 页面为空,因此不存在可用的
> `releases/latest/download/...` 链接。请先在本机构建一次(需要方案一已成功执行),
> 再本地安装:
>
> ```bash
> bash scripts/build-prebuilt.sh          # 生成 dsh-termux.tgz + dsh-termux-full.tgz
> npm i -g ./dsh-termux-full.tgz          # 约 57MB,完全自包含
> dsh web
> ```
>
> 把这两个文件上传到本 fork 的 release 后,即可使用等价的短命令:
>
> ```bash
> npm i -g https://github.com/ThinkForge-core/deepseek-harness-termux/releases/latest/download/dsh-termux-full.tgz
> ```
>
> 请**不要**使用上游 fork 的 release 包做当前安装:它们构建自更旧的 dsh
> (`0.1.0-rc.6` 时期),与本文档所述的补丁集合不匹配。

`dsh-termux-full.tgz` 是自包含变体(整个打过补丁的 dsh + `node_modules`,约 57MB)。
更小的 `dsh-termux.tgz`(约 360KB)则由 postinstall 从 npm registry 拉取
dsh(npmjs→npmmirror 自动回退)、应用补丁并放入预编译原生模块 —— 仅当在意
~57MB 下载体积时再选它。详见 [`prebuilt/README.md`](prebuilt/README.md)。
维护者用 [`scripts/build-prebuilt.sh`](scripts/build-prebuilt.sh) 重建两者。

## 使用方法

### 移动端 UI 适配

安装脚本会自动安装 [`dsh-web-mobile`](https://github.com/mexiaosqwq/dsh-web-mobile) 插件(by [@mexiaosqwq](https://github.com/mexiaosqwq))。在窄屏(<1024px)设备上:

- 侧栏 rail 隐藏,目录变为 overlay 抽屉
- 会话区独占全宽
- 状态栏适配(不遮挡内容)
- 设置界面改为近全宽 sheet


## 效果

| 会话主页(全宽) | 目录抽屉 | 设置界面 |
| --- | --- | --- |
| ![移动端会话主页](https://raw.githubusercontent.com/mexiaosqwq/dsh-web-mobile/main/assets/hero.png) | ![目录抽屉](https://raw.githubusercontent.com/mexiaosqwq/dsh-web-mobile/main/assets/drawer.png) | ![移动端设置界面](https://raw.githubusercontent.com/mexiaosqwq/dsh-web-mobile/main/assets/settings.png) |


### 启动

以全插件模式启动 Web 界面:

```bash
node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js web
```

或在 `~/.bashrc` 中添加别名:

```bash
alias dsh='node --expose-internals $(npm root -g)/@deepseek-ai/dsh/lib/bin.js'
```

`--expose-internals` 标志是必需的,因为 `cordis-plugin-hmr` 会访问 Node.js 内部模块(如 `node:internal/modules`),自 Node.js 22 起默认禁止访问。

### 网页搜索

Web UI 里有两种开启网页搜索的方式:

1. **推荐 — `dsh-web-search-pro`**(多引擎:Exa / DuckDuckGo / Bing / Jina / 平台搜索,带缓存)。装进 web profile:

   ```bash
   dsh plugin --profile web add dsh-web-search-pro
   # 它的 patch 引用了 @anweat/dsh-browser —— 需作为普通依赖装一下,
   # 否则启动时 `browser` 行无法解析:
   cd ~/.dsh/profiles/web && pnpm add @anweat/dsh-browser
   ```

   然后在 `~/.dsh/settings.yaml` 里配置 Exa key(热重载,改完即生效):

   ```yaml
   web-search-pro:
     exaApiKey: 'exa-...'        # 或把 EXA_API_KEY 写进 ~/.dsh/.credentials.yaml
     engines: [exa, ddg, bing]   # 可选;默认 [ddg,bing,exa,seam,jina]
   ```

   装完插件后重启一次 `dsh web`。

> [!WARNING]
> 已知问题(在 dsh `0.1.0-rc.6` 上复现;**未**在本 fork 验证的
> `0.1.5-rc.2` 上重新测试):安装 `dsh-web-search-pro@0.1.2` 及
> `@anweat/dsh-browser` 后,共享工具分发层被破坏——所有工具调用(含 GUI 自带工具)
> 都会报 `Cannot read properties of undefined (reading 'prepare')`
> (即 `dsh-tools` 里 `scheduler.prepare` 处 `registry[TOOL_RUNTIME_SCHEDULER]`
> 为 undefined)。根因指向插件在 profile 里装的独立 `@deepseek-ai/dsh-tools`
> 副本遮蔽了宿主注册表(Symbol 键调度器查询)。恢复方法:卸载插件并重启:
> `dsh plugin --profile web remove dsh-web-search-pro`
> 若作者发布修复版,可在空闲端口(`dsh web --port 3191`)先测试再替换线上实例。


2. **内置 `web-search-deepseek`** — 只讲 DeepSeek 的 *Anthropic 兼容* Messages API(`baseURL` + `/messages`,原生 `web_search_20250305` 工具)。⚠️ 它**不是** Exa 客户端:把 `baseURL` 指向 `https://api.exa.ai/search` 会去请求 `.../search/messages`,必然 **404**。保持默认 `https://api.deepseek.com/anthropic/v1`,并使用在该端点有效的 key。

## 源码补丁

所有修改由 `scripts/apply-termux-fixes.mjs` 按固定顺序应用。多数是基于锚点的就地修改；两个较大的补丁以 `.patch` 文件形式保留：

| 修复 | 目标包 | 说明 |
|---|---|---|
| sharp | `sharp` + `@img/sharp-wasm32` | 安装官方 WebAssembly 回退，无需原生 android-arm64 构建即可处理图片 |
| fs-local | `dsh-fs-local` | `link(2)` → `rename(2)` 回退：让 `write`/`edit` 文件工具可用 |
| session-persistence | `dsh-session-persistence-jsonl` | 会话文件 `link(2)` → `rename(2)` 回退（3 处，含 worker） |
| attachment-local | `dsh-attachment-local` | 上传与不可变别名 `link(2)` → `rename(2)`/`copyFile()` |
| flock | `node-addon-system` | Android 上 `flock(2)` 直接 no-op（Bionic 无此系统调用） |
| subprocess-local | `dsh-subprocess-local` | 进程组检查将 `android` 视同 `linux` |
| terminal-bash | `dsh-terminal-bash` | 解析 Termux 上真实存在的 shell |
| sandbox-local | `dsh-sandbox-local` | 使用 `proot` 作为沙箱执行器（[patch](patches/07-sandbox-local-proot-runner.patch)） |
| native-command | `dsh-native-command` | Android 下用 `termux-open` 打开路径/URL |
| directory-picker | `dsh-host-directory-picker-native` | Android 下目录选择走 zenity 路径 |
| workspace | `dsh-workspace` | 归档时跳过 session-known 检查 |
| ripgrep | `@vscode/ripgrep-android-arm64`（shim） | 解析到系统 `rg`；`@vscode/ripgrep` 无 android 平台包（见 [`docs/termux-ripgrep-fix.md`](docs/termux-ripgrep-fix.md)） |
| bin.js | `@deepseek-ai/dsh` | `--expose-internals` shebang |
| koffi | `koffi` | Android 上条件编译掉 `statx()`（[patch](patches/koffi-statx.patch)） |

`install.sh` 会自动执行该集合；每次 `npm install -g @deepseek-ai/dsh` 之后用 `bash fix-dsh-runtime.sh` 重新应用。

## 兼容性说明

- **平台判定**:Termux 上 `process.platform` 为 `"android"`,上游 `platform === "linux"` 分支统一扩展为 `platform === "linux" || platform === "android"`。
- **Bash 沙箱**:`bubblewrap` 需要 `user_namespaces` 及特定 `/proc` 访问权限,Android sepolicy 会拒绝。框架在运行时检测到这一情况并安全降级为 `SandboxUnavailableError`,而不是崩溃 —— 子进程执行本身仍通过 `node-pty` 正常工作。
- **Termux 路径**:`termux-open` 会唤起 Android 的 VIEW intent(浏览器、文件查看器等)。

## 项目结构

```
deepseek-harness-termux/
├── README.md                      # 英文 README
├── README.zh-CN.md                # 本文件（简体中文）
├── TERMUX-PATCHES.md              # 有序的 Termux 修复集合（权威参考）
├── LICENSE                        # MIT 许可证
├── install.sh                     # 从零开始的干净安装脚本（幂等）
├── fix-dsh-runtime.sh             # 升级后重新应用全部修复
├── docs/
│   └── termux-ripgrep-fix.md      # ripgrep android-arm64 修复（根因与恢复）
├── scripts/
│   ├── apply-termux-fixes.mjs     # 补丁集合本体（幂等、基于锚点）
│   ├── fix-npm.sh                 # 恢复工具：干净重装 node/npm
│   └── build-prebuilt.sh          # 可选的预编译包构建脚本
└── patches/                       # 由补丁器/安装脚本应用的大补丁
    ├── 07-sandbox-local-proot-runner.patch
    └── koffi-statx.patch
```

## 致谢

- **[Vengisk](https://github.com/Vengisk)** — 本 fork 所基于的原始
  [deepseek-harness-termux](https://github.com/Vengisk/deepseek-harness-termux) 兼容层。
- **[DeepSeek AI](https://github.com/deepseek-ai)** — 优秀的 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 智能体框架。
- **[@mexiaosqwq](https://github.com/mexiaosqwq)** — [dsh-web-mobile](https://github.com/mexiaosqwq/dsh-web-mobile) 移动端 UI 适配插件。
- **Termux 社区** — Android 终端环境。
- **koffi**、**node-pty**、**sharp** 的维护者。

## 许可证

MIT — 与官方 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 相同。参见 [LICENSE](LICENSE)。

---

*由 [ThinkForge-core](https://github.com/ThinkForge-core) 维护 — 基于
[Vengisk/deepseek-harness-termux](https://github.com/Vengisk/deepseek-harness-termux) 的
fork,非 DeepSeek 官方产品。*