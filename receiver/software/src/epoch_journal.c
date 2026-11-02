#include "epoch_journal.h"
#include <string.h>

#define BODY_MAGIC UINT32_C(0x314f5045)   /* EPO1, little endian */
#define COMMIT_MAGIC UINT32_C(0x31544d43) /* CMT1 */
#define VERSION UINT32_C(1)
#define NO_ADDRESS UINT32_MAX

static uint32_t get32(const uint8_t *p)
{
    return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);
}
static uint64_t get64(const uint8_t *p)
{ return (uint64_t)get32(p)|((uint64_t)get32(p+4)<<32); }
static void put32(uint8_t *p,uint32_t v)
{ unsigned int n; for(n=0;n<4;n++) p[n]=(uint8_t)(v>>(8*n)); }
static void put64(uint8_t *p,uint64_t v)
{ put32(p,(uint32_t)v); put32(p+4,(uint32_t)(v>>32)); }
static uint32_t crc32(const uint8_t *p,size_t len)
{
    uint32_t c=UINT32_MAX; size_t n; unsigned int bit;
    for(n=0;n<len;n++) {
        c^=p[n];
        for(bit=0;bit<8;bit++) c=(c>>1)^((c&1U)?UINT32_C(0xedb88320):0U);
    }
    return ~c;
}
static int power2(uint32_t v) { return v!=0U && (v&(v-1U))==0U; }
static epoch_status_t stop(epoch_journal_t *j,epoch_status_t status)
{
    j->last_status=status;
    if(status!=EPOCH_OK) j->mounted=0;
    return status;
}
static epoch_status_t validate(const epoch_layout_t *l,const epoch_storage_t *s)
{
    uint64_t end;
    if(l==NULL || s==NULL || s->read==NULL || s->program==NULL || s->erase==NULL)
        return EPOCH_LAYOUT_INVALID;
    if(l->layout_verified!=1U) return EPOCH_LAYOUT_UNVERIFIED;
    end=(uint64_t)l->partition_base+2ULL*l->erase_bytes;
    if(l->namespace_id==0U || !power2(l->erase_bytes) || !power2(l->page_bytes) ||
       l->page_bytes<64U || l->page_bytes>4096U ||
       (uint64_t)l->erase_bytes<2ULL*l->page_bytes ||
       l->partition_base%l->erase_bytes!=0U || end>l->flash_bytes || end>UINT32_MAX)
        return EPOCH_LAYOUT_INVALID;
    return EPOCH_OK;
}
/* Reads bounded chunks; no page-sized stack buffer or dynamic allocation. */
static epoch_status_t erased(epoch_journal_t *j,uint32_t address,uint32_t bytes,int *blank)
{
    uint8_t data[64]; size_t n,k;
    *blank=1;
    while(bytes!=0U) {
        n=bytes<sizeof(data)?bytes:sizeof(data);
        if(j->storage.read(j->storage.context,address,data,n)!=0) return EPOCH_IO;
        for(k=0;k<n;k++) if(data[k]!=UINT8_C(0xff)) *blank=0;
        address+=(uint32_t)n; bytes-=(uint32_t)n;
    }
    return EPOCH_OK;
}
static epoch_status_t record(epoch_journal_t *j,uint32_t address,
                             int *present,int *blank,uint64_t *epoch)
{
    uint8_t b[64],c[32]; int body_blank,commit_blank,tail; epoch_status_t status;
    *present=0; *blank=0;
    status=erased(j,address,j->layout.page_bytes,&body_blank); if(status) return status;
    status=erased(j,address+j->layout.page_bytes,j->layout.page_bytes,&commit_blank);
    if(status) return status;
    if(commit_blank) {
        /* Torn body cannot have issued an epoch; skip occupied slot forever.
         * A dirty commit is NEVER treated like an uncommitted body. */
        *blank=body_blank; return EPOCH_OK;
    }
    if(j->storage.read(j->storage.context,address,b,sizeof(b))!=0 ||
       j->storage.read(j->storage.context,address+j->layout.page_bytes,c,sizeof(c))!=0)
        return EPOCH_IO;
    if(get32(b)!=BODY_MAGIC || get32(b+4)!=VERSION || get32(c)!=COMMIT_MAGIC ||
       get32(c+4)!=VERSION || get64(b+16)!=~get64(b+8) ||
       get64(b+24)!=j->layout.namespace_id || get64(b+32)!=~get64(b+24) ||
       get32(b+40)!=address || get32(b+44)!=j->layout.erase_bytes ||
       get32(b+48)!=j->layout.page_bytes || get32(b+52)!=64U ||
       get32(b+56)!=crc32(b,56) || get32(b+60)!=~get32(b+56) ||
       get64(c+8)!=get64(b+8) || get32(c+16)!=get32(b+56) ||
       get32(c+20)!=~get32(c+16) || get32(c+24)!=crc32(c,24) ||
       get32(c+28)!=~get32(c+24)) return EPOCH_CORRUPT;
    status=erased(j,address+64,j->layout.page_bytes-64U,&tail);
    if(status) return status;
    if(!tail) return EPOCH_CORRUPT;
    status=erased(j,address+j->layout.page_bytes+32,j->layout.page_bytes-32U,&tail);
    if(status) return status;
    if(!tail) return EPOCH_CORRUPT;
    *present=1; *epoch=get64(b+8); return EPOCH_OK;
}
static epoch_status_t scan(epoch_journal_t *j)
{
    unsigned int block; uint32_t offset,address; uint64_t e=0;
    uint64_t first[2]={0,0},last[2]={0,0}; int has[2]={0,0},present,blank;
    epoch_status_t status;
    j->mounted=0; j->free_address[0]=NO_ADDRESS; j->free_address[1]=NO_ADDRESS;
    for(block=0;block<2;block++) {
        for(offset=0;offset<j->layout.erase_bytes;offset+=2U*j->layout.page_bytes) {
            address=j->layout.partition_base+block*j->layout.erase_bytes+offset;
            status=record(j,address,&present,&blank,&e); if(status) return stop(j,status);
            if(present) {
                if(has[block] && e<=last[block]) return stop(j,EPOCH_CORRUPT);
                if(!has[block]) first[block]=e;
                last[block]=e; has[block]=1;
                /* Never append into an earlier hole preceding a committed record. */
                j->free_address[block]=NO_ADDRESS;
            } else if(blank && j->free_address[block]==NO_ADDRESS) j->free_address[block]=address;
        }
    }
    if(!has[0] && !has[1]) return stop(j,EPOCH_UNPROVISIONED);
    if(has[0] && has[1] && !(last[0]<first[1] || last[1]<first[0]))
        return stop(j,EPOCH_CORRUPT);
    j->newest_block=has[1] && (!has[0] || last[1]>last[0]) ? 1U : 0U;
    j->high_water=last[j->newest_block]; j->mounted=1;
    j->last_status=EPOCH_OK; return EPOCH_OK;
}
static epoch_status_t append(epoch_journal_t *j,uint32_t address,uint64_t epoch)
{
    uint8_t b[64],c[32],readback[64]; int present,blank; uint64_t checked=0;
    epoch_status_t status;
    status=record(j,address,&present,&blank,&checked); if(status) return stop(j,status);
    if(!blank || present) return stop(j,EPOCH_NOT_BLANK);
    memset(b,0xff,sizeof(b)); memset(c,0xff,sizeof(c));
    put32(b,BODY_MAGIC); put32(b+4,VERSION); put64(b+8,epoch); put64(b+16,~epoch);
    put64(b+24,j->layout.namespace_id); put64(b+32,~j->layout.namespace_id);
    put32(b+40,address); put32(b+44,j->layout.erase_bytes); put32(b+48,j->layout.page_bytes);
    put32(b+52,64U); put32(b+56,crc32(b,56)); put32(b+60,~get32(b+56));
    if(j->storage.program(j->storage.context,address,b,sizeof(b))!=0) return stop(j,EPOCH_IO);
    if(j->storage.read(j->storage.context,address,readback,sizeof(b))!=0) return stop(j,EPOCH_IO);
    if(memcmp(readback,b,sizeof(b))!=0) return stop(j,EPOCH_READBACK);
    /* Commit is written LAST, on a fresh physical page, after body readback. */
    put32(c,COMMIT_MAGIC); put32(c+4,VERSION); put64(c+8,epoch);
    put32(c+16,get32(b+56)); put32(c+20,~get32(c+16));
    put32(c+24,crc32(c,24)); put32(c+28,~get32(c+24));
    if(j->storage.program(j->storage.context,address+j->layout.page_bytes,c,sizeof(c))!=0)
        return stop(j,EPOCH_IO);
    status=record(j,address,&present,&blank,&checked);
    if(status) return stop(j,status);
    if(!present || checked!=epoch) return stop(j,EPOCH_READBACK);
    return scan(j);
}
epoch_status_t epoch_journal_mount(epoch_journal_t *j,const epoch_layout_t *l,
                                  const epoch_storage_t *s)
{
    epoch_status_t status;
    if(j==NULL) return EPOCH_LAYOUT_INVALID;
    memset(j,0,sizeof(*j));
    status=validate(l,s); if(status) return stop(j,status);
    j->layout=*l; j->storage=*s; j->initialized=1;
    return scan(j);
}
epoch_status_t epoch_journal_provision(epoch_journal_t *j,uint64_t floor)
{
    int blank; epoch_status_t status;
    if(j==NULL || !j->initialized) return EPOCH_NOT_MOUNTED;
    /* Provision cannot bypass a dirty page/corruption by wiping it. */
    status=erased(j,j->layout.partition_base,2U*j->layout.erase_bytes,&blank);
    if(status) return stop(j,status);
    if(!blank) return stop(j,EPOCH_NOT_BLANK);
    return append(j,j->layout.partition_base,floor);
}
epoch_status_t epoch_journal_reserve(epoch_journal_t *j,uint64_t *out)
{
    uint32_t address; uint64_t next; unsigned int other; int blank;
    epoch_status_t status;
    if(out==NULL) return EPOCH_LAYOUT_INVALID;
    *out=0;
    if(j==NULL || !j->initialized || !j->mounted) return EPOCH_NOT_MOUNTED;
    /* Re-scan also prevents sequential use of stale mounted objects. Still
     * requires one serialized physical storage owner for concurrent callers. */
    status=scan(j); if(status) return status;
    if(j->high_water==UINT64_MAX) return stop(j,EPOCH_EXHAUSTED);
    next=j->high_water+1U; address=j->free_address[j->newest_block];
    if(address==NO_ADDRESS) {
        other=1U-j->newest_block;
        address=j->layout.partition_base+other*j->layout.erase_bytes;
        /* Highest committed epoch ALWAYS survives in the untouched block. */
        if(j->storage.erase(j->storage.context,address,j->layout.erase_bytes)!=0)
            return stop(j,EPOCH_IO);
        status=erased(j,address,j->layout.erase_bytes,&blank);
        if(status) return stop(j,status);
        if(!blank) return stop(j,EPOCH_READBACK);
    }
    status=append(j,address,next); if(status) return status;
    if(j->high_water!=next) return stop(j,EPOCH_READBACK);
    *out=next; return EPOCH_OK; /* ONLY this point authorizes a new session. */
}
