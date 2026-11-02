
"""以匹配BSP真实构建当前A53应用，并从最终ELF核验符号、地址和四频Profile。"""
from pathlib import Path
import argparse,json,subprocess,hashlib,os,re,sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from prepare_ps_build import prepare
from verify_artifacts import profiles,elf
from check_profiles import check as check_profiles
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def run(bsp,toolchain,name):
 prepare(bsp,toolchain,name,root=ROOT)
 out=ROOT/'build'/name;plan=json.loads((out/'COMPILE_PLAN.json').read_text(encoding='utf-8'));commands=[]
 env=os.environ.copy();env['PATH']=str(Path(toolchain))+os.pathsep+env.get('PATH','')
 env.pop('PYTHONHOME',None);env.pop('PYTHONPATH',None)
 version=subprocess.run([str(Path(toolchain)/'aarch64-none-elf-gcc.exe'),'--version'],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (out/'compiler_version.log').write_bytes(version.stdout)
 if version.returncode:raise RuntimeError('目标编译器版本查询失败')
 for i,c in enumerate(plan['commands']):
  r=subprocess.run(c,cwd=out,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=300)
  (out/('%02d.log'%i)).write_bytes(r.stdout);commands.append({'command':c,'exit_code':r.returncode})
  (out/'COMMANDS.json').write_text(json.dumps(commands,ensure_ascii=False,indent=2),encoding='utf-8')
  if r.returncode:raise RuntimeError('A53构建失败，保留日志：'+str(out/('%02d.log'%i)))
 p=out/'DOA_RF_ENGINEERING.elf';spec=json.loads((ROOT/'receiver/software/BUILD_SPEC.json').read_text(encoding='utf-8'))
 for suffix,options,name2 in [('readelf',['-h','-l','-S'],'readelf.log'),('nm',['-n'],'nm.log')]:
  c=[str(Path(toolchain)/('aarch64-none-elf-'+suffix+'.exe')),*options,str(p)]
  r=subprocess.run(c,cwd=out,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
  (out/name2).write_bytes(r.stdout)
  if r.returncode:raise RuntimeError(name2+'失败')
 symbols=(out/'nm.log').read_text(encoding='utf-8',errors='replace')
 for symbol in spec['symbols_required']:
  if not re.search(r'\b'+re.escape(symbol)+r'\s*$',symbols,re.M):raise RuntimeError('缺少必须符号：'+symbol)
 info=elf(p)
 if info['machine']!=183 or info['entry']!=int(spec['entry_expected'],0):raise RuntimeError('ELF架构或入口不符')
 for seg in info['LOAD']:
  if not 0x01000000<=seg['paddr']<=seg['end']<=0x3ff00000:raise RuntimeError('应用超出受控DDR区')
 actual=profiles(p);expected=check_profiles()
 for a,b in zip(actual,expected):
  if (a['profile_id'],a['reference_hz'],a['bias_pi_F35'],a['measured'],a['d_mm'],a['c_mps'])!=(b['profile_id'],b['frequency_hz'],b['bias_code'],0,5000,300000000):raise RuntimeError('最终ELF的校准或几何改变')
 result={'status':'ELF_BUILD_VERIFIED','elf':str(p),'sha256':sha(p),'bytes':p.stat().st_size,'profiles':actual,'ELF':info,'BSP_header_sha256':plan['bsp_header_sha256'],'BSP_lib_sha256':plan['bsp_lib_sha256'],'sources':{f:sha(ROOT/f) for f in spec['sources']+spec['font_dependencies']},'board_tested':False,'algorithm_changed':False}
 (out/'ELF_RESULT.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8');print(json.dumps(result,ensure_ascii=False));return result
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('--bsp',required=True);a.add_argument('--toolchain',required=True);a.add_argument('--out-name',required=True);a.add_argument('--repo-root',type=Path,default=ROOT);x=a.parse_args()
 if x.repo_root.resolve()!=ROOT.resolve():raise ValueError('别名必须指向同一仓库')
 ROOT=x.repo_root;run(x.bsp,x.toolchain,x.out_name)

