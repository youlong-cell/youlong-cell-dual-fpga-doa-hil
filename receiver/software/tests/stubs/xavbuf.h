#ifndef DISPLAY_TEST_AVBUF_H
#define DISPLAY_TEST_AVBUF_H
#include "xil_types.h"
typedef int XAVBuf_VideoFormat;
typedef struct {u32 Mode;} XAVBuf_VideoAttribute;
typedef struct {u32 dummy;} XAVBuf;
#define RGBA8888 1
#define RGB_8BPC 2
#define XAVBUF_VIDSTREAM1_NONE 0
#define XAVBUF_VIDSTREAM2_NONLIVE_GFX 1
#define XAVBUF_PS_CLK 0
XAVBuf_VideoAttribute *XAVBuf_GetNLGraphicsAttribute(XAVBuf_VideoFormat);
XAVBuf_VideoAttribute *XAVBuf_GetNLiveVideoAttribute(XAVBuf_VideoFormat);
void XAVBuf_CfgInitialize(XAVBuf *, UINTPTR, u16);
int XAVBuf_SetInputNonLiveGraphicsFormat(XAVBuf *, XAVBuf_VideoFormat);
void XAVBuf_EnableGraphicsBuffers(XAVBuf *, u8);
void XAVBuf_SetOutputVideoFormat(XAVBuf *, XAVBuf_VideoFormat);
void XAVBuf_InputVideoSelect(XAVBuf *, u8, u8);
void XAVBuf_ConfigureGraphicsPipeline(XAVBuf *);
void XAVBuf_ConfigureOutputVideo(XAVBuf *);
void XAVBuf_SetBlenderAlpha(XAVBuf *, u8, u8);
void XAVBuf_SetAudioVideoClkSrc(XAVBuf *, u8, u8);
void XAVBuf_SoftReset(XAVBuf *);
#endif
