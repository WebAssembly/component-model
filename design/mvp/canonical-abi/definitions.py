# After the Boilerplate section, this file is ordered to line up with the code
# blocks in ../CanonicalABI.md (split by # comment lines). If you update this
# file, don't forget to update ../CanonicalABI.md.

### Boilerplate

from __future__ import annotations
import math
import struct
from dataclasses import dataclass
from typing import Literal
from typing import Optional
from typing import Callable
from typing import MutableMapping

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
  params: [typing.Tuple[str,ValType]]
  results: [ValType|typing.Tuple[str,ValType]]
  def param_names(self):
    if len(self.params) == 0:
      return []
    if isinstance(self.params[0], ValType):
      return [str(i) for i in range(len(self.params))]
    return [name for name,t in self.params]
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

@dataclass
class Flags(ValType):
  labels: [str]

@dataclass
class Parent:
  param_name: str

Scope = None | Literal['call'] | Parent

@dataclass
class Handle(ValType):
  rt: ResourceType
  own: bool
  scope: Scope

@dataclass
class Own(ValType):
  rt: ResourceType
  scope: Scope = None

@dataclass
class Use(ValType):
  rt: ResourceType
  scope: Scope = None

@dataclass
class Consume(ValType):
  rt: ResourceType

@dataclass
class Borrow(ValType):
  rt: ResourceType

### Despecialization

def despecialize(t):
  match t:
    case Tuple(ts)         : return Record([ Field(str(i), t) for i,t in enumerate(ts) ])
    case Union(ts)         : return Variant([ Case(str(i), t) for i,t in enumerate(ts) ])
    case Enum(labels)      : return Variant([ Case(l, None) for l in labels ])
    case Option(t)         : return Variant([ Case("none", None), Case("some", t) ])
    case Result(ok, error) : return Variant([ Case("ok", ok), Case("error", error) ])
    case Own(rt, scope)    : return Handle(rt, True, scope)
    case Use(rt, scope)    : return Handle(rt, False, scope)
    case Consume(rt)       : return Handle(rt, True, 'call')
    case Borrow(rt)        : return Handle(rt, False, 'call')
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
    case Handle()           : return 4

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
    case Handle()           : return 4

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
  if n == 0: return 0
  if n <= 8: return 1
  if n <= 16: return 2
  return 4 * num_i32_flags(labels)

def num_i32_flags(labels):
  return math.ceil(len(labels) / 32)

### Runtime State

class CallContext:
  opts: CanonicalOptions
  inst: ComponentInstance
  keep_alive_handles: [HandleIndex]
  call_scoped_handle_count: int
  param_name_to_index: MutableMapping[str, HandleIndex]

  def __init__(self, opts, inst):
    self.opts = opts
    self.inst = inst
    self.keep_alive_handles = []
    self.call_scoped_handle_count = 0
    self.param_name_to_index = {}

  def keep_alive_for_call(self, hi):
    self.inst.handles[hi].pin_count += 1
    self.keep_alive_handles.append(hi)

  def add_call_scoped_handle_to_table(self):
    self.call_scoped_handle_count += 1

  def remove_call_scoped_handle_from_table(self):
    self.call_scoped_handle_count -= 1

  def exit_call(self):
    trap_if(self.call_scoped_handle_count != 0)
    for hi in self.keep_alive_handles:
      h = self.inst.handles[hi]
      h.pin_count -= 1

class CanonicalOptions:
  memory: bytearray
  string_encoding: str
  realloc: Callable[[int,int,int,int],int]
  post_return: Callable[[],None]

class ComponentInstance:
  may_leave: bool
  may_enter: bool
  handles: HandleTables

  def __init__(self):
    self.may_leave = True
    self.may_enter = True
    self.handles = HandleTables()

class ResourceType(Type):
  impl: ComponentInstance
  dtor: Optional[Callable[[int],None]]

  def __init__(self, impl, dtor = None):
    self.impl = impl
    self.dtor = dtor

class Resource:
  rep: int
  children: HandleIndex | Literal['end']

  def __init__(self, rep):
    self.rep = rep
    self.children = 'end'

  def adopt(self, cx, hi):
    h = cx.inst.handles[hi]
    h.pin_count += 1
    trap_if(h.next_child is not None)
    h.next_child = self.children
    self.children = hi

  def destroy(self, inst, rt):
    c = self.children
    while c != 'end':
      h = inst.handles[c]
      h.pin_count -= 1
      h.next_child = None
      c = h.next_child
    trap_if(inst is not rt.impl and not rt.impl.may_enter)
    if rt.dtor:
      rt.dtor(self.rep)

class HandleElem:
  r: Resource
  own: bool
  scope: None | CallContext | CallParam | HandleIndex
  param_name: Optional[str]
  pin_count: int
  next_child: Optional[HandleIndex]

  def __init__(self, r, own, scope = None, param_name = None):
    self.r = r
    self.own = own
    self.scope = scope
    self.param_name = param_name
    self.pin_count = 0
    self.next_child = None

@dataclass
class CallParam:
  cx: CallContext
  param_name: str

@dataclass
class HandleIndex:
  rt: ResourceType
  i: int

class HandleTable:
  array: [Optional[HandleElem]]
  free: [int]

  def __init__(self):
    self.array = []
    self.free = []

  def get(self, i):
    trap_if(i >= len(self.array))
    trap_if(self.array[i] is None)
    return self.array[i]

  def add(self, inst, h):
    if self.free:
      i = self.free.pop()
      assert(self.array[i] is None)
      self.array[i] = h
    else:
      i = len(self.array)
      self.array.append(h)
    match h.scope:
      case None            : pass
      case CallContext()   : h.scope.add_call_scoped_handle_to_table()
      case CallParam(cx,_) : cx.add_call_scoped_handle_to_table()
      case HandleIndex()   : inst.handles[h.scope].pin_count += 1
    return i

  def remove(self, inst, rt, i):
    trap_if(i >= len(self.array))
    trap_if(self.array[i] is None)
    h = self.array[i]
    trap_if(h.pin_count != 0)
    assert(h.next_child is None)
    self.array[i] = None
    self.free.append(i)
    match h.scope:
      case None            : pass
      case CallContext()   : h.scope.remove_call_scoped_handle_from_table()
      case CallParam(cx,_) : cx.remove_call_scoped_handle_from_table()
      case HandleIndex()   : inst.handles[h.scope].pin_count -= 1
    return h

class HandleTables:
  rt_to_table: MutableMapping[ResourceType, HandleTable]

  def __init__(self):
    self.rt_to_table = dict()

  def table(self, rt):
    if rt not in self.rt_to_table:
      self.rt_to_table[rt] = HandleTable()
    return self.rt_to_table[rt]

  def get(self, rt, i):
    return self.table(rt).get(i)
  def add(self, inst, rt, h):
    return self.table(rt).add(inst, h)
  def remove(self, inst, rt, i):
    return self.table(rt).remove(inst, rt, i)

  def __getitem__(self, hi: HandleIndex):
    assert(hi.rt in self.rt_to_table)
    h = self.rt_to_table[hi.rt].array[hi.i]
    assert(h is not None)
    return h

### Loading

def load(cx, ptr, t, param_name = None):
  assert(ptr == align_to(ptr, alignment(t)))
  assert(ptr + size(t) <= len(cx.opts.memory))
  t = despecialize(t)
  match t:
    case Bool()         : return convert_int_to_bool(load_int(cx, ptr, 1))
    case U8()           : return load_int(cx, ptr, 1)
    case U16()          : return load_int(cx, ptr, 2)
    case U32()          : return load_int(cx, ptr, 4)
    case U64()          : return load_int(cx, ptr, 8)
    case S8()           : return load_int(cx, ptr, 1, signed=True)
    case S16()          : return load_int(cx, ptr, 2, signed=True)
    case S32()          : return load_int(cx, ptr, 4, signed=True)
    case S64()          : return load_int(cx, ptr, 8, signed=True)
    case Float32()      : return canonicalize32(reinterpret_i32_as_float(load_int(cx, ptr, 4)))
    case Float64()      : return canonicalize64(reinterpret_i64_as_float(load_int(cx, ptr, 8)))
    case Char()         : return convert_i32_to_char(cx, load_int(cx, ptr, 4))
    case String()       : return load_string(cx, ptr)
    case List(t)        : return load_list(cx, ptr, t)
    case Record(fields) : return load_record(cx, ptr, fields)
    case Variant(cases) : return load_variant(cx, ptr, cases)
    case Flags(labels)  : return load_flags(cx, ptr, labels)
    case Handle()       : return lift_handle(cx, load_int(opts, ptr, 4), t, param_name)

def load_int(cx, ptr, nbytes, signed = False):
  return int.from_bytes(cx.opts.memory[ptr : ptr+nbytes], 'little', signed=signed)

def convert_int_to_bool(i):
  assert(i >= 0)
  return bool(i)

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

def convert_i32_to_char(cx, i):
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
  trap_if(ptr + length * size(elem_type) > len(cx.opts.memory))
  a = []
  for i in range(length):
    a.append(load(cx, ptr + i * size(elem_type), elem_type))
  return a

def load_record(cx, ptr, fields):
  record = {}
  for field in fields:
    ptr = align_to(ptr, alignment(field.t))
    record[field.label] = load(cx, ptr, field.t)
    ptr += size(field.t)
  return record

def load_variant(cx, ptr, cases):
  disc_size = size(discriminant_type(cases))
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
  i = load_int(cx, ptr, size_flags(labels))
  return unpack_flags_from_int(i, labels)

def unpack_flags_from_int(i, labels):
  record = {}
  for l in labels:
    record[l] = bool(i & 1)
    i >>= 1
  return record

def lift_handle(cx, i, t, param_name):
  hi = HandleIndex(t.rt, i)
  if param_name is not None:
    cx.param_name_to_index[param_name] = hi
  if t.own:
    h = cx.inst.handles.remove(cx.inst, t.rt, i)
    trap_if(not h.own)
  else:
    h = cx.inst.handles.get(t.rt, i)
    if h.own:
      match t.scope:
        case None:
          h.pin_count += 1
        case 'call':
          cx.keep_alive_for_call(hi)
        case Parent():
          trap_if(cx.inst is not t.rt.impl)
          parent = cx.inst.handles[cx.param_name_to_index[t.scope.param_name]]
          parent.r.adopt(cx, hi)
  match t.scope:
    case None:
      trap_if(h.scope is not None)
    case 'call':
      if isinstance(h.scope, HandleIndex):
        cx.keep_alive_for_call(h.scope)
    case Parent():
      match h.scope:
        case None:
          pass
        case CallContext():
          trap()
        case CallParam(other_cx, param_name):
          trap_if(cx is not other_cx)
          trap_if(param_name != t.scope.param_name)
        case HandleIndex():
          trap()
  return h.r

### Storing

def store(cx, v, t, ptr, param_name = None):
  assert(ptr == align_to(ptr, alignment(t)))
  assert(ptr + size(t) <= len(cx.opts.memory))
  t = despecialize(t)
  match t:
    case Bool()         : store_int(cx, int(bool(v)), ptr, 1)
    case U8()           : store_int(cx, v, ptr, 1)
    case U16()          : store_int(cx, v, ptr, 2)
    case U32()          : store_int(cx, v, ptr, 4)
    case U64()          : store_int(cx, v, ptr, 8)
    case S8()           : store_int(cx, v, ptr, 1, signed=True)
    case S16()          : store_int(cx, v, ptr, 2, signed=True)
    case S32()          : store_int(cx, v, ptr, 4, signed=True)
    case S64()          : store_int(cx, v, ptr, 8, signed=True)
    case Float32()      : store_int(cx, reinterpret_float_as_i32(canonicalize32(v)), ptr, 4)
    case Float64()      : store_int(cx, reinterpret_float_as_i64(canonicalize64(v)), ptr, 8)
    case Char()         : store_int(cx, char_to_i32(v), ptr, 4)
    case String()       : store_string(cx, v, ptr)
    case List(t)        : store_list(cx, v, ptr, t)
    case Record(fields) : store_record(cx, v, ptr, fields)
    case Variant(cases) : store_variant(cx, v, ptr, cases)
    case Flags(labels)  : store_flags(cx, v, ptr, labels)
    case Handle()       : store_int(cx, lower_handle(opts, v, t, param_name), ptr, 4)

def store_int(cx, v, ptr, nbytes, signed = False):
  cx.opts.memory[ptr : ptr+nbytes] = int.to_bytes(v, nbytes, 'little', signed=signed)

def reinterpret_float_as_i32(f):
  return struct.unpack('!I', struct.pack('!f', f))[0] # i32.reinterpret_f32

def reinterpret_float_as_i64(f):
  return struct.unpack('!Q', struct.pack('!d', f))[0] # i64.reinterpret_f64

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
  encoded = src.encode('utf-8')
  assert(src_code_units <= len(encoded))
  cx.opts.memory[ptr : ptr+src_code_units] = encoded[0 : src_code_units]
  if src_code_units < len(encoded):
    trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
    ptr = cx.opts.realloc(ptr, src_code_units, 1, worst_case_size)
    trap_if(ptr + worst_case_size > len(cx.opts.memory))
    cx.opts.memory[ptr+src_code_units : ptr+len(encoded)] = encoded[src_code_units : ]
    if worst_case_size > len(encoded):
      ptr = cx.opts.realloc(ptr, worst_case_size, 1, len(encoded))
      trap_if(ptr + len(encoded) > len(cx.opts.memory))
  return (ptr, len(encoded))

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
  byte_length = len(v) * size(elem_type)
  trap_if(byte_length >= (1 << 32))
  ptr = cx.opts.realloc(0, 0, alignment(elem_type), byte_length)
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + byte_length > len(cx.opts.memory))
  for i,e in enumerate(v):
    store(cx, e, elem_type, ptr + i * size(elem_type))
  return (ptr, len(v))

def store_record(cx, v, ptr, fields):
  for f in fields:
    ptr = align_to(ptr, alignment(f.t))
    store(cx, v[f.label], f.t, ptr)
    ptr += size(f.t)

def store_variant(cx, v, ptr, cases):
  case_index, case_value = match_case(v, cases)
  disc_size = size(discriminant_type(cases))
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
  store_int(cx, i, ptr, size_flags(labels))

def pack_flags_into_int(v, labels):
  i = 0
  shift = 0
  for l in labels:
    i |= (int(bool(v[l])) << shift)
    shift += 1
  return i

def lower_handle(cx, r, t, param_name):
  assert(isinstance(r, Resource))
  if not t.own and cx.inst is t.rt.impl:
    return r.rep
  if isinstance(t.scope, Parent):
    parent_index = cx.param_name_to_index[t.scope.param_name]
    parent = cx.inst.handles[parent_index]
    if parent.own:
      scope = parent_index
    elif isinstance(parent.scope, CallContext):
      scope = CallParam(parent.scope, parent.param_name)
    else:
      scope = parent.scope
  else:
    scope = t.scope
  h = HandleElem(r, t.own, scope, param_name)
  i = cx.inst.handles.add(cx.inst, t.rt, h)
  if param_name is not None:
    cx.param_name_to_index[param_name] = HandleIndex(t.rt, i)
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
    case Handle()             : return ['i32']

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

def lift_flat(cx, vi, t, param_name = None):
  t = despecialize(t)
  match t:
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
    case Char()         : return convert_i32_to_char(cx, vi.next('i32'))
    case String()       : return lift_flat_string(cx, vi)
    case List(t)        : return lift_flat_list(cx, vi, t)
    case Record(fields) : return lift_flat_record(cx, vi, fields)
    case Variant(cases) : return lift_flat_variant(cx, vi, cases)
    case Flags(labels)  : return lift_flat_flags(vi, labels)
    case Handle()       : return lift_handle(cx, vi.next('i32'), t, param_name)

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
        case ('i32', 'f32') : return reinterpret_i32_as_float(x)
        case ('i64', 'i32') : return wrap_i64_to_i32(x)
        case ('i64', 'f32') : return reinterpret_i32_as_float(wrap_i64_to_i32(x))
        case ('i64', 'f64') : return reinterpret_i64_as_float(x)
        case _              : return x
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

def lower_flat(cx, v, t, param_name = None):
  t = despecialize(t)
  match t:
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
    case String()       : return lower_flat_string(cx, v)
    case List(t)        : return lower_flat_list(cx, v, t)
    case Record(fields) : return lower_flat_record(cx, v, fields)
    case Variant(cases) : return lower_flat_variant(cx, v, cases)
    case Flags(labels)  : return lower_flat_flags(v, labels)
    case Handle()       : return [Value('i32', lower_handle(cx, v, t, param_name))]

def lower_flat_signed(i, core_bits):
  if i < 0:
    i += (1 << core_bits)
  return [Value('i' + str(core_bits), i)]

def lower_flat_string(cx, v):
  ptr, packed_length = store_string_into_range(cx, v)
  return [Value('i32', ptr), Value('i32', packed_length)]

def lower_flat_list(cx, v, elem_type):
  (ptr, length) = store_list_into_range(cx, v, elem_type)
  return [Value('i32', ptr), Value('i32', length)]

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

def lower_flat_flags(v, labels):
  i = pack_flags_into_int(v, labels)
  flat = []
  for _ in range(num_i32_flags(labels)):
    flat.append(Value('i32', i & 0xffffffff))
    i >>= 32
  assert(i == 0)
  return flat

### Lifting and Lowering Values

def lift_values(cx, max_flat, vi, ts, param_names):
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    ptr = vi.next('i32')
    tuple_type = Tuple(ts)
    trap_if(ptr != align_to(ptr, alignment(tuple_type)))
    trap_if(ptr + size(tuple_type) > len(cx.opts.memory))
    vals = []
    for i,t in enumerate(ts):
      pn = param_names[i] if param_names is not None else None
      ptr = align_to(ptr, alignment(t))
      vals.append(load(cx, ptr, t, pn))
      ptr += size(t)
    return vals
  else:
    vals = []
    for i,t in enumerate(ts):
      pn = param_names[i] if param_names is not None else None
      vals.append(lift_flat(cx, vi, t, pn))
    return vals

def lower_values(cx, max_flat, vs, ts, param_names, out_param = None):
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    tuple_type = Tuple(ts)
    if out_param is None:
      base = cx.opts.realloc(0, 0, alignment(tuple_type), size(tuple_type))
    else:
      base = out_param.next('i32')
    trap_if(base != align_to(base, alignment(tuple_type)))
    trap_if(base + size(tuple_type) > len(cx.opts.memory))
    ptr = base
    for i,(v,t) in enumerate(zip(vs,ts)):
      pn = param_names[i] if param_names is not None else None
      ptr = align_to(ptr, alignment(t))
      store(cx, v, t, ptr, pn)
      ptr += size(t)
    return [ Value('i32', base) ]
  else:
    flat_vals = []
    for i,(v,t) in enumerate(zip(vs,ts)):
      pn = param_names[i] if param_names is not None else None
      flat_vals += lower_flat(cx, v, t, pn)
    return flat_vals

### `canon lift`

def canon_lift(opts, inst, callee, ft, args):
  cx = CallContext(opts, inst)
  trap_if(not inst.may_enter)

  assert(inst.may_leave)
  inst.may_leave = False
  flat_args = lower_values(cx, MAX_FLAT_PARAMS, args, ft.param_types(), ft.param_names())
  inst.may_leave = True

  try:
    flat_results = callee(flat_args)
  except CoreWebAssemblyException:
    trap()

  results = lift_values(cx, MAX_FLAT_RESULTS, ValueIter(flat_results), ft.result_types(), None)

  def post_return():
    if opts.post_return is not None:
      opts.post_return(flat_results)
    cx.exit_call()

  return (results, post_return)

### `canon lower`

def canon_lower(opts, inst, callee, calling_import, ft, flat_args):
  cx = CallContext(opts, inst)
  trap_if(not inst.may_leave)

  assert(inst.may_enter)
  if calling_import:
    inst.may_enter = False

  flat_args = ValueIter(flat_args)
  args = lift_values(cx, MAX_FLAT_PARAMS, flat_args, ft.param_types(), ft.param_names())

  results, post_return = callee(args)

  inst.may_leave = False
  flat_results = lower_values(cx, MAX_FLAT_RESULTS, results, ft.result_types(), None, flat_args)
  inst.may_leave = True

  post_return()
  cx.exit_call()

  if calling_import:
    inst.may_enter = True

  return flat_results

### `canon resource.new`

def canon_resource_new(inst, rt, rep):
  r = Resource(rep)
  h = HandleElem(r, own=True)
  return inst.handles.add(inst, rt, h)

### `canon resource.drop`

def canon_resource_drop(inst, rt, i):
  h = inst.handles.remove(inst, rt, i)
  if h.own:
    h.r.destroy(inst, rt)

### `canon resource.rep`

def canon_resource_rep(inst, rt, i):
  h = inst.handles.get(rt, i)
  return h.r.rep
