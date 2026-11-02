/* Telemetry only. No MMIO polling, allocation, UART, delay or safety changes.
 * One A53 foreground writer; GIC IRQs are non-nested and use separate rings.
 * No lock disables interrupts while measuring a service. */
#include <string.h>
#include "service_profile.h"
#include "xil_cache.h"
typedef struct { uint32_t seq;sp_stats_t data; } stat_record_t;
typedef struct { uint32_t seq;uint64_t sequence;sp_event_t data; } trace_record_t;
static stat_record_t stats[2][SP_COUNT];
static trace_record_t trace[2][SP_TRACE_CAP];
static sp_event_t slow[2][SP_SLOW_CAP];
static uint32_t slow_head[2],slow_tail[2];
static volatile uint64_t irq_ticks;
static unsigned irq_context, runtime;
volatile sp_active_t service_profile_active[2];
volatile uint64_t service_profile_slow_dropped[2],service_profile_trace_total[2];
static const char *names[SP_COUNT]={
 "MAIN_LOOP","ADC_SERVICE","DMA_CHECK_CH0","DMA_CHECK_CH1","DMA_ARM_CH0","DMA_ARM_CH1",
 "DMA_INIT_CH0","DMA_INIT_CH1","FFT_SERVICE","FFT_BANK_SERVICE","FFT_CONVERT",
 "FINE_DOA_SERVICE","SESSION_CONFIG","FINE_STOP","FINE_CMD_ACK",
 "UI_DRAW","DISPLAY_PRESENT","DP_HOTPLUG_SERVICE","DISPLAY_START","DISPLAY_STOP",
 "DP_WAKE","DP_TRAIN","DP_AUX_READY","DP_AUX_REPLY","DP_AUX_SEND",
 "DP_TRAIN_FSM","DP_CLOCK_RECOVERY","DP_PHY_READY","DP_EXISTING_WAIT",
 "UART_RX","UART_TX","UART_FORMAT_ENQUEUE","LOG_BATCH","PROFILE_REPORT",
 "MMIO_READ","MMIO_WRITE","CACHE_FLUSH","CACHE_INVALIDATE",
 "GIC_IRQ","DPDMA_IRQ","CACHE_FLUSH_IRQ","CACHE_INVALIDATE_IRQ","MMIO_READ_IRQ","MMIO_WRITE_IRQ","DPDMA_DRAIN_WAIT",
 "PL_BUS_CHECK","ATB_INIT","DP_PIXEL_CLOCK","UI_SPECTRUM_FILTER"};
static uint64_t ticks(void){XTime t;XTime_GetTime(&t);return t;}
uint64_t sp_ticks_us(uint64_t t)
{return (t/COUNTS_PER_SECOND)*1000000ULL+(t%COUNTS_PER_SECOND)*1000000ULL/COUNTS_PER_SECOND;}
const char *sp_name(unsigned id){return id<SP_COUNT?names[id]:"ROOT";}
int sp_in_irq(void){return irq_context!=0;}
void sp_runtime_begin(void){runtime=1;}
sp_scope_t sp_begin(enum sp_id id,uint32_t state,uint64_t detail)
{
 sp_scope_t c={0};unsigned q=irq_context?1:0;
 c.previous=service_profile_active[q];
 c.event.id=(uint16_t)id;c.event.parent=c.previous.start_ticks?c.previous.id:SP_NONE;
 c.event.parent_start_ticks=c.previous.start_ticks;
 c.event.state=state;c.event.detail=detail;c.event.phase=(uint8_t)runtime;c.event.irq=(uint8_t)q;
 c.irq_ticks_before=irq_ticks;c.event.start_ticks=ticks();
 sp_active_t a={c.event.start_ticks,detail,state,0,0,(uint16_t)id,c.event.parent,(uint8_t)runtime,(uint8_t)q};
 service_profile_active[q]=a;
 return c;
}
sp_scope_t sp_irq_begin(enum sp_id id,uint32_t state,uint64_t detail)
{irq_context=1;sp_scope_t c=sp_begin(id,state,detail);c.irq_owner=1;return c;}
void sp_mark(sp_scope_t *c,uint32_t state,uint32_t status,uint64_t detail)
{
 c->event.state=state;c->event.status=status;c->event.detail=detail;
 service_profile_active[c->event.irq].state=state;
 service_profile_active[c->event.irq].status=status;
 service_profile_active[c->event.irq].detail=detail;
}
void sp_iteration(sp_scope_t *c,uint32_t state,uint32_t status)
{c->event.iterations++;service_profile_active[c->event.irq].iterations=c->event.iterations;
 sp_mark(c,state,status,c->event.detail);}
void sp_end(sp_scope_t *c)
{
 unsigned q=c->event.irq;sp_event_t e=c->event;stat_record_t *s;
 uint64_t dt,number;uint32_t h,t;trace_record_t *r;
 e.end_ticks=ticks();dt=e.end_ticks-e.start_ticks;e.cost_us=sp_ticks_us(dt);
 e.irq_us=q?0:sp_ticks_us(irq_ticks-c->irq_ticks_before);
 if(e.irq_us>e.cost_us)e.irq_us=e.cost_us; /* timestamp-boundary preemption */
 if(e.id<SP_COUNT){
  s=&stats[e.phase][e.id];__atomic_add_fetch(&s->seq,1,__ATOMIC_ACQ_REL);
  s->data.calls++;s->data.last_us=e.cost_us;s->data.last_irq_us=e.irq_us;
  s->data.total_ticks+=dt;s->data.last=e;
  if(s->data.calls==1 || e.cost_us>s->data.max_us){s->data.max_us=e.cost_us;s->data.worst=e;}
  if(e.irq_us>s->data.max_irq_us)s->data.max_irq_us=e.irq_us;
  if(e.cost_us>SP_SLOW_US)s->data.slow_count++;
  __atomic_add_fetch(&s->seq,1,__ATOMIC_RELEASE);
 }
 number=service_profile_trace_total[q];r=&trace[q][number&(SP_TRACE_CAP-1)];
 __atomic_add_fetch(&r->seq,1,__ATOMIC_ACQ_REL);r->sequence=number;r->data=e;
 __atomic_add_fetch(&r->seq,1,__ATOMIC_RELEASE);service_profile_trace_total[q]=number+1;
 if(e.cost_us>SP_SLOW_US){
  h=__atomic_load_n(&slow_head[q],__ATOMIC_RELAXED);t=__atomic_load_n(&slow_tail[q],__ATOMIC_ACQUIRE);
  if(h-t<SP_SLOW_CAP){slow[q][h&(SP_SLOW_CAP-1)]=e;__atomic_store_n(&slow_head[q],h+1,__ATOMIC_RELEASE);}
  else service_profile_slow_dropped[q]++;
 }
 service_profile_active[q]=c->previous;
 if(c->irq_owner){irq_ticks+=dt;irq_context=0;}
}
int sp_stats_copy(unsigned phase,unsigned id,sp_stats_t *out)
{
 if(phase>1 || id>=SP_COUNT || !out)return 0;
 stat_record_t *s=&stats[phase][id];
 for(unsigned n=0;n<3;n++){
  uint32_t before=__atomic_load_n(&s->seq,__ATOMIC_ACQUIRE);if(before&1)continue;
  *out=s->data;__atomic_thread_fence(__ATOMIC_ACQUIRE);
  if(before==__atomic_load_n(&s->seq,__ATOMIC_ACQUIRE))return 1;
 }return 0; /* never spin forever if IRQ updates race with snapshot */
}
int sp_slow_pop(sp_event_t *out)
{
 if(!out)return 0;
 for(unsigned q=0;q<2;q++){
  uint32_t t=__atomic_load_n(&slow_tail[q],__ATOMIC_RELAXED);
  if(t==__atomic_load_n(&slow_head[q],__ATOMIC_ACQUIRE))continue;
  *out=slow[q][t&(SP_SLOW_CAP-1)];__atomic_store_n(&slow_tail[q],t+1,__ATOMIC_RELEASE);return 1;
 }return 0;
}
int sp_trace_copy(unsigned q,uint64_t number,sp_event_t *out)
{
 if(q>1 || !out)return 0;
 trace_record_t *r=&trace[q][number&(SP_TRACE_CAP-1)];
 for(unsigned n=0;n<3;n++){
  uint32_t before=__atomic_load_n(&r->seq,__ATOMIC_ACQUIRE);if(before&1)continue;
  uint64_t actual=r->sequence;*out=r->data;__atomic_thread_fence(__ATOMIC_ACQUIRE);
  if(before==__atomic_load_n(&r->seq,__ATOMIC_ACQUIRE))return actual==number && number<service_profile_trace_total[q];
 }return 0;
}
void service_cache_flush(uintptr_t a,uint32_t n)
{
 SP_SCOPE(c,sp_in_irq()?SP_CACHE_FLUSH_IRQ:SP_CACHE_FLUSH,n,a);
 Xil_DCacheFlushRange(a,n);
}
void service_cache_invalidate(uintptr_t a,uint32_t n)
{
 SP_SCOPE(c,sp_in_irq()?SP_CACHE_INVALIDATE_IRQ:SP_CACHE_INVALIDATE,n,a);
 Xil_DCacheInvalidateRange(a,n);
}
