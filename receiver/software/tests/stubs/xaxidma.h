#ifndef RB5_DMA_MOCK
#define RB5_DMA_MOCK
#include "xil_types.h"
typedef struct {UINTPTR RegBase;int Sg;} XAxiDma;
typedef struct {u16 DeviceId;UINTPTR BaseAddr;} XAxiDma_Config;
#include "xaxidma_hw.h"
XAxiDma_Config *XAxiDma_LookupConfig(u16);
int XAxiDma_CfgInitialize(XAxiDma*,XAxiDma_Config*);
int XAxiDma_HasSg(XAxiDma*);
int XAxiDma_SimpleTransfer(XAxiDma*,UINTPTR,u32,int);
void XAxiDma_IntrDisable(XAxiDma*,u32,int);
void XAxiDma_IntrAckIrq(XAxiDma*,u32,int);
#endif
