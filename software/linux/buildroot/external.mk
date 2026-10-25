include $(sort $(wildcard $(BR2_EXTERNAL_ZCU104_PATH)/package/*/*.mk))

# Install on every U-Boot build/rebuild, including an existing configured cache.
define ZCU104_INSTALL_FMC_VADJ
	$(HOST_DIR)/bin/python3 $(BR2_EXTERNAL_ZCU104_PATH)/../uboot/install.py $(@D)
endef
UBOOT_PRE_BUILD_HOOKS += ZCU104_INSTALL_FMC_VADJ
define ZCU104_RECORD_FMC_VADJ
	$(HOST_DIR)/bin/python3 $(BR2_EXTERNAL_ZCU104_PATH)/../uboot/evidence.py record $(@D)
endef
UBOOT_POST_BUILD_HOOKS += ZCU104_RECORD_FMC_VADJ
