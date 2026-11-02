/* Native competition renderer: immutable inputs only; no MMIO/ACK/DSP. */
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "debug_ui.h"
#include "ui1920.h"
#include "font5x7.h"
#include "font12x12.h"
#include "display_draw_safe.h"
#include "hardware/sample_clock.h"
#include "ui_alpha_font.h"
#include "ui_zh.h"
typedef struct {u8 r,g,b;} color;
static const color bg={8,15,24},panel={14,27,39},ink={229,241,246},muted={134,163,181},
 cyan={70,216,241},amber={255,190,79},green={87,232,159},red={255,100,103},grid={34,56,71};
typedef struct {u8 *pixels;enum debug_page page;unsigned reduced;u64 status_ms;} frame_style;
static frame_style style_cache[DISPLAY_NUM_FRAMES];
static unsigned style_next;
static int static_refresh(u8*f,const debug_view_t*v)
{
 for(unsigned i=0;i<DISPLAY_NUM_FRAMES;i++)if(style_cache[i].pixels==f){
  int changed=style_cache[i].page!=v->page||style_cache[i].reduced!=v->ui_low_detail;
  style_cache[i].page=v->page;style_cache[i].reduced=v->ui_low_detail;return changed;
 }
 style_cache[style_next]=(frame_style){f,v->page,v->ui_low_detail,0};
 style_next=(style_next+1)%DISPLAY_NUM_FRAMES;return 1;
}
static int system_text_due(u8*f,const debug_view_t*v,int refresh)
{
 for(unsigned i=0;i<DISPLAY_NUM_FRAMES;i++)if(style_cache[i].pixels==f){
  u64 last=style_cache[i].status_ms,period=v->ui_low_detail?1000:250;
  if(refresh||v->uptime_ms<last||v->uptime_ms-last>=period){style_cache[i].status_ms=v->uptime_ms;return 1;}
  return 0;
 }
 return 1;
}
const char *debug_state_name(enum debug_state s)
{switch(s){case DBG_OK:return "OK";case DBG_ERROR:return "ERROR";case DBG_NO_DATA:return "NO DATA";default:return "NOT INITIALIZED";}}
void debug_doa_visible_snapshot(const debug_view_t *v,const doa_published_result_t *source,doa_published_result_t *visible)
{
 if(!visible)return;
 memset(visible,0,sizeof *visible);
 if(source)*visible=*source;
 if(!v||v->input_pair!=INPUT_SIGNAL_DETECTED||!v->result_fresh||v->session_state!=ENG_MEASURING)visible->available=0;
 const hil_profile_t *p=hil_profile_current();
 if(!p->geometry_valid||!p->calibration_valid)visible->available=0;
 if(visible->available&&pl_fine_bits(&visible->packet,PL_THETA_VALID_BIT,1)&&
  (visible->identity.geometry_id!=p->geometry_id||visible->identity.calibration_profile_id!=p->profile_id))visible->available=0;
}
static void rect(u8*f,int x,int y,int w,int h,color c)
{lcd_draw_rect(f,DISPLAY_STRIDE,x,y,w,h,c.r,c.g,c.b);}
static void line(u8*f,int x,int y,int a,int b,color c)
{lcd_draw_line(f,DISPLAY_STRIDE,x,y,a,b,c.r,c.g,c.b);}
static void text(u8*f,int x,int y,int right,const char*s,int height,color c)
{
 if(!s||height<1||height>UI_ANGLE_PX)return;
 char translated[320];s=ui_zh_text(s,translated,sizeof translated);
 /* Legacy call sites retain coordinates; type hierarchy changes, not layout. */
 if(height==20)height=UI_STATUS_PX;
 if(height==28)height=UI_PARAM_PX;
 if(height==36)height=UI_TITLE_PX;
#ifdef UI_RENDER_TRACE
 extern void ui_test_text(const char *,int,int,int);
 ui_test_text(s,x,y,height);
#endif
 ui_alpha_draw(f,x,y,right,s,(unsigned)height,c.r,c.g,c.b);
}
static void card(u8*f,int x,int y,int w,int h,const char*name)
{rect(f,x,y,w,h,panel);text(f,x+24,y+24,x+w-24,name,UI_SECTION_PX,ink);}
static color state_color(enum debug_state s)
{return s==DBG_OK?green:s==DBG_ERROR?red:amber;}
/* Fixed 10-degree dial: no per-frame trigonometry for static arc/ticks. */
static const short dial[19][2]={{-1000,0},{-985,-174},{-940,-342},{-866,-500},{-766,-643},
 {-643,-766},{-500,-866},{-342,-940},{-174,-985},{0,-1000},{174,-985},{342,-940},
 {500,-866},{643,-766},{766,-643},{866,-500},{940,-342},{985,-174},{1000,0}};
static void degree(u8*f,int x,int y,color c)
{ui_alpha_draw(f,x-4,y-8,1920,"\xc2\xb0",18,c.r,c.g,c.b);}
static void angle(u8*f,const doa_render_model_t*m,int y,int height)
{
 char b[32];if(!m->pointer_valid){text(f,190,y,644,"---",height,muted);return;}
 uint64_t mag=m->theta_code<0?(uint64_t)-m->theta_code:(uint64_t)m->theta_code;
 uint64_t tenth=(mag*1800+(UINT64_C(1)<<34))>>35;
 snprintf(b,sizeof b,"%c%llu.%llu",m->theta_code<0?'-':'+',(unsigned long long)(tenth/10),(unsigned long long)(tenth%10));
 int width=ui_alpha_width(b,(unsigned)height),degree_width=ui_alpha_width("\xc2\xb0",(unsigned)height);
 int x=24+(644-width-degree_width)/2;
 text(f,x,y,644,b,height,green);
 ui_alpha_draw(f,x+width,y,668,"\xc2\xb0",(unsigned)height,green.r,green.g,green.b);
}
static void doa_card(u8*f,const debug_view_t*v,const doa_render_model_t*m)
{
 card(f,24,100,644,850,"DOA RESULT");text(f,454,128,644,"AZIMUTH",20,muted);
 char smooth[40],raw[40];
 int pair_valid=m->pointer_valid&&!m->stale&&v->doa_angles.available&&
     v->doa_angles.raw_theta_code==m->theta_code;
 snprintf(smooth,sizeof smooth,"---");snprintf(raw,sizeof raw,"---");
 if(pair_valid){doa_ui_smooth_text(smooth,sizeof smooth,v->doa_angles.smooth_doa);
     doa_ui_raw_text(raw,sizeof raw,m->theta_code);}
 text(f,48,176,644,"平滑 DOA",24,muted);
 int sw=ui_alpha_width(smooth,96),dw=ui_alpha_width("\xc2\xb0",96),sx=24+(644-sw-(pair_valid?dw:0))/2;
 text(f,sx,208,644,smooth,96,pair_valid?green:muted);
 if(pair_valid)ui_alpha_draw(f,sx+sw,208,668,"\xc2\xb0",96,green.r,green.g,green.b);
 text(f,48,322,258,"实时 DOA",24,muted);
 int rw=ui_alpha_width(raw,52);
 text(f,278,306,644,raw,52,pair_valid?ink:muted);
 if(pair_valid)ui_alpha_draw(f,278+rw,306,668,"\xc2\xb0",52,ink.r,ink.g,ink.b);
 text(f,48,618,644,m->stale?"STALE / ENGINEERING ESTIMATE":m->pointer_valid?"实时指针 / ENGINEERING_ESTIMATE":!strcmp(m->state,"INVALID")?"SIGNAL INVALID":"NO CURRENT DIRECTION",18,
  m->pointer_valid&&!m->stale?green:!strcmp(m->state,"INVALID")?red:amber);
 const int cx=346,cy=568,r=168;
 for(unsigned i=1;i<19;i++)line(f,cx+dial[i-1][0]*r/1000,cy+dial[i-1][1]*r/1000,cx+dial[i][0]*r/1000,cy+dial[i][1]*r/1000,muted);
 for(unsigned i=0;i<19;i+=3)line(f,cx+dial[i][0]*r/1000,cy+dial[i][1]*r/1000,cx+dial[i][0]*(r-10)/1000,cy+dial[i][1]*(r-10)/1000,muted);
 text(f,164,586,270,"-90",24,muted);degree(f,239,590,muted);text(f,340,370,390,"0",24,muted);
 text(f,488,586,620,"+90",24,muted);degree(f,564,590,muted);
 if(m->pointer_valid){double a=(double)m->theta_code*3.14159265358979323846/(double)(UINT64_C(1)<<35);
  line(f,cx,cy,cx+(int)lround((r-12)*sin(a)),cy-(int)lround((r-12)*cos(a)),green);rect(f,cx-3,cy-3,7,7,green);}
 const char*labels[]={"Frequency","Raw Phase","Cal Phase","Result Age"};
 const char*age_value=!strncmp(m->age,"RESULT AGE ",11)?m->age+11:m->age;
 char age_local[64];
 if(m->stale){snprintf(age_local,sizeof age_local,"%llu ms / 已过期",(unsigned long long)v->result_age_ms);age_value=age_local;}
 const char*values[]={m->frequency,m->raw_phase,m->cal_phase,age_value};
 for(unsigned i=0;i<4;i++){text(f,48,642+i*62,266,labels[i],20,muted);text(f,278,640+i*62,644,values[i],28,ink);}
 text(f,48,910,644,"STATUS: ENGINEERING MODE",16,amber);(void)v;
}
static void hil_card(u8*f,const doa_render_model_t*m)
{
 card(f,24,100,644,850,"HIL VALIDATION");text(f,48,190,644,"SOURCE CONFIG",UI_SECTION_PX,cyan);
 text(f,48,240,644,"Frequency: ---",24,muted);text(f,48,280,644,"Phase Offset: ---",24,muted);
 text(f,48,328,644,"SOURCE NOT CONFIGURED",20,amber);
 text(f,48,398,644,"MEASURED / FINAL PL RESULT",UI_SECTION_PX,cyan);text(f,48,450,644,m->frequency,28,ink);
 text(f,48,498,644,"Raw Phase",20,muted);text(f,278,498,644,m->raw_phase,28,ink);
 text(f,48,562,644,"DOA RESULT",UI_SECTION_PX,cyan);angle(f,m,614,96);
 text(f,48,744,644,"Reference angle: ---",24,muted);text(f,48,792,644,"Error: ---",28,muted);
 text(f,48,852,644,"NO SOURCE TRUTH / NO ERROR CLAIM",16,amber);
 text(f,48,910,644,"Measured values never use source settings",16,muted);
}
static void detail_card(u8*f,const debug_view_t*v,const doa_render_model_t*m)
{
 char b[128],n[40];card(f,24,100,644,850,v->page==PAGE_ADC?"ENGINEERING DETAIL":"SYSTEM DETAIL");
 for(unsigned c=0;c<2;c++){
  debug_format_milli(n,sizeof n,v->rms_millicodes[c]);
  snprintf(b,sizeof b,"ADC CH%u: %s  RMS %s",c,v->adc_fresh?ui_zh_state(v->adc[c]):"无数据",v->adc_fresh?n:"---");
  text(f,48,184+c*34,644,b,20,v->adc_fresh?state_color(v->adc[c]):amber);
  snprintf(b,sizeof b,"DMA CH%u: %s IOC %lu ERR %lu",c,ui_zh_state(v->dma[c]),(unsigned long)v->transfers[c],(unsigned long)v->errors[c]);
  text(f,48,276+c*34,644,b,16,state_color(v->dma[c]));
 }
 snprintf(b,sizeof b,"帧计数 FFT %lu / ADC %lu",(unsigned long)v->fft_frames,(unsigned long)v->capture_seq);text(f,48,378,644,b,20,ink);
 snprintf(b,sizeof b,"Fine 忙时丢弃 %lu / 结果丢弃 %lu",(unsigned long)v->fine_busy_drop,(unsigned long)v->fine_result_drop);text(f,48,422,644,b,16,muted);
 text(f,48,458,644,"FIFO OCCUPANCY: NOT AVAILABLE",16,muted);
 snprintf(b,sizeof b,"配置 %lu  GEO %lu CAL %lu",(unsigned long)v->config_version,(unsigned long)hil_profile_current()->geometry_id,(unsigned long)hil_profile_current()->profile_id);text(f,48,516,644,b,20,ink);
 snprintf(b,sizeof b,"会话 %s",v->session_state==ENG_MEASURING?"已启用":v->session_state==ENG_ERROR?"错误":"已关闭");text(f,48,560,644,b,UI_STATUS_PX,v->session_state==ENG_ERROR?red:amber);
 snprintf(b,sizeof b,"Epoch %016llX",(unsigned long long)v->session_epoch);text(f,48,602,644,b,16,muted);
 snprintf(b,sizeof b,"F101 %08lX STATUS %08lX",(unsigned long)v->lifecycle,(unsigned long)v->fine_status);text(f,48,642,644,b,16,muted);
 snprintf(b,sizeof b,"故障 %lu  发布 %llu 无效 %llu",(unsigned long)v->fine_fault_code,(unsigned long long)v->fine_published,(unsigned long long)v->fine_invalid);text(f,48,684,644,b,16,v->fine_fault_code?red:muted);
 snprintf(b,sizeof b,"主循环峰值 %llu us / 间隔 %llu us",(unsigned long long)v->loop_max_us,(unsigned long long)v->service_gap_max_us);text(f,48,736,644,b,16,muted);
 snprintf(b,sizeof b,"UI %lu.%03lu FPS / 绘制 %llu us",(unsigned long)(v->display_fps_milli/1000),(unsigned long)(v->display_fps_milli%1000),(unsigned long long)v->renderer_max_us);text(f,48,776,644,b,16,muted);
 text(f,48,826,644,m->pointer_valid?"ENGINEERING_ESTIMATE":m->state,20,m->pointer_valid?green:amber);
 text(f,48,868,644,m->reason,16,amber);text(f,48,910,644,"Detailed errors on UART / no added polling",16,muted);
}
static void spectrum(u8*f,const debug_view_t*v,const spectrum_view_snapshot_t*s,const doa_render_model_t*m,int refresh)
{
 char b[120];if(refresh)card(f,684,100,1212,850,"LIVE FFT SPECTRUM");
 else{rect(f,704,184,1172,40,panel);rect(f,UI_PLOT_X,UI_PLOT_Y,UI_PLOT_W+1,UI_PLOT_H+1,panel);rect(f,704,814,1172,106,panel);}
 /* Alpha edges must not be repeatedly blended over a cached glyph. */
 if(refresh){text(f,1410,130,1620,"CH0 cyan",20,cyan);text(f,1660,130,1872,"CH1 amber",20,amber);}
 snprintf(b,sizeof b,"目标 = 最终 F_HAT  %s",m->frequency);text(f,708,192,1872,b,24,m->target_valid?green:muted);
 unsigned rows=v->ui_low_detail?2:4,cols=v->ui_low_detail?4:8;
 for(unsigned j=0;j<=rows;j++){int y=UI_PLOT_Y+(int)j*UI_PLOT_H/(int)rows;line(f,UI_PLOT_X,y,UI_PLOT_X+UI_PLOT_W,y,grid);if(refresh){snprintf(b,sizeof b,"-%u",j*120/rows);text(f,700,y-8,756,b,16,muted);}}
 for(unsigned j=0;j<=cols;j++){int x=UI_PLOT_X+(int)j*UI_PLOT_W/(int)cols;line(f,x,UI_PLOT_Y,x,UI_PLOT_Y+UI_PLOT_H,grid);}
 if(v->spectrum_fresh&&s&&s->available){
  for(unsigned c=0;c<2;c++){int last_x=0,last_y=0,last_valid=0;
   for(unsigned k=2;k<FFT_BINS-1;k++){float db=s->ch[c].mag_db[k];if(!isfinite(db)){last_valid=0;continue;}
    if(db>0)db=0;
    if(db< -120)db=-120;
    int x=UI_PLOT_X+(int)((uint64_t)k*UI_PLOT_W/512),y=UI_PLOT_Y+(int)lroundf(-db*UI_PLOT_H/120);
    if(last_valid)line(f,last_x,last_y,x,y,c?amber:cyan);
    last_x=x;last_y=y;last_valid=1;
   }
  }
 }else{int y=UI_PLOT_Y+110*UI_PLOT_H/120;line(f,UI_PLOT_X,y,UI_PLOT_X+UI_PLOT_W,y,muted);
  text(f,1050,446,1850,"NO FFT DATA",28,muted);text(f,1050,492,1850,"-110 dBFS REFERENCE ONLY",16,muted);}
 if(m->target_valid){uint64_t max=((uint64_t)ADC_SAMPLE_RATE_HZ<<23);
  if(m->frequency_code<=max){int x=UI_PLOT_X+(int)(m->frequency_code*UI_PLOT_W/max);line(f,x,UI_PLOT_Y,x,UI_PLOT_Y+UI_PLOT_H,green);}}
 if(refresh){text(f,764,770,1000,"0 MHz",24,muted);text(f,1190,770,1550,"Frequency / MHz",24,muted);
  snprintf(b,sizeof b,"%lu.%03lu MHz",(unsigned long)(ADC_SAMPLE_RATE_HZ/2000000),(unsigned long)((ADC_SAMPLE_RATE_HZ/2000)%1000));text(f,1610,770,1872,b,24,muted);}
 for(unsigned c=0;c<2;c++){char n[32];
  if(v->spectrum_fresh&&v->peak[c].valid){debug_format_milli(n,sizeof n,v->peak[c].dbfs_milli);snprintf(b,sizeof b,"CH%u 峰值  %s dBFS",c,n);}
  else snprintf(b,sizeof b,"CH%u 峰值  ---",c);
  text(f,708+c*590,830,1280+c*590,b,24,c?amber:cyan);
 }
 text(f,708,898,1872,"Live spectrum and final DOA are independent snapshots",16,muted);
}
static void bottom(u8*f,const debug_view_t*v,const doa_render_model_t*m,int refresh)
{
 char b[160];const hil_profile_t*p=hil_profile_current();
 if(refresh){card(f,24,970,1108,210,"TARGET INFO");card(f,1148,970,748,210,"SYSTEM STATUS");
  text(f,48,1054,240,"Frequency",20,muted);text(f,656,1054,1100,"SNR: ---",20,muted);
  text(f,48,1100,1100,"Noise Floor: -110 dBFS (UI)    Latency: ---",20,muted);}
 rect(f,250,1050,380,34,panel);text(f,250,1054,630,m->frequency,24,ink);
 rect(f,1172,1034,700,70,panel);
 int adc_error=v->adc[0]==DBG_ERROR||v->adc[1]==DBG_ERROR;
 int adc_ok=v->adc_fresh&&v->adc[0]==DBG_OK&&v->adc[1]==DBG_OK;
 int fft_ok=v->spectrum_fresh&&v->fft==DBG_OK;
 snprintf(b,sizeof b,"ADC %s",adc_error?"错误":adc_ok?"正常":"无数据");text(f,1172,1040,1460,b,UI_STATUS_PX,adc_error?red:adc_ok?green:amber);
 snprintf(b,sizeof b,"FFT %s",v->fft==DBG_ERROR?"错误":fft_ok?"运行中":"无数据");text(f,1510,1040,1872,b,UI_STATUS_PX,v->fft==DBG_ERROR?red:fft_ok?green:amber);
 int fine_error=v->session_state==ENG_ERROR||v->fine_fault_code;
 snprintf(b,sizeof b,"Fine %s",fine_error?"错误":m->target_valid?"就绪":"未就绪");text(f,1172,1080,1500,b,UI_STATUS_PX,fine_error?red:m->target_valid?green:amber);
 snprintf(b,sizeof b,"DOA %s",m->pointer_valid?(m->stale?"已过期":"就绪"):!strcmp(m->state,"INVALID")?"无效":"未就绪");text(f,1510,1080,1872,b,UI_STATUS_PX,!strcmp(m->state,"INVALID")?red:m->pointer_valid&&!m->stale?green:amber);
 if(system_text_due(f,v,refresh)){
  rect(f,48,1150,1056,30,panel);text(f,48,1156,1108,"SNR / processing latency unavailable; no substituted metric",16,muted);
  rect(f,1172,1130,700,50,panel);snprintf(b,sizeof b,"d=5m c=300000000 偏置 %s",p->bias_display);text(f,1172,1130,1872,b,16,muted);
  text(f,1172,1162,1872,"ENGINEERING_ESTIMATE / UNCALIBRATED",16,amber);
 }
}
void debug_draw(u8*f,const debug_view_t*v,const spectrum_view_snapshot_t*s,const doa_published_result_t*d,const u16 samples[2][1920])
{
 if(!f||!v)return;
 doa_published_result_t visible;debug_doa_visible_snapshot(v,d,&visible);
 doa_framebuffer_t surface={f,DISPLAY_STRIDE,v->result_age_ms,visible.available,DOA_UI_STALE_MS};doa_render_model_t m;
 lcd_doa_model(&surface,&visible,&m);int refresh=static_refresh(f,v);
 /* The renderer never advances EMA. Reject a mismatched copied pair rather
  * than silently presenting a different candidate as the raw/smooth source. */
 debug_view_t drawing=*v;
 if(!doa_ui_angles_match(&v->doa_angles,&visible)||m.stale)drawing.doa_angles.available=0;
 if(m.stale||(v->page==PAGE_DOA&&m.pointer_valid&&!drawing.doa_angles.available)){
  m.pointer_valid=0;
  if(strcmp(m.state,"INVALID"))snprintf(m.state,sizeof m.state,"NOT READY");
 }
 /* Header depends only on page/style: cache on the leased physical frame. */
 if(refresh){
  rect(f,0,0,1920,1200,bg);
  text(f,24,12,1900,"REAL-TIME DOA ANALYZER | DUAL FPGA HIL",36,ink);
  text(f,24,62,1900,"ENGINEERING_TEST / NOT_SIGNED_OFF",16,muted);
  text(f,1320,62,1896,debug_page_name(v->page),16,cyan);
 }
 if(v->page==PAGE_DOA)doa_card(f,&drawing,&m);
 else if(v->page==PAGE_FFT)hil_card(f,&m);
 else detail_card(f,v,&m);
 spectrum(f,v,s,&m,refresh);bottom(f,v,&m,refresh);
 (void)samples;
}
