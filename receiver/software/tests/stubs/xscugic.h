#ifndef DISPLAY_TEST_GIC_H
#define DISPLAY_TEST_GIC_H
#include "xil_types.h"
typedef void (*Xil_InterruptHandler)(void *);
typedef struct {u32 dummy;} XScuGic;
typedef struct {UINTPTR CpuBaseAddress;} XScuGic_Config;
XScuGic_Config *XScuGic_LookupConfig(u16);
int XScuGic_CfgInitialize(XScuGic*,XScuGic_Config*,UINTPTR);
void XScuGic_InterruptHandler(void*);
int XScuGic_Connect(XScuGic*,u32,Xil_InterruptHandler,void*);
void XScuGic_Enable(XScuGic*,u32);void XScuGic_Disable(XScuGic*,u32);
void XScuGic_SetPriorityTriggerType(XScuGic*,u32,u8,u8);
#endif
