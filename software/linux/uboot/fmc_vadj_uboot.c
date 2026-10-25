// SPDX-License-Identifier: GPL-2.0-only
#include <common.h>
#include <dm.h>
#include <dm/uclass.h>
#include <env.h>
#include <i2c.h>
#include <zynqmp_firmware.h>
#include <asm/arch/sys_proto.h>
#include <asm/global_data.h>
#include <linux/delay.h>
#include "fmc_vadj.h"

DECLARE_GLOBAL_DATA_PTR;
#define I2C_ROOT "/axi/i2c@ff030000"
#define FMC_BUS I2C_ROOT "/i2c-mux@74/i2c@5"
#define POWER_BUS I2C_ROOT "/i2c-mux@74/i2c@2"

static int get_chip(const char *path, unsigned int address, struct udevice **chip)
{
	struct udevice *bus;
	int ret = uclass_get_device_by_of_path(UCLASS_I2C, path, &bus);
	return ret ? ret : i2c_get_chip(bus, address, 1, chip);
}

static int read_reg(void *ctx, unsigned char reg, unsigned char *data, int len)
{
	return dm_i2c_read(ctx, reg, data, len);
}

static int write_reg(void *ctx, unsigned char reg, const unsigned char *data, int len)
{
	return dm_i2c_write(ctx, reg, data, len);
}

static void wait_ms(unsigned int ms)
{
	mdelay(ms);
}

void zcu104_fmc_vadj_init(void)
{
	struct udevice *gpio, *eeprom, *power;
	unsigned char present, config, fru[256];
	unsigned int mv = 0;
	u32 payload[PAYLOAD_ARG_CNT];
	struct fmc_io io = { .read = read_reg, .write = write_reg, .delay_ms = wait_ms };
	int ret;

	if (fdt_node_check_compatible(gd->fdt_blob, 0, "xlnx,zynqmp-zcu104-revC"))
		return;
	env_set("fmc_vadj_ready", "0");
	/* Do not change a supply used by an already configured PL. */
	ret = xilinx_pm_request(PM_FPGA_GET_STATUS, 0, 0, 0, 0, payload);
	if (ret || (payload[1] & 0x40002008)) {
		puts("FMC VADJ: skipped (PL configured or status unavailable)\n");
		return;
	}
	ret = get_chip(I2C_ROOT, 0x20, &gpio);
	if (ret || dm_i2c_read(gpio, 6, &config, 1) || !(config & 0x80) ||
	    dm_i2c_read(gpio, 0, &present, 1))
		goto fail;
	if (present & 0x80) {
		puts("FMC VADJ: no card present; no power changes\n");
		return;
	}
	ret = get_chip(FMC_BUS, 0x50, &eeprom);
	if (ret || dm_i2c_read(eeprom, 0, fru, sizeof(fru)) || fmc_fru_valid(fru, sizeof(fru))) {
		puts("FMC VADJ: invalid/unsupported OP047 FRU; no power changes\n");
		return;
	}
	ret = get_chip(POWER_BUS, 0x44, &power);
	if (ret)
		goto fail;
	io.ctx = power;
	if (fmc_vadj_init(&io, fru, sizeof(fru), &mv))
		goto fail;
	env_set("fmc_vadj_ready", "1");
	printf("FMC VADJ: OP047 1.8V ready, telemetry %u mV; measure TP3 before PL use\n", mv);
	return;
fail:
	printf("FMC VADJ: FAILED (%u mV); do not load PL; inspect power\n", mv);
}
