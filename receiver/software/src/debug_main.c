/* ENGINEERING_TEST / NOT_SIGNED_OFF, SD cold boot integrated diagnostic.
 * Display remains independent of sample completion and Fine admission.
 * Explicit volatile ENGINEERING_SESSION. No QSPI/SD writes or PS Fine fallback.
 */
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include "xparameters.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_mmu.h"
#include "xscugic.h"
#include "xaxidma.h"
#include "xaxidma_hw.h"
#include "xuartps_hw.h"
#include "xtime_l.h"
#include "debug_ui.h"
#include "debug_mmio.h"
#include "hardware/sample_clock.h"
#include "adc_g2_metrics.h"
#include "service_profile.h"
#include "spectrum_display_filter.h"
#include "ui1920.h"
#include "auto_profile.h"
#define N 1920U
#define ADC_STATUS 8U
#define ADC_DROP 12U
static XScuGic gic;
static DisplayCtrl display;
/* Large buffers are linker-owned .bss, aligned and outside FSBL scratch.
 * DMA-owned raw buffers are never written by CPU while inflight. */
static u8 frames[3][DISPLAY_FRAME_SIZE] __attribute__((aligned(256)));
static u16 dma_raw[2][N] __attribute__((aligned(64)));
static u16 copied_raw[2][N] __attribute__((aligned(64)));
static XAxiDma dma[2];
static unsigned dma_ready[2], done[2], inflight;
static u32 drop_before[2];
static XTime capture_start, last_capture, last_good_adc, next_draw, next_hotplug, next_log, previous_loop, next_key;
static XTime fps_start;static u32 fps_previous;
static const UINTPTR adc_base[2]={XPAR_AD9238_SAMPLE_0_S00_AXI_BASEADDR,XPAR_AD9238_SAMPLE_1_S00_AXI_BASEADDR};
static const u16 dma_id[2]={XPAR_AXIDMA_0_DEVICE_ID,XPAR_AXIDMA_1_DEVICE_ID};
static spectrum_view_snapshot_t spectrum_cache, render_spectrum;
static spectrum_view_snapshot_t display_spectrum;
static spectrum_display_filter_t display_filter;
static void display_power_tap(u32 seq,float fs,unsigned bin,s32 r0,s32 i0,s32 r1,s32 i1)
{spectrum_display_stage_bin(&display_filter,seq,fs,bin,r0,i0,r1,i1);}
static doa_published_result_t doa_cache;
static doa_published_result_t doa_ui_packet;
static doa_ui_ema_t doa_ui_filter;
static XTime doa_ui_number_due;
static debug_view_t view;
static auto_profile_t auto_receiver;
static int auto_initialized;
static u64 auto_next_probe_ms;
static int display_initialized, fine_initialized, spectrum_initialized, capture_enabled, fft_enabled;
static char uart_queue[8192];static unsigned uq_head, uq_tail;static u32 uart_dropped;
static XTime profile_next,profile_row_due;
static unsigned profile_row=SP_COUNT*2;
static sp_event_t trace_dump[80];static unsigned trace_dump_count,trace_dump_position,trace_dump_missing;
static sp_event_t profile_worst;static int profile_worst_pending;
static XTime now_ticks(void) {XTime t;XTime_GetTime(&t);return t;}
static u64 elapsed_us(XTime later,XTime earlier)
{return later>=earlier?(later-earlier)*1000000ULL/COUNTS_PER_SECOND:UINT64_MAX;}
static void log_line(const char *format,...)
{
    SP_SCOPE(p,SP_LOG,(uq_head+sizeof uart_queue-uq_tail)%sizeof uart_queue,0);
    char b[640];va_list args;int i,n;va_start(args,format);n=vsnprintf(b,sizeof b,format,args);va_end(args);
    if(n<0){sp_mark(&p,0,(uint32_t)n,0);return;}
    if(n>=(int)sizeof b)n=sizeof b-1;
    for(i=0;i<n;i++){unsigned next=(uq_head+1)%sizeof uart_queue;if(next==uq_tail){uart_dropped++;break;}uart_queue[uq_head]=b[i];uq_head=next;}
    sp_mark(&p,(uint32_t)i,uart_dropped,(uint64_t)n);
}
static void uart_service(void)
{
    SP_SCOPE(p,SP_UART_TX,(uq_head+sizeof uart_queue-uq_tail)%sizeof uart_queue,0);
    unsigned budget=96;
    while(budget-- && uq_tail!=uq_head && !XUartPs_IsTransmitFull(STDOUT_BASEADDRESS)) {
        Xil_Out32(STDOUT_BASEADDRESS+XUARTPS_FIFO_OFFSET,(u8)uart_queue[uq_tail]);
        uq_tail=(uq_tail+1)%sizeof uart_queue;
    }
}
static void ProfileInterruptHandler(void *reference)
{
    SP_IRQ_SCOPE(p,SP_GIC_IRQ,0,0);
    XScuGic_InterruptHandler(reference);
}
/* Keep vendor logs ordered with application logs, without blocking on TX.
 * Current DP IRQ path does not call xil_printf; queue writers are foreground. */
void outbyte(char c)
{
    unsigned next=(uq_head+1)%sizeof uart_queue;
    if(next==uq_tail){uart_dropped++;return;}
    uart_queue[uq_head]=c;uq_head=next;
}
static int interrupt_init(void)
{
    XScuGic_Config *cfg=XScuGic_LookupConfig(XPAR_SCUGIC_0_DEVICE_ID);int rc;
    if(!cfg)return XST_FAILURE;
    rc=XScuGic_CfgInitialize(&gic,cfg,cfg->CpuBaseAddress);if(rc)return rc;
    Xil_ExceptionInit();Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,(Xil_ExceptionHandler)ProfileInterruptHandler,&gic);
    Xil_ExceptionEnable();return 0;
}
/* Foreground presentation service only: copies the already ACK-published
 * object after fine_service, even on pages without DOA or without a FREE frame.
 * No new poll/ACK, FFT read, UART parser or measurement-side state changes. */
static void doa_ui_service(XTime t)
{
    doa_published_result_t p;
    doa_result_snapshot(&p);
    int adc_fresh=last_good_adc&&t>=last_good_adc&&elapsed_us(t,last_good_adc)/1000<=300;
    int spec_fresh=spectrum_cache.available&&t>=spectrum_cache.received_time&&
        elapsed_us(t,spectrum_cache.received_time)/1000<=300;
    debug_input_state_t input[2];
    for(unsigned c=0;c<2;c++)input[c]=debug_input_classify(adc_fresh&&view.adc[c]==DBG_OK,
        spec_fresh,view.rms_millicodes[c],(view.adc_status[c]&1U)!=0,&view.peak[c],&debug_input_default_config);
    const hil_profile_t *profile=hil_profile_current();
    int allowed=view.session_state==ENG_MEASURING&&(!auto_initialized||auto_receiver.visible)&&
        debug_input_pair(input[0],input[1])==INPUT_SIGNAL_DETECTED&&profile->geometry_valid&&profile->calibration_valid;
    if(p.available&&pl_fine_bits(&p.packet,PL_THETA_VALID_BIT,1))allowed=allowed&&
        p.identity.session_epoch==view.session_epoch&&p.identity.config_version==view.config_version&&
        p.identity.calibration_profile_id==profile->profile_id&&p.identity.geometry_id==profile->geometry_id;
    uint64_t steps=doa_ui_filter.step_resets;
    (void)doa_ui_ema_update(&doa_ui_filter,&p,t,allowed);
    int context_changed=view.doa_angles.available&&doa_ui_filter.value.available&&
        (view.doa_angles.identity.session_epoch!=doa_ui_filter.value.identity.session_epoch||
         view.doa_angles.identity.config_version!=doa_ui_filter.value.identity.config_version||
         view.doa_angles.identity.calibration_profile_id!=doa_ui_filter.value.identity.calibration_profile_id||
         view.doa_angles.identity.geometry_id!=doa_ui_filter.value.identity.geometry_id);
    if(!doa_ui_filter.value.available||!view.doa_angles.available||context_changed||
       steps!=doa_ui_filter.step_resets||t>=doa_ui_number_due){
        /* Pair is latched atomically in foreground; both numbers name the same
         * latest accepted candidate. Invalidations bypass the 100ms deadline. */
        doa_ui_packet=p;if(!allowed)doa_ui_packet.available=0;
        view.doa_angles=doa_ui_filter.value;
        doa_ui_number_due=t+COUNTS_PER_SECOND*DOA_UI_NUMBER_PERIOD_MS/1000;
    }
}
static void draw_once(void)
{
    DisplayDrawFrame draw;XTime start=now_ticks();int rc;u64 span;
    if(!display_initialized || display.state!=DISPLAY_RUNNING)return;
    /* Single-outstanding presenter cannot accept a second frame yet.
     * Skip expensive redraw, never touch its pending/scanning pixels. */
    if(display.pendingFrame>=0){view.no_buffer++;return;}
    if(display_acquire_draw_frame(&display,&draw)) {view.no_buffer++;return;}
    view.uptime_ms=elapsed_us(start,0)/1000;
    view.atb_status=debug_atb_status();view.bus_fault_address=debug_fault_address();
    render_spectrum=spectrum_cache;spectrum_view_age(&render_spectrum,start);
    view.spectrum_fresh=render_spectrum.available && render_spectrum.age_valid && render_spectrum.age_ms<=300;
    if(!view.spectrum_fresh){
        render_spectrum.available=0;
        if(display_filter.average_valid || display_filter.stage_valid)spectrum_display_reset(&display_filter);
    }
    view.adc_fresh=last_good_adc && elapsed_us(start,last_good_adc)<=300000;
    for(unsigned c=0;c<2;c++)view.input[c]=debug_input_classify(
        view.adc_fresh && view.adc[c]==DBG_OK, view.spectrum_fresh,
        view.rms_millicodes[c], (view.adc_status[c]&1U)!=0,
        &view.peak[c],&debug_input_default_config);
    view.input_pair=debug_input_pair(view.input[0],view.input[1]);
    doa_cache=doa_ui_packet; /* 10Hz coherent display pair, not a new consumer */
    if(auto_initialized && !auto_receiver.visible)doa_cache.available=0;
    view.result_fresh=doa_result_age_ms(&doa_cache,&view.result_age_ms)==1 && view.result_age_ms<=300;
    {SP_SCOPE(p,SP_UI_SPECTRUM,display_filter.count,render_spectrum.view_seq);
     spectrum_display_prepare(&display_filter,&render_spectrum,&display_spectrum);}
    {SP_SCOPE(p,SP_UI_DRAW,display.state,view.capture_seq);
     XTime renderer_start=now_ticks();
     debug_draw(draw.pixels,&view,&display_spectrum,&doa_cache,copied_raw);
     view.renderer_last_us=elapsed_us(now_ticks(),renderer_start);
     if(view.renderer_last_us>view.renderer_max_us)view.renderer_max_us=view.renderer_last_us;
     if(view.renderer_last_us>UI_DRAW_LIMIT_US&&!view.ui_low_detail){
       view.ui_low_detail=1;
       log_line("[UI_BUDGET] renderer=%llu us >16000; reduce grid and system text, algorithms unchanged\r\n",(unsigned long long)view.renderer_last_us);
     }}
    rc=display_present_frame(&display,&draw);
    if(rc){view.present_fail++;display_cancel_draw_frame(&display,&draw);}else{
        view.drawn++;
        spectrum_display_commit(&display_filter,&render_spectrum,&display_spectrum);
    }
    span=elapsed_us(now_ticks(),start);if(span>view.draw_max_us)view.draw_max_us=span;
}
static void stop_checked(void)
{
    SP_SCOPE(p,SP_FINE_STOP,view.stop,view.lifecycle);
    u32 w=0;int rc;
    capture_enabled=0;fft_enabled=0;spectrum_cache.available=0;
    view.session_state=ENG_CLOSED;
    spectrum_display_reset(&display_filter);
    doa_result_invalidate(DOA_INVALIDATION_STOP);doa_result_snapshot(&doa_cache);
    if(!debug_pl_bus_ok() || !fine_initialized) {view.stop=DBG_ERROR;view.stop_rc=-999;return;}
    rc=pl_fine_stop();view.stop_rc=rc;
    if(rc || !debug_pl_bus_ok()) {view.stop=DBG_ERROR;return;}
    {SP_SCOPE(q,SP_SESSION_CONFIG,0,0);rc=pl_fine_status(0,&w);sp_mark(&q,0,(uint32_t)rc,w);}view.lifecycle=w;
    if(rc || (w>>16)!=0xF101 || (w&0xFF00U) || (w&0xFBU)!=0x40U || !debug_pl_bus_ok()) {
        view.stop=DBG_ERROR;view.stop_rc=rc?rc:-998;return;
    }
    /* Independent second command / completion, not cached observation. */
    {SP_SCOPE(q,SP_SESSION_CONFIG,0,1);rc=pl_fine_status(0,&w);sp_mark(&q,0,(uint32_t)rc,w);}view.lifecycle=w;
    if(rc || (w>>16)!=0xF101 || (w&0xFF00U) || (w&0xFBU)!=0x40U || !debug_pl_bus_ok()) {view.stop=DBG_ERROR;view.stop_rc=-997;return;}
    view.stop=DBG_OK;log_line("[STOP] real grant + two closed checks F101=%08lx; Fine CLOSED\r\n",(unsigned long)w);
}
static void fine_start_engineering(void)
{
    pl_fine_lifecycle_t ctx;int rc;
    if(!debug_pl_bus_ok() || !fine_initialized || !fft_enabled || view.stop!=DBG_OK){
        view.session_state=ENG_ERROR;view.fine_rc=-999;return;
    }
    view.session_state=ENG_STARTING;
    rc=engineering_session_start(&ctx);view.fine_rc=rc;
    if(rc || !debug_pl_bus_ok()){
        view.session_state=ENG_ERROR;
        doa_result_invalidate(DOA_INVALIDATION_PROTOCOL_FATAL);
        log_line("[ENG_SESSION] FAILED rc=%d; no replay; ADC/FFT/UI diagnostics continue\r\n",rc);return;
    }
    view.session_epoch=ctx.session_epoch;view.config_version=ctx.config_version;
    view.session_state=ENG_MEASURING;
    log_line("[ENG_SESSION] ENGINEERING_ONLY epoch=%016llx config=%lu PL_FINE 24+4 COMMIT ACK / traffic_ready confirmed\r\n",
        (unsigned long long)ctx.session_epoch,(unsigned long)ctx.config_version);
    const hil_profile_t *p=hil_profile_current();
    log_line("[PROFILE] GEO=%lu %s d=%lu mm c=%lu m/s valid=%u CAL=%lu bias=%s valid=%u measured=%u ENGINEERING_ONLY\r\n",
        (unsigned long)p->geometry_id,p->name,(unsigned long)p->d_mm,(unsigned long)p->c_mps,p->geometry_valid,
        (unsigned long)p->profile_id,p->bias_display,p->calibration_valid,p->measured);
    log_line("[CAL_SELECTION] %s ref=%lu Hz band=%lu..%lu Hz bias_pi_F35=%lld %s COMPILE_TIME / COLD_BOOT_ONLY\r\n",
        p->cal_name,(unsigned long)p->reference_hz,(unsigned long)p->minimum_hz,
        (unsigned long)p->maximum_hz,(long long)p->bias_pi_f35,p->evidence_state);
    log_line("[Fine] real 3-bin + 4K DFT + CH1-CH0 phase / ABI=1 34-word ACK-before-publish; ENGINEERING_ESTIMATE / UNCALIBRATED\r\n");
    log_line("[DETECTOR] bins=2..510 thresholds=5/5 score=10 (power>>16); Pmin=.25log2 Dmin=9003088/F28 provisional ENGINEERING_ONLY\r\n");
}
static void service_key_mode(XTime t)
{
    if(t<next_key)return;
    next_key=t+COUNTS_PER_SECOND/50; /* deadline, not blocking sleep */
    if(!debug_pl_bus_ok())return;
    u32 raw=Xil_In32((UINTPTR)XPAR_AXI_GPIO_MODE_BASEADDR);
    if(!debug_pl_bus_ok())return;
    view.key_mode_raw=raw;
    unsigned mode=raw&7U;
    if(mode>=6){view.key_mode_errors++;return;}
    if(mode!=view.key_mode_code || view.page!=debug_page_from_pl_mode(mode)){
        view.key_mode_code=mode;view.page=debug_page_from_pl_mode(mode);next_draw=t;
        log_line("[KEY1] PL code=%u UI=%s; RTL six-state encoding unchanged, KEY2 unused\r\n",mode,debug_page_name(view.page));
    }
}
static void fine_service(void)
{
    if(view.session_state!=ENG_MEASURING)return;
    int rc;
    if(!debug_pl_bus_ok())rc=DOA_RESULT_FENCED;
    else rc=doa_result_service(); /* independent of UI refresh and FFT bank reads */
    view.fine_rc=rc;
    if(rc<0){
        view.session_state=ENG_ERROR;
        doa_result_invalidate(DOA_INVALIDATION_PROTOCOL_FATAL);
        int stop_rc=debug_pl_bus_ok()?pl_fine_stop():-999;
        log_line("[Fine] ERROR service=%d driver=%d STOP=%d; no old result/no auto retry\r\n",
            rc,doa_result_last_driver_error(),stop_rc);
        if(auto_initialized){
            auto_receiver.state=AP_FAULT;auto_receiver.enabled=0;
            auto_receiver.visible=0;auto_receiver.error=rc;
        }
    }
    doa_result_counts_t counts;
    if(!doa_result_counts_snapshot(&counts)){
        view.fine_published=counts.published_count;view.fine_invalid=counts.invalid_count;
    }
}
static void dma_init_channels(void)
{
    unsigned c;capture_enabled=0;
    for(c=0;c<2;c++) {
        XAxiDma_Config *cfg=XAxiDma_LookupConfig(dma_id[c]);int rc;
        dma_ready[c]=0;view.dma[c]=DBG_NOT_INITIALIZED;
        if(!cfg || !debug_pl_bus_ok()){view.dma[c]=DBG_ERROR;continue;}
        {SP_SCOPE(p,c?SP_DMA_INIT1:SP_DMA_INIT0,0,cfg->BaseAddr);
         rc=XAxiDma_CfgInitialize(&dma[c],cfg);sp_mark(&p,0,(uint32_t)rc,cfg->BaseAddr);}
        if(rc || XAxiDma_HasSg(&dma[c]) || !debug_pl_bus_ok()){view.dma[c]=DBG_ERROR;log_line("[DMA%u] init rc=%d\r\n",c,rc);continue;}
        XAxiDma_IntrDisable(&dma[c],XAXIDMA_IRQ_ALL_MASK,XAXIDMA_DEVICE_TO_DMA);
        XAxiDma_IntrDisable(&dma[c],XAXIDMA_IRQ_ALL_MASK,XAXIDMA_DMA_TO_DEVICE);
        dma_ready[c]=1;view.dma[c]=DBG_NO_DATA;view.adc[c]=DBG_NO_DATA;
        log_line("[DMA%u] initialized, polled IOC/errors, base=%08lx\r\n",c,(unsigned long)dma[c].RegBase);
    }
    capture_enabled=dma_ready[0]&&dma_ready[1]&&view.stop==DBG_OK&&debug_pl_bus_ok();
}
static void dma_fault(unsigned c,int timeout)
{
    if(timeout)view.timeouts[c]++;else view.errors[c]++;
    view.dma[c]=DBG_ERROR;view.adc[c]=DBG_ERROR;
    view.rejected++;inflight=0;capture_enabled=0;last_good_adc=0;
    log_line("[DMA%u] %s SR=%08lx ADC=%08lx DROP=%lu capture=%lu; no buffer reuse, [r] explicit recovery\r\n",c,
        timeout?"TIMEOUT":"ERROR",(unsigned long)view.dma_status[c],(unsigned long)view.adc_status[c],
        (unsigned long)view.dropped[c],(unsigned long)view.capture_seq);
}
static void adc_service(XTime t)
{
    SP_SCOPE(p,SP_ADC,inflight | (capture_enabled<<1),view.capture_seq);
    unsigned c,k;
    if(!capture_enabled || !debug_pl_bus_ok())return;
    if(inflight) {
        for(c=0;c<2;c++) {
            SP_SCOPE(q,c?SP_DMA_CHECK1:SP_DMA_CHECK0,done[c],dma[c].RegBase);
            u32 sr=XAxiDma_ReadReg(dma[c].RegBase,XAXIDMA_RX_OFFSET+XAXIDMA_SR_OFFSET);
            view.dma_status[c]=sr;
            view.adc_status[c]=Xil_In32(adc_base[c]+ADC_STATUS);
            view.dropped[c]=Xil_In32(adc_base[c]+ADC_DROP);
            sp_mark(&q,done[c],sr,dma[c].RegBase);
            if(!debug_pl_bus_ok()){dma_fault(c,0);return;}
            if(sr & (XAXIDMA_ERR_ALL_MASK|XAXIDMA_IRQ_ERROR_MASK)) {dma_fault(c,0);return;}
            if(!done[c] && (sr & XAXIDMA_IRQ_IOC_MASK)) {
                XAxiDma_IntrAckIrq(&dma[c],XAXIDMA_IRQ_IOC_MASK,XAXIDMA_DEVICE_TO_DMA);
                done[c]=1;view.transfers[c]++;
            }
        }
        if(!done[0] || !done[1]) {
            if(elapsed_us(t,capture_start)>100000)dma_fault(!done[0]?0:1,1);
            return;
        }
        /* Overflow counter/sticky invalidates both channels. No phase claim. */
        if((view.adc_status[0]&1U)||(view.adc_status[1]&1U)||
           view.dropped[0]!=drop_before[0]||view.dropped[1]!=drop_before[1]) {dma_fault(0,0);return;}
        for(c=0;c<2;c++) {
            u64 sum=0;u16 lo=4095,hi=0;
            service_cache_invalidate((UINTPTR)dma_raw[c],sizeof dma_raw[c]);
            for(k=0;k<N;k++) {
                u16 raw=dma_raw[c][k];
                if(raw & 0xF000U){dma_fault(c,0);return;}
                copied_raw[c][k]=raw;if(raw<lo)lo=raw;if(raw>hi)hi=raw;sum+=raw;
            }
            view.min[c]=lo;view.max[c]=hi;view.mean[c]=(u32)(sum/N);view.first[c]=copied_raw[c][0];
            view.adc[c]=DBG_OK;view.dma[c]=DBG_OK;
        }
        for(c=0;c<2;c++) {
            debug_adc_metrics_t metrics;
            if(!debug_adc_measure(copied_raw[c],N,&metrics)){dma_fault(c,0);return;}
            view.rms_millicodes[c]=metrics.rms_millicodes;
            view.rail_count[c]=metrics.rail_count;
            view.block_sample_count[c]=(u32)metrics.count;
            view.sample_count[c]+=metrics.count;
        }
        last_good_adc=t;inflight=0;view.capture_seq++;return;
    }
    if(elapsed_us(t,last_capture)<50000)return;
    for(c=0;c<2;c++) {
        SP_SCOPE(q,c?SP_DMA_ARM1:SP_DMA_ARM0,0,dma[c].RegBase);
        drop_before[c]=Xil_In32(adc_base[c]+ADC_DROP);
        service_cache_flush((UINTPTR)dma_raw[c],sizeof dma_raw[c]);
        if(XAxiDma_SimpleTransfer(&dma[c],(UINTPTR)dma_raw[c],sizeof dma_raw[c],XAXIDMA_DEVICE_TO_DMA)!=XST_SUCCESS || !debug_pl_bus_ok()) {dma_fault(c,0);return;}
        done[c]=0;
    }
    /* Both DMA channels armed BEFORE either start; no claim of same sample origin. */
    for(c=0;c<2;c++){Xil_Out32(adc_base[c]+4,N);Xil_Out32(adc_base[c],1);}
    if(!debug_pl_bus_ok()){dma_fault(0,0);return;}
    capture_start=last_capture=t;inflight=1;
}
static void fft_service(XTime t)
{
    SP_SCOPE(p,SP_FFT,fft_enabled,view.fft_frames);
    int rc;const spectrum_t *s0,*s1;unsigned c;
    if(!fft_enabled || !debug_pl_bus_ok())return;
    rc=spectrum_pl_service();view.fft_rc=rc;
    sp_mark(&p,fft_enabled,(uint32_t)rc,view.fft_frames);
    if(!debug_pl_bus_ok()){view.fft=DBG_ERROR;spectrum_cache.available=0;spectrum_display_reset(&display_filter);return;}
    if(rc<0){view.fft=DBG_ERROR;view.fft_timeouts++;spectrum_cache.available=0;spectrum_display_reset(&display_filter);return;}
    if(rc!=SPECTRUM_PL_SERVICE_FRAME)return;
    if(!spectrum_pl_get(&s0,&s1))return;
    spectrum_cache.ch[0]=*s0;spectrum_cache.ch[1]=*s1;
    spectrum_cache.metadata_valid=spectrum_pl_get_frame_meta(&spectrum_cache.metadata);
    if(!spectrum_cache.metadata_valid){view.fft=DBG_ERROR;spectrum_cache.available=0;spectrum_display_reset(&display_filter);return;}
    spectrum_cache.available=1;spectrum_cache.received_time=t;spectrum_cache.view_seq++;
    {SP_SCOPE(p,SP_UI_SPECTRUM,display_filter.count,spectrum_cache.view_seq);
     if(!spectrum_display_accept(&display_filter,&spectrum_cache))
        log_line("[SPEC_UI] display frame rejected seq=%lu; raw FFT diagnostics unaffected\r\n",
                 (unsigned long)spectrum_cache.metadata.sequence);}
    view.fft=DBG_OK;view.fft_frames++;view.signal_quality=1;
    for(c=0;c<2;c++) {
        debug_peak_measure(&spectrum_cache.ch[c],&debug_input_default_config,&view.peak[c]);
        view.peak_bin[c]=view.peak[c].bin;view.peak_db[c]=view.peak[c].dbfs;
        view.peak_hz[c]=(float)view.peak[c].hz;
        view.prominence_db[c]=view.peak[c].prominence_db;
        /* Debug-only heuristic, not detector/Fine validity or calibration. */
        if(!view.peak[c].valid || view.peak_db[c]<debug_input_default_config.min_peak_dbfs ||
           view.prominence_db[c]<debug_input_default_config.min_prominence_db)view.signal_quality=0;
    }
    if(auto_initialized && elapsed_us(t,0)/1000>=auto_next_probe_ms){
        /* Bounded 50Hz classification, not a second full scan per FFT frame. */
        auto_next_probe_ms=elapsed_us(t,0)/1000+20;
        int quality=view.signal_quality && last_good_adc &&
            elapsed_us(t,last_good_adc)<=300000 &&
            !(view.adc_status[0]&1U) && !(view.adc_status[1]&1U) &&
            !view.rail_count[0] && !view.rail_count[1];
        auto_profile_observe(&auto_receiver,&spectrum_cache.ch[0],&spectrum_cache.ch[1],
            spectrum_cache.metadata.sequence,elapsed_us(t,0)/1000,quality);
    }
}
static void auto_profile_runtime(void)
{
    if(!auto_initialized)return;
    SP_SCOPE(p,SP_SESSION_CONFIG,auto_receiver.state,auto_receiver.desired_hz);
    enum auto_profile_state before=auto_receiver.state;
    int was_busy=pl_fine_control_busy();
    u64 old_switches=auto_receiver.switches;
    auto_profile_service(&auto_receiver,elapsed_us(now_ticks(),0)/1000,debug_pl_bus_ok());
    (void)pl_fine_control_runtime(&view.lifecycle);
    if(auto_receiver.state==AP_FAULT){
        view.session_state=ENG_ERROR;view.fine_rc=auto_receiver.error;
        view.stop=DBG_ERROR;view.stop_rc=auto_receiver.error;
        if(before!=AP_FAULT)doa_result_invalidate(DOA_INVALIDATION_PROTOCOL_FATAL);
    }else if(pl_fine_control_busy())view.session_state=ENG_STARTING;
    else if(auto_receiver.active_ready){
        view.session_state=ENG_MEASURING;view.session_epoch=auto_receiver.context.session_epoch;
        view.config_version=auto_receiver.context.config_version;
    }else{
        view.session_state=ENG_CLOSED;
        if(!auto_receiver.stop_pending){view.stop=DBG_OK;view.stop_rc=0;}
    }
    if(was_busy && !pl_fine_control_busy())
        log_line("[AUTO_COMPLETE] F101=%08lx ready=%u CAL=%lu rc=%d; hardware ACK checked; not a DOA result\r\n",
            (unsigned long)view.lifecycle,auto_receiver.active_ready,
            (unsigned long)hil_profile_current()->profile_id,auto_receiver.error);
    if(before!=auto_receiver.state || old_switches!=auto_receiver.switches){
        const hil_profile_t *p=hil_profile_current();
        log_line("[AUTO_PROFILE] state=%s detected=%lu Hz active=%lu Hz CAL=%lu bias_pi_F35=%lld epoch=%016llx cfg=%lu switches=%llu rc=%d ENGINEERING_ONLY\r\n",
            auto_profile_state_name(auto_receiver.state),(unsigned long)auto_receiver.desired_hz,
            (unsigned long)p->reference_hz,(unsigned long)p->profile_id,(long long)p->bias_pi_f35,
            (unsigned long long)auto_receiver.context.session_epoch,(unsigned long)auto_receiver.context.config_version,
            (unsigned long long)auto_receiver.switches,auto_receiver.error);
        next_draw=now_ticks();
    }
    sp_mark(&p,auto_receiver.state,(uint32_t)auto_receiver.error,auto_receiver.switches);
}
static void start_capture_and_fft(void)
{
    if(view.stop!=DBG_OK || !debug_pl_bus_ok())return;
    spectrum_pl_set_display_tap(display_power_tap);
    dma_init_channels();
    /* Never reset software bank ownership on an initialized bridge. */
    if(!spectrum_initialized) {
        view.fft_rc=spectrum_pl_init();spectrum_initialized=view.fft_rc==0&&debug_pl_bus_ok();
    } else view.fft_rc=spectrum_pl_start_search();
    fft_enabled=spectrum_initialized;view.fft=fft_enabled?DBG_NO_DATA:DBG_ERROR;
    log_line("[FFT] banked real ADC FFT init=%d ABI/status=%08lx FS=%lu Hz\r\n",view.fft_rc,
        (unsigned long)(debug_pl_bus_ok()?spectrum_pl_status():0),(unsigned long)ADC_SAMPLE_RATE_HZ);
}
static void uart_commands(void)
{
    SP_SCOPE(p,SP_UART_RX,0,0);
    if(!XUartPs_IsReceiveData(STDOUT_BASEADDRESS))return;
    int c=(int)(Xil_In32(STDOUT_BASEADDRESS+XUARTPS_FIFO_OFFSET)&255);
    if(c=='s') {
        capture_enabled=0;fft_enabled=0;
        if(spectrum_initialized&&debug_pl_bus_ok())spectrum_pl_stop_search();
        if(auto_initialized){
            view.stop_rc=auto_profile_disable(&auto_receiver);
            view.stop=view.stop_rc?DBG_ERROR:DBG_NOT_INITIALIZED;view.session_state=ENG_CLOSED;
            doa_result_invalidate(DOA_INVALIDATION_STOP);
        }else stop_checked();
        log_line("[USER STOP] rc=%d; AUTO disabled; pending hardware completion is NOT grant; DMA buffers held\r\n",view.stop_rc);
    } else if(c=='r') {
        /* DMA reset reclaims buffers only after ResetIsDone; never on bus fault. */
        if(!debug_pl_bus_ok()||view.stop!=DBG_OK){log_line("[RECOVERY] DENIED: STOP/bus not proven\r\n");return;}
        capture_enabled=0;inflight=0;last_good_adc=0;start_capture_and_fft();
    } else if(c=='f') {
        /* Explicit recovery only. STOP must grant before a new volatile epoch.
         * Never automatically clear a Manager fault or reinitialize a fenced bus. */
        if(pl_fine_control_busy()){log_line("[RECOVERY] DENIED: mailbox transaction pending\r\n");return;}
        stop_checked();
        if(view.stop==DBG_OK){
            start_capture_and_fft();
            if(debug_pl_bus_ok() && spectrum_initialized &&
               (spectrum_pl_status()&UINT32_C(0xffffff00))==UINT32_C(0xb25a3c00)){
                pl_fine_lifecycle_t ctx;pl_fine_lifecycle_snapshot(&ctx); /* ready=0 after STOP */
                auto_profile_init(&auto_receiver,&ctx,1);auto_initialized=1;
                auto_next_probe_ms=0;
                log_line("[RECOVERY] AUTO explicitly re-enabled; wait stable FFT; no synchronous session replay\r\n");
            }
        }
    } else if(c=='d' && display_initialized) {
        int rc=DisplayStop(&display);if(!rc)rc=DisplayStart(&display);
        view.dp_rc=rc;view.dp=rc?DBG_ERROR:DBG_OK;log_line("[DP RETRY] rc=%d\r\n",rc);
    } else if(c=='p') {
        profile_row=0;profile_row_due=now_ticks();
    } else if(c=='t') {
        trace_dump_count=trace_dump_position=trace_dump_missing=0;
        /* Bounded snapshot: don't hold pointers into a live rolling trace. */
        for(unsigned q=0;q<2;q++){
            uint64_t total=service_profile_trace_total[q],take=q?16:64;
            if(take>total)take=total;
            for(uint64_t n=total-take;n<total;n++){
                if(sp_trace_copy(q,n,&trace_dump[trace_dump_count]))trace_dump_count++;
                else trace_dump_missing++;
            }
        }
        log_line("[TRACE] recent snapshot=%u unavailable=%u; host/board wall time includes instrumentation\r\n",trace_dump_count,trace_dump_missing);
    }
}
static void profile_event_line(const char *kind,const sp_event_t *e)
{
    log_line("%s: name=%s cost_us=%llu irq_us=%llu state=0x%08lx error/status=0x%08lx return_rc=%ld detail=0x%llx polls=%lu phase=%s parent=%s start_us=%llu parent_start_us=%llu\r\n",
        kind,sp_name(e->id),(unsigned long long)e->cost_us,(unsigned long long)e->irq_us,
        (unsigned long)e->state,(unsigned long)e->status,(long)e->return_rc,(unsigned long long)e->detail,
        (unsigned long)e->iterations,e->phase?"RUN":"BOOT",sp_name(e->parent),
        (unsigned long long)sp_ticks_us(e->start_ticks),(unsigned long long)sp_ticks_us(e->parent_start_ticks));
}
static void profile_report_service(void)
{
    SP_SCOPE(p,SP_PROFILE_REPORT,profile_row,0);XTime t=now_ticks();
    unsigned queued=(uq_head+sizeof uart_queue-uq_tail)%sizeof uart_queue;
    /* One line per iteration; never wait for a UART FIFO or free queue space. */
    if(sizeof uart_queue-1-queued<640)return;
    sp_event_t e;
    if(sp_slow_pop(&e)){profile_event_line("SERVICE_SLOW",&e);return;}
    if(profile_worst_pending){profile_event_line("SERVICE_WORST",&profile_worst);profile_worst_pending=0;return;}
    if(trace_dump_position<trace_dump_count){profile_event_line("SERVICE_TRACE",&trace_dump[trace_dump_position++]);return;}
    if(profile_row>=SP_COUNT*2 && t>=profile_next){profile_row=0;profile_row_due=t;}
    if(profile_row<SP_COUNT*2 && t>=profile_row_due){
        unsigned phase=profile_row/SP_COUNT,id=profile_row%SP_COUNT;sp_stats_t s;
        if(sp_stats_copy(phase,id,&s)){
            log_line("SERVICE_STAT: phase=%s name=%s calls=%llu last_us=%llu max_us=%llu slow=%llu irq_max_us=%llu state=0x%08lx error/status=0x%08lx return_rc=%ld worst_state=0x%08lx worst_status=0x%08lx active=%s\r\n",
                phase?"RUN":"BOOT",sp_name(id),(unsigned long long)s.calls,(unsigned long long)s.last_us,
                (unsigned long long)s.max_us,(unsigned long long)s.slow_count,(unsigned long long)s.max_irq_us,
                (unsigned long)s.last.state,(unsigned long)s.last.status,(long)s.last.return_rc,(unsigned long)s.worst.state,(unsigned long)s.worst.status,
                s.calls?"MEASURED":"NOT_CALLED");
            if(s.slow_count){profile_worst=s.worst;profile_worst_pending=1;}
        }else{
            log_line("SERVICE_STAT_UNAVAILABLE: phase=%s name=%s reason=concurrent_snapshot_busy\r\n",phase?"RUN":"BOOT",sp_name(id));
        }
        profile_row++;profile_row_due=t+COUNTS_PER_SECOND/100;
        if(profile_row==SP_COUNT*2){
            log_line("[PROFILE] slow_queue_drop=%llu/%llu trace_total=%llu/%llu UART_DROP=%lu; [p]stats [t]recent trace\r\n",
                (unsigned long long)service_profile_slow_dropped[0],(unsigned long long)service_profile_slow_dropped[1],
                (unsigned long long)service_profile_trace_total[0],(unsigned long long)service_profile_trace_total[1],(unsigned long)uart_dropped);
            profile_next=now_ticks()+COUNTS_PER_SECOND*5;
        }
    }
}
int main(void)
{
    int rc;u8 *ptr[3]={frames[0],frames[1],frames[2]};XTime start,t;
    Xil_DCacheEnable();Xil_ICacheEnable();
    spectrum_display_init(&display_filter,&spectrum_display_default_config);
    log_line("\r\nENGINEERING_TEST / NOT_SIGNED_OFF | NATIVE 1920x1200 UI R8 | SD cold boot only\r\n");
    log_line("[SPEC_UI] ONLY display: linear Re2+Im2 mean=8 accepted frames, floor=-110dBFS gate=+6dB EMA=0.85/0.15 fast-rise>10dB; RAW peak/phase/Fine untouched\r\n");
    log_line("[PROFILE] wall time + IRQ overlap, threshold >20000us, bounded traces, Fine service independent of UI\r\n");
    log_line("[INPUT POLICY] engineering only: bins=2..510, NO SIGNAL AC_RMS<=2.000 codes, tone peak>=-60.000dBFS + prominence>=12.000dB; no calibrated noise claim\r\n");
    log_line("[Fine] explicit ENGINEERING_SESSION / volatile epoch / JSON embedded profiles / no QSPI writes / UNCALIBRATED\r\n");uart_service();
    doa_result_invalidate(DOA_INVALIDATION_RESET_RECOVERY);doa_result_snapshot(&doa_cache);
    doa_ui_ema_init(&doa_ui_filter);
    rc=interrupt_init();log_line("[GIC] rc=%d\r\n",rc);uart_service();
    if(!rc) {
        rc=DisplayInitialize(&display,ptr,DISPLAY_STRIDE);
        if(!rc)rc=DisplaySetupInterrupts(&display,&gic);
        display_initialized=!rc;
        if(!rc)rc=DisplayStart(&display);
    }
    view.dp_rc=rc;view.dp=rc==0?DBG_OK:rc==XST_DEVICE_NOT_FOUND?DBG_NO_DATA:DBG_ERROR;
    log_line("[DP] 1920x1200@60 RGBA8888 stride=7680 frame=9216000 rc=%d; UI target60, actual presented FPS measured\r\n",rc);
    draw_once();uart_service();
    /* Boot-time ATB before any PL access. HWH identifies HPM0_LPD. */
    rc=debug_atb_initialize();log_line("[ATB] HPM0_LPD hardware containment rc=%d; first timeout fences PL\r\n",rc);
    if(!rc) {
        fine_initialized=pl_fine_init()&&debug_pl_bus_ok();
        view.fine_status=debug_mmio_in32(XPAR_AXI_GPIO_FINE_STATUS_BASEADDR);
        stop_checked();
        log_line("[Fine] init=%d ABI=%lu STOP rc=%d state=%s F101=%08lx\r\n",fine_initialized,
            (unsigned long)(view.fine_status>>16),view.stop_rc,debug_state_name(view.stop),(unsigned long)view.lifecycle);
        if(view.stop==DBG_OK){start_capture_and_fft();fine_start_engineering();}
    } else {view.stop=DBG_ERROR;view.stop_rc=rc;}
    {
        pl_fine_lifecycle_t ctx;pl_fine_lifecycle_snapshot(&ctx);
        int bank_ok=spectrum_initialized && debug_pl_bus_ok() &&
            (spectrum_pl_status()&UINT32_C(0xffffff00))==UINT32_C(0xb25a3c00);
        auto_profile_init(&auto_receiver,&ctx,bank_ok && view.session_state==ENG_MEASURING);
        auto_initialized=bank_ok && view.session_state==ENG_MEASURING;
        log_line("[AUTO_PROFILE] enabled=%d; RELEASE-granted raw dual FFT; 5 frames/100ms stable; 500ms no-signal STOP; no source angle input; candidate biases remain UNVERIFIED\r\n",auto_initialized);
    }
    next_draw=next_hotplug=next_log=previous_loop=now_ticks();
    sp_runtime_begin();
    for(;;) {
        SP_SCOPE(loop_profile,SP_LOOP,0,view.capture_seq);
        start=t=now_ticks();
        u64 gap=elapsed_us(t,previous_loop);if(gap>view.service_gap_max_us)view.service_gap_max_us=gap;previous_loop=t;
        if(!debug_pl_bus_ok()) {
            capture_enabled=0;fft_enabled=0;view.fft=DBG_ERROR;spectrum_cache.available=0;last_good_adc=0;
            if(display_filter.average_valid || display_filter.stage_valid)spectrum_display_reset(&display_filter);
            for(unsigned c=0;c<2;c++){view.adc[c]=DBG_ERROR;view.dma[c]=DBG_ERROR;}
        }
        service_key_mode(t);adc_service(t);fft_service(t);auto_profile_runtime();fine_service();uart_commands();uart_service();
        doa_ui_service(now_ticks()); /* independent of framebuffer/renderer cadence */
        if(t>=next_hotplug) {
            if(display_initialized){SP_SCOPE(p,SP_DISPLAY_SERVICE,display.state,0);display_service(&display);
                sp_mark(&p,display.state,display.errorIsr|display.errorEisr,0);}
            view.dp=display.state==DISPLAY_RUNNING?DBG_OK:display.state==DISPLAY_FAULT_LOCKED?DBG_ERROR:DBG_NO_DATA;
            /* Recovery advances one bounded step; HPD debounce/retry deadlines
             * live inside display_service. No half-second blocking cadence. */
            next_hotplug=now_ticks();
        }
        if(t>=next_draw) {
            draw_once();XTime completed=now_ticks();
            next_draw=ui_next_deadline(t,completed,COUNTS_PER_SECOND);
            if(!fps_start){fps_start=completed;fps_previous=display.presentedCount;}
            else if(completed-fps_start>=COUNTS_PER_SECOND){
                u64 us=elapsed_us(completed,fps_start);
                view.display_fps_milli=(u32)((u64)(display.presentedCount-fps_previous)*1000000000ULL/us);
                fps_previous=display.presentedCount;fps_start=completed;
            }
        }
        if(t>=next_log) {
            SP_SCOPE(p,SP_LOG_BATCH,0,view.capture_seq);
            log_line("[LIVE] DP=%s VSYNC=%lu PRESENT=%lu DRAW=%lu FRAME=%lu FFT=%s/%lu STOP=%s F101=%08lx ATB=%08lx/%08llx\r\n",
                debug_state_name(view.dp),(unsigned long)display.vsyncCount,(unsigned long)display.presentedCount,(unsigned long)view.drawn,
                (unsigned long)view.capture_seq,debug_state_name(view.fft),(unsigned long)view.fft_frames,debug_state_name(view.stop),
                (unsigned long)view.lifecycle,(unsigned long)debug_atb_status(),(unsigned long long)debug_fault_address());
            log_line("[DP_RECOVERY] phase=%lu train=%u failures=%lu rc=%d; async foreground, no board timing claim\r\n",
                (unsigned long)display.recoveryPhase,(unsigned)display.recoveryTraining.state,
                (unsigned long)display.recoveryFailures,display.recoveryLastRc);
            for(unsigned c=0;c<2;c++) {
                char rms[32], db[32], prominence[32], peak_text[96];
                int adc_fresh=last_good_adc && elapsed_us(now_ticks(),last_good_adc)<=300000 && view.adc[c]==DBG_OK;
                int fft_fresh=spectrum_cache.available && elapsed_us(now_ticks(),spectrum_cache.received_time)<=300000;
                debug_input_state_t input=debug_input_classify(adc_fresh,fft_fresh,view.rms_millicodes[c],
                    (view.adc_status[c]&1U)!=0,&view.peak[c],&debug_input_default_config);
                debug_format_milli(rms,sizeof rms,view.rms_millicodes[c]);
                debug_format_milli(db,sizeof db,view.peak[c].dbfs_milli);
                debug_format_milli(prominence,sizeof prominence,view.peak[c].prominence_milli);
                if(fft_fresh && view.peak[c].valid)snprintf(peak_text,sizeof peak_text,"%u/%lluHz/%sdBFS/PROM=%sdB",
                    view.peak[c].bin,(unsigned long long)view.peak[c].hz,db,prominence);
                else strcpy(peak_text,"---");
                log_line("[CH%u] ADC=%s raw=%u..%u mean=%lu first=%u DMA=%s SR=%08lx ADCST=%08lx IOC=%lu ERR=%lu TIMEOUT=%lu DROP=%lu PEAK=%s\r\n",
                c,debug_state_name(view.adc[c]),view.min[c],view.max[c],(unsigned long)view.mean[c],view.first[c],debug_state_name(view.dma[c]),
                (unsigned long)view.dma_status[c],(unsigned long)view.adc_status[c],(unsigned long)view.transfers[c],
                (unsigned long)view.errors[c],(unsigned long)view.timeouts[c],(unsigned long)view.dropped[c],
                peak_text);
                log_line("[ADC%u] RMS_AC=%s codes%s OVERFLOW=%u CLIP=%lu SAMPLE_COUNT=%llu BLOCK=%lu INPUT=%s\r\n",
                    c,adc_fresh?rms:"---",adc_fresh?"":" (STALE/NO DATA)",(unsigned)(view.adc_status[c]&1U),
                    (unsigned long)view.rail_count[c],(unsigned long long)view.sample_count[c],
                    (unsigned long)view.block_sample_count[c],debug_input_name(input));
            }
            log_line("[TIME] loop_max_us=%llu service_gap_max_us=%llu draw_max_us=%llu UART_DROP=%lu NO_BUFFER=%lu | ENGINEERING_ONLY\r\n",
                (unsigned long long)view.loop_max_us,(unsigned long long)view.service_gap_max_us,(unsigned long long)view.draw_max_us,
                (unsigned long)uart_dropped,(unsigned long)view.no_buffer);
            log_line("[UI_NATIVE] 1920x1200 VIDEO_HZ=60 TARGET_FPS=60 PRESENTED_FPS=%lu.%03lu RENDER_LAST_US=%llu RENDER_MAX_US=%llu REDUCED=%u\r\n",
                (unsigned long)(view.display_fps_milli/1000),(unsigned long)(view.display_fps_milli%1000),
                (unsigned long long)view.renderer_last_us,(unsigned long long)view.renderer_max_us,view.ui_low_detail);
            if(view.session_state==ENG_MEASURING){
                int q=pl_fine_status(0,&view.lifecycle);
                if(!q && (view.lifecycle&0x30U)){
                    (void)pl_fine_status(18,&view.fine_fault_code);
                    log_line("[Fine FAULT] F101=%08lx fault_code=%08lx; STOP, explicit recovery required\r\n",
                        (unsigned long)view.lifecycle,(unsigned long)view.fine_fault_code);
                    view.session_state=ENG_ERROR;view.fine_rc=-998;
                    doa_result_invalidate(DOA_INVALIDATION_PROTOCOL_FATAL);(void)pl_fine_stop();
                }else if(q){view.fine_rc=q;view.session_state=ENG_ERROR;
                    doa_result_invalidate(DOA_INVALIDATION_PROTOCOL_FATAL);(void)pl_fine_stop();}
                else{(void)pl_fine_status(16,&view.fine_result_drop);(void)pl_fine_status(19,&view.fine_busy_drop);}
            }
            doa_result_snapshot(&doa_cache);uint64_t age=0;
            int has_age=doa_result_age_ms(&doa_cache,&age);
            log_line("[Fine LIVE] ENG_state=%u epoch=%016llx cfg=%lu F101=%08lx service=%d PUB=%llu INVALID=%llu DROP=%lu BUSY_DROP=%lu AGE=%s%llums\r\n",
                view.session_state,(unsigned long long)view.session_epoch,(unsigned long)view.config_version,
                (unsigned long)view.lifecycle,view.fine_rc,(unsigned long long)view.fine_published,
                (unsigned long long)view.fine_invalid,(unsigned long)view.fine_result_drop,(unsigned long)view.fine_busy_drop,
                has_age==1?"":"NOT_READY/",(unsigned long long)age);
            if(doa_cache.available)log_line("[PL RESULT] seq=%lu f_hat_Hz_F24=%llu raw_pi_F35=%lld fine_valid=%llu stage=%llu status=%llu cal_pi_F35=%lld theta_pi_F35=%lld theta_valid=%llu profile=%lu geo=%lu epoch=%016llx cfg=%lu calibration_status=%llu calibrated_valid=%llu numeric_valid=%llu UNCALIBRATED/ENGINEERING_ESTIMATE HIL_COMMAND_ZERO\r\n",
                (unsigned long)doa_cache.identity.candidate_seq,
                (unsigned long long)pl_fine_bits(&doa_cache.packet,PL_F_HAT_HZ_BIT,PL_F_HAT_HZ_WIDTH),
                (long long)pl_fine_signed(&doa_cache.packet,PL_PHASE_RAW_BIT,PL_PHASE_RAW_WIDTH),
                (unsigned long long)pl_fine_bits(&doa_cache.packet,PL_FINE_NUMERIC_VALID_BIT,1),
                (unsigned long long)pl_fine_bits(&doa_cache.packet,PL_STATUS_STAGE_BIT,PL_STATUS_STAGE_WIDTH),
                (unsigned long long)pl_fine_bits(&doa_cache.packet,PL_STATUS_BIT,PL_STATUS_WIDTH),
                (long long)pl_fine_signed(&doa_cache.packet,PL_PHASE_CAL_BIT,PL_PHASE_CAL_WIDTH),
                (long long)pl_fine_signed(&doa_cache.packet,PL_THETA_BIT,PL_THETA_WIDTH),
                (unsigned long long)pl_fine_bits(&doa_cache.packet,PL_THETA_VALID_BIT,1),
                (unsigned long)doa_cache.identity.calibration_profile_id,(unsigned long)doa_cache.identity.geometry_id,
                (unsigned long long)doa_cache.identity.session_epoch,(unsigned long)doa_cache.identity.config_version,
                (unsigned long long)pl_fine_bits(&doa_cache.packet,PL_CALIBRATION_STATUS_BIT,PL_CALIBRATION_STATUS_WIDTH),
                (unsigned long long)pl_fine_bits(&doa_cache.packet,PL_CALIBRATED_VALID_BIT,1),
                (unsigned long long)pl_fine_bits(&doa_cache.packet,PL_NUMERIC_VALID_BIT,1));
            char before[32],after[32],before_last[32],after_last[32];
            debug_format_milli(before,sizeof before,(int64_t)llround(display_filter.stats.before_max_db*1000.0));
            debug_format_milli(after,sizeof after,(int64_t)llround(display_filter.stats.after_max_db*1000.0));
            debug_format_milli(before_last,sizeof before_last,(int64_t)llround(display_filter.stats.before_last_db*1000.0));
            debug_format_milli(after_last,sizeof after_last,(int64_t)llround(display_filter.stats.after_last_db*1000.0));
            log_line("[SPEC_UI_CHANGE] bins=2..510 submitted_pairs=%llu warmup=%u/8 raw_max=%sdB filtered_max=%sdB raw_last=%sdB filtered_last=%sdB fast_rises=%llu resets=%llu rejected=%llu\r\n",
                (unsigned long long)display_filter.stats.compared_frames,display_filter.count,before,after,before_last,after_last,
                (unsigned long long)display_filter.stats.fast_rises,(unsigned long long)display_filter.stats.resets,
                (unsigned long long)display_filter.stats.rejected_frames);
            next_log=now_ticks()+COUNTS_PER_SECOND;
        }
        profile_report_service();
        u64 cost=elapsed_us(now_ticks(),start);if(cost>view.loop_max_us)view.loop_max_us=cost;
    }
}
