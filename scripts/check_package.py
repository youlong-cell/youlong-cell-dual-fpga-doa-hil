"""区分复制完整性、真实缺失依赖和公开就绪，不靠忽略获得PASS。"""
from pathlib import Path
import argparse,hashlib,json,re,os,sys
ROOT=Path(__file__).resolve().parents[1]
def source_files(root):
 # 先剪枝再遍历，避免检查器进入数GB可再生构建输出。
 for directory,dirs,files in os.walk(root):
  dirs[:]=[d for d in dirs if d not in ['build','.git','__pycache__'] and not (Path(directory).relative_to(root).as_posix() in {'transmitter','receiver'} and d=='vivado')]
  for name in files:yield Path(directory)/name

def check(root=ROOT):
 manifest=json.loads((root/'SOURCE_MANIFEST.json').read_text(encoding='utf-8'))
 drift=[x['path'] for x in manifest['files'] if not (root/x['path']).is_file() or hashlib.sha256((root/x['path']).read_bytes()).hexdigest()!=x['sha256']]
 # 双击入口的派生清单必须与权威JSON一致；不检查可再生Vivado输出。
 sys.path.insert(0,str(root/'scripts'))
 from generate_bat_entry import render
 for relative,text in render(root).items():
  if not (root/relative).is_file() or (root/relative).read_text(encoding='utf-8')!=text:drift.append(relative)
 ext=json.loads((root/'EXTERNAL_DEPENDENCIES.json').read_text(encoding='utf-8'))['files']
 missing=[x['path'] for x in ext if not (root/x['path']).is_file()]
 wrong=[x['path'] for x in ext if (root/x['path']).exists() and hashlib.sha256((root/x['path']).read_bytes()).hexdigest()!=x['sha256']]
 artifacts=[str(p.relative_to(root)) for p in source_files(root) if p.is_file() and 'build' not in p.relative_to(root).parts and (p.suffix.lower() in {'.bit','.elf','.dcp','.xsa','.ttf','.ttc','.otf','.zip'} or 'acoustic_doa' in p.parts) and p.relative_to(root).as_posix()!='third_party/fonts/NotoSansSC-wght.ttf']
 font=root/'third_party/fonts/NotoSansSC-wght.ttf'
 if not font.is_file() or hashlib.sha256(font.read_bytes()).hexdigest()!='a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da':drift.append('third_party/fonts/NotoSansSC-wght.ttf')
 license=root/'third_party/fonts/OFL.txt'
 if not license.is_file() or hashlib.sha256(license.read_bytes()).hexdigest()!='1c05c68c34f9708415aada51f17e1b0092d2cea709bf4a94cd38114f9e73d7d9':drift.append('third_party/fonts/OFL.txt')
 history=[p.relative_to(root).as_posix() for p in source_files(root) if p.is_file() and 'build' not in p.relative_to(root).parts and (any(k in p.relative_to(root).parts for k in ['archive','reference','backup','legacy','xsim','golden']) or p.name.endswith(('_equiv.sv','_equivalence.sv')))]
 return dict(integrity='PASS' if not drift and not wrong and not artifacts and not history else 'FAIL',history_paths=history,files_checked=len(manifest['files']),drift=drift,missing_external=missing,wrong_external=wrong,unexpected_artifacts=artifacts,public_release='BLOCKED',blockers=['模板/链接脚本许可范围待确认'],verification_limits=['实际构建状态见REPRODUCTION_STATUS.json','新制品未上板'],board_verified=False)
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('--require-public-ready',action='store_true');x=a.parse_args();r=check();print(json.dumps(r,ensure_ascii=False,indent=2))
 raise SystemExit(2 if r['integrity']=='FAIL' or (x.require_public_ready and r['public_release']!='READY') else 0)
