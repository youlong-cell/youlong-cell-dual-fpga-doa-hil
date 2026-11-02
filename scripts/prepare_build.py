"""生成独立综合/实现/位流流程；仅对已明确授权的候选工程使用。"""
from pathlib import Path
import argparse,json,re
import sys
# 明确载入同目录辅助模块，不依赖当前目录或外部PYTHONPATH。
sys.path.insert(0,str(Path(__file__).resolve().parent))
from prepare_project import quote
ROOT=Path(__file__).resolve().parents[1]
def prepare(side,project_run,out_name,root=ROOT):
 for name in [project_run,out_name]:
  if not re.fullmatch(r'[A-Za-z0-9_-]+',name):raise ValueError('非法目录名')
 if side not in ['transmitter','receiver']:raise ValueError('未知工程')
 project=root/'build'/project_run/'project'/(side+'.xpr')
 if not project.is_file():raise FileNotFoundError('必须先成功创建独立工程')
 out=root/'build'/out_name
 if out.exists():raise FileExistsError('不覆盖旧构建证据')
 out.mkdir(parents=True);report=out/'reports';release=out/'release';report.mkdir();release.mkdir()
 lines=[
 '# 已授权的独立复现综合/实现，不操作板卡，不改RTL或约束内容。',
 'set project '+quote(project),'set reports '+quote(report),'set release '+quote(release),
 'open_project $project','set_param general.maxThreads 6',
 'set syn [get_runs synth_1]',
 'if {[lsearch -exact [list_property $syn] AUTO_INCREMENTAL_CHECKPOINT]>=0} {set_property AUTO_INCREMENTAL_CHECKPOINT 0 $syn}',
 'launch_runs synth_1 -jobs 6','wait_on_run synth_1',
 'set status [get_property STATUS [get_runs synth_1]]',
 'if {![string match "*synth_design Complete*" $status]} {error "SYNTHESIS_FAILED: $status"}',
 'open_run synth_1','report_utilization -file [file join $reports synthesis_utilization.rpt]',
 'close_design','launch_runs impl_1 -to_step route_design -jobs 6','wait_on_run impl_1',
 'set status [get_property STATUS [get_runs impl_1]]',
 'if {![string match "*route_design Complete*" $status]} {error "IMPLEMENTATION_FAILED: $status"}',
 'open_run impl_1','report_route_status -file [file join $reports route_status.rpt]',
 'report_utilization -file [file join $reports routed_utilization.rpt]',
 'report_utilization -hierarchical -file [file join $reports hierarchy.rpt]',
 'report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -file [file join $reports timing_summary.rpt]',
 'report_cdc -details -file [file join $reports cdc.rpt]',
 'report_drc -file [file join $reports drc.rpt]',
 'report_methodology -file [file join $reports methodology.rpt]',
 'report_exceptions -ignored -file [file join $reports ignored_exceptions.rpt]',
 'set setup [get_timing_paths -delay_type max -max_paths 1]',
 'set hold [get_timing_paths -delay_type min -max_paths 1]',
 'if {[llength $setup]!=1 || [llength $hold]!=1} {error "TIMING_PATHS_MISSING"}',
 'set wns [get_property SLACK $setup]','set whs [get_property SLACK $hold]',
 'set fp [open [file join $reports timing_gate.txt] w]',
 'puts $fp "WNS=$wns\\nWHS=$whs"','close $fp',
 'if {$wns<0 || $whs<0} {error "ROUTED_TIMING_FAILED WNS=$wns WHS=$whs"}',
 'foreach v [get_drc_violations] {if {[string equal -nocase [get_property SEVERITY $v] Error]} {error "DRC_ERROR_BEFORE_BITSTREAM: $v"}}',
 'write_checkpoint [file join $release routed.dcp]',
 'write_bitstream [file join $release '+side+'.bit]']
 if side=='receiver':lines.append('write_hw_platform -fixed -file [file join $release receiver_no_bit.xsa]')
 lines+=['puts "REPRODUCTION_PL_COMPLETE side='+side+' WNS=$wns WHS=$whs"','close_project']
 script=out/'build.tcl';script.write_text('\n'.join(lines)+'\n',encoding='utf-8')
 (out/'loader.tcl').write_text('if {[catch {\n'+(script.read_text(encoding='utf-8')).encode('ascii','backslashreplace').decode('ascii')+'\n} e o]} {puts stderr $e;puts stderr [dict get $o -errorinfo];exit 1}\nexit 0\n',encoding='ascii')
 info=dict(status='BUILD_SCRIPT_PREPARED_NOT_EXECUTED',side=side,project=str(project),output=str(out))
 (out/'BUILD_PLAN.json').write_text(json.dumps(info,ensure_ascii=False,indent=2),encoding='utf-8')
 return info
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('--side',required=True);a.add_argument('--project-run',required=True);a.add_argument('--out-name',required=True);a.add_argument('--repo-root',type=Path,default=ROOT);x=a.parse_args()
 if x.repo_root.resolve()!=ROOT.resolve():raise ValueError('别名必须指向同一仓库')
 print(json.dumps(prepare(x.side,x.project_run,x.out_name,root=x.repo_root),ensure_ascii=False))

