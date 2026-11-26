#!/usr/bin/env bash
# Deploy the static site to Cloudflare Pages (project: indexhot) via wrangler.
#
# Usage:  ./scripts/deploy-cloudflare.sh
#
# Token: reads CLOUDFLARE_API_TOKEN from the environment, or falls back to
# ~/.cf_token (chmod 600). The token must never be committed to the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${CF_PAGES_PROJECT:-indexhot}"
ACCOUNT="${CLOUDFLARE_ACCOUNT_ID:-21799924405145891bce7a351db58259}"

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] && [ -f "$HOME/.cf_token" ]; then
  CLOUDFLARE_API_TOKEN="$(cat "$HOME/.cf_token")"
fi
: "${CLOUDFLARE_API_TOKEN:?missing token: export CLOUDFLARE_API_TOKEN or write it to ~/.cf_token}"
export CLOUDFLARE_API_TOKEN

# wrangler lives outside the default PATH on some hosts
export PATH="$PATH:$HOME/.npm-global/bin:/usr/local/bin"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Stage only what the public site needs: html, css, robots, sitemap, 404.
( cd "$ROOT" && tar -cf - \
    --exclude='*.zip' \
    --exclude='.git' \
    --exclude='scripts' \
    --exclude='tailwind.config.js' \
    --exclude='tailwind.input.css' \
    --exclude='.git' \
    --exclude='.tmp-tool-results' \
    --exclude='.DS_Store' \
    . ) | ( cd "$STAGE" && tar -xf - )

# Generate _redirects (bare path -> trailing slash) and _headers from the tree.
python3 - "$STAGE" <<'PY'
import glob, os, sys

stage = sys.argv[1]
dirs = []
for p in glob.glob(os.path.join(stage, "**", "index.html"), recursive=True):
    rel = os.path.relpath(p, stage).replace(os.sep, "/")[:-len("index.html")].rstrip("/")
    if rel:
        dirs.append("/" + rel)

open(os.path.join(stage, "_redirects"), "w").write(
    "\n".join(f"{d}  {d}/  301" for d in sorted(dirs)) + "\n"
)
open(os.path.join(stage, "_headers"), "w").write(
    "/*\n"
    "  X-Content-Type-Options: nosniff\n"
    "  X-Frame-Options: SAMEORIGIN\n"
    "  Referrer-Policy: strict-origin-when-cross-origin\n"
    "\n"
    "/*.css\n"
    "  Cache-Control: public, max-age=600\n"
)
print(f"[stage] {len(dirs)} directories, {len(dirs) + 1} pages")
PY

export CLOUDFLARE_ACCOUNT_ID="$ACCOUNT"

if command -v wrangler >/dev/null 2>&1; then
  wrangler pages deploy "$STAGE" --project-name="$PROJECT" --branch=main --commit-dirty=true
else
  npx --yes wrangler@4 pages deploy "$STAGE" --project-name="$PROJECT" --branch=main --commit-dirty=true
fi
