#ifndef EPOCH_QSPI_BACKEND_H
#define EPOCH_QSPI_BACKEND_H
#include "epoch_journal.h"

/* Single owner across ALL users/IRQs/updaters. Not a thread lock.
 * xfer keeps CS asserted for TX then RX, x1 STR, and is itself bounded.
 * On failure it must quiesce/fence controller references before returning.
 * now_us is monotonic; every wait also has an iteration guard.
 */
typedef struct {
    void *context;
    int (*xfer)(void *,const uint8_t *,size_t,uint8_t *,size_t,uint32_t);
    uint64_t (*now_us)(void *);
} epoch_qspi_io_t;

typedef enum {
    EQ_OK=0, EQ_ARGUMENT, EQ_TRANSPORT, EQ_TIMEOUT, EQ_PROFILE,
    EQ_NOT_READY, EQ_PROTECTED, EQ_FENCED, EQ_READBACK, EQ_RANGE,
    EQ_NOT_BLANK, EQ_LAYOUT, EQ_NOT_ARMED, EQ_REENTRANT
} epoch_qspi_status_t;

#define EQ_TRANSFER_US 10000U
#define EQ_PROGRAM_US 10000U
#define EQ_ERASE_US 2000000U
#define EQ_POLL_LIMIT 100000U

typedef struct {
    uint8_t id[20],sr,fsr,nvcr[2],vcr,evcr,ear,sfdp[16];
    /* 32 4KiB addresses in the two journal sectors, including last sector. */
    uint8_t volatile_lock[32],nonvolatile_lock[32];
    unsigned int stage; /* 0 empty, 1 SR, 2 ID, 3 registers, 4 SFDP, 5 locks */
    unsigned int locks_read; /* only these entries are valid, even on failure */
    epoch_qspi_status_t status;
} epoch_qspi_diagnostic_t;

typedef struct {
    epoch_qspi_io_t io;
    epoch_layout_t layout;
    epoch_qspi_diagnostic_t diagnostic;
    unsigned int initialized,armed,fenced,in_call;
    epoch_qspi_status_t last_status;
} epoch_qspi_backend_t;

/* Only reads: 05,9F,70,B5,85,65,C8,5A,E0,E2. Stops on wrong identity.
 * Never WREN/clear-error/unlock/reset/address-mode/config write.
 * Passing does NOT automatically authorize deployment or writes.
 */
epoch_qspi_status_t epoch_qspi_diagnose(const epoch_qspi_io_t *,epoch_qspi_diagnostic_t *);
epoch_qspi_status_t epoch_qspi_backend_init(epoch_qspi_backend_t *,const epoch_qspi_io_t *);
/* Explicit software deployment gate, not a substitute for physical evidence.
 * reviewed=1 only after actual chip/backend/map/updater/HIL review.
 * Also requires the transport owner to explicitly enable its write capability.
 * open itself performs reads only; default partition helper cannot pass.
 */
epoch_qspi_status_t epoch_qspi_backend_open(epoch_qspi_backend_t *,const epoch_layout_t *,unsigned int reviewed);
void epoch_qspi_backend_close(epoch_qspi_backend_t *);
epoch_storage_t epoch_qspi_backend_storage(epoch_qspi_backend_t *);
int epoch_qspi_backend_read(void *,uint32_t,uint8_t *,size_t);
int epoch_qspi_backend_program(void *,uint32_t,const uint8_t *,size_t);
int epoch_qspi_backend_erase(void *,uint32_t,size_t);
#endif
