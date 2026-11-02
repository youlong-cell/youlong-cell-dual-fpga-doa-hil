/* ENGINEERING_ONLY: provisional detector/interpolation controls and explicitly
 * selected, unmeasured HIL profiles. Production durable entry stays separate. */
#include <string.h>
#include "engineering_session.h"
#include "hardware/sample_clock.h"
#include "hil_profiles.h"
int engineering_configuration_for_profile(const hil_profile_t *profile,pl_fine_configuration_t *c)
{
    if(!c)return -1;
    memset(c,0,sizeof(*c));
    c->fine[1]=1; /* Frozen CH1-CH0 convention; not a measured sign calibration. */
    c->fine[10]=ADC_SAMPLE_RATE_HZ;
    c->fine[11]=1;
    c->fine[12]=UINT32_C(67108864); /* P_min=0.25 log2, F28, provisional */
    c->fine[14]=UINT32_C(9003088);  /* curvature certificate, F28 */
    c->fine[16]=UINT32_C(2147483648); /* max |delta|=.5 bin, F32 */
    c->fine[18]=UINT32_C(4294); /* delta error budget ~1e-6 bin, F32 */
    /* Power score = sat32((Re^2+Im^2)>>16). At -60dBFS a Hann
     * 1024-point single tone gives about 4.18; ceil -> 5, NOT raw power. */
    c->detector[0]=1U|(2U<<1)|(510U<<10);
    c->detector[1]=5;c->detector[2]=5;c->detector[3]=10;
    /* Explicit user-approved HIL model, not durable production approval. */
    if(hil_profile_apply(profile,c)){
        /* Do not submit a malformed profile through the transport. */
        c->reviewed=UINT32_MAX;
        return -1;
    }
    return 0;
}
void engineering_configuration(pl_fine_configuration_t *c)
{(void)engineering_configuration_for_profile(hil_profile_current(),c);}
int engineering_session_start(pl_fine_lifecycle_t *context)
{
    pl_fine_configuration_t c;uint32_t lo=0,hi=0;uint64_t previous,next;
    if(!context)return -1;
    memset(context,0,sizeof(*context));
    if(pl_fine_stop() || pl_fine_status(3,&lo) || pl_fine_status(4,&hi))return -2;
    previous=((uint64_t)hi<<32)|lo;
    if(previous==UINT64_MAX)return -3;
    next=previous>=ENGINEERING_EPOCH_BASE?previous+1:ENGINEERING_EPOCH_BASE;
    engineering_configuration(&c);
    int rc=pl_fine_start_engineering_session(next,&c);
    if(rc)return rc;
    if(pl_fine_lifecycle_snapshot(context) || !context->ready ||
       context->session_epoch!=next)return -4;
    return 0;
}
