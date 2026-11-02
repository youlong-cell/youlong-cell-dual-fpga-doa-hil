#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include "doa_ui_ema.h"
static unsigned checks;
#define C(x) do{checks++;assert(x);}while(0)
static XTime tick(unsigned ms){return (XTime)ms*COUNTS_PER_SECOND/1000;}
static void put(pl_fine_packet_t *p,unsigned bit,unsigned width,uint64_t v)
{for(unsigned i=0;i<width;i++){uint32_t m=1U<<((bit+i)%32);p->word[(bit+i)/32]=(p->word[(bit+i)/32]&~m)|(((v>>i)&1U)?m:0);}}
static doa_published_result_t sample(uint64_t seq,unsigned ms,double deg)
{
 doa_published_result_t p={0};p.available=1;p.publish_seq=seq;p.received_time=tick(ms);p.view_state=DOA_VIEW_VALID;
 p.identity=(result_identity_t){1,(uint32_t)seq,1,9,1};
 put(&p.packet,PL_FINE_NUMERIC_VALID_BIT,1,1);put(&p.packet,PL_CALIBRATED_VALID_BIT,1,1);
 put(&p.packet,PL_NUMERIC_VALID_BIT,1,1);put(&p.packet,PL_THETA_VALID_BIT,1,1);
 put(&p.packet,PL_THETA_BIT,36,(uint64_t)llround(deg/180.0*(double)(UINT64_C(1)<<35)));
 return p;
}
static void feed(doa_ui_ema_t *s,doa_published_result_t *p,unsigned ms,int allowed)
{
 doa_published_result_t original=*p;int updated=doa_ui_ema_update(s,p,tick(ms),allowed);
 C(!memcmp(&original,p,sizeof original));
 if(updated){C(s->value.raw_theta_code==pl_fine_signed(&p->packet,PL_THETA_BIT,36));
 C(s->value.raw_doa==(double)s->value.raw_theta_code*180.0/(double)(UINT64_C(1)<<35));
 C(doa_ui_angles_match(&s->value,p));}
}
int main(void)
{
 doa_ui_ema_t s;doa_ui_ema_init(&s);doa_published_result_t p=sample(1,0,30);feed(&s,&p,0,1);
 C(s.value.smooth_doa==s.value.raw_doa);C(s.accepted==1);
 double raw_lo=100,raw_hi=-100,sm_lo=100,sm_hi=-100;
 for(unsigned i=2;i<=1000;i++){
  p=sample(i,i*10,30+(i&1?0.15:-0.15));feed(&s,&p,i*10,1);
  if(i>100){double a=s.value.raw_doa,b=s.value.smooth_doa;
   if(a<raw_lo)raw_lo=a;if(a>raw_hi)raw_hi=a;if(b<sm_lo)sm_lo=b;if(b>sm_hi)sm_hi=b;}
 }
 C(raw_hi-raw_lo>0.299);C(sm_hi-sm_lo<0.01);C(s.step_resets==0);
 printf("JITTER_HOST raw_pp_deg=%.9f smooth_pp_deg=%.9f tau_ms=%u dt_ms=10; SYNTHETIC NOT BOARD\n",raw_hi-raw_lo,sm_hi-sm_lo,DOA_UI_EMA_TAU_MS);
 uint64_t n=s.accepted;doa_ui_angles_t old=s.value;
 for(unsigned i=0;i<100;i++)feed(&s,&p,10001,1);
 C(s.accepted==n&&!memcmp(&old,&s.value,sizeof old)); /* many redraws, no samples */
 for(unsigned direction=0;direction<2;direction++){
  double a=direction?-30:30,b=direction?60:-60;doa_ui_ema_init(&s);
  p=sample(1,0,a);feed(&s,&p,0,1);p=sample(2,10,b);feed(&s,&p,10,1);
  C(s.step_resets==0&&fabs(s.value.smooth_doa-b)>1);
  /* A repeated candidate cannot confirm a direction change. */
  feed(&s,&p,11,1);C(s.step_resets==0);
  p=sample(3,20,b+0.01);feed(&s,&p,20,1);C(s.step_resets==1&&fabs(s.value.smooth_doa-b-0.01)<1e-6);
  printf("STEP_HOST from=%.0f to=%.0f confirmed_at_ms=20; NOT BOARD LATENCY\n",a,b);
 }
 /* One valid outlier followed by baseline does not reset the EMA. */
 doa_ui_ema_init(&s);p=sample(1,0,30);feed(&s,&p,0,1);p=sample(2,10,-60);feed(&s,&p,10,1);
 p=sample(3,20,30);feed(&s,&p,20,1);C(s.step_resets==0&&fabs(s.value.smooth_doa-30)<3);
 /* Opposite/unrelated large samples do not confirm the same new direction. */
 doa_ui_ema_init(&s);p=sample(1,0,0);feed(&s,&p,0,1);p=sample(2,10,30);feed(&s,&p,10,1);
 p=sample(3,20,-60);feed(&s,&p,20,1);C(s.step_resets==0);
 /* Irregular timestamps: exact time-aware reference, including sub-ms dt. */
 doa_ui_ema_init(&s);p=sample(1,0,0);feed(&s,&p,0,1);double reference=s.value.smooth_doa;unsigned time=0;
 for(unsigned i=2;i<=800;i++){
  unsigned dt=(i%7==0)?97:(i%3==0)?1:13;time+=dt;
  p=sample(i,time,(i&1?0.15:-0.15));double raw=(double)pl_fine_signed(&p.packet,PL_THETA_BIT,36)*180.0/(double)(UINT64_C(1)<<35);
  reference+=(-expm1(-(double)dt/400.0))*(raw-reference);feed(&s,&p,time,1);
  C(fabs(s.value.smooth_doa-reference)<1e-12);
 }
 C(s.step_resets==0&&fabs(s.value.smooth_doa)<0.15);
 /* Two 100ms samples confirm within the time window, not fixed cadence. */
 doa_ui_ema_init(&s);p=sample(1,0,30);feed(&s,&p,0,1);p=sample(2,100,-60);feed(&s,&p,100,1);
 p=sample(3,200,-60);feed(&s,&p,200,1);C(s.step_resets==1&&s.value.smooth_doa==s.value.raw_doa);
 /* Session/config/Profile/geometry changes seed, never mix prior history. */
 for(unsigned kind=0;kind<4;kind++){
  doa_ui_ema_init(&s);p=sample(1,0,30);feed(&s,&p,0,1);p=sample(2,10,-30);
  if(kind==0){p.identity.session_epoch=2;p.identity.candidate_seq=1;}
  if(kind==1)p.identity.config_version=2;if(kind==2)p.identity.calibration_profile_id=10;if(kind==3)p.identity.geometry_id=2;
  feed(&s,&p,10,1);C(s.value.smooth_doa==s.value.raw_doa&&s.step_resets==0);
 }
 /* Missing signal, reset/STOP/HOLD/unavailable, invalid calibration/domain,
  * faults and malformed numeric values all clear both current numbers. */
 for(unsigned kind=0;kind<9;kind++){
  doa_ui_ema_init(&s);p=sample(1,0,30);feed(&s,&p,0,1);p=sample(2,10,31);
  if(kind==0)p.available=0;
  if(kind==1)p.view_state=DOA_VIEW_INVALID;
  if(kind==2)p.view_state=DOA_VIEW_FAULT;
  if(kind==3)put(&p.packet,PL_CALIBRATED_VALID_BIT,1,0);
  if(kind==4)put(&p.packet,PL_THETA_VALID_BIT,1,0);
  if(kind==5)put(&p.packet,PL_STATUS_STAGE_BIT,4,5);
  if(kind==6)put(&p.packet,PL_THETA_BIT,36,UINT64_C(1)<<34|1);
  if(kind==7)put(&p.packet,PL_NUMERIC_VALID_BIT,1,0);
  feed(&s,&p,10,kind!=8);C(!s.value.available&&s.value.raw_doa==0&&s.value.smooth_doa==0);
  p=sample(3,20,-20);feed(&s,&p,20,1);C(s.value.available&&s.value.smooth_doa==s.value.raw_doa);
 }
 doa_ui_ema_init(&s);p=sample(1,0,30);feed(&s,&p,0,1);feed(&s,&p,301,1);C(!s.value.available);
 feed(&s,&p,302,1);C(!s.value.available);p=sample(2,303,-40);feed(&s,&p,303,1);C(s.value.smooth_doa==s.value.raw_doa);
 /* Temporary loss cannot re-promote the old candidate when signal returns. */
 feed(&s,&p,304,0);feed(&s,&p,305,1);C(!s.value.available);p=sample(3,306,10);feed(&s,&p,306,1);C(s.value.smooth_doa==s.value.raw_doa);
 /* Time regression/future timestamp and older/replayed candidate fail closed. */
 feed(&s,&p,300,1);C(!s.value.available);p=sample(4,400,30);feed(&s,&p,350,1);C(!s.value.available);
 p=sample(5,401,30);feed(&s,&p,401,1);p=sample(4,402,-30);feed(&s,&p,402,1);C(!s.value.available);
 doa_ui_ema_init(&s);p=sample(1,0,20);feed(&s,&p,0,1);p.publish_seq=2;feed(&s,&p,1,1);C(!s.value.available&&s.accepted==1);
 /* Same timestamp: new raw is retained, alpha=0 and no bogus elapsed time. */
 doa_ui_ema_init(&s);p=sample(1,0,20);feed(&s,&p,0,1);p=sample(2,0,21);feed(&s,&p,0,1);C(s.accepted==2&&fabs(s.value.smooth_doa-20)<1e-6);
 /* A new current sample after a long service gap seeds, not mixes history. */
 doa_ui_ema_init(&s);p=sample(1,10,30);feed(&s,&p,10,1);
 p=sample(2,60010,-60);feed(&s,&p,60010,1);
 C(s.value.available&&s.value.smooth_doa==s.value.raw_doa&&s.step_resets==0);
 /* Monotonic service time cannot legitimize a regressed publication time. */
 p=sample(3,60009,10);feed(&s,&p,60011,1);C(!s.value.available);
 p=sample(4,60012,20);feed(&s,&p,60012,1);C(s.value.smooth_doa==s.value.raw_doa);
 /* Near-maximum tick values remain a safe integer difference before double. */
 doa_ui_ema_init(&s);p=sample(1,0,30);p.received_time=UINT64_MAX-tick(20);
 C(doa_ui_ema_update(&s,&p,p.received_time,1)==1);
 p=sample(2,0,30.15);p.received_time=UINT64_MAX-tick(10);
 C(doa_ui_ema_update(&s,&p,p.received_time,1)==1);
 C(fabs(s.value.smooth_doa-(30.0+(-expm1(-0.01/0.4))*(s.value.raw_doa-30.0)))<1e-6);
 C(doa_ui_ema_update(&s,&p,1,1)==0&&!s.value.available);
 char b[40];doa_ui_raw_text(b,sizeof b,llround(29.84/180.0*(double)(UINT64_C(1)<<35)));C(!strcmp(b,"+29.84"));
 doa_ui_smooth_text(b,sizeof b,30);C(!strcmp(b,"+30.0"));doa_ui_smooth_text(b,sizeof b,NAN);C(!strcmp(b,"---"));
 doa_ui_raw_text(b,sizeof b,INT64_C(1)<<34);C(!strcmp(b,"+90.00"));
 LARGE_INTEGER rate,a,z;QueryPerformanceFrequency(&rate);QueryPerformanceCounter(&a);
 doa_ui_ema_init(&s);
 for(unsigned i=1;i<=200000;i++){p=sample(i,i,30+(i&1?0.15:-0.15));doa_ui_ema_update(&s,&p,p.received_time,1);}
 QueryPerformanceCounter(&z);
 printf("FILTER_HOST avg_fixture_plus_update_us=%.6f n=200000; NOT A53 TIMING\n",(double)(z.QuadPart-a.QuadPart)*1e6/rate.QuadPart/200000);
 printf("DOA_UI_EMA_PASS checks=%u accepted=%llu raw-code immutable/jitter/steps/time/dedup/context/invalid/stale/no-signal; HOST ONLY\n",checks,(unsigned long long)s.accepted);
 return 0;
}
