# kimi-code-nix

[English README](README.md)

始终保持最新的 [kimi-code](https://github.com/MoonshotAI/kimi-code)（Moonshot AI 的编码 agent CLI）Nix 包。

**🚀 每日自动更新** —— 上游新版本在全平台构建通过后，24 小时内落到 `main`。

**📦 官方预编译产物** —— 就是 `npm install -g @moonshot-ai/kimi-code` 会安装的那些 tarball。

## 为什么需要这个包？

### 目标：让 Nix 用户始终用上最新的 kimi-code

1. **预编译产物**：官方 npm bundle 和 release 二进制——秒级安装，而不是分钟级编译
2. **自动更新**：每日检查；新版本发布后 24 小时内可用
3. **零构建更新**：hash 直接来自 npm registry 元数据——升版本不需要下载 tarball
4. **Flake 优先**：直接 flake 引用，附带 overlay
5. **hash 固定**：每个产物都用 registry 发布的 sha512 integrity hash 锁定

### 为什么不用官方 flake 或 nixpkgs？

官方 kimi-code flake 从源码构建——每次更新都要编译整个 pnpm workspace（26 个包）加 SEA 原生二进制，还钉死在特定 nixpkgs 频道上。nixpkgs 则根本没有 kimi-code 包。`npm install -g` 虽然快，但活在声明式 Nix 配置之外，而且它的自更新会绕过你的配置偷偷改动安装。

### 对比

| 特性 | npm 全局 | nixpkgs | 官方 flake | 本 flake |
|---|---|---|---|---|
| **版本时效** | ✅ 总是最新 | ❌ 未收录 | ✅ 发布即有 | ✅ 每日检查 |
| **安装速度** | ✅ 秒级 | — | ❌ 源码编译 | ✅ 秒级 |
| **声明式配置** | ❌ | — | ✅ | ✅ |
| **兼容 stable nixpkgs** | n/a | — | ❌ 钉死 nixos-25.11 | ✅ 见下文 |
| **版本锁定** | ⚠️ 手动 | — | ✅ flake lock | ✅ flake lock |
| **hash 校验** | ❌ | — | ✅ | ✅ registry sha512 |
| **可复现** | ❌ | — | ✅ | ✅ |

## 快速开始

### 最快方式（立即试用）

```bash
nix run github:jerryfound/kimi-code-nix
```

（自包含变体：`nix run github:jerryfound/kimi-code-nix#kimi-code-standalone`。）

### 安装到系统

```bash
nix profile add github:jerryfound/kimi-code-nix
```

Nix 2.30 之前的版本没有 `nix profile add`，请改用 `nix profile install`。

## 在 flake 中使用

**选哪个变体？** 大多数人用默认的 `kimi-code` 即可（体积更小，与系统共享
Node.js）。如果你的 nixpkgs 老于 nixos-25.05，或者想要一个可以随便拷贝的
完全自包含二进制，选 `kimi-code-standalone`。详见[技术细节](#技术细节)。

### NixOS / nix-darwin（overlay，推荐）

overlay 让 `pkgs.kimi-code`（和 `pkgs.kimi-code-standalone`）在所有地方
可用——系统配置、Home Manager、dev shell：

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    kimi-code-nix.url = "github:jerryfound/kimi-code-nix";
  };

  outputs = { nixpkgs, kimi-code-nix, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [{
        nixpkgs.overlays = [ kimi-code-nix.overlays.default ];
        environment.systemPackages = [ pkgs.kimi-code ];
      }];
    };
  };
}
```

### NixOS / Home Manager（直接引用）

只在一个地方安装时用这种方式即可：

```nix
{ inputs, pkgs, ... }:
{
  environment.systemPackages = [
    inputs.kimi-code-nix.packages.${pkgs.system}.default
  ];
}
```

Home Manager 下把 `environment.systemPackages` 换成 `home.packages`。

### 复用你自己的 nixpkgs

本包只用到 nixpkgs 里长期稳定的设施（`fetchurl`、`stdenv`、`makeWrapper`、
`autoPatchelfHook`）。为避免闭包里多一份 nixpkgs 求值，把 input 指向你的：

```nix
inputs.kimi-code-nix = {
  url = "github:jerryfound/kimi-code-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

钉住的 `nixpkgs-unstable` 只是独立使用场景（`nix run`、CI 冒烟构建）的默认值；
跟随你自己的 nixpkgs 是安全的——已对各归档 stable 分支实测：

| 变体 | 最低 nixpkgs | 限制因素 |
|---|---|---|
| `kimi-code`（npm） | **nixos-25.05** | 上游要求 Node.js >= 22.19.0 |
| `kimi-code-standalone` | 未找到下限（实测至 **nixos-22.05**，2022 年） | 只有 `unzip`/`makeWrapper`/`autoPatchelfHook` |

nixpkgs 太老时，npm 版会在求值阶段给出明确报错并指向
`kimi-code-standalone`。对 nix 工具本身的唯一要求是 Nix >= 2.4（flakes）。

### 在 dev shell 里

```nix
devShells.${system}.default = pkgs.mkShell {
  buildInputs = [
    kimi-code-nix.packages.${system}.default
  ];
};
```

## 技术细节

### 打包架构

kimi-code 在 npm 上以全量 bundle 发布（`@moonshot-ai/kimi-code`）：
`dist/main.mjs` 加 web 资源和 darwin 原生扩展，外加两个可选原生依赖——
`node-pty`（终端会话）和 `@mariozechner/clipboard`（剪贴板图片）。本 flake
组装出与 npm 全局安装一致的布局，每个 tarball 都用 registry integrity
hash 固定：

- **macOS**：node-pty 的 tarball 自带预编译产物——完全不编译
- **Linux**：node-pty 没有 Linux 预编译产物，其小型 C++ 扩展用 node-gyp
  现场编译（秒级，按 hash 缓存）

两种变体：

| | `kimi-code`（默认） | `kimi-code-standalone` |
|---|---|---|
| 来源 | npm tarball（预编译 JS bundle） | GitHub release 二进制 |
| 运行时 | nixpkgs 的 `nodejs_22`（闭包共享） | 内嵌 Node.js，完全自包含 |
| 体积 | ~57MB + 共享 nodejs | ~180MB 独立单文件 |
| Linux 上 | node-pty 用 node-gyp 现场编译 | 用 autoPatchelf 修补 ELF 解释器 |

standalone 变体是 Node.js 的
[SEA](https://nodejs.org/api/single-executable-applications.html)
（Single Executable Application）：应用 bundle 注入一份 Node 可执行文件
本体。想要零 nixpkgs 运行时依赖就选它——单文件甚至可以拷到没有 Nix 的
机器上跑（store 路径里的 `libexec/kimi`）。

在裸产物之上，两个变体都加了一个 Nix 安装的 CLI 应有的打磨：

- **运行时工具钉进 PATH**：kimi-code 搜索时会用 `fd` 和 `ripgrep`，没有
  就在运行时从自家 CDN 下载——wrapper 把它们的 store 路径放进 PATH，
  永远可用
- **禁用自更新**：wrapper 设置 `KIMI_CODE_NO_AUTO_UPDATE=1`——只读 store
  里的程序绝不能尝试覆写自己
- **安装时冒烟测试**：每次构建都跑 `kimi --version` 并断言与锁定版本一致

支持的系统：`x86_64-linux`、`aarch64-linux`、`x86_64-darwin`、`aarch64-darwin`。

### 更新机制

```
GitHub Actions（cron，每日 UTC 01:17）
        │
        ▼
scripts/update-sources.sh ──► registry.npmjs.org（纯 JSON，不下载）
        │                     • @moonshot-ai/kimi-code dist-tags.latest → 版本
        │                     • 每个 tarball → URL + sha512 integrity
        │                  ──► GitHub release manifest.json → SEA sha256
        ▼
sources.json  ◄── package.nix / package-standalone.nix 读取
        │
        ▼
四平台 nix build（暂存分支） ──► 快进 main
```

npm registry 元数据为每个 tarball 携带发布时计算的 `dist.integrity`
sha512——刷新锁定只需要几次 HTTP 请求。Nix 只用于更新后的构建验证。

## 开发

```bash
# 克隆仓库
git clone https://github.com/jerryfound/kimi-code-nix
cd kimi-code-nix

# 本地构建
nix build                        # npm 变体
nix build .#kimi-code-standalone # standalone 变体

# 测试
./result/bin/kimi --version
```

注意：flake 只看 git 已跟踪的文件，新文件记得先 `git add`。

## 更新 kimi-code 版本

### 自动更新

GitHub Action 每日检查 npm registry。发现新的稳定版本时：

1. `scripts/update-sources.sh` 用新版本号、URL 和 hash 重写 `sources.json`
2. 两个变体在四个平台（x86_64/aarch64 × linux/darwin）上构建，包括
   `kimi --version` 冒烟测试
3. 全部通过后才快进 `main`

如果上游改动可选依赖集合、提高 Node.js 版本下限、或把预发布版错标为
latest，脚本会直接报错中止，而不是悄悄产出坏包。没有新版本时不做任何
改动、不产生 commit。workflow 也支持在 GitHub Actions 页面手动触发。

### 手动更新

```bash
scripts/update-sources.sh   # 有新版本则重写 sources.json
nix build                   # 验证
./result/bin/kimi --version
```

## 故障排查

### 命令找不到

确认 Nix profile 的 bin 目录在 PATH 里：

```bash
export PATH="$HOME/.nix-profile/bin:$PATH"
```

### 老 nixpkgs 上报 "kimi-code requires nodejs_22 >= 22.19.0"

npm 版要求 nixpkgs 的 `nodejs_22` 满足上游下限（nixos-25.05 或更新）。
更老的 nixpkgs 请用 standalone 变体，它没有 Node.js 要求：

```nix
inputs.kimi-code-nix.packages.${pkgs.system}.kimi-code-standalone
```

## 许可证

本 Nix 打包采用 MIT 许可证——见 [LICENSE](LICENSE)。

kimi-code 本身由 Moonshot AI 以 MIT 协议发布——见
[上游仓库](https://github.com/MoonshotAI/kimi-code)。

## 贡献

欢迎通过 GitHub 提交 PR 或 issue。

## 相关项目

- [opencode-cli-nix](https://github.com/jerryfound/opencode-cli-nix) —— opencode 的同类预编译打包
- [llm-agents.nix](https://github.com/numtide/llm-agents.nix) —— 众多 AI coding agent 的 Nix 包合集，每日更新（从源码构建 kimi-code）
- [codex-cli-nix](https://github.com/sadjow/codex-cli-nix) —— OpenAI Codex 的同类打包
- [nixpkgs](https://github.com/NixOS/nixpkgs) —— Nix 软件包合集
