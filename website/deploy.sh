#!/bin/sh
# Deploys nostrvault.app from this checkout: builds the site image (pages + web apps) and restarts it on :4024.
set -eu
cd "$(dirname "$0")"
docker compose up -d --build
docker compose ps
