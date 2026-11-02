/* Force include after the official inline definitions, before driver macros.
 * All isolated application and AXI-DMA source accesses are checked. */
#include "xil_io.h"
#include "debug_mmio.h"
#define Xil_In32 debug_mmio_in32
#define Xil_Out32 debug_mmio_out32
#include "xil_cache.h"
#include "service_profile.h"
#ifdef Xil_DCacheFlushRange
#undef Xil_DCacheFlushRange
#endif
#define Xil_DCacheFlushRange service_cache_flush
#define Xil_DCacheInvalidateRange service_cache_invalidate
