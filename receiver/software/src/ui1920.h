#ifndef UI1920_H
#define UI1920_H
/* Native pixels; no low-resolution canvas or full-frame scaling. */
enum {
 UI_HEADER_H=80, UI_FOOTER_Y=970, UI_FOOTER_H=230,
 UI_LEFT_X=24, UI_LEFT_W=644, UI_RIGHT_X=684, UI_RIGHT_W=1212,
 UI_DOA_Y=100, UI_DOA_H=850, UI_CONFIG_Y=500, UI_CONFIG_H=260,
 UI_SESSION_Y=760, UI_SESSION_H=260,
 UI_FFT_Y=100, UI_FFT_H=850,
 UI_PLOT_X=764, UI_PLOT_Y=244, UI_PLOT_W=1108, UI_PLOT_H=500,
 UI_TITLE_PX=52, UI_SECTION_PX=30, UI_ANGLE_PX=144, UI_PARAM_PX=24,
 UI_STATUS_PX=18, UI_DEBUG_PX=16,
 UI_TARGET_FPS=60, UI_DRAW_LIMIT_US=16000
};
static inline uint64_t ui_next_deadline(uint64_t started,uint64_t completed,uint64_t rate)
{
 uint64_t period=rate/UI_TARGET_FPS;
 if(!period)period=1;
 return completed-started>=period?completed+1:started+period;
}
#endif
