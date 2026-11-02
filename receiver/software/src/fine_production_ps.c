#include "fine_production_ps.h"
#include "xparameters.h"
#include "xil_io.h"
#include "xtime_l.h"
#include "service_profile.h"
#include <string.h>

#if defined(XPAR_AXI_GPIO_FINE_CMD_BASEADDR) && defined(XPAR_AXI_GPIO_FINE_STATUS_BASEADDR)
#define PL_FINE_PRESENT 1
#define CMD_BASE XPAR_AXI_GPIO_FINE_CMD_BASEADDR
#define STATUS_BASE XPAR_AXI_GPIO_FINE_STATUS_BASEADDR
#else
#define PL_FINE_PRESENT 0
#endif
static int available,fenced;
static uint32_t toggle;
static unsigned control_owned;
static pl_fine_lifecycle_t lifecycle_observer;
static pl_fine_lifecycle_listener_t lifecycle_listener;
void pl_fine_lifecycle_set_listener(pl_fine_lifecycle_listener_t listener)
{
    lifecycle_listener=listener;
    if(listener)listener(&lifecycle_observer);
}
static void lifecycle_invalidate(pl_fine_lifecycle_event_t event)
{
    if(lifecycle_observer.generation!=UINT64_MAX)lifecycle_observer.generation++;
    lifecycle_observer.ready=0;lifecycle_observer.session_epoch=0;
    lifecycle_observer.config_version=0;lifecycle_observer.event=event;
    if(lifecycle_listener)lifecycle_listener(&lifecycle_observer);
}
int pl_fine_lifecycle_snapshot(pl_fine_lifecycle_t *out)
{
    if(!out)return -1;
    *out=lifecycle_observer;return 0;
}
#if PL_FINE_PRESENT
static uint32_t status_read(void){return Xil_In32((UINTPTR)STATUS_BASE);}
static int command(unsigned int op,unsigned int index,uint32_t data,uint32_t *out)
{
    SP_SCOPE(p,SP_FINE_COMMAND,(op<<16)|index,data);
    XTime first,now;uint32_t s;unsigned poll_budget=1000000;
    if(!available || fenced || control_owned || op>15 || index>255)return -1;
    s=status_read();if((s>>16)!=1 || (s&4U))return -2;
    /* Derive next token from acknowledged mailbox; never blindly reuse the
     * reset software toggle when PL is still running after a PS restart. */
    toggle=(s&1U)?0U:UINT32_C(0x80000000);
    Xil_Out32((UINTPTR)CMD_BASE+8U,data);
    Xil_Out32((UINTPTR)CMD_BASE,toggle|((uint32_t)op<<24)|index);
    XTime_GetTime(&first);
    do {
        s=status_read();
        sp_iteration(&p,(op<<16)|index,s);
        if((s>>16)!=1){fenced=1;SP_RETURN(p,-3);}
        if(!(s&4U) && (s&1U)==(toggle>>31)) {
            if(out)*out=Xil_In32((UINTPTR)STATUS_BASE+8U);
            SP_RETURN(p,(s&2U)?0:-(100+(int)((s>>8)&255U)));
        }
        XTime_GetTime(&now);
    } while(--poll_budget && now-first<(XTime)(COUNTS_PER_SECOND/20U));
    /* No automatic resend after uncertain completion; coordinated reset
     * then a new durable session is required. */
    fenced=1;SP_RETURN(p,-4);
}
static int tag_write(uint64_t epoch,uint32_t seq,uint32_t version)
{
    return command(0,0,(uint32_t)epoch,0) || command(0,1,(uint32_t)(epoch>>32),0) ||
           command(0,2,seq,0) || command(0,3,version,0) ? -1:0;
}
#endif
int pl_fine_init(void)
{
    lifecycle_invalidate(PL_FINE_LIFECYCLE_INIT);
#if PL_FINE_PRESENT
    fenced=0;available=(status_read()>>16)==1;
    if(available){
        Xil_Out32((UINTPTR)CMD_BASE+4U,0);Xil_Out32((UINTPTR)CMD_BASE+12U,0);
        Xil_Out32((UINTPTR)STATUS_BASE+4U,UINT32_MAX);Xil_Out32((UINTPTR)STATUS_BASE+12U,UINT32_MAX);
    }
    return available;
#else
    available=0;fenced=0;toggle=0;return 0;
#endif
}
int pl_fine_stop(void)
{
    /* Invalidate the software view even if STOP completion is uncertain. */
    lifecycle_invalidate(PL_FINE_LIFECYCLE_STOP);
#if PL_FINE_PRESENT
    return command(4,0,0,0);
#else
    return -1;
#endif
}
int pl_fine_status(unsigned int index,uint32_t *out)
{
#if PL_FINE_PRESENT
    return out?command(11,index,0,out):-1;
#else
    (void)index;(void)out;return -1;
#endif
}
#if PL_FINE_PRESENT
/* Transport sequence shared by two EXPLICIT policies. This helper cannot
 * allocate an epoch or bypass either caller's admission prerequisites. */
static int install_configuration(uint64_t epoch,const pl_fine_configuration_t *cfg)
{
    unsigned int i;uint32_t lifecycle=0,version=0;
    if(tag_write(epoch,0,0) || command(3,0,0,0) || command(5,0,1,0))goto fail;
    for(i=0;i<PL_FINE_CONFIG_WORDS;i++)if(command(1,i,cfg->fine[i],0))goto fail;
    if(command(2,0,0,&version))goto fail;
    for(i=0;i<4;i++)if(command(6,i,cfg->detector[i],0))goto fail;
    if(command(7,0,0,0))goto fail;
    /* INSTALL is only control-ready. Final COMMIT must complete the dual-domain
     * ARM before software may claim that the new session is searching. */
    if(command(11,0,0,&lifecycle) || (lifecycle>>16)!=UINT32_C(0xf101) ||
       !(lifecycle&UINT32_C(0x80)) || (lifecycle&UINT32_C(0x40)))goto fail;
    if(lifecycle_observer.generation==UINT64_MAX)goto fail;
    lifecycle_observer.generation++;
    lifecycle_observer.session_epoch=epoch;
    lifecycle_observer.config_version=version;
    lifecycle_observer.event=PL_FINE_LIFECYCLE_SESSION_READY;
    lifecycle_observer.ready=1;
    if(lifecycle_listener)lifecycle_listener(&lifecycle_observer);
    return 0;
fail:
    (void)pl_fine_stop();return -4;
}
#endif
int pl_fine_start_new_session(epoch_journal_t *journal,const pl_fine_configuration_t *cfg)
{
    SP_SCOPE(p,SP_SESSION_CONFIG,1,0);
#if PL_FINE_PRESENT
    uint64_t epoch=0;
    /* Production durable policy unchanged: never fabricate a mounted journal. */
    if(!journal || !cfg || cfg->reviewed!=1 || !journal->mounted ||
       !journal->layout.layout_verified || !journal->layout.namespace_id)return -1;
    if(pl_fine_stop())return -2;
    if(epoch_journal_reserve(journal,&epoch)!=EPOCH_OK || !epoch)return -3;
    return install_configuration(epoch,cfg);
#else
    (void)journal;(void)cfg;return -1;
#endif
}
#if defined(ENGINEERING_SESSION) && ENGINEERING_SESSION
int pl_fine_start_engineering_session(uint64_t epoch,const pl_fine_configuration_t *cfg)
{
    SP_SCOPE(p,SP_SESSION_CONFIG,2,0);
#if PL_FINE_PRESENT
    uint32_t state=0,lo=0,hi=0;
    /* Explicit ENGINEERING_ONLY profile may enable a HIL mathematical model.
     * Numeric calibration enable does not certify physical calibration. */
    if(!cfg || cfg->reviewed || !epoch || cfg->fine[0]>1 || cfg->fine[19]>1 ||
       (cfg->fine[0] && !cfg->fine[8]) ||
       (cfg->fine[19] && (!cfg->fine[23] || !(cfg->fine[20]|cfg->fine[21]))))return -1;
    if(pl_fine_stop())return -2;
    if(pl_fine_status(0,&state) || (state>>16)!=0xf101 ||
       (state&0xff00U) || (state&0xfbU)!=0x40U ||
       pl_fine_status(3,&lo) || pl_fine_status(4,&hi))return -3;
    if(epoch<=(((uint64_t)hi<<32)|lo))return -3;
    /* PL independently enforces epoch > last_epoch, including its retained
     * high-water mark. A rejected install is never automatically replayed. */
    if(install_configuration(epoch,cfg))return -4;
    if(pl_fine_status(0,&state) || (state>>16)!=0xf101 ||
       (state&0xc6U)!=0x86U){(void)pl_fine_stop();return -5;}
    return 0;
#else
    (void)epoch;(void)cfg;return -1;
#endif
}
#endif
int pl_fine_poll(pl_fine_packet_t *p)
{
#if PL_FINE_PRESENT
    unsigned int i;result_identity_t id;
    if(!available || fenced || !p)return -1;
    if(!(status_read()&8U))return 0;
    for(i=0;i<PL_FINE_PACKET_WORDS;i++)if(command(8,i,0,&p->word[i]))return -2;
    return pl_fine_packet_identity(p,&id)?-3:1;
#else
    (void)p;return 0;
#endif
}
int pl_fine_result_ack(const result_identity_t *id)
{
#if PL_FINE_PRESENT
    if(!id || tag_write(id->session_epoch,id->candidate_seq,id->config_version))return -1;
    return command(9,0,0,0);
#else
    (void)id;return -1;
#endif
}
int pl_fine_clear_fault(uint64_t epoch,uint32_t seq)
{
#if PL_FINE_PRESENT
    if(tag_write(epoch,seq,0))return -1;
    return command(10,0,0,0);
#else
    (void)epoch;(void)seq;return -1;
#endif
}
int pl_fine_set_consumer(unsigned int mode)
{
#if PL_FINE_PRESENT
    return mode<2?command(5,0,mode,0):-1;
#else
    (void)mode;return -1;
#endif
}
int pl_fine_release_window(uint64_t epoch,uint32_t seq)
{
#if PL_FINE_PRESENT
    if(tag_write(epoch,seq,0))return -1;
    return command(12,0,0,0);
#else
    (void)epoch;(void)seq;return -1;
#endif
}
#if defined(ENGINEERING_SESSION) && ENGINEERING_SESSION
/* Cooperative variant of the EXISTING STOP/tag/INSTALL/mode/24+4/COMMIT/F101
 * sequence. No new PL opcodes, no durable policy, no packet consumer. */
typedef struct {
    pl_fine_configuration_t cfg;
    uint64_t floor, previous, epoch, old_epoch;
    uint32_t phase, pending, stop_only, cancel, version, token, response, runtime;
    int error;
    XTime started;
} fine_control_t;
static fine_control_t control;
static uint64_t control_reserved_epoch;
int pl_fine_control_runtime(uint32_t *out)
{
    if(!out || (control.runtime>>16)!=0xf101)return 0;
    *out=control.runtime;return 1;
}

int pl_fine_control_busy(void){return control_owned!=0;}

int pl_fine_control_begin(const pl_fine_configuration_t *cfg,uint64_t floor)
{
#if PL_FINE_PRESENT
    if(!available || fenced || control_owned)return -1;
    if(cfg && (!floor || cfg->reviewed || cfg->fine[0]>1 || cfg->fine[19]>1 ||
       (cfg->fine[0]&&!cfg->fine[8]) ||
       (cfg->fine[19]&&(!cfg->fine[23] || !(cfg->fine[20]|cfg->fine[21])))))return -2;
    memset(&control,0,sizeof control);
    control.floor=floor;control.stop_only=cfg==0;
    if(cfg)control.cfg=*cfg;
    control.old_epoch=lifecycle_observer.session_epoch;
    if(control_reserved_epoch<control.old_epoch)control_reserved_epoch=control.old_epoch;
    control_owned=1;
    lifecycle_invalidate(PL_FINE_LIFECYCLE_STOP);
    return 0;
#else
    (void)cfg;(void)floor;return -1;
#endif
}
int pl_fine_control_cancel(void)
{
    if(!control_owned)return pl_fine_control_begin(0,0);
    control.cancel=1;return 0;
}
#if PL_FINE_PRESENT
static int control_hard_fail(int rc)
{
    /* Clock/bus/reset/unknown completion: fence, do not resend or guess epoch. */
    fenced=1;control_owned=0;control.error=rc;
    lifecycle_invalidate(PL_FINE_LIFECYCLE_STOP);
    return rc;
}
static int control_reject(int rc)
{
    /* A definitive rejection/check failure may issue one NEW STOP, not replay. */
    if(control.phase==0 || control.error)return control_hard_fail(rc);
    control.error=rc;control.phase=0;control.stop_only=1;control.pending=0;
    return 0;
}
#endif
int pl_fine_control_step(void)
{
    SP_SCOPE(profile_step,SP_FINE_COMMAND,UINT32_C(0x80000000)|control.phase,control.pending);
#if PL_FINE_PRESENT
    uint32_t s,op=0,index=0,data=0;XTime now;
    if(!control_owned)return control.error?control.error:1;
    if(!available || fenced)return control_hard_fail(-201);
    if(control.pending){
        s=status_read();
        if((s>>16)!=1)return control_hard_fail(-202);
        if((s&4U) || (s&1U)!=control.token){
            XTime_GetTime(&now);
            if(now<control.started || now-control.started>=(XTime)(COUNTS_PER_SECOND/20U))
                return control_hard_fail(-203);
            return 0;
        }
        control.pending=0;
        if(!(s&2U))return control_reject(-(300+(int)((s>>8)&255U)));
        control.response=Xil_In32((UINTPTR)STATUS_BASE+8U);
        if(control.cancel && control.phase!=0){
            control.cancel=0;control.phase=0;control.stop_only=1;return 0;
        }
        switch(control.phase){
        case 1:
            if((control.response>>16)!=0xf101 || (control.response&0xff00U) ||
               (control.response&0xfbU)!=0x40U)return control_reject(-204);
            control.runtime=control.response;
            break;
        case 2:
            if(control.stop_only){
                if((control.response>>16)!=0xf101 || (control.response&0xff00U) ||
                   (control.response&0xfbU)!=0x40U)return control_hard_fail(-214);
                control.runtime=control.response;
                control_owned=0;return control.error?control.error:1;
            }
            control.previous=control.response;break;
        case 3:
            control.previous|=(uint64_t)control.response<<32;
            if(control.previous<control.old_epoch)return control_reject(-205);
            control.epoch=control.previous;
            if(control.epoch<control_reserved_epoch)control.epoch=control_reserved_epoch;
            if(control.epoch<control.floor-1)control.epoch=control.floor-1;
            if(control.epoch==UINT64_MAX)return control_reject(-206);
            control.epoch++;control_reserved_epoch=control.epoch;
            break;
        case 34:
            control.version=control.response;
            if(!control.version)return control_reject(-207);
            break;
        case 40:case 41:
            if((control.response>>16)!=0xf101 || (control.response&0xff00U) ||
               (control.response&0x30U) ||
               (control.response&0xc6U)!=0x86U)return control_reject(-208);
            control.runtime=control.response;
            break;
        case 42:
            if(control.response!=(uint32_t)control.epoch)return control_reject(-209);
            break;
        case 43:
            if(control.response!=(uint32_t)(control.epoch>>32))return control_reject(-210);
            break;
        case 44:
            if(control.response!=control.version ||
               lifecycle_observer.generation==UINT64_MAX)return control_reject(-211);
            lifecycle_observer.generation++;
            lifecycle_observer.session_epoch=control.epoch;
            lifecycle_observer.config_version=control.version;
            lifecycle_observer.event=PL_FINE_LIFECYCLE_SESSION_READY;
            lifecycle_observer.ready=1;control_owned=0;
            if(lifecycle_listener)lifecycle_listener(&lifecycle_observer);
            return 1;
        default:break;
        }
        control.phase++;return 0;
    }
    if(control.cancel){control.cancel=0;control.phase=0;control.stop_only=1;}
    switch(control.phase){
    case 0:op=4;break;
    case 1:op=11;break;
    case 2:op=11;index=control.stop_only?0:3;break;
    case 3:op=11;index=4;break;
    case 4:case 5:case 6:case 7:
        op=0;index=control.phase-4;
        data=index==0?(uint32_t)control.epoch:index==1?(uint32_t)(control.epoch>>32):0;
        break;
    case 8:op=3;break;
    case 9:op=5;data=1;break;
    case 34:op=2;break;
    case 39:op=7;break;
    case 40:case 41:op=11;break;
    case 42:op=11;index=3;break;
    case 43:op=11;index=4;break;
    case 44:op=11;index=1;break;
    default:
        if(control.phase>=10 && control.phase<=33){
            op=1;index=control.phase-10;data=control.cfg.fine[index];
        }else if(control.phase>=35 && control.phase<=38){
            op=6;index=control.phase-35;data=control.cfg.detector[index];
        }else return control_hard_fail(-212);
    }
    s=status_read();
    if((s>>16)!=1 || (s&4U))return control_hard_fail(-213);
    control.token=(s&1U)?0U:1U;
    Xil_Out32((UINTPTR)CMD_BASE+8U,data);
    Xil_Out32((UINTPTR)CMD_BASE,(control.token<<31)|(op<<24)|index);
    XTime_GetTime(&control.started);control.pending=1;
    return 0;
#else
    return -1;
#endif
}
#endif
