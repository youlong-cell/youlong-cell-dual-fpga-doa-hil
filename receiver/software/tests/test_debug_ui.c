#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "debug_ui.h"
#include "ui_angles_fixture.h"
void lcd_draw_text(uint8_t *,uint32_t,int64_t,int64_t,const char *,uint8_t,uint8_t,uint8_t,int);
enum{G=1024,F=DISPLAY_FRAME_SIZE};
static unsigned checks;
static void put(pl_fine_packet_t *p,unsigned bit,unsigned width,uint64_t value)
{for(unsigned i=0;i<width;i++){uint32_t mask=1U<<((bit+i)%32);
 p->word[(bit+i)/32]=(p->word[(bit+i)/32]&~mask)|(((value>>i)&1U)?mask:0);}}
static void guards(unsigned char *a)
{for(unsigned i=0;i<G;i++){checks+=2;assert(a[i]==0xa5 && a[G+F+i]==0xa5);}}
static void screenshot(const char *prefix,const char *name,unsigned char *pixels)
{
 char path[512];snprintf(path,sizeof path,"%s.%s.rgba",prefix,name);
 lcd_draw_text(pixels,DISPLAY_STRIDE,1600,84,"HOST MOCK / NOT BOARD DATA",255,210,105,1);
 FILE *f=fopen(path,"wb");assert(f);assert(fwrite(pixels,1,F,f)==F);fclose(f);
}
int main(int argc,char **argv)
{
 (void)argc;unsigned char *a=malloc(F+2*G);assert(a);memset(a,0xa5,F+2*G);
 debug_view_t v={0};spectrum_view_snapshot_t s={0};doa_published_result_t d={0};
 static u16 raw[2][1920];doa_framebuffer_t fb={a+G,DISPLAY_STRIDE,0,0,1000};doa_render_model_t model;
 for(unsigned scene=0;scene<24;scene++){
  v.adc_fresh=scene&1;v.spectrum_fresh=(scene>>1)&1;v.signal_quality=(scene>>2)&1;
  v.dp=DBG_OK;v.fft=(scene>>3)&1?DBG_ERROR:DBG_NO_DATA;
  v.drawn=scene;v.stop=DBG_OK;v.lifecycle=0xf1010040;v.atb_status=scene&8?2:0;
  s.available=v.spectrum_fresh;
  s.ch[0].fs=s.ch[1].fs=62499374;
  for(unsigned c=0;c<2;c++)for(unsigned k=0;k<512;k++){s.ch[c].freq[k]=k*61034.54f;s.ch[c].mag_db[k]=-110;}
  if(v.signal_quality)for(unsigned c=0;c<2;c++){s.ch[c].mag_db[50]=-18;v.peak_bin[c]=50;v.peak_hz[c]=3051727;v.peak_db[c]=-18;}
  if(scene>=16){v.adc_fresh=v.spectrum_fresh=s.available=1;v.signal_quality=0;
   for(unsigned c=0;c<2;c++)for(unsigned k=2;k<511;k++)s.ch[c].mag_db[k]=-70;
   if(scene==20)s.ch[0].mag_db[33]=-20;
  }
  for(unsigned c=0;c<2;c++){
   debug_peak_measure(&s.ch[c],&debug_input_default_config,&v.peak[c]);
   v.rms_millicodes[c]=scene>=16?8000:v.signal_quality?100000:1118;
   v.sample_count[c]=UINT64_MAX;v.block_sample_count[c]=1920;
   v.adc_status[c]=(scene==21?1:0);v.dropped[c]=scene==21?UINT32_MAX:0;
   v.rail_count[c]=scene==22?1920:0;
   v.input[c]=debug_input_classify(v.adc_fresh,v.spectrum_fresh,v.rms_millicodes[c],v.adc_status[c]&1,&v.peak[c],&debug_input_default_config);
  }
  v.input_pair=debug_input_pair(v.input[0],v.input[1]);
  for(unsigned c=0;c<2;c++)for(unsigned k=0;k<1920;k++)raw[c][k]=(u16)((k*13+c*419)%4096);
  debug_draw(a+G,&v,&s,&d,raw);guards(a);
  lcd_doa_model(&fb,&d,&model);assert(!model.pointer_valid&&!model.target_valid);assert(!strcmp(model.state,"NOT READY"));
  if(scene==0){FILE *f=fopen(argv[1],"wb");assert(f);assert(fwrite(a+G,1,F,f)==F);fclose(f);}
  if(scene==7){char path[512];snprintf(path,sizeof path,"%s.signal.rgba",argv[1]);FILE *f=fopen(path,"wb");assert(f);assert(fwrite(a+G,1,F,f)==F);fclose(f);}
 }
 v.session_state=ENG_MEASURING;v.result_fresh=1;v.input_pair=INPUT_SIGNAL_DETECTED;
 d.available=1;d.view_state=DOA_VIEW_INVALID;
 put(&d.packet,PL_FINE_NUMERIC_VALID_BIT,1,1);
 put(&d.packet,PL_F_HAT_HZ_BIT,49,UINT64_C(2000000)<<24);
 put(&d.packet,PL_PHASE_RAW_BIT,36,(uint64_t)-INT64_C(8589934592));
 put(&d.packet,PL_STATUS_STAGE_BIT,4,5);put(&d.packet,PL_STATUS_BIT,8,1);
 doa_published_result_t original=d,visible;
 for(unsigned scene=0;scene<6;scene++){
  v.input_pair=scene==1?INPUT_NO_SIGNAL:scene==2?INPUT_NOISE_ONLY:INPUT_SIGNAL_DETECTED;
  v.result_fresh=scene!=3;v.session_state=scene==4?ENG_ERROR:ENG_MEASURING;
  debug_doa_visible_snapshot(&v,&d,&visible);
  lcd_doa_model(&fb,&visible,&model);
  if(scene==0 || scene==5){assert(model.target_valid&&!model.pointer_valid);
    assert(!strcmp(model.raw_phase,"-45.000 deg")&&!strcmp(model.angle,"---"));
    assert(!strcmp(model.state,"INVALID"));
  }else{assert(!model.target_valid&&!model.pointer_valid);assert(!strcmp(model.raw_phase,"---"));}
  debug_draw(a+G,&v,&s,&d,raw);guards(a);assert(!memcmp(&original,&d,sizeof d));
  if(scene==0){char path[512];snprintf(path,sizeof path,"%s.fine.rgba",argv[1]);
   FILE *f=fopen(path,"wb");assert(f);assert(fwrite(a+G,1,F,f)==F);fclose(f);}
 }
 /* Valid packet is a HOST MOCK to test rendering, not a measured DOA. */
 memset(&d,0,sizeof d);d.available=1;d.view_state=DOA_VIEW_VALID;
 d.identity.geometry_id=1;d.identity.calibration_profile_id=17;
 put(&d.packet,PL_PROFILE_ID_BIT,32,17);put(&d.packet,PL_GEOMETRY_ID_BIT,32,1);
 put(&d.packet,PL_FINE_NUMERIC_VALID_BIT,1,1);put(&d.packet,PL_CALIBRATED_VALID_BIT,1,1);
 put(&d.packet,PL_NUMERIC_VALID_BIT,1,1);put(&d.packet,PL_THETA_VALID_BIT,1,1);
 put(&d.packet,PL_F_HAT_HZ_BIT,49,UINT64_C(5000000)<<24);
 put(&d.packet,PL_PHASE_RAW_BIT,36,INT64_C(2863311531)); /* 15 deg */
 put(&d.packet,PL_PHASE_CAL_BIT,36,INT64_C(2863311531));
 put(&d.packet,PL_THETA_BIT,36,INT64_C(5726623061)); /* 30 deg */
 v.session_state=ENG_MEASURING;v.result_fresh=1;v.input_pair=INPUT_SIGNAL_DETECTED;
 v.input[0]=v.input[1]=INPUT_SIGNAL_DETECTED;v.result_age_ms=12;v.fine_published=10;
 v.config_version=1;v.session_epoch=UINT64_C(0xE100000000000001);
 v.adc_fresh=v.spectrum_fresh=s.available=1;v.adc[0]=v.adc[1]=DBG_OK;
 v.dma[0]=v.dma[1]=DBG_OK;v.fft=DBG_OK;
 for(unsigned c=0;c<2;c++){
  for(unsigned k=0;k<512;k++)s.ch[c].mag_db[k]=-110;
  s.ch[c].mag_db[82]=-(20+(int)c*3);
  v.sample_count[c]=192000;v.transfers[c]=100;v.errors[c]=v.timeouts[c]=v.dropped[c]=v.rail_count[c]=0;
  v.min[c]=1800;v.max[c]=2300;v.rms_millicodes[c]=150000;
  debug_peak_measure(&s.ch[c],&debug_input_default_config,&v.peak[c]);
  assert(v.peak[c].valid&&v.peak[c].bin==82);
 }
 ui_fixture_angles(&v,&d);original=d;
 debug_doa_visible_snapshot(&v,&d,&visible);lcd_doa_model(&fb,&visible,&model);
 assert(model.pointer_valid&&model.target_valid&&!strcmp(model.frequency,"5.000000 MHz"));
 assert(!strcmp(model.raw_phase,"+15.000 deg")&&!strcmp(model.cal_phase,"+15.000 deg"));
 assert(!strcmp(model.angle,"+29.999 deg"));
 for(unsigned page=0;page<4;page++){
  v.page=(enum debug_page)page;v.key_mode_code=page;
  debug_draw(a+G,&v,&s,&d,raw);screenshot(argv[1],debug_page_name(v.page),a+G);guards(a);
  assert(!memcmp(&original,&d,sizeof d));
 }
 /* Invalid must replace valid, and stale/session/signal/profile mismatch hides angle. */
 v.page=PAGE_DOA;
 put(&d.packet,PL_THETA_VALID_BIT,1,0);put(&d.packet,PL_STATUS_STAGE_BIT,4,5);put(&d.packet,PL_STATUS_BIT,8,6);
 debug_doa_visible_snapshot(&v,&d,&visible);lcd_doa_model(&fb,&visible,&model);
 assert(!model.pointer_valid&&!strcmp(model.angle,"---")&&!strcmp(model.state,"INVALID"));
 debug_draw(a+G,&v,&s,&d,raw);screenshot(argv[1],"INVALID",a+G);guards(a);
 d=original;
 for(unsigned cause=0;cause<5;cause++){
  v.result_fresh=cause!=0;v.session_state=cause==1?ENG_CLOSED:ENG_MEASURING;
  v.input_pair=cause==2?INPUT_NO_SIGNAL:INPUT_SIGNAL_DETECTED;
  d.identity.geometry_id=cause==3?2:1;d.identity.calibration_profile_id=cause==4?2:17;
  debug_doa_visible_snapshot(&v,&d,&visible);lcd_doa_model(&fb,&visible,&model);
  assert(!visible.available&&!model.pointer_valid&&!strcmp(model.angle,"---"));
  debug_draw(a+G,&v,&s,&d,raw);guards(a);
 }
 memset(&d,0,sizeof d);v.session_state=ENG_CLOSED;v.result_fresh=0;
 v.adc_fresh=v.spectrum_fresh=s.available=0;v.input_pair=INPUT_NO_SIGNAL;
 v.input[0]=v.input[1]=INPUT_NO_SIGNAL;
 v.key_mode_code=0;
 debug_draw(a+G,&v,&s,&d,raw);screenshot(argv[1],"NO_INPUT",a+G);guards(a);
 /* Host model of no tone while the real FFT service is still delivering.
  * The target firmware never inserts these synthetic values. */
 v.adc_fresh=v.spectrum_fresh=s.available=1;
 v.rms_millicodes[0]=v.rms_millicodes[1]=0;
 memset(v.peak,0,sizeof v.peak);
 for(unsigned c=0;c<2;c++)for(unsigned k=0;k<512;k++)s.ch[c].mag_db[k]=-110;
 debug_draw(a+G,&v,&s,&d,raw);screenshot(argv[1],"NO_SIGNAL_LIVE_FFT",a+G);guards(a);
 /* Reduced-detail branch and native right/bottom pixel boundaries. */
 v.ui_low_detail=1;debug_draw(a+G,&v,&s,&d,raw);guards(a);
 screenshot(argv[1],"REDUCED_DETAIL",a+G);
 printf("DEBUG UI PASS scenes=43 guard_checks=%u native1920x1200 angle/raw/cal/invalid/stale/profile/pages/no-signal/reduced-detail/immutable snapshot; HOST MOCK ONLY\n",checks);free(a);return 0;
}
