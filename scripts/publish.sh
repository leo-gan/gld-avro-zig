#!/usr/bin/env bash
# Print the zig fetch hash for this release and attach it to the GitHub Release.
# Zig has no upload registry. See docs/publishing.md.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${root}"

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
elif [[ -n "${1:-}" ]]; then
  echo "usage: scripts/publish.sh [--dry-run]" >&2
  exit 2
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "zig is not on PATH. Install Zig 0.16.0." >&2
  exit 1
fi

version="$(sed -n 's/^[[:space:]]*\.version = "\([^"]*\)".*/\1/p' build.zig.zon | head -n 1)"
package_key="$(sed -n 's/^[[:space:]]*\.name = \.\([A-Za-z0-9_]*\).*/\1/p' build.zig.zon | head -n 1)"
module="$(sed -n 's/.*addModule("\([^"]*\)".*/\1/p' build.zig | head -n 1)"
if [[ -z "${version}" || -z "${package_key}" || -z "${module}" ]]; then
  echo "could not read name, version, or module from build.zig.zon and build.zig" >&2
  exit 1
fi

origin="$(git remote get-url origin)"
origin="${origin%.git}"
origin="${origin#git@github.com:}"
origin="${origin#https://github.com/}"
repo_name="${origin#*/}"

if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  tag_name="${GITHUB_REF_NAME}"
  tag_version="${tag_name#v}"
  if [[ "${tag_version}" != "${version}" ]]; then
    echo "git tag ${tag_name} does not match build.zig.zon version ${version}" >&2
    exit 1
  fi
else
  tag_name="${version}"
fi

archive="$(mktemp --suffix=.tar.gz)"
cache="$(mktemp -d)"
trap 'rm -rf "${archive}" "${cache}"' EXIT
# Fetch outside the repo. `zig fetch .` copies zig-pkg into itself and the path explodes.
git archive --format=tar.gz --prefix="${repo_name}-${tag_name}/" -o "${archive}" HEAD
archive_hash="$(zig fetch --global-cache-dir "${cache}" "${archive}" | tail -n 1)"

fetch_url="https://github.com/${origin}/archive/refs/tags/${tag_name}.tar.gz"
if [[ "${GITHUB_ACTIONS:-}" == "true" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  remote_hash=""
  for _try in 1 2 3 4 5; do
    if remote_hash="$(zig fetch --global-cache-dir "${cache}" "${fetch_url}" | tail -n 1)" && [[ -n "${remote_hash}" ]]; then
      break
    fi
    remote_hash=""
    sleep 5
  done
  if [[ -z "${remote_hash}" ]]; then
    echo "zig fetch failed for ${fetch_url}" >&2
    exit 1
  fi
  if [[ "${remote_hash}" != "${archive_hash}" ]]; then
    echo "local archive hash ${archive_hash}" >&2
    echo "GitHub tag archive hash ${remote_hash}" >&2
    exit 1
  fi
fi

block="$(cat <<EOF
Zig package \`${package_key}\`, module \`${module}\`.

\`\`\`zig
.dependencies = .{
    .${package_key} = .{
        .url = "${fetch_url}",
        .hash = "${archive_hash}",
    },
},
\`\`\`

\`\`\`bash
zig fetch --save=${package_key} ${fetch_url}
\`\`\`

Zig has no central upload registry. Zigistry lists this repository after the GitHub topic \`zig-package\` is set.
EOF
)"
printf '%s\n' "${block}"

if [[ "${dry_run}" -eq 1 ]]; then
  echo "dry-run: release notes were not changed"
  exit 0
fi

if [[ "${GITHUB_ACTIONS:-}" == "true" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  printf '%s\n' "${block}" | python3 scripts/github_release.py notes --tag "${tag_name}"
fi
