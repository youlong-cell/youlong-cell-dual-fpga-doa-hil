#include <string.h>
#include "hil_profiles.h"
#include "hardware/sample_clock.h"
#include "hil_profile_generated.h"
const hil_profile_t *hil_profile_for_frequency(uint32_t hz)
{
    for(unsigned i=0;i<sizeof embedded_hil_profiles/sizeof embedded_hil_profiles[0];i++)
        if(embedded_hil_profiles[i].reference_hz==hz)return &embedded_hil_profiles[i];
    return NULL;
}
static const hil_profile_t *installed_profile;
const hil_profile_t *hil_profile_current(void)
{return installed_profile?installed_profile:hil_profile_for_frequency(HIL_PROFILE_HZ);}
int hil_profile_select_installed(const hil_profile_t *p)
{
    if(!p || hil_profile_for_frequency(p->reference_hz)!=p)return -1;
    installed_profile=p;return 0;
}
int hil_profile_apply(const hil_profile_t *p,pl_fine_configuration_t *c)
{
    if(!p || !c || p->geometry_valid>1 || p->calibration_valid>1 || p->measured>1 ||
       !p->geometry_id || !p->profile_id || p->d_mm!=5000 || p->c_mps!=300000000 ||
       p->geometry_a_f24!=(UINT64_C(30000000)<<24) ||
       p->calibration_words[0]!=p->calibration_valid || p->calibration_words[1]!=1 ||
       p->calibration_words[8]!=p->profile_id || p->calibration_words[9]!=0 ||
       p->geometry_words[0]!=p->geometry_valid || p->geometry_words[4]!=p->geometry_id ||
       p->geometry_words[3]!=0)return -1;
    uint64_t encoded_bias=((uint64_t)p->calibration_words[3]<<32)|p->calibration_words[2];
    uint64_t encoded_a=((uint64_t)p->geometry_words[2]<<32)|p->geometry_words[1];
    if(encoded_bias!=(uint64_t)p->bias_pi_f35 || encoded_a!=p->geometry_a_f24 ||
       p->bias_pi_f35<-(INT64_C(1)<<35) || p->bias_pi_f35>=(INT64_C(1)<<35))return -1;
    /* ENGINEERING_ONLY per-frequency test band, U64/F24 Hz. A configured acceptance
     * band is NOT evidence of measured calibration across that band.
     * Frozen PL requires f_min>0 and 2*f_max < Fs (both in F24). */
    const uint64_t minimum=(uint64_t)p->minimum_hz<<24;
    const uint64_t maximum=(uint64_t)p->maximum_hz<<24;
    const uint64_t sample_rate_f24=(uint64_t)ADC_SAMPLE_RATE_HZ<<24;
    if (!minimum || maximum<minimum || p->reference_hz<p->minimum_hz ||
        p->reference_hz>p->maximum_hz || maximum>>49 || minimum>>49 || maximum>=sample_rate_f24 ||
        maximum>=sample_rate_f24-maximum)
        return -1;
    memcpy(c->fine,p->calibration_words,sizeof p->calibration_words);
    c->fine[4]=(uint32_t)minimum;c->fine[5]=(uint32_t)(minimum>>32);
    c->fine[6]=(uint32_t)maximum;c->fine[7]=(uint32_t)(maximum>>32);
    memcpy(&c->fine[19],p->geometry_words,sizeof p->geometry_words);
    return 0;
}
