"""Read Intel AppleSMC fan speeds and hardware maxima; never write SMC keys."""
import ctypes
import json
import math
import struct

u8, u16, u32 = ctypes.c_uint8, ctypes.c_uint16, ctypes.c_uint32


class SMCVersion(ctypes.Structure):
    _fields_ = [('major', u8), ('minor', u8), ('build', u8), ('reserved', u8), ('release', u16)]


class SMCPowerLimit(ctypes.Structure):
    _fields_ = [('version', u16), ('length', u16), ('cpu', u32), ('gpu', u32), ('memory', u32)]


class SMCKeyInfo(ctypes.Structure):
    _fields_ = [('dataSize', u32), ('dataType', u32), ('dataAttributes', u8)]


class SMCKeyData(ctypes.Structure):
    _fields_ = [('key', u32), ('version', SMCVersion), ('powerLimit', SMCPowerLimit),
                ('keyInfo', SMCKeyInfo), ('result', u8), ('status', u8), ('data8', u8),
                ('data32', u32), ('bytes', u8 * 32)]


assert ctypes.sizeof(SMCKeyData) == 80
io = ctypes.CDLL('/System/Library/Frameworks/IOKit.framework/IOKit')
system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
io.IOServiceMatching.argtypes = [ctypes.c_char_p]
io.IOServiceMatching.restype = ctypes.c_void_p
io.IOServiceGetMatchingService.argtypes = [u32, ctypes.c_void_p]
io.IOServiceGetMatchingService.restype = u32
io.IOServiceOpen.argtypes = [u32, u32, u32, ctypes.POINTER(u32)]
io.IOServiceOpen.restype = ctypes.c_int
io.IOServiceClose.argtypes = [u32]
io.IOServiceClose.restype = ctypes.c_int
io.IOObjectRelease.argtypes = [u32]
io.IOObjectRelease.restype = ctypes.c_int
io.IOConnectCallStructMethod.argtypes = [u32, u32, ctypes.c_void_p, ctypes.c_size_t,
                                        ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
io.IOConnectCallStructMethod.restype = ctypes.c_int
service = io.IOServiceGetMatchingService(0, io.IOServiceMatching(b'AppleSMC'))
if not service:
    raise RuntimeError('AppleSMC service unavailable')
connection = u32()
try:
    task = u32.in_dll(system, 'mach_task_self_').value
    code = io.IOServiceOpen(service, task, 0, ctypes.byref(connection))
    if code:
        raise RuntimeError('IOServiceOpen failed: %s' % code)
    try:
        def call(request):
            response = SMCKeyData()
            output_size = ctypes.c_size_t(ctypes.sizeof(response))
            code = io.IOConnectCallStructMethod(connection, 2, ctypes.byref(request), ctypes.sizeof(request),
                                                ctypes.byref(response), ctypes.byref(output_size))
            if code or response.result or output_size.value != ctypes.sizeof(response):
                raise RuntimeError('SMC read failed: IOKit=%s, SMC=%s' % (code, response.result))
            return response

        def read(key):
            request = SMCKeyData()
            request.key = int.from_bytes(key.encode('ascii'), 'big')
            request.data8 = 9  # Read key metadata.
            metadata = call(request)
            size = metadata.keyInfo.dataSize
            if not 0 < size <= 32:
                raise RuntimeError('Invalid SMC data size: %s' % size)
            request = SMCKeyData()
            request.key = int.from_bytes(key.encode('ascii'), 'big')
            request.keyInfo.dataSize = size
            request.data8 = 5  # Read bytes.
            raw = bytes(call(request).bytes[:size])
            data_type = metadata.keyInfo.dataType.to_bytes(4, 'big').decode('ascii')
            if data_type == 'flt ' and size == 4:
                return struct.unpack('<f', raw)[0]
            if data_type == 'fpe2' and size == 2:
                return int.from_bytes(raw, 'big') / 4.0
            if data_type in ('ui8 ', 'ui16', 'ui32'):
                return int.from_bytes(raw, 'big')
            raise RuntimeError('Unsupported SMC type: %s' % data_type)

        def optional_rpm(key, minimum):
            try:
                value = read(key)
                return round(value, 1) if math.isfinite(value) and minimum <= value <= 100000 else None
            except RuntimeError:
                return None

        count = int(read('FNum'))
        if not 0 <= count <= 16:
            raise RuntimeError('Invalid fan count')
        fans = [{'id': str(index), 'name': 'Fan%d' % (index + 1),
                 'rpm': optional_rpm('F%XAc' % index, 0),
                 'maximumRPM': optional_rpm('F%XMx' % index, 1)} for index in range(count)]
        print(json.dumps({'fans': fans}, separators=(',', ':'), allow_nan=False), flush=True)
    finally:
        io.IOServiceClose(connection)
finally:
    io.IOObjectRelease(service)
