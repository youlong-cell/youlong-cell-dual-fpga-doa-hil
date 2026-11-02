#ifndef DOA_RESULT_TEST_XTIME_H
#define DOA_RESULT_TEST_XTIME_H
#include <stdint.h>
typedef uint64_t XTime;
#define COUNTS_PER_SECOND UINT64_C(1000000)
void XTime_GetTime(XTime *out);
#endif
