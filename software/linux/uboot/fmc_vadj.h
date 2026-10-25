/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef ZCU104_FMC_VADJ_H
#define ZCU104_FMC_VADJ_H
#include <stddef.h>

/* Only the platform adapter knows the physical bus/address. */
struct fmc_io {
	void *ctx;
	int (*read)(void *ctx, unsigned char reg, unsigned char *data, int len);
	int (*write)(void *ctx, unsigned char reg, const unsigned char *data, int len);
	void (*delay_ms)(unsigned int ms);
};

int fmc_fru_valid(const unsigned char *fru, size_t len);
/* Call only before PL configuration; never use this for live recovery. */
int fmc_vadj_init(const struct fmc_io *io, const unsigned char *fru, size_t len,
		  unsigned int *millivolts);
#endif
