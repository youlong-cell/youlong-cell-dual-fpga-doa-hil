#ifndef DISPLAY_TEST_DPPSU_H
#define DISPLAY_TEST_DPPSU_H
#include "xil_types.h"
typedef struct {UINTPTR BaseAddr;} XDpPsu_Config;
typedef struct {
    u8 SupportEnhancedFramingMode, MaxLaneCount, MaxLinkRate,
       SupportDownspreadControl, LaneCount, LinkRate;
} XDpPsu_LinkConfig;
typedef struct {
    XDpPsu_Config Config;
    XDpPsu_LinkConfig LinkConfig;
    struct {u32 PixelClockHz;} MsaConfig;
} XDpPsu;
#define XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE 0x600
#define XDPPSU_CENC_RGB 0
#define XDPPSU_SOFT_RESET 0x1c
#define XDPPSU_INTERRUPT_SIG_STATE 0x130
#define XDPPSU_INTERRUPT_SIG_STATE_HPD_STATE_MASK 1
u32 XDpPsu_ReadReg(UINTPTR, u32);
XDpPsu_Config *XDpPsu_LookupConfig(u16);
void XDpPsu_CfgInitialize(XDpPsu *, XDpPsu_Config *, UINTPTR);
int XDpPsu_InitializeTx(XDpPsu *);
int XDpPsu_AuxWrite(XDpPsu *, u32, u32, u8 *);
int XDpPsu_GetRxCapabilities(XDpPsu *);
int XDpPsu_SetEnhancedFrameMode(XDpPsu *, u8);
int XDpPsu_SetLaneCount(XDpPsu *, u8);
int XDpPsu_SetLinkRate(XDpPsu *, u8);
int XDpPsu_SetDownspread(XDpPsu *, u8);
int XDpPsu_EstablishLink(XDpPsu *);
void XDpPsu_SetColorEncode(XDpPsu *, u8);
void XDpPsu_CfgMsaSetBpc(XDpPsu *, u8);
void XDpPsu_CfgMsaEnSynchClkMode(XDpPsu *, u8);
void XDpPsu_CfgMsaUseStandardVideoMode(XDpPsu *, int);
void XDpPsu_WriteReg(UINTPTR, u32, u32);
void XDpPsu_SetMsaValues(XDpPsu *);
void XDpPsu_EnableMainLink(XDpPsu *, u8);
int XDpPsu_IsConnected(XDpPsu *);
int XDpPsu_CheckLinkStatus(XDpPsu *, u8);
#endif
