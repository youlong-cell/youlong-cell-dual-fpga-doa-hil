
"""从本轮独立构建的硬件、平台和应用生成BOOT，并逐字节核验载荷；不部署。"""
from pathlib import Path
import argparse,json,hashlib,subprocess,shutil,sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from verify_artifacts import verify_boot
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def run(platform_report,app_report,bit,xsa,home,name,root=ROOT):
 out=root/'build'/name
 if out.exists():raise FileExistsError(out)
 platform_report=Path(platform_report);app_report=Path(app_report);bit=Path(bit);xsa=Path(xsa)
 for p in [platform_report,app_report,bit,xsa]:
  if not p.resolve().is_relative_to((ROOT/'build').resolve()):raise ValueError('只接受本仓库build内独立构建产物：'+str(p))
 plat=json.loads(platform_report.read_text(encoding='utf-8'));app=json.loads(app_report.read_text(encoding='utf-8'))
 if plat['status']!='PLATFORM_BSP_BUILD_VERIFIED' or app['status']!='ELF_BUILD_VERIFIED':raise ValueError('平台/应用缺少构建证明')
 if sha(xsa)!=plat['xsa_sha256']:raise ValueError('XSA漂移')
 if sha(Path(app['elf']))!=app['sha256']:raise ValueError('应用漂移')
 for p,h in plat['files'].items():
  if sha(p)!=h:raise ValueError('平台产物漂移：'+p)
 out.mkdir(parents=True);paths={}
 for key,p in {'fsbl':Path(plat['fsbl']),'pmufw':Path(plat['pmufw']),'app':Path(app['elf']),'bit':bit}.items():
  dst=out/({'fsbl':'fsbl.elf','pmufw':'pmufw.elf','app':'DOA_RF_ENGINEERING.elf','bit':'receiver.bit'}[key]);shutil.copy2(p,dst);paths[key]=dst
 bif='DOA_REPRODUCED_ENGINEERING:\n{\n [pmufw_image] pmufw.elf\n [bootloader, destination_cpu=a53-0, exception_level=el-3, trustzone=secure] fsbl.elf\n [destination_device=pl] receiver.bit\n [destination_cpu=a53-0, exception_level=el-3, trustzone=secure] DOA_RF_ENGINEERING.elf\n}\n'
 (out/'boot.bif').write_text(bif,encoding='ascii');image=out/'BOOT.bin'
 cmd=[str(Path(home)/'bin/bootgen.bat'),'-arch','zynqmp','-image',str(out/'boot.bif'),'-o',str(image),'-log','info']
 r=subprocess.run(['cmd.exe','/d','/s','/c','call '+subprocess.list2cmdline(cmd)],cwd=out,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=300)
 (out/'bootgen.log').write_bytes(r.stdout)
 (out/'BOOTGEN_COMMAND.json').write_text(json.dumps({'command':cmd,'exit_code':r.returncode},ensure_ascii=False,indent=2),encoding='utf-8')
 if r.returncode or b'Bootimage generated successfully' not in r.stdout or not image.is_file():raise RuntimeError('BOOT未成功生成，保留日志')
 proof=verify_boot(image,paths)
 result={'status':'BOOT_BUILD_AND_PAYLOAD_VERIFIED','BOOT':str(image),'sha256':sha(image),'bytes':image.stat().st_size,'input_files':{str(p):sha(p) for p in [platform_report,app_report,bit,xsa]},'output_files':{p.name:sha(p) for p in [*paths.values(),image,out/'boot.bif']},'payload_verification':proof,'board_tested':False,'deployment_performed':False}
 (out/'BOOT_RESULT.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8');print(json.dumps(result,ensure_ascii=False));return result
if __name__=='__main__':
 a=argparse.ArgumentParser()
 for k in ['platform-report','app-report','bit','xsa','tool-home','out-name']:a.add_argument('--'+k,required=True)
 a.add_argument('--repo-root',type=Path,default=ROOT);x=a.parse_args()
 if x.repo_root.resolve()!=ROOT.resolve():raise ValueError('别名必须指向同一仓库')
 run(x.platform_report,x.app_report,x.bit,x.xsa,x.tool_home,x.out_name,root=x.repo_root)

