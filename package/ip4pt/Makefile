include $(TOPDIR)/rules.mk

PKG_NAME:=ip4pt
PKG_VERSION:=1.0.0
PKG_RELEASE:=3
PKG_LICENSE:=GPL-2.0-or-later
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/ip4pt
  SECTION:=net
  CATEGORY:=Network
  TITLE:=IPv4 passthrough emulation via Ethernet MAC rewriting
  URL:=https://github.com/local/ip4pt
  # tcpdump:     full build (needs -e ARP verbose output for discovery parsing)
  # ebtables:    userspace tool for the per-client arpreply rules
  # kmod-ebtables-ipv4: provides the ebt_arpreply kernel target (README item 1;
  #              if it can't install on the target build, neither can we)
  # kmod-nft-bridge: bridge-family nftables for the MAC-rewrite table
  DEPENDS:=+tcpdump +ebtables +kmod-ebtables-ipv4 +kmod-nft-bridge
endef

define Package/ip4pt/description
  Emulates IPv4 passthrough on a cascaded, NAT-less second router via an
  intermediate OpenWrt device: rewrites Ethernet source/destination MACs on a
  bridge via an nftables map, answers ARP with clients' real MACs via ebtables
  arpreply, and learns bindings passively by watching a mirrored port.
  Per-device setup (br-ip4pt bridge, ROUTER2_MAC) stays manual -- see README.
endef

# Pure shell; nothing to prepare/configure/compile.
define Build/Prepare
endef
define Build/Configure
endef
define Build/Compile
endef

# conffile: survives package upgrades; state/ is kept across sysupgrade via
# the keep.d drop-in installed below.
define Package/ip4pt/conffiles
/etc/ip4pt/ip4pt.conf
endef

define Package/ip4pt/install
	$(INSTALL_DIR)  $(1)/usr/lib/ip4pt
	$(INSTALL_BIN)  $(CURDIR)/files/usr/lib/ip4pt/ip4pt-lib.sh      $(1)/usr/lib/ip4pt/
	$(INSTALL_BIN)  $(CURDIR)/files/usr/lib/ip4pt/ip4pt-discover.sh $(1)/usr/lib/ip4pt/
	$(INSTALL_BIN)  $(CURDIR)/files/usr/lib/ip4pt/ip4pt-gc.sh       $(1)/usr/lib/ip4pt/
	$(INSTALL_DATA) $(CURDIR)/files/usr/lib/ip4pt/10-ip4pt.nft.tmpl $(1)/usr/lib/ip4pt/

	$(INSTALL_DIR)  $(1)/usr/bin
	$(INSTALL_BIN)  $(CURDIR)/files/usr/bin/ip4pt-gen-nft $(1)/usr/bin/

	$(INSTALL_DIR)  $(1)/etc/ip4pt
	$(INSTALL_DATA) $(CURDIR)/files/etc/ip4pt/ip4pt.conf $(1)/etc/ip4pt/
	$(INSTALL_DIR)  $(1)/etc/init.d
	$(INSTALL_BIN)  $(CURDIR)/files/etc/init.d/ip4pt $(1)/etc/init.d/

	$(INSTALL_DIR)  $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) $(CURDIR)/files/lib/upgrade/keep.d/ip4pt $(1)/lib/upgrade/keep.d/
endef

$(eval $(call BuildPackage,ip4pt))
