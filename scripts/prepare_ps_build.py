"""仅输出A53编译命令计划；不调用编译器、bootgen或硬件。"""
from pathlib import Path
import argparse,hashlib,json,re
ROOT=Path(__file__).resolve().parents[1]
def prepare(bsp,toolchain,name,root=ROOT):
 if not re.fullmatch(r'[A-Za-z0-9_-]+',name):raise ValueError('非法输出名')
 bsp=Path(bsp).resolve();tc=Path(toolchain).resolve()
 spec=json.loads((root/'receiver/software/BUILD_SPEC.json').read_text(encoding='utf-8'))
 missing=[p for p in spec['sources']+spec['font_dependencies'] if not (root/p).is_file()]
 if missing:raise FileNotFoundError('真实依赖缺失，禁止假构建：'+', '.join(missing))
 h=bsp/'include/xparameters.h';lib=bsp/'lib/libxil.a'
 if not h.is_file() or not lib.is_file():raise FileNotFoundError('匹配BSP头或libxil不存在')
 text=h.read_text(encoding='utf-8',errors='replace')
 for key,expected in spec['fine_addresses_expected'].items():
  m=re.search(r'^\s*#define\s+'+key+r'\s+(0x[0-9a-fA-F]+|\d+)[uUlL]*\b',text,re.M)
  if not m or int(m.group(1),0)!=int(expected,0):raise ValueError('BSP地址不匹配：'+key)
 gcc=tc/'aarch64-none-elf-gcc.exe'
 if not gcc.is_file():raise FileNotFoundError('指定目标编译器不存在')
 out=root/'build'/name
 if out.exists():raise FileExistsError('禁止覆盖')
 out.mkdir(parents=True);commands=[];objects=[]
 flags=spec['flags']+['-I'+str(root/'receiver/software/src'),'-I'+str(bsp/'include')]
 for i,source in enumerate(spec['sources']):
  p=root/source;obj=out/(str(i)+'_'+p.stem+'.o');objects.append(str(obj))
  more=[] if p.name in spec['forced_include_exceptions'] else ['-include',str(root/spec['forced_include'])]
  commands.append([str(gcc),*flags,*more,'-c',str(p),'-o',str(obj)])
 elf=out/'DOA_RF_ENGINEERING.elf'
 commands.append([str(gcc),'-Wl,--gc-sections','-Wl,--undefined,receiver_build_identity','-Wl,--defsym,ENGINEERING_TEST_NOT_SIGNED_OFF=1',
 '-Wl,-T,'+str(root/spec['linker_script']),'-Wl,-Map,'+str(out/'receiver.map'),'-L'+str(bsp/'lib'),'-o',str(elf),*objects,
 '-Wl,--start-group','-lxil','-lgcc','-lc','-lm','-Wl,--end-group'])
 info=dict(status='PLAN_ONLY_NOT_ELF_BUILT',commands=commands,bsp_header_sha256=hashlib.sha256(h.read_bytes()).hexdigest(),bsp_lib_sha256=hashlib.sha256(lib.read_bytes()).hexdigest(),hardware_alignment='仅地址预检；须提供与目标XSA对应的平台构建证据',board_tested=False)
 (out/'COMPILE_PLAN.json').write_text(json.dumps(info,ensure_ascii=False,indent=2),encoding='utf-8')
 return dict(status=info['status'],commands=len(commands))
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('--bsp',required=True);a.add_argument('--toolchain',required=True);a.add_argument('--out-name',required=True);x=a.parse_args()
 print(json.dumps(prepare(x.bsp,x.toolchain,x.out_name),ensure_ascii=False))
