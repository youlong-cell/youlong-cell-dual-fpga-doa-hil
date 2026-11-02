
"""从干净源码创建当前双FPGA硬件、匹配软件和BOOT；绝不部署或操作板卡。"""
from pathlib import Path
import argparse,json,sys,re,subprocess,hashlib
sys.path.insert(0,str(Path(__file__).resolve().parent))
import prepare_project,prepare_build,run_vivado,build_platform,build_ps,build_boot
from check_package import check
from check_profiles import check as check_profiles
ROOT=Path(__file__).resolve().parents[1]
def main():
 a=argparse.ArgumentParser(description=__doc__)
 a.add_argument('--vivado',required=True);a.add_argument('--vitis',required=True)
 a.add_argument('--run-name',required=True);a.add_argument('--repo-root',type=Path,default=ROOT)
 a.add_argument('--with-tests',action='store_true');a.add_argument('--host-gcc')
 x=a.parse_args();root=x.repo_root
 if root.resolve()!=ROOT.resolve():raise ValueError('别名必须指向当前仓库')
 if not re.fullmatch(r'[A-Za-z0-9_-]+',x.run_name):raise ValueError('运行名只能含英数下划线及短横线')
 out=root/'build'/x.run_name
 if out.exists():raise FileExistsError('不覆盖旧运行；请使用新run-name')
 if x.with_tests and not x.host_gcc:raise ValueError('宿主测试需--host-gcc')
 out.mkdir(parents=True);steps=[]
 def record(stage,status,detail):
  steps.append({'stage':stage,'status':status,'detail':detail})
  (out/'PIPELINE.json').write_text(json.dumps(steps,ensure_ascii=False,indent=2),encoding='utf-8')
 def vendor(script,name):
  r=run_vivado.run(x.vivado,script,name)
  if r['exit_code']:raise RuntimeError('厂商工具失败，保留日志：'+name)
 try:
  integrity=check();check_profiles()
  if integrity['integrity']!='PASS' or integrity['missing_external']:raise RuntimeError('源码/字体身份检查未通过')
  r=subprocess.run([sys.executable,'-I','-X','utf8','-B',str(root/'transmitter/scripts/generate_mode_catalog.py'),'--check'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  (out/'mode_check.log').write_bytes(r.stdout)
  if r.returncode:raise RuntimeError('模式生成表漂移')
  record('inputs','PASS',integrity)
  if x.with_tests:
   import run_rtl_tests,run_host_tests
   run_rtl_tests.run(x.vivado,x.run_name+'_rtl')
   run_host_tests.run(x.host_gcc,x.run_name+'_host')
   record('tests','PASS','8项独立RTL、8项O0/O2宿主；不是板测')
  hardware={}
  for side,short in [('transmitter','tx'),('receiver','rx')]:
   create=x.run_name+'_'+short+'_create';build=x.run_name+'_'+short+'_pl'
   prepare_project.prepare(side,create,root=root)
   vendor(root/'build'/create/'loader.tcl',create)
   prepare_build.prepare(side,create,build,root=root)
   vendor(root/'build'/build/'loader.tcl',build)
   release=root/'build'/build/'release'
   for p in [release/(side+'.bit'),release/'routed.dcp']:
    if not p.is_file() or not p.stat().st_size:raise RuntimeError('厂商结束但缺少产物：'+str(p))
   hardware[side]=release;record(side,'BUILD VERIFIED',str(release))
  xsa=hardware['receiver']/'receiver_no_bit.xsa'
  platform=build_platform.run(xsa,x.vitis,x.run_name+'_platform',root=root)
  record('platform','BUILD VERIFIED',platform)
  build_ps.ROOT=root
  app=build_ps.run(platform['bsp'],Path(x.vitis)/'gnu/aarch64/nt/aarch64-none/bin',x.run_name+'_app')
  record('application','BUILD VERIFIED',str(app['elf']))
  result=build_boot.run(root/'build'/(x.run_name+'_platform')/'PLATFORM_RESULT.json',
    root/'build'/(x.run_name+'_app')/'ELF_RESULT.json',hardware['receiver']/'receiver.bit',xsa,x.vitis,x.run_name+'_boot',root=root)
  record('boot','PAYLOAD VERIFIED',{'path':result['BOOT'],'sha256':result['sha256']})
  final={'status':'OFFLINE_REPRODUCTION_COMPLETE','board_tested':False,'deployed':False,'BOOT':result['BOOT'],'BOOT_sha256':result['sha256'],'production_touched':False}
  (out/'COMPLETE.json').write_text(json.dumps(final,ensure_ascii=False,indent=2),encoding='utf-8')
  print(json.dumps(final,ensure_ascii=False))
 except Exception as e:
  record('failure','FAIL',str(e));raise
if __name__=='__main__':main()

