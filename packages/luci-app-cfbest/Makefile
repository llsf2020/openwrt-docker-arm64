include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-cfbest
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only

LUCI_TITLE:=Cloudflare IP selection for proxy nodes
LUCI_DESCRIPTION:=Selects the fastest Cloudflare IP for CDN-fronted nodes of PassWall, PassWall2, HomeProxy, SSR-Plus, OpenClash and momo, and selects again when it gets slow.
LUCI_DEPENDS:=+cfst +curl +ucode +ucode-mod-fs +ucode-mod-uci +nftables
LUCI_PKGARCH:=all

define Package/luci-app-cfbest/conffiles
/etc/config/cfbest
endef

define Package/luci-app-cfbest/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/cfbest stop
	/etc/init.d/cfbest disable
	nft delete table inet cfbest 2>/dev/null
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
