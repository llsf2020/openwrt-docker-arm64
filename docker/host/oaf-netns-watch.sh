#!/bin/sh
# Keep oaf.ko attached to the OpenWrt container: load it now (if the container
# is up) and again every time the container starts. Run by oaf-netns.service.
set -u

CONTAINER="${OAF_CONTAINER:-OpenWrt}"
LOAD="$(dirname "$0")/oaf-netns-load.sh"

"$LOAD" || true

docker events --filter "container=$CONTAINER" --filter event=start --format '{{.Status}}' |
while read -r _; do
	# give procd inside the container a moment to bring up the network
	sleep 5
	"$LOAD" || true
done
