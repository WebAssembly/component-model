# After the Boilerplate section, this file is ordered to line up with the code
# blocks in ../CanonicalABI.md (split by # comment lines). If you update this
# file, don't forget to update ../CanonicalABI.md.

### Boilerplate

import math
import struct
from dataclasses import dataclass
import typing
from typing import Optional
from typing import Callable

class Trap(BaseException): pass
class CoreWebAssemblyException(BaseException): pass

def trap():
  raise Trap()

def trap_if(cond):
  if cond:
    raise Trap()

class Type: pass
class ValType(Type): pass
class ExternType(Type): pass
class CoreExternType(Type): pass

@dataclass
class CoreImportDecl:
  module: str
  field: str
  t: CoreExternType

@dataclass
class CoreExportDecl:
  name: str
  t: CoreExternType

@dataclass
class ModuleType(ExternType):
  imports: [CoreImportDecl]
  exports: [CoreExportDecl]

@dataclass
class CoreFuncType(CoreExternType):
  params: [str]
  results: [str]

@dataclass
class CoreMemoryType(CoreExternType):
  initial: [int]
  maximum: Optional[int]

@dataclass
class ExternDecl:
  name: str
  t: ExternType

@dataclass
class ComponentType(ExternType):
  imports: [ExternDecl]
  exports: [ExternDecl]

@dataclass
class InstanceType(ExternType):
  exports: [ExternDecl]

@dataclass
class FuncType(ExternType):
  params: [ValType|typing.Tuple[str,ValType]]
  results: [ValType|typing.Tuple[str,ValType]]
  def param_types(self):
    return self.extract_types(self.params)
  def result_types(self):
    return self.extract_types(self.results)
  def extract_types(self, vec):
    if len(vec) == 0:
      return []
    if isinstance(vec[0], ValType):
      return vec
    return [t for name,t in vec]

@dataclass
class ValueType(ExternType):
  t: ValType

class Bounds: pass

@dataclass
class Eq(Bounds):
  t: Type

@dataclass
class TypeType(ExternType):
  bounds: Bounds

class Bool(ValType): pass
class S8(ValType): pass
class U8(ValType): pass
class S16(ValType): pass
class U16(ValType): pass
class S32(ValType): pass
class U32(ValType): pass
class S64(ValType): pass
class U64(ValType): pass
class Float32(ValType): pass
class Float64(ValType): pass
class Char(ValType): pass
class String(ValType): pass

@dataclass
class List(ValType):
  t: ValType

@dataclass
class Field:
  label: str
  t: ValType

@dataclass
class Record(ValType):
  fields: [Field]

@dataclass
class Tuple(ValType):
  ts: [ValType]

@dataclass
class Flags(ValType):
  labels: [str]

@dataclass
class Case:
  label: str
  t: Optional[ValType]
  refines: str = None

@dataclass
class Variant(ValType):
  cases: [Case]

@dataclass
class Enum(ValType):
  labels: [str]

@dataclass
class Union(ValType):
  ts: [ValType]

@dataclass
class Option(ValType):
  t: ValType

@dataclass
class Result(ValType):
  ok: Optional[ValType]
  error: Optional[ValType]

### Despecialization

def despecialize(t):
  match t:
    case Tuple(ts)         : return Record([ Field(str(i), t) for i,t in enumerate(ts) ])
    case Union(ts)         : return Variant([ Case(str(i), t) for i,t in enumerate(ts) ])
    case Enum(labels)      : return Variant([ Case(l, None) for l in labels ])
    case Option(t)         : return Variant([ Case("none", None), Case("some", t) ])
    case Result(ok, error) : return Variant([ Case("ok", ok), Case("error", error) ])
    case _                 : return t

### Alignment

def alignment(t):
  match despecialize(t):
    case Bool()             : return 1
    case S8() | U8()        : return 1
    case S16() | U16()      : return 2
    case S32() | U32()      : return 4
    case S64() | U64()      : return 8
    case Float32()          : return 4
    case Float64()          : return 8
    case Char()             : return 4
    case String() | List(_) : return 4
    case Record(fields)     : return alignment_record(fields)
    case Variant(cases)     : return alignment_variant(cases)
    case Flags(labels)      : return alignment_flags(labels)

#

def alignment_record(fields):
  a = 1
  for f in fields:
    a = max(a, alignment(f.t))
  return a

#

def alignment_variant(cases):
  return max(alignment(discriminant_type(cases)), max_case_alignment(cases))

def discriminant_type(cases):
  n = len(cases)
  assert(0 < n < (1 << 32))
  match math.ceil(math.log2(n)/8):
    case 0: return U8()
    case 1: return U8()
    case 2: return U16()
    case 3: return U32()

def max_case_alignment(cases):
  a = 1
  for c in cases:
    if c.t is not None:
      a = max(a, alignment(c.t))
  return a

#

def alignment_flags(labels):
  n = len(labels)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4

### Size

def size(t):
  match despecialize(t):
    case Bool()             : return 1
    case S8() | U8()        : return 1
    case S16() | U16()      : return 2
    case S32() | U32()      : return 4
    case S64() | U64()      : return 8
    case Float32()          : return 4
    case Float64()          : return 8
    case Char()             : return 4
    case String() | List(_) : return 8
    case Record(fields)     : return size_record(fields)
    case Variant(cases)     : return size_variant(cases)
    case Flags(labels)      : return size_flags(labels)

def size_record(fields):
  s = 0
  for f in fields:
    s = align_to(s, alignment(f.t))
    s += size(f.t)
  return align_to(s, alignment_record(fields))

def align_to(ptr, alignment):
  return math.ceil(ptr / alignment) * alignment

def size_variant(cases):
  s = size(discriminant_type(cases))
  s = align_to(s, max_case_alignment(cases))
  cs = 0
  for c in cases:
    if c.t is not None:
      cs = max(cs, size(c.t))
  s += cs
  return align_to(s, alignment_variant(cases))

def size_flags(labels):
  n = len(labels)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4 * num_i32_flags(labels)

def num_i32_flags(labels):
  return math.ceil(len(labels) / 32)

### Loading

class Opts:
  string_encoding: str
  memory: bytearray
  realloc: Callable[[int,int,int,int],int]
  post_return: Callable[[],None]

def load(opts, ptr, t):
  assert(ptr == align_to(ptr, alignment(t)))
  match despecialize(t):
    case Bool()         : return convert_int_to_bool(load_int(opts, ptr, 1))
    case U8()           : return load_int(opts, ptr, 1)
    case U16()          : return load_int(opts, ptr, 2)
    case U32()          : return load_int(opts, ptr, 4)
    case U64()          : return load_int(opts, ptr, 8)
    case S8()           : return load_int(opts, ptr, 1, signed=True)
    case S16()          : return load_int(opts, ptr, 2, signed=True)
    case S32()          : return load_int(opts, ptr, 4, signed=True)
    case S64()          : return load_int(opts, ptr, 8, signed=True)
    case Float32()      : return canonicalize32(reinterpret_i32_as_float(load_int(opts, ptr, 4)))
    case Float64()      : return canonicalize64(reinterpret_i64_as_float(load_int(opts, ptr, 8)))
    case Char()         : return i32_to_char(opts, load_int(opts, ptr, 4))
    case String()       : return load_string(opts, ptr)
    case List(t)        : return load_list(opts, ptr, t)
    case Record(fields) : return load_record(opts, ptr, fields)
    case Variant(cases) : return load_variant(opts, ptr, cases)
    case Flags(labels)  : return load_flags(opts, ptr, labels)

#

def load_int(opts, ptr, nbytes, signed = False):
  trap_if(ptr + nbytes > len(opts.memory))
  return int.from_bytes(opts.memory[ptr : ptr+nbytes], 'little', signed=signed)

#

def convert_int_to_bool(i):
  assert(i >= 0)
  return bool(i)

#

def reinterpret_i32_as_float(i):
  return struct.unpack('!f', struct.pack('!I', i))[0] # f32.reinterpret_i32

def reinterpret_i64_as_float(i):
  return struct.unpack('!d', struct.pack('!Q', i))[0] # f64.reinterpret_i64

CANONICAL_FLOAT32_NAN = 0x7fc00000
CANONICAL_FLOAT64_NAN = 0x7ff8000000000000

def canonicalize32(f):
  if math.isnan(f):
    return reinterpret_i32_as_float(CANONICAL_FLOAT32_NAN)
  return f

def canonicalize64(f):
  if math.isnan(f):
    return reinterpret_i64_as_float(CANONICAL_FLOAT64_NAN)
  return f

#

def i32_to_char(opts, i):
  trap_if(i >= 0x110000)
  trap_if(0xD800 <= i <= 0xDFFF)
  return chr(i)

#

def load_string(opts, ptr):
  begin = load_int(opts, ptr, 4)
  tagged_code_units = load_int(opts, ptr + 4, 4)
  return load_string_from_range(opts, begin, tagged_code_units)

UTF16_TAG = 1 << 31

def load_string_from_range(opts, ptr, tagged_code_units):
  match opts.string_encoding:
    case 'utf8':
      byte_length = tagged_code_units
      encoding = 'utf-8'
    case 'utf16':
      byte_length = 2 * tagged_code_units
      encoding = 'utf-16-le'
    case 'latin1+utf16':
      if bool(tagged_code_units & UTF16_TAG):
        byte_length = 2 * (tagged_code_units ^ UTF16_TAG)
        encoding = 'utf-16-le'
      else:
        byte_length = tagged_code_units
        encoding = 'latin-1'

  trap_if(ptr + byte_length > len(opts.memory))
  try:
    s = opts.memory[ptr : ptr+byte_length].decode(encoding)
  except UnicodeError:
    trap()

  return (s, opts.string_encoding, tagged_code_units)

#

def load_list(opts, ptr, elem_type):
  begin = load_int(opts, ptr, 4)
  length = load_int(opts, ptr + 4, 4)
  return load_list_from_range(opts, begin, length, elem_type)

def load_list_from_range(opts, ptr, length, elem_type):
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + length * size(elem_type) > len(opts.memory))
  a = []
  for i in range(length):
    a.append(load(opts, ptr + i * size(elem_type), elem_type))
  return a

def load_record(opts, ptr, fields):
  record = {}
  for field in fields:
    ptr = align_to(ptr, alignment(field.t))
    record[field.label] = load(opts, ptr, field.t)
    ptr += size(field.t)
  return record

#

def load_variant(opts, ptr, cases):
  disc_size = size(discriminant_type(cases))
  case_index = load_int(opts, ptr, disc_size)
  ptr += disc_size
  trap_if(case_index >= len(cases))
  c = cases[case_index]
  ptr = align_to(ptr, max_case_alignment(cases))
  case_label = case_label_with_refinements(c, cases)
  if c.t is None:
    return { case_label: None }
  return { case_label: load(opts, ptr, c.t) }

def case_label_with_refinements(c, cases):
  label = c.label
  while c.refines is not None:
    c = cases[find_case(c.refines, cases)]
    label += '|' + c.label
  return label

def find_case(label, cases):
  matches = [i for i,c in enumerate(cases) if c.label == label]
  assert(len(matches) <= 1)
  if len(matches) == 1:
    return matches[0]
  return -1

#

def load_flags(opts, ptr, labels):
  i = load_int(opts, ptr, size_flags(labels))
  return unpack_flags_from_int(i, labels)

def unpack_flags_from_int(i, labels):
  record = {}
  for l in labels:
    record[l] = bool(i & 1)
    i >>= 1
  return record

### Storing

def store(opts, v, t, ptr):
  assert(ptr == align_to(ptr, alignment(t)))
  match despecialize(t):
    case Bool()         : store_int(opts, int(bool(v)), ptr, 1)
    case U8()           : store_int(opts, v, ptr, 1)
    case U16()          : store_int(opts, v, ptr, 2)
    case U32()          : store_int(opts, v, ptr, 4)
    case U64()          : store_int(opts, v, ptr, 8)
    case S8()           : store_int(opts, v, ptr, 1, signed=True)
    case S16()          : store_int(opts, v, ptr, 2, signed=True)
    case S32()          : store_int(opts, v, ptr, 4, signed=True)
    case S64()          : store_int(opts, v, ptr, 8, signed=True)
    case Float32()      : store_int(opts, reinterpret_float_as_i32(canonicalize32(v)), ptr, 4)
    case Float64()      : store_int(opts, reinterpret_float_as_i64(canonicalize64(v)), ptr, 8)
    case Char()         : store_int(opts, char_to_i32(v), ptr, 4)
    case String()       : store_string(opts, v, ptr)
    case List(t)        : store_list(opts, v, ptr, t)
    case Record(fields) : store_record(opts, v, ptr, fields)
    case Variant(cases) : store_variant(opts, v, ptr, cases)
    case Flags(labels)  : store_flags(opts, v, ptr, labels)

#

def store_int(opts, v, ptr, nbytes, signed = False):
  trap_if(ptr + nbytes > len(opts.memory))
  opts.memory[ptr : ptr+nbytes] = int.to_bytes(v, nbytes, 'little', signed=signed)

#

def reinterpret_float_as_i32(f):
  return struct.unpack('!I', struct.pack('!f', f))[0] # i32.reinterpret_f32

def reinterpret_float_as_i64(f):
  return struct.unpack('!Q', struct.pack('!d', f))[0] # i64.reinterpret_f64

#

def char_to_i32(c):
  i = ord(c)
  assert(0 <= i <= 0xD7FF or 0xD800 <= i <= 0x10FFFF)
  return i

#

def store_string(opts, v, ptr):
  begin, tagged_code_units = store_string_into_range(opts, v)
  store_int(opts, begin, ptr, 4)
  store_int(opts, tagged_code_units, ptr + 4, 4)

def store_string_into_range(opts, v):
  src, src_encoding, src_tagged_code_units = v

  if src_encoding == 'latin1+utf16':
    if bool(src_tagged_code_units & UTF16_TAG):
      src_simple_encoding = 'utf16'
      src_code_units = src_tagged_code_units ^ UTF16_TAG
    else:
      src_simple_encoding = 'latin1'
      src_code_units = src_tagged_code_units
  else:
    src_simple_encoding = src_encoding
    src_code_units = src_tagged_code_units

  match opts.string_encoding:
    case 'utf8':
      match src_simple_encoding:
        case 'utf8'         : return store_string_copy(opts, src, src_code_units, 1, 1, 'utf-8')
        case 'utf16'        : return store_utf16_to_utf8(opts, src, src_code_units)
        case 'latin1'       : return store_latin1_to_utf8(opts, src, src_code_units)
    case 'utf16':
      match src_simple_encoding:
        case 'utf8'         : return store_utf8_to_utf16(opts, src, src_code_units)
        case 'utf16'        : return store_string_copy(opts, src, src_code_units, 2, 2, 'utf-16-le')
        case 'latin1'       : return store_string_copy(opts, src, src_code_units, 2, 2, 'utf-16-le')
    case 'latin1+utf16':
      match src_encoding:
        case 'utf8'         : return store_string_to_latin1_or_utf16(opts, src, src_code_units)
        case 'utf16'        : return store_string_to_latin1_or_utf16(opts, src, src_code_units)
        case 'latin1+utf16' :
          match src_simple_encoding:
            case 'latin1'   : return store_string_copy(opts, src, src_code_units, 1, 2, 'latin-1')
            case 'utf16'    : return store_probably_utf16_to_latin1_or_utf16(opts, src, src_code_units)

#

MAX_STRING_BYTE_LENGTH = (1 << 31) - 1

def store_string_copy(opts, src, src_code_units, dst_code_unit_size, dst_alignment, dst_encoding):
  dst_byte_length = dst_code_unit_size * src_code_units
  trap_if(dst_byte_length > MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, dst_alignment, dst_byte_length)
  encoded = src.encode(dst_encoding)
  assert(dst_byte_length == len(encoded))
  opts.memory[ptr : ptr+len(encoded)] = encoded
  return (ptr, src_code_units)

#

def store_utf16_to_utf8(opts, src, src_code_units):
  worst_case_size = src_code_units * 3
  return store_string_to_utf8(opts, src, src_code_units, worst_case_size)

def store_latin1_to_utf8(opts, src, src_code_units):
  worst_case_size = src_code_units * 2
  return store_string_to_utf8(opts, src, src_code_units, worst_case_size)

def store_string_to_utf8(opts, src, src_code_units, worst_case_size):
  assert(src_code_units <= MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, 1, src_code_units)
  encoded = src.encode('utf-8')
  assert(src_code_units <= len(encoded))
  opts.memory[ptr : ptr+src_code_units] = encoded[0 : src_code_units]
  if src_code_units < len(encoded):
    trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
    ptr = opts.realloc(ptr, src_code_units, 1, worst_case_size)
    opts.memory[ptr+src_code_units : ptr+len(encoded)] = encoded[src_code_units : ]
    if worst_case_size > len(encoded):
      ptr = opts.realloc(ptr, worst_case_size, 1, len(encoded))
  return (ptr, len(encoded))

#

def store_utf8_to_utf16(opts, src, src_code_units):
  worst_case_size = 2 * src_code_units
  trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, 2, worst_case_size)
  encoded = src.encode('utf-16-le')
  opts.memory[ptr : ptr+len(encoded)] = encoded
  if len(encoded) < worst_case_size:
    ptr = opts.realloc(ptr, worst_case_size, 2, len(encoded))
  code_units = int(len(encoded) / 2)
  return (ptr, code_units)

#

def store_string_to_latin1_or_utf16(opts, src, src_code_units):
  assert(src_code_units <= MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, 2, src_code_units)
  dst_byte_length = 0
  for usv in src:
    if ord(usv) < (1 << 8):
      opts.memory[ptr + dst_byte_length] = ord(usv)
      dst_byte_length += 1
    else:
      worst_case_size = 2 * src_code_units
      trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
      ptr = opts.realloc(ptr, src_code_units, 2, worst_case_size)
      for j in range(dst_byte_length-1, -1, -1):
        opts.memory[ptr + 2*j] = opts.memory[ptr + j]
        opts.memory[ptr + 2*j + 1] = 0
      encoded = src.encode('utf-16-le')
      opts.memory[ptr+2*dst_byte_length : ptr+len(encoded)] = encoded[2*dst_byte_length : ]
      if worst_case_size > len(encoded):
        ptr = opts.realloc(ptr, worst_case_size, 2, len(encoded))
      tagged_code_units = int(len(encoded) / 2) | UTF16_TAG
      return (ptr, tagged_code_units)
  if dst_byte_length < src_code_units:
    ptr = opts.realloc(ptr, src_code_units, 2, dst_byte_length)
  return (ptr, dst_byte_length)

#

def store_probably_utf16_to_latin1_or_utf16(opts, src, src_code_units):
  src_byte_length = 2 * src_code_units
  trap_if(src_byte_length > MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, 2, src_byte_length)
  encoded = src.encode('utf-16-le')
  opts.memory[ptr : ptr+len(encoded)] = encoded
  if any(ord(c) >= (1 << 8) for c in src):
    tagged_code_units = int(len(encoded) / 2) | UTF16_TAG
    return (ptr, tagged_code_units)
  latin1_size = int(len(encoded) / 2)
  for i in range(latin1_size):
    opts.memory[ptr + i] = opts.memory[ptr + 2*i]
  ptr = opts.realloc(ptr, src_byte_length, 1, latin1_size)
  return (ptr, latin1_size)

#

def store_list(opts, v, ptr, elem_type):
  begin, length = store_list_into_range(opts, v, elem_type)
  store_int(opts, begin, ptr, 4)
  store_int(opts, length, ptr + 4, 4)

def store_list_into_range(opts, v, elem_type):
  byte_length = len(v) * size(elem_type)
  trap_if(byte_length >= (1 << 32))
  ptr = opts.realloc(0, 0, alignment(elem_type), byte_length)
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + byte_length > len(opts.memory))
  for i,e in enumerate(v):
    store(opts, e, elem_type, ptr + i * size(elem_type))
  return (ptr, len(v))

def store_record(opts, v, ptr, fields):
  for f in fields:
    ptr = align_to(ptr, alignment(f.t))
    store(opts, v[f.label], f.t, ptr)
    ptr += size(f.t)

#

def store_variant(opts, v, ptr, cases):
  case_index, case_value = match_case(v, cases)
  disc_size = size(discriminant_type(cases))
  store_int(opts, case_index, ptr, disc_size)
  ptr += disc_size
  ptr = align_to(ptr, max_case_alignment(cases))
  c = cases[case_index]
  if c.t is not None:
    store(opts, case_value, c.t, ptr)

def match_case(v, cases):
  assert(len(v.keys()) == 1)
  key = list(v.keys())[0]
  value = list(v.values())[0]
  for label in key.split('|'):
    case_index = find_case(label, cases)
    if case_index != -1:
      return (case_index, value)

#

def store_flags(opts, v, ptr, labels):
  i = pack_flags_into_int(v, labels)
  store_int(opts, i, ptr, size_flags(labels))

def pack_flags_into_int(v, labels):
  i = 0
  shift = 0
  for l in labels:
    i |= (int(bool(v[l])) << shift)
    shift += 1
  return i

### Flattening

MAX_FLAT_PARAMS = 16
MAX_FLAT_RESULTS = 1

def flatten_functype(ft, context):
  flat_params = flatten_types(ft.param_types())
  if len(flat_params) > MAX_FLAT_PARAMS:
    flat_params = ['i32']

  flat_results = flatten_types(ft.result_types())
  if len(flat_results) > MAX_FLAT_RESULTS:
    match context:
      case 'lift':
        flat_results = ['i32']
      case 'lower':
        flat_params += ['i32']
        flat_results = []

  return CoreFuncType(flat_params, flat_results)

def flatten_types(ts):
  return [ft for t in ts for ft in flatten_type(t)]

#

def flatten_type(t):
  match despecialize(t):
    case Bool()               : return ['i32']
    case U8() | U16() | U32() : return ['i32']
    case S8() | S16() | S32() : return ['i32']
    case S64() | U64()        : return ['i64']
    case Float32()            : return ['f32']
    case Float64()            : return ['f64']
    case Char()               : return ['i32']
    case String() | List(_)   : return ['i32', 'i32']
    case Record(fields)       : return flatten_record(fields)
    case Variant(cases)       : return flatten_variant(cases)
    case Flags(labels)        : return ['i32'] * num_i32_flags(labels)

#

def flatten_record(fields):
  flat = []
  for f in fields:
    flat += flatten_type(f.t)
  return flat

#

def flatten_variant(cases):
  flat = []
  for c in cases:
    if c.t is not None:
      for i,ft in enumerate(flatten_type(c.t)):
        if i < len(flat):
          flat[i] = join(flat[i], ft)
        else:
          flat.append(ft)
  return flatten_type(discriminant_type(cases)) + flat

def join(a, b):
  if a == b: return a
  if (a == 'i32' and b == 'f32') or (a == 'f32' and b == 'i32'): return 'i32'
  return 'i64'

### Flat Lifting

@dataclass
class Value:
  t: str # 'i32'|'i64'|'f32'|'f64'
  v: int|float

@dataclass
class ValueIter:
  values: [Value]
  i = 0
  def next(self, t):
    v = self.values[self.i]
    self.i += 1
    assert(v.t == t)
    return v.v

def lift_flat(opts, vi, t):
  match despecialize(t):
    case Bool()         : return convert_int_to_bool(vi.next('i32'))
    case U8()           : return lift_flat_unsigned(vi, 32, 8)
    case U16()          : return lift_flat_unsigned(vi, 32, 16)
    case U32()          : return lift_flat_unsigned(vi, 32, 32)
    case U64()          : return lift_flat_unsigned(vi, 64, 64)
    case S8()           : return lift_flat_signed(vi, 32, 8)
    case S16()          : return lift_flat_signed(vi, 32, 16)
    case S32()          : return lift_flat_signed(vi, 32, 32)
    case S64()          : return lift_flat_signed(vi, 64, 64)
    case Float32()      : return canonicalize32(vi.next('f32'))
    case Float64()      : return canonicalize64(vi.next('f64'))
    case Char()         : return i32_to_char(opts, vi.next('i32'))
    case String()       : return lift_flat_string(opts, vi)
    case List(t)        : return lift_flat_list(opts, vi, t)
    case Record(fields) : return lift_flat_record(opts, vi, fields)
    case Variant(cases) : return lift_flat_variant(opts, vi, cases)
    case Flags(labels)  : return lift_flat_flags(vi, labels)

#

def lift_flat_unsigned(vi, core_width, t_width):
  i = vi.next('i' + str(core_width))
  assert(0 <= i < (1 << core_width))
  return i % (1 << t_width)

def lift_flat_signed(vi, core_width, t_width):
  i = vi.next('i' + str(core_width))
  assert(0 <= i < (1 << core_width))
  i %= (1 << t_width)
  if i >= (1 << (t_width - 1)):
    return i - (1 << t_width)
  return i

#

def lift_flat_string(opts, vi):
  ptr = vi.next('i32')
  packed_length = vi.next('i32')
  return load_string_from_range(opts, ptr, packed_length)

def lift_flat_list(opts, vi, elem_type):
  ptr = vi.next('i32')
  length = vi.next('i32')
  return load_list_from_range(opts, ptr, length, elem_type)

#

def lift_flat_record(opts, vi, fields):
  record = {}
  for f in fields:
    record[f.label] = lift_flat(opts, vi, f.t)
  return record

#

def lift_flat_variant(opts, vi, cases):
  flat_types = flatten_variant(cases)
  assert(flat_types.pop(0) == 'i32')
  case_index = vi.next('i32')
  trap_if(case_index >= len(cases))
  class CoerceValueIter:
    def next(self, want):
      have = flat_types.pop(0)
      x = vi.next(have)
      match (have, want):
        case ('i32', 'f32') : return reinterpret_i32_as_float(x)
        case ('i64', 'i32') : return wrap_i64_to_i32(x)
        case ('i64', 'f32') : return reinterpret_i32_as_float(wrap_i64_to_i32(x))
        case ('i64', 'f64') : return reinterpret_i64_as_float(x)
        case _              : return x
  c = cases[case_index]
  if c.t is None:
    v = None
  else:
    v = lift_flat(opts, CoerceValueIter(), c.t)
  for have in flat_types:
    _ = vi.next(have)
  return { case_label_with_refinements(c, cases): v }

def wrap_i64_to_i32(i):
  assert(0 <= i < (1 << 64))
  return i % (1 << 32)

#

def lift_flat_flags(vi, labels):
  i = 0
  shift = 0
  for _ in range(num_i32_flags(labels)):
    i |= (vi.next('i32') << shift)
    shift += 32
  return unpack_flags_from_int(i, labels)

### Flat Lowering

def lower_flat(opts, v, t):
  match despecialize(t):
    case Bool()         : return [Value('i32', int(v))]
    case U8()           : return [Value('i32', v)]
    case U16()          : return [Value('i32', v)]
    case U32()          : return [Value('i32', v)]
    case U64()          : return [Value('i64', v)]
    case S8()           : return lower_flat_signed(v, 32)
    case S16()          : return lower_flat_signed(v, 32)
    case S32()          : return lower_flat_signed(v, 32)
    case S64()          : return lower_flat_signed(v, 64)
    case Float32()      : return [Value('f32', canonicalize32(v))]
    case Float64()      : return [Value('f64', canonicalize64(v))]
    case Char()         : return [Value('i32', char_to_i32(v))]
    case String()       : return lower_flat_string(opts, v)
    case List(t)        : return lower_flat_list(opts, v, t)
    case Record(fields) : return lower_flat_record(opts, v, fields)
    case Variant(cases) : return lower_flat_variant(opts, v, cases)
    case Flags(labels)  : return lower_flat_flags(v, labels)

#

def lower_flat_signed(i, core_bits):
  if i < 0:
    i += (1 << core_bits)
  return [Value('i' + str(core_bits), i)]

#

def lower_flat_string(opts, v):
  ptr, packed_length = store_string_into_range(opts, v)
  return [Value('i32', ptr), Value('i32', packed_length)]

def lower_flat_list(opts, v, elem_type):
  (ptr, length) = store_list_into_range(opts, v, elem_type)
  return [Value('i32', ptr), Value('i32', length)]

#

def lower_flat_record(opts, v, fields):
  flat = []
  for f in fields:
    flat += lower_flat(opts, v[f.label], f.t)
  return flat

#

def lower_flat_variant(opts, v, cases):
  case_index, case_value = match_case(v, cases)
  flat_types = flatten_variant(cases)
  assert(flat_types.pop(0) == 'i32')
  c = cases[case_index]
  if c.t is None:
    payload = []
  else:
    payload = lower_flat(opts, case_value, c.t)
  for i,have in enumerate(payload):
    want = flat_types.pop(0)
    match (have.t, want):
      case ('f32', 'i32') : payload[i] = Value('i32', reinterpret_float_as_i32(have.v))
      case ('i32', 'i64') : payload[i] = Value('i64', have.v)
      case ('f32', 'i64') : payload[i] = Value('i64', reinterpret_float_as_i32(have.v))
      case ('f64', 'i64') : payload[i] = Value('i64', reinterpret_float_as_i64(have.v))
      case _              : pass
  for want in flat_types:
    payload.append(Value(want, 0))
  return [Value('i32', case_index)] + payload

#

def lower_flat_flags(v, labels):
  i = pack_flags_into_int(v, labels)
  flat = []
  for _ in range(num_i32_flags(labels)):
    flat.append(Value('i32', i & 0xffffffff))
    i >>= 32
  assert(i == 0)
  return flat

### Lifting and Lowering Values

def lift_values(opts, max_flat, vi, ts):
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    ptr = vi.next('i32')
    tuple_type = Tuple(ts)
    trap_if(ptr != align_to(ptr, alignment(tuple_type)))
    return list(load(opts, ptr, tuple_type).values())
  else:
    return [ lift_flat(opts, vi, t) for t in ts ]

#

def lower_values(opts, max_flat, vs, ts, out_param = None):
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    tuple_type = Tuple(ts)
    tuple_value = {str(i): v for i,v in enumerate(vs)}
    if out_param is None:
      ptr = opts.realloc(0, 0, alignment(tuple_type), size(tuple_type))
    else:
      ptr = out_param.next('i32')
    trap_if(ptr != align_to(ptr, alignment(tuple_type)))
    store(opts, tuple_value, tuple_type, ptr)
    return [ Value('i32', ptr) ]
  else:
    flat_vals = []
    for i in range(len(vs)):
      flat_vals += lower_flat(opts, vs[i], ts[i])
    return flat_vals

### `lift`

class Instance:
  may_leave = True
  may_enter = True
  # ...

def canon_lift(callee_opts, callee_instance, callee, ft, args, called_as_export):
  if called_as_export:
    trap_if(not callee_instance.may_enter)
    callee_instance.may_enter = False
  else:
    assert(not callee_instance.may_enter)

  assert(callee_instance.may_leave)
  callee_instance.may_leave = False
  flat_args = lower_values(callee_opts, MAX_FLAT_PARAMS, args, ft.param_types())
  callee_instance.may_leave = True

  try:
    flat_results = callee(flat_args)
  except CoreWebAssemblyException:
    trap()

  results = lift_values(callee_opts, MAX_FLAT_RESULTS, ValueIter(flat_results), ft.result_types())
  def post_return():
    if callee_opts.post_return is not None:
      callee_opts.post_return(flat_results)
    if called_as_export:
      callee_instance.may_enter = True

  return (results, post_return)

### `lower`

def canon_lower(caller_opts, caller_instance, callee, ft, flat_args):
  trap_if(not caller_instance.may_leave)

  flat_args = ValueIter(flat_args)
  args = lift_values(caller_opts, MAX_FLAT_PARAMS, flat_args, ft.param_types())

  results, post_return = callee(args)

  caller_instance.may_leave = False
  flat_results = lower_values(caller_opts, MAX_FLAT_RESULTS, results, ft.result_types(), flat_args)
  caller_instance.may_leave = True

  post_return()

  return flat_results

### Canonical Module Type

CABI_VERSION = '0.1'

#

def canonical_module_type(ct: ComponentType) -> ModuleType:
  start_params, import_funcs = mangle_instances(ct.imports)
  start_results, export_funcs = mangle_instances(ct.exports)

  imports = []
  for name,ft in import_funcs:
    flat_ft = flatten_functype(ft, 'lower')
    imports.append(CoreImportDecl('', mangle_funcname(name, ft), flat_ft))

  exports = []
  exports.append(CoreExportDecl('cabi_memory', CoreMemoryType(initial=0, maximum=None)))
  exports.append(CoreExportDecl('cabi_realloc', CoreFuncType(['i32','i32','i32','i32'], ['i32'])))

  start_ft = FuncType(start_params, start_results)
  start_name = mangle_funcname('cabi_start{cabi=' + CABI_VERSION + '}', start_ft)
  exports.append(CoreExportDecl(start_name, flatten_functype(start_ft, 'lift')))

  for name,ft in export_funcs:
    flat_ft = flatten_functype(ft, 'lift')
    exports.append(CoreExportDecl(mangle_funcname(name, ft), flat_ft))
    if any(contains_dynamic_allocation(t) for t in ft.results):
      exports.append(CoreExportDecl('cabi_post_' + name, CoreFuncType(flat_ft.results, [])))

  return ModuleType(imports, exports)

def contains_dynamic_allocation(t):
  match despecialize(t):
    case String()       : return True
    case List(t)        : return True
    case Record(fields) : return any(contains_dynamic_allocation(f.t) for f in fields)
    case Variant(cases) : return any(contains_dynamic_allocation(c.t) for c in cases)
    case _              : return False

#

def mangle_instances(xs, path = ''):
  values = []
  funcs = []
  for x in xs:
    name = path + x.name
    match x.t:
      case ValueType(t):
        values.append( (name, t) )
      case FuncType(params,results):
        funcs.append( (name, x.t) )
      case InstanceType(exports):
        vs,fs = mangle_instances(exports, name + '.')
        values += vs
        funcs += fs
      case TypeType(bounds):
        assert(False) # TODO: resource types
      case ComponentType(imports, exports):
        assert(False) # TODO: `canon instantiate`
      case ModuleType(imports, exports):
        assert(False) # TODO: canonical shared-everything linking
  return (values, funcs)

#

def mangle_funcname(name, ft):
  return '{name}: func {params} -> {results}'.format(
           name = name,
           params = mangle_funcvec(ft.params),
           results = mangle_funcvec(ft.results))

def mangle_funcvec(es):
  if len(es) == 1 and isinstance(es[0], ValType):
    return mangle_valtype(es[0])
  assert(all(type(e) == tuple and len(e) == 2 for e in es))
  mangled_elems = (e[0] + ': ' + mangle_valtype(e[1]) for e in es)
  return '(' + ', '.join(mangled_elems) + ')'

def mangle_valtype(t):
  match t:
    case Bool()           : return 'bool'
    case S8()             : return 's8'
    case U8()             : return 'u8'
    case S16()            : return 's16'
    case U16()            : return 'u16'
    case S32()            : return 's32'
    case U32()            : return 'u32'
    case S64()            : return 's64'
    case U64()            : return 'u64'
    case Float32()        : return 'float32'
    case Float64()        : return 'float64'
    case Char()           : return 'char'
    case String()         : return 'string'
    case List(t)          : return 'list<' + mangle_valtype(t) + '>'
    case Record(fields)   : return mangle_recordtype(fields)
    case Tuple(ts)        : return mangle_tupletype(ts)
    case Flags(labels)    : return mangle_flags(labels)
    case Variant(cases)   : return mangle_varianttype(cases)
    case Enum(labels)     : return mangle_enumtype(labels)
    case Union(ts)        : return mangle_uniontype(ts)
    case Option(t)        : return mangle_optiontype(t)
    case Result(ok,error) : return mangle_resulttype(ok,error)

def mangle_recordtype(fields):
  mangled_fields = (f.label + ': ' + mangle_valtype(f.t) for f in fields)
  return 'record { ' + ', '.join(mangled_fields) + ' }'

def mangle_tupletype(ts):
  return 'tuple<' + ', '.join(mangle_valtype(t) for t in ts) + '>'

def mangle_flags(labels):
  return 'flags { ' + ', '.join(labels) + ' }'

def mangle_varianttype(cases):
  mangled_cases = (c.label + '(' + mangle_maybevaltype(c.t) + ')' for c in cases)
  return 'variant { ' + ', '.join(mangled_cases) + ' }'

def mangle_enumtype(labels):
  return 'enum { ' + ', '.join(labels) + ' }'

def mangle_uniontype(ts):
  return 'union { ' + ', '.join(mangle_valtype(t) for t in ts) + ' }'

def mangle_optiontype(t):
  return 'option<' + mangle_valtype(t) + '>'

def mangle_resulttype(ok, error):
  return 'result<' + mangle_maybevaltype(ok) + ', ' + mangle_maybevaltype(error) + '>'

def mangle_maybevaltype(t):
  if t is None:
    return '_'
  return mangle_valtype(t)

## Lifting Canonical Modules

class Module:
  t: ModuleType
  instantiate: Callable[typing.List[typing.Tuple[str,str,Value]], typing.List[typing.Tuple[str,Value]]]

class Component:
  t: ComponentType
  instantiate: Callable[typing.List[typing.Tuple[str,any]], typing.List[typing.Tuple[str,any]]]

def lift_canonical_module(module: Module) -> Component:
  pass # TODO
