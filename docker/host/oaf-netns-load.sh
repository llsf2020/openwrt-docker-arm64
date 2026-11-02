#!/bin/sh
# Load oaf.ko on the docker host and attach it to the network namespace of
# the OpenWrt docker container. Safe to run again after the container restarts.
#
#   oaf-netns-load.sh            load / reload
#   oaf-netns-load.sh unload     rmmod only
set -eu

CONTAINER="${OAF_CONTAINER:-OpenWrt}"
KO="${OAF_KO:-/lib/modules/$(uname -r)/extra/oaf.ko}"

log() { echo "oaf-netns: $*"; logger -t oaf-netns "$*" 2>/dev/null || true; }

unload() {
	if grep -q '^oaf ' /proc/modules; then
		rmmod oaf
		log "unloaded"
	fi
}

[ "${1:-}" = unload ] && { unload; exit 0; }

[ -f "$KO" ] || { log "missing $KO"; exit 1; }

pid="$(docker inspect -f '{{if .State.Running}}{{.State.Pid}}{{end}}' "$CONTAINER" 2>/dev/null || true)"
[ -n "$pid" ] && [ "$pid" != 0 ] || { log "container $CONTAINER not running"; exit 1; }

# dependencies of oaf.ko (nf_send_reset etc.)
modprobe nf_conntrack
modprobe nf_reject_ipv4

unload
insmod "$KO" netns_pid="$pid"
log "loaded, netns of $CONTAINER (pid $pid)"

# the container's /dev was populated when it started; create the char device
major="$(awk '$2 == "fwx" { print $1 }' /proc/devices)"
[ -n "$major" ] || { log "fwx char device not registered"; exit 1; }
docker exec "$CONTAINER" sh -c "rm -f /dev/fwx && mknod /dev/fwx c $major 0"

docker exec "$CONTAINER" sh -c 'test -e /proc/net/af_client' \
	|| { log "/proc/net/af_client not visible in container"; exit 1; }

# (re)start the OpenWrt side if it is installed
docker exec "$CONTAINER" sh -c '[ -x /etc/init.d/appfilter ] && /etc/init.d/appfilter restart || true'
log "ready"
