
"""创建或验证源码交付树SHA；默认只读，不进入build或历史目录。"""
from pathlib import Path
import argparse,hashlib,json,os,sys
ROOT=Path(__file__).resolve().parents[1]
EXCLUDE={'SHA256SUMS.json','SHA256SUMS.json.sha256'}
def files(root):
 for path,dirs,names in os.walk(root):
  dirs[:]=[d for d in dirs if d not in ['build','.git','__pycache__'] and not (Path(path).relative_to(root).as_posix() in {'transmitter','receiver'} and d=='vivado')]
  for n in names:
   p=Path(path)/n;r=p.relative_to(root).as_posix()
   if r not in EXCLUDE:yield p,r
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def refresh(root=ROOT):
 rows={r:{'sha256':sha(p),'bytes':p.stat().st_size} for p,r in sorted(files(root),key=lambda v:v[1])}
 manifest=root/'SHA256SUMS.json'
 manifest.write_text(json.dumps({'scope':'当前源码、必要资料及本轮证据；不含可再生build、Git元数据、自身及伴随摘要','files':rows},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 (root/'SHA256SUMS.json.sha256').write_text(sha(manifest)+'  SHA256SUMS.json\n',encoding='ascii')
 return len(rows)
def verify(root=ROOT):
 manifest=root/'SHA256SUMS.json';data=json.loads(manifest.read_text(encoding='utf-8'))
 expected=(root/'SHA256SUMS.json.sha256').read_text(encoding='ascii').split()[0]
 if sha(manifest)!=expected:raise ValueError('SHA清单自身发生变化')
 rows=data['files'];actual={r for p,r in files(root)}
 bad=[r for r,v in rows.items() if not (root/r).is_file() or sha(root/r)!=v['sha256'] or (root/r).stat().st_size!=v['bytes']]
 result={'status':'PASS' if not bad and actual==set(rows) else 'FAIL','files':len(rows),'drift':bad,'extra':sorted(actual-set(rows)),'missing':sorted(set(rows)-actual)}
 return result
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('--refresh',action='store_true');x=a.parse_args()
 if x.refresh:print('已更新当前交付树清单，文件数',refresh())
 else:
  r=verify();print(json.dumps(r,ensure_ascii=False,indent=2));raise SystemExit(0 if r['status']=='PASS' else 1)

