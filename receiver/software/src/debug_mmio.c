/* ENGINEERING_TEST / NOT_SIGNED_OFF. Boot-time PS ATB, not PL modification.
 * Only HPM0_LPD (AFIFS2) is changed, before any PL master access.
 * Timeout-generated OKAY retires the single CPU transaction; sticky status
 * makes the DATA INVALID and permanently fences ALL subsequent PL access.
 * This is diagnostic containment, never a fabricated successful PL result.
 * First ATB timeout REQUIRES cold restart. Never clear/retry in this boot.
 */
#include "xil_io.h"
#include "xparameters.h"
#include "debug_mmio.h"
#include "lpd_slcr.h"
#include "xpseudo_asm.h"
#include "service_profile.h"
_Static_assert(LPD_SLCR_BASEADDR==XPAR_PSU_LPD_SLCR_S_AXI_BASEADDR,"LPD base mismatch");
static int enabled, fenced;
static u32 raw_status;
static UINTPTR failed_address;
static int is_pl(UINTPTR a)
{
    /* Exact active hardware ranges from the matching BSP; no guessed base. */
    return (a>=XPAR_AD9238_SAMPLE_0_S00_AXI_BASEADDR && a<=XPAR_AD9238_SAMPLE_0_S00_AXI_HIGHADDR) ||
           (a>=XPAR_AD9238_SAMPLE_1_S00_AXI_BASEADDR && a<=XPAR_AD9238_SAMPLE_1_S00_AXI_HIGHADDR) ||
           (a>=XPAR_AXI_DMA_0_BASEADDR && a<=XPAR_AXI_DMA_0_HIGHADDR) ||
           (a>=XPAR_AXI_DMA_1_BASEADDR && a<=XPAR_AXI_DMA_1_HIGHADDR) ||
           (a>=XPAR_AXI_GPIO_FFT_BASEADDR && a<=XPAR_AXI_GPIO_FFT_HIGHADDR) ||
           (a>=XPAR_FFT_RESULT_BRAM_CTRL_S_AXI_BASEADDR && a<=XPAR_FFT_RESULT_BRAM_CTRL_S_AXI_HIGHADDR) ||
           (a>=XPAR_AXI_GPIO_MODE_BASEADDR && a<=XPAR_AXI_GPIO_MODE_HIGHADDR) ||
           (a>=XPAR_AXI_GPIO_FINE_CMD_BASEADDR && a<=XPAR_AXI_GPIO_FINE_CMD_HIGHADDR) ||
           (a>=XPAR_AXI_GPIO_FINE_STATUS_BASEADDR && a<=XPAR_AXI_GPIO_FINE_STATUS_HIGHADDR);
}
static int inspect(UINTPTR a)
{
    raw_status |= Xil_In32(LPD_SLCR_ERR_ATB_ISR);
    if(raw_status & LPD_SLCR_ERR_ATB_ISR_AFIFS2_MASK) {
        fenced=1; if(!failed_address) failed_address=a;
    }
    return enabled && !fenced;
}
int debug_atb_initialize(void)
{
    SP_SCOPE(p,SP_ATB_INIT,0,LPD_SLCR_ATB_RESP_EN);
    u32 mask=LPD_SLCR_ATB_RESP_EN_AFIFS2_MASK;
    /* Preserve the unrelated LPD inbound/core-switch ATB. No traffic yet. */
    enabled=0;
    raw_status=Xil_In32(LPD_SLCR_ERR_ATB_ISR);
    if(raw_status) { fenced=1; return -1; }
    /* Do not inherit an unknown long timeout from another boot/master. */
    if((Xil_In32(LPD_SLCR_ATB_PRESCALE)&0x1FFFFU)>0x10000U) {
        fenced=1; return -3;
    }
    Xil_Out32(LPD_SLCR_ATB_RESP_EN,Xil_In32(LPD_SLCR_ATB_RESP_EN)&~mask);
    Xil_Out32(LPD_SLCR_ATB_RESP_TYPE,Xil_In32(LPD_SLCR_ATB_RESP_TYPE)&~mask);
    Xil_Out32(LPD_SLCR_ATB_CMD_STORE_EN,Xil_In32(LPD_SLCR_ATB_CMD_STORE_EN)|mask);
    /* Shared prescale kept if already enabled; otherwise minimum timeout.
     * 131071 LPD_LSBUS clocks, hardware clock independent of CPU polling. */
    if(!(Xil_In32(LPD_SLCR_ATB_PRESCALE)&LPD_SLCR_ATB_PRESCALE_ENABLE_MASK))
        Xil_Out32(LPD_SLCR_ATB_PRESCALE,LPD_SLCR_ATB_PRESCALE_ENABLE_MASK);
    Xil_Out32(LPD_SLCR_ATB_RESP_EN,Xil_In32(LPD_SLCR_ATB_RESP_EN)|mask);
    dsb();
    enabled=(Xil_In32(LPD_SLCR_ATB_RESP_EN)&mask) &&
            !(Xil_In32(LPD_SLCR_ATB_RESP_TYPE)&mask) &&
            (Xil_In32(LPD_SLCR_ATB_CMD_STORE_EN)&mask) &&
            (Xil_In32(LPD_SLCR_ATB_PRESCALE)&LPD_SLCR_ATB_PRESCALE_ENABLE_MASK);
    if(!enabled) fenced=1;
    return enabled?0:-2;
}
int debug_pl_bus_ok(void) { SP_SCOPE(p,SP_BUS_CHECK,0,LPD_SLCR_ERR_ATB_ISR);
    int ok=inspect(0);sp_mark(&p,ok?1:2,raw_status,LPD_SLCR_ERR_ATB_ISR);return ok; }
u32 debug_atb_status(void) { return raw_status; }
UINTPTR debug_fault_address(void) { return failed_address; }
u32 debug_mmio_in32(UINTPTR a)
{
    SP_SCOPE(p,sp_in_irq()?SP_MMIO_READ_IRQ:SP_MMIO_READ,(uint32_t)is_pl(a),a);
    u32 data;
    if(!is_pl(a)){data=Xil_In32(a);sp_mark(&p,0,data,a);return data;}
    if(!inspect(a))return 0;
    dsb(); data=Xil_In32(a); dsb();
    int ok=inspect(a);sp_mark(&p,ok?1:2,ok?data:raw_status,a);return ok?data:0;
}
void debug_mmio_out32(UINTPTR a,u32 data)
{
    SP_SCOPE(p,sp_in_irq()?SP_MMIO_WRITE_IRQ:SP_MMIO_WRITE,(uint32_t)is_pl(a),a);
    sp_mark(&p,p.event.state,data,a);
    if(!is_pl(a)) { Xil_Out32(a,data);return; }
    if(!inspect(a))return;
    dsb();Xil_Out32(a,data);dsb();(void)inspect(a);
}
