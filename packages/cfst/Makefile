include $(TOPDIR)/rules.mk

PKG_NAME:=cfst
PKG_VERSION:=2.3.5
PKG_RELEASE:=1

ifeq ($(ARCH),aarch64)
  CFST_ARCH:=arm64
  PKG_HASH:=0ac992fcf24d4684caed33620deb9b83ce82f32d2418dc1f90be490ce5900300
else ifeq ($(ARCH),x86_64)
  CFST_ARCH:=amd64
  PKG_HASH:=c4c8fc76b4e1bf2bdb5ced8b765956d82dda7bc4eb59df5c04053f0f7db98d90
endif

PKG_SOURCE:=cfst_linux_$(CFST_ARCH).tar.gz
PKG_SOURCE_URL:=https://github.com/XIU2/CloudflareSpeedTest/releases/download/v$(PKG_VERSION)/
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=

include $(INCLUDE_DIR)/package.mk

define Package/cfst
  SECTION:=net
  CATEGORY:=Network
  TITLE:=CloudflareSpeedTest (prebuilt release binary)
  URL:=https://github.com/XIU2/CloudflareSpeedTest
  DEPENDS:=@(aarch64||x86_64)
endef

define Package/cfst/description
  Measures latency to Cloudflare IPs. Prebuilt binary from the upstream release.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(TAR) -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR) --strip-components=1
endef

define Build/Compile
endef

define Package/cfst/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/share/cfst
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/cfst $(1)/usr/bin/cfst
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/ip.txt $(1)/usr/share/cfst/ip.txt
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/ipv6.txt $(1)/usr/share/cfst/ipv6.txt
endef

$(eval $(call BuildPackage,cfst))
