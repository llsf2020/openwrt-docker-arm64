# openwrt-docker-arm64

ImmortalWrt for arm64, in two separate builds:

| Folder | What it builds | Published as |
|---|---|---|
| `docker/` | Container for an arm64 Linux docker host, with OpenAppFilter working inside the container | `ghcr.io/<owner>/<repo>` |
| `native/` | Firmware for the Phicomm N1, installed directly on the box. See [native/README.md](native/README.md) | Releases |
| `packages/` | `luci-app-cfbest` (Cloudflare IP selection for proxy nodes), `cfst`, and the third-party packages in `packages/sources.txt`, built on their own by `extra-packages.yml` as ipk (24.10) and apk (25.12) | Releases `packages-*` |

## Layout of `docker/`

```
docker host (arm64)
 ├─ oaf.ko (OpenAppFilter, attached to the OpenWrt container's netns)
 └─ docker container "OpenWrt"
```

| Path | Contents |
|---|---|
| `docker/oaf-netns/` | OpenAppFilter patches: the kernel module can attach to the network namespace of a given pid (`netns_pid=`) and detaches itself when that namespace goes away; the `appfilter` init script no longer runs modprobe when the module is already attached; `luci-app-oaf` no longer depends on `kmod-oaf`. `UPSTREAM_COMMIT` is the upstream commit the patches apply to. |
| `docker/host/` | For the docker host: `oaf-netns-load.sh` loads the module and creates `/dev/fwx` inside the container; `oaf-netns-watch.sh` + `oaf-netns.service` reload it every time the container starts. |
| `docker/packages.txt` | Packages in the image. |
| `docker/sources.txt` | Packages not in the ImmortalWrt feeds, built with the SDK from pinned commits. |
| `docker/files/` | Files added to the rootfs. |
| `docker/Dockerfile`, `docker/prepare-rootfs.sh` | Dockerfile and the script that strips the rootfs for docker (no kernel modules or firmware). |
| `.github/workflows/docker-image.yml` | SDK build of `docker/sources.txt` (with the `docker/oaf-netns/` patches) → ImageBuilder rootfs → `ghcr.io/<owner>/<repo>`. |
| `.github/workflows/docker-oaf-kmod.yml` | Builds `oaf.ko` against the host kernel's headers with the compiler the kernel was built with. The kernel is given by repository secrets (see the workflow). |

## Versions and automatic updates

`versions.env` holds every version the builds use: the ImmortalWrt release and its SDK and ImageBuilder, a hash of the feed indexes, the kernel for the N1 firmware and the toolchain it was built with, the packager commit and AdGuard Home, each with its sha256.

`auto-update.yml` runs every three days. `scripts/update-versions.sh` moves `versions.env` to the newest point release of `IMMORTALWRT_BRANCH` and the newest kernel of `KERNEL_BRANCH`, and the sources in `docker/sources.txt` and `native/sources.txt` to their newest commits (a source stays where it is when our patches no longer apply; an issue says so). The workflow commits the result and starts `docker-image.yml` and `native-firmware.yml` for whatever has not been built yet; when nothing changed, nothing is built.

A newer ImmortalWrt branch or kernel branch is not used on its own. It goes to `versions-next.env`, is built as a test (pre-release `test-native-*`, image tag `test-*`) and reported in an issue. To switch, change `IMMORTALWRT_BRANCH` or `KERNEL_BRANCH` in `versions.env`.

The firmware workflow keeps the 5 newest releases (2 test releases); the image workflow keeps the 6 newest images plus `latest` and the release tags.

## Docker image

ImmortalWrt (the release in `versions.env`), `linux/arm64`. Tags: `latest`, `<release>`, `<release>-<date>-<commit>`.

On first boot the LAN is `192.168.1.1/24` with DHCP and router advertisements on, and root has no password. **Configure it on an isolated network before connecting it to an existing LAN**, or it will hand out addresses there:

```sh
docker network create --internal setup
docker run -d --name OpenWrt --restart always --privileged --network setup ghcr.io/<owner>/<repo>:latest
docker exec -it OpenWrt sh
# set network.lan.ipaddr, netmask, gateway and dns with uci
# set dhcp.lan.ignore=1 and dhcp.lan.ra, dhcpv6, ndp to disabled, then uci commit
# /etc/init.d/odhcpd disable, set a root password, restart network and dnsmasq
# netstat -lnup | grep -E ':67 |:547 ' must print nothing
docker network disconnect setup OpenWrt
docker network connect --ip <address> <network> OpenWrt
docker restart OpenWrt    # the interface is eth1 until the container restarts
```

Kernel modules used by OpenWrt packages (tun, nft_tproxy, nft_socket, ...) have to be loaded on the host.

## oaf.ko (docker)

Set the secrets listed in `docker-oaf-kmod.yml`, then run the workflow. The module is in the run's artifacts.
**Rebuild after every host kernel upgrade**; a module built for another kernel will not load.

Install on the host:

```sh
install -Dm644 oaf.ko /lib/modules/$(uname -r)/extra/oaf.ko
install -Dm755 -t /usr/local/lib/oaf-netns docker/host/oaf-netns-load.sh docker/host/oaf-netns-watch.sh
/usr/local/lib/oaf-netns/oaf-netns-load.sh            # try it by hand first
install -Dm644 docker/host/oaf-netns.service /etc/systemd/system/oaf-netns.service
systemctl daemon-reload && systemctl enable --now oaf-netns
```

## Recreating the GitHub repository

This directory is a complete copy:

```sh
gh repo create <name> --public --source . --push
```
