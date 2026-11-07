import ctypes
import json
import platform
import socket
import subprocess
import time


def linux_ticks():
    result = {}
    with open('/proc/stat', encoding='utf-8') as stat:
        for line in stat:
            fields = line.split()
            if not fields or not fields[0].startswith('cpu'):
                continue
            label = fields[0]
            if label != 'cpu' and not label[3:].isdigit():
                continue
            values = [int(value) for value in fields[1:9]]
            result[label] = (sum(values), values[3] + (values[4] if len(values) > 4 else 0))
    return result


def mac_ticks():
    lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    uint = ctypes.c_uint32
    pointer = ctypes.POINTER(uint)
    lib.mach_host_self.restype = uint
    lib.host_processor_info.argtypes = [uint, ctypes.c_int, ctypes.POINTER(uint), ctypes.POINTER(pointer), ctypes.POINTER(uint)]
    lib.host_processor_info.restype = ctypes.c_int
    lib.vm_deallocate.argtypes = [uint, ctypes.c_uint64, ctypes.c_uint64]
    lib.vm_deallocate.restype = ctypes.c_int
    lib.mach_port_deallocate.argtypes = [uint, uint]
    lib.mach_port_deallocate.restype = ctypes.c_int
    host = lib.mach_host_self()
    task = uint.in_dll(lib, 'mach_task_self_').value
    cpus, count, info = uint(), uint(), pointer()
    try:
        status = lib.host_processor_info(host, 2, ctypes.byref(cpus), ctypes.byref(info), ctypes.byref(count))
        if status != 0:
            raise RuntimeError('host_processor_info returned %s' % status)
        try:
            result = {}
            for index in range(cpus.value):
                values = [int(info[index * 4 + state]) for state in range(4)]
                result['cpu' + str(index)] = (sum(values), values[2])
            result['cpu'] = (sum(value[0] for value in result.values()), sum(value[1] for value in result.values()))
            return result
        finally:
            lib.vm_deallocate(task, ctypes.cast(info, ctypes.c_void_p).value, count.value * ctypes.sizeof(uint))
    finally:
        lib.mach_port_deallocate(task, host)


system = platform.system()
is_wsl = system == 'Linux' and 'microsoft' in platform.release().lower()
if system not in ('Darwin', 'Linux'):
    raise RuntimeError('Unsupported CPU monitoring platform: ' + system)
reader = mac_ticks if system == 'Darwin' else linux_ticks
before = reader()
time.sleep(0.5)
after = reader()


def usage(label):
    total_delta = after[label][0] - before[label][0]
    idle_delta = after[label][1] - before[label][1]
    if total_delta <= 0:
        raise RuntimeError('CPU counters did not advance: ' + label)
    return round(min(100.0, max(0.0, 100.0 * (total_delta - idle_delta) / total_delta)), 1)


core_labels = sorted((label for label in after if label != 'cpu' and label in before), key=lambda label: int(label[3:]))
if system == 'Darwin':
    cpu_model = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string'], universal_newlines=True).strip()
else:
    cpu_model = ''
    with open('/proc/cpuinfo', encoding='utf-8') as cpu_info:
        for line in cpu_info:
            if line.startswith('model name'):
                cpu_model = line.split(':', 1)[1].strip()
                break
print(json.dumps({'hostname': socket.gethostname(), 'platform': 'WSL' if is_wsl else ('macOS' if system == 'Darwin' else 'Linux'), 'scope': 'WSL' if is_wsl else 'host', 'cpuModel': cpu_model, 'totalUsage': usage('cpu'), 'cores': [{'id': int(label[3:]), 'usage': usage(label)} for label in core_labels]}, separators=(',', ':')), flush=True)
