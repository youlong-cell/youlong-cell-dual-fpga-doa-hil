#include "auto_profile.h"
#include "debug_input.h"
#include <string.h>
#include <math.h>
/* Engineering thresholds, not factory accuracy/noise specifications. */
const auto_profile_config_t auto_profile_defaults={5,100,200,500,80000,100000,6.0f};
static const uint32_t centers[4]={1000000,2000000,5000000,10000000};
static void fault(auto_profile_t *a,int error)
{a->error=error;a->state=AP_FAULT;a->visible=0;a->enabled=0;}
const char *auto_profile_state_name(enum auto_profile_state s)
{
    static const char *names[]={"OFF","SCAN","CONFIRM","SWITCHING","RUNNING","FAULT"};
    return (unsigned)s<6?names[s]:"UNKNOWN";
}
void auto_profile_init(auto_profile_t *a,const pl_fine_lifecycle_t *ctx,int enabled)
{
    memset(a,0,sizeof *a);a->config=auto_profile_defaults;a->active=hil_profile_current();
    if(ctx){a->context=*ctx;a->active_ready=ctx->ready;}
    a->enabled=enabled!=0;a->state=a->enabled?AP_SCAN:AP_OFF;
}
int auto_profile_enable(auto_profile_t *a)
{
    if(!a || a->state==AP_FAULT || pl_fine_control_busy())return -1;
    a->enabled=1;a->visible=0;a->state=AP_SCAN;a->desired_hz=a->count=0;
    a->have_sequence=0;a->clock_ms=a->last_frame_ms=a->last_good_ms=0;
    return 0;
}
int auto_profile_disable(auto_profile_t *a)
{
    if(!a)return -1;
    a->enabled=0;a->visible=0;a->state=AP_OFF;
    a->desired_hz=a->count=0;a->stop_pending=1;
    if(pl_fine_control_cancel()){fault(a,-10);return -1;}
    return 0;
}
static uint32_t identify(const auto_profile_t *a,const spectrum_t *s0,const spectrum_t *s1)
{
    debug_peak_t peak[2];
    const spectrum_t *s[2]={s0,s1};
    uint32_t hz=0;
    if(!s0 || !s1 || !isfinite(s0->fs) || !isfinite(s1->fs) ||
       s0->fs<=0 || s0->fs!=s1->fs)return 0;
    for(unsigned ch=0;ch<2;ch++){
        debug_peak_measure(s[ch],&debug_input_default_config,&peak[ch]);
        if(!peak[ch].valid || peak[ch].dbfs<debug_input_default_config.min_peak_dbfs ||
           peak[ch].prominence_db<debug_input_default_config.min_prominence_db)return 0;
    }
    unsigned b0=peak[0].bin,b1=peak[1].bin;
    if(b0>b1+1 || b1>b0+1)return 0;
    for(unsigned i=0;i<4;i++){
        uint32_t width=a->active_ready && a->active->reference_hz==centers[i]?
                       a->config.hold_hz:a->config.enter_hz;
        if(fabs((double)peak[0].hz-centers[i])<=width &&
           fabs((double)peak[1].hz-centers[i])<=width){if(hz)return 0;hz=centers[i];}
    }
    if(!hz)return 0;
    /* Reject competitive OTHER frequency bands. This is prominence, NOT SNR. */
    for(unsigned ch=0;ch<2;ch++)
        for(unsigned k=debug_input_default_config.bin_min;k<=debug_input_default_config.bin_max;k++){
            if(!isfinite(s[ch]->freq[k]) || !isfinite(s[ch]->mag_db[k]))return 0;
            for(unsigned i=0;i<4;i++)if(centers[i]!=hz &&
                fabs((double)s[ch]->freq[k]-centers[i])<=a->config.hold_hz &&
                s[ch]->mag_db[k]>peak[ch].dbfs-a->config.competing_margin_db)return 0;
        }
    return hz;
}
void auto_profile_observe(auto_profile_t *a,const spectrum_t *s0,const spectrum_t *s1,
                          uint32_t sequence,uint64_t now,int quality)
{
    if(!a || !a->enabled || a->state==AP_FAULT)return;
    if(a->have_sequence){
        uint32_t delta=sequence-a->sequence;
        if(!delta || delta>=UINT32_C(0x80000000)){a->duplicate_frames++;return;}
    }
    if(now<a->clock_ms){fault(a,-11);return;}
    if(a->have_sequence && now-a->last_frame_ms>a->config.max_gap_ms){
        a->desired_hz=0;a->count=0;a->visible=0;
    }
    a->clock_ms=now;a->last_frame_ms=now;a->sequence=sequence;a->have_sequence=1;
    uint32_t hz=quality?identify(a,s0,s1):0;
    if(!hz){
        a->rejected_frames++;a->desired_hz=0;a->count=0;a->visible=0;
        if(!pl_fine_control_busy())a->state=AP_SCAN;
        return;
    }
    a->last_good_ms=now;
    if(hz!=a->desired_hz){
        a->desired_hz=hz;a->count=1;a->since_ms=now;a->visible=0;
    }else if(a->count!=UINT32_MAX)a->count++;
    if(!pl_fine_control_busy()){
        if(a->active_ready && hz==a->active->reference_hz &&
           a->count>=a->config.confirm_frames && now-a->since_ms>=a->config.confirm_ms){
            a->visible=1;a->state=AP_RUNNING;
        }else{a->visible=0;a->state=AP_CONFIRM;}
    }
}
void auto_profile_service(auto_profile_t *a,uint64_t now,int bus_ok)
{
    if(!a || a->state==AP_FAULT)return;
    if(!bus_ok){fault(a,-12);return;} /* no MMIO retries on a fenced bus */
    if(now<a->clock_ms){fault(a,-11);return;}
    a->clock_ms=now;
    if(pl_fine_control_busy()){
        int rc=pl_fine_control_step();a->state=a->enabled?AP_SWITCHING:AP_OFF;
        a->visible=0;
        if(rc<0){fault(a,rc);return;}
        if(!rc)return;
        if(a->stop_pending){
            a->stop_pending=0;a->active_ready=0;a->target=0;
            a->state=a->enabled?AP_SCAN:AP_OFF;
            return;
        }
        if(!a->target || pl_fine_lifecycle_snapshot(&a->context) || !a->context.ready ||
           hil_profile_select_installed(a->target)){fault(a,-13);return;}
        a->active=a->target;a->target=0;a->active_ready=1;a->switches++;
        /* No result is invented here. The sole consumer still needs poll->ACK. */
        a->state=AP_CONFIRM;
        return;
    }
    if(!a->enabled || a->state==AP_FAULT)return;
    if(!a->have_sequence || now-a->last_frame_ms>a->config.max_gap_ms){
        a->visible=0;a->count=0;a->desired_hz=0;a->state=AP_SCAN;
    }
    if((!a->have_sequence && now>=a->config.loss_ms) ||
       (a->have_sequence && now-a->last_good_ms>=a->config.loss_ms)){
        if(a->active_ready){
            if(pl_fine_control_begin(0,0)){fault(a,-14);return;}
            a->active_ready=0;a->stop_pending=1;a->visible=0;a->state=AP_SWITCHING;
        }
        return;
    }
    if(!a->desired_hz || a->count<a->config.confirm_frames ||
       now-a->since_ms<a->config.confirm_ms)return;
    if(a->active_ready && a->active->reference_hz==a->desired_hz)return;
    const hil_profile_t *p=hil_profile_for_frequency(a->desired_hz);
    pl_fine_configuration_t cfg;
    if(!p || engineering_configuration_for_profile(p,&cfg) ||
       pl_fine_control_begin(&cfg,ENGINEERING_EPOCH_BASE)){fault(a,-15);return;}
    a->target=p;a->visible=0;a->state=AP_SWITCHING;
}
