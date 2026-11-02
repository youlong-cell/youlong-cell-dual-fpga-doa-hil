#include "fine_production_ps.h"
#include <string.h>
uint64_t pl_fine_bits(const pl_fine_packet_t *p,unsigned int bit,unsigned int width)
{
    uint64_t r=0;unsigned int i;
    if(!p || !width || width>64 || bit+width>PL_FINE_USED_BITS)return 0;
    for(i=0;i<width;i++)r|=(uint64_t)((p->word[(bit+i)/32]>>((bit+i)%32))&1U)<<i;
    return r;
}
int64_t pl_fine_signed(const pl_fine_packet_t *p,unsigned int bit,unsigned int width)
{
    uint64_t r=pl_fine_bits(p,bit,width);
    /* All signed transport fields are <64; avoid undefined signed shifts. */
    if(!width || width>=64)return 0;
    return (r & (UINT64_C(1)<<(width-1))) ?
        -(int64_t)(((UINT64_C(1)<<width)-1U)^r)-1 : (int64_t)r;
}
int pl_fine_packet_identity(const pl_fine_packet_t *p,result_identity_t *id)
{
    unsigned int i;
    if(!p || !id)return -1;
    if(p->word[32]&UINT32_C(0xff800000))return -2;
    for(i=33;i<PL_FINE_PACKET_WORDS;i++)if(p->word[i])return -2;
    result_identity_decode_words(p->word,id);
    return id->session_epoch ? 0 : -3;
}
