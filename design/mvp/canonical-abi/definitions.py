# After the Boilerplate section, this file is ordered to line up with the code
# blocks in ../CanonicalABI.md (split by # comment lines). If you update this
# file, don't forget to update ../CanonicalABI.md.

### Boilerplate

from __future__ import annotations
from dataclasses import dataclass
from functools import partial
from typing import Any, Optional, Callable, Awaitable, TypeVar, Generic, Literal
from enum import IntEnum
import math
import struct
import random
import asyncio

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
  def __eq__(self, other):
    return self.params == other.params and self.results == other.results

def types_match_values(ts, vs):
  if len(ts) != len(vs):
    return False
  return all(type_matches_value(t, v) for t,v in zip(ts, vs))

def type_matches_value(t, v):
  match t:
    case 'i32' | 'i64': return type(v) == int
    case 'f32' | 'f64': return type(v) == float
  assert(False)

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
class PrimValType(ValType):
  pass

class BoolType(PrimValType): pass
class S8Type(PrimValType): pass
class U8Type(PrimValType): pass
class S16Type(PrimValType): pass
class U16Type(PrimValType): pass
class S32Type(PrimValType): pass
class U32Type(PrimValType): pass
class S64Type(PrimValType): pass
class U64Type(PrimValType): pass
class F32Type(PrimValType): pass
class F64Type(PrimValType): pass
class CharType(PrimValType): pass
class StringType(PrimValType): pass
class ErrorContextType(ValType): pass

@dataclass
class ListType(ValType):
  t: ValType
  l: Optional[int] = None

@dataclass
class FieldType:
  label: str
  t: ValType

@dataclass
class RecordType(ValType):
  fields: list[FieldType]

@dataclass
class TupleType(ValType):
  ts: list[ValType]

@dataclass
class CaseType:
  label: str
  t: Optional[ValType]

@dataclass
class VariantType(ValType):
  cases: list[CaseType]

@dataclass
class EnumType(ValType):
  labels: list[str]

@dataclass
class OptionType(ValType):
  t: ValType

@dataclass
class ResultType(ValType):
  ok: Optional[ValType]
  error: Optional[ValType]

@dataclass
class FlagsType(ValType):
  labels: list[str]

@dataclass
class OwnType(ValType):
  rt: ResourceType

@dataclass
class BorrowType(ValType):
  rt: ResourceType

@dataclass
class StreamType(ValType):
  t: Optional[ValType]

@dataclass
class FutureType(ValType):
  t: Optional[ValType]

### Lifting and Lowering Context

class LiftLowerContext:
  opts: LiftLowerOptions
  inst: ComponentInstance
  borrow_scope: Optional[Task|Subtask]

  def __init__(self, opts, inst, borrow_scope = None):
    self.opts = opts
    self.inst = inst
    self.borrow_scope = borrow_scope


### Canonical ABI Options

@dataclass
class LiftOptions:
  string_encoding: str = 'utf8'
  memory: Optional[bytearray] = None

  def equal(lhs, rhs):
    return lhs.string_encoding == rhs.string_encoding and \
           lhs.memory is rhs.memory

@dataclass
class LiftLowerOptions(LiftOptions):
  realloc: Optional[Callable] = None

@dataclass
class CanonicalOptions(LiftLowerOptions):
  post_return: Optional[Callable] = None
  sync: bool = True # = !canonopt.async
  callback: Optional[Callable] = None
  always_task_return: bool = False

### Runtime State

class ComponentInstance:
  resources: Table[ResourceHandle]
  waitables: Table[Waitable]
  waitable_sets: Table[WaitableSet]
  error_contexts: Table[ErrorContext]
  may_leave: bool
  backpressure: bool
  calling_sync_export: bool
  calling_sync_import: bool
  pending_tasks: list[tuple[Task, asyncio.Future]]
  starting_pending_task: bool

  def __init__(self):
    self.resources = Table[ResourceHandle]()
    self.waitables = Table[Waitable]()
    self.waitable_sets = Table[WaitableSet]()
    self.error_contexts = Table[ErrorContext]()
    self.may_leave = True
    self.backpressure = False
    self.calling_sync_export = False
    self.calling_sync_import = False
    self.pending_tasks = []
    self.starting_pending_task = False

#### Table State

ElemT = TypeVar('ElemT')
class Table(Generic[ElemT]):
  array: list[Optional[ElemT]]
  free: list[int]

  MAX_LENGTH = 2**28 - 1

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
      trap_if(i > Table.MAX_LENGTH)
      self.array.append(e)
    return i

  def remove(self, i):
    e = self.get(i)
    self.array[i] = None
    self.free.append(i)
    return e

#### Resource State

class ResourceHandle:
  rt: ResourceType
  rep: int
  own: bool
  borrow_scope: Optional[Task]
  num_lends: int

  def __init__(self, rt, rep, own, borrow_scope = None):
    self.rt = rt
    self.rep = rep
    self.own = own
    self.borrow_scope = borrow_scope
    self.num_lends = 0

class ResourceType(Type):
  impl: ComponentInstance
  dtor: Optional[Callable]
  dtor_sync: bool
  dtor_callback: Optional[Callable]

  def __init__(self, impl, dtor = None, dtor_sync = True, dtor_callback = None):
    self.impl = impl
    self.dtor = dtor
    self.dtor_sync = dtor_sync
    self.dtor_callback = dtor_callback

#### Buffer State

class Buffer:
  MAX_LENGTH = 2**30 - 1
  t: ValType
  remain: Callable[[], int]

class ReadableBuffer(Buffer):
  read: Callable[[int], list[any]]

class WritableBuffer(Buffer):
  write: Callable[[list[any]]]

class BufferGuestImpl(Buffer):
  cx: LiftLowerContext
  t: ValType
  ptr: int
  progress: int
  length: int

  def __init__(self, t, cx, ptr, length):
    trap_if(length == 0 or length > Buffer.MAX_LENGTH)
    if t:
      trap_if(ptr != align_to(ptr, alignment(t)))
      trap_if(ptr + length * elem_size(t) > len(cx.opts.memory))
    self.cx = cx
    self.t = t
    self.ptr = ptr
    self.progress = 0
    self.length = length

  def remain(self):
    return self.length - self.progress

class ReadableBufferGuestImpl(BufferGuestImpl):
  def read(self, n):
    assert(n <= self.remain())
    if self.t:
      vs = load_list_from_valid_range(self.cx, self.ptr, n, self.t)
      self.ptr += n * elem_size(self.t)
    else:
      vs = n * [()]
    self.progress += n
    return vs

class WritableBufferGuestImpl(BufferGuestImpl, WritableBuffer):
  def write(self, vs):
    assert(len(vs) <= self.remain())
    if self.t:
      store_list_into_valid_range(self.cx, vs, self.ptr, self.t)
      self.ptr += len(vs) * elem_size(self.t)
    else:
      assert(all(v == () for v in vs))
    self.progress += len(vs)

#### Context-Local Storage

class ContextLocalStorage:
  LENGTH = 2
  array: list[int]

  def __init__(self):
    self.array = [0] * ContextLocalStorage.LENGTH

  def set(self, i, v):
    assert(types_match_values(['i32'], [v]))
    self.array[i] = v

  def get(self, i):
    return self.array[i]

#### Task State

class Task:
  opts: CanonicalOptions
  inst: ComponentInstance
  ft: FuncType
  supertask: Optional[Task]
  on_return: Optional[Callable]
  on_block: Callable[[Awaitable], Awaitable]
  num_borrows: int
  context: ContextLocalStorage

  def __init__(self, opts, inst, ft, supertask, on_return, on_block):
    self.opts = opts
    self.inst = inst
    self.ft = ft
    self.supertask = supertask
    self.on_return = on_return
    self.on_block = on_block
    self.num_borrows = 0
    self.context = ContextLocalStorage()

  current = asyncio.Lock()

  async def sync_on_block(a: Awaitable):
    Task.current.release()
    v = await a
    await Task.current.acquire()
    return v

  async def enter(self, on_start):
    assert(Task.current.locked())
    self.trap_if_on_the_stack(self.inst)
    if not self.may_enter(self) or self.inst.pending_tasks:
      f = asyncio.Future()
      self.inst.pending_tasks.append((self, f))
      await self.on_block(f)
      assert(self.may_enter(self) and self.inst.starting_pending_task)
      self.inst.starting_pending_task = False
    if self.opts.sync:
      self.inst.calling_sync_export = True
    cx = LiftLowerContext(self.opts, self.inst, self)
    return lower_flat_values(cx, MAX_FLAT_PARAMS, on_start(), self.ft.param_types())

  def trap_if_on_the_stack(self, inst):
    c = self.supertask
    while c is not None:
      trap_if(c.inst is inst)
      c = c.supertask

  def may_enter(self, pending_task):
    return not self.inst.backpressure and \
           not self.inst.calling_sync_import and \
           not (self.inst.calling_sync_export and pending_task.opts.sync)

  def maybe_start_pending_task(self):
    if self.inst.starting_pending_task:
      return
    for i,(pending_task,pending_future) in enumerate(self.inst.pending_tasks):
      if self.may_enter(pending_task):
        self.inst.pending_tasks.pop(i)
        self.inst.starting_pending_task = True
        pending_future.set_result(None)
        return

  async def yield_(self, sync):
    await self.wait_on(asyncio.sleep(0), sync)

  async_waiting_tasks = asyncio.Condition(current)

  async def wait_on(self, awaitable, sync):
    assert(not self.inst.calling_sync_import)
    if sync:
      self.inst.calling_sync_import = True
      v = await self.on_block(awaitable)
      self.inst.calling_sync_import = False
      self.async_waiting_tasks.notify_all()
    else:
      self.maybe_start_pending_task()
      v = await self.on_block(awaitable)
      while self.inst.calling_sync_import:
        await self.async_waiting_tasks.wait()
    return v

  async def call_sync(self, callee, *args):
    assert(not self.inst.calling_sync_import)
    self.inst.calling_sync_import = True
    v = await callee(*args, self.on_block)
    self.inst.calling_sync_import = False
    self.async_waiting_tasks.notify_all()
    return v

  async def call_async(self, callee, *args):
    ret = asyncio.Future()
    async def async_on_block(a: Awaitable):
      if not ret.done():
        ret.set_result(None)
      else:
        Task.current.release()
      v = await a
      await Task.current.acquire()
      return v
    async def do_call():
      await callee(*args, async_on_block)
      if not ret.done():
        ret.set_result(None)
      else:
        Task.current.release()
    asyncio.create_task(do_call())
    await ret

  def return_(self, flat_results):
    trap_if(not self.on_return)
    trap_if(self.num_borrows > 0)
    if self.opts.sync and not self.opts.always_task_return:
      maxflat = MAX_FLAT_RESULTS
    else:
      maxflat = MAX_FLAT_PARAMS
    ts = self.ft.result_types()
    cx = LiftLowerContext(self.opts, self.inst, self)
    vs = lift_flat_values(cx, maxflat, CoreValueIter(flat_results), ts)
    self.on_return(vs)
    self.on_return = None

  def exit(self):
    assert(Task.current.locked())
    trap_if(self.on_return)
    assert(self.num_borrows == 0)
    if self.opts.sync:
      assert(self.inst.calling_sync_export)
      self.inst.calling_sync_export = False
    self.maybe_start_pending_task()

#### Waitable State

class CallState(IntEnum):
  STARTING = 1
  STARTED = 2
  RETURNED = 3

class EventCode(IntEnum):
  NONE = 0
  CALL_STARTING = CallState.STARTING
  CALL_STARTED = CallState.STARTED
  CALL_RETURNED = CallState.RETURNED
  STREAM_READ = 5
  STREAM_WRITE = 6
  FUTURE_READ = 7
  FUTURE_WRITE = 8

EventTuple = tuple[EventCode, int, int]

class Waitable:
  pending_event: Optional[Callable[[], EventTuple]]
  has_pending_event_: asyncio.Event
  maybe_waitable_set: Optional[WaitableSet]

  def __init__(self):
    self.pending_event = None
    self.has_pending_event_ = asyncio.Event()
    self.maybe_waitable_set = None

  def set_event(self, pending_event):
    self.pending_event = pending_event
    self.has_pending_event_.set()
    if self.maybe_waitable_set:
      self.maybe_waitable_set.maybe_has_pending_event.set()

  def has_pending_event(self):
    assert(self.has_pending_event_.is_set() == bool(self.pending_event))
    return self.has_pending_event_.is_set()

  async def wait_for_pending_event(self):
    return await self.has_pending_event_.wait()

  def get_event(self) -> EventTuple:
    assert(self.has_pending_event())
    pending_event = self.pending_event
    self.pending_event = None
    self.has_pending_event_.clear()
    return pending_event()

  def join(self, maybe_waitable_set):
    if self.maybe_waitable_set:
      self.maybe_waitable_set.elems.remove(self)
    self.maybe_waitable_set = maybe_waitable_set
    if maybe_waitable_set:
      maybe_waitable_set.elems.append(self)
      if self.has_pending_event():
        maybe_waitable_set.maybe_has_pending_event.set()

  def drop(self):
    assert(not self.has_pending_event())
    self.join(None)

class WaitableSet:
  elems: list[Waitable]
  maybe_has_pending_event: asyncio.Event
  num_waiting: int

  def __init__(self):
    self.elems = []
    self.maybe_has_pending_event = asyncio.Event()
    self.num_waiting = 0

  async def wait(self) -> EventTuple:
    self.num_waiting += 1
    while True:
      await self.maybe_has_pending_event.wait()
      if (e := self.poll()):
        self.num_waiting -= 1
        return e

  def poll(self) -> Optional[EventTuple]:
    random.shuffle(self.elems)
    for w in self.elems:
      assert(self is w.maybe_waitable_set)
      if w.has_pending_event():
        assert(self.maybe_has_pending_event.is_set())
        return w.get_event()
    self.maybe_has_pending_event.clear()
    return None

  def drop(self):
    trap_if(len(self.elems) > 0)
    trap_if(self.num_waiting > 0)

#### Subtask State

class Subtask(Waitable):
  state: CallState
  lenders: list[ResourceHandle]
  finished: bool
  supertask: Optional[Task]

  def __init__(self):
    self.state = CallState.STARTING
    self.lenders = []
    self.finished = False
    self.supertask = None

  def add_to_waitables(self, task):
    assert(not self.supertask)
    self.supertask = task
    Waitable.__init__(self)
    return task.inst.waitables.add(self)

  def add_lender(self, lending_handle):
    assert(not self.finished and self.state != CallState.RETURNED)
    lending_handle.num_lends += 1
    self.lenders.append(lending_handle)

  def finish(self):
    assert(not self.finished and self.state == CallState.RETURNED)
    for h in self.lenders:
      h.num_lends -= 1
    self.finished = True

  def drop(self):
    trap_if(not self.finished)
    assert(self.state == CallState.RETURNED)
    Waitable.drop(self)

#### Stream State

RevokeBuffer = Callable[[], None]
OnPartialCopy = Callable[RevokeBuffer, None]
OnCopyDone = Callable[[], None]

class ReadableStream:
  t: ValType
  read: Callable[[WritableBuffer, OnPartialCopy, OnCopyDone], Literal['done','blocked']]
  cancel: Callable[[], None]
  close: Callable[[Optional[ErrorContext]]]
  closed: Callable[[], bool]
  closed_with: Callable[[], Optional[ErrorContext]]

class ReadableStreamGuestImpl(ReadableStream):
  impl: ComponentInstance
  closed_: bool
  pending_buffer: Optional[Buffer]
  pending_on_partial_copy: Optional[OnPartialCopy]
  pending_on_copy_done: Optional[OnCopyDone]

  def __init__(self, t, inst):
    self.t = t
    self.impl = inst
    self.closed_ = False
    self.reset_pending()

  def reset_pending(self):
    self.pending_buffer = None
    self.pending_on_partial_copy = None
    self.pending_on_copy_done = None

  def reset_and_notify_pending(self):
    pending_on_copy_done = self.pending_on_copy_done
    self.reset_pending()
    pending_on_copy_done()

  def cancel(self):
    self.reset_and_notify_pending()

  def close(self):
    if not self.closed_:
      self.closed_ = True
      if self.pending_buffer:
        self.reset_and_notify_pending()

  def closed(self):
    return self.closed_

  def read(self, dst, on_partial_copy, on_copy_done):
    return self.copy(dst, on_partial_copy, on_copy_done, self.pending_buffer, dst)

  def write(self, src, on_partial_copy, on_copy_done):
    return self.copy(src, on_partial_copy, on_copy_done, src, self.pending_buffer)

  def copy(self, buffer, on_partial_copy, on_copy_done, src, dst):
    if self.closed_:
      return 'done'
    elif not self.pending_buffer:
      self.pending_buffer = buffer
      self.pending_on_partial_copy = on_partial_copy
      self.pending_on_copy_done = on_copy_done
      return 'blocked'
    else:
      ncopy = min(src.remain(), dst.remain())
      assert(ncopy > 0)
      dst.write(src.read(ncopy))
      if self.pending_buffer.remain() > 0:
        self.pending_on_partial_copy(self.reset_pending)
      else:
        self.reset_and_notify_pending()
      return 'done'

class StreamEnd(Waitable):
  stream: ReadableStream
  copying: bool

  def __init__(self, stream):
    Waitable.__init__(self)
    self.stream = stream
    self.copying = False

  def drop(self):
    trap_if(self.copying)
    self.stream.close()
    Waitable.drop(self)

class ReadableStreamEnd(StreamEnd):
  def copy(self, dst, on_partial_copy, on_copy_done):
    return self.stream.read(dst, on_partial_copy, on_copy_done)

class WritableStreamEnd(StreamEnd):
  paired: bool = False
  def copy(self, src, on_partial_copy, on_copy_done):
    return self.stream.write(src, on_partial_copy, on_copy_done)

#### Future State

class FutureEnd(StreamEnd):
  def close_after_copy(self, copy_op, buffer, on_copy_done):
    assert(buffer.remain() == 1)
    def on_copy_done_wrapper():
      if buffer.remain() == 0:
        self.stream.close()
      on_copy_done()
    ret = copy_op(buffer, on_partial_copy = None, on_copy_done = on_copy_done_wrapper)
    if ret == 'done' and buffer.remain() == 0:
      self.stream.close()
    return ret

class ReadableFutureEnd(FutureEnd):
  def copy(self, dst, on_partial_copy, on_copy_done):
    return self.close_after_copy(self.stream.read, dst, on_copy_done)

class WritableFutureEnd(FutureEnd):
  paired: bool = False
  def copy(self, src, on_partial_copy, on_copy_done):
    return self.close_after_copy(self.stream.write, src, on_copy_done)
  def drop(self):
    FutureEnd.drop(self)

### Despecialization

def despecialize(t):
  match t:
    case TupleType(ts)       : return RecordType([ FieldType(str(i), t) for i,t in enumerate(ts) ])
    case EnumType(labels)    : return VariantType([ CaseType(l, None) for l in labels ])
    case OptionType(t)       : return VariantType([ CaseType("none", None), CaseType("some", t) ])
    case ResultType(ok, err) : return VariantType([ CaseType("ok", ok), CaseType("error", err) ])
    case _                   : return t

### Type Predicates

def contains_borrow(t):
  return contains(t, lambda u: isinstance(u, BorrowType))

def contains_async_value(t):
  return contains(t, lambda u: isinstance(u, StreamType | FutureType))

def contains(t, p):
  t = despecialize(t)
  match t:
    case None:
      return False
    case PrimValType() | OwnType() | BorrowType():
      return p(t)
    case ListType(u) | StreamType(u) | FutureType(u):
      return p(t) or contains(u, p)
    case RecordType(fields):
      return p(t) or any(contains(f.t, p) for f in fields)
    case VariantType(cases):
      return p(t) or any(contains(c.t, p) for c in cases)
    case FuncType():
      return any(p(u) for u in t.param_types() + t.result_types())
    case _:
      assert(False)


### Alignment

def alignment(t):
  match despecialize(t):
    case BoolType()                  : return 1
    case S8Type() | U8Type()         : return 1
    case S16Type() | U16Type()       : return 2
    case S32Type() | U32Type()       : return 4
    case S64Type() | U64Type()       : return 8
    case F32Type()                   : return 4
    case F64Type()                   : return 8
    case CharType()                  : return 4
    case StringType()                : return 4
    case ErrorContextType()          : return 4
    case ListType(t, l)              : return alignment_list(t, l)
    case RecordType(fields)          : return alignment_record(fields)
    case VariantType(cases)          : return alignment_variant(cases)
    case FlagsType(labels)           : return alignment_flags(labels)
    case OwnType() | BorrowType()    : return 4
    case StreamType() | FutureType() : return 4

def alignment_list(elem_type, maybe_length):
  if maybe_length is not None:
    return alignment(elem_type)
  return 4

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
    case 0: return U8Type()
    case 1: return U8Type()
    case 2: return U16Type()
    case 3: return U32Type()

def max_case_alignment(cases):
  a = 1
  for c in cases:
    if c.t is not None:
      a = max(a, alignment(c.t))
  return a

def alignment_flags(labels):
  n = len(labels)
  assert(0 < n <= 32)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4

### Element Size

def elem_size(t):
  match despecialize(t):
    case BoolType()                  : return 1
    case S8Type() | U8Type()         : return 1
    case S16Type() | U16Type()       : return 2
    case S32Type() | U32Type()       : return 4
    case S64Type() | U64Type()       : return 8
    case F32Type()                   : return 4
    case F64Type()                   : return 8
    case CharType()                  : return 4
    case StringType()                : return 8
    case ErrorContextType()          : return 4
    case ListType(t, l)              : return elem_size_list(t, l)
    case RecordType(fields)          : return elem_size_record(fields)
    case VariantType(cases)          : return elem_size_variant(cases)
    case FlagsType(labels)           : return elem_size_flags(labels)
    case OwnType() | BorrowType()    : return 4
    case StreamType() | FutureType() : return 4

def elem_size_list(elem_type, maybe_length):
  if maybe_length is not None:
    return maybe_length * elem_size(elem_type)
  return 8

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
  assert(0 < n <= 32)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4

### Loading

def load(cx, ptr, t):
  assert(ptr == align_to(ptr, alignment(t)))
  assert(ptr + elem_size(t) <= len(cx.opts.memory))
  match despecialize(t):
    case BoolType()         : return convert_int_to_bool(load_int(cx, ptr, 1))
    case U8Type()           : return load_int(cx, ptr, 1)
    case U16Type()          : return load_int(cx, ptr, 2)
    case U32Type()          : return load_int(cx, ptr, 4)
    case U64Type()          : return load_int(cx, ptr, 8)
    case S8Type()           : return load_int(cx, ptr, 1, signed = True)
    case S16Type()          : return load_int(cx, ptr, 2, signed = True)
    case S32Type()          : return load_int(cx, ptr, 4, signed = True)
    case S64Type()          : return load_int(cx, ptr, 8, signed = True)
    case F32Type()          : return decode_i32_as_float(load_int(cx, ptr, 4))
    case F64Type()          : return decode_i64_as_float(load_int(cx, ptr, 8))
    case CharType()         : return convert_i32_to_char(cx, load_int(cx, ptr, 4))
    case StringType()       : return load_string(cx, ptr)
    case ErrorContextType() : return lift_error_context(cx, load_int(cx, ptr, 4))
    case ListType(t, l)     : return load_list(cx, ptr, t, l)
    case RecordType(fields) : return load_record(cx, ptr, fields)
    case VariantType(cases) : return load_variant(cx, ptr, cases)
    case FlagsType(labels)  : return load_flags(cx, ptr, labels)
    case OwnType()          : return lift_own(cx, load_int(cx, ptr, 4), t)
    case BorrowType()       : return lift_borrow(cx, load_int(cx, ptr, 4), t)
    case StreamType(t)      : return lift_stream(cx, load_int(cx, ptr, 4), t)
    case FutureType(t)      : return lift_future(cx, load_int(cx, ptr, 4), t)

def load_int(cx, ptr, nbytes, signed = False):
  return int.from_bytes(cx.opts.memory[ptr : ptr+nbytes], 'little', signed = signed)

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

String = tuple[str, str, int]

def load_string(cx, ptr) -> String:
  begin = load_int(cx, ptr, 4)
  tagged_code_units = load_int(cx, ptr + 4, 4)
  return load_string_from_range(cx, begin, tagged_code_units)

UTF16_TAG = 1 << 31

def load_string_from_range(cx, ptr, tagged_code_units) -> String:
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

def lift_error_context(cx, i):
  return cx.inst.error_contexts.get(i)

def load_list(cx, ptr, elem_type, maybe_length):
  if maybe_length is not None:
    return load_list_from_valid_range(cx, ptr, maybe_length, elem_type)
  begin = load_int(cx, ptr, 4)
  length = load_int(cx, ptr + 4, 4)
  return load_list_from_range(cx, begin, length, elem_type)

def load_list_from_range(cx, ptr, length, elem_type):
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + length * elem_size(elem_type) > len(cx.opts.memory))
  return load_list_from_valid_range(cx, ptr, length, elem_type)

def load_list_from_valid_range(cx, ptr, length, elem_type):
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
  if c.t is None:
    return { c.label: None }
  return { c.label: load(cx, ptr, c.t) }

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
  h = cx.inst.resources.remove(i)
  trap_if(h.rt is not t.rt)
  trap_if(h.num_lends != 0)
  trap_if(not h.own)
  return h.rep

def lift_borrow(cx, i, t):
  assert(isinstance(cx.borrow_scope, Subtask))
  h = cx.inst.resources.get(i)
  trap_if(h.rt is not t.rt)
  cx.borrow_scope.add_lender(h)
  return h.rep

def lift_stream(cx, i, t):
  return lift_async_value(ReadableStreamEnd, WritableStreamEnd, cx, i, t)

def lift_future(cx, i, t):
  v = lift_async_value(ReadableFutureEnd, WritableFutureEnd, cx, i, t)
  trap_if(v.closed())
  return v

def lift_async_value(ReadableEndT, WritableEndT, cx, i, t):
  assert(not contains_borrow(t))
  e = cx.inst.waitables.get(i)
  match e:
    case ReadableEndT():
      trap_if(e.copying)
      cx.inst.waitables.remove(i)
    case WritableEndT():
      trap_if(e.paired)
      e.paired = True
    case _:
      trap()
  trap_if(e.stream.t != t)
  return e.stream

### Storing

def store(cx, v, t, ptr):
  assert(ptr == align_to(ptr, alignment(t)))
  assert(ptr + elem_size(t) <= len(cx.opts.memory))
  match despecialize(t):
    case BoolType()         : store_int(cx, int(bool(v)), ptr, 1)
    case U8Type()           : store_int(cx, v, ptr, 1)
    case U16Type()          : store_int(cx, v, ptr, 2)
    case U32Type()          : store_int(cx, v, ptr, 4)
    case U64Type()          : store_int(cx, v, ptr, 8)
    case S8Type()           : store_int(cx, v, ptr, 1, signed = True)
    case S16Type()          : store_int(cx, v, ptr, 2, signed = True)
    case S32Type()          : store_int(cx, v, ptr, 4, signed = True)
    case S64Type()          : store_int(cx, v, ptr, 8, signed = True)
    case F32Type()          : store_int(cx, encode_float_as_i32(v), ptr, 4)
    case F64Type()          : store_int(cx, encode_float_as_i64(v), ptr, 8)
    case CharType()         : store_int(cx, char_to_i32(v), ptr, 4)
    case StringType()       : store_string(cx, v, ptr)
    case ErrorContextType() : store_int(cx, lower_error_context(cx, v), ptr, 4)
    case ListType(t, l)     : store_list(cx, v, ptr, t, l)
    case RecordType(fields) : store_record(cx, v, ptr, fields)
    case VariantType(cases) : store_variant(cx, v, ptr, cases)
    case FlagsType(labels)  : store_flags(cx, v, ptr, labels)
    case OwnType()          : store_int(cx, lower_own(cx, v, t), ptr, 4)
    case BorrowType()       : store_int(cx, lower_borrow(cx, v, t), ptr, 4)
    case StreamType(t)      : store_int(cx, lower_stream(cx, v, t), ptr, 4)
    case FutureType(t)      : store_int(cx, lower_future(cx, v, t), ptr, 4)

def store_int(cx, v, ptr, nbytes, signed = False):
  cx.opts.memory[ptr : ptr+nbytes] = int.to_bytes(v, nbytes, 'little', signed = signed)

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

def store_string(cx, v: String, ptr):
  begin, tagged_code_units = store_string_into_range(cx, v)
  store_int(cx, begin, ptr, 4)
  store_int(cx, tagged_code_units, ptr + 4, 4)

def store_string_into_range(cx, v: String):
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

def lower_error_context(cx, v):
  return cx.inst.error_contexts.add(v)

def store_list(cx, v, ptr, elem_type, maybe_length):
  if maybe_length is not None:
    assert(maybe_length == len(v))
    store_list_into_valid_range(cx, v, ptr, elem_type)
    return
  begin, length = store_list_into_range(cx, v, elem_type)
  store_int(cx, begin, ptr, 4)
  store_int(cx, length, ptr + 4, 4)

def store_list_into_range(cx, v, elem_type):
  byte_length = len(v) * elem_size(elem_type)
  trap_if(byte_length >= (1 << 32))
  ptr = cx.opts.realloc(0, 0, alignment(elem_type), byte_length)
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + byte_length > len(cx.opts.memory))
  store_list_into_valid_range(cx, v, ptr, elem_type)
  return (ptr, len(v))

def store_list_into_valid_range(cx, v, ptr, elem_type):
  for i,e in enumerate(v):
    store(cx, e, elem_type, ptr + i * elem_size(elem_type))

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
  [label] = v.keys()
  [index] = [i for i,c in enumerate(cases) if c.label == label]
  [value] = v.values()
  return (index, value)

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
  h = ResourceHandle(t.rt, rep, own = True)
  return cx.inst.resources.add(h)

def lower_borrow(cx, rep, t):
  assert(isinstance(cx.borrow_scope, Task))
  if cx.inst is t.rt.impl:
    return rep
  h = ResourceHandle(t.rt, rep, own = False, borrow_scope = cx.borrow_scope)
  h.borrow_scope.num_borrows += 1
  return cx.inst.resources.add(h)

def lower_stream(cx, v, t):
  return lower_async_value(ReadableStreamEnd, WritableStreamEnd, cx, v, t)

def lower_future(cx, v, t):
  assert(not v.closed())
  return lower_async_value(ReadableFutureEnd, WritableFutureEnd, cx, v, t)

def lower_async_value(ReadableEndT, WritableEndT, cx, v, t):
  assert(isinstance(v, ReadableStream))
  assert(not contains_borrow(t))
  if isinstance(v, ReadableStreamGuestImpl) and cx.inst is v.impl:
    for i,e in enumerate(cx.inst.waitables.array):
      if isinstance(e, WritableEndT) and e.stream is v:
        break
    assert(e.paired)
    e.paired = False
    assert(i <= Table.MAX_LENGTH < 2**31)
    return i | (2**31)
  else:
    return cx.inst.waitables.add(ReadableEndT(v))

### Flattening

MAX_FLAT_PARAMS = 16
MAX_FLAT_RESULTS = 1

def flatten_functype(opts, ft, context):
  flat_params = flatten_types(ft.param_types())
  flat_results = flatten_types(ft.result_types())
  if opts.sync:
    if len(flat_params) > MAX_FLAT_PARAMS:
      flat_params = ['i32']
    if len(flat_results) > MAX_FLAT_RESULTS:
      match context:
        case 'lift':
          flat_results = ['i32']
        case 'lower':
          flat_params += ['i32']
          flat_results = []
    return CoreFuncType(flat_params, flat_results)
  else:
    match context:
      case 'lift':
        if opts.callback:
          flat_results = ['i32']
        else:
          flat_results = []
      case 'lower':
        if len(flat_params) > 1:
          flat_params = ['i32']
        if len(flat_results) > 0:
          flat_params += ['i32']
        flat_results = ['i32']
    return CoreFuncType(flat_params, flat_results)

def flatten_types(ts):
  return [ft for t in ts for ft in flatten_type(t)]

def flatten_type(t):
  match despecialize(t):
    case BoolType()                       : return ['i32']
    case U8Type() | U16Type() | U32Type() : return ['i32']
    case S8Type() | S16Type() | S32Type() : return ['i32']
    case S64Type() | U64Type()            : return ['i64']
    case F32Type()                        : return ['f32']
    case F64Type()                        : return ['f64']
    case CharType()                       : return ['i32']
    case StringType()                     : return ['i32', 'i32']
    case ErrorContextType()               : return ['i32']
    case ListType(t, l)                   : return flatten_list(t, l)
    case RecordType(fields)               : return flatten_record(fields)
    case VariantType(cases)               : return flatten_variant(cases)
    case FlagsType(labels)                : return ['i32']
    case OwnType() | BorrowType()         : return ['i32']
    case StreamType() | FutureType()      : return ['i32']

def flatten_list(elem_type, maybe_length):
  if maybe_length is not None:
    return flatten_type(elem_type) * maybe_length
  return ['i32', 'i32']

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

class CoreValueIter:
  values: list[int|float]
  i: int

  def __init__(self, vs):
    self.values = vs
    self.i = 0

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

  def done(self):
    return self.i == len(self.values)

def lift_flat(cx, vi, t):
  match despecialize(t):
    case BoolType()         : return convert_int_to_bool(vi.next('i32'))
    case U8Type()           : return lift_flat_unsigned(vi, 32, 8)
    case U16Type()          : return lift_flat_unsigned(vi, 32, 16)
    case U32Type()          : return lift_flat_unsigned(vi, 32, 32)
    case U64Type()          : return lift_flat_unsigned(vi, 64, 64)
    case S8Type()           : return lift_flat_signed(vi, 32, 8)
    case S16Type()          : return lift_flat_signed(vi, 32, 16)
    case S32Type()          : return lift_flat_signed(vi, 32, 32)
    case S64Type()          : return lift_flat_signed(vi, 64, 64)
    case F32Type()          : return canonicalize_nan32(vi.next('f32'))
    case F64Type()          : return canonicalize_nan64(vi.next('f64'))
    case CharType()         : return convert_i32_to_char(cx, vi.next('i32'))
    case StringType()       : return lift_flat_string(cx, vi)
    case ErrorContextType() : return lift_error_context(cx, vi.next('i32'))
    case ListType(t, l)     : return lift_flat_list(cx, vi, t, l)
    case RecordType(fields) : return lift_flat_record(cx, vi, fields)
    case VariantType(cases) : return lift_flat_variant(cx, vi, cases)
    case FlagsType(labels)  : return lift_flat_flags(vi, labels)
    case OwnType()          : return lift_own(cx, vi.next('i32'), t)
    case BorrowType()       : return lift_borrow(cx, vi.next('i32'), t)
    case StreamType(t)      : return lift_stream(cx, vi.next('i32'), t)
    case FutureType(t)      : return lift_future(cx, vi.next('i32'), t)

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

def lift_flat_list(cx, vi, elem_type, maybe_length):
  if maybe_length is not None:
    a = []
    for i in range(maybe_length):
      a.append(lift_flat(cx, vi, elem_type))
    return a
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
  return { c.label: v }

def wrap_i64_to_i32(i):
  assert(0 <= i < (1 << 64))
  return i % (1 << 32)

def lift_flat_flags(vi, labels):
  assert(0 < len(labels) <= 32)
  i = vi.next('i32')
  return unpack_flags_from_int(i, labels)

### Flat Lowering

def lower_flat(cx, v, t):
  match despecialize(t):
    case BoolType()         : return [int(v)]
    case U8Type()           : return [v]
    case U16Type()          : return [v]
    case U32Type()          : return [v]
    case U64Type()          : return [v]
    case S8Type()           : return lower_flat_signed(v, 32)
    case S16Type()          : return lower_flat_signed(v, 32)
    case S32Type()          : return lower_flat_signed(v, 32)
    case S64Type()          : return lower_flat_signed(v, 64)
    case F32Type()          : return [maybe_scramble_nan32(v)]
    case F64Type()          : return [maybe_scramble_nan64(v)]
    case CharType()         : return [char_to_i32(v)]
    case StringType()       : return lower_flat_string(cx, v)
    case ErrorContextType() : return lower_error_context(cx, v)
    case ListType(t, l)     : return lower_flat_list(cx, v, t, l)
    case RecordType(fields) : return lower_flat_record(cx, v, fields)
    case VariantType(cases) : return lower_flat_variant(cx, v, cases)
    case FlagsType(labels)  : return lower_flat_flags(v, labels)
    case OwnType()          : return [lower_own(cx, v, t)]
    case BorrowType()       : return [lower_borrow(cx, v, t)]
    case StreamType(t)      : return [lower_stream(cx, v, t)]
    case FutureType(t)      : return [lower_future(cx, v, t)]

def lower_flat_signed(i, core_bits):
  if i < 0:
    i += (1 << core_bits)
  return [i]

def lower_flat_string(cx, v):
  ptr, packed_length = store_string_into_range(cx, v)
  return [ptr, packed_length]

def lower_flat_list(cx, v, elem_type, maybe_length):
  if maybe_length is not None:
    assert(maybe_length == len(v))
    flat = []
    for e in v:
      flat += lower_flat(cx, e, elem_type)
    return flat
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
  assert(0 < len(labels) <= 32)
  return [pack_flags_into_int(v, labels)]

### Lifting and Lowering Values

def lift_flat_values(cx, max_flat, vi, ts):
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    return lift_heap_values(cx, vi, ts)
  else:
    return [ lift_flat(cx, vi, t) for t in ts ]

def lift_heap_values(cx, vi, ts):
  ptr = vi.next('i32')
  tuple_type = TupleType(ts)
  trap_if(ptr != align_to(ptr, alignment(tuple_type)))
  trap_if(ptr + elem_size(tuple_type) > len(cx.opts.memory))
  return list(load(cx, ptr, tuple_type).values())

def lower_flat_values(cx, max_flat, vs, ts, out_param = None):
  cx.inst.may_leave = False
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    flat_vals = lower_heap_values(cx, vs, ts, out_param)
  else:
    flat_vals = []
    for i in range(len(vs)):
      flat_vals += lower_flat(cx, vs[i], ts[i])
  cx.inst.may_leave = True
  return flat_vals

def lower_heap_values(cx, vs, ts, out_param):
  tuple_type = TupleType(ts)
  tuple_value = {str(i): v for i,v in enumerate(vs)}
  if out_param is None:
    ptr = cx.opts.realloc(0, 0, alignment(tuple_type), elem_size(tuple_type))
    flat_vals = [ptr]
  else:
    ptr = out_param.next('i32')
    flat_vals = []
  trap_if(ptr != align_to(ptr, alignment(tuple_type)))
  trap_if(ptr + elem_size(tuple_type) > len(cx.opts.memory))
  store(cx, tuple_value, tuple_type, ptr)
  return flat_vals

### `canon lift`

async def canon_lift(opts, inst, ft, callee, caller, on_start, on_return, on_block):
  task = Task(opts, inst, ft, caller, on_return, on_block)
  flat_args = await task.enter(on_start)
  flat_ft = flatten_functype(opts, ft, 'lift')
  assert(types_match_values(flat_ft.params, flat_args))
  if opts.sync:
    flat_results = await call_and_trap_on_throw(callee, task, flat_args)
    if not opts.always_task_return:
      assert(types_match_values(flat_ft.results, flat_results))
      task.return_(flat_results)
      if opts.post_return is not None:
        [] = await call_and_trap_on_throw(opts.post_return, task, flat_results)
    task.exit()
    return
  else:
    if not opts.callback:
      [] = await call_and_trap_on_throw(callee, task, flat_args)
      assert(types_match_values(flat_ft.results, []))
      task.exit()
      return
    else:
      [packed] = await call_and_trap_on_throw(callee, task, flat_args)
      s = None
      while True:
        code,si = unpack_callback_result(packed)
        if si != 0:
          s = task.inst.waitable_sets.get(si)
        match code:
          case CallbackCode.EXIT:
            task.exit()
            return
          case CallbackCode.YIELD:
            await task.yield_(sync = False)
            e = None
          case CallbackCode.WAIT:
            trap_if(not s)
            e = await task.wait_on(s.wait(), sync = False)
          case CallbackCode.POLL:
            trap_if(not s)
            await task.yield_(sync = False)
            e = s.poll()
        if e:
          event, p1, p2 = e
        else:
          event, p1, p2 = (EventCode.NONE, 0, 0)
        [packed] = await call_and_trap_on_throw(opts.callback, task, [event, p1, p2])

class CallbackCode(IntEnum):
  EXIT = 0
  YIELD = 1
  WAIT = 2
  POLL = 3
  MAX = 3

def unpack_callback_result(packed):
  code = packed & 0xf
  trap_if(code > CallbackCode.MAX)
  assert(packed < 2**32)
  assert(Table.MAX_LENGTH < 2**28)
  waitable_set_index = packed >> 4
  return (CallbackCode(code), waitable_set_index)

async def call_and_trap_on_throw(callee, task, args):
  try:
    return await callee(task, args)
  except CoreWebAssemblyException:
    trap()

### `canon lower`

async def canon_lower(opts, ft, callee, task, flat_args):
  trap_if(not task.inst.may_leave)
  subtask = Subtask()
  cx = LiftLowerContext(opts, task.inst, subtask)

  flat_ft = flatten_functype(opts, ft, 'lower')
  assert(types_match_values(flat_ft.params, flat_args))
  flat_args = CoreValueIter(flat_args)
  flat_results = None
  on_progress = lambda: None
  def on_start():
    subtask.state = CallState.STARTED
    on_progress()
    return lift_flat_values(cx, max_flat_params, flat_args, ft.param_types())
  def on_return(vs):
    subtask.state = CallState.RETURNED
    on_progress()
    nonlocal flat_results
    flat_results = lower_flat_values(cx, max_flat_results, vs, ft.result_types(), flat_args)
    assert(flat_args.done())

  if opts.sync:
    assert(not contains_async_value(ft))
    max_flat_params = MAX_FLAT_PARAMS
    max_flat_results = MAX_FLAT_RESULTS
    await task.call_sync(callee, task, on_start, on_return)
    assert(subtask.state == CallState.RETURNED)
    subtask.finish()
    assert(types_match_values(flat_ft.results, flat_results))
  else:
    max_flat_params = 1
    max_flat_results = 0
    await task.call_async(callee, task, on_start, on_return)
    match subtask.state:
      case CallState.RETURNED:
        subtask.finish()
        flat_results = [0]
      case _:
        subtaski = subtask.add_to_waitables(task)
        def on_progress():
          def subtask_event():
            if subtask.state == CallState.RETURNED:
              subtask.finish()
            return (EventCode(subtask.state), subtaski, 0)
          subtask.set_event(subtask_event)
        assert(0 < subtaski <= Table.MAX_LENGTH < 2**28)
        assert(0 <= int(subtask.state) < 2**4)
        flat_results = [int(subtask.state) | (subtaski << 4)]

  return flat_results

### `canon resource.new`

async def canon_resource_new(rt, task, rep):
  trap_if(not task.inst.may_leave)
  h = ResourceHandle(rt, rep, own = True)
  i = task.inst.resources.add(h)
  return [i]

### `canon resource.drop`

async def canon_resource_drop(rt, sync, task, i):
  trap_if(not task.inst.may_leave)
  inst = task.inst
  h = inst.resources.remove(i)
  trap_if(h.rt is not rt)
  trap_if(h.num_lends != 0)
  flat_results = [] if sync else [0]
  if h.own:
    assert(h.borrow_scope is None)
    if inst is rt.impl:
      if rt.dtor:
        await rt.dtor(h.rep)
    else:
      if rt.dtor:
        caller_opts = CanonicalOptions(sync = sync)
        callee_opts = CanonicalOptions(sync = rt.dtor_sync, callback = rt.dtor_callback)
        ft = FuncType([U32Type()],[])
        callee = partial(canon_lift, callee_opts, rt.impl, ft, rt.dtor)
        flat_results = await canon_lower(caller_opts, ft, callee, task, [h.rep])
      else:
        task.trap_if_on_the_stack(rt.impl)
  else:
    h.borrow_scope.num_borrows -= 1
  return flat_results

### `canon resource.rep`

async def canon_resource_rep(rt, task, i):
  h = task.inst.resources.get(i)
  trap_if(h.rt is not rt)
  return [h.rep]

### 🔀 `canon context.get`

async def canon_context_get(t, i, task):
  assert(t == 'i32')
  assert(i < ContextLocalStorage.LENGTH)
  return [task.context.get(i)]

### 🔀 `canon context.set`

async def canon_context_set(t, i, task, v):
  assert(t == 'i32')
  assert(i < ContextLocalStorage.LENGTH)
  task.context.set(i, v)
  return []

### 🔀 `canon backpressure.set`

async def canon_backpressure_set(task, flat_args):
  trap_if(task.opts.sync)
  task.inst.backpressure = bool(flat_args[0])
  return []

### 🔀 `canon task.return`

async def canon_task_return(task, result_type, opts: LiftOptions, flat_args):
  trap_if(not task.inst.may_leave)
  trap_if(task.opts.sync and not task.opts.always_task_return)
  trap_if(result_type != task.ft.results)
  trap_if(not LiftOptions.equal(opts, task.opts))
  task.return_(flat_args)
  return []

### 🔀 `canon yield`

async def canon_yield(sync, task):
  trap_if(not task.inst.may_leave)
  trap_if(task.opts.callback and not sync)
  await task.yield_(sync)
  return []

### 🔀 `canon waitable-set.new`

async def canon_waitable_set_new(task):
  trap_if(not task.inst.may_leave)
  return [ task.inst.waitable_sets.add(WaitableSet()) ]

### 🔀 `canon waitable-set.wait`

async def canon_waitable_set_wait(sync, mem, task, si, ptr):
  trap_if(not task.inst.may_leave)
  trap_if(task.opts.callback and not sync)
  s = task.inst.waitable_sets.get(si)
  e = await task.wait_on(s.wait(), sync)
  return unpack_event(mem, task, ptr, e)

def unpack_event(mem, task, ptr, e: EventTuple):
  event, p1, p2 = e
  cx = LiftLowerContext(LiftLowerOptions(memory = mem), task.inst)
  store(cx, p1, U32Type(), ptr)
  store(cx, p2, U32Type(), ptr + 4)
  return [event]

### 🔀 `canon waitable-set.poll`

async def canon_waitable_set_poll(sync, mem, task, si, ptr):
  trap_if(not task.inst.may_leave)
  trap_if(task.opts.callback and not sync)
  s = task.inst.waitable_sets.get(si)
  await task.yield_(sync)
  if (e := s.poll()):
    return unpack_event(mem, task, ptr, e)
  return [EventCode.NONE]

### 🔀 `canon waitable-set.drop`

async def canon_waitable_set_drop(task, i):
  trap_if(not task.inst.may_leave)
  s = task.inst.waitable_sets.remove(i)
  s.drop()
  return []

### 🔀 `canon waitable.join`

async def canon_waitable_join(task, wi, si):
  trap_if(not task.inst.may_leave)
  w = task.inst.waitables.get(wi)
  if si == 0:
    w.join(None)
  else:
    w.join(task.inst.waitable_sets.get(si))
  return []

### 🔀 `canon subtask.drop`

async def canon_subtask_drop(task, i):
  trap_if(not task.inst.may_leave)
  s = task.inst.waitables.remove(i)
  trap_if(not isinstance(s, Subtask))
  s.drop()
  return []

### 🔀 `canon {stream,future}.new`

async def canon_stream_new(elem_type, task):
  trap_if(not task.inst.may_leave)
  stream = ReadableStreamGuestImpl(elem_type, task.inst)
  return [ task.inst.waitables.add(WritableStreamEnd(stream)) ]

async def canon_future_new(t, task):
  trap_if(not task.inst.may_leave)
  future = ReadableStreamGuestImpl(t, task.inst)
  return [ task.inst.waitables.add(WritableFutureEnd(future)) ]

### 🔀 `canon {stream,future}.{read,write}`

async def canon_stream_read(t, opts, task, i, ptr, n):
  return await copy(ReadableStreamEnd, WritableBufferGuestImpl, EventCode.STREAM_READ,
                    t, opts, task, i, ptr, n)

async def canon_stream_write(t, opts, task, i, ptr, n):
  return await copy(WritableStreamEnd, ReadableBufferGuestImpl, EventCode.STREAM_WRITE,
                    t, opts, task, i, ptr, n)

async def canon_future_read(t, opts, task, i, ptr):
  return await copy(ReadableFutureEnd, WritableBufferGuestImpl, EventCode.FUTURE_READ,
                    t, opts, task, i, ptr, 1)

async def canon_future_write(t, opts, task, i, ptr):
  return await copy(WritableFutureEnd, ReadableBufferGuestImpl, EventCode.FUTURE_WRITE,
                    t, opts, task, i, ptr, 1)

async def copy(EndT, BufferT, event_code, t, opts, task, i, ptr, n):
  trap_if(not task.inst.may_leave)
  e = task.inst.waitables.get(i)
  trap_if(not isinstance(e, EndT))
  trap_if(e.stream.t != t)
  trap_if(e.copying)
  assert(not contains_borrow(t))
  cx = LiftLowerContext(opts, task.inst, borrow_scope = None)
  buffer = BufferT(t, cx, ptr, n)
  if opts.sync:
    final_revoke_buffer = None
    def on_partial_copy(revoke_buffer):
      nonlocal final_revoke_buffer
      final_revoke_buffer = revoke_buffer
      if not async_copy.done():
        async_copy.set_result(None)
    on_copy_done = partial(on_partial_copy, revoke_buffer = lambda:())
    if e.copy(buffer, on_partial_copy, on_copy_done) != 'done':
      async_copy = asyncio.Future()
      await task.wait_on(async_copy, sync = True)
      final_revoke_buffer()
  else:
    def copy_event(revoke_buffer):
      revoke_buffer()
      e.copying = False
      return (event_code, i, pack_copy_result(task, buffer, e))
    def on_partial_copy(revoke_buffer):
      e.set_event(partial(copy_event, revoke_buffer))
    def on_copy_done():
      e.set_event(partial(copy_event, revoke_buffer = lambda:()))
    if e.copy(buffer, on_partial_copy, on_copy_done) != 'done':
      e.copying = True
      return [BLOCKED]
  return [pack_copy_result(task, buffer, e)]

BLOCKED = 0xffff_ffff
CLOSED  = 0x8000_0000

def pack_copy_result(task, buffer, e):
  if buffer.progress or not e.stream.closed():
    assert(buffer.progress <= Buffer.MAX_LENGTH < BLOCKED)
    assert(not (buffer.progress & CLOSED))
    return buffer.progress
  else:
    return CLOSED

### 🔀 `canon {stream,future}.cancel-{read,write}`

async def canon_stream_cancel_read(t, sync, task, i):
  return await cancel_copy(ReadableStreamEnd, EventCode.STREAM_READ, t, sync, task, i)

async def canon_stream_cancel_write(t, sync, task, i):
  return await cancel_copy(WritableStreamEnd, EventCode.STREAM_WRITE, t, sync, task, i)

async def canon_future_cancel_read(t, sync, task, i):
  return await cancel_copy(ReadableFutureEnd, EventCode.FUTURE_READ, t, sync, task, i)

async def canon_future_cancel_write(t, sync, task, i):
  return await cancel_copy(WritableFutureEnd, EventCode.FUTURE_WRITE, t, sync, task, i)

async def cancel_copy(EndT, event_code, t, sync, task, i):
  trap_if(not task.inst.may_leave)
  e = task.inst.waitables.get(i)
  trap_if(not isinstance(e, EndT))
  trap_if(e.stream.t != t)
  trap_if(not e.copying)
  if not e.has_pending_event():
    e.stream.cancel()
    if not e.has_pending_event():
      if sync:
        await task.wait_on(e.wait_for_pending_event(), sync = True)
      else:
        return [BLOCKED]
  code,index,payload = e.get_event()
  assert(not e.copying and code == event_code and index == i)
  return [payload]

### 🔀 `canon {stream,future}.close-{readable,writable}`

async def canon_stream_close_readable(t, task, i):
  return await close(ReadableStreamEnd, t, task, i)

async def canon_stream_close_writable(t, task, hi):
  return await close(WritableStreamEnd, t, task, hi)

async def canon_future_close_readable(t, task, i):
  return await close(ReadableFutureEnd, t, task, i)

async def canon_future_close_writable(t, task, hi):
  return await close(WritableFutureEnd, t, task, hi)

async def close(EndT, t, task, hi):
  trap_if(not task.inst.may_leave)
  e = task.inst.waitables.remove(hi)
  trap_if(not isinstance(e, EndT))
  trap_if(e.stream.t != t)
  e.drop()
  return []

### 📝 `canon error-context.new`

@dataclass
class ErrorContext:
  debug_message: String

async def canon_error_context_new(opts, task, ptr, tagged_code_units):
  trap_if(not task.inst.may_leave)
  if DETERMINISTIC_PROFILE or random.randint(0,1):
    s = String(('', 'utf8', 0))
  else:
    cx = LiftLowerContext(opts, task.inst)
    s = load_string_from_range(cx, ptr, tagged_code_units)
    s = host_defined_transformation(s)
  i = task.inst.error_contexts.add(ErrorContext(s))
  return [i]

### 📝 `canon error-context.debug-message`

async def canon_error_context_debug_message(opts, task, i, ptr):
  trap_if(not task.inst.may_leave)
  errctx = task.inst.error_contexts.get(i)
  cx = LiftLowerContext(opts, task.inst)
  store_string(cx, errctx.debug_message, ptr)
  return []

### 📝 `canon error-context.drop`

async def canon_error_context_drop(task, i):
  trap_if(not task.inst.may_leave)
  task.inst.error_contexts.remove(i)
  return []
