# SPDX-License-Identifier: Apache-2.0
"""Execute the production config callback against a bounded MMIO fault model."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def test_config_poll_and_quarantine(tmp_path):
    source = (ROOT / 'software/driver/zcu104-soft-pcie.c').read_text()
    callback = source[source.index('static int soft_config('):source.index('static int soft_read(')]
    constants = source[source.index('#define CFG_ENABLE'):source.index('struct soft_pcie {')]
    harness = r'''
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>
#include <stdio.h>
typedef uint32_t u32;
#define module_param(a,b,c)
#define MODULE_PARM_DESC(a,b)
#define PCIBIOS_SUCCESSFUL 0
#define PCIBIOS_BAD_REGISTER_NUMBER 1
#define PCIBIOS_DEVICE_NOT_FOUND 2
#define PCIBIOS_SET_FAILED 3
#define PCI_EXP_DEVCTL 8
#define PCI_EXP_DEVCTL_PAYLOAD 0xe0
#define PCI_EXP_DEVCTL_RELAX_EN 0x10
#define PCI_EXP_DEVCTL_NOSNOOP_EN 0x800
#define raw_spin_lock_irqsave(lock,flags) ((flags)=0)
#define raw_spin_unlock_irqrestore(lock,flags) ((void)(flags))
struct soft_pcie { unsigned char *cfg; bool fault; uint8_t exp_cap; int cfg_lock; };
static unsigned char memory[64];
static unsigned reads, writes, scenario;
static u32 last_data;
static u32 readl(void *address) {
 unsigned offset=(unsigned char *)address-memory;
 if (offset==8) return 2;
 if (offset==0x38) return 0x1234144d;
 if (offset==0x34) {
  reads++;
  if (scenario==1) return 0; /* no completion */
  if (scenario==2) return 4; /* quarantine even without done */
  if (scenario==3) return 0x406;
  if (scenario==4) return 0x702;
  if (scenario==5) return reads>3 ? 2 : 1;
  return 2;
 }
 return 0;
}
static void writel(u32 value, void *address) {
 writes++;
 if ((unsigned char *)address-memory==0x28) last_data=value;
}
/* Each model iteration is one us. Execute callback's actual predicate and
 * budget expression; no sleeps, hardware access or copied callback logic. */
#define readl_poll_timeout_atomic(addr,val,condition,delay,budget) \
 ({ unsigned elapsed=0; int rc=-1; \
    do { val=readl(addr); if (condition) {rc=0;break;} } while (++elapsed<budget); rc; })
'''
    cases = r'''
int main(void) {
 struct soft_pcie p={.cfg=memory};
 u32 value=0;
 assert(soft_config(&p,false,0,4,&value)==0 && value==0x1234144d);
 scenario=5; reads=0;
 assert(soft_config(&p,false,0,2,&value)==0 && value==0x144d && reads==4);
 for (scenario=1; scenario<=3; scenario++) {
  p.fault=false; reads=0; writes=0; value=0;
  assert(soft_config(&p,false,0,4,&value)!=0 && p.fault && value==~0U);
  assert(reads==(scenario==1 ? CFG_POLL_TIMEOUT_US : 1));
  unsigned prior=writes;
  /* Even a late successful response cannot permit another submission. */
  unsigned old=scenario; scenario=0;
  assert(soft_config(&p,true,4,4,&value)!=0 && writes==prior);
  scenario=old;
 }
 scenario=4; p.fault=false;
 assert(soft_config(&p,false,0,4,&value)==0 && value==0xffff0001 && !p.fault);
 scenario=0; p.exp_cap=0x40; value=~0U;
 assert(soft_config(&p,true,0x48,2,&value)==0);
 assert(!(last_data & (PCI_EXP_DEVCTL_PAYLOAD|PCI_EXP_DEVCTL_RELAX_EN|PCI_EXP_DEVCTL_NOSNOOP_EN)));
 puts("PASS config polling, early fault, unchanged deadline, late completion quarantine and policy");
}
'''
    path = tmp_path / 'config.c'
    path.write_text(harness + constants + callback + cases)
    exe = tmp_path / 'config'
    subprocess.run(['gcc', '-std=gnu11', '-Wall', '-Wextra', '-Werror', str(path), '-o', str(exe)], check=True)
    result = subprocess.run([str(exe)], capture_output=True, text=True, check=True)
    assert 'PASS config polling' in result.stdout
