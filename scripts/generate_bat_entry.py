"""由权威JSON源集生成原生Tcl清单和ASCII入口；用户双击BAT不需要Python。"""
from pathlib import Path
import argparse,json,hashlib,re
ROOT=Path(__file__).resolve().parents[1]
def atom(s):
    s=str(s)
    if not re.fullmatch(r'[A-Za-z0-9_./+-]+',s):raise ValueError('清单字段需明确的安全相对路径或名称：'+s)
    return '{'+s+'}'
def render(root=ROOT):
    spec=json.loads((root/'PROJECTS.json').read_text(encoding='utf-8'))
    tests=json.loads((root/'SIMULATION_TESTS.json').read_text(encoding='utf-8'))['tests']
    old=json.loads((root/'SOURCE_MANIFEST.json').read_text(encoding='utf-8'))['files']
    assets=json.loads((root/'GENERATED_ASSETS.json').read_text(encoding='utf-8'))['assets']
    hashes={r['path']:r['sha256'] for r in old+assets}
    for t in tests:
        p=t['testbench'];hashes[p]=hashlib.sha256((root/p).read_bytes()).hexdigest()
    for p in ['PROJECTS.json','SIMULATION_TESTS.json','SOURCE_MANIFEST.json']:
        hashes[p]=hashlib.sha256((root/p).read_bytes()).hexdigest()
    lines=['# JSON source catalog derivative; generated, do not hand edit.',
           'set doa_catalog_id '+atom(hashes['PROJECTS.json']),'set doa_specs [dict create]']
    for side,s in spec.items():
        lines+=['dict set doa_specs '+side+' part '+atom(s['part']),
                'dict set doa_specs '+side+' top '+atom(s['top'])]
        rows=['[list '+atom(r['path'])+' '+atom(r['role'])+' '+str(int(r['disabled']))+']' for r in s['sources']]
        lines.append('dict set doa_specs '+side+' sources [list '+' '.join(rows)+']')
        lines.append('dict set doa_specs '+side+' include_dirs [list '+' '.join(atom(p) for p in s['include_dirs'])+']')
        sources=[t['testbench'] for t in tests if t['testbench'].startswith(side+'/')]
        lines.append('dict set doa_specs '+side+' sim_sources [list '+' '.join(atom(p) for p in sources)+']')
        lines.append('dict set doa_specs '+side+' sim_top '+('tb_hil20_baud' if side=='transmitter' else 'tb_sample_timebase'))
    lines+=['set doa_input_hashes [list '+' '.join(atom(p)+' '+atom(h) for p,h in sorted(hashes.items()))+']','']
    text=(root/'auto_create_project/create_project.tcl').read_text(encoding='utf-8')
    # 窗口工具采用ASCII直接载入；维护者读取中文主脚本，运行语义相同。
    loader='if {[catch {\n'+text.encode('ascii','backslashreplace').decode('ascii')+'\n} error_message error_options]} {\n puts stderr $error_message\n puts stderr [dict get $error_options -errorinfo]\n exit 1\n}\nexit 0\n'
    return {'auto_create_project/sources.tcl':'\n'.join(lines),'auto_create_project/run.tcl':loader,'auto_create_project/input_hashes.json':json.dumps({'catalog_sha256':hashes['PROJECTS.json'],'files':[{'path':p,'sha256':h} for p,h in sorted(hashes.items())]},ensure_ascii=True,indent=2)+'\n'}
def generate(root=ROOT,check=False):
    result=[]
    for relative,text in render(root).items():
        p=root/relative
        if check:
            if not p.is_file() or p.read_text(encoding='utf-8')!=text:raise ValueError('派生入口过期：'+relative)
        else:p.write_text(text,encoding='ascii',newline='\n')
        result.append(relative)
    return result
if __name__=='__main__':
    a=argparse.ArgumentParser();a.add_argument('--check',action='store_true');x=a.parse_args()
    print(json.dumps({'status':'CHECK_PASS' if x.check else 'GENERATED','files':generate(check=x.check)},ensure_ascii=False))

