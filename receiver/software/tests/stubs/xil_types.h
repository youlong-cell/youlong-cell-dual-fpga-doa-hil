#ifndef DISPLAY_TEST_XIL_TYPES_H
#define DISPLAY_TEST_XIL_TYPES_H
#include <stdint.h>
#include <stddef.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef uint64_t u64;
typedef int8_t s8; typedef int16_t s16; typedef int32_t s32; typedef int64_t s64;
typedef uintptr_t UINTPTR; typedef intptr_t INTPTR;
#define UPPER_32_BITS(x) ((u32)((u64)(x) >> 32))
#define LOWER_32_BITS(x) ((u32)(u64)(x))
#define XPAR_XDPDMA_NUM_INSTANCES 1
#endif
