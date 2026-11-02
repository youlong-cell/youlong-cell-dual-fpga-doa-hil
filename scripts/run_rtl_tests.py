
"""以真实串口比特时序测试平台运行当前发送端仿真，严格检查结束标记。"""
from pathlib import Path
import argparse,json,subprocess,shutil,os,time,sys
ROOT=Path(__file__).resolve().parents[1]
MARKERS={'tb_angle_decoder':'ANGLE_DECODER_PASS','tb_angle_mapper':'ANGLE_MAPPER_PASS','tb_hil20_any_angle':'ANY_ANGLE_UART_PASS','tb_hil20_baud':'UART_BAUD_ALL_PASS','tb_reply_fifo':'REFACTOR_FIFO_ALL_PASS','tb_sample_timebase':'RESULT: PASS checks=timebase_semantics_and_tick_gating','tb_fine_result_slot':'RESULT: PASS fine_result_slot','tb_fine_phase_calibration':'RESULT: PASS calibration'}
def run(home,name,side=None):
 out=ROOT/'build'/name
 if out.exists():raise FileExistsError(out)
 out.mkdir(parents=True);results=[]
 for test in json.loads((ROOT/'SIMULATION_TESTS.json').read_text(encoding='utf-8'))['tests']:
  top=test['top']
  if side and not test['testbench'].startswith(side+'/'):continue
  w=out/top;w.mkdir()
  for f in test['data_files']:shutil.copy2(ROOT/f,w/Path(f).name)
  if test.get('generator'):
   r=subprocess.run([sys.executable,'-I','-X','utf8','-B',str(ROOT/test['generator']),'--out',str(w/'calibration_vectors.txt')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
   (w/'vector_generation.log').write_bytes(r.stdout)
   if r.returncode:raise RuntimeError('合成向量生成失败')
  commands=[
   [str(Path(home)/'bin/xvlog.bat'),'--sv',*[arg for inc in test['include_dirs'] for arg in ['-i',str(ROOT/inc)]],*[str(ROOT/f) for f in test['sources']],str(ROOT/test['testbench'])],
   [str(Path(home)/'bin/xelab.bat'),top,'-s','snapshot','--debug','typical'],
   [str(Path(home)/'bin/xsim.bat'),'snapshot','-runall']]
  records=[];ok=True
  for i,c in enumerate(commands):
   start=time.time();r=subprocess.run(['cmd.exe','/d','/s','/c','call '+subprocess.list2cmdline(c)],cwd=w,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=1800)
   (w/('step'+str(i)+'.log')).write_bytes(r.stdout);records.append({'command':c,'exit_code':r.returncode,'seconds':time.time()-start})
   if r.returncode:ok=False;break
  text=r.stdout.decode('utf-8',errors='replace')
  ok=ok and MARKERS[top] in text and 'Fatal:' not in text and 'FATAL_ERROR' not in text and 'RESULT: FAIL' not in text
  row={'top':top,'pass':ok,'required_marker':MARKERS[top],'commands':records};results.append(row)
  (out/'RTL_RESULTS.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
  print(top,'PASS' if ok else 'FAIL',flush=True)
  if not ok:raise RuntimeError('真实RTL测试失败，保留日志：'+str(w))
 return results
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('--tool-home',required=True);a.add_argument('--out-name',required=True);a.add_argument('--side',choices=['transmitter','receiver']);x=a.parse_args();run(x.tool_home,x.out_name,x.side)

