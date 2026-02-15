#!/usr/bin/env bash
# Detect outdated container images in docker-compose files.
#
# Required env:
#   COMPOSE_PATTERN  - glob for compose files (e.g., docker-compose.yml)
#   GITHUB_OUTPUT    - set by the Actions runner
#
# Outputs (via GITHUB_OUTPUT):
#   has_updates  - "true" if any image was updated
#
# Side effects:
#   - Updates compose files in-place with newer image tags
#   - Bumps per-app metadata.yaml if present alongside compose file
#   - Bumps VERSION and .bumpversion.cfg if no per-app metadata was bumped
#   - Writes /tmp/pr_body.md with the PR description

set -euo pipefail

python3 -c "import yaml" 2>/dev/null || pip install --quiet --break-system-packages pyyaml

# ---------------------------------------------------------------------------
# Parse images from compose files
# ---------------------------------------------------------------------------

IMAGES=$(python3 << 'PYEOF'
import yaml, os, glob

for f in sorted(glob.glob(os.environ["COMPOSE_PATTERN"], recursive=True)):
    with open(f) as fh:
        data = yaml.safe_load(fh)
    if not data or "services" not in data:
        continue
    for name, svc in data.get("services", {}).items():
        img = svc.get("image", "")
        if ":" in img:
            ref, tag = img.rsplit(":", 1)
            print(f"{f}|{name}|{ref}|{tag}")
PYEOF
)

if [ -z "$IMAGES" ]; then
  echo "No tagged images found"
  echo "has_updates=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

echo "=== Images found ==="
echo "$IMAGES"
echo ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build regex from a tag: replace digit runs with [0-9]+, escape the rest.
# e.g. "v3.6.7" -> "^v[0-9]+\.[0-9]+\.[0-9]+$"
tag_pattern() {
  python3 -c "
import re, sys
tag = sys.argv[1]
parts = re.split(r'(\d+)', tag)
pat = ''.join('[0-9]+' if p.isdigit() else re.escape(p) for p in parts if p)
print('^' + pat + r'$')
" "$1"
}

# Fetch all tags from Docker Hub or GHCR.
fetch_tags() {
  local image=$1
  if [[ $image == ghcr.io/* ]]; then
    local repo=${image#ghcr.io/}
    local token
    token=$(curl -fsSL "https://ghcr.io/token?scope=repository:${repo}:pull" \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
    # n=10000: OCI tags/list defaults to ~100 in lex order which misses
    # high-numbered versions (e.g., v1.51.0 sorts after v1.9.0)
    curl -fsSL -H "Authorization: Bearer $token" \
      "https://ghcr.io/v2/${repo}/tags/list?n=10000" \
      | python3 -c "import sys,json;[print(t) for t in json.load(sys.stdin).get('tags',[])]"
  else
    local path=$image
    [[ $image != */* ]] && path="library/$image"
    curl -fsSL \
      "https://hub.docker.com/v2/repositories/${path}/tags?page_size=100&ordering=last_updated" \
      | python3 -c "import sys,json;[print(r['name']) for r in json.load(sys.stdin).get('results',[])]"
  fi
}

# ---------------------------------------------------------------------------
# Check each image for updates
# ---------------------------------------------------------------------------

UPDATES_FILE=$(mktemp)
METADATA_BUMPS_FILE=$(mktemp)
BUMPED_METADATA=""  # track already-bumped metadata files
HAS_UPDATES=false
DID_METADATA_BUMP=false
trap 'rm -f "$UPDATES_FILE" "$METADATA_BUMPS_FILE"' EXIT

while IFS='|' read -r file service image current_tag; do
  echo "--- $service ($image:$current_tag) ---"

  pattern=$(tag_pattern "$current_tag")
  echo "  Pattern: $pattern"

  if ! all_tags=$(fetch_tags "$image" 2>/dev/null); then
    echo "  WARNING: Failed to fetch tags, skipping"
    continue
  fi

  matching=$(echo "$all_tags" | grep -E "$pattern" || true)
  if [ -z "$matching" ]; then
    echo "  No tags matching pattern"
    continue
  fi

  latest=$(echo "$matching" | sort -V | tail -1)
  echo "  Latest: $latest"

  if [ "$latest" != "$current_tag" ]; then
    echo "  UPDATE: $current_tag -> $latest"
    HAS_UPDATES=true
    sed -i "s|${image}:${current_tag}|${image}:${latest}|g" "$file"
    echo "| $service | $image | \`$current_tag\` | \`$latest\` |" >> "$UPDATES_FILE"

    # Bump per-app metadata.yaml if present alongside the compose file
    app_dir=$(dirname "$file")
    metadata="$app_dir/metadata.yaml"
    if [ -f "$metadata" ] && [[ "$BUMPED_METADATA" != *"|$metadata|"* ]]; then
      stripped_tag="${latest#v}"
      new_meta_ver="${stripped_tag}-1"
      old_meta_ver=$(python3 -c "
import yaml, sys
d = yaml.safe_load(open(sys.argv[1]))
v = d.get('version')
if v is None: sys.exit(1)
print(v)
" "$metadata") || { echo "  metadata.yaml: no version field, skipping"; continue; }
      # Update version and upstream_version, preserving any YAML quoting style
      python3 - "$metadata" "$new_meta_ver" "$stripped_tag" << 'PYEOF'
import sys
path, new_ver, new_upstream = sys.argv[1:]
lines = []
for line in open(path):
    for key, val in [('version:', new_ver), ('upstream_version:', new_upstream)]:
        if line.startswith(key):
            rest = line[len(key):].strip()
            if rest.startswith('"') or rest.startswith("'"):
                q = rest[0]
                line = f'{key} {q}{val}{q}\n'
            else:
                line = f'{key} {val}\n'
            break
    lines.append(line)
with open(path, 'w') as f:
    f.writelines(lines)
PYEOF
      BUMPED_METADATA="${BUMPED_METADATA}|$metadata|"
      echo "| $service | \`$old_meta_ver\` | \`$new_meta_ver\` |" >> "$METADATA_BUMPS_FILE"
      DID_METADATA_BUMP=true
      echo "  metadata.yaml: $old_meta_ver -> $new_meta_ver"
    fi
  else
    echo "  Up to date"
  fi
done <<< "$IMAGES"

if [ "$HAS_UPDATES" = false ]; then
  echo ""
  echo "All images are up to date."
  echo "has_updates=false" >> "$GITHUB_OUTPUT"
  rm -f "$UPDATES_FILE" "$METADATA_BUMPS_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# Bump VERSION if present
# ---------------------------------------------------------------------------

OLD_VER=""
NEW_VER=""
if [ "$DID_METADATA_BUMP" = false ] && [ -f VERSION ]; then
  OLD_VER=$(tr -d '[:space:]' < VERSION)
  NEW_VER=$(echo "$OLD_VER" | awk -F. '{ $NF = $NF + 1; print }' OFS='.')
  echo "$NEW_VER" > VERSION
  [ -f .bumpversion.cfg ] && \
    sed -i "s/current_version = .*/current_version = $NEW_VER/" .bumpversion.cfg
  echo "VERSION: $OLD_VER -> $NEW_VER"
fi

# ---------------------------------------------------------------------------
# Build PR body
# ---------------------------------------------------------------------------

{
  echo "## Container Image Updates"
  echo ""
  echo "| Service | Image | Current | Latest |"
  echo "|---------|-------|---------|--------|"
  cat "$UPDATES_FILE"
  if [ -s "$METADATA_BUMPS_FILE" ]; then
    echo ""
    echo "### App version bumps"
    echo ""
    echo "| App | Old | New |"
    echo "|-----|-----|-----|"
    cat "$METADATA_BUMPS_FILE"
  fi
  if [ -n "$OLD_VER" ]; then
    echo ""
    echo "### VERSION bump"
    echo "\`${OLD_VER}\` -> \`${NEW_VER}\`"
  fi
  echo ""
  echo "---"
  echo "*Automatically generated by container image update checker.*"
} > /tmp/pr_body.md

echo "has_updates=true" >> "$GITHUB_OUTPUT"
echo ""
echo "=== PR body ==="
cat /tmp/pr_body.md

rm -f "$UPDATES_FILE" "$METADATA_BUMPS_FILE"
