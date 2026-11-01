# openwrt-docker-arm64

ImmortalWrt for an arm64 Linux docker host, with OpenAppFilter working inside the container.

```
docker host (arm64)
 ├─ oaf.ko (OpenAppFilter, attached to the OpenWrt container's netns)
 └─ docker container "OpenWrt"
```

## Layout

| Path | Contents |
|---|---|
| `oaf-netns/` | OpenAppFilter patches: the kernel module can attach to the network namespace of a given pid (`netns_pid=`) and detaches itself when that namespace goes away; the `appfilter` init script no longer runs modprobe when the module is already attached; `luci-app-oaf` no longer depends on `kmod-oaf`. `UPSTREAM_COMMIT` is the upstream commit the patches apply to. |
| `host/` | For the docker host: `oaf-netns-load.sh` loads the module and creates `/dev/fwx` inside the container; `oaf-netns-watch.sh` + `oaf-netns.service` reload it every time the container starts. |
| `.github/workflows/oaf-kmod.yml` | Builds `oaf.ko` against the host kernel's headers with the compiler the kernel was built with. The kernel is given by repository secrets (see the workflow). |
| `openwrt/packages.txt` | Packages in the image. |
| `openwrt/sources.txt` | Packages not in the ImmortalWrt feeds, built with the SDK from pinned commits. |
| `openwrt/files/` | Files added to the rootfs. |
| `docker/` | Dockerfile and the script that strips the rootfs for docker (no kernel modules or firmware). |
| `.github/workflows/openwrt-image.yml` | SDK build of `openwrt/sources.txt` (with the `oaf-netns/` patches) → ImageBuilder rootfs → `ghcr.io/<owner>/<repo>`. |

## OpenWrt image

ImmortalWrt 25.12.2, `linux/arm64`. Tags: `latest`, `25.12.2`, `25.12.2-<date>-<commit>`.

```sh
docker run -d --name OpenWrt --restart always --privileged --network <network> ghcr.io/<owner>/<repo>:latest
```

Kernel modules used by OpenWrt packages (tun, nft_tproxy, nft_socket, ...) have to be loaded on the host.

## oaf.ko

Set the secrets listed in `oaf-kmod.yml`, then run the workflow. The module is in the run's artifacts.
**Rebuild after every host kernel upgrade**; a module built for another kernel will not load.

Install on the host:

```sh
install -Dm644 oaf.ko /lib/modules/$(uname -r)/extra/oaf.ko
install -Dm755 -t /usr/local/lib/oaf-netns host/oaf-netns-load.sh host/oaf-netns-watch.sh
/usr/local/lib/oaf-netns/oaf-netns-load.sh            # try it by hand first
install -Dm644 host/oaf-netns.service /etc/systemd/system/oaf-netns.service
systemctl daemon-reload && systemctl enable --now oaf-netns
```

## Recreating the GitHub repository

This directory is a complete copy:

```sh
gh repo create <name> --public --source . --push
```
