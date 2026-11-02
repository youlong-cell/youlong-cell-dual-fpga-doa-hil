"""独立校验ELF配置、内存段及BOOT内的完整真实载荷；不操作板卡。"""

from pathlib import Path

import struct

def check(ok,message):
    if not ok:raise RuntimeError(message)

def elf(path):
    b=path.read_bytes();check(b[:4]==b'\x7fELF' and b[4] in [1,2] and b[5]==1,'ELF format')
    wide=b[4]==2;h=struct.unpack_from('<HHIQQQIHHHHHH' if wide else '<HHIIIIIHHHHHH',b,16);segments=[]
    for i in range(h[9]):
        q=struct.unpack_from('<IIQQQQQQ' if wide else '<IIIIIIII',b,h[4]+i*h[8])
        if q[0]!=1:continue
        if wide:_,flags,offset,va,pa,fs,ms,align=q
        else:_,offset,va,pa,fs,ms,flags,align=q
        check(fs<=ms and offset+fs<=len(b),'ELF LOAD range')
        segments.append(dict(offset=offset,paddr=pa,file_bytes=fs,memory_bytes=ms,end=pa+ms,flags=flags))
    check(bool(segments),'No PT_LOAD');return dict(path=str(path),machine=h[1],entry=h[3],LOAD=segments)

def profiles(p):
    """从最终ELF读取四套实际配置；不以JSON或UI字面值代替实际链接数据。"""
    raw = p.read_bytes()
    h = struct.unpack_from('<HHIQQQIHHHHHH', raw, 16)
    sections = [struct.unpack_from('<IIQQQQIIQQ', raw, h[5] + i * h[10]) for i in range(h[11])]
    for section in sections:
        if section[1] != 2:
            continue
        strings = sections[section[6]]
        names = raw[strings[4]:strings[4] + strings[5]]
        for pos in range(section[4], section[4] + section[5], section[9]):
            sym = struct.unpack_from('<IBBHQQ', raw, pos)
            if names[sym[0]:].split(b'\0', 1)[0] != b'embedded_hil_profiles':
                continue
            check(sym[5] == 704, '校准表结构或长度意外变化')
            owner = sections[sym[3]]
            offset = owner[4] + sym[4] - owner[3]
            result = []
            for i in range(4):
                base = offset + 176 * i
                values = struct.unpack_from('<7I', raw, base)
                bias, geometry_a = struct.unpack_from('<qQ', raw, base + 72)
                cal = list(struct.unpack_from('<10I', raw, base + 88))
                geometry = list(struct.unpack_from('<5I', raw, base + 128))
                hz = struct.unpack_from('<3I', raw, base + 148)
                check(cal[2] | cal[3] << 32 == bias % (1 << 64), '偏置编码不一致')
                check(cal[8] == values[1] and geometry[4] == values[0], '配置身份不一致')
                result.append(dict(geometry_id=values[0], profile_id=values[1], d_mm=values[2],
                                   c_mps=values[3], geometry_valid=values[4], calibration_valid=values[5],
                                   measured=values[6], bias_pi_F35=bias, bias_deg=bias * 180 / 2**35,
                                   geometry_a_F24=geometry_a, calibration_words=cal, geometry_words=geometry,
                                   reference_hz=hz[0], min_hz=hz[1], max_hz=hz[2]))
            return result
    raise RuntimeError('未找到真实链接校准表')

def verify_boot(image, paths):
    """独立读取启动分区并逐字节对比实际ELF和完整PL载荷。"""
    values = {name: elf(path) for name, path in paths.items() if name != 'bit'}
    check(values['fsbl']['machine'] == 183 and values['fsbl']['entry'] == 0xfffc0000, 'FSBL入口')
    pmu = values['pmufw']
    check(pmu['machine'] == 189, 'PMU处理器')
    check(min(s['paddr'] for s in pmu['LOAD']) == 0xffdc0000 and max(s['end'] for s in pmu['LOAD']) <= 0xffde0000, 'PMU内存')
    check(any(s['paddr'] <= pmu['entry'] < s['paddr'] + s['file_bytes'] and s['flags'] & 1 for s in pmu['LOAD']), 'PMU可执行入口')
    reset = next(s for s in pmu['LOAD'] if s['paddr'] == 0xffdc0000)
    hi, lo = struct.unpack_from('<II', paths['pmufw'].read_bytes(), reset['offset'])
    check(hi & 0xffff0000 == 0xb0000000 and lo & 0xffff0000 == 0xb8080000, 'PMU复位指令')
    check(((hi & 0xffff) << 16 | (lo & 0xffff)) == pmu['entry'], 'PMU复位跳转')
    app = values['app']
    check(app['machine'] == 183 and app['entry'] == 0x01000000, 'A53入口')
    intervals = [(name, s) for name, value in values.items() for s in value['LOAD'] if s['memory_bytes']]
    for i, (name, s) in enumerate(intervals):
        if name == 'app':
            check(0x01000000 <= s['paddr'] < s['end'] <= 0x3ff00000, 'DDR与保留区冲突')
        for other, t in intervals[i + 1:]:
            check(s['end'] <= t['paddr'] or t['end'] <= s['paddr'], 'ELF内存重叠: ' + name + '/' + other)
    data = image.read_bytes()
    u32 = lambda at: struct.unpack_from('<I', data, at)[0]
    check(u32(0x20) == 0xaa995566 and u32(0x24) == 0x584c4e58, 'BOOT头')
    check(sum(struct.unpack_from('<11I', data, 0x20)) & 0xffffffff == 0xffffffff, 'BOOT校验和')
    check(sum(struct.unpack_from('<16I', data, u32(0x98))) & 0xffffffff == 0xffffffff, '分区表校验和')
    specs = [('fsbl', 0x117, 0xfffc0000, 0xfffc0000), ('PL', 0x26, 0, 0xffffffff)]
    specs += [('app.' + str(i), 0x117, app['entry'] if i == 0 else 0, s['paddr']) for i, s in enumerate(app['LOAD'])]
    at = u32(0x9c)
    headers = []
    for name, attr, entry, address in specs:
        w = struct.unpack_from('<16I', data, at)
        check(sum(w) & 0xffffffff == 0xffffffff, '分区头校验和: ' + name)
        check((w[4] | w[5] << 32, w[6] | w[7] << 32, w[9]) == (entry, address, attr), '分区目标: ' + name)
        check(w[0] == w[1] == w[2], '意外加密或压缩: ' + name)
        start, size = w[8] * 4, w[2] * 4
        check(start + size <= len(data), '分区边界')
        headers.append(dict(name=name, entry=entry, load=address, attributes=attr, offset=start, bytes=size))
        at = w[3] * 4
    check(at == 0 and u32(u32(0x98) + 4) == len(specs), '额外或缺失分区')
    check(headers[0]['offset'] == u32(0x30) and headers[0]['bytes'] == u32(0x34) + u32(0x3c), '启动组件长度')
    for name, base, start in [('pmufw', 0xffdc0000, headers[0]['offset']),
                              ('fsbl', 0xfffc0000, headers[0]['offset'] + u32(0x34))]:
        raw = paths[name].read_bytes()
        for s in values[name]['LOAD']:
            pos, size = start + s['paddr'] - base, s['file_bytes']
            check(data[pos:pos + size] == raw[s['offset']:s['offset'] + size], '启动ELF载荷: ' + name)
    raw = paths['app'].read_bytes()
    for i, s in enumerate(app['LOAD']):
        h, size = headers[i + 2], s['file_bytes']
        check(h['bytes'] == (size + 3) // 4 * 4, '应用分区大小')
        check(data[h['offset']:h['offset'] + size] == raw[s['offset']:s['offset'] + size], '应用ELF载荷')
    raw = paths['bit'].read_bytes()
    p = 2 + int.from_bytes(raw[:2], 'big')
    check(raw[p:p + 2] == b'\0\1', 'bit头')
    p += 2
    fields, payload = {}, None
    while p < len(raw):
        tag = chr(raw[p]); p += 1
        if tag == 'e':
            size = int.from_bytes(raw[p:p + 4], 'big'); p += 4
            payload = raw[p:p + size]
            check(p + size == len(raw), 'bit边界')
            break
        size = int.from_bytes(raw[p:p + 2], 'big'); p += 2
        fields[tag] = raw[p:p + size].rstrip(b'\0').decode(); p += size
    check(fields['b'] == 'xczu2cg-sfvc784-1-i' and 'Version=2023.1' in fields['a'], '器件或工具版本')
    pl = headers[1]
    check(payload is not None and len(payload) == pl['bytes'] and len(payload) % 4 == 0, '完整PL长度')
    check(data[pl['offset']:pl['offset'] + pl['bytes']] == b''.join(payload[i:i + 4][::-1] for i in range(0, len(payload), 4)), 'PL逐字节载荷')
    return dict(ELFs=values, partitions=headers, bit_header=fields, complete_PL_payload_verified=True,
                all_ELF_payloads_byte_identical=True, reserved_PL_scratch=[0x100000, 0x5dfcf4])
