"""Control-plane angle ROM only; never edits the existing NCO waveform ROM.

HIL d=5m,c=300000000m/s; phase turns=f*d/c*sin(theta).
0.1deg index, 80-digit Decimal Taylor sin, nearest-even 32bit phase word.
"""
from decimal import Decimal,localcontext,ROUND_HALF_EVEN
from pathlib import Path
import hashlib,json
from generate_mode_catalog import load_catalog
ROOT=Path(__file__).resolve().parents[1]
PI=Decimal('3.141592653589793238462643383279502884197169399375105820974944592307816406286208998628')
def phase(frequency,angle_tenths):
    with localcontext() as ctx:
        ctx.prec=80
        x=Decimal(angle_tenths)*PI/1800
        term=x;s=x
        for k in range(1,90):
            term=-term*x*x/Decimal((2*k)*(2*k+1));s+=term
        exact=s*Decimal(frequency)*5*Decimal(2**32)/300000000
        return int(exact.to_integral_value(rounding=ROUND_HALF_EVEN)),exact
def main():
    words=[];vectors=[];maxerr=Decimal(0)
    # 频段次序来自统一定义，避免ROM生成脚本另存一张频率表。
    for band in load_catalog()['frequencies']:
        fi,f=band['index'],band['hz']
        for a in range(1024):
            word,exact=phase(f,a) if a<=900 else (0,Decimal(0))
            words.append('%08X'%(word&0xffffffff))
            if a<=900:
                maxerr=max(maxerr,abs(Decimal(word)-exact))
                for sign in ([1] if a==0 else [1,-1]):
                    vectors.append(f'{fi:X} {((sign*a)&0x7ff):03X} {((sign*word)&0xffffffff):08X}\n')
    rom=ROOT/'config/hil_angle_phase_rom.mem'
    rom.write_text('\n'.join(words)+'\n',encoding='ascii')
    sim=ROOT/'sim/uart_angle';sim.mkdir(parents=True,exist_ok=True)
    (sim/'angle_golden_vectors.txt').write_text(''.join(vectors),encoding='ascii')
    result={'classification':'DERIVED / NOT_ANALOG_MEASURED','model':'FIXED_BASELINE_HIL','d_m':5,'c_m_per_s':300000000,
      'step_deg':'0.1','range_deg':[-90,90],'entries':4096,'legal_positive_entries':3604,'signed_vectors':len(vectors),
      'rounding':'NEAREST_EVEN','max_phase_word_rounding_error_LSB':str(maxerr),'phase_LSB_deg':360/(2**32),
      'rom_sha256':hashlib.sha256(rom.read_bytes()).hexdigest(),'source_script_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    out=ROOT/'reports/uart_angle_20261020/ANGLE_ENCODING.json';out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(result,indent=2),encoding='utf-8');print('ANGLE_ROM_GENERATED',len(vectors),result['rom_sha256'])
if __name__=='__main__':main()
