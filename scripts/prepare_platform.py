"""只生成匹配XSA的平台创建草案，不调用XSCT。"""
from pathlib import Path
import argparse,hashlib,json,re,zipfile
import sys
# 明确载入同目录辅助模块，不依赖当前目录或外部PYTHONPATH。
sys.path.insert(0,str(Path(__file__).resolve().parent))
from prepare_project import quote
ROOT=Path(__file__).resolve().parents[1]
def prepare(xsa,name,root=ROOT):
 xsa=Path(xsa).resolve()
 if not re.fullmatch(r'[A-Za-z0-9_-]+',name):raise ValueError('非法新目录名')
 if not xsa.is_file():raise FileNotFoundError('XSA不存在')
 with zipfile.ZipFile(xsa) as z:
  if z.testzip() is not None:raise ValueError('XSA压缩完整性失败')
  if not any(n.endswith('.hwh') for n in z.namelist()):raise ValueError('缺少硬件元数据')
 out=root/'build'/name
 if out.exists():raise FileExistsError('禁止覆盖')
 out.mkdir(parents=True)
 lines=['# 只生成A53裸机平台，不连接/编程设备。','setws '+quote(out/'workspace'),
 'platform create -name doa_ps -hw '+quote(xsa)+' -proc psu_cortexa53_0 -os standalone -arch 64-bit',
 'platform generate','platform report','puts "PLATFORM_GENERATE_COMPLETE"']
 (out/'platform.tcl').write_text('\n'.join(lines)+'\n',encoding='utf-8')
 (out/'loader.tcl').write_text('if {[catch {\n'+('\n'.join(lines)).encode('ascii','backslashreplace').decode('ascii')+'\n} e o]} {puts stderr $e;puts stderr [dict get $o -errorinfo];exit 1}\nexit 0\n',encoding='ascii')
 info=dict(status='PLAN_ONLY_NOT_PLATFORM_BUILT',xsa_sha256=hashlib.sha256(xsa.read_bytes()).hexdigest(),processor='psu_cortexa53_0',os='standalone',architecture=64,hardware_alignment='须另核对BD/地址/时钟/DMA与硬件制品来源，不由ZIP存在自动通过')
 (out/'PLATFORM_INPUT.json').write_text(json.dumps(info,ensure_ascii=False,indent=2),encoding='utf-8')
 return info
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('--xsa',required=True);a.add_argument('--out-name',required=True);x=a.parse_args()
 print(json.dumps(prepare(x.xsa,x.out_name),ensure_ascii=False))
