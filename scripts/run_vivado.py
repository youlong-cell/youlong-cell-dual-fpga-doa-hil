"""在仓库build内运行已审查的厂商Tcl；不操作板卡。"""
from pathlib import Path
import argparse,json,os,subprocess,time
ROOT=Path(__file__).resolve().parents[1]
def run(tool_home,script,out_name,timeout=14400):
 if tool_home is None:raise ValueError('必须显式给出工具安装目录')
 out=(ROOT/'build'/out_name).resolve()
 if not out.is_relative_to((ROOT/'build').resolve()):raise ValueError('输出必须在仓库build内')
 script=Path(script).resolve()
 if not script.is_relative_to((ROOT/'build').resolve()) or not script.is_file():raise ValueError('只运行仓库build内的已审查Tcl')
 home=Path(tool_home).resolve();bat=home/'bin/vivado.bat'
 if not bat.is_file():raise FileNotFoundError(bat)
 out.mkdir(parents=True,exist_ok=True)
 for name in ['vendor_console.log','VENDOR_EXECUTION.json']:
  if (out/name).exists():raise FileExistsError('不覆盖运行证据：'+str(out/name))
 env=os.environ.copy()
 env.pop('PYTHONHOME',None);env.pop('PYTHONPATH',None)
 # 保留厂商Tcl所需的原始用户目录环境；不改用户配置。
 args=[str(bat),'-mode','batch','-nojournal','-log',str(out/'vivado.log'),'-source',str(script)]
 if any(any(c in s for c in '%!^&|<>\r\n') for s in args):raise ValueError('工具路径/参数包含未支持的cmd元字符')
 command=[env.get('COMSPEC','C:/Windows/System32/cmd.exe'),'/d','/s','/c','call '+subprocess.list2cmdline(args)]
 started=time.time()
 with (out/'vendor_console.log').open('wb') as stream:
  process=subprocess.run(command,cwd=out,env=env,stdout=stream,stderr=subprocess.STDOUT,timeout=timeout)
 result=dict(command=command,script=str(script),exit_code=process.returncode,elapsed_seconds=time.time()-started,
 child_profile_overrides={},user_startup_tcl_may_load=True,hardware_operated=False)
 (out/'VENDOR_EXECUTION.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 return result
if __name__=='__main__':
 a=argparse.ArgumentParser(description=__doc__);a.add_argument('--tool-home',required=True);a.add_argument('--script',required=True);a.add_argument('--out-name',required=True);x=a.parse_args()
 r=run(x.tool_home,x.script,x.out_name);print(json.dumps(r,ensure_ascii=False));raise SystemExit(r['exit_code'])

