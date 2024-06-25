# After the Boilerplate section, this file is ordered to line up with the code
# blocks in ../CanonicalABI.md (split by # comment lines). If you update this
# file, don't forget to update ../CanonicalABI.md.

### Boilerplate

from __future__ import annotations
from dataclasses import dataclass
from typing import Optional, Callable, MutableMapping, TypeVar, Generic
import math
import struct
import random

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
  imports: list[CoreImportDecl]
  exports: list[CoreExportDecl]

@dataclass
class CoreFuncType(CoreExternType):
  params: list[str]
  results: list[str]

@dataclass
class CoreMemoryType(CoreExternType):
  initial: list[int]
  maximum: Optional[int]

@dataclass
class ExternDecl:
  name: str
  t: ExternType

@dataclass
class ComponentType(ExternType):
  imports: list[ExternDecl]
  exports: list[ExternDecl]

@dataclass
class InstanceType(ExternType):
  exports: list[ExternDecl]

@dataclass
class FuncType(ExternType):
  params: list[tuple[str,ValType]]
  results: list[ValType|tuple[str,ValType]]
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
class F32(ValType): pass
class F64(ValType): pass
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
  fields: list[Field]

@dataclass
class Tuple(ValType):
  ts: list[ValType]

@dataclass
class Case:
  label: str
  t: Optional[ValType]
  refines: Optional[str] = None

@dataclass
class Variant(ValType):
  cases: list[Case]

@dataclass
class Enum(ValType):
  labels: list[str]

@dataclass
class Option(ValType):
  t: ValType

@dataclass
class Result(ValType):
  ok: Optional[ValType]
  error: Optional[ValType]

@dataclass
class Flags(ValType):
  labels: list[str]

@dataclass
class Own(ValType):
  rt: ResourceType

@dataclass
class Borrow(ValType):
  rt: ResourceType

### Despecialization

def despecialize(t):
  match t:
    case Tuple(ts)         : return Record([ Field(str(i), t) for i,t in enumerate(ts) ])
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
    case F32()              : return 4
    case F64()              : return 8
    case Char()             : return 4
    case String() | List(_) : return 4
    case Record(fields)     : return alignment_record(fields)
    case Variant(cases)     : return alignment_variant(cases)
    case Flags(labels)      : return alignment_flags(labels)
    case Own(_) | Borrow(_) : return 4

def alignment_record(fields):
  a = 1
  for f in fields:
    a = max(a, alignment(f.t))
  return a

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

def alignment_flags(labels):
  n = len(labels)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4

### Element Size

def elem_size(t):
  match despecialize(t):
    case Bool()             : return 1
    case S8() | U8()        : return 1
    case S16() | U16()      : return 2
    case S32() | U32()      : return 4
    case S64() | U64()      : return 8
    case F32()              : return 4
    case F64()              : return 8
    case Char()             : return 4
    case String() | List(_) : return 8
    case Record(fields)     : return elem_size_record(fields)
    case Variant(cases)     : return elem_size_variant(cases)
    case Flags(labels)      : return elem_size_flags(labels)
    case Own(_) | Borrow(_) : return 4

def elem_size_record(fields):
  s = 0
  for f in fields:
    s = align_to(s, alignment(f.t))
    s += elem_size(f.t)
  assert(s > 0)
  return align_to(s, alignment_record(fields))

def align_to(ptr, alignment):
  return math.ceil(ptr / alignment) * alignment

def elem_size_variant(cases):
  s = elem_size(discriminant_type(cases))
  s = align_to(s, max_case_alignment(cases))
  cs = 0
  for c in cases:
    if c.t is not None:
      cs = max(cs, elem_size(c.t))
  s += cs
  return align_to(s, alignment_variant(cases))

def elem_size_flags(labels):
  n = len(labels)
  assert(n > 0)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4 * num_i32_flags(labels)

def num_i32_flags(labels):
  return math.ceil(len(labels) / 32)

### Runtime State

@dataclass
class CallContext:
  opts: CanonicalOptions
  inst: ComponentInstance

@dataclass
class CanonicalOptions:
  memory: Optional[bytearray] = None
  string_encoding: Optional[str] = None
  realloc: Optional[Callable] = None
  post_return: Optional[Callable] = None

class ComponentInstance:
  # core module instance state
  may_leave: bool
  may_enter: bool
  handles: HandleTables

  def __init__(self):
    self.may_leave = True
    self.may_enter = True
    self.handles = HandleTables()

class HandleTables:
  rt_to_table: MutableMapping[ResourceType, Table[HandleElem]]

  def __init__(self):
    self.rt_to_table = dict()

  def table(self, rt):
    if rt not in self.rt_to_table:
      self.rt_to_table[rt] = Table[HandleElem]()
    return self.rt_to_table[rt]

  def get(self, rt, i):
    return self.table(rt).get(i)
  def add(self, rt, h):
    return self.table(rt).add(h)
  def remove(self, rt, i):
    return self.table(rt).remove(i)

class ResourceType(Type):
  impl: ComponentInstance
  dtor: Optional[Callable]

  def __init__(self, impl, dtor = None):
    self.impl = impl
    self.dtor = dtor

ElemT = TypeVar('ElemT')
class Table(Generic[ElemT]):
  array: list[Optional[ElemT]]
  free: list[int]

  def __init__(self):
    self.array = [None]
    self.free = []

  def get(self, i):
    trap_if(i >= len(self.array))
    trap_if(self.array[i] is None)
    return self.array[i]

  def add(self, e):
    if self.free:
      i = self.free.pop()
      assert(self.array[i] is None)
      self.array[i] = e
    else:
      i = len(self.array)
      trap_if(i >= 2**30)
      self.array.append(e)
    return i

  def remove(self, i):
    e = self.get(i)
    self.array[i] = None
    self.free.append(i)
    return e

class HandleElem:
  rep: int
  own: bool
  scope: Optional[ExportCall]
  lend_count: int

  def __init__(self, rep, own, scope = None):
    self.rep = rep
    self.own = own
    self.scope = scope
    self.lend_count = 0

class ExportCall(CallContext):
  borrow_count: int

  def __init__(self, opts, inst):
    super().__init__(opts, inst)
    self.borrow_count = 0

  def create_borrow(self):
    self.borrow_count += 1

  def drop_borrow(self):
    assert(self.borrow_count > 0)
    self.borrow_count -= 1

  def exit(self):
    trap_if(self.borrow_count != 0)

class ImportCall(CallContext):
  lenders: list[HandleElem]

  def __init__(self, opts, inst):
    super().__init__(opts, inst)
    self.lenders = []

  def track_owning_lend(self, lending_handle):
    assert(lending_handle.own)
    lending_handle.lend_count += 1
    self.lenders.append(lending_handle)

  def exit(self):
    for h in self.lenders:
      h.lend_count -= 1

### Loading

def load(cx, ptr, t):
  assert(ptr == align_to(ptr, alignment(t)))
  assert(ptr + elem_size(t) <= len(cx.opts.memory))
  match despecialize(t):
    case Bool()         : return convert_int_to_bool(load_int(cx, ptr, 1))
    case U8()           : return load_int(cx, ptr, 1)
    case U16()          : return load_int(cx, ptr, 2)
    case U32()          : return load_int(cx, ptr, 4)
    case U64()          : return load_int(cx, ptr, 8)
    case S8()           : return load_int(cx, ptr, 1, signed=True)
    case S16()          : return load_int(cx, ptr, 2, signed=True)
    case S32()          : return load_int(cx, ptr, 4, signed=True)
    case S64()          : return load_int(cx, ptr, 8, signed=True)
    case F32()          : return decode_i32_as_float(load_int(cx, ptr, 4))
    case F64()          : return decode_i64_as_float(load_int(cx, ptr, 8))
    case Char()         : return convert_i32_to_char(cx, load_int(cx, ptr, 4))
    case String()       : return load_string(cx, ptr)
    case List(t)        : return load_list(cx, ptr, t)
    case Record(fields) : return load_record(cx, ptr, fields)
    case Variant(cases) : return load_variant(cx, ptr, cases)
    case Flags(labels)  : return load_flags(cx, ptr, labels)
    case Own()          : return lift_own(cx, load_int(cx, ptr, 4), t)
    case Borrow()       : return lift_borrow(cx, load_int(cx, ptr, 4), t)

def load_int(cx, ptr, nbytes, signed = False):
  return int.from_bytes(cx.opts.memory[ptr : ptr+nbytes], 'little', signed=signed)

def convert_int_to_bool(i):
  assert(i >= 0)
  return bool(i)

DETERMINISTIC_PROFILE = False # or True
CANONICAL_FLOAT32_NAN = 0x7fc00000
CANONICAL_FLOAT64_NAN = 0x7ff8000000000000

def canonicalize_nan32(f):
  if math.isnan(f):
    f = core_f32_reinterpret_i32(CANONICAL_FLOAT32_NAN)
    assert(math.isnan(f))
  return f

def canonicalize_nan64(f):
  if math.isnan(f):
    f = core_f64_reinterpret_i64(CANONICAL_FLOAT64_NAN)
    assert(math.isnan(f))
  return f

def decode_i32_as_float(i):
  return canonicalize_nan32(core_f32_reinterpret_i32(i))

def decode_i64_as_float(i):
  return canonicalize_nan64(core_f64_reinterpret_i64(i))

def core_f32_reinterpret_i32(i):
  return struct.unpack('<f', struct.pack('<I', i))[0] # f32.reinterpret_i32

def core_f64_reinterpret_i64(i):
  return struct.unpack('<d', struct.pack('<Q', i))[0] # f64.reinterpret_i64

def convert_i32_to_char(cx, i):
  assert(i >= 0)
  trap_if(i >= 0x110000)
  trap_if(0xD800 <= i <= 0xDFFF)
  return chr(i)

def load_string(cx, ptr):
  begin = load_int(cx, ptr, 4)
  tagged_code_units = load_int(cx, ptr + 4, 4)
  return load_string_from_range(cx, begin, tagged_code_units)

UTF16_TAG = 1 << 31

def load_string_from_range(cx, ptr, tagged_code_units):
  match cx.opts.string_encoding:
    case 'utf8':
      alignment = 1
      byte_length = tagged_code_units
      encoding = 'utf-8'
    case 'utf16':
      alignment = 2
      byte_length = 2 * tagged_code_units
      encoding = 'utf-16-le'
    case 'latin1+utf16':
      alignment = 2
      if bool(tagged_code_units & UTF16_TAG):
        byte_length = 2 * (tagged_code_units ^ UTF16_TAG)
        encoding = 'utf-16-le'
      else:
        byte_length = tagged_code_units
        encoding = 'latin-1'

  trap_if(ptr != align_to(ptr, alignment))
  trap_if(ptr + byte_length > len(cx.opts.memory))
  try:
    s = cx.opts.memory[ptr : ptr+byte_length].decode(encoding)
  except UnicodeError:
    trap()

  return (s, cx.opts.string_encoding, tagged_code_units)

def load_list(cx, ptr, elem_type):
  begin = load_int(cx, ptr, 4)
  length = load_int(cx, ptr + 4, 4)
  return load_list_from_range(cx, begin, length, elem_type)

def load_list_from_range(cx, ptr, length, elem_type):
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + length * elem_size(elem_type) > len(cx.opts.memory))
  a = []
  for i in range(length):
    a.append(load(cx, ptr + i * elem_size(elem_type), elem_type))
  return a

def load_record(cx, ptr, fields):
  record = {}
  for field in fields:
    ptr = align_to(ptr, alignment(field.t))
    record[field.label] = load(cx, ptr, field.t)
    ptr += elem_size(field.t)
  return record

def load_variant(cx, ptr, cases):
  disc_size = elem_size(discriminant_type(cases))
  case_index = load_int(cx, ptr, disc_size)
  ptr += disc_size
  trap_if(case_index >= len(cases))
  c = cases[case_index]
  ptr = align_to(ptr, max_case_alignment(cases))
  case_label = case_label_with_refinements(c, cases)
  if c.t is None:
    return { case_label: None }
  return { case_label: load(cx, ptr, c.t) }

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

def load_flags(cx, ptr, labels):
  i = load_int(cx, ptr, elem_size_flags(labels))
  return unpack_flags_from_int(i, labels)

def unpack_flags_from_int(i, labels):
  record = {}
  for l in labels:
    record[l] = bool(i & 1)
    i >>= 1
  return record

def lift_own(cx, i, t):
  h = cx.inst.handles.remove(t.rt, i)
  trap_if(h.lend_count != 0)
  trap_if(not h.own)
  return h.rep

def lift_borrow(cx, i, t):
  assert(isinstance(cx, ImportCall))
  h = cx.inst.handles.get(t.rt, i)
  if h.own:
    cx.track_owning_lend(h)
  return h.rep

### Storing

def store(cx, v, t, ptr):
  assert(ptr == align_to(ptr, alignment(t)))
  assert(ptr + elem_size(t) <= len(cx.opts.memory))
  match despecialize(t):
    case Bool()         : store_int(cx, int(bool(v)), ptr, 1)
    case U8()           : store_int(cx, v, ptr, 1)
    case U16()          : store_int(cx, v, ptr, 2)
    case U32()          : store_int(cx, v, ptr, 4)
    case U64()          : store_int(cx, v, ptr, 8)
    case S8()           : store_int(cx, v, ptr, 1, signed=True)
    case S16()          : store_int(cx, v, ptr, 2, signed=True)
    case S32()          : store_int(cx, v, ptr, 4, signed=True)
    case S64()          : store_int(cx, v, ptr, 8, signed=True)
    case F32()          : store_int(cx, encode_float_as_i32(v), ptr, 4)
    case F64()          : store_int(cx, encode_float_as_i64(v), ptr, 8)
    case Char()         : store_int(cx, char_to_i32(v), ptr, 4)
    case String()       : store_string(cx, v, ptr)
    case List(t)        : store_list(cx, v, ptr, t)
    case Record(fields) : store_record(cx, v, ptr, fields)
    case Variant(cases) : store_variant(cx, v, ptr, cases)
    case Flags(labels)  : store_flags(cx, v, ptr, labels)
    case Own()          : store_int(cx, lower_own(cx.opts, v, t), ptr, 4)
    case Borrow()       : store_int(cx, lower_borrow(cx.opts, v, t), ptr, 4)

def store_int(cx, v, ptr, nbytes, signed = False):
  cx.opts.memory[ptr : ptr+nbytes] = int.to_bytes(v, nbytes, 'little', signed=signed)

def maybe_scramble_nan32(f):
  if math.isnan(f):
    if DETERMINISTIC_PROFILE:
      f = core_f32_reinterpret_i32(CANONICAL_FLOAT32_NAN)
    else:
      f = core_f32_reinterpret_i32(random_nan_bits(32, 8))
    assert(math.isnan(f))
  return f

def maybe_scramble_nan64(f):
  if math.isnan(f):
    if DETERMINISTIC_PROFILE:
      f = core_f64_reinterpret_i64(CANONICAL_FLOAT64_NAN)
    else:
      f = core_f64_reinterpret_i64(random_nan_bits(64, 11))
    assert(math.isnan(f))
  return f

def random_nan_bits(total_bits, exponent_bits):
  fraction_bits = total_bits - exponent_bits - 1
  bits = random.getrandbits(total_bits)
  bits |= ((1 << exponent_bits) - 1) << fraction_bits
  bits |= 1 << random.randrange(fraction_bits - 1)
  return bits

def encode_float_as_i32(f):
  return core_i32_reinterpret_f32(maybe_scramble_nan32(f))

def encode_float_as_i64(f):
  return core_i64_reinterpret_f64(maybe_scramble_nan64(f))

def core_i32_reinterpret_f32(f):
  return struct.unpack('<I', struct.pack('<f', f))[0] # i32.reinterpret_f32

def core_i64_reinterpret_f64(f):
  return struct.unpack('<Q', struct.pack('<d', f))[0] # i64.reinterpret_f64

def char_to_i32(c):
  i = ord(c)
  assert(0 <= i <= 0xD7FF or 0xD800 <= i <= 0x10FFFF)
  return i

def store_string(cx, v, ptr):
  begin, tagged_code_units = store_string_into_range(cx, v)
  store_int(cx, begin, ptr, 4)
  store_int(cx, tagged_code_units, ptr + 4, 4)

def store_string_into_range(cx, v):
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

  match cx.opts.string_encoding:
    case 'utf8':
      match src_simple_encoding:
        case 'utf8'         : return store_string_copy(cx, src, src_code_units, 1, 1, 'utf-8')
        case 'utf16'        : return store_utf16_to_utf8(cx, src, src_code_units)
        case 'latin1'       : return store_latin1_to_utf8(cx, src, src_code_units)
    case 'utf16':
      match src_simple_encoding:
        case 'utf8'         : return store_utf8_to_utf16(cx, src, src_code_units)
        case 'utf16'        : return store_string_copy(cx, src, src_code_units, 2, 2, 'utf-16-le')
        case 'latin1'       : return store_string_copy(cx, src, src_code_units, 2, 2, 'utf-16-le')
    case 'latin1+utf16':
      match src_encoding:
        case 'utf8'         : return store_string_to_latin1_or_utf16(cx, src, src_code_units)
        case 'utf16'        : return store_string_to_latin1_or_utf16(cx, src, src_code_units)
        case 'latin1+utf16' :
          match src_simple_encoding:
            case 'latin1'   : return store_string_copy(cx, src, src_code_units, 1, 2, 'latin-1')
            case 'utf16'    : return store_probably_utf16_to_latin1_or_utf16(cx, src, src_code_units)

MAX_STRING_BYTE_LENGTH = (1 << 31) - 1

def store_string_copy(cx, src, src_code_units, dst_code_unit_size, dst_alignment, dst_encoding):
  dst_byte_length = dst_code_unit_size * src_code_units
  trap_if(dst_byte_length > MAX_STRING_BYTE_LENGTH)
  ptr = cx.opts.realloc(0, 0, dst_alignment, dst_byte_length)
  trap_if(ptr != align_to(ptr, dst_alignment))
  trap_if(ptr + dst_byte_length > len(cx.opts.memory))
  encoded = src.encode(dst_encoding)
  assert(dst_byte_length == len(encoded))
  cx.opts.memory[ptr : ptr+len(encoded)] = encoded
  return (ptr, src_code_units)

def store_utf16_to_utf8(cx, src, src_code_units):
  worst_case_size = src_code_units * 3
  return store_string_to_utf8(cx, src, src_code_units, worst_case_size)

def store_latin1_to_utf8(cx, src, src_code_units):
  worst_case_size = src_code_units * 2
  return store_string_to_utf8(cx, src, src_code_units, worst_case_size)

def store_string_to_utf8(cx, src, src_code_units, worst_case_size):
  assert(src_code_units <= MAX_STRING_BYTE_LENGTH)
  ptr = cx.opts.realloc(0, 0, 1, src_code_units)
  trap_if(ptr + src_code_units > len(cx.opts.memory))
  for i,code_point in enumerate(src):
    if ord(code_point) < 2**7:
      cx.opts.memory[ptr + i] = ord(code_point)
    else:
      trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
      ptr = cx.opts.realloc(ptr, src_code_units, 1, worst_case_size)
      trap_if(ptr + worst_case_size > len(cx.opts.memory))
      encoded = src.encode('utf-8')
      cx.opts.memory[ptr+i : ptr+len(encoded)] = encoded[i : ]
      if worst_case_size > len(encoded):
        ptr = cx.opts.realloc(ptr, worst_case_size, 1, len(encoded))
        trap_if(ptr + len(encoded) > len(cx.opts.memory))
      return (ptr, len(encoded))
  return (ptr, src_code_units)

def store_utf8_to_utf16(cx, src, src_code_units):
  worst_case_size = 2 * src_code_units
  trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
  ptr = cx.opts.realloc(0, 0, 2, worst_case_size)
  trap_if(ptr != align_to(ptr, 2))
  trap_if(ptr + worst_case_size > len(cx.opts.memory))
  encoded = src.encode('utf-16-le')
  cx.opts.memory[ptr : ptr+len(encoded)] = encoded
  if len(encoded) < worst_case_size:
    ptr = cx.opts.realloc(ptr, worst_case_size, 2, len(encoded))
    trap_if(ptr != align_to(ptr, 2))
    trap_if(ptr + len(encoded) > len(cx.opts.memory))
  code_units = int(len(encoded) / 2)
  return (ptr, code_units)

def store_string_to_latin1_or_utf16(cx, src, src_code_units):
  assert(src_code_units <= MAX_STRING_BYTE_LENGTH)
  ptr = cx.opts.realloc(0, 0, 2, src_code_units)
  trap_if(ptr != align_to(ptr, 2))
  trap_if(ptr + src_code_units > len(cx.opts.memory))
  dst_byte_length = 0
  for usv in src:
    if ord(usv) < (1 << 8):
      cx.opts.memory[ptr + dst_byte_length] = ord(usv)
      dst_byte_length += 1
    else:
      worst_case_size = 2 * src_code_units
      trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
      ptr = cx.opts.realloc(ptr, src_code_units, 2, worst_case_size)
      trap_if(ptr != align_to(ptr, 2))
      trap_if(ptr + worst_case_size > len(cx.opts.memory))
      for j in range(dst_byte_length-1, -1, -1):
        cx.opts.memory[ptr + 2*j] = cx.opts.memory[ptr + j]
        cx.opts.memory[ptr + 2*j + 1] = 0
      encoded = src.encode('utf-16-le')
      cx.opts.memory[ptr+2*dst_byte_length : ptr+len(encoded)] = encoded[2*dst_byte_length : ]
      if worst_case_size > len(encoded):
        ptr = cx.opts.realloc(ptr, worst_case_size, 2, len(encoded))
        trap_if(ptr != align_to(ptr, 2))
        trap_if(ptr + len(encoded) > len(cx.opts.memory))
      tagged_code_units = int(len(encoded) / 2) | UTF16_TAG
      return (ptr, tagged_code_units)
  if dst_byte_length < src_code_units:
    ptr = cx.opts.realloc(ptr, src_code_units, 2, dst_byte_length)
    trap_if(ptr != align_to(ptr, 2))
    trap_if(ptr + dst_byte_length > len(cx.opts.memory))
  return (ptr, dst_byte_length)

def store_probably_utf16_to_latin1_or_utf16(cx, src, src_code_units):
  src_byte_length = 2 * src_code_units
  trap_if(src_byte_length > MAX_STRING_BYTE_LENGTH)
  ptr = cx.opts.realloc(0, 0, 2, src_byte_length)
  trap_if(ptr != align_to(ptr, 2))
  trap_if(ptr + src_byte_length > len(cx.opts.memory))
  encoded = src.encode('utf-16-le')
  cx.opts.memory[ptr : ptr+len(encoded)] = encoded
  if any(ord(c) >= (1 << 8) for c in src):
    tagged_code_units = int(len(encoded) / 2) | UTF16_TAG
    return (ptr, tagged_code_units)
  latin1_size = int(len(encoded) / 2)
  for i in range(latin1_size):
    cx.opts.memory[ptr + i] = cx.opts.memory[ptr + 2*i]
  ptr = cx.opts.realloc(ptr, src_byte_length, 1, latin1_size)
  trap_if(ptr + latin1_size > len(cx.opts.memory))
  return (ptr, latin1_size)

def store_list(cx, v, ptr, elem_type):
  begin, length = store_list_into_range(cx, v, elem_type)
  store_int(cx, begin, ptr, 4)
  store_int(cx, length, ptr + 4, 4)

def store_list_into_range(cx, v, elem_type):
  byte_length = len(v) * elem_size(elem_type)
  trap_if(byte_length >= (1 << 32))
  ptr = cx.opts.realloc(0, 0, alignment(elem_type), byte_length)
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + byte_length > len(cx.opts.memory))
  for i,e in enumerate(v):
    store(cx, e, elem_type, ptr + i * elem_size(elem_type))
  return (ptr, len(v))

def store_record(cx, v, ptr, fields):
  for f in fields:
    ptr = align_to(ptr, alignment(f.t))
    store(cx, v[f.label], f.t, ptr)
    ptr += elem_size(f.t)

def store_variant(cx, v, ptr, cases):
  case_index, case_value = match_case(v, cases)
  disc_size = elem_size(discriminant_type(cases))
  store_int(cx, case_index, ptr, disc_size)
  ptr += disc_size
  ptr = align_to(ptr, max_case_alignment(cases))
  c = cases[case_index]
  if c.t is not None:
    store(cx, case_value, c.t, ptr)

def match_case(v, cases):
  assert(len(v.keys()) == 1)
  key = list(v.keys())[0]
  value = list(v.values())[0]
  for label in key.split('|'):
    case_index = find_case(label, cases)
    if case_index != -1:
      return (case_index, value)

def store_flags(cx, v, ptr, labels):
  i = pack_flags_into_int(v, labels)
  store_int(cx, i, ptr, elem_size_flags(labels))

def pack_flags_into_int(v, labels):
  i = 0
  shift = 0
  for l in labels:
    i |= (int(bool(v[l])) << shift)
    shift += 1
  return i

def lower_own(cx, rep, t):
  h = HandleElem(rep, own=True)
  return cx.inst.handles.add(t.rt, h)

def lower_borrow(cx, rep, t):
  assert(isinstance(cx, ExportCall))
  if cx.inst is t.rt.impl:
    return rep
  h = HandleElem(rep, own=False, scope=cx)
  cx.create_borrow()
  return cx.inst.handles.add(t.rt, h)

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

def flatten_type(t):
  match despecialize(t):
    case Bool()               : return ['i32']
    case U8() | U16() | U32() : return ['i32']
    case S8() | S16() | S32() : return ['i32']
    case S64() | U64()        : return ['i64']
    case F32()                : return ['f32']
    case F64()                : return ['f64']
    case Char()               : return ['i32']
    case String() | List(_)   : return ['i32', 'i32']
    case Record(fields)       : return flatten_record(fields)
    case Variant(cases)       : return flatten_variant(cases)
    case Flags(labels)        : return ['i32'] * num_i32_flags(labels)
    case Own(_) | Borrow(_)   : return ['i32']

def flatten_record(fields):
  flat = []
  for f in fields:
    flat += flatten_type(f.t)
  return flat

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
class CoreValueIter:
  values: list[int|float]
  i = 0
  def next(self, t):
    v = self.values[self.i]
    self.i += 1
    match t:
      case 'i32': assert(isinstance(v, int) and 0 <= v < 2**32)
      case 'i64': assert(isinstance(v, int) and 0 <= v < 2**64)
      case 'f32': assert(isinstance(v, (int,float)))
      case 'f64': assert(isinstance(v, (int,float)))
      case _    : assert(False)
    return v

def lift_flat(cx, vi, t):
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
    case F32()          : return canonicalize_nan32(vi.next('f32'))
    case F64()          : return canonicalize_nan64(vi.next('f64'))
    case Char()         : return convert_i32_to_char(cx, vi.next('i32'))
    case String()       : return lift_flat_string(cx, vi)
    case List(t)        : return lift_flat_list(cx, vi, t)
    case Record(fields) : return lift_flat_record(cx, vi, fields)
    case Variant(cases) : return lift_flat_variant(cx, vi, cases)
    case Flags(labels)  : return lift_flat_flags(vi, labels)
    case Own()          : return lift_own(cx, vi.next('i32'), t)
    case Borrow()       : return lift_borrow(cx, vi.next('i32'), t)

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

def lift_flat_string(cx, vi):
  ptr = vi.next('i32')
  packed_length = vi.next('i32')
  return load_string_from_range(cx, ptr, packed_length)

def lift_flat_list(cx, vi, elem_type):
  ptr = vi.next('i32')
  length = vi.next('i32')
  return load_list_from_range(cx, ptr, length, elem_type)

def lift_flat_record(cx, vi, fields):
  record = {}
  for f in fields:
    record[f.label] = lift_flat(cx, vi, f.t)
  return record

def lift_flat_variant(cx, vi, cases):
  flat_types = flatten_variant(cases)
  assert(flat_types.pop(0) == 'i32')
  case_index = vi.next('i32')
  trap_if(case_index >= len(cases))
  class CoerceValueIter:
    def next(self, want):
      have = flat_types.pop(0)
      x = vi.next(have)
      match (have, want):
        case ('i32', 'f32') : return decode_i32_as_float(x)
        case ('i64', 'i32') : return wrap_i64_to_i32(x)
        case ('i64', 'f32') : return decode_i32_as_float(wrap_i64_to_i32(x))
        case ('i64', 'f64') : return decode_i64_as_float(x)
        case _              : assert(have == want); return x
  c = cases[case_index]
  if c.t is None:
    v = None
  else:
    v = lift_flat(cx, CoerceValueIter(), c.t)
  for have in flat_types:
    _ = vi.next(have)
  return { case_label_with_refinements(c, cases): v }

def wrap_i64_to_i32(i):
  assert(0 <= i < (1 << 64))
  return i % (1 << 32)

def lift_flat_flags(vi, labels):
  i = 0
  shift = 0
  for _ in range(num_i32_flags(labels)):
    i |= (vi.next('i32') << shift)
    shift += 32
  return unpack_flags_from_int(i, labels)

### Flat Lowering

def lower_flat(cx, v, t):
  match despecialize(t):
    case Bool()         : return [int(v)]
    case U8()           : return [v]
    case U16()          : return [v]
    case U32()          : return [v]
    case U64()          : return [v]
    case S8()           : return lower_flat_signed(v, 32)
    case S16()          : return lower_flat_signed(v, 32)
    case S32()          : return lower_flat_signed(v, 32)
    case S64()          : return lower_flat_signed(v, 64)
    case F32()          : return [maybe_scramble_nan32(v)]
    case F64()          : return [maybe_scramble_nan64(v)]
    case Char()         : return [char_to_i32(v)]
    case String()       : return lower_flat_string(cx, v)
    case List(t)        : return lower_flat_list(cx, v, t)
    case Record(fields) : return lower_flat_record(cx, v, fields)
    case Variant(cases) : return lower_flat_variant(cx, v, cases)
    case Flags(labels)  : return lower_flat_flags(v, labels)
    case Own()          : return [lower_own(cx, v, t)]
    case Borrow()       : return [lower_borrow(cx, v, t)]

def lower_flat_signed(i, core_bits):
  if i < 0:
    i += (1 << core_bits)
  return [i]

def lower_flat_string(cx, v):
  ptr, packed_length = store_string_into_range(cx, v)
  return [ptr, packed_length]

def lower_flat_list(cx, v, elem_type):
  (ptr, length) = store_list_into_range(cx, v, elem_type)
  return [ptr, length]

def lower_flat_record(cx, v, fields):
  flat = []
  for f in fields:
    flat += lower_flat(cx, v[f.label], f.t)
  return flat

def lower_flat_variant(cx, v, cases):
  case_index, case_value = match_case(v, cases)
  flat_types = flatten_variant(cases)
  assert(flat_types.pop(0) == 'i32')
  c = cases[case_index]
  if c.t is None:
    payload = []
  else:
    payload = lower_flat(cx, case_value, c.t)
    for i,(fv,have) in enumerate(zip(payload, flatten_type(c.t))):
      want = flat_types.pop(0)
      match (have, want):
        case ('f32', 'i32') : payload[i] = encode_float_as_i32(fv)
        case ('i32', 'i64') : payload[i] = fv
        case ('f32', 'i64') : payload[i] = encode_float_as_i32(fv)
        case ('f64', 'i64') : payload[i] = encode_float_as_i64(fv)
        case _              : assert(have == want)
  for _ in flat_types:
    payload.append(0)
  return [case_index] + payload

def lower_flat_flags(v, labels):
  i = pack_flags_into_int(v, labels)
  flat = []
  for _ in range(num_i32_flags(labels)):
    flat.append(i & 0xffffffff)
    i >>= 32
  assert(i == 0)
  return flat

### Lifting and Lowering Values

def lift_values(cx, max_flat, vi, ts):
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    ptr = vi.next('i32')
    tuple_type = Tuple(ts)
    trap_if(ptr != align_to(ptr, alignment(tuple_type)))
    trap_if(ptr + elem_size(tuple_type) > len(cx.opts.memory))
    return list(load(cx, ptr, tuple_type).values())
  else:
    return [ lift_flat(cx, vi, t) for t in ts ]

def lower_values(cx, max_flat, vs, ts, out_param = None):
  inst = cx.inst
  assert(inst.may_leave)
  inst.may_leave = False

  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    tuple_type = Tuple(ts)
    tuple_value = {str(i): v for i,v in enumerate(vs)}
    if out_param is None:
      ptr = cx.opts.realloc(0, 0, alignment(tuple_type), elem_size(tuple_type))
    else:
      ptr = out_param.next('i32')
    trap_if(ptr != align_to(ptr, alignment(tuple_type)))
    trap_if(ptr + elem_size(tuple_type) > len(cx.opts.memory))
    store(cx, tuple_value, tuple_type, ptr)
    flat_vales = [ptr]
  else:
    flat_vals = []
    for i in range(len(vs)):
      flat_vals += lower_flat(cx, vs[i], ts[i])

  inst.may_leave = True
  return flat_vals

### `canon lift`

def canon_lift(opts, inst, callee, ft, start_thunk, return_thunk):
  export_call = ExportCall(opts, inst)
  trap_if(not inst.may_enter)

  flat_args = lower_values(export_call, MAX_FLAT_PARAMS, start_thunk(), ft.param_types())
  flat_results = call_and_trap_on_throw(callee, flat_args)
  return_thunk(lift_values(export_call, MAX_FLAT_RESULTS, CoreValueIter(flat_results), ft.result_types()))

  if opts.post_return is not None:
    call_and_trap_on_throw(opts.post_return, flat_results)

  export_call.exit()

def call_and_trap_on_throw(callee, args):
  try:
    return callee(args)
  except CoreWebAssemblyException:
    trap()

### `canon lower`

def canon_lower(opts, inst, callee, calling_import, ft, flat_args):
  import_call = ImportCall(opts, inst)
  trap_if(not inst.may_leave)

  assert(inst.may_enter)
  if calling_import:
    inst.may_enter = False

  flat_args = CoreValueIter(flat_args)
  flat_results = None

  def start_thunk():
    return lift_values(import_call, MAX_FLAT_PARAMS, flat_args, ft.param_types())

  def return_thunk(results):
    nonlocal flat_results
    flat_results = lower_values(import_call, MAX_FLAT_RESULTS, results, ft.result_types(), flat_args)

  callee(start_thunk, return_thunk)

  if calling_import:
    inst.may_enter = True

  import_call.exit()
  return flat_results

### `canon resource.new`

def canon_resource_new(inst, rt, rep):
  h = HandleElem(rep, own=True)
  i = inst.handles.add(rt, h)
  return [i]

### `canon resource.drop`

def canon_resource_drop(inst, rt, i):
  h = inst.handles.remove(rt, i)
  if h.own:
    assert(h.scope is None)
    trap_if(h.lend_count != 0)
    trap_if(inst is not rt.impl and not rt.impl.may_enter)
    if rt.dtor:
      rt.dtor(h.rep)
  else:
    h.scope.drop_borrow()
  return []

### `canon resource.rep`

def canon_resource_rep(inst, rt, i):
  h = inst.handles.get(rt, i)
  return [h.rep]
