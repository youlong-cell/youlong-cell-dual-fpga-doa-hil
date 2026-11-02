#ifndef SERVICE_PROFILE_H
#define SERVICE_PROFILE_H
#include <stdint.h>
#include "xtime_l.h"

enum sp_id {
 SP_LOOP, SP_ADC, SP_DMA_CHECK0, SP_DMA_CHECK1, SP_DMA_ARM0, SP_DMA_ARM1,
 SP_DMA_INIT0, SP_DMA_INIT1, SP_FFT, SP_FFT_BANK, SP_FFT_CONVERT,
 SP_FINE_DOA, SP_SESSION_CONFIG, SP_FINE_STOP, SP_FINE_COMMAND,
 SP_UI_DRAW, SP_PRESENT, SP_DISPLAY_SERVICE, SP_DISPLAY_START, SP_DISPLAY_STOP,
 SP_DP_WAKE, SP_DP_TRAIN, SP_DP_AUX_READY, SP_DP_AUX_REPLY, SP_DP_AUX_SEND,
 SP_DP_TRAIN_FSM, SP_DP_CLOCK_RECOVERY, SP_DP_PHY_READY, SP_DP_WAIT,
 SP_UART_RX, SP_UART_TX, SP_LOG, SP_LOG_BATCH, SP_PROFILE_REPORT,
 SP_MMIO_READ, SP_MMIO_WRITE, SP_CACHE_FLUSH, SP_CACHE_INVALIDATE,
 SP_GIC_IRQ, SP_DPDMA_IRQ, SP_CACHE_FLUSH_IRQ, SP_CACHE_INVALIDATE_IRQ,
 SP_MMIO_READ_IRQ, SP_MMIO_WRITE_IRQ, SP_DPDMA_DRAIN, SP_BUS_CHECK, SP_ATB_INIT,
 SP_DP_PIXEL_CLOCK, SP_UI_SPECTRUM, SP_COUNT, SP_NONE=255
};
enum { SP_TRACE_CAP=512, SP_SLOW_CAP=64, SP_SLOW_US=20000 };
typedef struct {
 uint64_t start_ticks, end_ticks, cost_us, irq_us, detail, parent_start_ticks;
 uint32_t state, status, iterations;
 int32_t return_rc;
 uint16_t id, parent;
 uint8_t phase, irq;
} sp_event_t;
typedef struct {
 uint64_t calls, last_us, max_us, total_ticks, slow_count, last_irq_us, max_irq_us;
 sp_event_t last, worst;
} sp_stats_t;
typedef struct {
 uint64_t start_ticks, detail;
 uint32_t state, status, iterations;
 uint16_t id, parent;
 uint8_t phase, irq;
} sp_active_t;
typedef struct {
 sp_event_t event;
 sp_active_t previous;
 uint64_t irq_ticks_before;
 int irq_owner;
} sp_scope_t;
/* Live breadcrumbs remain readable if a call never returns. No UART here. */
extern volatile sp_active_t service_profile_active[2];
extern volatile uint64_t service_profile_slow_dropped[2];
extern volatile uint64_t service_profile_trace_total[2];
sp_scope_t sp_begin(enum sp_id id,uint32_t state,uint64_t detail);
sp_scope_t sp_irq_begin(enum sp_id id,uint32_t state,uint64_t detail);
void sp_end(sp_scope_t *scope);
void sp_mark(sp_scope_t *scope,uint32_t state,uint32_t status,uint64_t detail);
void sp_iteration(sp_scope_t *scope,uint32_t state,uint32_t status);
void sp_runtime_begin(void);
const char *sp_name(unsigned id);
int sp_stats_copy(unsigned phase,unsigned id,sp_stats_t *out);
int sp_slow_pop(sp_event_t *out);
int sp_trace_copy(unsigned irq,uint64_t sequence,sp_event_t *out);
uint64_t sp_ticks_us(uint64_t ticks);
int sp_in_irq(void);
/* GNU cleanup ensures every existing early-return path is measured without
 * changing its return value or adding a new wait. Both compilers are GNU C. */
#define SP_SCOPE(v,id,state,detail) sp_scope_t v __attribute__((cleanup(sp_end)))=sp_begin(id,state,detail)
#define SP_IRQ_SCOPE(v,id,state,detail) sp_scope_t v __attribute__((cleanup(sp_end)))=sp_irq_begin(id,state,detail)
#define SP_RETURN(v,rc) do{int sp_rc_=(rc);(v).event.return_rc=sp_rc_;return sp_rc_;}while(0)
void service_cache_flush(uintptr_t address,uint32_t bytes);
void service_cache_invalidate(uintptr_t address,uint32_t bytes);
#endif
