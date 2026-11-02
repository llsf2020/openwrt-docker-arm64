# Firmware for the Phicomm N1

ImmortalWrt 25.12.2 with kernel 6.12.115-ophub, installed directly on the box. Images are published as releases named `native-<version>-<date>-<commit>`.

| Path | Contents |
|---|---|
| `packages.txt` | Packages in the firmware. |
| `sources.txt` | Packages not in the ImmortalWrt feeds, built with the SDK from pinned commits. |
| `patches/` | OpenAppFilter patch: `luci-app-oaf` no longer depends on `kmod-oaf`, because `oaf.ko` is built against the firmware's kernel and added to the image. |
| `files/` | Files added to the rootfs. |
| `../.github/workflows/native-firmware.yml` | SDK packages + `oaf.ko` → ImageBuilder rootfs → image from [ophub/amlogic-s9xxx-openwrt](https://github.com/ophub/amlogic-s9xxx-openwrt). |

## First boot

- LAN: `192.168.1.1/24`, DHCP and IPv6 announcements off. Give the computer a static address such as `192.168.1.2/24`.
- Set a root password straight away, then set the LAN address, gateway and DNS for your network.
- To use it as the network's main router, turn DHCP back on (`dhcp.lan.ignore`, `ra`, `dhcpv6`, `ndp`) and run `/etc/init.d/odhcpd enable`.
- `frpc`, `frps` and `haproxy` are installed but disabled.

## Trying it and installing it

Write the image to a USB drive and boot from it; the system on the eMMC is not touched. Once it works, `openwrt-install-amlogic` writes it to the eMMC and replaces the system there, so back that up first.

## Update buttons that replace this firmware

- `luci-app-amlogic` (System → Amlogic Service) can download another kernel or firmware. A new kernel stops `oaf.ko` from loading, and its default firmware source is ophub's, which has a different package set.
- `luci-app-attendedsysupgrade` asks a public build server for a generic image, which is not built for this box. Do not use it to upgrade.

To update, build new firmware here and flash it.

## Kernel

Kernel modules come with the firmware's kernel, so kernel module packages from the online feeds will not load. Add what you need to `packages.txt` or to the kernel and build again. `oaf.ko` only loads on the kernel it was built for: do not change the kernel on an installed system.
