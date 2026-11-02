#ifndef EPOCH_JOURNAL_H
#define EPOCH_JOURNAL_H
#include <stddef.h>
#include <stdint.h>

/* Pure-C journal core; no MMIO, QSPI opcodes or automatic formatting.
 * SINGLE OWNER: serialize ALL users of this flash, including IRQs/updaters.
 * The backend must wait for device completion, detect errors, and provide
 * coherent uncached reads. A program callback touches one page at most.
 * Commit uses a DIFFERENT physical page: no assumed repeat-page capability.
 */
typedef enum {
    EPOCH_OK=0, EPOCH_UNPROVISIONED=1, EPOCH_LAYOUT_UNVERIFIED=2,
    EPOCH_LAYOUT_INVALID=3, EPOCH_IO=4, EPOCH_CORRUPT=5,
    EPOCH_EXHAUSTED=6, EPOCH_READBACK=7, EPOCH_NOT_MOUNTED=8,
    EPOCH_NOT_BLANK=9
} epoch_status_t;

typedef struct {
    uint32_t partition_base;
    uint32_t flash_bytes;
    uint32_t erase_bytes;
    uint32_t page_bytes;
    uint64_t namespace_id;
    /* Must be explicit, reviewed deployment evidence, not autodetection of
     * erased-looking data. Default hardware configuration leaves these zero. */
    unsigned int layout_verified;
} epoch_layout_t;

typedef struct {
    void *context;
    int (*read)(void *,uint32_t,uint8_t *,size_t);
    int (*program)(void *,uint32_t,const uint8_t *,size_t);
    int (*erase)(void *,uint32_t,size_t);
} epoch_storage_t;

typedef struct {
    epoch_layout_t layout;
    epoch_storage_t storage;
    uint64_t high_water;
    uint32_t free_address[2];
    unsigned int newest_block;
    unsigned int initialized;
    unsigned int mounted;
    epoch_status_t last_status;
} epoch_journal_t;

/* Mount never writes. Dirty/corrupt commit pages fail closed; no fallback to
 * an older epoch. Blank flash is UNPROVISIONED, NOT epoch=0 ready to issue. */
epoch_status_t epoch_journal_mount(epoch_journal_t *,const epoch_layout_t *,
                                  const epoch_storage_t *);
/* Explicit factory/operator action ONLY on an entirely blank partition.
 * floor is an externally authorized high-water bound, not a reset counter.
 * Do not call at normal boot. Does not erase or repair existing contents. */
epoch_status_t epoch_journal_provision(epoch_journal_t *,uint64_t floor);
/* Re-scan, persist high_water+1, verify, THEN return a usable nonzero epoch.
 * *epoch_out is zero on EVERY failure. Never issue mount's high_water itself.
 * Ambiguous I/O/readback failure blocks this object until explicit re-mount. */
epoch_status_t epoch_journal_reserve(epoch_journal_t *,uint64_t *epoch_out);
#endif
