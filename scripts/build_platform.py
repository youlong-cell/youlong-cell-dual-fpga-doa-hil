
"""从本轮真实XSA创建独立平台，校验新BSP和启动组件，不连接硬件。"""
from pathlib import Path
import argparse,hashlib,json,os,subprocess,sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from prepare_platform import prepare
from verify_artifacts import elf
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def run(xsa,home,name,root=ROOT):
 prepare(xsa,name,root=root);out=root/'build'/name
 cmd=[str(Path(home)/'bin/xsct.bat'),str(out/'loader.tcl')]
 env=os.environ.copy();env.pop('PYTHONHOME',None);env.pop('PYTHONPATH',None)
 command=['cmd.exe','/d','/s','/c','call '+subprocess.list2cmdline(cmd)]
 with (out/'platform_console.log').open('wb') as stream:
  r=subprocess.run(command,cwd=out,env=env,stdout=stream,stderr=subprocess.STDOUT,timeout=2400)
 result={'command':command,'exit_code':r.returncode,'xsa':str(xsa),'xsa_sha256':sha(xsa),'board_tested':False}
 (out/'PLATFORM_EXECUTION.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
 text=(out/'platform_console.log').read_text(encoding='utf-8',errors='replace')
 if r.returncode or 'PLATFORM_GENERATE_COMPLETE' not in text:raise RuntimeError('平台构建失败或缺少完整结束标记：'+str(out))
 platform=out/'workspace/doa_ps'
 bsp=platform/'psu_cortexa53_0/standalone_domain/bsp/psu_cortexa53_0'
 fsbl=platform/'zynqmp_fsbl/fsbl_a53.elf';pmu=platform/'zynqmp_pmufw/pmufw.elf'
 for p in [bsp/'include/xparameters.h',bsp/'lib/libxil.a',fsbl,pmu]:
  if not p.is_file() or p.stat().st_size==0:raise RuntimeError('新平台产物缺失：'+str(p))
 if elf(fsbl)['machine']!=183 or elf(pmu)['machine']!=189:raise RuntimeError('启动处理器不匹配')
 result.update(status='PLATFORM_BSP_BUILD_VERIFIED',bsp=str(bsp),fsbl=str(fsbl),pmufw=str(pmu),files={str(p):sha(p) for p in [bsp/'include/xparameters.h',bsp/'lib/libxil.a',fsbl,pmu]})
 (out/'PLATFORM_RESULT.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
 print(json.dumps(result,ensure_ascii=False));return result
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('--xsa',required=True);a.add_argument('--tool-home',required=True);a.add_argument('--out-name',required=True);a.add_argument('--repo-root',type=Path,default=ROOT);x=a.parse_args()
 if x.repo_root.resolve()!=ROOT.resolve():raise ValueError('别名必须指向同一仓库')
 run(x.xsa,x.tool_home,x.out_name,root=x.repo_root)

