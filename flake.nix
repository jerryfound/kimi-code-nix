{
  description = "kimi-code (Moonshot AI CLI) packaged from the prebuilt npm artifacts, updated every 6 hours";

  # Pinned to the 26.05 stable branch: nixpkgs 26.11 (unstable) dropped
  # x86_64-darwin entirely, while 26.05 keeps it (supported until end of 2026).
  # Consumers should usually override with inputs.nixpkgs.follows anyway.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Single source of truth for version + tarball hashes, regenerated
      # every 6 hours by .github/workflows/update.yml from npm registry metadata.
      sources = builtins.fromJSON (builtins.readFile ./sources.json);
    in
    {
      packages = forAllSystems (pkgs: rec {
        # npm variant: prebuilt JS bundle on nixpkgs' nodejs_22 (default).
        kimi-code = pkgs.callPackage ./package.nix { inherit sources; };
        # standalone variant: self-contained SEA binary with Node.js embedded.
        kimi-code-standalone = pkgs.callPackage ./package-standalone.nix { inherit sources; };
        default = kimi-code;
      });

      overlays.default = final: prev: {
        kimi-code = final.callPackage ./package.nix { inherit sources; };
        kimi-code-standalone = final.callPackage ./package-standalone.nix { inherit sources; };
      };
    };
}
