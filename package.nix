# Builds kimi-code from the prebuilt npm tarballs published by Moonshot AI.
#
# Unlike the upstream flake.nix (which compiles the whole pnpm workspace and a
# SEA native binary from source), this package downloads the published npm
# artifacts and only assembles them, so a version bump costs seconds instead of
# a full compile.
#
# All inputs come from `sources.json` (regenerated daily by CI from npm
# registry metadata); every tarball is pinned by its registry integrity hash.
#
# Runtime layout mirrors `npm install -g @moonshot-ai/kimi-code`:
#
#   lib/kimi-code/                     main package (dist/, dist-web/, native/)
#   lib/kimi-code/node_modules/
#     node-pty/                        terminal sessions (optionalDependency)
#     @mariozechner/clipboard/         clipboard images (optionalDependency)
#     @mariozechner/clipboard-<plat>/  napi-rs native binding for the platform
#
# node-pty ships prebuilt binaries for darwin only; on Linux its small C++
# addon is compiled here with node-gyp (still seconds, and cached by hash).

{ lib
, stdenv
, stdenvNoCC
, fetchurl
, makeWrapper
, nodejs_22
  # Only used by the Linux node-pty build; not a top-level nixpkgs
  # attribute before 24.11, so default to null to keep evaluation working.
, node-gyp ? null
, python3
, fd
, ripgrep
  # Not present before nixpkgs 24.11; fall back to a plain --version check.
, versionCheckHook ? null
, sources
}:

let
  inherit (sources) version;

  system = stdenvNoCC.hostPlatform.system;
  isLinux = stdenvNoCC.hostPlatform.isLinux;

  # Platform key shared by the node-pty prebuilds directory name and the
  # clipboard napi-rs package suffix (@mariozechner/clipboard-<key>).
  platformKey =
    {
      "aarch64-darwin" = "darwin-arm64";
      "x86_64-darwin" = "darwin-x64";
      "x86_64-linux" = "linux-x64-gnu";
      "aarch64-linux" = "linux-arm64-gnu";
    }.${system} or (throw "kimi-code-nix: unsupported system ${system}");

  fetch = { url, hash, ... }: fetchurl { inherit url hash; };

  src = fetch { inherit (sources) url hash; };
  nodePtySrc = fetch sources.nodePty;
  clipboardJsSrc = fetch sources.clipboard;
  clipboardNativeSrc = fetch sources.clipboard.native.${platformKey};

  # Linux-only: compile pty.node + spawn-helper from source (node-gyp).
  # Never instantiated on darwin, where the tarball prebuilds are used.
  nodePtyNative = stdenv.mkDerivation {
    pname = "node-pty-native";
    inherit (sources.nodePty) version;

    src = nodePtySrc;

    # node-pty's only build-time dependency (header-only); binding.gyp
    # locates it via require('node-addon-api'), so it must sit in
    # node_modules before node-gyp runs.
    nodeAddonApiSrc = fetch sources.nodeAddonApi;

    nativeBuildInputs = [
      nodejs_22
      node-gyp
      python3
    ];

    # npm tarballs unpack to ./package
    sourceRoot = "package";

    postUnpack = ''
      mkdir -p $sourceRoot/node_modules/node-addon-api
      tar -xzf $nodeAddonApiSrc -C $sourceRoot/node_modules/node-addon-api --strip-components=1
      chmod -R u+w $sourceRoot
    '';

    buildPhase = ''
      runHook preBuild
      # --nodedir keeps node-gyp fully offline (headers from nixpkgs nodejs)
      node-gyp rebuild --nodedir=${nodejs_22}
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r build/Release $out/
      runHook postInstall
    '';
  };
in

# Upstream requires node >= 22.19.0; the first stable nixpkgs branch with a
# qualifying nodejs_22 is nixos-25.05. Fail with a legible message instead of
# a broken runtime.
assert lib.assertMsg (lib.versionAtLeast nodejs_22.version "22.19.0") ''
  kimi-code requires nodejs_22 >= 22.19.0 (nixpkgs 25.05 or newer).
  On older nixpkgs, use the kimi-code-standalone variant instead.
'';

stdenvNoCC.mkDerivation ({
  pname = "kimi-code";
  inherit version src;

  nativeBuildInputs = [ makeWrapper ];

  # npm tarballs unpack to ./package
  sourceRoot = "package";

  installPhase = ''
    runHook preInstall

    dest=$out/lib/kimi-code
    mkdir -p $dest/node_modules/@mariozechner $out/bin

    # Main package: bundled CLI (dist/), web assets (dist-web/) and darwin
    # native addons (native/). The npm postinstall script is skipped on
    # purpose: it only renames legacy Python `kimi-cli` shims, which is
    # meaningless for a Nix install.
    cp -r . $dest
    chmod -R u+w $dest

    # node-pty: plain JS plus the native binding. The loader
    # (lib/utils.js) checks build/Release first, then prebuilds/<plat>.
    mkdir -p $dest/node_modules/node-pty
    tar -xzf ${nodePtySrc} -C $dest/node_modules/node-pty --strip-components=1
    ${if isLinux then ''
      rm -rf $dest/node_modules/node-pty/prebuilds
      mkdir -p $dest/node_modules/node-pty/build
      cp -r ${nodePtyNative}/Release $dest/node_modules/node-pty/build/
    '' else ''
      rm -rf $dest/node_modules/node-pty/prebuilds/win32-*
      # npm tarballs store spawn-helper without the exec bit; node-pty
      # execs it directly and fails with `posix_spawnp failed` otherwise.
      chmod +x $dest/node_modules/node-pty/prebuilds/*/spawn-helper
    ''}

    # clipboard: napi-rs umbrella package plus the per-platform .node package
    mkdir -p $dest/node_modules/@mariozechner/clipboard
    tar -xzf ${clipboardJsSrc} -C $dest/node_modules/@mariozechner/clipboard --strip-components=1
    mkdir -p "$dest/node_modules/@mariozechner/clipboard-${platformKey}"
    tar -xzf ${clipboardNativeSrc} -C "$dest/node_modules/@mariozechner/clipboard-${platformKey}" --strip-components=1

    # Drop native blobs for foreign platforms
    rm -rf $dest/native/win32
    ${lib.optionalString stdenvNoCC.hostPlatform.isDarwin ''
      find $dest/native/darwin -mindepth 2 -maxdepth 2 -type d \
        ! -name '${platformKey}' -exec rm -rf {} +
    ''}

    # KIMI_CODE_NO_AUTO_UPDATE: the built-in updater cannot work from the
    # read-only store; updates come from this flake instead.
    # fd/ripgrep on PATH: kimi-code uses them for search when present and
    # otherwise downloads prebuilt archives from its CDN at runtime.
    makeWrapper ${nodejs_22}/bin/node $out/bin/kimi \
      --add-flags "$dest/dist/main.mjs" \
      --set KIMI_CODE_NO_AUTO_UPDATE 1 \
      --prefix PATH : ${lib.makeBinPath [ fd ripgrep ]}

    runHook postInstall
  '';

  doInstallCheck = true;
  # versionCheckHook runs `kimi --version` and asserts it prints `version`.
  # versionCheckProgram is set explicitly because the hook before nixpkgs
  # 25.11 resolves $out/bin/$pname and ignores meta.mainProgram.
  nativeInstallCheckInputs = lib.optional (versionCheckHook != null) versionCheckHook;
  versionCheckProgram = "${placeholder "out"}/bin/kimi";

  meta = {
    description = "Kimi Code CLI (packaged from the prebuilt npm artifacts)";
    homepage = "https://github.com/MoonshotAI/kimi-code";
    license = lib.licenses.mit;
    mainProgram = "kimi";
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
} // lib.optionalAttrs (versionCheckHook == null) {
  # Plain fallback check on nixpkgs < 24.11 (no versionCheckHook).
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/kimi --version
    runHook postInstallCheck
  '';
})
