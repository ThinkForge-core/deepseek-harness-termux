# Termux ripgrep 修复（glob / grep 工具 "ripgrep launch failed"）

> 依据第三方文章整理：`@vscode/ripgrep` 1.18.0 在 Termux 上的平台包解析问题。
> 本文档同时是修复记录与故障排查手册。

## 现象

在 Termux（Android arm64）上，DSH 的 glob / grep 工具报错：

```
ripgrep launch failed
```

每次启动新进程都会复现，重装 / 重启无效。

## 根因

`@vscode/ripgrep` 1.18.0 解析其平台二进制的方式是动态 require 平台包：

```
@vscode/ripgrep-${process.platform}-${process.arch}
```

在 Termux 上 `process.platform === "android"`、`process.arch === "arm64"`，于是解析为：

```
@vscode/ripgrep-android-arm64   ← 上游不存在这个包
```

模块求值抛错（`Could not find @vscode/ripgrep-android-arm64`），且 **Node 会把求值失败的 ESM 模块缓存在当前进程内**——之后重复 import 永远得到同一个失败结果，所以每个新进程都报错，
而 `npm install` / `npm update` 也无法解决（问题包本来就不存在，无从安装）。

## 修复（两部分）

### Part 1 — 平台包 shim

在 DSH 的 `node_modules` 下手工创建 `@vscode/ripgrep-android-arm64` 包，使其平台包解析"命中"，
`bin/rg` 符号链接到可用的系统 ripgrep（Termux 官方包 `ripgrep`，`/data/data/com.termux/files/usr/bin/rg`）。

```
node_modules/@vscode/ripgrep-android-arm64/
├── package.json   # name/version @vscode/ripgrep-android-arm64@1.18.0, bin.rg -> bin/rg
└── bin/rg -> /data/data/com.termux/files/usr/bin/rg
```

### Part 2 — 补丁 `dsh-tool-fs-search` 的 `resolveRgPath()`

`patches/08-dsh-tool-fs-search-android-rg.patch`（`install.sh` 自动应用）把原来基于
`import("@vscode/ripgrep")`（会触发模块求值 → 抛错 → 缓存失败结果）的解析替换为：

1. `require.resolve()` 纯文件系统解析平台包（不做模块求值，永不抛错）；
2. 失败则回退到系统 `rg`（`RIPGREP_BIN` 环境变量优先，然后是
   `/data/data/com.termux/files/usr/bin/rg`、`/usr/bin/rg`、`/usr/local/bin/rg`）；
3. 全部失败才抛错。

`require.resolve` 同样绕过了 Node 对坏 ESM 模块的失败缓存，因此**热重载后当前运行中的 server 进程即刻恢复**。

```js
rgPathPromise ??= Promise.resolve().then(() => {
  const require = createRequire(import.meta.url);
  const binaryName = process.platform === "win32" ? "rg.exe" : "rg";
  try {
    return require.resolve(`@vscode/ripgrep-${process.platform}-${process.arch}/bin/${binaryName}`);
  } catch {
    const candidates = process.env.RIPGREP_BIN
      ? [process.env.RIPGREP_BIN]
      : ["/data/data/com.termux/files/usr/bin/rg", "/usr/bin/rg", "/usr/local/bin/rg"];
    for (const candidate of candidates) {
      if (candidate && existsSync(candidate)) return candidate;
    }
    throw new Error(`Could not resolve packaged ripgrep for ${process.platform}-${process.arch} and no system rg was found`);
  }
});
```

## 仓库集成

- `install.sh` 在打完所有补丁后自动创建 shim（幂等），并应用 `08-*.patch`；
- 安装完成时的 patched 校验循环会把 `08-dsh-tool-fs-search-android-rg` 映射到 `dsh-tool-fs-search` 校验。

## 重新应用 / 恢复（`npm update -g @deepseek-ai/dsh` 之后）

升级会覆盖补丁与 shim，glob/grep 会再次报错。恢复命令：

```bash
bash ~/deepseek-harness-termux/scripts/fix-dsh-glob-rg.sh
```

脚本幂等（已修补则直接提示跳过），执行完会提示对运行中的实例热重载：

```
dev_reload_package "dsh-tool-fs-search"
```

## 验证

```bash
# 1. 系统 rg 存在
ls -l /data/data/com.termux/files/usr/bin/rg

# 2. 平台包解析直接命中（无需 import）
node -e 'console.log(require.resolve("@vscode/ripgrep-android-arm64/bin/rg"))'

# 3. 插件已修补（包含 require.resolve 标记）
grep -n 'createRequire(import.meta.url)' \
  ~/.npm-global/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js

# 4. 热重载后实际调用 glob / grep 工具，不再报 "ripgrep launch failed"
```