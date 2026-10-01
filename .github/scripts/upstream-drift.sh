#!/usr/bin/env bash
# Compare upstream triggerdotdev/trigger.dev hosting/docker between the tag this
# template pins and the latest release, and write a Markdown report.
#
# Usage: upstream-drift.sh [PINNED] [LATEST]
#   PINNED defaults to the trigger.dev image default in docker-compose.yaml,
#   LATEST to the latest upstream release.
#
# Writes $OUT_DIR/body.md (OUT_DIR defaults to a temp dir) and prints
# `pinned=… latest=… changed=N out=DIR` on stdout. Needs gh, jq, diff.
set -euo pipefail

REPO=triggerdotdev/trigger.dev
DIR=hosting/docker
MAX_BODY=60000 # GitHub caps issue bodies at 65536 chars

pinned=${1:-$(sed -nE 's#.*ghcr\.io/triggerdotdev/trigger\.dev:\$\{TRIGGER_IMAGE_TAG:-([^}]+)\}.*#\1#p' docker-compose.yaml | head -1)}
latest=${2:-$(gh api "repos/$REPO/releases/latest" --jq .tag_name)}
[ -n "$pinned" ] && [ -n "$latest" ] || { echo "could not resolve pinned/latest tag" >&2; exit 1; }

out=${OUT_DIR:-$(mktemp -d)}
mkdir -p "$out"

# The monorepo's full recursive tree is truncated by the API, so list only the
# hosting/docker subtree. The compare API is no good either: it stops at 300 files.
blobs() {
  local tree
  tree=$(gh api "repos/$REPO/contents/$(dirname "$DIR")?ref=$1" \
    --jq ".[] | select(.path == \"$DIR\") | .sha")
  gh api "repos/$REPO/git/trees/$tree?recursive=1" \
    --jq '.tree[] | select(.type == "blob") | "\(.path) \(.sha)"' | sort
}
raw() {
  gh api "repos/$REPO/contents/$DIR/$2?ref=$1" -H "Accept: application/vnd.github.raw" 2>/dev/null || true
}

blobs "$pinned" >"$out/old.txt"
blobs "$latest" >"$out/new.txt"

# path -> status (modified / added / removed)
join -a1 -a2 -e MISSING -o 0,1.2,2.2 "$out/old.txt" "$out/new.txt" |
  awk '$2 != $3 { print $1, ($2 == "MISSING" ? "added" : ($3 == "MISSING" ? "removed" : "modified")) }' \
    >"$out/changed.txt"
changed=$(wc -l <"$out/changed.txt" | tr -d ' ')

{
  echo "<!-- upstream-drift range=$pinned...$latest -->"
  echo "## Upstream \`$DIR\` changed: \`$pinned\` → \`$latest\`"
  echo
  if [ "$changed" -eq 0 ]; then
    echo "No changes under \`$DIR\` — only the image tag needs bumping (Renovate's \`renovate/trigger.dev\` PR)."
  else
    echo "Port these upstream self-hosting changes into this Coolify template. Follow the Coolify parser"
    echo "rules in the header of \`docker-compose.yaml\` and \`CLAUDE.md\` — upstream's compose is not"
    echo "Coolify-shaped (ports, networks, restart, \`.env\` secrets vs \`SERVICE_*\` magic variables)."
    echo "Not everything applies: skip local-only tooling (\`generate-secrets.sh\`, Traefik example, publish IPs)."
    echo
    echo "| File | Change |"
    echo "|---|---|"
    while read -r path status; do echo "| \`$DIR/$path\` | $status |"; done <"$out/changed.txt"
    echo
    echo "Full diff: https://github.com/$REPO/compare/$pinned...$latest"
  fi
  echo
  echo "### Self-hosting notes from releases in range"
  echo
  gh api "repos/$REPO/releases?per_page=100" --jq '.[].tag_name' |
    grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
    { cat; echo "$pinned"; } | sort -uV |
    awk -v p="$pinned" -v l="$latest" '$0 == p { on = 1; next } on { print } $0 == l { exit }' |
    while read -r tag; do
      # The bullets under "These changes affect the self-hosted Docker image", plus
      # any other bullet naming an ENV_VAR or self-hosting.
      notes=$(gh api "repos/$REPO/releases/tags/$tag" --jq .body | awk '
        /affect the self-hosted Docker image/ { block = 1; next }
        block && /^- / { print; next }
        block && /^  / { next }
        { block = 0 }
        /^- / && (/[Ss]elf-host/ || /`[A-Z][A-Z0-9]*_[A-Z0-9_]+`/) { print }
      ' | awk '!seen[$0]++')
      if [ -n "$notes" ]; then
        printf '#### [%s](https://github.com/%s/releases/tag/%s)\n%s\n\n' "$tag" "$REPO" "$tag" "$notes"
      fi
    done
} >"$out/body.md"

if [ "$changed" -gt 0 ]; then
  {
    echo "### Diffs"
    echo
    while read -r path status; do
      echo "<details><summary><code>$DIR/$path</code> ($status)</summary>"
      echo
      echo '```diff'
      diff -u --label "$pinned/$path" --label "$latest/$path" \
        <(raw "$pinned" "$path") <(raw "$latest" "$path") || true
      echo '```'
      echo "</details>"
      echo
    done <"$out/changed.txt"
  } >"$out/diffs.md"

  if [ $(($(wc -c <"$out/body.md") + $(wc -c <"$out/diffs.md"))) -le $MAX_BODY ]; then
    cat "$out/diffs.md" >>"$out/body.md"
  else
    echo "_Diffs are too large for an issue body — use the compare link above._" >>"$out/body.md"
  fi
fi

echo "pinned=$pinned latest=$latest changed=$changed out=$out"
