
"""生成独立相位补偿整数Golden向量；全部是合成数据，不是ADC或板级测量。"""
from pathlib import Path
import argparse,random,json,hashlib
S=1<<35;F=1<<24;FS=62499374
def image(valid=1,sign=1,bias=0,fmin=F,fmax=(FS//2-1)*F,profile=123,flags=0):
 return [valid&0xffffffff,sign&0xffffffff,bias&0xffffffff,(bias>>32)&0xffffffff,fmin&0xffffffff,(fmin>>32)&0xffffffff,fmax&0xffffffff,(fmax>>32)&0xffffffff,profile,flags]
def expected(c,raw,freq,valid,status,fs):
 v,sign,lo,hi,fl,fh,xl,xh,profile,flags=c
 sign=sign-(1<<32) if sign>>31 else sign
 bias=(hi<<32)|lo;bias=bias-(1<<64) if bias>>63 else bias
 fmin=(fh<<32)|fl;fmax=(xh<<32)|xl
 result=[status if valid or status else 7,0,0,0,0]
 if not valid or v==0:return result
 if v!=1 or flags or not -S<=bias<S or sign not in [-1,1] or not profile or not 0<fmin<=fmax or 2*fmax>=fs*F or fmax>=1<<49:
  result[2]=2;return result
 if not fmin<=freq<=fmax:result[2]=3;return result
 return [result[0],1,1,(sign*(raw-bias)+S)%(2*S)-S,profile]
def generate(out):
 out=Path(out)
 if out.exists():raise FileExistsError('不覆盖向量')
 rng=random.Random(20261101);rows=[]
 def add(c,raw=0,freq=4000000*F,valid=1,status=0,fs=FS):
  rows.append(' '.join('%08x'%v for v in c)+' '+' '.join(map(str,[fs,raw,freq,valid,status,*expected(c,raw,freq,valid,status,fs)])))
 edges=[-S,-S+1,-S+2,-S//2,-1,0,1,S//2,S-2,S-1]
 for raw in edges:
  for bias in edges:
   for sign in [-1,1]:add(image(sign=sign,bias=bias),raw)
 for _ in range(2048):add(image(sign=rng.choice([-1,1]),bias=rng.randrange(-S,S)),rng.randrange(-S,S))
 for c in [image(valid=0),image(valid=2),image(sign=0),image(sign=2),image(profile=0),image(flags=1),image(bias=S),image(bias=-S-1),image(fmin=0),image(fmin=2*F,fmax=F),image(fmax=FS*F//2),image(fmax=1<<49)]:
  add(c,raw=-S)
 for freq in [100*F-1,100*F,100*F+1,200*F-1,200*F,200*F+1]:add(image(fmin=100*F,fmax=200*F),freq=freq)
 for valid in [0,1]:
  for status in ([0,1,4,6,7] if not valid else [0]):add(image(),valid=valid,status=status)
 out.write_text('\n'.join(rows)+'\n',encoding='ascii')
 proof={'kind':'SYNTHETIC_INTEGER_GOLDEN','seed':20261101,'count':len(rows),'phase_unit':'pi/2^35','frequency_unit':'Hz/2^24','sha256':hashlib.sha256(out.read_bytes()).hexdigest()}
 out.with_suffix('.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2),encoding='utf-8')
 print(json.dumps(proof));return proof
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('--out',required=True);x=a.parse_args();generate(x.out)

