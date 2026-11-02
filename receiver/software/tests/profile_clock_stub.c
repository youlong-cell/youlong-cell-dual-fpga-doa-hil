/* Fallback only; suites with their own clock/cache mocks override these. */
#include "xtime_l.h"
#include "xil_types.h"
#ifndef PROFILE_CLOCK_FROM_TEST
void XTime_GetTime(XTime *out){static XTime t=100;*out=t++;}
#endif
#ifndef PROFILE_FLUSH_FROM_TEST
void Xil_DCacheFlushRange(UINTPTR a,u32 n){(void)a;(void)n;}
#endif
void Xil_DCacheInvalidateRange(UINTPTR a,u32 n){(void)a;(void)n;}
