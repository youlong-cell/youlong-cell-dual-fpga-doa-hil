/* miniDP DOA main view. Pure PS renderer, independent of acquisition/control.
 * Final numbers come ONLY from the ACKed immutable ABI1 packet. */
#include "lcd_doa.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

/* Definitions live in main.c/display_draw_safe.h. Do not include that
 * implementation twice: every primitive here uses its existing clipping. */
void lcd_draw_rect(uint8_t *, uint32_t, int64_t, int64_t, int64_t, int64_t,
                   uint8_t, uint8_t, uint8_t);
void lcd_draw_hline(uint8_t *, uint32_t, int64_t, int64_t, int64_t,
                    uint8_t, uint8_t, uint8_t);
void lcd_draw_vline(uint8_t *, uint32_t, int64_t, int64_t, int64_t,
                    uint8_t, uint8_t, uint8_t);
void lcd_draw_line(uint8_t *, uint32_t, int, int, int, int,
                   uint8_t, uint8_t, uint8_t);
void lcd_draw_text(uint8_t *, uint32_t, int64_t, int64_t, const char *,
                   uint8_t, uint8_t, uint8_t, int);

#define PHASE_UNIT (INT64_C(1) << 35)
#define THETA_LIMIT (INT64_C(1) << 34)
#define UFIELD(p,n) pl_fine_bits((p), PL_##n##_BIT, PL_##n##_WIDTH)
#define SFIELD(p,n) pl_fine_signed((p), PL_##n##_BIT, PL_##n##_WIDTH)

static void format_phase(char *out, size_t capacity, int64_t code)
{
    /* Valid S36 values fit signed int64 after *180000. Display truncation
     * toward zero also avoids showing +180 for a code just below +pi. */
    uint64_t magnitude = (uint64_t)(code < 0 ? -code : code);
    uint64_t mdeg = magnitude * UINT64_C(180000) / PHASE_UNIT;
    snprintf(out, capacity, "%s%llu.%03llu deg", code < 0 ? "-" : "+",
             (unsigned long long)(mdeg/1000), (unsigned long long)(mdeg%1000));
}

static const char *argument_reason(unsigned status)
{
    switch (status) {
    case 1: return "UNCALIBRATED";
    case 2: return "INVALID FREQUENCY";
    case 3: return "INVALID PHASE";
    case 4: return "INVALID GEOMETRY";
    case 5: return "SPATIAL AMBIGUITY";
    case 6: return "ASIN DOMAIN";
    case 8: return "GEOMETRY BOUNDARY UNCERTAIN";
    case 9: return "GEOMETRY NUMERIC RANGE";
    case 10: return "PHASE BOUNDARY UNCERTAIN";
    default: return "UNRECOGNIZED DOA STATUS";
    }
}

static const char *interpolation_reason(unsigned status)
{
    /* fine_three_bin_interpolator.sv numeric status, not the PS Fine enum. */
    switch(status) {
    case 1: return "INTERPOLATION NOT CONFIGURED";
    case 2: return "INTERPOLATION INVALID SCORE";
    case 3: return "CENTER NOT LOCAL MAXIMUM";
    case 4: return "LOW PEAK PROMINENCE";
    case 5: return "NONNEGATIVE CURVATURE";
    case 6: return "WEAK CURVATURE";
    case 7: return "DELTA OUT OF RANGE";
    case 8: return "FREQUENCY / META RANGE";
    case 9: return "INTERPOLATION CONFIG BUDGET";
    default: return "THREE-BIN / CONFIG INVALID";
    }
}

void lcd_doa_model(const doa_framebuffer_t *surface,
                   const doa_published_result_t *doa, doa_render_model_t *m)
{
    const pl_fine_packet_t *p;
    unsigned stage, status, fine, cal, theta;
    uint64_t mhz_units;
    if (!m) return;
    memset(m, 0, sizeof(*m));
    strcpy(m->angle, "---"); strcpy(m->raw_phase, "---");
    strcpy(m->cal_phase, "---"); strcpy(m->frequency, "---");
    strcpy(m->state, "NOT READY"); strcpy(m->age, "RESULT AGE ---");
    if (!doa || !doa->available) {
        if (doa && doa->view_state == DOA_VIEW_FAULT) {
            strcpy(m->state, "FAULT");
            snprintf(m->reason, sizeof(m->reason), "SOFTWARE PROTOCOL FAULT / reason %u",
                     (unsigned)doa->invalidation_reason);
        }
        return;
    }
    p = &doa->packet;
    fine = (unsigned)UFIELD(p,FINE_NUMERIC_VALID);
    cal = (unsigned)UFIELD(p,CALIBRATED_VALID);
    theta = (unsigned)UFIELD(p,THETA_VALID);
    stage = (unsigned)UFIELD(p,STATUS_STAGE);
    status = (unsigned)UFIELD(p,STATUS);
    m->theta_code = SFIELD(p,THETA);
    m->frequency_code = UFIELD(p,F_HAT_HZ);
    /* Invalid interpolation can carry zero/stale diagnostic numbers: don't
     * pretend they are a valid target. Later calibration/geometry invalid
     * results may still have a valid Fine frequency and raw phase. */
    m->target_valid = fine && m->frequency_code != 0;
    if (m->target_valid) {
        /* U49/F24 -> micro-MHz: bounded product <2^59, no float printf. */
        mhz_units = (m->frequency_code + (UINT64_C(1)<<23)) >> 24;
        snprintf(m->frequency, sizeof(m->frequency), "%llu.%06llu MHz",
                 (unsigned long long)(mhz_units/1000000),
                 (unsigned long long)(mhz_units%1000000));
    }
    if (fine) format_phase(m->raw_phase, sizeof(m->raw_phase), SFIELD(p,PHASE_RAW));
    if (cal) format_phase(m->cal_phase, sizeof(m->cal_phase), SFIELD(p,PHASE_CAL));
    strcpy(m->state, "INVALID");
    if (theta && m->theta_code >= -THETA_LIMIT && m->theta_code <= THETA_LIMIT) {
        strcpy(m->state, "VALID");
        format_phase(m->angle, sizeof(m->angle), m->theta_code);
        m->pointer_valid = 1;
        /* Linear direction ruler: -90=48, 0=368, +90=688. No invalid clamp. */
        m->pointer_x = 368 + (int)((m->theta_code * 320) / THETA_LIMIT);
    } else if (theta) {
        strcpy(m->reason, "UI THETA CODE OUT OF RANGE (NO CLAMP)");
    } else if (stage == 5) {
        snprintf(m->reason, sizeof(m->reason), "%s / S%u C%u", argument_reason(status), stage, status);
    } else if (fine && !cal) {
        unsigned cs = (unsigned)UFIELD(p,CALIBRATION_STATUS);
        const char *r = cs==0 ? "CALIBRATION NOT CONFIGURED" :
                        cs==2 ? "CALIBRATION CONFIG INVALID" :
                        cs==3 ? "CALIBRATION FREQUENCY RANGE" : "CALIBRATION INVALID";
        snprintf(m->reason, sizeof(m->reason), "%s / CAL%u S%u C%u", r, cs, stage, status);
    } else {
        unsigned interpolation=(unsigned)UFIELD(p,INTERPOLATION_STATUS);
        const char *r = stage==1 ? (status==0x90 ? "FINE CONFIG INVALID" : interpolation_reason(interpolation)) :
                        stage==2 ? "FINE 4K INVALID" :
                        stage==3 ? "CROSS PHASE INVALID" : "NUMERIC INVALID";
        snprintf(m->reason, sizeof(m->reason), "%s / S%u C%u I%u", r, stage, status,
                 interpolation);
    }
    if (surface && surface->result_age_valid) {
        m->stale = surface->result_age_ms > surface->stale_after_ms;
        snprintf(m->age, sizeof(m->age), "RESULT AGE %llu ms%s",
                 (unsigned long long)surface->result_age_ms, m->stale ? "  STALE" : "");
    }
}

void spectrum_view_age(spectrum_view_snapshot_t *s, XTime now)
{
    uint64_t diff, seconds;
    if (!s) return;
    s->age_valid = 0; s->age_ms = 0;
    if (!s->available || now < s->received_time) return;
    diff = now - s->received_time; seconds = diff / COUNTS_PER_SECOND;
    if (seconds > UINT64_MAX/1000) return;
    s->age_ms = seconds*1000 + (diff%COUNTS_PER_SECOND)*1000/COUNTS_PER_SECOND;
    s->age_valid = 1;
}

static void text(const doa_framebuffer_t *s, int x, int y, const char *t, int size,
                 uint8_t r, uint8_t g, uint8_t b)
{ lcd_draw_text(s->pixels, s->stride, x, y, t, r,g,b,size); }

void lcd_draw_doa(const doa_framebuffer_t *s, const doa_published_result_t *doa,
                  const spectrum_view_snapshot_t *spec)
{
    doa_render_model_t m;
    char buf[112];
    const int px=776, py=146, pw=472, ph=396;
    unsigned c, k;
    if (!s || !s->pixels || s->stride != 5120U) return;
    lcd_doa_model(s, doa, &m);
    /* Always repaint the whole leased frame: INVALID cannot retain a ray. */
    lcd_draw_rect(s->pixels,s->stride,0,0,1280,720,10,17,29);
    lcd_draw_rect(s->pixels,s->stride,24,80,712,574,17,29,45);
    lcd_draw_rect(s->pixels,s->stride,760,80,496,574,17,29,45);
    text(s,32,24,"SPECTRUM + DOA TERMINAL",3,224,236,255);
    text(s,32,98,"FINAL PL DOA / CH1 - CH0",2,119,200,242);
    snprintf(buf,sizeof(buf),"DOA %s",m.angle); text(s,48,144,buf,5,239,247,255);
    snprintf(buf,sizeof(buf),"STATUS %s%s",m.state,m.stale ? " / STALE" : "");
    text(s,48,206,buf,3,m.pointer_valid?93:255,m.pointer_valid?227:160,130);
    text(s,48,248,m.reason,1,255,180,125);
    text(s,48,280,"DIRECTION  -90 ... 0 ... +90 deg",2,173,190,212);
    lcd_draw_hline(s->pixels,s->stride,48,688,338,83,106,135);
    for(k=0;k<=6;k++) lcd_draw_vline(s->pixels,s->stride,48+(int)k*640/6,330,346,83,106,135);
    text(s,48,358,"-90",2,173,190,212); text(s,356,358,"0",2,173,190,212);
    text(s,648,358,"+90",2,173,190,212);
    if(m.pointer_valid) {
        lcd_draw_vline(s->pixels,s->stride,m.pointer_x,308,344,80,234,180);
        lcd_draw_line(s->pixels,s->stride,m.pointer_x,308,m.pointer_x-7,320,80,234,180);
        lcd_draw_line(s->pixels,s->stride,m.pointer_x,308,m.pointer_x+7,320,80,234,180);
    }
    snprintf(buf,sizeof(buf),"F_HAT      %s",m.frequency); text(s,48,400,buf,2,223,237,253);
    snprintf(buf,sizeof(buf),"RAW PHASE  %s",m.raw_phase); text(s,48,438,buf,2,223,237,253);
    snprintf(buf,sizeof(buf),"CAL PHASE  %s",m.cal_phase); text(s,48,476,buf,2,223,237,253);
    text(s,48,514,m.age,2,m.stale?255:150,m.stale?185:185,150);
    if(doa && doa->available) {
        const pl_fine_packet_t *p=&doa->packet;
        snprintf(buf,sizeof(buf),"EPOCH %llu  CAND %lu  CFG %lu",
                 (unsigned long long)doa->identity.session_epoch,
                 (unsigned long)doa->identity.candidate_seq,(unsigned long)doa->identity.config_version);
        text(s,48,558,buf,1,149,166,190);
        snprintf(buf,sizeof(buf),"DOA FRAME %lu / PROFILE %lu / GEO %lu",
                 (unsigned long)UFIELD(p,FRAME_SEQ),(unsigned long)doa->identity.calibration_profile_id,
                 (unsigned long)doa->identity.geometry_id); text(s,48,580,buf,1,149,166,190);
        snprintf(buf,sizeof(buf),"ENDPOINT %u  NEAR ENDFIRE %u  DOMAIN CLAMPED %u",
                 (unsigned)UFIELD(p,THETA_ENDPOINT_SNAPPED),(unsigned)UFIELD(p,NEAR_ENDFIRE),
                 (unsigned)UFIELD(p,DOMAIN_CLAMPED)); text(s,48,606,buf,1,149,166,190);
    }
    text(s,776,98,"LIVE FFT SPECTRUM",2,119,200,242);
    text(s,776,124,"CH0 cyan / CH1 amber / -120..0 dBFS",1,173,190,212);
    for(k=0;k<=4;k++) {
        lcd_draw_hline(s->pixels,s->stride,px,px+pw,py+(int)k*ph/4,44,60,80);
        lcd_draw_vline(s->pixels,s->stride,px+(int)k*pw/4,py,py+ph,44,60,80);
    }
    if(spec && spec->available && isfinite(spec->ch[0].fs) && spec->ch[0].fs>0) {
        for(c=0;c<2;c++) {
            int last_x=0,last_y=0,last_ok=0;
            for(k=0;k<FFT_BINS;k++) {
                float db=spec->ch[c].mag_db[k];
                int x=px+(int)k*pw/(FFT_BINS-1), y;
                if(!isfinite(db)) { last_ok=0; continue; }
                /* Plot clipping is visual only; no modification of samples. */
                if(db>0) db=0;
                if(db< -120) db=-120;
                y=py+(int)((-db)*(float)ph/120.0f);
                if(last_ok) lcd_draw_line(s->pixels,s->stride,last_x,last_y,x,y,
                                          c?255:80,c?181:219,c?86:250);
                last_x=x; last_y=y; last_ok=1;
            }
        }
        if(m.target_valid) {
            double hz=(double)m.frequency_code/16777216.0;
            double max_hz=(double)spec->ch[0].fs*(FFT_BINS-1)/FFT_SIZE;
            if(hz<=max_hz) {
                int x=px+(int)(hz*pw/max_hz);
                lcd_draw_vline(s->pixels,s->stride,x,py,py+ph,100,240,171);
                text(s,776,552,"TARGET = FINAL F_HAT (not FFT peak)",1,100,240,171);
            } else text(s,776,552,"FINAL F_HAT OUTSIDE SPECTRUM SPAN",1,255,180,125);
        }
        /* Integer formatting only: target floating printf was unreliable. */
        {
            unsigned long long khz=(unsigned long long)((double)spec->ch[0].fs*(FFT_BINS-1)/FFT_SIZE/1000.0+0.5);
            snprintf(buf,sizeof(buf),"0 Hz                  %llu.%03llu MHz",khz/1000,khz%1000);
        }
        text(s,776,566,buf,1,173,190,212);
        if(spec->metadata_valid) snprintf(buf,sizeof(buf),"SPEC FRAME %lu / independent of DOA",
                                         (unsigned long)spec->metadata.sequence);
        else strcpy(buf,"SPEC FRAME UNKNOWN / legacy FFT export");
        text(s,776,588,buf,1,173,190,212);
        if(spec->age_valid) snprintf(buf,sizeof(buf),"SPEC AGE %llu ms",(unsigned long long)spec->age_ms);
        else strcpy(buf,"SPEC AGE ---");
        text(s,776,610,buf,1,173,190,212);
    } else text(s,840,320,"SPEC NOT READY",2,173,190,212);
    text(s,32,678,"[KEY1] DOA / WAVE / FULL BAR / FULL TRACE / ZOOM BAR / ZOOM TRACE",2,133,157,186);
}
