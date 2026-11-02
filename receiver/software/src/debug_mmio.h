#ifndef DEBUG_MMIO_H
#define DEBUG_MMIO_H
#include "xil_types.h"
int debug_atb_initialize(void);
int debug_pl_bus_ok(void);
u32 debug_atb_status(void);
UINTPTR debug_fault_address(void);
u32 debug_mmio_in32(UINTPTR address);
void debug_mmio_out32(UINTPTR address, u32 data);
#endif
