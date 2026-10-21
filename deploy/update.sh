#!/bin/sh
# Brings this host up to date with main: follows changes to the compose file and
# this script, pulls the images GitHub Actions published, and restarts what
# changed. A run that finds nothing new exits without touching anything.
#
# The maailma-update timer runs it; deploy/install-updater.sh sets that up.
set -eu
cd "$(dirname "$0")"

grep -q '^IMAGE_PREFIX=.' .env || {
  echo 'Set IMAGE_PREFIX in deploy/.env, or there are no published images to pull.' >&2
  exit 1
}

# The checked-out commit and the local image of every service.
state() {
  git rev-parse HEAD
  docker compose config --images | xargs docker image inspect -f '{{.Id}}' 2>/dev/null || true
}

before=$(state)

# --ff-only stops rather than discarding edits made directly on this host.
git fetch -q origin main
git merge -q --ff-only origin/main

# Postgres is left alone so its image changes only when you choose to update it.
docker compose pull -q migrate server

if [ "$(state)" = "$before" ] && [ -n "$(docker compose ps -q --status running server)" ]; then
  exit 0
fi

echo "Deploying $(git rev-parse --short HEAD)"
# Runs the migration first; a failed one stops here, leaving the old server up.
docker compose up -d --no-build --remove-orphans

server=$(docker compose ps -q server)
for _ in $(seq 60); do
  case $(docker inspect -f '{{.State.Health.Status}}' "$server") in
    healthy)
      docker image prune -f > /dev/null
      echo 'Server is healthy.'
      exit 0
      ;;
    unhealthy) break ;;
  esac
  sleep 5
done

echo 'Server did not become healthy; see: docker compose logs server' >&2
exit 1
