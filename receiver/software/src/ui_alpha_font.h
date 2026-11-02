#ifndef UI_ALPHA_FONT_H
#define UI_ALPHA_FONT_H
/* Static coverage atlas: no heap, files, floating point, or hardware access. */
#include <stdint.h>
#include <limits.h>
#include <string.h>
typedef struct {
 uint32_t offset;
 uint16_t rows;
 int16_t x,y;
 uint16_t advance;
 uint8_t supported;
} ui_alpha_glyph_t;
typedef struct {
 unsigned height;
 const ui_alpha_glyph_t *glyph;
 const uint8_t *alpha;
} ui_alpha_face_t;
#include "ui_alpha_atlas.h"
static inline const ui_alpha_face_t *ui_alpha_face(unsigned height)
{
 for(unsigned i=0;i<sizeof ui_alpha_faces/sizeof ui_alpha_faces[0];i++)
  if(ui_alpha_faces[i].height==height)return &ui_alpha_faces[i];
 return 0;
}
static inline unsigned ui_alpha_decode(const char **s)
{
 const unsigned char *p=(const unsigned char *)*s;
 uint32_t cp=p[0];unsigned n=1;
 if(cp>=0xc2&&cp<=0xdf)n=2;
 else if(cp>=0xe0&&cp<=0xef)n=3;
 else if(cp>=0xf0&&cp<=0xf4)n=4;
 else if(cp>=0x80){(*s)++;return '?'-32;}
 if(n>1){
  cp&=(1U<<(7-n))-1;
  for(unsigned i=1;i<n;i++){
   /* Stop at NUL before looking at any subsequent byte. */
   if(!p[i]||(p[i]&0xc0)!=0x80){(*s)++;return '?'-32;}
   cp=(cp<<6)|(p[i]&0x3f);
  }
  if((n==2&&cp<0x80)||(n==3&&cp<0x800)||(n==4&&cp<0x10000)||
     (cp>=0xd800&&cp<=0xdfff)||cp>0x10ffff){(*s)++;return '?'-32;}
 }
 *s+=n;
 if(cp>=32&&cp<127)return cp-32;
 if(cp==0xb0)return 95;
 unsigned lo=0,hi=sizeof ui_cjk_codepoints/sizeof ui_cjk_codepoints[0];
 while(lo<hi){unsigned mid=lo+(hi-lo)/2;
  if(ui_cjk_codepoints[mid]<cp)lo=mid+1;else hi=mid;}
 return lo<sizeof ui_cjk_codepoints/sizeof ui_cjk_codepoints[0]&&ui_cjk_codepoints[lo]==cp?96+lo:'?'-32;
}
static inline const ui_alpha_glyph_t *ui_alpha_glyph(const ui_alpha_face_t *face,unsigned ch)
{return &face->glyph[ch<UI_ALPHA_GLYPH_COUNT&&face->glyph[ch].supported?ch:'?'-32];}
static inline int ui_alpha_width(const char *s,unsigned height)
{
 const ui_alpha_face_t *face=ui_alpha_face(height);int width=0;
 if(!s||!face)return 0;
 while(*s){unsigned ch=ui_alpha_decode(&s);unsigned a=ui_alpha_glyph(face,ch)->advance;
  if(width>INT_MAX-(int)a)return INT_MAX;
  width+=(int)a;
 }
 return width;
}
/* Exact round-to-nearest for v/255, v in [0,65025]. Exhaustively tested. */
static inline uint8_t ui_alpha_div255(unsigned v)
{v+=128;return (uint8_t)((v+(v>>8))>>8);}
static inline void ui_alpha_blend(uint8_t *p,uint8_t r,uint8_t g,uint8_t b,unsigned a)
{
 if(!a)return;
#ifdef UI_FONT_METRICS
 extern uint64_t ui_test_pixel_writes; ++ui_test_pixel_writes;
#endif
 if(a==255){p[0]=r;p[1]=g;p[2]=b;}
 else{unsigned inv=255-a;
  p[0]=ui_alpha_div255(a*r+inv*p[0]);
  p[1]=ui_alpha_div255(a*g+inv*p[1]);
  p[2]=ui_alpha_div255(a*b+inv*p[2]);
 }
 p[3]=255;
}
static inline void ui_alpha_draw(uint8_t *frame,int x,int y,int right,const char *s,
 unsigned height,uint8_t r,uint8_t g,uint8_t b)
{
 const ui_alpha_face_t *face=ui_alpha_face(height);
 if(!frame||!s||!face||right<=0||x>=1920||y>=1200||y< -512||x< -65536)return;
 if(right>1920)right=1920;
 while(*s){unsigned ch=ui_alpha_decode(&s);const ui_alpha_glyph_t *glyph=ui_alpha_glyph(face,ch);
  if(x>right-(int)glyph->advance)break;
  const uint8_t *row=face->alpha+glyph->offset;
  for(unsigned j=0;j<glyph->rows;j++){
   int py=y+glyph->y+row[0],left=x+glyph->x+row[1];unsigned count=row[2],opaque=row[3];row+=4;
   if(py>=0&&py<1200){
    int begin=left<0?-left:0,end=(int)count;
    if(left+end>right)end=right-left;
    if(begin<end){uint8_t *p=frame+(uint32_t)py*7680+(uint32_t)(left+begin)*4;
     if(opaque){const uint8_t rgba[4]={r,g,b,255};
      for(int k=begin;k<end;k++,p+=4){memcpy(p,rgba,4);
#ifdef UI_FONT_METRICS
       extern uint64_t ui_test_pixel_writes; ++ui_test_pixel_writes;
#endif
      }
     }else for(int k=begin;k<end;k++,p+=4)ui_alpha_blend(p,r,g,b,row[k]);}
   }if(!opaque)row+=count;
  }
  x+=glyph->advance;
 }
}
#endif
