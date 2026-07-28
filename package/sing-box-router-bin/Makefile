include $(TOPDIR)/rules.mk

PKG_NAME:=sing-box-router-bin
PKG_VERSION:=1.13.11
PKG_RELEASE:=1

SING_BOX_ARCHIVE:=sing-box-$(PKG_VERSION)-linux-arm64-musl
PKG_SOURCE:=$(SING_BOX_ARCHIVE).tar.gz
PKG_SOURCE_URL:=https://github.com/SagerNet/sing-box/releases/download/v$(PKG_VERSION)
PKG_HASH:=da8380fc3387a0a431cda259acd90098d988d7e679c780f0ecef3ced7534216c
PKG_BUILD_DIR:=$(BUILD_DIR)/$(SING_BOX_ARCHIVE)

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/sing-box-router-bin
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Pinned sing-box binary for the personal router stack
  URL:=https://sing-box.sagernet.org/
  DEPENDS:=@aarch64 +ca-bundle +kmod-tun
endef

define Package/sing-box-router-bin/description
 Installs the pinned upstream arm64-musl sing-box release at the path used by
 this repository. It deliberately does not install configuration or manage
 services.
endef

define Build/Compile
endef

define Package/sing-box-router-bin/install
	$(INSTALL_DIR) $(1)/usr/local/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/sing-box $(1)/usr/local/bin/sing-box
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/99-sing-box-router-bin-persistence \
		$(1)/etc/uci-defaults/99-sing-box-router-bin-persistence
endef

define Package/sing-box-router-bin/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/uci-defaults/99-sing-box-router-bin-persistence
	rm -f /etc/uci-defaults/99-sing-box-router-bin-persistence
}
exit 0
endef

$(eval $(call BuildPackage,sing-box-router-bin))
