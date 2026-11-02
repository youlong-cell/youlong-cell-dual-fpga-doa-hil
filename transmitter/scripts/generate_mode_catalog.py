"""从唯一模式定义生成局部静态表；不综合、不改ROM、不操作硬件。"""
import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'config/hil_mode_catalog.json'
OUTPUT = ROOT / 'config/generated'


def load_catalog(path=CATALOG):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    if data['schema_version'] != 1:
        raise ValueError('未知模式定义版本')
    bands, modes, cycle = data['frequencies'], data['modes'], data['key_cycle']
    if [f['index'] for f in bands] != list(range(4)):
        raise ValueError('频段索引必须唯一且按0..3排列')
    if len({f['token'] for f in bands}) != 4:
        raise ValueError('频率标识重复')
    for f in bands:
        if f['token'] != str(f['hz'] // 1000000) + 'M' or f['hz'] % 1000000:
            raise ValueError('频率标识与Hz不一致')
        if not re.fullmatch('[0-9A-F]{8}', f['word_hex']):
            raise ValueError('频率字必须为8位大写十六进制')
        if int(f['word_hex'], 16) != round(f['hz'] * 2**32 / data['dac_clock_hz']):
            raise ValueError('频率字与时钟不一致')
    if [m['id'] for m in modes] != list(range(20)):
        raise ValueError('模式编号必须唯一且按0..19排列')
    if len(cycle) != 20 or set(cycle) != set(range(20)) or cycle[0] != 0:
        raise ValueError('按键循环必须从0开始且每模式恰好一次')
    if data['phase_word_bits'] != 32 or data['default_amplitude'] != 1024 or data['custom_mode_id'] != 31:
        raise ValueError('本次重构禁止更改现有数据合同')
    for m in modes:
        if not 0 <= m['frequency_index'] < 4 or m['angle_tenths'] not in (0, 300, -300, 600, -600):
            raise ValueError('非法预设频段或角度')
        if not re.fullmatch('[0-9A-F]{8}', m['phase_word_hex']):
            raise ValueError('相位字必须为8位大写十六进制')
    for f in bands:
        if sorted(m['angle_tenths'] for m in modes if m['frequency_index'] == f['index']) != [-600, -300, 0, 300, 600]:
            raise ValueError('每频段必须包含且仅包含五个预设角度')
    return data


def render(data):
    """保留局部case/并行前缀结构，不增加寄存器、流水或运行时共享译码器。"""
    bands, modes, cycle = data['frequencies'], data['modes'], data['key_cycle']
    defaults = data['legacy_invalid_defaults']
    digest = hashlib.sha256(json.dumps(data, sort_keys=True, ensure_ascii=False).encode('utf-8')).hexdigest()
    banner = '// 自动生成：scripts/generate_mode_catalog.py；只修改config/hil_mode_catalog.json。\n// 定义SHA256：' + digest + '\n'
    result = {}

    def emit(name, lines):
        result[name] = banner + '\n'.join(lines) + '\n'

    def ids(items):
        return ','.join("5'd%d" % m['id'] for m in items)

    def grouped(key):
        groups = {}
        for m in modes:
            groups.setdefault(m[key], []).append(m)
        return groups.items()

    def function(name, width, values, default, signed=False):
        text = ['function %s[%s] %s;' % ('signed ' if signed else '', width, name),
                '    input [4:0] index;', '    case(index)']
        text += ['        %s:%s=%s;' % (keys, name, value) for keys, value in values]
        return text + ['        default:%s=%s;' % (name, default), '    endcase', 'endfunction']

    lines = function('freq_word_of', '31:0', [(ids(ms), "32'h" + bands[fi]['word_hex']) for fi, ms in grouped('frequency_index')], "32'h" + bands[defaults['frequency_word_band']]['word_hex'])
    lines += function('phase_word_of', '31:0', [(ids(ms), "32'h" + word) for word, ms in grouped('phase_word_hex')], "32'h" + defaults['phase_word_hex'])
    lines += function('frequency_index_of', '1:0', [(ids(ms), "2'd%d" % fi) for fi, ms in grouped('frequency_index')], "2'd%d" % defaults['active_frequency_index'])
    lines += function('angle_of', '10:0', [(ids(ms), ("-11'sd%d" % -a if a < 0 else "11'sd%d" % a)) for a, ms in grouped('angle_tenths')], "11'sd%d" % defaults['angle_tenths'], signed=True)
    lines += function('next_mode_of', '4:0', [("5'd%d" % i, "5'd%d" % cycle[(n + 1) % 20]) for n, i in enumerate(cycle)], "5'd%d" % defaults['next_mode'])
    emit('mode_select_tables.vh', lines)
    emit('mapper_reset.vh', ["localparam [31:0] HIL_RESET_FREQUENCY_WORD=32'h%s;" % bands[0]['word_hex']])
    emit('mapper_frequency.vh', ['case(held_frequency)'] + ["    2'd%d:frequency_word<=32'h%s;" % (f['index'], f['word_hex']) for f in bands] + ['endcase'])

    prefixes = {}
    for f in bands:
        for sign in ('', '+', '-'):
            token = 'SET ' + f['token'] + ' ' + sign
            prefixes.setdefault(len(token), []).append((token, f['index'], sign == '-'))
    lines = ['case(line_length)']
    for length, entries in sorted(prefixes.items()):
        lines += ['    n+%d:case(line[n*8+:%d])' % (length, length * 8)]
        for token, fi, negative in entries:
            lines += ['        "%s":%s' % (token, ('begin band=%d;negative=1;end' % fi) if negative else ('band=%d;' % fi))]
        lines += ['        default:prefix_ok=0;', '    endcase']
    lines += ['    default:prefix_ok=0;', 'endcase']
    emit('decoder_prefix.vh', lines)
    lines = []
    for m in modes:
        a = m['angle_tenths'] // 10
        angle = '0' if a == 0 else '%+d' % a
        lines += ['"SET %s %s":decoded={2\'d0,5\'d%d};' % (bands[m['frequency_index']]['token'], angle, m['id'])]
    emit('decoder_presets.vh', lines)
    # 预设编号从ASCII后缀直接识别，不串联十进制加法、符号转换及数值比较。
    lines = ['function [4:0] alias_mode_of(input [1:0] band,input negative,input [1:0] kind);',
             '    case({band,negative,kind})']
    for m in modes:
        a = m['angle_tenths']
        kind = {0: 0, 300: 1, 600: 2}[abs(a)]
        for negative in ([0, 1] if a == 0 else [int(a < 0)]):
            key = (m['frequency_index'] << 3) | (negative << 2) | kind
            lines += ["        5'd%d:alias_mode_of=5'd%d;" % (key, m['id'])]
    lines += ["        default:alias_mode_of=5'd0;", '    endcase', 'endfunction']
    # 位号对应数值后缀长度1/2/3/4。合法前缀仍由原并行译码器检查。
    lines += ['wire [3:0] alias_zero={(line[31:0]=="00.0"),(line[23:0]=="0.0"),(line[15:0]=="00"),(line[7:0]=="0")};',
              'wire [3:0] alias_thirty={(line[31:0]=="30.0"),1\'b0,(line[15:0]=="30"),1\'b0};',
              'wire [3:0] alias_sixty={(line[31:0]=="60.0"),1\'b0,(line[15:0]=="60"),1\'b0};']
    emit('decoder_aliases.vh', lines)

    lines = ['case(m)']
    for fi, ms in grouped('frequency_index'):
        lines += ['    %s:f=4\'d%d;' % (ids(ms), bands[fi]['hz'] // 1000000)]
    lines += ["    default:f=4'd%d;" % (bands[defaults['reply_frequency_band']]['hz'] // 1000000), 'endcase', 'case(m)']
    for a, ms in grouped('angle_tenths'):
        lines += ['    %s:begin sign_char="%s";tens="%d";end' % (ids(ms), '-' if a < 0 else '+', abs(a) // 100)]
    lines += ['    default:begin sign_char="+";tens="0";end', 'endcase']
    emit('reply_presets.vh', lines)
    emit('reply_custom_band.vh', ['case(d[22:21])'] + ["    2'd%d:f=4'd%d;" % (f['index'], f['hz'] // 1000000) for f in bands] + ['endcase'])
    # S11绝对值只可能为0..1024。组合真值表替代串联常数除余，保持原周期。
    # 1000..1024的百位仍为10，保留旧格式器对协议外描述符的精确输出。
    lines = ['function [11:0] angle_decimal_digits(input [10:0] value);', '    case(value)']
    for value in range(1025):
        digits = ((value // 100) << 8) | (((value // 10) % 10) << 4) | (value % 10)
        lines += ["        11'd%d:angle_decimal_digits=12'h%03X;" % (value, digits)]
    lines += ["        default:angle_decimal_digits=12'h000;", '    endcase', 'endfunction']
    emit('reply_decimal.vh', lines)
    lines = ['case(mode_index)']
    for fi, ms in grouped('frequency_index'):
        lines += ["    %s:led_frequency=2'd%d;" % (ids(ms), fi)]
    lines += ["    default:led_frequency=2'd%d;" % defaults['led_frequency_index'], 'endcase', 'case(mode_index)']
    for a, ms in grouped('angle_tenths'):
        value = {0: "2'b00", 300: "2'b01", -300: "2'b10", 600: "2'b11", -600: "led_blink ? 2'b11 : 2'b00"}[a]
        lines += ['    %s:led_angle=%s;' % (ids(ms), value)]
    lines += ["    default:led_angle=2'b00;", 'endcase']
    emit('led_tables.vh', lines)
    return result


def verify_rom(data):
    """只读核对任意角度ROM与预设字；绝不自动重写旧ROM。"""
    rom = [int(x, 16) for x in (ROOT / 'config/hil_angle_phase_rom.mem').read_text('ascii').split()]
    if len(rom) != 4096:
        raise ValueError('现有相位参数ROM大小不正确')
    for m in data['modes']:
        a = m['angle_tenths']
        word = rom[m['frequency_index'] * 1024 + abs(a)]
        if a < 0:
            word = (-word) & 0xffffffff
        if word != int(m['phase_word_hex'], 16):
            raise ValueError('预设与现有ROM不一致，禁止自动继续：模式%d' % m['id'])


def check_files(generated, output=OUTPUT):
    return [name for name, text in generated.items() if not (output / name).is_file() or (output / name).read_bytes() != text.encode('utf-8')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='只读验证，不写任何文件')
    args = parser.parse_args()
    data = load_catalog()
    verify_rom(data)
    generated = render(data)
    stale = check_files(generated)
    if args.check:
        if stale:
            raise SystemExit('MODE_CATALOG_STALE: ' + ', '.join(stale))
        print('MODE_CATALOG_CHECK_PASS modes=20 bands=4 headers=%d ROM_UNCHANGED' % len(generated))
    else:
        OUTPUT.mkdir(parents=True, exist_ok=True)
        for name in stale:
            (OUTPUT / name).write_bytes(generated[name].encode('utf-8'))
        print('MODE_CATALOG_GENERATED headers=%d updated=%d' % (len(generated), len(stale)))


if __name__ == '__main__':
    main()
