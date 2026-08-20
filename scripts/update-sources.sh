#!/usr/bin/env bash
# Checks npm for a new @moonshot-ai/kimi-code release and rewrites
# sources.json with pinned tarball URLs and registry integrity hashes.
#
# Usage: scripts/update-sources.sh
#   stdout: the new version number if sources.json was updated, empty otherwise
#   stderr: progress / diagnostics
#   exit 1: upstream layout changed in a way this script refuses to guess about
#
# Requires: npm, jq, curl, python3 (all preinstalled on GitHub runners).

set -euo pipefail

PKG="@moonshot-ai/kimi-code"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/sources.json"

log() { echo "$*" >&2; }

# Highest version satisfying a semver range. `npm view <pkg>@<range> version`
# prints a JSON string for a single match, a JSON array (ascending) for many.
resolve() { # <package> <range>
  npm view --json "$1@$2" version | jq -r 'if type == "array" then last else . end'
}

tarball() { # <package> <version> -> {"url": ..., "hash": ...}
  npm view --json "$1@$2" dist.tarball dist.integrity |
    jq -c '{url: .["dist.tarball"], hash: .["dist.integrity"]}'
}

latest="$(npm view "$PKG" version)"
current="$(jq -r .version "$SOURCES")"

# Reject prereleases even if one ever gets tagged `latest` by mistake.
if [[ "$latest" == *-* ]]; then
  log "ERROR: latest version '$latest' looks like a prerelease; refusing to package it."
  exit 1
fi

if [[ "$latest" == "$current" ]]; then
  log "up to date ($current)"
  exit 0
fi
log "update available: $current -> $latest"

meta="$(npm view --json "$PKG@$latest" engines optionalDependencies)"

# --- Guard rails: fail loudly instead of silently packaging something wrong ---

# Node runtime floor must stay within what package.nix provides (nodejs_22).
engines_node="$(jq -r '.engines.node // ""' <<<"$meta")"
min_major="$(sed -E 's/[^0-9]*([0-9]+).*/\1/' <<<"$engines_node")"
if [[ -n "$min_major" && "$min_major" -gt 22 ]]; then
  log "ERROR: $PKG@$latest requires node $engines_node, but package.nix wraps nodejs_22."
  log "       Bump the nodejs version in package.nix (and update this check)."
  exit 1
fi

# The packaging logic knows exactly these two optional dependencies.
opt_deps="$(jq -r '.optionalDependencies // {} | keys | sort | join("\n")' <<<"$meta")"
expected_opt_deps='@mariozechner/clipboard
node-pty'
if [[ "$opt_deps" != "$expected_opt_deps" ]]; then
  log "ERROR: optionalDependencies changed upstream:"
  log "$opt_deps"
  log "       Review the new dependencies and update package.nix + this script."
  exit 1
fi

# --- Resolve pinned versions -------------------------------------------------

pty_range="$(jq -r '.optionalDependencies["node-pty"]' <<<"$meta")"
pty_version="$(resolve node-pty "$pty_range")"
log "node-pty $pty_range -> $pty_version"

clip_range="$(jq -r '.optionalDependencies["@mariozechner/clipboard"]' <<<"$meta")"
clip_version="$(resolve "@mariozechner/clipboard" "$clip_range")"
log "clipboard $clip_range -> $clip_version"

# node-addon-api is node-pty's only build-time dependency (needed for the
# Linux source build of pty.node).
naa_range="$(npm view --json "node-pty@$pty_version" dependencies | jq -r '."node-addon-api" // empty')"
if [[ -z "$naa_range" ]]; then
  log "ERROR: node-pty@$pty_version no longer depends on node-addon-api."
  log "       Review its build requirements and update package.nix + this script."
  exit 1
fi
naa_version="$(resolve node-addon-api "$naa_range")"
log "node-addon-api $naa_range -> $naa_version"

# --- Collect tarball URLs + hashes -------------------------------------------

main_tarball="$(tarball "$PKG" "$latest")"
pty_tarball="$(tarball node-pty "$pty_version")"
naa_tarball="$(tarball node-addon-api "$naa_version")"
clip_tarball="$(tarball "@mariozechner/clipboard" "$clip_version")"

# napi-rs publishes one native package per platform, same version as the
# umbrella package.
native_json='{}'
for key in darwin-arm64 darwin-x64 linux-x64-gnu linux-arm64-gnu; do
  entry="$(tarball "@mariozechner/clipboard-$key" "$clip_version")" || {
    log "ERROR: @mariozechner/clipboard-$key@$clip_version not found on npm."
    log "       The platform package layout may have changed; review upstream."
    exit 1
  }
  native_json="$(jq --arg k "$key" --argjson v "$entry" '. + {($k): $v}' <<<"$native_json")"
done

# --- SEA release binaries (GitHub Releases) -----------------------------------
# The release ships a manifest.json with per-platform filename + sha256, so
# hashes are pinned without downloading the ~60MB zips.

tag_encoded="%40moonshot-ai%2Fkimi-code%40$latest"
release_base="https://github.com/MoonshotAI/kimi-code/releases/download/$tag_encoded"

manifest="$(curl -fsSL "$release_base/manifest.json")" || {
  log "ERROR: no manifest.json at $release_base."
  log "       The SEA release layout may have changed; review upstream."
  exit 1
}
manifest_version="$(jq -r .version <<<"$manifest")"
if [[ "$manifest_version" != "$latest" ]]; then
  log "ERROR: manifest.json version ($manifest_version) != npm latest ($latest)."
  log "       The GitHub release may lag the npm release; retry later."
  exit 1
fi

hex_to_sri() { # <hex sha256> -> sha256-<base64>
  python3 -c 'import base64, binascii, sys; print("sha256-" + base64.b64encode(binascii.unhexlify(sys.argv[1])).decode())' "$1"
}

sea_json='{}'
for key in darwin-arm64 darwin-x64 linux-x64 linux-arm64; do
  filename="$(jq -r --arg k "$key" '.platforms[$k].filename // empty' <<<"$manifest")"
  checksum="$(jq -r --arg k "$key" '.platforms[$k].checksum // empty' <<<"$manifest")"
  if [[ -z "$filename" || -z "$checksum" ]]; then
    log "ERROR: manifest.json has no entry for platform $key."
    log "       The SEA release layout may have changed; review upstream."
    exit 1
  fi
  entry="$(jq -cn --arg url "$release_base/$filename" --arg hash "$(hex_to_sri "$checksum")" '{url: $url, hash: $hash}')"
  sea_json="$(jq --arg k "$key" --argjson v "$entry" '. + {($k): $v}' <<<"$sea_json")"
done

# --- Write sources.json --------------------------------------------------------

jq -n \
  --arg version "$latest" \
  --argjson main "$main_tarball" \
  --arg pty_version "$pty_version" \
  --argjson pty "$pty_tarball" \
  --arg naa_version "$naa_version" \
  --argjson naa "$naa_tarball" \
  --arg clip_version "$clip_version" \
  --argjson clip "$clip_tarball" \
  --argjson native "$native_json" \
  --argjson sea "$sea_json" \
  '{
    version: $version,
    url: $main.url,
    hash: $main.hash,
    nodePty: { version: $pty_version, url: $pty.url, hash: $pty.hash },
    nodeAddonApi: { version: $naa_version, url: $naa.url, hash: $naa.hash },
    clipboard: {
      version: $clip_version,
      url: $clip.url,
      hash: $clip.hash,
      native: $native
    },
    sea: $sea
  }' > "$SOURCES"

log "sources.json updated to $latest"
echo "$latest"
