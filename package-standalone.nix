# Builds kimi-code from the official SEA (Single Executable Application)
# release binaries published on GitHub.
#
# A SEA binary is a copy of the Node.js executable with the application JS
# injected into it (via postject) — fully self-contained, no nodejs runtime
# dependency, at the cost of bundling a whole Node (~180MB unpacked per
# platform vs ~57MB for the npm variant plus a shared nodejs).
#
# Hashes come from the release's own manifest.json (see the `sea` block in
# sources.json, regenerated daily by CI).

{ lib
, stdenv
, stdenvNoCC
, fetchurl
, unzip
, makeWrapper
, autoPatchelfHook
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

  platformKey =
    {
      "aarch64-darwin" = "darwin-arm64";
      "x86_64-darwin" = "darwin-x64";
      "x86_64-linux" = "linux-x64";
      "aarch64-linux" = "linux-arm64";
    }.${system} or (throw "kimi-code-nix: unsupported system ${system}");

  src = fetchurl { inherit (sources.sea.${platformKey}) url hash; };
in

stdenvNoCC.mkDerivation ({
  pname = "kimi-code-standalone";
  inherit version src;

  nativeBuildInputs = [ unzip makeWrapper ]
    # The SEA binary is a prebuilt glibc-linked Node; on NixOS its ELF
    # interpreter and libstdc++ must be rewritten to store paths.
    ++ lib.optionals isLinux [ autoPatchelfHook ];

  buildInputs = lib.optionals isLinux [ stdenv.cc.cc.lib ];

  unpackPhase = ''
    runHook preUnpack
    unzip $src
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 kimi $out/libexec/kimi
    # Wrapper: disable the built-in updater (read-only store; updates come
    # from this flake) and put fd/ripgrep on PATH so kimi-code uses them
    # instead of downloading prebuilt archives from its CDN at runtime.
    makeWrapper $out/libexec/kimi $out/bin/kimi \
      --set KIMI_CODE_NO_AUTO_UPDATE 1 \
      --prefix PATH : ${lib.makeBinPath [ fd ripgrep ]}
    runHook postInstall
  '';

  # Stripping rewrites section tables and can invalidate the offsets of the
  # injected SEA blob (same reason the upstream Nix build sets dontStrip).
  dontStrip = true;

  doInstallCheck = true;
  # versionCheckHook runs `kimi --version` and asserts it prints `version`.
  # versionCheckProgram is set explicitly because the hook before nixpkgs
  # 25.11 resolves $out/bin/$pname and ignores meta.mainProgram.
  nativeInstallCheckInputs = lib.optional (versionCheckHook != null) versionCheckHook;
  versionCheckProgram = "${placeholder "out"}/bin/kimi";

  meta = {
    description = "Kimi Code CLI (standalone binary with Node.js embedded; built from the official SEA release)";
    homepage = "https://github.com/MoonshotAI/kimi-code";
    license = lib.licenses.mit;
    mainProgram = "kimi";
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
} // lib.optionalAttrs isLinux {
  # On a glibc distro this binary would run even without patching, so a
  # bare `--version` proves nothing on CI runners. Assert the ELF
  # interpreter was actually rewritten into the store (NixOS purity).
  postInstallCheck = ''
    interp="$(patchelf --print-interpreter $out/libexec/kimi)"
    case "$interp" in
      /nix/store/*) ;;
      *) echo "ELF interpreter was not patched to a store path: $interp" >&2; exit 1 ;;
    esac
  '';
} // lib.optionalAttrs (versionCheckHook == null) {
  # Plain fallback check on nixpkgs < 24.11 (no versionCheckHook).
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/kimi --version
    runHook postInstallCheck
  '';
})
