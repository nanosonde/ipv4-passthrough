include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ip4pt
PKG_VERSION:=1.0.0
PKG_RELEASE:=8
PKG_LICENSE:=GPL-2.0-or-later
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-ip4pt
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI status page for ip4pt (IPv4 passthrough emulation)
  # +ip4pt:  the status helper sources the same ip4pt-lib.sh the daemons do
  #          (STATE_DIR / thresholds / arpreply_present) and reads its state.
  # +luci-base: serves the menu.d/acl.d JSON and the JS view natively.
  DEPENDS:=+ip4pt +luci-base
endef

define Package/luci-app-ip4pt/description
  Optional read-only LuCI page for ip4pt (Status -> IPv4 Passthrough):
  lists every handled host with its DHCP hostname (when the client sent
  one), IP + MAC, its online/suspended state and the countdowns to both
  GC tiers (OFFLINE_SECS suspension, STALE_SECS removal). All data comes
  from /usr/libexec/ip4pt-status, which derives everything from ip4pt's
  own state files + ebtables listing -- nothing is stored a second time.
  A per-row Remove button deprovisions a binding via
  /usr/libexec/ip4pt-remove (the GC's own removal path), and a
  Remove-all-suspended button clears every suspended binding at once;
  removed hosts are re-learned from their next ARP.
endef

# Pure shell + static JSON/JS payloads; nothing to prepare/configure/compile.
define Build/Prepare
endef
define Build/Configure
endef
define Build/Compile
endef

define Package/luci-app-ip4pt/install
	$(INSTALL_DIR)  $(1)/usr/libexec
	$(INSTALL_BIN)  $(CURDIR)/root/usr/libexec/ip4pt-status $(1)/usr/libexec/
	$(INSTALL_BIN)  $(CURDIR)/root/usr/libexec/ip4pt-remove $(1)/usr/libexec/

	$(INSTALL_DIR)  $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) $(CURDIR)/root/usr/share/luci/menu.d/luci-app-ip4pt.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR)  $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(CURDIR)/root/usr/share/rpcd/acl.d/luci-app-ip4pt.json $(1)/usr/share/rpcd/acl.d/

	$(INSTALL_DIR)  $(1)/www/luci-static/resources/view/ip4pt
	$(INSTALL_DATA) $(CURDIR)/htdocs/luci-static/resources/view/ip4pt/status.js $(1)/www/luci-static/resources/view/ip4pt/
endef

$(eval $(call BuildPackage,luci-app-ip4pt))