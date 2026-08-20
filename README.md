# kimi-code-nix

Always up-to-date Nix package for [kimi-code](https://github.com/MoonshotAI/kimi-code) — Moonshot AI's coding agent CLI.

**🚀 Automatically updated daily** — new upstream releases land on `main` within 24 hours, only after building green on all four platforms.

**📦 Prebuilt official artifacts** — the exact same tarballs that `npm install -g @moonshot-ai/kimi-code` installs.

[中文文档](README.zh-CN.md)

## Why this package?

### Primary Goal: Always Up-to-Date kimi-code for Nix Users

This flake provides immediate access to the latest kimi-code versions with:

1. **Prebuilt Artifacts**: the official npm bundles and release binaries — installs in seconds, not minutes
2. **Automated Updates**: checked daily; new kimi-code versions land within 24 hours of release
3. **Zero-Build Updates**: hashes come from the npm registry metadata itself — no tarball downloads needed to bump versions
4. **Flake-First Design**: direct flake usage, overlay included
5. **Hash Pinned**: every artifact is pinned by its registry-attested sha512 integrity hash

### Why Not the Official Flake or nixpkgs?

The official kimi-code flake builds from source — the whole pnpm workspace (26 packages) plus a SEA native binary on every update — and pins a specific nixpkgs channel. nixpkgs has no kimi-code package at all. `npm install -g` is fast but lives outside your declarative Nix configuration, and its self-updater mutates the install behind your configuration's back.

### Comparison Table

| Feature | npm global | nixpkgs | Official flake | This flake |
|---------|------------|---------|----------------|------------|
| **Latest Version** | ✅ Always | ❌ Not packaged | ✅ At release | ✅ Daily checks |
| **Install Speed** | ✅ Seconds | — | ❌ Source build | ✅ Seconds |
| **Declarative Config** | ❌ No | — | ✅ Yes | ✅ Yes |
| **Stable nixpkgs OK** | n/a | — | ❌ Pins nixos-25.11 | ✅ See below |
| **Version Pinning** | ⚠️ Manual | — | ✅ Flake lock | ✅ Flake lock |
| **Hash Verified** | ❌ No | — | ✅ Yes | ✅ Registry sha512 |
| **Reproducible** | ❌ No | — | ✅ Yes | ✅ Yes |

## Quick Start

### Fastest Installation (Try it now!)

```bash
nix run github:jerryfound/kimi-code-nix
```

(Or `nix run github:jerryfound/kimi-code-nix#kimi-code-standalone` for the
self-contained variant.)

### Install to Your System

```bash
nix profile add github:jerryfound/kimi-code-nix
```

On Nix versions before 2.30 that do not provide `nix profile add`, use
`nix profile install` instead.

## Using with Nix Flakes

**Which variant?** Most people want the default `kimi-code` (smaller, shares
the system Node.js). Pick `kimi-code-standalone` if your nixpkgs is older
than nixos-25.05, or if you want a fully self-contained binary you can copy
anywhere. Details in [Technical Details](#technical-details).

### Using with NixOS / nix-darwin (overlay, recommended)

The overlay exposes `pkgs.kimi-code` (and `pkgs.kimi-code-standalone`)
everywhere — system configuration, Home Manager, dev shells:

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

### Using with NixOS / Home Manager (direct reference)

Fine when you only install it in one place:

```nix
{ inputs, pkgs, ... }:
{
  environment.systemPackages = [
    inputs.kimi-code-nix.packages.${pkgs.system}.default
  ];
}
```

For Home Manager, use `home.packages` instead of `environment.systemPackages`.

### Reusing your own nixpkgs

The packages only use long-stable nixpkgs facilities (`fetchurl`, `stdenv`,
`makeWrapper`, `autoPatchelfHook`). To avoid a duplicate nixpkgs evaluation
in your closure, point the input at yours:

```nix
inputs.kimi-code-nix = {
  url = "github:jerryfound/kimi-code-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

The pinned `nixpkgs-unstable` is only the default for standalone use
(`nix run`, CI smoke builds); following your own nixpkgs is safe — verified
by building against archived stable branches:

| variant | minimum nixpkgs | limiting factor |
|---|---|---|
| `kimi-code` (npm) | **nixos-25.05** | upstream requires Node.js >= 22.19.0 |
| `kimi-code-standalone` | none found (verified down to **nixos-22.05**, 2022) | only `unzip`/`makeWrapper`/`autoPatchelfHook` |

On nixpkgs too old for the npm variant, evaluation fails with a clear message
pointing at `kimi-code-standalone`. The only nix-side requirement is
Nix >= 2.4 (flakes).

### In a dev shell

```nix
devShells.${system}.default = pkgs.mkShell {
  buildInputs = [
    kimi-code-nix.packages.${system}.default
  ];
};
```

## Technical Details

### Package Architecture

kimi-code ships on npm as a fully bundled package (`@moonshot-ai/kimi-code`):
`dist/main.mjs` plus web assets and darwin native addons, with two optional
native dependencies — `node-pty` (terminal sessions) and
`@mariozechner/clipboard` (clipboard images). This flake assembles the same
layout a global npm install would produce, with every tarball pinned by its
registry integrity hash:

- **macOS**: node-pty's tarball already ships prebuilt binaries — no
  compilation at all
- **Linux**: node-pty has no Linux prebuilds, so its small C++ addon is
  compiled with node-gyp (seconds, content-cached)

Two variants are available:

| | `kimi-code` (default) | `kimi-code-standalone` |
|---|---|---|
| Source | npm tarball (prebuilt JS bundle) | GitHub release binary |
| Runtime | nixpkgs `nodejs_22` (shared closure) | Node.js embedded, self-contained |
| Size | ~57MB + shared nodejs | ~180MB standalone single file |
| On Linux | node-pty compiled with node-gyp | ELF interpreter patched via autoPatchelf |

The standalone variant is a Node.js
[SEA](https://nodejs.org/api/single-executable-applications.html)
(Single Executable Application): the application bundle injected into a copy
of the Node executable itself. Pick it for zero nixpkgs runtime dependencies —
one file you can even copy to a machine without Nix (`libexec/kimi` inside
the store path).

On top of the bare artifacts, both variants add the polish a Nix-installed
CLI needs:

- **Runtime tools pinned into PATH**: kimi-code uses `fd` and `ripgrep` for
  search when present and otherwise downloads them from its CDN at runtime —
  the wrapper prepends their store paths so they always work
- **Self-update disabled**: the wrapper sets `KIMI_CODE_NO_AUTO_UPDATE=1`,
  since kimi-code must never try to overwrite itself in the read-only store
- **Install-time smoke test**: every build runs `kimi --version` and asserts
  it matches the pinned version

Supported systems: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`,
`aarch64-darwin`.

### How Updates Work

```
GitHub Actions (cron, daily 01:17 UTC)
        │
        ▼
scripts/update-sources.sh ──► registry.npmjs.org  (pure JSON, no downloads)
        │                     • @moonshot-ai/kimi-code dist-tags.latest → version
        │                     • each tarball → URL + sha512 integrity
        │                  ──► GitHub release manifest.json → SEA sha256
        ▼
sources.json  ◄── package.nix / package-standalone.nix read it
        │
        ▼
nix build on 4 platforms (staging branch) ──► fast-forward main
```

The npm registry metadata carries a `dist.integrity` sha512 hash for every
tarball, computed at publish time — so refreshing the pins requires nothing
but a few HTTP requests. Nix is only used for the post-update build
verification.

## Development

```bash
# Clone the repository
git clone https://github.com/jerryfound/kimi-code-nix
cd kimi-code-nix

# Build locally
nix build                        # npm variant
nix build .#kimi-code-standalone # standalone variant

# Test the build
./result/bin/kimi --version
```

Note: flakes only see files tracked by git, so remember to `git add` new
files before building.

## Updating kimi-code Version

### Automated Updates

A GitHub Action checks the npm registry daily. When a new stable version is
detected:

1. `scripts/update-sources.sh` rewrites `sources.json` with the new version,
   URLs, and hashes
2. Both variants are built on all four platforms (x86_64/aarch64 ×
   linux/darwin), including the `kimi --version` smoke test
3. Only if everything is green, `main` is fast-forwarded

The script fails loudly — blocking the update — if upstream changes its
optional dependency set, raises its Node.js version floor, or tags a
prerelease as latest, rather than silently producing a broken package.
A check that finds no new version touches nothing and produces no commit.
The workflow also runs on manual trigger via the GitHub Actions UI.

### Manual Updates

```bash
scripts/update-sources.sh   # rewrites sources.json if a new release exists
nix build                   # verify
./result/bin/kimi --version
```

## Troubleshooting

### Command not found

Make sure the Nix profile bin directory is in your PATH:

```bash
export PATH="$HOME/.nix-profile/bin:$PATH"
```

### "kimi-code requires nodejs_22 >= 22.19.0" on an older nixpkgs

The npm variant needs a nixpkgs whose `nodejs_22` satisfies upstream's floor
(nixos-25.05 or newer). On older nixpkgs, use the standalone variant, which
has no Node.js requirement:

```nix
inputs.kimi-code-nix.packages.${pkgs.system}.kimi-code-standalone
```

## License

This Nix packaging is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

kimi-code itself is licensed under the MIT License — see the [upstream repository](https://github.com/MoonshotAI/kimi-code) for details.

## Contributing

Contributions are welcome! Please submit pull requests or issues on GitHub.

## Related Projects

- [opencode-cli-nix](https://github.com/jerryfound/opencode-cli-nix) — same prebuilt packaging approach for opencode
- [llm-agents.nix](https://github.com/numtide/llm-agents.nix) — Nix packages for many AI coding agents, updated daily (builds kimi-code from source)
- [codex-cli-nix](https://github.com/sadjow/codex-cli-nix) — similar packaging for OpenAI Codex
- [nixpkgs](https://github.com/NixOS/nixpkgs) — the Nix Packages collection
