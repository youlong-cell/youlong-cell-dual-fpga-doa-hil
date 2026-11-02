"""生成独立建工程Tcl草案；不调用Vivado，不综合、不操作板卡。"""
from pathlib import Path
import argparse,hashlib,json,re,shutil,sys
ROOT=Path(__file__).resolve().parents[1]
def quote(s):
 # Tcl双引号内明确转义替换符与Unicode，兼容Windows非ASCII路径。
 out=''
 for c in str(s).replace('\\','/'):
  if c in '$[]";':out+='\\'+c
  elif ord(c)>127:
   if ord(c)>65535:raise ValueError('路径含工具兼容性未验证的补充平面字符')
   out+='\\u%04x'%ord(c)
  else:out+=c
 return '"'+out+'"'
def prepare(side,name,root=ROOT):
 if side not in ['transmitter','receiver'] or not re.fullmatch(r'[A-Za-z0-9_-]+',name):raise ValueError('非法工程侧或新目录名')
 spec=json.loads((root/'PROJECTS.json').read_text(encoding='utf-8'))[side]
 for row in spec['sources']+([spec['post_synthesis_hook']] if 'post_synthesis_hook' in spec else []):
  p=root/row['path']
  if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=row['sha256']:raise ValueError('源集缺失或漂移：'+row['path'])
 out=root/'build'/name
 if out.exists():raise FileExistsError('不覆盖已有输出：'+str(out))
 out.mkdir(parents=True);project=out/'project'
 work=out/'rom_work';work.mkdir()
 for row in spec['sources']:
  if row['path'].endswith('.mem'):shutil.copy2(root/row['path'],work/Path(row['path']).name)
 lines=['# 仅创建独立候选工程；不执行硬件构建或编程。',
 'if {![string match "2023.1*" [version -short]]} {error "须使用已指定的Vivado2023.1"}',
 'set target '+quote(project),'if {[file exists $target]} {error "目标工程已存在"}',
 'create_project '+side+' $target -part '+spec['part'],
 'set_property target_language Verilog [current_project]',
 'config_ip_cache -disable_cache',
 'set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]',
 'set_property top '+spec['top']+' [get_filesets sources_1]',
 ]
 for row in spec['sources']:
  if row['path'].endswith('.bd'):continue
  path=root/row['path'];lines.append('add_files -norecurse '+quote(path))
  if row['role']=='constrs_1':
   lines[-1]='add_files -fileset constrs_1 -norecurse '+quote(path)
   if row['disabled']:lines.append('set_property IS_ENABLED false [get_files '+quote(path)+']')
   if path.name=='cdc_handwritten_sync_guard.tcl':
    lines+=['set_property FILE_TYPE TCL [get_files '+quote(path)+']',
    'set_property USED_IN_SYNTHESIS false [get_files '+quote(path)+']',
    'set_property USED_IN_IMPLEMENTATION true [get_files '+quote(path)+']',
    'set_property PROCESSING_ORDER LATE [get_files '+quote(path)+']',
    'set_property STEPS.OPT_DESIGN.TCL.PRE '+quote(path)+' [get_runs impl_1]']
 if spec['include_dirs']:
  lines.append('set_property include_dirs [list '+' '.join(quote(root/p) for p in spec['include_dirs'])+'] [get_filesets sources_1]')
 if side=='transmitter':
  src=root/'transmitter/ip/dac_pll/dac_pll.xci';d=json.loads(src.read_text(encoding='utf-8'))
  config_before=d['ip_inst']['parameters']
  d['ip_inst']['gen_directory']=(out/'ip_generated').as_posix()
  stage=out/'ip/dac_pll/dac_pll.xci';stage.parent.mkdir(parents=True)
  stage.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
  assert json.loads(stage.read_text(encoding='utf-8'))['ip_inst']['parameters']==config_before
  lines+=['import_ip [list '+quote(stage)+']','generate_target all [get_ips dac_pll]']
  lines.append('set_property STEPS.SYNTH_DESIGN.TCL.POST '+quote(root/'transmitter/constraints/apply_uart_j11.tcl')+' [get_runs synth_1]')
 else:
  bd=out/'bd/design_1.bd';bd.parent.mkdir();shutil.copy2(root/'receiver/bd/design_1.bd',bd)
  lines+=['set_property ip_repo_paths [list '+quote(root/'receiver/ip_repo')+'] [current_project]',
   'update_ip_catalog','update_compile_order -fileset sources_1',
   'add_files -norecurse '+quote(bd),'open_bd_design '+quote(bd),'validate_bd_design',
   'generate_target all [get_files '+quote(bd)+']',
   'set wrappers [make_wrapper -files [get_files '+quote(bd)+'] -top]',
   'add_files -norecurse $wrappers','set_property top '+spec['top']+' [get_filesets sources_1]']
 lines+=['update_compile_order -fileset sources_1',
 'report_ip_status -file '+quote(out/'ip_status.rpt'),
 'puts "PROJECT_CREATE_ONLY_COMPLETE"','close_project']
 tcl=out/'recreate.tcl';tcl.write_text('\n'.join(lines)+'\n',encoding='utf-8')
 (out/'loader.tcl').write_text('if {[catch {\n'+(tcl.read_text(encoding='utf-8')).encode('ascii','backslashreplace').decode('ascii')+'\n} e o]} {puts stderr $e;puts stderr [dict get $o -errorinfo];exit 1}\nexit 0\n',encoding='ascii')
 info=dict(status='TCL_EMITTED_NOT_VIVADO_EXECUTED',side=side,part=spec['part'],top=spec['top'],source_count=len(spec['sources']),tcl_sha256=hashlib.sha256(tcl.read_bytes()).hexdigest(),complete_build_verified=False)
 (out/'PLAN.json').write_text(json.dumps(info,ensure_ascii=False,indent=2),encoding='utf-8')
 return info
if __name__=='__main__':
 a=argparse.ArgumentParser(description=__doc__);a.add_argument('--side',choices=['transmitter','receiver'],required=True);a.add_argument('--out-name',required=True)
 a.add_argument('--repo-root',type=Path,default=ROOT);x=a.parse_args()
 if x.repo_root.resolve()!=ROOT.resolve():raise ValueError('别名必须指向同一仓库')
 print(json.dumps(prepare(x.side,x.out_name,root=x.repo_root),ensure_ascii=False))
