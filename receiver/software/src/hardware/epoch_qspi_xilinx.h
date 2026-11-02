#ifndef EPOCH_QSPI_XILINX_H
#define EPOCH_QSPI_XILINX_H
#include "epoch_qspi_backend.h"
#include "xqspipsu.h"

/* Permanent storage; no QSPI GIC ISR may be routed/enabled concurrently.
 * Serviced manually via SDK InterruptHandler, IO mode only (no DMA/cache RX).
 * Uses four Msg slots: v1.17 reads Msg[MsgCnt] during CS-deassert completion,
 * beyond the two data messages. Padding remains live and zero initialized.
 */
typedef struct {
    XQspiPsu controller;
    XQspiPsu_Msg message[4];
    uint8_t tx[261],rx[256];
    volatile uint32_t done,event;
    unsigned int initialized,fenced,allow_mutation,in_call;
} epoch_qspi_xilinx_t;

/* Only for an isolated A53 standalone diagnostic/maintenance application.
 * Caller guarantees PS initialized, no flash XIP, no concurrent flash user,
 * QSPI IRQ disabled/unrouted at GIC. exclusive=1 acknowledges this contract.
 * Configures controller, not Flash contents/mode/protection.
 */
int epoch_qspi_xilinx_init(epoch_qspi_xilinx_t *,uint16_t device_id,unsigned int exclusive);
epoch_qspi_io_t epoch_qspi_xilinx_io(epoch_qspi_xilinx_t *);
/* Explicit separate opt-in, defaults 0. Never called by readonly main. */
int epoch_qspi_xilinx_allow_writes(epoch_qspi_xilinx_t *,unsigned int reviewed);
#endif
