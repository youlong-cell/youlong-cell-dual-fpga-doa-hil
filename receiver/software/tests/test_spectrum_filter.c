#include <stdio.h>
#include <string.h>
#include <math.h>
#include <limits.h>
#include <stdlib.h>
#include "spectrum_display_filter.h"
static unsigned checks;
#define CHECK(v) do{checks++;if(!(v)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#v);exit(1);}}while(0)
static spectrum_display_filter_t f;
static spectrum_view_snapshot_t raw,out,saved;
static const double gain=2.0/((16760324.0/32768.0)*2048.0);
static void init(void)
{
 CHECK(spectrum_display_init(&f,&spectrum_display_default_config));memset(&raw,0,sizeof raw);
 raw.available=raw.metadata_valid=1;
 for(unsigned c=0;c<2;c++){
  raw.ch[c].fs=62499374;raw.ch[c].freq_resolution=raw.ch[c].fs/1024;
  for(unsigned k=0;k<FFT_BINS;k++){raw.ch[c].freq[k]=k*raw.ch[c].freq_resolution;raw.ch[c].mag_db[k]=-120;}
 }
}
static void input(unsigned seq,s32 re,s32 im,s32 re1,s32 im1)
{
 raw.metadata.sequence=seq;raw.received_time=(XTime)seq*(COUNTS_PER_SECOND/1000);
 for(unsigned k=0;k<FFT_BINS;k++){
  spectrum_display_stage_bin(&f,seq,raw.ch[0].fs,k,k==33?re:0,k==33?im:0,k==33?re1:0,k==33?im1:0);
  for(unsigned c=0;c<2;c++){
   double p=c?(double)re1*re1+(double)im1*im1:(double)re*re+(double)im*im;
   raw.ch[c].mag_db[k]=k==33&&p>0?(float)fmax(-120,10*log10(p*gain*gain)):-120;
  }
 }
 saved=raw;CHECK(spectrum_display_accept(&f,&raw));CHECK(!memcmp(&raw,&saved,sizeof raw));
}
static void present(void)
{
 saved=raw;CHECK(spectrum_display_prepare(&f,&raw,&out));CHECK(!memcmp(&raw,&saved,sizeof raw));
 CHECK(out.metadata.sequence==raw.metadata.sequence && out.received_time==raw.received_time);
 spectrum_display_commit(&f,&raw,&out);
}
int main(void)
{
 init();CHECK(!spectrum_display_prepare(&f,&raw,&out)&&!out.available);
 double history[8]={0};unsigned count=0;
 for(unsigned seq=1;seq<=24;seq++){
  s32 r=(s32)(seq*100),i=(s32)(-seq*37);input(seq,r,i,r/2,-i);
  history[(seq-1)%8]=(double)r*r+(double)i*i;if(count<8)count++;
  double sum=0;for(unsigned j=0;j<count;j++)sum+=history[j];
  CHECK(f.count==count);CHECK(fabs(f.sum[0][33]-sum)<0.00001);
  CHECK(fabs(f.average_db[0][33]-10*log10(sum/count*gain*gain))<0.00002);
 }
 /* Powers 1 and 100: mean power 50.5, not mean dB, not coherent I/Q mean. */
 init();input(1,100,0,100,0);input(2,-1000,0,-1000,0);
 CHECK(fabs(f.average_db[0][33]-10*log10(505000*gain*gain))<0.00002);
 CHECK(fabs(f.average_db[0][33]-(raw.ch[0].mag_db[33]+10*log10(10000*gain*gain))/2)>5);
 /* Floor gate, DC/invalid bin mask; exactly threshold is NOT below it. */
 init();input(1,0,0,0,0);present();CHECK(out.ch[0].mag_db[33]==-110);
 input(2,1,0,1,0);present();CHECK(out.ch[0].mag_db[33]==-110);
 init();input(1,4,0,4,0);present();CHECK(out.ch[0].mag_db[33]>-104);
 CHECK(out.ch[0].mag_db[0]==-110&&out.ch[0].mag_db[1]==-110&&out.ch[0].mag_db[511]==-110);
 spectrum_display_config_t cfg=spectrum_display_default_config;
 cfg.noise_floor_dbfs=(float)(10*log10(16*gain*gain))-6;
 CHECK(spectrum_display_init(&f,&cfg));input(1,4,0,4,0);
 CHECK(f.average_db[0][33]!=cfg.noise_floor_dbfs);
 /* Exact requested EMA formula; fast rise is AFTER mean and gating. */
 init();input(1,1000,0,1000,0);present();float old=out.ch[0].mag_db[33];
 input(2,2000,0,2000,0);CHECK(spectrum_display_prepare(&f,&raw,&out));
 CHECK(fabs(out.ch[0].mag_db[33]-(0.85*old+0.15*f.average_db[0][33]))<0.00002);
 /* Preparing / failed present must NOT advance EMA, counters or prior frame. */
 unsigned prior=f.stats.submitted_frames;float previous=f.previous_display[0][33];
 spectrum_view_snapshot_t again;CHECK(spectrum_display_prepare(&f,&raw,&again));
 CHECK(!memcmp(&again,&out,sizeof out));CHECK(f.stats.submitted_frames==prior && f.previous_display[0][33]==previous);
 spectrum_display_commit(&f,&raw,&out);
 input(3,100000,0,100000,0);present();CHECK(out.ch[0].mag_db[33]==f.average_db[0][33]);
 CHECK(f.stats.fast_rises>=2);
 old=out.ch[0].mag_db[33];input(4,0,0,0,0);present();
 CHECK(fabs(out.ch[0].mag_db[33]-(0.85*old+0.15*f.average_db[0][33]))<0.00002);
 /* Duplicate, partial, out-of-order staging, source mismatch cannot publish. */
 CHECK(!spectrum_display_accept(&f,&raw));
 spectrum_display_stage_bin(&f,5,raw.ch[0].fs,0,1,0,1,0);
 raw.metadata.sequence=5;CHECK(!spectrum_display_accept(&f,&raw));
 spectrum_display_stage_bin(&f,5,raw.ch[0].fs,2,1,0,1,0);
 for(unsigned k=1;k<FFT_BINS;k++)spectrum_display_stage_bin(&f,5,raw.ch[0].fs,k,1,0,1,0);
 CHECK(!spectrum_display_accept(&f,&raw));
 raw.available=0;CHECK(!spectrum_display_prepare(&f,&raw,&out)&&!out.available);
 raw.available=1;spectrum_display_reset(&f);CHECK(!f.count&&!f.display_valid&&!f.average_valid);
 input(6,2,0,2,0);CHECK(f.count==1);present();
 /* Stage 512 raw bins alone must not alter a published average. */
 float oldavg=f.average_db[0][33];unsigned oldcount=f.count;
 for(unsigned k=0;k<FFT_BINS;k++)spectrum_display_stage_bin(&f,7,raw.ch[0].fs,k,100000,0,100000,0);
 CHECK(f.average_db[0][33]==oldavg && f.count==oldcount);
 /* Large gap and sample-rate change flush history/EMA, preserve counters. */
 input(1000,100,0,100,0);CHECK(f.count==1&&!f.display_valid);
 raw.ch[0].fs=raw.ch[1].fs=50000000;input(1001,100,0,100,0);CHECK(f.count==1);
 /* Full signed32 power without overflow; loud-to-tiny cancellation avoided. */
 init();input(1,INT_MIN,INT_MIN,INT_MAX,INT_MIN);
 CHECK(isfinite(f.average_db[0][33])&&f.sum[0][33]>9e18);
 for(unsigned s=2;s<=9;s++)input(s,1,0,1,0);
 CHECK(f.sum[0][33]==8&&f.average_db[0][33]==-110);
 /* Strong trigger must remain immediate even though this may increase max variation. */
 init();for(unsigned s=1;s<=10;s++){input(s,0,0,0,0);present();}
 input(11,100000,0,100000,0);present();CHECK(out.ch[0].mag_db[33]==f.average_db[0][33]);
 CHECK(f.stats.before_max_db>0 && f.stats.after_max_db>0);
 /* 400 deterministic noise frames, sampled once per UI submission. */
 init();unsigned rng=9;double sums[8]={0};count=0;
 for(unsigned seq=1;seq<=400;seq++){
  rng=1664525U*rng+1013904223U;s32 a=(s32)(2+(rng>>24)%29);
  input(seq,a,0,a/2+1,0);sums[(seq-1)%8]=(double)a*a;if(count<8)count++;
  double total=0;for(unsigned j=0;j<count;j++)total+=sums[j];
  float expected=(float)(10*log10(total/count*gain*gain));if(expected<-104)expected=-110;
  CHECK(fabs(f.average_db[0][33]-expected)<0.00002);present();
 }
 CHECK(f.stats.compared_frames==399);CHECK(f.stats.after_max_db<f.stats.before_max_db);
 printf("NOISE_SWEEP_HOST: frames=400 raw_max=%.6fdB filtered_max=%.6fdB; NOT HARDWARE\n",f.stats.before_max_db,f.stats.after_max_db);
 init();for(unsigned s=1;s<=100;s++){input(s,(s&1)?1:3,0,(s&1)?3:1,0);present();}
 CHECK(f.stats.before_max_db>9 && f.stats.after_max_db==0);
 printf("BELOW_GATE_NOISE_HOST: frames=100 raw_max=%.6fdB filtered_max=%.6fdB; NOT HARDWARE\n",f.stats.before_max_db,f.stats.after_max_db);
 printf("SPECTRUM_DISPLAY_FILTER PASS checks=%u average-power/gate/EMA/fast-rise/commit/reset/immutable/signed32\n",checks);
 return 0;
}
