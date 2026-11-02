
"""运行当前PS显示软件的宿主测试；不把合成快照当作板测。"""
from pathlib import Path
import argparse,subprocess,json,time,os
ROOT=Path(__file__).resolve().parents[1]
def run(gcc,name):
 out=ROOT/'build'/name
 if out.exists():raise FileExistsError(out)
 out.mkdir(parents=True);env=os.environ.copy();env['PATH']=str(Path(gcc).parent)+os.pathsep+env.get('PATH','');t=ROOT/'receiver/software/tests';s=ROOT/'receiver/software/src'
 cases={
 'alpha':(['test_alpha_font.c'],[],'ALPHA_FONT PASS'),
 'ema':(['test_doa_ui_ema.c'],['doa_ui_ema.c','fine_production_decode.c'],'DOA_UI_EMA_PASS'),
 'spectrum':(['test_spectrum_filter.c'],['spectrum_display_filter.c'],'PASS'),
 'ui':(['test_debug_ui.c','profile_clock_stub.c'],['debug_ui.c','debug_pages.c','debug_input.c','lcd_doa.c','font12x12.c','fine_production_decode.c','hil_profiles.c','doa_ui_ema.c'],'DEBUG UI PASS')}
 results=[]
 for opt in ['-O0','-O2']:
  for label,(tests,sources,marker) in cases.items():
   w=out/(label+opt[1:]);w.mkdir();exe=w/'test.exe'
   cmd=[str(gcc),'-std=gnu11',opt,'-g','-Wall','-Wextra','-Wno-unused-function','-DENGINEERING_SESSION=1','-I'+str(t/'stubs'),'-I'+str(t),'-I'+str(s),'-I'+str(ROOT/'receiver/software/drivers/dpdma_v1_4'),*[str(t/f) for f in tests],*[str(s/f) for f in sources],'-lm','-o',str(exe)]
   r=subprocess.run(cmd,cwd=w,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
   (w/'compile.log').write_bytes(r.stdout);passed=False;run_cmd=[str(exe),str(w/'ui')]
   if r.returncode==0:
    start=time.time();rr=subprocess.run(run_cmd,cwd=w,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=300)
    (w/'run.log').write_bytes(rr.stdout);text=rr.stdout.decode('utf-8',errors='replace')
    passed=rr.returncode==0 and marker in text
   results.append({'test':label,'optimization':opt,'pass':passed,'compile_command':cmd,'compile_exit':r.returncode,'run_command':run_cmd,'run_exit':rr.returncode if r.returncode==0 else None})
   (out/'HOST_RESULTS.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
   print(label,opt,'PASS' if passed else 'FAIL',flush=True)
   if not passed:raise RuntimeError('测试失败，请查看原始日志：'+str(w))
 if any(out.rglob('*.rgba')):
  from PIL import Image
  for p in out.rglob('*.rgba'):
   b=p.read_bytes()
   if len(b)==1920*1200*4:Image.frombytes('RGBA',(1920,1200),b).save(p.with_suffix('.png'))
 return results
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('--gcc',required=True);a.add_argument('--out-name',required=True);x=a.parse_args();run(x.gcc,x.out_name)

