#include "display_ctrl.h"

#include "sleep.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xavbuf_clk.h"
#include "xpseudo_asm.h"
#include "service_profile.h"

#define DPPSU_DEVICE_ID XPAR_PSU_DP_DEVICE_ID
#define DPDMA_DEVICE_ID XPAR_XDPDMA_0_DEVICE_ID
#define AVBUF_DEVICE_ID XPAR_PSU_DP_DEVICE_ID
/* Exact dpdma_v1_4 xdpdma_video_example.c: DPDMA interrupt ID is 154. */
#define DISPLAY_DPDMA_INTR_ID 154U
#define DISPLAY_DMA_ERRORS 0x07FFF000U

static void DisplayIrqLock(DisplayCtrl *d)
{
    if (d->irqConnected)
        XScuGic_Disable(d->interruptController, DISPLAY_DPDMA_INTR_ID);
    dsb();
    __asm__ volatile ("" ::: "memory");
}

static void DisplayIrqUnlock(DisplayCtrl *d)
{
    __asm__ volatile ("" ::: "memory");
    dsb();
    if (d->irqConnected && d->state == DISPLAY_RUNNING)
        XScuGic_Enable(d->interruptController, DISPLAY_DPDMA_INTR_ID);
}

/* A later VSYNC plus a hardware descriptor-ID match is switch evidence.
 * Current and DSCR_STRT_ADDR only describe the software-issued request.
 * Single pending submission keeps both BSP descriptors immutable until ACK. */
static void DisplayConfirmPresented(DisplayCtrl *d)
{
    u32 id, control;
    int old, next = d->pendingFrame;
    if (next < 0 || !d->pendingIssued)
        return;
    id = XDpDma_ReadReg(d->DpDma.Config.BaseAddr, XDPDMA_CH3_DSCR_ID)
         & XDPDMA_CH_DSCR_ID_VAL_MASK;
    control = XDpDma_ReadReg(d->DpDma.Config.BaseAddr, XDPDMA_CH3_CNTL);
    if (id != d->pendingDescriptorId ||
        !(control & XDPDMA_CH_CNTL_EN_MASK) ||
        (control & XDPDMA_CH_CNTL_PAUSE_MASK))
        return;
    old = d->scanningFrame;
    d->frameState[next] = DISPLAY_FRAME_SCANNING;
    d->scanningFrame = next;
    d->lastFrame = (u32)next;
    d->pendingFrame = -1;
    d->pendingIssued = 0;
    d->presentedCount++;
    if (old >= 0)
        d->frameState[old] = DISPLAY_FRAME_FREE;
}

static void DisplayDpdmaInterrupt(void *reference)
{
    DisplayCtrl *d = (DisplayCtrl *)reference;
    SP_SCOPE(p,SP_DPDMA_IRQ,d->state,0);
    UINTPTR base = d->DpDma.Config.BaseAddr;
    u32 isr = XDpDma_ReadReg(base, XDPDMA_ISR);
    u32 eisr = XDpDma_ReadReg(base, XDPDMA_EISR);
    int status, initial;
    if ((isr & DISPLAY_DMA_ERRORS) || eisr) {
        d->errorIsr |= isr & DISPLAY_DMA_ERRORS;
        d->errorEisr |= eisr;
        d->state = DISPLAY_FAULT_LOCKED;
        XDpDma_WriteReg(base, XDPDMA_IDS, 0xFFFFFFFFU);
        XDpDma_WriteReg(base, XDPDMA_EIDS, 0xFFFFFFFFU);
    }
    if (d->state == DISPLAY_RUNNING &&
        (isr & XDPDMA_ISR_VSYNC_INT_MASK)) {
        d->vsyncCount++;
        /* Confirm FIRST: never ACK a descriptor just created in this ISR. */
        DisplayConfirmPresented(d);
        if (d->pendingFrame >= 0 && !d->pendingIssued) {
            initial = d->DpDma.Gfx.Channel.Current == NULL;
            /* Official BSP generates/switches its two descriptors. Only add
             * an ID and cache maintenance BEFORE the official Trigger. */
            XDpDma_SetupChannel(&d->DpDma, GraphicsChan);
            d->pendingDescriptor = d->DpDma.Gfx.Channel.Current;
            do {
                d->descriptorSerial++;
            } while (!d->descriptorSerial || d->descriptorSerial ==
                (XDpDma_ReadReg(base, XDPDMA_CH3_DSCR_ID) &
                 XDPDMA_CH_DSCR_ID_VAL_MASK));
            d->pendingDescriptorId = d->descriptorSerial;
            d->pendingDescriptor->DSCR_ID = d->pendingDescriptorId;
            service_cache_flush((UINTPTR)d->pendingDescriptor,
                                sizeof(*d->pendingDescriptor));
            dsb();
            status = initial ?
                XDpDma_SetChannelState(&d->DpDma, GraphicsChan, XDPDMA_ENABLE) :
                XST_SUCCESS;
            if (status == XST_SUCCESS)
                status = initial ? XDpDma_Trigger(&d->DpDma, GraphicsChan) :
                                   XDpDma_ReTrigger(&d->DpDma, GraphicsChan);
            if (status != XST_SUCCESS) {
                d->state = DISPLAY_FAULT_LOCKED;
                d->DpDma.Gfx.TriggerStatus = XDPDMA_TRIGGER_DONE;
                XDpDma_WriteReg(base, XDPDMA_IDS, 0xFFFFFFFFU);
            } else {
                d->pendingIssued = 1;
            }
        }
    }
    /* Existing official dispatcher clears VSYNC / services supported audio.
     * TriggerStatus is DONE, so it never regenerates our tagged descriptor. */
    if (d->state != DISPLAY_RUNNING)
        d->DpDma.Gfx.TriggerStatus = XDPDMA_TRIGGER_DONE;
    XDpDma_InterruptHandler(&d->DpDma);
    /* VSYNC was already W1C-cleared by the BSP. Do not clear it twice and
     * accidentally swallow a fresh boundary arriving at the end of the ISR. */
    XDpDma_WriteReg(base, XDPDMA_ISR, isr & ~XDPDMA_ISR_VSYNC_INT_MASK);
    XDpDma_WriteReg(base, XDPDMA_EISR, eisr);
    sp_mark(&p,d->state,isr|eisr,0);
}

static int DisplayConfigurePipeline(DisplayCtrl *dispPtr)
{
    int status;
    XDpPsu_Config *dp_cfg;
    XDpDma_Config *dma_cfg;

    dp_cfg = XDpPsu_LookupConfig(DPPSU_DEVICE_ID);
    dma_cfg = XDpDma_LookupConfig(DPDMA_DEVICE_ID);
    if (dp_cfg == NULL || dma_cfg == NULL)
        return XST_FAILURE;

    XDpPsu_CfgInitialize(&dispPtr->DpPsu, dp_cfg, dp_cfg->BaseAddr);
    XAVBuf_CfgInitialize(&dispPtr->AVBuf,
                         dispPtr->DpPsu.Config.BaseAddr,
                         AVBUF_DEVICE_ID);
    XDpDma_CfgInitialize(&dispPtr->DpDma, dma_cfg);

    status = XDpPsu_InitializeTx(&dispPtr->DpPsu);
    if (status != XST_SUCCESS)
        return status;

    status = XDpDma_SetGraphicsFormat(&dispPtr->DpDma, RGBA8888);
    if (status != XST_SUCCESS)
        return status;

    status = XAVBuf_SetInputNonLiveGraphicsFormat(&dispPtr->AVBuf, RGBA8888);
    if (status != XST_SUCCESS)
        return status;

    XDpDma_SetQOS(&dispPtr->DpDma, 11);
    XAVBuf_EnableGraphicsBuffers(&dispPtr->AVBuf, 1);
    XAVBuf_SetOutputVideoFormat(&dispPtr->AVBuf, RGB_8BPC);
    XAVBuf_InputVideoSelect(&dispPtr->AVBuf, XAVBUF_VIDSTREAM1_NONE,
                           XAVBUF_VIDSTREAM2_NONLIVE_GFX);
    XAVBuf_ConfigureGraphicsPipeline(&dispPtr->AVBuf);
    XAVBuf_ConfigureOutputVideo(&dispPtr->AVBuf);
    XAVBuf_SetBlenderAlpha(&dispPtr->AVBuf, 0, 0);
    XDpPsu_CfgMsaEnSynchClkMode(&dispPtr->DpPsu, 0);
    XAVBuf_SetAudioVideoClkSrc(&dispPtr->AVBuf, XAVBUF_PS_CLK, XAVBUF_PS_CLK);
    XAVBuf_SoftReset(&dispPtr->AVBuf);

    return XST_SUCCESS;
}

static int DisplayWakeSink(DisplayCtrl *dispPtr)
{
    SP_SCOPE(p,SP_DP_WAKE,dispPtr->state,0);
    u8 aux_data = 1U;
    int status;

    status = XDpPsu_AuxWrite(&dispPtr->DpPsu,
                             XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE,
                             1, &aux_data);
    if (status != XST_SUCCESS) {
        status = XDpPsu_AuxWrite(&dispPtr->DpPsu,
                                 XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE,
                                 1, &aux_data);
    }
    SP_RETURN(p,status);
}

static int DisplayTrainLink(DisplayCtrl *dispPtr)
{
    SP_SCOPE(p,SP_DP_TRAIN,dispPtr->state,0);
    XDpPsu *dp = &dispPtr->DpPsu;
    XDpPsu_LinkConfig *link = &dp->LinkConfig;
    int status;

    status = XDpPsu_GetRxCapabilities(dp);
    if (status != XST_SUCCESS)
        return status;

    status = XDpPsu_SetEnhancedFrameMode(
        dp, link->SupportEnhancedFramingMode ? 1 : 0);
    if (status != XST_SUCCESS)
        return status;

    status = XDpPsu_SetLaneCount(dp, link->MaxLaneCount);
    if (status != XST_SUCCESS)
        return status;

    status = XDpPsu_SetLinkRate(dp, link->MaxLinkRate);
    if (status != XST_SUCCESS)
        return status;

    status = XDpPsu_SetDownspread(dp, link->SupportDownspreadControl);
    if (status != XST_SUCCESS)
        return status;

    xil_printf("[DP] lane=%d link-rate=0x%02x\r\n",
               dp->LinkConfig.LaneCount, dp->LinkConfig.LinkRate);
    SP_RETURN(p,XDpPsu_EstablishLink(dp));
}

static int DisplaySetupStream(DisplayCtrl *dispPtr)
{
    XDpPsu *dp = &dispPtr->DpPsu;

    if(!display_link_supports_native(dp->LinkConfig.LaneCount,dp->LinkConfig.LinkRate)){
        xil_printf("[DP] insufficient bandwidth for native1920x1200 RGB8; lanes=%u rate=0x%02x\r\n",
            dp->LinkConfig.LaneCount,dp->LinkConfig.LinkRate);
        return XST_FAILURE;
    }

    XDpPsu_SetColorEncode(dp, XDPPSU_CENC_RGB);
    XDpPsu_CfgMsaSetBpc(dp, XVIDC_BPC_8);
    XDpPsu_CfgMsaUseStandardVideoMode(dp, XVIDC_VM_1920x1200_60_P);
    if(dp->MsaConfig.PixelClockHz!=DISPLAY_PIXEL_CLOCK_HZ)return XST_FAILURE;
    {SP_SCOPE(p,SP_DP_PIXEL_CLOCK,0,dp->MsaConfig.PixelClockHz);
     int rc=XAVBuf_SetPixelClock(dp->MsaConfig.PixelClockHz);
     sp_mark(&p,0,(uint32_t)rc,dp->MsaConfig.PixelClockHz);
     if(rc!=XST_SUCCESS)return XST_FAILURE;}

    XDpPsu_WriteReg(dp->Config.BaseAddr, XDPPSU_SOFT_RESET, 0x1);
    usleep(10);
    XDpPsu_WriteReg(dp->Config.BaseAddr, XDPPSU_SOFT_RESET, 0x0);
    XDpPsu_SetMsaValues(dp);

    XDpPsu_WriteReg(dp->Config.BaseAddr, 0xB124, 0x3);
    usleep(10);
    XDpPsu_WriteReg(dp->Config.BaseAddr, 0xB124, 0x0);
    return XST_SUCCESS;
}

int DisplayInitialize(DisplayCtrl *dispPtr,
                      u8 *framePtr[DISPLAY_NUM_FRAMES], u32 stride)
{
    unsigned i, j;
    int status;

    if (dispPtr == NULL || framePtr == NULL || stride != DISPLAY_STRIDE)
        return XST_INVALID_PARAM;
    for (i = 0; i < DISPLAY_NUM_FRAMES; ++i) {
        UINTPTR address = (UINTPTR)framePtr[i];
        if (!address || address % XDPDMA_DESCRIPTOR_ALIGN ||
            address > (UINTPTR)-1 - DISPLAY_FRAME_SIZE)
            return XST_INVALID_PARAM;
        for (j = 0; j < i; ++j) {
            UINTPTR other = (UINTPTR)framePtr[j];
            if (address < other + DISPLAY_FRAME_SIZE &&
                other < address + DISPLAY_FRAME_SIZE)
                return XST_INVALID_PARAM;
        }
    }
    /* Never overwrite descriptors/leases while DMA may still reference them. */
    if (dispPtr->initialized && DisplayStop(dispPtr) != XST_SUCCESS)
        return XST_FAILURE;

    dispPtr->vMode.label = "1920x1200@60Hz";
    dispPtr->vMode.width = DISPLAY_WIDTH;
    dispPtr->vMode.height = DISPLAY_HEIGHT;
    dispPtr->stride = stride;
    dispPtr->state = DISPLAY_STOPPED;
    dispPtr->scanningFrame = dispPtr->pendingFrame = -1;
    dispPtr->pendingIssued = 0;
    dispPtr->lastFrame = 0;
    dispPtr->startRequested = 0;
    for (i = 0; i < DISPLAY_NUM_FRAMES; ++i) {
        dispPtr->framePtr[i] = framePtr[i];
        dispPtr->frameState[i] = DISPLAY_FRAME_FREE;
        dispPtr->frameLease[i] = 0;
        dispPtr->DpFrames[i].Address = (INTPTR)framePtr[i];
        dispPtr->DpFrames[i].Stride = stride;
        dispPtr->DpFrames[i].LineSize = DISPLAY_WIDTH * DISPLAY_BPP;
        dispPtr->DpFrames[i].Size = DISPLAY_FRAME_SIZE;
    }

    status = DisplayConfigurePipeline(dispPtr);
    if (status != XST_SUCCESS)
        return status;

    dispPtr->initialized = 1;
    /* Also drain a channel inherited from a preceding application instance. */
    if (DisplayStop(dispPtr) != XST_SUCCESS)
        return XST_FAILURE;
    return XST_SUCCESS;
}

int DisplaySetupInterrupts(DisplayCtrl *d, XScuGic *controller)
{
    int status;
    if (!d || !d->initialized || !controller || d->state != DISPLAY_STOPPED)
        return XST_INVALID_PARAM;
    XDpDma_WriteReg(d->DpDma.Config.BaseAddr, XDPDMA_IDS, 0xFFFFFFFFU);
    XDpDma_WriteReg(d->DpDma.Config.BaseAddr, XDPDMA_EIDS, 0xFFFFFFFFU);
    status = XScuGic_Connect(controller, DISPLAY_DPDMA_INTR_ID,
                            (Xil_InterruptHandler)DisplayDpdmaInterrupt, d);
    if (status != XST_SUCCESS)
        return status;
    d->interruptController = controller;
    d->irqConnected = 1;
    /* DPDMA ISR status is W1C; the aggregate IRQ is level-sensitive. */
    XScuGic_SetPriorityTriggerType(controller, DISPLAY_DPDMA_INTR_ID, 0xA0, 0x01);
    XScuGic_Disable(controller, DISPLAY_DPDMA_INTR_ID);
    return XST_SUCCESS;
}

static int DisplayActivate(DisplayCtrl *dispPtr)
{
    DisplayDrawFrame draw;
    int status;
    dispPtr->state = DISPLAY_RUNNING;
    XDpDma_WriteReg(dispPtr->DpDma.Config.BaseAddr, XDPDMA_ISR, 0xFFFFFFFFU);
    XDpDma_WriteReg(dispPtr->DpDma.Config.BaseAddr, XDPDMA_EISR, 0xFFFFFFFFU);
    XDpDma_InterruptEnable(&dispPtr->DpDma,
        XDPDMA_IEN_VSYNC_INT_MASK | DISPLAY_DMA_ERRORS);
    XDpDma_WriteReg(dispPtr->DpDma.Config.BaseAddr, XDPDMA_EIEN, 0xFFFFFFFFU);
    DisplayIrqUnlock(dispPtr);
    if (display_acquire_draw_frame(dispPtr, &draw) != XST_SUCCESS)
        return XST_FAILURE;
    status = display_present_frame(dispPtr, &draw);
    if (status != XST_SUCCESS) display_cancel_draw_frame(dispPtr, &draw);
    return status;
}

int DisplayStart(DisplayCtrl *dispPtr)
{
    SP_SCOPE(p,SP_DISPLAY_START,dispPtr?dispPtr->state:UINT32_MAX,0);
    int status;

    if (dispPtr == NULL || !dispPtr->initialized || !dispPtr->irqConnected)
        return XST_INVALID_PARAM;
    dispPtr->startRequested = 1;
    if (dispPtr->state == DISPLAY_RUNNING)
        return XST_SUCCESS;
    if (dispPtr->state != DISPLAY_STOPPED)
        return XST_FAILURE;

    XDpPsu_EnableMainLink(&dispPtr->DpPsu, 0);
    if (!XDpPsu_IsConnected(&dispPtr->DpPsu))
        return XST_DEVICE_NOT_FOUND;

    status = DisplayWakeSink(dispPtr);
    if (status != XST_SUCCESS)
        return status;

    status = DisplayTrainLink(dispPtr);
    if (status != XST_SUCCESS)
        return status;

    status = DisplaySetupStream(dispPtr);
    if (status != XST_SUCCESS)
        return status;
    XDpPsu_EnableMainLink(&dispPtr->DpPsu, 1);

    status = XDpPsu_CheckLinkStatus(&dispPtr->DpPsu,
                                    dispPtr->DpPsu.LinkConfig.LaneCount);
    if (status != XST_SUCCESS) {
        XDpPsu_EnableMainLink(&dispPtr->DpPsu, 0);
        return status;
    }
    status = DisplayActivate(dispPtr);
    SP_RETURN(p,status);
}

int DisplayStop(DisplayCtrl *dispPtr)
{
    SP_SCOPE(p,SP_DISPLAY_STOP,dispPtr?dispPtr->state:UINT32_MAX,0);
    unsigned i;
    int status;
    if (dispPtr == NULL || !dispPtr->initialized)
        return XST_INVALID_PARAM;

    dispPtr->startRequested = 0;
    dispPtr->recoveryPhase = 0;
    DisplayIrqLock(dispPtr);
    dispPtr->state = DISPLAY_STOPPING;
    XDpDma_WriteReg(dispPtr->DpDma.Config.BaseAddr, XDPDMA_IDS, 0xFFFFFFFFU);
    XDpDma_WriteReg(dispPtr->DpDma.Config.BaseAddr, XDPDMA_EIDS, 0xFFFFFFFFU);
    dispPtr->DpDma.Gfx.TriggerStatus = XDPDMA_TRIGGER_DONE;
    XDpPsu_EnableMainLink(&dispPtr->DpPsu, 0);
    status = XDpDma_SetChannelState(&dispPtr->DpDma, GraphicsChan, XDPDMA_IDLE);
    if (status != XST_SUCCESS) {
        /* Ownership remains quarantined, not falsely FREE after a timeout. */
        dispPtr->state = DISPLAY_FAULT_LOCKED;
        SP_RETURN(p,status);
    }
    for (i = 0; i < DISPLAY_NUM_FRAMES; ++i) {
        dispPtr->frameState[i] = DISPLAY_FRAME_FREE;
        dispPtr->frameLease[i] = 0;
    }
    dispPtr->pendingFrame = dispPtr->scanningFrame = -1;
    dispPtr->pendingIssued = 0;
    dispPtr->pendingDescriptor = NULL;
    dispPtr->DpDma.Gfx.Channel.Current = NULL;
    dispPtr->DpDma.Gfx.FrameBuffer = NULL;
    XDpDma_WriteReg(dispPtr->DpDma.Config.BaseAddr, XDPDMA_ISR, 0xFFFFFFFFU);
    XDpDma_WriteReg(dispPtr->DpDma.Config.BaseAddr, XDPDMA_EISR, 0xFFFFFFFFU);
    dispPtr->state = DISPLAY_STOPPED;
    return XST_SUCCESS;
}

static int DisplayLeaseMatches(DisplayCtrl *d, const DisplayDrawFrame *draw)
{
    return draw && draw->index < DISPLAY_NUM_FRAMES && draw->lease &&
        d->frameState[draw->index] == DISPLAY_FRAME_RENDERING &&
        d->frameLease[draw->index] == draw->lease &&
        d->framePtr[draw->index] == draw->pixels;
}

int display_acquire_draw_frame(DisplayCtrl *d, DisplayDrawFrame *draw)
{
    unsigned n;
    if (!d || !draw || !d->initialized)
        return XST_INVALID_PARAM;
    draw->pixels = NULL;
    draw->lease = 0;
    DisplayIrqLock(d);
    if (d->state == DISPLAY_RUNNING && d->leaseSerial != (u64)-1) {
        for (n = 0; n < DISPLAY_NUM_FRAMES; ++n) {
            unsigned i = (d->lastFrame + n) % DISPLAY_NUM_FRAMES;
            if (d->frameState[i] == DISPLAY_FRAME_FREE) {
                draw->lease = ++d->leaseSerial;
                draw->index = i;
                draw->pixels = d->framePtr[i];
                d->frameLease[i] = draw->lease;
                d->frameState[i] = DISPLAY_FRAME_RENDERING;
                DisplayIrqUnlock(d);
                return XST_SUCCESS;
            }
        }
    }
    d->droppedCount++;
    DisplayIrqUnlock(d);
    return XST_FAILURE;
}

int display_present_frame(DisplayCtrl *d, const DisplayDrawFrame *draw)
{
    SP_SCOPE(p,SP_PRESENT,d?d->state:UINT32_MAX,DISPLAY_FRAME_SIZE);
    if (!d || !d->initialized)
        return XST_INVALID_PARAM;
    DisplayIrqLock(d);
    if (d->state != DISPLAY_RUNNING || d->pendingFrame >= 0 ||
        !DisplayLeaseMatches(d, draw)) {
        d->droppedCount++;
        DisplayIrqUnlock(d);
        return XST_FAILURE;
    }
    service_cache_flush((UINTPTR)draw->pixels, DISPLAY_FRAME_SIZE);
    dsb();
    d->frameState[draw->index] = DISPLAY_FRAME_PENDING;
    d->pendingFrame = (int)draw->index;
    d->pendingIssued = 0;
    XDpDma_DisplayGfxFrameBuffer(&d->DpDma, &d->DpFrames[draw->index]);
    DisplayIrqUnlock(d);
    return XST_SUCCESS;
}

int display_cancel_draw_frame(DisplayCtrl *d, const DisplayDrawFrame *draw)
{
    int status = XST_FAILURE;
    if (!d || !d->initialized)
        return XST_INVALID_PARAM;
    DisplayIrqLock(d);
    if (DisplayLeaseMatches(d, draw)) {
        d->frameState[draw->index] = DISPLAY_FRAME_FREE;
        d->frameLease[draw->index] = 0;
        status = XST_SUCCESS;
    }
    DisplayIrqUnlock(d);
    return status;
}

void display_service(DisplayCtrl *dispPtr)
{
    XTime ticks;
    u64 now;
    int connected, status=XST_SUCCESS;
    XDpPsu *dp;
    XDpPsu_LinkConfig *link;

    if (dispPtr == NULL || !dispPtr->initialized)
        return;
    XTime_GetTime(&ticks);now=sp_ticks_us(ticks);
    if(now<dispPtr->recoveryPreviousUs) {
        dispPtr->hpdSamples=0;dispPtr->recoveryPollUs=0;
        dispPtr->recoveryRetryUs=0;
        if(dispPtr->recoveryPhase)goto failed;
    }
    dispPtr->recoveryPreviousUs=now;
    dp=&dispPtr->DpPsu;link=&dp->LinkConfig;
    /* Single status read, not the vendor's 1..51ms IsConnected loop. */
    if(!dispPtr->recoveryPhase && now<dispPtr->recoveryPollUs)return;
    connected=!!(XDpPsu_ReadReg(dp->Config.BaseAddr,XDPPSU_INTERRUPT_SIG_STATE) &
                  XDPPSU_INTERRUPT_SIG_STATE_HPD_STATE_MASK);
    if(!dispPtr->recoveryPhase) {
        dispPtr->recoveryPollUs=now+20000;
        if(dispPtr->hpdSample!=(u32)connected){
            dispPtr->hpdSample=(u32)connected;dispPtr->hpdSamples=1;
        } else if(dispPtr->hpdSamples<3)dispPtr->hpdSamples++;
        if(dispPtr->hpdSamples<3)return;
        if(!connected && dispPtr->state==DISPLAY_RUNNING) {
            u32 restart=dispPtr->startRequested;
            status=DisplayStop(dispPtr);dispPtr->startRequested=restart;
            dispPtr->recoveryLastRc=status;
            return;
        }
        if(!connected || dispPtr->state!=DISPLAY_STOPPED ||
           !dispPtr->startRequested || now<dispPtr->recoveryRetryUs)return;
        XDpPsu_EnableMainLink(dp,0);dispPtr->recoveryPhase=1;
        return;
    }
    if(!connected || !dispPtr->startRequested)goto failed;
    dp_training_vendor_budget_begin();
    switch(dispPtr->recoveryPhase) {
    case 1: status=DisplayWakeSink(dispPtr);break;
    case 2: status=XDpPsu_GetRxCapabilities(dp);break;
    case 3: status=XDpPsu_SetEnhancedFrameMode(dp,link->SupportEnhancedFramingMode?1:0);break;
    case 4: status=XDpPsu_SetLaneCount(dp,link->MaxLaneCount);break;
    case 5: status=XDpPsu_SetLinkRate(dp,link->MaxLinkRate);break;
    case 6:
        status=XDpPsu_SetDownspread(dp,link->SupportDownspreadControl);
        if(status==XST_SUCCESS)
            dp_training_begin(&dispPtr->recoveryTraining,now,dp_training_vendor_delay(dp));
        break;
    case 7:
        status=dp_training_step(&dispPtr->recoveryTraining,now,dp_training_vendor_io,dp);
        if(status==0){dp_training_vendor_budget_end();return;}
        status=status==1?XST_SUCCESS:XST_FAILURE;break;
    case 8: status=DisplaySetupStream(dispPtr);break;
    case 9:
        XDpPsu_EnableMainLink(dp,1);
        status=XDpPsu_CheckLinkStatus(dp,link->LaneCount);break;
    case 10:status=DisplayActivate(dispPtr);break;
    default:status=XST_FAILURE;break;
    }
    dp_training_vendor_budget_end();
    if(status!=XST_SUCCESS)goto failed;
    if(++dispPtr->recoveryPhase==11){
        dispPtr->recoveryPhase=0;dispPtr->recoveryLastRc=XST_SUCCESS;
        dispPtr->recoveryPollUs=now+20000;
    }
    return;
failed:
    /* No ownership release without the existing hardware drain confirmation. */
    dp_training_vendor_budget_end();
    if(dispPtr->state==DISPLAY_RUNNING){
        u32 restart=dispPtr->startRequested;
        DisplayStop(dispPtr);dispPtr->startRequested=restart;
    } else XDpPsu_EnableMainLink(&dispPtr->DpPsu,0);
    dispPtr->recoveryPhase=0;dispPtr->recoveryLastRc=XST_FAILURE;
    dispPtr->recoveryFailures++;dispPtr->recoveryRetryUs=now+1000000;
}
