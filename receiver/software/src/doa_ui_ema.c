#include "doa_ui_ema.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

_Static_assert(COUNTS_PER_SECOND > 0, "XTime rate must be defined");
_Static_assert(DOA_UI_EMA_TAU_MS > 0, "EMA time constant");
static double seconds(XTime a, XTime b)
{return (double)(a-b)/(double)COUNTS_PER_SECOND;}
static int same_context(const result_identity_t *a,const result_identity_t *b)
{return a->session_epoch==b->session_epoch&&a->config_version==b->config_version&&
 a->calibration_profile_id==b->calibration_profile_id&&a->geometry_id==b->geometry_id;}
static void invalidate(doa_ui_ema_t *s)
{memset(&s->value,0,sizeof s->value);s->step_pending=0;}
void doa_ui_ema_init(doa_ui_ema_t *s)
{if(s)memset(s,0,sizeof *s);}
int doa_ui_ema_update(doa_ui_ema_t *s,const doa_published_result_t *p,XTime now,int allowed)
{
 if(!s)return 0;
 if(s->clock_seen&&now<s->last_now){invalidate(s);s->last_now=now;return 0;}
 s->last_now=now;s->clock_seen=1;
 if(!p||!p->available){invalidate(s);return 0;}
 int fresh=!s->seen||p->publish_seq>s->seen_publish_seq;
 if(s->seen&&p->publish_seq<s->seen_publish_seq){invalidate(s);return 0;}
 if(s->seen&&p->publish_seq==s->seen_publish_seq&&
    !result_identity_same_provenance(&p->identity,&s->seen_identity)){invalidate(s);return 0;}
 int context_change=s->seen&&!same_context(&p->identity,&s->seen_identity);
 if(fresh&&s->seen&&!context_change&&p->identity.candidate_seq<=s->seen_identity.candidate_seq){
  /* A new software serial cannot make a repeated/older candidate new. */
  invalidate(s);return 0;
 }
 if(fresh){s->seen=1;s->seen_identity=p->identity;s->seen_publish_seq=p->publish_seq;}
 if(!allowed||p->received_time>now||seconds(now,p->received_time)*1000.0>DOA_UI_EMA_STALE_MS||
    p->view_state!=DOA_VIEW_VALID||!pl_fine_bits(&p->packet,PL_FINE_NUMERIC_VALID_BIT,1)||
    !pl_fine_bits(&p->packet,PL_CALIBRATED_VALID_BIT,1)||!pl_fine_bits(&p->packet,PL_NUMERIC_VALID_BIT,1)||
    !pl_fine_bits(&p->packet,PL_THETA_VALID_BIT,1)||pl_fine_bits(&p->packet,PL_STATUS_STAGE_BIT,PL_STATUS_STAGE_WIDTH)||
    pl_fine_bits(&p->packet,PL_STATUS_BIT,PL_STATUS_WIDTH)){invalidate(s);return 0;}
 int64_t raw=pl_fine_signed(&p->packet,PL_THETA_BIT,PL_THETA_WIDTH);
 if(raw<-(INT64_C(1)<<34)||raw>(INT64_C(1)<<34)){invalidate(s);return 0;} /* no clamp */
 if(!fresh)return 0; /* redraw and polling of a COPY are not samples */
 double deg=(double)raw*180.0/(double)(UINT64_C(1)<<35);
 int seed=!s->value.available||context_change;
 if(!seed){
  if(p->received_time<s->value.received_time){invalidate(s);return 0;}
  if(seconds(p->received_time,s->value.received_time)*1000.0>DOA_UI_EMA_STALE_MS)seed=1;
 }
 double smooth=deg;
 if(!seed){
  double dt=seconds(p->received_time,s->value.received_time);
  int confirmed=s->step_pending&&p->received_time>s->step_time&&
   seconds(p->received_time,s->step_time)*1000.0<=DOA_UI_EMA_STEP_WINDOW_MS&&
   fabs(deg-s->step_target)<=DOA_UI_EMA_STEP_MATCH_DEG&&fabs(deg-s->step_anchor)>DOA_UI_EMA_STEP_DEG&&
   (deg-s->step_anchor)*(s->step_target-s->step_anchor)>0;
  if(confirmed){s->step_resets++;s->step_pending=0;}
  else{
   double alpha=-expm1(-dt*1000.0/(double)DOA_UI_EMA_TAU_MS);
   smooth=s->value.smooth_doa+alpha*(deg-s->value.smooth_doa);
   s->step_pending=fabs(deg-s->value.smooth_doa)>DOA_UI_EMA_STEP_DEG;
   if(s->step_pending){s->step_anchor=s->value.smooth_doa;s->step_target=deg;s->step_time=p->received_time;}
  }
 }else s->step_pending=0;
 s->value=(doa_ui_angles_t){1,raw,deg,smooth,p->publish_seq,p->received_time,p->identity};
 s->accepted++;return 1;
}
int doa_ui_angles_match(const doa_ui_angles_t *a,const doa_published_result_t *p)
{return a&&p&&a->available&&p->available&&a->publish_seq==p->publish_seq&&
 a->received_time==p->received_time&&result_identity_same_provenance(&a->identity,&p->identity)&&
 a->raw_theta_code==pl_fine_signed(&p->packet,PL_THETA_BIT,PL_THETA_WIDTH);}
void doa_ui_raw_text(char *b,unsigned size,int64_t code)
{
 if(!b||!size)return;
 if(code<-(INT64_C(1)<<34)||code>(INT64_C(1)<<34)){snprintf(b,size,"---");return;}
 uint64_t mag=code<0?(uint64_t)-code:(uint64_t)code;
 uint64_t q=(mag*18000+(UINT64_C(1)<<34))>>35;
 snprintf(b,size,"%c%llu.%02llu",code<0?'-':'+',(unsigned long long)(q/100),(unsigned long long)(q%100));
}
void doa_ui_smooth_text(char *b,unsigned size,double deg)
{
 if(!b||!size)return;
 if(!isfinite(deg)||fabs(deg)>90.0){snprintf(b,size,"---");return;}
 unsigned q=(unsigned)lround(fabs(deg)*10.0);
 snprintf(b,size,"%c%u.%u",deg<0?'-':'+',q/10,q%10);
}
