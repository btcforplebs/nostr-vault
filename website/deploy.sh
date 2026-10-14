#!/bin/sh
# Deploys nostrvault.app from this checkout: builds the site image (pages + web apps), tagged with the
# commit, and restarts it on :4024. Keeps the last 3 builds for rollback and prunes the rest.
#   ./deploy.sh                 build and deploy HEAD
#   ./deploy.sh <tag>           roll back to a kept build, no rebuild (tags: docker images nostrvault-website)
set -eu
cd "$(dirname "$0")"

if [ $# -gt 0 ]; then
  SITE_TAG=$1 docker compose up -d --no-build
  docker compose ps
  exit 0
fi

tag=$(git rev-parse --short=12 HEAD)
git diff --quiet HEAD -- .. || tag="$tag-dirty"
export SITE_TAG=$tag
docker compose build
docker compose up -d
docker compose ps

# Keep the 3 newest site builds (the one just deployed among them); drop older ones and old build cache.
docker images nostrvault-website --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}' | sort -r | tail -n +4 | cut -f2 \
  | xargs -r docker rmi 2>/dev/null || true
docker image prune -f --filter label=app.nostrvault.site=1 >/dev/null
docker builder prune -f --filter until=168h >/dev/null
