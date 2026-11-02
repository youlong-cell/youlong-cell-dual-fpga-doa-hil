"""只读检查当前Profile数值、身份与编译头，不写校准参数。"""
from pathlib import Path
from decimal import Decimal, ROUND_HALF_EVEN
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[1]
def check(root=ROOT):
 config=root/'receiver/config/calibration_profiles.json'
 profiles=json.loads(config.read_text(encoding='utf-8'),parse_float=Decimal)['profiles']
 header=(root/'receiver/software/src/hil_profile_generated.h').read_text(encoding='utf-8')
 blocks=re.findall(r'\{\s*\.geometry_id=.*?\.evidence_state=.*?\}',header,re.S)
 assert len(blocks)==len(profiles)==4
 expected_ids=[15,16,17,18];result=[]
 for p,b,profile_id in zip(profiles,blocks,expected_ids):
  c=p['calibration'];assert c['profile_id']==profile_id and c['phase_sign']==1 and c['measured'] is False
  assert Decimal(0)<p['minimum_hz']<p['reference_hz']<p['maximum_hz']<Decimal(62499374)/2
  code=int((c['phase_bias_deg']*Decimal(2**35)/Decimal(180)).to_integral_value(rounding=ROUND_HALF_EVEN))
  m=re.search(r'\.bias_pi_f35=([-+]?)INT64_C\((\d+)\)',b)
  actual=int(m.group(2))*(-1 if m.group(1)=='-' else 1);assert code==actual
  for key,value in [('profile_id',profile_id),('reference_hz',p['reference_hz']),('minimum_hz',p['minimum_hz']),('maximum_hz',p['maximum_hz'])]:
   assert re.search(r'\.'+key+r'='+str(value)+r'u\b',b)
  assert hashlib.sha256(config.read_bytes()).hexdigest() in b
  result.append(dict(profile_id=profile_id,frequency_hz=p['reference_hz'],bias_code=code,measured=False))
 return result
if __name__=='__main__':print(json.dumps(dict(status='HOST_CHECK_PASS',profiles=check()),ensure_ascii=False))
