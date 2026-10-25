// Experimental root-port command interface; no Linux PCI host enumeration.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
static volatile uint32_t *regs;
static uint32_t rd(unsigned a) { uint32_t v=regs[a/4]; atomic_thread_fence(memory_order_seq_cst); return v; }
static void wr(unsigned a,uint32_t v) { atomic_thread_fence(memory_order_seq_cst); regs[a/4]=v; atomic_thread_fence(memory_order_seq_cst); }
static void pause_ms(void) { struct timespec t={0,1000000}; nanosleep(&t,NULL); }
static unsigned number(const char *s,unsigned max) {
 char *end;errno=0;unsigned long v=strtoul(s,&end,0);
 if(errno||!*s||*end||v>max) {fprintf(stderr,"Invalid number: %s\n",s);exit(2);} return (unsigned)v;
}
int main(int argc,char **argv) {
 if(argc<3) {fprintf(stderr,"Usage: %s /dev/uioN status|enable|disable|cfg-read [BDF OFFSET]\n",argv[0]);return 2;}
 if(strncmp(argv[1],"/dev/uio",8)) {fprintf(stderr,"Expected a UIO device\n");return 2;}
 const char *n=argv[1]+8; if(!*n||strspn(n,"0123456789")!=strlen(n))return 2;
 int fd=open(argv[1],O_RDWR|O_SYNC);if(fd<0){perror("open UIO");return 1;}
 if(flock(fd,LOCK_EX|LOCK_NB)<0){perror("UIO ownership");close(fd);return 1;}
 void *map=mmap(NULL,4096,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
 if(map==MAP_FAILED){perror("mmap");close(fd);return 1;}regs=map;int result=0;
 if(rd(0)!=0x53525031||rd(4)!=0x00010000){fprintf(stderr,"Unrecognized root-port ABI\n");result=1;goto done;}
 if(!strcmp(argv[2],"status")&&argc==3){
  uint32_t s=rd(8),c=rd(0x34);
  printf("enable=%u link=%u dl_active=%u error=%u ltssm=%u busy=%u done=%u quarantined=%u response=%u\n",rd(0x10)&1,s&1,(s>>1)&1,(s>>2)&1,(s>>3)&31,c&1,(c>>1)&1,(c>>2)&1,(c>>8)&7);
 } else if((!strcmp(argv[2],"enable")||!strcmp(argv[2],"disable"))&&argc==3){
  if(rd(0x34)&5){fprintf(stderr,"Busy or quarantined; global reset required after timeout\n");result=1;goto done;}
  unsigned enable=!strcmp(argv[2],"enable");wr(0x10,enable);
  if((rd(0x10)&1)!=enable){fprintf(stderr,"Enable rejected\n");result=1;}
 } else if(!strcmp(argv[2],"cfg-read")&&argc==5){
  unsigned bdf=number(argv[3],65535),off=number(argv[4],4095);
  if((off&3)||(rd(0x34)&5)||!(rd(8)&2)){fprintf(stderr,"Require aligned DWORD, active link and idle non-quarantined interface\n");result=1;goto done;}
  wr(0x20,off);wr(0x24,0);wr(0x28,0);wr(0x2c,(bdf<<16)|0xf2);wr(0x30,1);
  unsigned i;uint32_t status=0;
  for(i=0;i<1000;i++){status=rd(0x34);if(!(status&1)&&(status&2))break;pause_ms();}
  if(i==1000||(status&0x704)){fprintf(stderr,"Configuration read failed: status=0x%08" PRIx32 "\n",status);result=1;}
  else printf("%04x offset 0x%03x = 0x%08" PRIx32 "\n",bdf,off,rd(0x38));
 } else {fprintf(stderr,"Invalid command or arguments\n");result=2;}
 done:munmap(map,4096);close(fd);return result;
}
