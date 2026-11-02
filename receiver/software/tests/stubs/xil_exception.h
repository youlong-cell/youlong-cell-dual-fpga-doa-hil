#include "xscugic.h"
typedef void (*Xil_ExceptionHandler)(void*);
#define XIL_EXCEPTION_ID_INT 2
void Xil_ExceptionInit(void);
void Xil_ExceptionRegisterHandler(int,Xil_ExceptionHandler,void*);
void Xil_ExceptionEnable(void);
