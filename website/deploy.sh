#!/bin/sh
# Deploys nostrvault.app from this checkout: builds the site image (pages + web apps), tagged with the
# commit, and restarts it on :4024 with the thread service (public post pages) beside it. Keeps the last 3 builds
# for rollback and prunes the rest. Then ./check-live.sh checks the new container; if it fails, deploy.sh stops with
# exit 1 before pruning, naming the build to roll back to. Last, ./publish-nsite.sh publishes the same files as the
# nsite (NSITE=0 skips it).
#   ./deploy.sh                 build and deploy HEAD
#   ./deploy.sh <tag>           roll back to a kept build, no rebuild (tags: docker images nostrvault-website)
set -eu
cd "$(dirname "$0")"

# The build running now, to roll back to if the new one fails its check.
running=$(docker compose ps -q website 2>/dev/null | head -n 1)
prev=$([ -n "$running" ] && docker inspect --format '{{.Config.Image}}' "$running" | sed 's/^.*://' || true)
check() {
  ./check-live.sh http://localhost:4024 && return 0
  echo "deploy.sh: CHECK FAILED, the site is serving a broken build. Roll back: ./deploy.sh ${prev:-<tag>}" >&2
  echo "deploy.sh: kept builds: $(docker images nostrvault-website --format '{{.Tag}}' | tr '\n' ' ')" >&2
  exit 1
}
nsite() {
  [ "${NSITE:-1}" = 0 ] && { echo "deploy.sh: NSITE=0, the nsite was not published"; return 0; }
  ./publish-nsite.sh && return 0
  echo "deploy.sh: the site is live, but the nsite copy did NOT publish and still serves the previous release. Re-run ./publish-nsite.sh" >&2
  exit 1
}

if [ $# -gt 0 ]; then
  SITE_TAG=$1 docker compose up -d --no-build
  docker compose ps
  # A build older than a check (e.g. from before /v3/ redirected) fails that check: read the FAIL lines.
  ./check-live.sh http://localhost:4024 || { echo "deploy.sh: rolled back to $1, and it FAILS check-live (above)" >&2; exit 1; }
  nsite
  exit 0
fi

tag=$(git rev-parse --short=12 HEAD)
git diff --quiet HEAD -- .. || tag="$tag-dirty"
export SITE_TAG=$tag
docker compose build
docker compose up -d
docker compose ps
check

# Keep the 3 newest site builds (the one just deployed among them); drop older ones and old build cache.
for repo in nostrvault-website nostrvault-thread; do
  docker images $repo --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}' | sort -r | tail -n +4 | cut -f2 \
    | xargs -r docker rmi 2>/dev/null || true
done
docker image prune -f --filter label=app.nostrvault.site=1 >/dev/null
docker builder prune -f --filter until=168h >/dev/null
nsite
