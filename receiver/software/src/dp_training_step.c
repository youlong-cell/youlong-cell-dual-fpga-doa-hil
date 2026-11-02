#include <string.h>
#include "dp_training_step.h"

void dp_training_begin(dp_training_t *t, uint64_t now, uint32_t delay)
{
 memset(t,0,sizeof(*t));
 t->state=DP_TR_RESET;t->start_us=t->previous_us=now;
 t->delay_us=delay;t->attempts_left=64;
}
static int fail(dp_training_t *t) {t->state=DP_TR_FAILED;return -1;}
int dp_training_step(dp_training_t *t,uint64_t now,dp_train_io io,void *ctx)
{
 int v;
 if(t->state==DP_TR_FAILED)return -1;
 if(t->state==DP_TR_DONE)return 1;
 /* Clock rollback / unreasonable elapsed history cannot complete a link. */
 if(now<t->previous_us || now-t->start_us>UINT64_C(60000000))return fail(t);
 t->previous_us=now;
 switch(t->state) {
 case DP_TR_RESET:
  if(io(ctx,DP_OP_RESET,0))return fail(t);
  t->state=DP_TR_CR_BEGIN;break;
 case DP_TR_CR_BEGIN:
  if(!t->attempts_left--)return fail(t);
  t->recovery_left=64;t->previous_vs=t->same_vs=0;
  if(io(ctx,DP_OP_PATTERN,1))return fail(t);
  t->due_us=0;t->state=DP_TR_CR_WAIT;break;
 case DP_TR_CR_WAIT:
  if(!t->due_us)t->due_us=now+t->delay_us;
  if(now>=t->due_us)t->state=DP_TR_CR_READ;
  break;
 case DP_TR_CR_READ:
  if(!t->recovery_left-- || io(ctx,DP_OP_STATUS,0))return fail(t);
  t->state=DP_TR_CR_CHECK;break;
 case DP_TR_CR_CHECK:
  if(!io(ctx,DP_OP_CR_OK,0)){t->state=DP_TR_EQ_BEGIN;break;}
  v=io(ctx,DP_OP_VS,0);if(v<0 || v>3)return fail(t);
  if(t->previous_vs==(unsigned)v)t->same_vs++;
  else {t->same_vs=0;t->previous_vs=(unsigned)v;}
  t->state=t->same_vs>=5 || v==3?DP_TR_OFF_ADJUST:DP_TR_CR_ADJUST;
  break;
 case DP_TR_CR_ADJUST:
  if(io(ctx,DP_OP_ADJUST,0))return fail(t);
  t->due_us=0;t->state=DP_TR_CR_WAIT;break;
 case DP_TR_EQ_BEGIN:
  t->eq_iterations=0;
  if(io(ctx,DP_OP_PATTERN,2))return fail(t);
  t->due_us=0;t->state=DP_TR_EQ_WAIT;break;
 case DP_TR_EQ_WAIT:
  if(!t->due_us)t->due_us=now+t->delay_us;
  if(now>=t->due_us)t->state=DP_TR_EQ_READ;
  break;
 case DP_TR_EQ_READ:
  if(io(ctx,DP_OP_STATUS,0))return fail(t);
  t->state=DP_TR_EQ_ADJUST;break;
 case DP_TR_EQ_ADJUST:
  if(io(ctx,DP_OP_ADJUST,0))return fail(t);
  t->state=DP_TR_EQ_CHECK;break;
 case DP_TR_EQ_CHECK:
  if(io(ctx,DP_OP_CR_OK,0)){t->state=DP_TR_OFF_ADJUST;break;}
  if(!io(ctx,DP_OP_EQ_OK,0)){t->state=DP_TR_OFF_FINAL;break;}
  if(++t->eq_iterations>=5){t->state=DP_TR_OFF_ADJUST;break;}
  t->due_us=0;t->state=DP_TR_EQ_WAIT;break;
 case DP_TR_OFF_ADJUST:
  if(io(ctx,DP_OP_PATTERN,0))return fail(t);
  t->state=DP_TR_RATE;break;
 case DP_TR_RATE:
  v=io(ctx,DP_OP_RATE,0);
  if(v<0)return fail(t);
  t->state=v?DP_TR_LANES:DP_TR_CR_BEGIN;break;
 case DP_TR_LANES:
  if(io(ctx,DP_OP_LANES,0))return fail(t);
  t->state=DP_TR_CR_BEGIN;break;
 case DP_TR_OFF_FINAL:
  if(io(ctx,DP_OP_PATTERN,0))return fail(t);
  t->state=DP_TR_FINAL;break;
 case DP_TR_FINAL:
  if(io(ctx,DP_OP_FINAL,0))return fail(t);
  t->state=DP_TR_DONE;return 1;
 default:return fail(t);
 }
 return 0;
}
