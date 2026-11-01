#!/bin/sh
# Turn the ImageBuilder rootfs tarball into a docker rootfs: kernel
# modules and firmware come from the host.
#   prepare-rootfs.sh <imagebuilder rootfs.tar.gz> <output rootfs.tar.gz>
set -eu

in="$1"
out="$2"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

tar -xzf "$in" -C "$tmp"

# not used in a container
rm -rf "${tmp:?}"/lib/firmware/* "${tmp:?}"/lib/modules/* "${tmp:?}"/boot
rm -f "${tmp:?}"/root/.todo_rootfs_resize

# hardware crypto engines are not available in a container
if [ -f "$tmp/etc/ssl/openssl.cnf" ]; then
	sed -i 's|^engines = engines_sect|#engines = engines_sect|' "$tmp/etc/ssl/openssl.cnf"
fi

tar -C "$tmp" --numeric-owner -czf "$out" .
