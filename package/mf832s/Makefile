include $(TOPDIR)/rules.mk

PKG_NAME:=mf832s
PKG_VERSION:=1.0.0
PKG_RELEASE:=4
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/mf832s
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=ZTE MF832S AT activation and USB Ethernet monitor
  URL:=https://github.com/rayniel/mf832s-openwrt
  DEPENDS:=+busybox +chat +coreutils-stty +flock +netifd +uci +ubus +procd +jsonfilter
endef

define Package/mf832s/description
  Supervised AT activation for a single ZTE MF832S, with DHCP managed by
  netifd. Auto-starts only when a matching modem is detected; otherwise exits
  quietly. Install the USB serial and network drivers matching your hardware
  separately; no PPP, QMI or LuCI stack is required.
endef

define Package/mf832s/conffiles
/etc/config/mf832s
endef

define Build/Prepare
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./../../LICENSE $(PKG_BUILD_DIR)/LICENSE
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/mf832s/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_DATA) ./files/mf832s.config $(1)/etc/config/mf832s
	$(INSTALL_BIN) ./files/mf832s.init $(1)/etc/init.d/mf832s
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/mf832s-monitor $(1)/usr/sbin/mf832s-monitor
	$(INSTALL_BIN) ./files/mf832s-status $(1)/usr/sbin/mf832s-status
	$(INSTALL_DIR) $(1)/etc/hotplug.d/usb $(1)/etc/hotplug.d/net $(1)/etc/hotplug.d/iface
	$(INSTALL_DATA) ./files/20-mf832s $(1)/etc/hotplug.d/usb/20-mf832s
	$(INSTALL_DATA) ./files/20-mf832s-net $(1)/etc/hotplug.d/net/20-mf832s
	$(INSTALL_DATA) ./files/20-mf832s-iface $(1)/etc/hotplug.d/iface/20-mf832s
endef

$(eval $(call BuildPackage,mf832s))
