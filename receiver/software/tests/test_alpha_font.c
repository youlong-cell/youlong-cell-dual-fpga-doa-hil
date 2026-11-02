/* Host-only arithmetic and guard tests; no hardware evidence. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ui_alpha_font.h"
static unsigned long long checks;
#define CHECK(x) do{checks++;assert(x);}while(0)
int main(void)
{
 for(unsigned v=0;v<=65025;v++)CHECK(ui_alpha_div255(v)==(v+127)/255);
 for(unsigned a=0;a<256;a++)for(unsigned fg=0;fg<256;fg++)for(unsigned old=0;old<256;old++){
  uint8_t p[4]={(uint8_t)old,(uint8_t)(255-old),(uint8_t)old,255};
  ui_alpha_blend(p,fg,255-fg,fg,a);
  CHECK(p[0]==(a*fg+(255-a)*old+127)/255);
  CHECK(p[1]==(a*(255-fg)+(255-a)*(255-old)+127)/255);
  CHECK(p[2]==p[0]&&p[3]==255);
 }
 enum{G=1024,F=1920*1200*4};uint8_t *mem=malloc(3*F+4*G);CHECK(mem);
 memset(mem,0xa5,3*F+4*G);
 const int xy[][2]={{-1,-1},{0,0},{1919,1199},{1920,1200},{-150,1190},{1900,-10},
  {INT_MIN,INT_MIN},{INT_MAX,INT_MAX},{1910,1180}};
 for(unsigned f=0;f<3;f++){
  uint8_t *frame=mem+G+f*(F+G);memset(frame,20,F);
  for(unsigned i=0;i<sizeof xy/sizeof xy[0];i++)for(unsigned s=0;s<7;s++)
   ui_alpha_draw(frame,xy[i][0],xy[i][1],1920,"Aa09 -+ \xc2\xb0 gyp \xff",ui_alpha_faces[s].height,200,100,40);
  for(unsigned s=0;s<7;s++){
   const ui_alpha_face_t *face=&ui_alpha_faces[s];
   for(unsigned ch=0;ch<96;ch++){
    char b[3]={(char)(ch+32),0,0};if(ch==95){b[0]=(char)0xc2;b[1]=(char)0xb0;}
    CHECK(ui_alpha_width(b,face->height)==ui_alpha_glyph(face,ch)->advance);
    ui_alpha_draw(frame,100+(ch%16)*100,100+(ch/16)*170,1920,b,face->height,10,255,80);
   }
  }
  CHECK(ui_alpha_width(NULL,24)==0);CHECK(ui_alpha_width("hello",25)==0);
  ui_alpha_draw(frame,1,1,INT_MIN,"hello",24,255,255,255);
  ui_alpha_draw(frame,1,1,INT_MAX,"hello",25,255,255,255);
  ui_alpha_draw(frame,1910,1190,1920,"A VERY LONG STRING THAT IS CLIPPED",52,255,255,255);
 }
 for(unsigned block=0;block<4;block++)for(unsigned i=0;i<G;i++)CHECK(mem[block*(F+G)+i]==0xa5);
 /* Every intermediate alpha must exist: this is not binary pixel scaling. */
 unsigned levels[256]={0};for(unsigned i=0;i<sizeof ui_alpha_52;i++)levels[ui_alpha_52[i]]=1;
 unsigned n=0;for(unsigned i=1;i<255;i++)n+=levels[i];CHECK(n>200);
 printf("ALPHA_FONT PASS checks=%llu: exact alpha blend, 7 faces, degree UTF8, clipping/3 frame guards; HOST ONLY\n",checks);
 free(mem);return 0;
}
