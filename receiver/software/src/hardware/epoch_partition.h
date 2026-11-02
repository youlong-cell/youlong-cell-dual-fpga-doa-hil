#ifndef EPOCH_PARTITION_H
#define EPOCH_PARTITION_H
#include "epoch_journal.h"

/* AXU2CGA/B hardware manual REV1.0, pp.10-11:
 * MT25QU256ABA1EW9-0SIT, single 256Mbit = 32MiB flash.
 * Micron MT25QU256ABA Rev.L: 256-byte pages, uniform 64KiB sectors.
 * User confirms no old contents need preserving. Reserve the last two sectors
 * for the journal; this is a deployment plan, NOT evidence from the board.
 * These addresses exceed 16MiB: never truncate to a 3-byte address.
 */
#define EPOCH_AXU2CGA_FLASH_BYTES UINT32_C(0x02000000)
#define EPOCH_AXU2CGA_ERASE_BYTES UINT32_C(0x00010000)
#define EPOCH_AXU2CGA_PAGE_BYTES UINT32_C(0x00000100)
#define EPOCH_AXU2CGA_BASE UINT32_C(0x01fe0000)
#define EPOCH_AXU2CGA_JEDEC_MFR UINT8_C(0x20)
#define EPOCH_AXU2CGA_JEDEC_TYPE UINT8_C(0xbb)
#define EPOCH_AXU2CGA_JEDEC_DENSITY UINT8_C(0x19)

/* Expected ID is only a preliminary filter (other parts share three bytes).
 * Keep namespace unassigned and layout_verified=0 until board identity,
 * protocol/protection/addressing, backend and updater exclusion are verified.
 * No enable API or automatic provisioning is intentionally provided here.
 */
static inline epoch_layout_t epoch_partition_axu2cga_expected(void)
{
    epoch_layout_t p={EPOCH_AXU2CGA_BASE,EPOCH_AXU2CGA_FLASH_BYTES,
        EPOCH_AXU2CGA_ERASE_BYTES,EPOCH_AXU2CGA_PAGE_BYTES,0,0};
    return p;
}

/* User authorizes a QSPI journal; physical profile is NOT verified yet.
 * Do not infer addresses/capacity from a demo's Flash_Config_Table or BOOT.bin.
 * Target runtime backend is intentionally not connected to production main.
 * The legacy default remains disabled. A board manual is not a runtime probe.
 */
static inline epoch_layout_t epoch_partition_unverified(void)
{
    epoch_layout_t p={0,0,0,0,0,0};
    return p; /* mount -> EPOCH_LAYOUT_UNVERIFIED, no read/erase/program */
}
#endif
