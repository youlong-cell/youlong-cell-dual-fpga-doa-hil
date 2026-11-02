#ifndef DISPLAY_CTRL_H_
#define DISPLAY_CTRL_H_

#include "xil_types.h"
#include "xstatus.h"
#include "xdpdma.h"
#include "xdppsu.h"
#include "xavbuf.h"
#include "xscugic.h"
#include "dp_training_step.h"

#define DISPLAY_NUM_FRAMES 3
#define DISPLAY_WIDTH      1920U
#define DISPLAY_HEIGHT     1200U
#define DISPLAY_BPP        4U
#define DISPLAY_STRIDE     (DISPLAY_WIDTH * DISPLAY_BPP)
#define DISPLAY_FRAME_SIZE (DISPLAY_STRIDE * DISPLAY_HEIGHT)
#define DISPLAY_PIXEL_CLOCK_HZ UINT64_C(193622400)
/* Current BSP DMT totals: 2592*1245*60. RGB8 uses 24 wire bits,
 * independently of the RGBA8888 framebuffer's 32 bits per pixel. */
static inline int display_link_supports_native(u32 lanes,u32 rate)
{
    if((lanes!=1&&lanes!=2&&lanes!=4)||(rate!=6&&rate!=10&&rate!=20))return 0;
    return (u64)lanes*rate*27000000ULL*8ULL>DISPLAY_PIXEL_CLOCK_HZ*24ULL;
}

/* Only the PS miniDP mode is supported. PL VGA/LCD porch tables are removed. */
typedef struct {
    const char *label;
    u32 width;
    u32 height;
} DisplayMode;

typedef enum {
    DISPLAY_STOPPED = 0,
    DISPLAY_RUNNING = 1,
    DISPLAY_STOPPING = 2,
    DISPLAY_FAULT_LOCKED = 3
} DisplayState;

typedef enum {
    DISPLAY_FRAME_FREE = 0,
    DISPLAY_FRAME_RENDERING,
    DISPLAY_FRAME_PENDING,
    DISPLAY_FRAME_SCANNING
} DisplayFrameState;

/* A lease, not an index into a presumed "next" buffer. Invalid after stop/reinit. */
typedef struct {
    u8 *pixels;
    u32 index;
    u64 lease;
} DisplayDrawFrame;

typedef struct {
    XDpDma DpDma;
    XDpPsu DpPsu;
    XAVBuf AVBuf;
    XDpDma_FrameBuffer DpFrames[DISPLAY_NUM_FRAMES];
    DisplayMode vMode;
    u8 *framePtr[DISPLAY_NUM_FRAMES];
    u32 stride;
    volatile DisplayState state;
    volatile DisplayFrameState frameState[DISPLAY_NUM_FRAMES];
    u64 frameLease[DISPLAY_NUM_FRAMES];
    u64 leaseSerial;
    volatile int scanningFrame;
    volatile int pendingFrame;
    volatile u32 pendingIssued;
    volatile u32 vsyncCount;
    volatile u32 presentedCount;
    volatile u32 droppedCount;
    volatile u32 errorIsr, errorEisr;
    u32 lastFrame;
    u16 descriptorSerial, pendingDescriptorId;
    XDpDma_Descriptor *pendingDescriptor;
    XScuGic *interruptController;
    u32 initialized, irqConnected, startRequested;
    /* Runtime recovery only; boot DisplayStart remains the existing API. */
    dp_training_t recoveryTraining;
    u64 recoveryPollUs, recoveryRetryUs, recoveryPreviousUs;
    u32 recoveryPhase, hpdSamples, hpdSample, recoveryFailures;
    int recoveryLastRc;
} DisplayCtrl;

/* Caller must zero-initialize DisplayCtrl before its first Initialize.
 * Single A53 foreground + its IRQ only. Other cores must not call this API. */
int DisplayInitialize(DisplayCtrl *dispPtr,
                      u8 *framePtr[DISPLAY_NUM_FRAMES], u32 stride);
int DisplaySetupInterrupts(DisplayCtrl *dispPtr, XScuGic *controller);
int DisplayStart(DisplayCtrl *dispPtr);
int DisplayStop(DisplayCtrl *dispPtr);
int display_acquire_draw_frame(DisplayCtrl *dispPtr, DisplayDrawFrame *draw);
int display_present_frame(DisplayCtrl *dispPtr, const DisplayDrawFrame *draw);
int display_cancel_draw_frame(DisplayCtrl *dispPtr, const DisplayDrawFrame *draw);
void display_service(DisplayCtrl *dispPtr);

#endif /* DISPLAY_CTRL_H_ */
