// SPDX-License-Identifier: GPL-2.0-only
/* Original experimental Gen1/Gen2 x1 host, DBR1/SRP1 ABI v1. No hard PCIe IP.
 * Direct endpoint only: Linux root bus 1, device/function 0. Root requester
 * ID is 00:00.0. No fabricated bridge configuration or Type-1 routing.
 */
#include <linux/bitmap.h>
#include <linux/delay.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/irq.h>
#include <linux/irqdomain.h>
#include <linux/module.h>
#include <linux/msi.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/pci.h>
#include <linux/platform_device.h>

#define CFG_ENABLE 0x10
#define CFG_ADDR_LO 0x20
#define CFG_ADDR_HI 0x24
#define CFG_DATA 0x28
#define CFG_COMMAND 0x2c
#define CFG_SUBMIT 0x30
#define CFG_RESULT 0x34
#define CFG_READ_DATA 0x38
#define DMA_ENABLE 0x10
#define DMA_STATUS 0x14
#define MSI_PENDING 0x20
#define MSI_MASK 0x24
#define MSI_ACK 0x28
#define MSI_ADDRESS 0xfee00000U
#define VECTORS 32

struct soft_pcie {
 struct device *dev;
 void __iomem *cfg, *host;
 struct pci_host_bridge *bridge;
 struct irq_domain *parent, *msi;
 raw_spinlock_t cfg_lock;
 struct mutex msi_lock;
 DECLARE_BITMAP(used, VECTORS);
 bool fault;
 u8 exp_cap;
};

/* PCI core serializes config accesses; use an explicit lock for the physical
 * single-command mailbox too. Atomic polling is necessary under PCI locks.
 * Hardware's requester times out after 50ms; mailbox at 335ms. The 400ms
 * guard quarantines all subsequent config traffic, never cancels DMA/TLPs.
 */
static int soft_config(struct soft_pcie *p, bool write, int where, int size, u32 *value)
{
 unsigned long flags;
 u32 result, be, data = *value;
 int ret = PCIBIOS_SUCCESSFUL;
 if ((size != 1 && size != 2 && size != 4) || where < 0 || where > 4096 - size ||
     (where & (size - 1)))
  return PCIBIOS_BAD_REGISTER_NUMBER;
 be = ((1U << size) - 1) << (where & 3);
 raw_spin_lock_irqsave(&p->cfg_lock, flags);
 if (p->fault || !(readl(p->cfg + 8) & 2)) {
  ret = PCIBIOS_DEVICE_NOT_FOUND;
  goto out;
 }
 /* MPS128 is the negotiated implementation limit. PCI policy may otherwise
  * increase an endpoint's MPS; force its Device Control field to 128 bytes.
  * MRRS up to4096 is supported by split completions, no MRRS clamp needed.
  */
 if (write && p->exp_cap && (where & ~3) == p->exp_cap + PCI_EXP_DEVCTL) {
  u32 mask = PCI_EXP_DEVCTL_PAYLOAD | PCI_EXP_DEVCTL_RELAX_EN |
             PCI_EXP_DEVCTL_NOSNOOP_EN;
  data = ((data << (8 * (where & 3))) & ~mask) >> (8 * (where & 3));
 }
 writel(where & ~3, p->cfg + CFG_ADDR_LO);
 writel(0, p->cfg + CFG_ADDR_HI);
 if (write) writel(data << (8 * (where & 3)), p->cfg + CFG_DATA);
 writel(0x01000000 | (be << 4) | (write ? 3 : 2), p->cfg + CFG_COMMAND);
 writel(1, p->cfg + CFG_SUBMIT);
 if (readl_poll_timeout_atomic(p->cfg + CFG_RESULT, result, result & 2, 1, 400000)) {
  p->fault = true;
  ret = PCIBIOS_SET_FAILED;
  goto out;
 }
 if ((result & 4) || (((result >> 8) & 7) >= 3 && ((result >> 8) & 7) <= 6)) p->fault = true;
 if (((result >> 8) & 7) == 7) {
  /* CRS Software Visibility for the standard PCI vendor-ID retry loop. */
  if (!write && where == 0 && size == 4) *value = 0xffff0001;
  else ret = PCIBIOS_SET_FAILED;
 } else if ((result >> 8) & 7) ret = PCIBIOS_DEVICE_NOT_FOUND;
 else if (!write) *value = (readl(p->cfg + CFG_READ_DATA) >> (8 * (where & 3))) &
                        (size == 4 ? ~0U : (1U << (size * 8)) - 1);
 out:
 if (ret != PCIBIOS_SUCCESSFUL && !write) *value = ~0U;
 raw_spin_unlock_irqrestore(&p->cfg_lock, flags);
 return ret;
}
static int soft_read(struct pci_bus *bus, unsigned int devfn, int where, int size, u32 *val)
{
 *val = ~0U;
 if (bus->number != 1 || devfn) return PCIBIOS_DEVICE_NOT_FOUND;
 return soft_config(bus->sysdata, false, where, size, val);
}
static int soft_write(struct pci_bus *bus, unsigned int devfn, int where, int size, u32 val)
{
 if (bus->number != 1 || devfn) return PCIBIOS_DEVICE_NOT_FOUND;
 return soft_config(bus->sysdata, true, where, size, &val);
}
static struct pci_ops soft_ops = { .read = soft_read, .write = soft_write };

static void soft_compose(struct irq_data *d, struct msi_msg *msg)
{
 msg->address_lo = MSI_ADDRESS;msg->address_hi = 0;msg->data = d->hwirq;
}
static int soft_affinity(struct irq_data *d, const struct cpumask *mask, bool force)
{
 return -EINVAL; /* One parent GIC interrupt; no independent vector routing. */
}
static struct irq_chip soft_bottom_chip = {
 .name = "soft-pcie-msi", .irq_compose_msi_msg = soft_compose,
 .irq_set_affinity = soft_affinity,
};
static void soft_ack(struct irq_data *d) { /* W1C is done before dispatch. */ }
static struct irq_chip soft_top_chip = {
 .name = "soft-pcie", .irq_ack = soft_ack,
 .irq_mask = pci_msi_mask_irq, .irq_unmask = pci_msi_unmask_irq,
};
static int soft_irq_alloc(struct irq_domain *domain, unsigned int virq,
                          unsigned int nr, void *arg)
{
 struct soft_pcie *p = domain->host_data;
 int base, i;
 mutex_lock(&p->msi_lock);
 base = bitmap_find_free_region(p->used, VECTORS, order_base_2(nr));
 mutex_unlock(&p->msi_lock);
 if (base < 0) return base;
 for (i = 0; i < nr; i++)
  irq_domain_set_info(domain, virq + i, base + i, &soft_bottom_chip, p,
                      handle_edge_irq, NULL, NULL);
 return 0;
}
static void soft_irq_free(struct irq_domain *domain, unsigned int virq, unsigned int nr)
{
 struct soft_pcie *p = domain->host_data;
 struct irq_data *d = irq_domain_get_irq_data(domain, virq);
 mutex_lock(&p->msi_lock);
 bitmap_release_region(p->used, d->hwirq, order_base_2(nr));
 mutex_unlock(&p->msi_lock);
}
static const struct irq_domain_ops soft_domain_ops = {
 .alloc = soft_irq_alloc, .free = soft_irq_free,
};
static struct msi_domain_info soft_msi_info = {
 .flags = MSI_FLAG_USE_DEF_DOM_OPS | MSI_FLAG_USE_DEF_CHIP_OPS |
          MSI_FLAG_MULTI_PCI_MSI | MSI_FLAG_PCI_MSIX,
 .chip = &soft_top_chip,
};
static irqreturn_t soft_irq(int irq, void *data)
{
 struct soft_pcie *p = data;
 u32 bits = readl(p->host + MSI_PENDING) & readl(p->host + MSI_MASK);
 unsigned int bit;
 if (!bits) return IRQ_NONE;
 // Ack before dispatch; a repeated message during dispatch remains pending.
 writel(bits, p->host + MSI_ACK);
 readl(p->host + MSI_PENDING);
 for (bit = 0; bit < VECTORS; bit++)
  if (bits & BIT(bit)) generic_handle_domain_irq(p->parent, bit);
 return IRQ_HANDLED;
}
static void soft_domains_remove(void *data)
{
 struct soft_pcie *p = data;
 irq_domain_remove(p->msi);irq_domain_remove(p->parent);
}
static int soft_probe(struct platform_device *pdev)
{
 struct device *dev = &pdev->dev;
 struct pci_host_bridge *bridge;
 struct soft_pcie *p;
 u32 val, cap, id, link_status;
 int irq, ret, n;
 unsigned long deadline;
 bridge = devm_pci_alloc_host_bridge(dev, sizeof(*p));
 if (!bridge) return -ENOMEM;
 p = pci_host_bridge_priv(bridge);p->dev = dev;p->bridge = bridge;
 raw_spin_lock_init(&p->cfg_lock);mutex_init(&p->msi_lock);
 p->cfg = devm_platform_ioremap_resource_byname(pdev, "config");
 if (IS_ERR(p->cfg)) return PTR_ERR(p->cfg);
 p->host = devm_platform_ioremap_resource_byname(pdev, "host");
 if (IS_ERR(p->host)) return PTR_ERR(p->host);
 if (readl(p->cfg) != 0x53525031 || readl(p->cfg + 4) != 0x10000 ||
     readl(p->host) != 0x44425231 || readl(p->host + 4) != 0x10000)
  return dev_err_probe(dev, -ENODEV, "unrecognized host RTL ABI\n");
 writel(0, p->host + MSI_MASK);writel(~0U, p->host + MSI_ACK);
 writel(0, p->host + DMA_ENABLE);
 if ((readl(p->host + DMA_STATUS) & 3) ||
     (readl(p->cfg + CFG_RESULT) & 5))
  return dev_err_probe(dev, -EIO, "host quarantined; global reset required\n");
 writel(readl(p->cfg + CFG_ENABLE) | 1, p->cfg + CFG_ENABLE);
 if (readl_poll_timeout(p->cfg + 8, val, val & 2, 1000, 2000000))
  return dev_err_probe(dev, -ETIMEDOUT, "PCIe link did not become active\n");
 // Discover the real endpoint's PCIe capability before PCI core can change MPS.
 deadline = jiffies + msecs_to_jiffies(2000);
 do {
  val = 0;ret = soft_config(p, false, PCI_VENDOR_ID, 4, &val);
  if (ret || val != 0xffff0001) break;
  msleep(20);
 } while (time_before(jiffies, deadline));
 if (ret || val == 0xffff0001 || (val & 0xffff) == 0xffff)
  return dev_err_probe(dev, -ENODEV, "no direct endpoint\n");
 val = 0;ret = soft_config(p, false, PCI_CAPABILITY_LIST, 1, &val);cap = val & ~3U;
 for (n = 0; !ret && cap >= 0x40 && cap <= 0xfc && n < 48; n++) {
  id = 0;ret = soft_config(p, false, cap, 2, &id);
  if ((id & 0xff) == PCI_CAP_ID_EXP) { p->exp_cap = cap;break; }
  cap = (id >> 8) & ~3U;
 }
 if (!p->exp_cap) return dev_err_probe(dev, -ENODEV, "PCIe capability missing\n");
 val = 0;ret = soft_config(p, false, p->exp_cap + PCI_EXP_DEVCTL, 2, &val);
 if (!ret) ret = soft_config(p, true, p->exp_cap + PCI_EXP_DEVCTL, 2, &val);
 if (ret) return -EIO;
 link_status = 0;
 ret = soft_config(p, false, p->exp_cap + PCI_EXP_LNKSTA, 2, &link_status);
 if (ret) return -EIO;
 p->parent = irq_domain_create_linear(dev_fwnode(dev), VECTORS, &soft_domain_ops, p);
 if (!p->parent) return -ENOMEM;
 irq_domain_update_bus_token(p->parent, DOMAIN_BUS_NEXUS);
 p->msi = pci_msi_create_irq_domain(dev_fwnode(dev), &soft_msi_info, p->parent);
 if (!p->msi) { irq_domain_remove(p->parent);return -ENOMEM; }
 ret = devm_add_action_or_reset(dev, soft_domains_remove, p);
 if (ret) return ret;
 dev_set_msi_domain(&bridge->dev, p->msi);
 irq = platform_get_irq(pdev, 0);
 if (irq < 0) return irq;
 ret = devm_request_irq(dev, irq, soft_irq, 0, "soft-pcie", p);
 if (ret) return ret;
 bridge->sysdata = p;bridge->ops = &soft_ops;
 bridge->busnr = 1;bridge->msi_domain = true;
 // HP0 is noncoherent: normal arm64 PCI DMA API cache maintenance is required.
 // dma-ranges restricts endpoint addresses to the installed lower2GiB PS DDR.
 writel(~0U, p->host + MSI_MASK);writel(1, p->host + DMA_ENABLE);
 ret = pci_host_probe(bridge);
 if (ret) { writel(0, p->host + DMA_ENABLE);writel(0, p->host + MSI_MASK); }
 else {
  /* No surprise removal or live reset implementation: pin this module once
   * endpoints can own DDR. A reboot/global coordinated reset is required. */
  __module_get(THIS_MODULE);
  dev_info(dev, "experimental PCIe Gen%ux%u host, MPS128, DDR2GiB, MSI/MSI-X32\n",
           link_status & PCI_EXP_LNKSTA_CLS,
           (link_status & PCI_EXP_LNKSTA_NLW) >> PCI_EXP_LNKSTA_NLW_SHIFT);
 }
 return ret;
}
static const struct of_device_id soft_match[] = {
 { .compatible = "ngt,zcu104-soft-pcie-1.0" }, {}
};
MODULE_DEVICE_TABLE(of, soft_match);
static struct platform_driver soft_driver = {
 .probe = soft_probe,
 .driver = { .name = "zcu104-soft-pcie", .of_match_table = soft_match,
             .suppress_bind_attrs = true },
};
module_platform_driver(soft_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Experimental ZCU104 soft PCIe root host");
MODULE_INFO(source_sha256, ZCU104_SOURCE_SHA256);
