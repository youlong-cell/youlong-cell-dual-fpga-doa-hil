/* UI only: arithmetic-power mean -> calibrated dBFS -> gate -> display EMA.
 * Never feeds detector, peak diagnosis, phase, Fine or DOA. */
#include <string.h>
#include <math.h>
#include "spectrum_display_filter.h"

const spectrum_display_config_t spectrum_display_default_config={
    SPECTRUM_UI_NOISE_FLOOR_DBFS,6.0f,0.85f,10.0f,2,FFT_BINS-2};
/* Same unscaled FFT/Hann coherent-gain normalization as the existing UI.
 * Frozen 1024-point Q15 Hann ROM sum. Averaging occurs BEFORE log/clipping. */
#define UI_HANN_SUM (16760324.0 / 32768.0)
#define UI_FULL_SCALE 2048.0
static void clear_history(spectrum_display_filter_t *f)
{
    memset(f->sum,0,sizeof f->sum);
    f->count=f->next_slot=f->average_valid=f->display_valid=0;
    f->stats.before_last_db=f->stats.after_last_db=0;
    f->stats.resets++;
}
int spectrum_display_init(spectrum_display_filter_t *f,const spectrum_display_config_t *c)
{
    if(!f || !c || !isfinite(c->noise_floor_dbfs) || c->noise_floor_dbfs < -300 ||
       c->noise_floor_dbfs>0 || !isfinite(c->gate_margin_db) || c->gate_margin_db<0 ||
       !isfinite(c->ema_old_weight) || c->ema_old_weight<0 || c->ema_old_weight>=1 ||
       !isfinite(c->fast_rise_db) || c->fast_rise_db<=0 ||
       c->first_bin<1 || c->first_bin>c->last_bin || c->last_bin>=FFT_BINS)return 0;
    memset(f,0,sizeof *f);f->config=*c;return 1;
}
void spectrum_display_reset(spectrum_display_filter_t *f)
{if(f){clear_history(f);f->stage_valid=f->staged_bins=0;}}
void spectrum_display_stage_bin(spectrum_display_filter_t *f,u32 seq,float fs,
                               unsigned k,s32 re0,s32 im0,s32 re1,s32 im1)
{
    if(!f || k>=FFT_BINS)return;
    if(k==0){f->staged_bins=0;f->stage_valid=0;f->staged_sequence=seq;f->staged_fs=fs;}
    if(k!=f->staged_bins || seq!=f->staged_sequence || fs!=f->staged_fs){
        f->stage_valid=0;f->staged_bins=FFT_BINS+1;return;
    }
    f->staged_power[0][k]=(double)re0*re0+(double)im0*im0;
    f->staged_power[1][k]=(double)re1*re1+(double)im1*im1;
    if(++f->staged_bins==FFT_BINS)f->stage_valid=1;
}
int spectrum_display_accept(spectrum_display_filter_t *f,const spectrum_view_snapshot_t *raw)
{
    if(!f || !raw)return 0;
    if(!raw->available || !raw->metadata_valid || !f->stage_valid ||
       raw->metadata.sequence!=f->staged_sequence || !isfinite(f->staged_fs) ||
       f->staged_fs<=0 || raw->ch[0].fs!=f->staged_fs || raw->ch[1].fs!=f->staged_fs){
        f->stats.rejected_frames++;return 0;
    }
    /* Do not count repeated UI refreshes or duplicate frame publications as FFT frames. */
    if(f->average_valid && (s32)(raw->metadata.sequence-f->committed_sequence)<=0){
        f->stats.rejected_frames++;return 0;
    }
    if(f->average_valid && (f->fs!=f->staged_fs || raw->received_time<f->last_receive ||
       raw->received_time-f->last_receive>(XTime)(COUNTS_PER_SECOND*3ULL/10ULL)))
        clear_history(f);
    unsigned full=f->count==SPECTRUM_UI_AVERAGE_FRAMES;
    if(!full)f->count++;
    const double gain=2.0/(UI_HANN_SUM*UI_FULL_SCALE);
    for(unsigned c=0;c<2;c++)for(unsigned k=0;k<FFT_BINS;k++){
        double p=f->staged_power[c][k];
        f->history[f->next_slot][c][k]=p;
        /* Bounded eight-term sum avoids cancellation when a loud frame exits
         * the window. It does not average clipped dB or zero-fill warmup. */
        double total=0;
        for(unsigned j=0;j<f->count;j++)total+=f->history[j][c][k];
        f->sum[c][k]=total;
        double normalized=f->sum[c][k]/f->count*gain*gain;
        float db=normalized>0?(float)(10.0*log10(normalized)):f->config.noise_floor_dbfs;
        if(k<f->config.first_bin || k>f->config.last_bin ||
           db<f->config.noise_floor_dbfs+f->config.gate_margin_db){
            db=f->config.noise_floor_dbfs;f->stats.gated_bins++;
        }
        f->average_db[c][k]=db;
    }
    f->next_slot=(f->next_slot+1)%SPECTRUM_UI_AVERAGE_FRAMES;
    f->committed_sequence=raw->metadata.sequence;f->fs=f->staged_fs;
    f->last_receive=raw->received_time;f->stage_valid=0;f->average_valid=1;
    f->stats.accepted_frames++;return 1;
}
int spectrum_display_prepare(const spectrum_display_filter_t *f,
                             const spectrum_view_snapshot_t *raw,spectrum_view_snapshot_t *out)
{
    if(!f || !raw || !out || out==raw)return 0;
    *out=*raw;
    if(!raw->available || !raw->metadata_valid || !f->average_valid ||
       raw->metadata.sequence!=f->committed_sequence){out->available=0;return 0;}
    for(unsigned c=0;c<2;c++){
        out->ch[c].max_mag_db=-INFINITY;out->ch[c].min_mag_db=INFINITY;
        for(unsigned k=0;k<FFT_BINS;k++){
            float db=f->average_db[c][k],old=f->previous_display[c][k];
            if(f->display_valid && !(db>old+f->config.fast_rise_db))
                db=f->config.ema_old_weight*old+(1.0f-f->config.ema_old_weight)*db;
            out->ch[c].mag_db[k]=db;
            if(db>out->ch[c].max_mag_db)out->ch[c].max_mag_db=db;
            if(db<out->ch[c].min_mag_db)out->ch[c].min_mag_db=db;
        }
    }
    return 1;
}
void spectrum_display_commit(spectrum_display_filter_t *f,const spectrum_view_snapshot_t *raw,
                             const spectrum_view_snapshot_t *out)
{
    if(!f || !raw || !out || !out->available || !raw->available || !f->average_valid ||
       raw->metadata.sequence!=f->committed_sequence ||
       out->metadata.sequence!=raw->metadata.sequence)return;
    float before=0,after=0;
    for(unsigned c=0;c<2;c++)for(unsigned k=0;k<FFT_BINS;k++){
        if(f->display_valid && k>=f->config.first_bin && k<=f->config.last_bin){
            float a=fabsf(raw->ch[c].mag_db[k]-f->previous_raw[c][k]);
            float b=fabsf(out->ch[c].mag_db[k]-f->previous_display[c][k]);
            if(isfinite(a)&&a>before)before=a;
            if(isfinite(b)&&b>after)after=b;
            if(f->average_db[c][k]>f->previous_display[c][k]+f->config.fast_rise_db)
                f->stats.fast_rises++;
        }
        f->previous_raw[c][k]=raw->ch[c].mag_db[k];
        f->previous_display[c][k]=out->ch[c].mag_db[k];
    }
    if(f->display_valid){
        f->stats.compared_frames++;f->stats.before_last_db=before;f->stats.after_last_db=after;
        if(before>f->stats.before_max_db)f->stats.before_max_db=before;
        if(after>f->stats.after_max_db)f->stats.after_max_db=after;
    }
    f->display_valid=1;f->stats.submitted_frames++;
}
