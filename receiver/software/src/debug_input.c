#include <string.h>
#include <stdio.h>
#include <math.h>
#include <limits.h>
#include "debug_input.h"
#include "hardware/sample_clock.h"

/* Provisional, user-configurable diagnostic policy. DC and one adjacent
 * Hann leakage bin are masked; Nyquist is not exported; last boundary bin
 * is excluded. Do not confuse these settings with production thresholds. */
const debug_input_config_t debug_input_default_config = {2, FFT_BINS-2, 2.0, -60.0f, 12.0f};

int debug_adc_measure(const uint16_t *raw, size_t count, debug_adc_metrics_t *out)
{
    size_t i; uint64_t sum=0, squares=0; double variance, rms;
    if(!out)return 0;
    memset(out,0,sizeof *out);
    if(!raw || !count || count>4096)return 0;
    out->min=4095;
    for(i=0;i<count;i++) {
        uint16_t v=raw[i];
        if(v>4095){memset(out,0,sizeof *out);return 0;}
        if(v<out->min)out->min=v;
        if(v>out->max)out->max=v;
        sum+=v; squares+=(uint64_t)v*v;
        if(v==0 || v==4095)out->rail_count++;
    }
    /* N*sum(x^2)-sum(x)^2 is exact and nonnegative in uint64 at N<=4096.
     * Subtract the measured mean, not the nominal midscale 2048. */
    variance=(double)((uint64_t)count*squares-sum*sum)/((double)count*count);
    rms=sqrt(variance);
    out->mean=(uint32_t)(sum/count);
    out->rms_millicodes=(uint32_t)floor(rms*1000.0+0.5);
    out->count=count;out->valid=1;
    return 1;
}

void debug_peak_measure(const spectrum_t *s, const debug_input_config_t *cfg, debug_peak_t *p)
{
    unsigned k, first, last, floor_bins=0; double background=0;
    if(!p)return;
    memset(p,0,sizeof *p);
    if(!s || !cfg || !isfinite(s->fs) || s->fs<=0 || cfg->bin_min>cfg->bin_max)return;
    first=cfg->bin_min<1?1:cfg->bin_min;
    last=cfg->bin_max>=FFT_BINS?FFT_BINS-1:cfg->bin_max;
    for(k=first;k<=last && k<FFT_BINS;k++) {
        float db=s->mag_db[k], f=s->freq[k];
        if(!isfinite(db) || db>120 || !isfinite(f) || f<=0 || f>=s->fs*0.5f || db<=SPEC_DB_FLOOR)continue;
        p->valid_bins++;
        if(!p->valid || db>p->dbfs){p->valid=1;p->bin=k;p->dbfs=db;}
    }
    if(!p->valid)return; /* A floor-only frame has no artificial bin-1 peak. */
    /* Mean log background excluding the peak and its +/-2-bin Hann lobe.
     * Valid floor bins participate, invalid/NaN bins do not. */
    for(k=first;k<=last && k<FFT_BINS;k++) {
        float db=s->mag_db[k], f=s->freq[k];
        if(!isfinite(db) || db>120 || !isfinite(f) || f<=0 || f>=s->fs*0.5f)continue;
        if(k+2>=p->bin && k<=p->bin+2)continue;
        background+=db<SPEC_DB_FLOOR?SPEC_DB_FLOOR:db;floor_bins++;
    }
    p->prominence_db=floor_bins?p->dbfs-(float)(background/floor_bins):0;
    /* Authoritative Fs, not floating-point printf or a rounded 62.5 MHz. */
    p->hz=((uint64_t)p->bin*ADC_SAMPLE_RATE_HZ+FFT_SIZE/2)/FFT_SIZE;
    p->dbfs_milli=(int32_t)llround((double)p->dbfs*1000.0);
    p->prominence_milli=(int32_t)llround((double)p->prominence_db*1000.0);
}

debug_input_state_t debug_input_classify(int adc_fresh,int fft_fresh,uint32_t rms,
    int overflow,const debug_peak_t *p,const debug_input_config_t *cfg)
{
    if(!adc_fresh || !fft_fresh || overflow || !p || !cfg)return INPUT_NOT_READY;
    if((double)rms<=cfg->no_signal_rms_codes*1000.0)return INPUT_NO_SIGNAL;
    if(p->valid && p->dbfs>=cfg->min_peak_dbfs && p->prominence_db>=cfg->min_prominence_db)
        return INPUT_SIGNAL_DETECTED;
    return INPUT_NOISE_ONLY; /* No prominent tone detected; not proof of noise. */
}
debug_input_state_t debug_input_pair(debug_input_state_t a,debug_input_state_t b)
{
    if(a==INPUT_SIGNAL_DETECTED || b==INPUT_SIGNAL_DETECTED)return INPUT_SIGNAL_DETECTED;
    if(a==INPUT_NOT_READY || b==INPUT_NOT_READY)return INPUT_NOT_READY;
    if(a==INPUT_NOISE_ONLY || b==INPUT_NOISE_ONLY)return INPUT_NOISE_ONLY;
    return INPUT_NO_SIGNAL;
}
const char *debug_input_name(debug_input_state_t s)
{
    switch(s){case INPUT_NO_SIGNAL:return "NO SIGNAL";
    case INPUT_NOISE_ONLY:return "NOISE ONLY";
    case INPUT_SIGNAL_DETECTED:return "SIGNAL DETECTED";
    default:return "NOT READY";}
}
void debug_format_milli(char *out,size_t cap,int64_t v)
{
    uint64_t a=v<0?(uint64_t)(-(v+1))+1:(uint64_t)v;
    if(!out || !cap)return;
    snprintf(out,cap,"%s%llu.%03llu",v<0?"-":"",
             (unsigned long long)(a/1000),(unsigned long long)(a%1000));
}
