"""从随包Noto/OFL字体生成现有接口的三份字形，保持测向代码不变。"""
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont,__version__ as PILLOW_VERSION
from PIL import features
import hashlib,json,re,struct
ROOT=Path(__file__).resolve().parents[1]
FONT=ROOT/'third_party/fonts/NotoSansSC-wght.ttf'
FONT_SHA='a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da'
SIZES=(16,18,24,30,52,96,144)
BITMAP_POINTS=[39057, 35889, 20202, 36890, 36947, 29575, 22833, 30495, 27491, 24358, 26041, 27874, 19977, 35282, 38191, 40831, 26410, 30693, 25918, 22823, 36864, 20986, 20840, 25353, 38190, 23792, 20540, 31034, 22120, 20302, 21387, 30456, 20301, 31867, 22411, 27169, 27573, 30005, 26377, 25928, 37319, 38598, 20449, 21495, 28304, 31227, 24494, 32435, 31186]
def covered_codepoints(data):
 # 只读SFNT Unicode cmap。优先采用能覆盖全Unicode的format12。
 num=struct.unpack_from('>H',data,4)[0];tables={}
 for i in range(num):
  tag,check,offset,length=struct.unpack_from('>4sIII',data,12+16*i);tables[tag]=(offset,length)
 base,length=tables[b'cmap'];n=struct.unpack_from('>H',data,base+2)[0];covered=set()
 for i in range(n):
  platform,encoding,offset=struct.unpack_from('>HHI',data,base+4+8*i)
  p=base+offset;fmt=struct.unpack_from('>H',data,p)[0]
  if fmt==12 and platform in [0,3]:
   groups=struct.unpack_from('>I',data,p+12)[0]
   for g in range(groups):
    start,end,glyph=struct.unpack_from('>III',data,p+16+12*g)
    covered.update(range(start+(glyph==0),end+1))
 if not covered:raise ValueError('字体缺少已验证的Unicode cmap12，不猜测字符覆盖')
 return covered
def face(size):
 font=ImageFont.truetype(str(FONT),size);font.set_variation_by_axes([400]);return font
def image_for(font,ch):
 b=font.getbbox(ch,anchor='ls');im=Image.new('L',(max(0,b[2]-b[0]),max(0,b[3]-b[1])))
 if im.width and im.height:ImageDraw.Draw(im).text((-b[0],-b[1]),ch,font=font,fill=255,anchor='ls')
 return im,b
def fit(font,ch,width,height):
 im,_=image_for(font,ch);canvas=Image.new('L',(width,height))
 if not im.width or not im.height:return canvas
 scale=min(width/im.width,height/im.height,1.0)
 if scale<1:im=im.resize((max(1,round(im.width*scale)),max(1,round(im.height*scale))),Image.Resampling.LANCZOS)
 canvas.paste(im,((width-im.width)//2,(height-im.height)//2));return canvas
def generate():
 if PILLOW_VERSION!='12.3.0':raise RuntimeError('重生成固定使用Pillow12.3.0；硬件/软件构建可直接使用已签名的生成资产')
 if features.version_module('freetype2')!='2.14.3':raise RuntimeError('固定字模栅格化引擎须为FreeType2.14.3；可直接使用已核验资产编译')
 data=FONT.read_bytes();assert hashlib.sha256(data).hexdigest()==FONT_SHA
 source=ROOT/'receiver/software/src'
 text=''.join((source/p).read_text(encoding='utf-8') for p in ['ui_zh.h','debug_ui.c'])
 literals=''.join(re.findall(r'"(?:\\.|[^"\\])*"',text))
 cjk=sorted(set(re.findall(r'[\u3000-\u303f\u3400-\u9fff\uff00-\uffef]',literals)))
 chars=''.join(map(chr,range(32,127)))+'\u00b0'+''.join(cjk)
 assert set(map(ord,chars))|set(BITMAP_POINTS)<=covered_codepoints(data)
 banner='/* 本文件字形派生自随包Noto Sans SC，适用OFL-1.1；原字体及许可见third_party/fonts。 */'
 out=[banner,'#ifndef UI_ALPHA_ATLAS_H','#define UI_ALPHA_ATLAS_H','#define UI_ALPHA_GLYPH_COUNT %d'%len(chars),
 'static const uint32_t ui_cjk_codepoints[] = {'+','.join(str(ord(c)) for c in cjk)+'};']
 checks=0;faces=[]
 for size in SIZES:
  font=face(size);ascent,descent=font.getmetrics();blob=[];records=[]
  for ch in chars:
   offset=len(blob);advance=round(font.getlength(ch));supported=size<96 or ch in ' +-0123456789.?\u00b0'
   if supported:
    im,box=image_for(font,ch);rows=0
    for y in range(im.height):
     row=list(im.crop((0,y,im.width,y+1)).getdata());x=0
     while x<len(row):
      if not row[x]:x+=1;continue
      left=x;opaque=row[x]==255;x+=1
      while x<len(row) and row[x] and (row[x]==255)==opaque:x+=1
      assert max(y,left,x-left)<256
      blob.extend([y,left,x-left,int(opaque)])
      if not opaque:blob.extend(row[left:x])
      rows+=1
    decoded=Image.new('L',im.size);cursor=offset
    for _ in range(rows):
     y,x,n,opaque=blob[cursor:cursor+4];cursor+=4
     values=[255]*n if opaque else blob[cursor:cursor+n]
     for dx,a in enumerate(values):decoded.putpixel((x+dx,y),a)
     if not opaque:cursor+=n
    assert cursor==len(blob) and decoded.tobytes()==im.tobytes()
    # UI接口的height为行高；Noto自带ascent大于行高，直接使用会压住下一行。
    # 将基线固定在行高的85%，只调整字形资产坐标，不改renderer。
    checks+=1;bx,by=box[0],round(size*0.85)+box[1]
   else:rows=bx=by=0
   records.append([offset,rows,bx,by,advance,int(supported)])
  out+=['static const uint8_t ui_alpha_%d[] = {'%size]
  out+=[' '+','.join(map(str,blob[i:i+24]))+',' for i in range(0,len(blob),24)]
  out+=['};','static const ui_alpha_glyph_t ui_glyph_%d[UI_ALPHA_GLYPH_COUNT] = {'%size]
  out+=[' {%d,%d,%d,%d,%d,%d},'%tuple(r) for r in records]
  out+=['};'];faces.append(dict(size=size,alpha_bytes=len(blob),ascent=ascent,descent=descent,glyphs=len(records)))
 out+=['static const ui_alpha_face_t ui_alpha_faces[] = {']
 out+=[' {%d,ui_glyph_%d,ui_alpha_%d},'%(s,s,s) for s in SIZES]
 out+=['};','#endif','']
 (source/'ui_alpha_atlas.h').write_text('\n'.join(out),encoding='utf-8')
 out=[banner,'#include "font12x12.h"','const cjk_glyph_t cjk_font[CJK_FONT_COUNT] = {']
 for cp in BITMAP_POINTS:
  im=fit(face(12),chr(cp),12,12);raw=[]
  for x in range(12):
   value=sum((1<<y) for y in range(12) if im.getpixel((x,y))>=96);raw.extend([value&255,value>>8])
  out.append(' {0x%04XU,{%s}},'%(cp,','.join('0x%02X'%v for v in raw)))
 out+=['};','const u8 *cjk_find(u16 unicode) {',' for (unsigned i=0;i<CJK_FONT_COUNT;i++) if(cjk_font[i].unicode==unicode) return cjk_font[i].bitmap;',' return 0;','}','']
 (source/'font12x12.c').write_text('\n'.join(out),encoding='utf-8')
 out=[banner,'#ifndef FONT5X7_H_','#define FONT5X7_H_','#include "xil_types.h"','static const u8 font5x7[][5] = {']
 for cp in range(32,128):
  im=fit(face(9),chr(cp) if cp<127 else ' ',5,7)
  values=[sum(1<<y for y in range(7) if im.getpixel((x,y))>=96) for x in range(5)]
  out.append(' {'+','.join('0x%02X'%v for v in values)+'},')
 out+=['};','#endif','']
 (source/'font5x7.h').write_text('\n'.join(out),encoding='utf-8')
 names=['ui_alpha_atlas.h','font12x12.c','font5x7.h']
 result=dict(source_font='third_party/fonts/NotoSansSC-wght.ttf',source_font_sha256=FONT_SHA,source_commit='6c1dbe27dcf7d817d4b62cec033ba77fa8e2a5ec',license='OFL-1.1',
 pillow_version=PILLOW_VERSION,freetype_version=features.version_module('freetype2'),weight=400,baseline_policy='round(line_height*0.85)',cjk_count=len(cjk),bitmap_cjk_count=len(BITMAP_POINTS),ascii_bitmap_count=96,
 independently_decoded_alpha_glyphs=checks,faces=faces,
 assets=[dict(path='receiver/software/src/'+n,bytes=(source/n).stat().st_size,sha256=hashlib.sha256((source/n).read_bytes()).hexdigest()) for n in names])
 target=ROOT/'GENERATED_ASSETS.json';target.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(result,ensure_ascii=False))
if __name__=='__main__':generate()
