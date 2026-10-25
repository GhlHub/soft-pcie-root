ZCU104_TOOLS_VERSION = 1
ZCU104_TOOLS_SITE = $(BR2_EXTERNAL_ZCU104_PATH)/../../tools
ZCU104_TOOLS_SITE_METHOD = local
# Original project source; no upstream code imported into this tool.
ZCU104_TOOLS_LICENSE = Apache-2.0
ZCU104_TOOLS_LICENSE_FILES = COPYING

define ZCU104_TOOLS_BUILD_CMDS
 $(TARGET_CC) $(TARGET_CFLAGS) -std=c11 -Wall -Wextra -Werror -o $(@D)/pcie-rootctl $(@D)/pcie-rootctl.c $(TARGET_LDFLAGS)
endef

define ZCU104_TOOLS_INSTALL_TARGET_CMDS
 $(INSTALL) -D -m 0755 $(@D)/pcie-rootctl $(TARGET_DIR)/usr/sbin/pcie-rootctl
endef
$(eval $(generic-package))
