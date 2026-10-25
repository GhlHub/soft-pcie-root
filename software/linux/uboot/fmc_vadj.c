/* SPDX-License-Identifier: GPL-2.0-only */
/* ZCU104/OP047 policy; no NVM writes, global reset or other regulator pages. */
#include "fmc_vadj.h"

static unsigned int word(const unsigned char *p)
{
	return p[0] | ((unsigned int)p[1] << 8);
}

static unsigned char sum(const unsigned char *p, size_t n)
{
	unsigned char s = 0;
	while (n--)
		s += *p++;
	return s;
}

int fmc_fru_valid(const unsigned char *f, size_t n)
{
	size_t off, end, p;
	unsigned int fields = 0, vadj = 0;
	int op047 = 0;

	if (n < 8 || f[0] != 1 || f[6] || sum(f, 8) || !f[3] || !f[5])
		return -1;
	/* Validate board area and the exact part-number field, not a substring. */
	off = f[3] * 8U;
	if (off < 8 || off + 8 > n || f[off] != 1)
		return -1;
	end = off + f[off + 1] * 8U;
	if (end <= off + 6 || end > n || sum(f + off, end - off))
		return -1;
	for (p = off + 6; p < end - 1 && f[p] != 0xc1;) {
		unsigned char type = f[p++];
		size_t len = type & 0x3f;
		if (p + len > end - 1)
			return -1;
		if (fields == 3 && type == 0xc5 && f[p] == 'O' &&
		    f[p+1] == 'P' && f[p+2] == '0' && f[p+3] == '4' && f[p+4] == '7')
			op047 = 1;
		fields++;
		p += len;
	}
	if (!op047 || fields < 5 || p >= end - 1 || f[p] != 0xc1)
		return -1;
	off = f[5] * 8U;
	if (off < end)
		return -1;
	/* Validate every multirecord through end-of-list, including checksums. */
	while (off + 5 <= n) {
		const unsigned char *h = f + off, *d = h + 5;
		unsigned int len = h[2];
		if ((h[1] & 0x7f) != 2 || sum(h, 5) || off + 5 + len > n ||
		    (unsigned char)(sum(d, len) + h[3]))
			return -1;
		if (h[0] == 2) {
			if (len != 13)
				return -1;
			if ((d[0] & 0xf) == 0) {
				unsigned int nominal = word(d+1), low = word(d+3), high = word(d+5);
				if (vadj++ || low > nominal || nominal > high || low > 180 || high < 180)
					return -1;
			}
		}
		if (h[1] & 0x80)
			return vadj == 1 ? 0 : -1;
		off += 5 + len;
	}
	return -1;
}

static int rd(const struct fmc_io *io, unsigned char reg, int len, unsigned int *v)
{
	unsigned char b[2] = {0, 0};
	if (io->read(io->ctx, reg, b, len))
		return -1;
	*v = word(b);
	return 0;
}

/* Verify the selected page before every write, including failure cleanup. */
static int wr(const struct fmc_io *io, unsigned char reg, int len, unsigned int v)
{
	unsigned char b[2] = {v & 0xff, v >> 8};
	unsigned int page, got;
	if (rd(io, 0, 1, &page) || page != 3 || io->write(io->ctx, reg, b, len) ||
	    rd(io, reg, len, &got) || got != v)
		return -1;
	return 0;
}

static int voltage(const struct fmc_io *io, unsigned int shift, unsigned int *mv)
{
	unsigned int raw;
	if (rd(io, 0x8b, 2, &raw))
		return -1;
	*mv = (raw * 1000U + (1U << (shift - 1))) >> shift;
	return 0;
}

int fmc_vadj_init(const struct fmc_io *io, const unsigned char *fru, size_t len,
		  unsigned int *millivolts)
{
	/* Correct UV ordering: fault below warning. Values are millivolts. */
	static const struct { unsigned char reg; unsigned int mv; } settings[] = {
		{0x24, 1800}, {0x21, 1800}, {0x40, 2000}, {0x42, 1950},
		{0x43, 1700}, {0x44, 1600}, {0x5e, 1710}, {0x5f, 1620}
	};
	unsigned char page = 3;
	unsigned int mode, shift, operation, cfg, protect, status, i;
	*millivolts = 0;
	if (fmc_fru_valid(fru, len))
		return -1;
	if (io->write(io->ctx, 0, &page, 1) || rd(io, 0, 1, &i) || i != 3 ||
	    rd(io, 0x20, 1, &mode) || rd(io, 1, 1, &operation) ||
	    rd(io, 2, 1, &cfg) || rd(io, 0x10, 1, &protect))
		return -1;
	/* Preserve factory exponent, enable-pin policy and write protection. */
	if ((mode != 0x18 && mode != 0x17 && mode != 0x14) || cfg != 0x1a || protect)
		return -1;
	shift = 32 - mode;
	if (voltage(io, shift, millivolts))
		return -1;
	if (operation == 0x80) {
		/* A warm boot must not cycle a valid live rail. */
		if (rd(io, 0x21, 2, &i) || i != ((1800U << shift) + 500) / 1000 ||
		    rd(io, 0x79, 2, &status) || (status & 0xfffe))
			return -1;
		return *millivolts >= 1710 && *millivolts <= 1890 ? 0 : -1;
	}
	if (operation != 0 || *millivolts > 300)
		return -1;
	for (i = 0; i < sizeof(settings) / sizeof(settings[0]); i++)
		if (wr(io, settings[i].reg, 2, ((settings[i].mv << shift) + 500) / 1000))
			goto fail;
	if (wr(io, 1, 1, 0x80))
		goto fail;
	for (i = 0; i < 100; i++) {
		io->delay_ms(10);
		if (voltage(io, shift, millivolts) || rd(io, 0x79, 2, &status))
			goto fail;
		if (*millivolts > 1890)
			goto fail;
		if (*millivolts >= 1710 && !(status & 0xfffe))
			return 0;
	}
fail:
	/* Best effort only: an I2C failure can prevent shutdown; report failure. */
	wr(io, 1, 1, 0);
	return -1;
}
