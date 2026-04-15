# After the Boilerplate section, this file is ordered to line up with the code
# blocks in ../CanonicalABI.md (split by # comment lines). If you update this
# file, don't forget to update ../CanonicalABI.md.

### Boilerplate

from __future__ import annotations
from dataclasses import dataclass
from functools import partial
from typing import Any, Optional, Callable, TypeVar, Generic, Literal
from enum import Enum, IntEnum
import math
import struct
import random
import threading

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

CoreValType = int | float

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
  result: list[ValType|tuple[str,ValType]]
  async_: bool = False
  def param_types(self):
    return self.extract_types(self.params)
  def result_type(self):
    return self.extract_types(self.result)
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

# START

### Embedding API

class Store:
  waiting: list[Thread]

  def __init__(self):
    self.waiting = []

  def invoke(self, f: FuncInst, caller: Optional[Supertask], on_start, on_resolve) -> Call:
    host_caller = Supertask()
    host_caller.inst = None
    host_caller.supertask = caller
    return f(host_caller, on_start, on_resolve)

  def tick(self):
    random.shuffle(self.waiting)
    for thread in self.waiting:
      if thread.ready():
        thread.resume(Cancelled.FALSE)
        return

FuncInst: Callable[[Optional[Supertask], OnStart, OnResolve], Call]

OnStart = Callable[[], list[any]]
OnResolve = Callable[[Optional[list[any]]], None]

class Supertask:
  inst: Optional[ComponentInstance]
  supertask: Optional[Supertask]

class Call:
  request_cancellation: Callable[[], None]


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

def ptr_size(ptr_type):
  match ptr_type:
    case 'i32':
      return 4
    case 'i64':
      return 8

@dataclass
class MemInst:
  bytes: bytearray
  addrtype: Literal['i32', 'i64']

  def __getitem__(self, i):
    return self.bytes[i]

  def __setitem__(self, i, v):
    self.bytes[i] = v

  def __len__(self):
    return len(self.bytes)

  def ptr_type(self):
    return self.addrtype

  def ptr_size(self):
    return ptr_size(self.ptr_type())

@dataclass
class LiftOptions:
  string_encoding: str = 'utf8'
  memory: Optional[MemInst] = None

  def equal(lhs, rhs):
    return lhs.string_encoding == rhs.string_encoding and \
           lhs.memory is rhs.memory

@dataclass
class LiftLowerOptions(LiftOptions):
  realloc: Optional[Callable] = None

@dataclass
class CanonicalOptions(LiftLowerOptions):
  post_return: Optional[Callable] = None
  async_: bool = False
  callback: Optional[Callable] = None

### Runtime State

#### Component Instance State

class ComponentInstance:
  store: Store
  parent: Optional[ComponentInstance]
  handles: Table[ResourceHandle | Waitable | WaitableSet | ErrorContext]
  threads: Table[Thread]
  may_leave: bool
  backpressure: int
  exclusive: Optional[Task]
  num_waiting_to_enter: int

  def __init__(self, store, parent = None):
    assert(parent is None or parent.store is store)
    self.store = store
    self.parent = parent
    self.handles = Table()
    self.threads = Table()
    self.may_leave = True
    self.backpressure = 0
    self.exclusive = None
    self.num_waiting_to_enter = 0

  def reflexive_ancestors(self) -> set[ComponentInstance]:
    s = set()
    inst = self
    while inst is not None:
      s.add(inst)
      inst = inst.parent
    return s

  def is_reflexive_ancestor_of(self, other):
    while other is not None:
      if self is other:
        return True
      other = other.parent
    return False

def call_might_be_recursive(caller: Supertask, callee_inst: ComponentInstance):
  if caller.inst is None:
    while caller is not None:
      if caller.inst and caller.inst.reflexive_ancestors() & callee_inst.reflexive_ancestors():
        return True
      caller = caller.supertask
    return False
  else:
    return (caller.inst.is_reflexive_ancestor_of(callee_inst) or
            callee_inst.is_reflexive_ancestor_of(caller.inst))

#### Table State

class Table:
  array: list[any]
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
  dtor_async: bool
  dtor_callback: Optional[Callable]

  def __init__(self, impl, dtor = None, dtor_async = False, dtor_callback = None):
    self.impl = impl
    self.dtor = dtor
    self.dtor_async = dtor_async
    self.dtor_callback = dtor_callback

#### Thread State

class Cancelled(IntEnum):
  FALSE = 0
  TRUE = 1

class Thread:
  task: Task
  fiber: threading.Thread
  fiber_lock: threading.Lock
  parent_lock: Optional[threading.Lock]
  ready_func: Optional[Callable[[], bool]]
  cancellable: bool
  cancelled: Cancelled
  index: Optional[int]
  storage: tuple[int,int]

  def running(self):
    return self.parent_lock is not None

  def suspended(self):
    return not self.running() and self.ready_func is None

  def waiting(self):
    return not self.running() and self.ready_func is not None

  def ready(self):
    assert(self.waiting())
    return self.ready_func()

  def __init__(self, task, thread_func):
    self.task = task
    self.fiber_lock = threading.Lock()
    self.fiber_lock.acquire()
    self.parent_lock = None
    self.ready_func = None
    self.cancellable = False
    self.cancelled = Cancelled.FALSE
    self.index = None
    self.storage = [0,0]
    def fiber_func():
      self.fiber_lock.acquire()
      thread_func(self)
      self.parent_lock.release()
    self.fiber = threading.Thread(target = fiber_func)
    self.fiber.start()
    assert(self.suspended())

  def resume_later(self):
    assert(self.suspended())
    self.ready_func = lambda: True
    self.task.inst.store.waiting.append(self)
    assert(self.ready())

  def resume(self, cancelled):
    assert(not self.running() and (self.cancellable or not cancelled))
    if self.waiting():
      assert(cancelled or self.ready())
      self.ready_func = None
      self.task.inst.store.waiting.remove(self)
    assert(self.cancellable or not cancelled)
    self.cancelled = cancelled
    self.parent_lock = threading.Lock()
    self.parent_lock.acquire()
    self.fiber_lock.release()
    self.parent_lock.acquire()
    self.parent_lock = None
    assert(not self.running())

  def suspend(self, cancellable) -> Cancelled:
    assert(self.running() and self.task.may_block())
    if self.task.deliver_pending_cancel(cancellable):
      return Cancelled.TRUE
    self.cancellable = cancellable
    self.parent_lock.release()
    self.fiber_lock.acquire()
    assert(self.running() and (cancellable or not self.cancelled))
    return self.cancelled

  def wait_until(self, ready_func, cancellable = False) -> Cancelled:
    assert(self.running() and self.task.may_block())
    if self.task.deliver_pending_cancel(cancellable):
      return Cancelled.TRUE
    if ready_func() and not DETERMINISTIC_PROFILE and random.randint(0,1):
      return Cancelled.FALSE
    self.ready_func = ready_func
    self.task.inst.store.waiting.append(self)
    return self.suspend(cancellable)

  def yield_until(self, ready_func, cancellable) -> Cancelled:
    assert(self.running())
    if self.task.may_block():
      return self.wait_until(ready_func, cancellable)
    else:
      assert(ready_func())
      return Cancelled.FALSE

  def yield_(self, cancellable) -> Cancelled:
    return self.yield_until(lambda: True, cancellable)

  def switch_to(self, cancellable, other: Thread) -> Cancelled:
    assert(self.running() and other.suspended())
    if self.task.deliver_pending_cancel(cancellable):
      return Cancelled.TRUE
    self.cancellable = cancellable
    other.cancelled = Cancelled.FALSE
    assert(self.parent_lock and not other.parent_lock)
    other.parent_lock = self.parent_lock
    self.parent_lock = None
    assert(not self.running() and other.running())
    other.fiber_lock.release()
    self.fiber_lock.acquire()
    assert(self.running() and (cancellable or not self.cancelled))
    return self.cancelled

  def yield_to(self, cancellable, other: Thread) -> Cancelled:
    assert(self.running() and other.suspended())
    self.ready_func = lambda: True
    self.task.inst.store.waiting.append(self)
    return self.switch_to(cancellable, other)

#### Waitable State

class EventCode(IntEnum):
  NONE = 0
  SUBTASK = 1
  STREAM_READ = 2
  STREAM_WRITE = 3
  FUTURE_READ = 4
  FUTURE_WRITE = 5
  TASK_CANCELLED = 6

EventTuple = tuple[EventCode, int, int]

class Waitable:
  pending_event: Optional[Callable[[], EventTuple]]
  wset: Optional[WaitableSet]

  def __init__(self):
    self.pending_event = None
    self.wset = None

  def set_pending_event(self, pending_event):
    self.pending_event = pending_event

  def has_pending_event(self):
    return bool(self.pending_event)

  def get_pending_event(self) -> EventTuple:
    pending_event = self.pending_event
    self.pending_event = None
    return pending_event()

  def join(self, wset):
    if self.wset:
      self.wset.elems.remove(self)
    self.wset = wset
    if wset:
      wset.elems.append(self)

  def drop(self):
    assert(not self.has_pending_event())
    self.join(None)

class WaitableSet:
  elems: list[Waitable]
  num_waiting: int

  def __init__(self):
    self.elems = []
    self.num_waiting = 0

  def has_pending_event(self):
    return any(w.has_pending_event() for w in self.elems)

  def get_pending_event(self) -> EventTuple:
    assert(self.has_pending_event())
    random.shuffle(self.elems)
    for w in self.elems:
      assert(self is w.wset)
      if w.has_pending_event():
        return w.get_pending_event()

  def wait_until(self, ready_func, thread, cancellable) -> EventTuple:
    def ready_and_has_event():
      return ready_func() and self.has_pending_event()
    self.num_waiting += 1
    if thread.wait_until(ready_and_has_event, cancellable) == Cancelled.TRUE:
      event = (EventCode.TASK_CANCELLED, 0, 0)
    else:
      event = self.get_pending_event()
    self.num_waiting -= 1
    return event

  def wait(self, thread, cancellable) -> EventTuple:
    return self.wait_until(lambda: True, thread, cancellable)

  def poll(self, thread, cancellable) -> EventTuple:
    if thread.task.deliver_pending_cancel(cancellable):
      return (EventCode.TASK_CANCELLED, 0, 0)
    elif not self.has_pending_event():
      return (EventCode.NONE, 0, 0)
    else:
      return self.get_pending_event()

  def drop(self):
    trap_if(len(self.elems) > 0)
    trap_if(self.num_waiting > 0)

#### Task State

class Task(Call, Supertask):
  class State(Enum):
    INITIAL = 1
    PENDING_CANCEL = 2
    CANCEL_DELIVERED = 3
    RESOLVED = 4

  state: State
  opts: CanonicalOptions
  inst: ComponentInstance
  ft: FuncType
  supertask: Supertask
  on_resolve: OnResolve
  num_borrows: int
  waiting_to_enter: Optional[Thread]
  threads: list[Thread]

  def __init__(self, opts, inst, ft, supertask, on_resolve):
    self.state = Task.State.INITIAL
    self.opts = opts
    self.inst = inst
    self.ft = ft
    self.supertask = supertask
    self.on_resolve = on_resolve
    self.num_borrows = 0
    self.waiting_to_enter = None
    self.threads = []

  def needs_exclusive(self):
    return not self.opts.async_ or self.opts.callback

  def may_block(self):
    return self.ft.async_ or self.state == Task.State.RESOLVED

  def enter(self, thread):
    if self.ft.async_:
      def has_backpressure():
        return self.inst.backpressure > 0 or (self.needs_exclusive() and bool(self.inst.exclusive))
      if has_backpressure() or self.inst.num_waiting_to_enter > 0:
        self.inst.num_waiting_to_enter += 1
        self.waiting_to_enter = thread
        cancelled = thread.wait_until(lambda: not has_backpressure(), cancellable = True)
        self.waiting_to_enter = None
        self.inst.num_waiting_to_enter -= 1
        if cancelled:
          self.cancel()
          return False
      if self.needs_exclusive():
        assert(self.inst.exclusive is None)
        self.inst.exclusive = self
    self.register_thread(thread)
    return True

  def register_thread(self, thread):
    assert(thread not in self.threads and thread.task is self)
    self.threads.append(thread)
    assert(thread.index is None)
    thread.index = self.inst.threads.add(thread)

  def exit(self, thread):
    self.unregister_thread(thread)
    if self.ft.async_ and self.needs_exclusive():
      assert(self.inst.exclusive is self)
      self.inst.exclusive = None

  def unregister_thread(self, thread):
    assert(thread in self.threads and thread.task is self)
    self.threads.remove(thread)
    if len(self.threads) == 0:
      trap_if(self.state != Task.State.RESOLVED)
      assert(self.num_borrows == 0)
    assert(thread.index is not None)
    self.inst.threads.remove(thread.index)

  def request_cancellation(self):
    if self.waiting_to_enter is not None:
      assert(not self.threads)
      self.state = Task.State.CANCEL_DELIVERED
      self.waiting_to_enter.resume(Cancelled.TRUE)
      return
    assert(self.state == Task.State.INITIAL)
    if not self.needs_exclusive() or not self.inst.exclusive or self.inst.exclusive is self:
      random.shuffle(self.threads)
      for thread in self.threads:
        if thread.cancellable:
          self.state = Task.State.CANCEL_DELIVERED
          thread.resume(Cancelled.TRUE)
          return
    self.state = Task.State.PENDING_CANCEL

  def deliver_pending_cancel(self, cancellable) -> bool:
    if cancellable and self.state == Task.State.PENDING_CANCEL:
      self.state = Task.State.CANCEL_DELIVERED
      return True
    return False

  def return_(self, result):
    trap_if(self.state == Task.State.RESOLVED)
    trap_if(self.num_borrows > 0)
    assert(result is not None)
    self.on_resolve(result)
    self.state = Task.State.RESOLVED

  def cancel(self):
    trap_if(self.state != Task.State.CANCEL_DELIVERED)
    trap_if(self.num_borrows > 0)
    self.on_resolve(None)
    self.state = Task.State.RESOLVED

#### Subtask State

class Subtask(Waitable):
  class State(IntEnum):
    STARTING = 0
    STARTED = 1
    RETURNED = 2
    CANCELLED_BEFORE_STARTED = 3
    CANCELLED_BEFORE_RETURNED = 4

  state: State
  callee: Optional[Call]
  lenders: Optional[list[ResourceHandle]]
  cancellation_requested: bool

  def __init__(self):
    Waitable.__init__(self)
    self.state = Subtask.State.STARTING
    self.callee = None
    self.lenders = []
    self.cancellation_requested = False

  def resolved(self):
    match self.state:
      case (Subtask.State.STARTING |
            Subtask.State.STARTED):
        return False
      case (Subtask.State.RETURNED |
            Subtask.State.CANCELLED_BEFORE_STARTED |
            Subtask.State.CANCELLED_BEFORE_RETURNED):
        return True

  def add_lender(self, lending_handle):
    assert(not self.resolve_delivered() and not self.resolved())
    lending_handle.num_lends += 1
    self.lenders.append(lending_handle)

  def deliver_resolve(self):
    assert(not self.resolve_delivered() and self.resolved())
    for h in self.lenders:
      h.num_lends -= 1
    self.lenders = None

  def resolve_delivered(self):
    assert(self.lenders is not None or self.resolved())
    return self.lenders is None

  def drop(self):
    trap_if(not self.resolve_delivered())
    Waitable.drop(self)

#### Buffer State

class Buffer:
  MAX_LENGTH = 2**28 - 1
  t: ValType
  remain: Callable[[], int]
  is_zero_length: Callable[[], bool]

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
    trap_if(length > Buffer.MAX_LENGTH)
    if t and length > 0:
      trap_if(ptr != align_to(ptr, alignment(t, cx.opts.memory.ptr_type())))
      trap_if(ptr + length * elem_size(t, cx.opts.memory.ptr_type()) > len(cx.opts.memory))
    self.cx = cx
    self.t = t
    self.ptr = ptr
    self.progress = 0
    self.length = length

  def remain(self):
    return self.length - self.progress

  def is_zero_length(self):
    return self.length == 0

class ReadableBufferGuestImpl(BufferGuestImpl):
  def read(self, n):
    assert(n <= self.remain())
    if self.t:
      vs = load_list_from_valid_range(self.cx, self.ptr, n, self.t)
      self.ptr += n * elem_size(self.t, self.cx.opts.memory.ptr_type())
    else:
      vs = n * [()]
    self.progress += n
    return vs

class WritableBufferGuestImpl(BufferGuestImpl, WritableBuffer):
  def write(self, vs):
    assert(len(vs) <= self.remain())
    if self.t:
      store_list_into_valid_range(self.cx, vs, self.ptr, self.t)
      self.ptr += len(vs) * elem_size(self.t, self.cx.opts.memory.ptr_type())
    else:
      assert(all(v == () for v in vs))
    self.progress += len(vs)

#### Stream State

class CopyResult(IntEnum):
  COMPLETED = 0
  DROPPED = 1
  CANCELLED = 2

ReclaimBuffer = Callable[[], None]
OnCopy = Callable[[ReclaimBuffer], None]
OnCopyDone = Callable[[CopyResult], None]

class SharedBase:
  t: ValType
  cancel: Callable[[], None]
  drop: Callable[[], None]

class ReadableStream(SharedBase):
  read: Callable[[ComponentInstance, WritableBuffer, OnCopy, OnCopyDone], None]

class WritableStream(SharedBase):
  write: Callable[[ComponentInstance, ReadableBuffer, OnCopy, OnCopyDone], None]

class SharedStreamImpl(ReadableStream, WritableStream):
  dropped: bool
  pending_inst: Optional[ComponentInstance]
  pending_buffer: Optional[Buffer]
  pending_on_copy: Optional[OnCopy]
  pending_on_copy_done: Optional[OnCopyDone]

  def __init__(self, t):
    self.t = t
    self.dropped = False
    self.reset_pending()

  def reset_pending(self):
    self.set_pending(None, None, None, None)

  def set_pending(self, inst, buffer, on_copy, on_copy_done):
    self.pending_inst = inst
    self.pending_buffer = buffer
    self.pending_on_copy = on_copy
    self.pending_on_copy_done = on_copy_done

  def reset_and_notify_pending(self, result):
    pending_on_copy_done = self.pending_on_copy_done
    self.reset_pending()
    pending_on_copy_done(result)

  def cancel(self):
    self.reset_and_notify_pending(CopyResult.CANCELLED)

  def drop(self):
    if not self.dropped:
      self.dropped = True
      if self.pending_buffer:
        self.reset_and_notify_pending(CopyResult.DROPPED)

  def read(self, inst, dst_buffer, on_copy, on_copy_done):
    if self.dropped:
      on_copy_done(CopyResult.DROPPED)
    elif not self.pending_buffer:
      self.set_pending(inst, dst_buffer, on_copy, on_copy_done)
    else:
      assert(self.t == dst_buffer.t == self.pending_buffer.t)
      trap_if(inst is self.pending_inst and not none_or_number_type(self.t)) # temporary
      if self.pending_buffer.remain() > 0:
        if dst_buffer.remain() > 0:
          n = min(dst_buffer.remain(), self.pending_buffer.remain())
          dst_buffer.write(self.pending_buffer.read(n))
          self.pending_on_copy(self.reset_pending)
        on_copy_done(CopyResult.COMPLETED)
      else:
        self.reset_and_notify_pending(CopyResult.COMPLETED)
        self.set_pending(inst, dst_buffer, on_copy, on_copy_done)

  def write(self, inst, src_buffer, on_copy, on_copy_done):
    if self.dropped:
      on_copy_done(CopyResult.DROPPED)
    elif not self.pending_buffer:
      self.set_pending(inst, src_buffer, on_copy, on_copy_done)
    else:
      assert(self.t == src_buffer.t == self.pending_buffer.t)
      trap_if(inst is self.pending_inst and not none_or_number_type(self.t)) # temporary
      if self.pending_buffer.remain() > 0:
        if src_buffer.remain() > 0:
          n = min(src_buffer.remain(), self.pending_buffer.remain())
          self.pending_buffer.write(src_buffer.read(n))
          self.pending_on_copy(self.reset_pending)
        on_copy_done(CopyResult.COMPLETED)
      elif src_buffer.is_zero_length() and self.pending_buffer.is_zero_length():
        on_copy_done(CopyResult.COMPLETED)
      else:
        self.reset_and_notify_pending(CopyResult.COMPLETED)
        self.set_pending(inst, src_buffer, on_copy, on_copy_done)

def none_or_number_type(t):
  return t is None or isinstance(t, U8Type | U16Type | U32Type | U64Type |
                                    S8Type | S16Type | S32Type | S64Type |
                                    F32Type | F64Type)

class CopyState(Enum):
  IDLE = 1
  SYNC_COPYING = 2
  ASYNC_COPYING = 3
  CANCELLING_COPY = 4
  DONE = 5

class CopyEnd(Waitable):
  state: CopyState
  shared: SharedBase

  def __init__(self, shared):
    Waitable.__init__(self)
    self.state = CopyState.IDLE
    self.shared = shared

  def copying(self):
    match self.state:
      case CopyState.IDLE | CopyState.DONE:
        return False
      case CopyState.SYNC_COPYING | CopyState.ASYNC_COPYING | CopyState.CANCELLING_COPY:
        return True
    assert(False)

  def drop(self):
    trap_if(self.copying())
    self.shared.drop()
    Waitable.drop(self)

class ReadableStreamEnd(CopyEnd):
  def copy(self, inst, dst, on_copy, on_copy_done):
    self.shared.read(inst, dst, on_copy, on_copy_done)

class WritableStreamEnd(CopyEnd):
  def copy(self, inst, src, on_copy, on_copy_done):
    self.shared.write(inst, src, on_copy, on_copy_done)

#### Future State

class ReadableFuture(SharedBase):
  read: Callable[[ComponentInstance, WritableBuffer, OnCopyDone], None]

class WritableFuture(SharedBase):
  write: Callable[[ComponentInstance, ReadableBuffer, OnCopyDone], None]

class SharedFutureImpl(ReadableFuture, WritableFuture):
  dropped: bool
  pending_inst: Optional[ComponentInstance]
  pending_buffer: Optional[Buffer]
  pending_on_copy_done: Optional[OnCopyDone]

  def __init__(self, t):
    self.t = t
    self.dropped = False
    self.reset_pending()

  def reset_pending(self):
    self.set_pending(None, None, None)

  def set_pending(self, inst, buffer, on_copy_done):
    self.pending_inst = inst
    self.pending_buffer = buffer
    self.pending_on_copy_done = on_copy_done

  def reset_and_notify_pending(self, result):
    pending_on_copy_done = self.pending_on_copy_done
    self.reset_pending()
    pending_on_copy_done(result)

  def cancel(self):
    self.reset_and_notify_pending(CopyResult.CANCELLED)

  def drop(self):
    if not self.dropped:
      self.dropped = True
      if self.pending_buffer:
        assert(isinstance(self.pending_buffer, WritableBuffer))
        self.reset_and_notify_pending(CopyResult.DROPPED)

  def read(self, inst, dst_buffer, on_copy_done):
    assert(not self.dropped and dst_buffer.remain() == 1)
    if not self.pending_buffer:
      self.set_pending(inst, dst_buffer, on_copy_done)
    else:
      trap_if(inst is self.pending_inst and not none_or_number_type(self.t)) # temporary
      dst_buffer.write(self.pending_buffer.read(1))
      self.reset_and_notify_pending(CopyResult.COMPLETED)
      on_copy_done(CopyResult.COMPLETED)

  def write(self, inst, src_buffer, on_copy_done):
    assert(src_buffer.remain() == 1)
    if self.dropped:
      on_copy_done(CopyResult.DROPPED)
    elif not self.pending_buffer:
      self.set_pending(inst, src_buffer, on_copy_done)
    else:
      trap_if(inst is self.pending_inst and not none_or_number_type(self.t)) # temporary
      self.pending_buffer.write(src_buffer.read(1))
      self.reset_and_notify_pending(CopyResult.COMPLETED)
      on_copy_done(CopyResult.COMPLETED)

class ReadableFutureEnd(CopyEnd):
  def copy(self, inst, src_buffer, on_copy_done):
    self.shared.read(inst, src_buffer, on_copy_done)

class WritableFutureEnd(CopyEnd):
  def copy(self, inst, dst_buffer, on_copy_done):
    self.shared.write(inst, dst_buffer, on_copy_done)

  def drop(self):
    trap_if(self.state != CopyState.DONE)
    CopyEnd.drop(self)

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
      return any(p(u) for u in t.param_types() + t.result_type())
    case _:
      assert(False)


### Alignment

def alignment(t, ptr_type):
  match despecialize(t):
    case BoolType()                  : return 1
    case S8Type() | U8Type()         : return 1
    case S16Type() | U16Type()       : return 2
    case S32Type() | U32Type()       : return 4
    case S64Type() | U64Type()       : return 8
    case F32Type()                   : return 4
    case F64Type()                   : return 8
    case CharType()                  : return 4
    case StringType()                : return ptr_size(ptr_type)
    case ErrorContextType()          : return 4
    case ListType(t, l)              : return alignment_list(t, l, ptr_type)
    case RecordType(fields)          : return alignment_record(fields, ptr_type)
    case VariantType(cases)          : return alignment_variant(cases, ptr_type)
    case FlagsType(labels)           : return alignment_flags(labels)
    case OwnType() | BorrowType()    : return 4
    case StreamType() | FutureType() : return 4

def alignment_list(elem_type, maybe_length, ptr_type):
  if maybe_length is not None:
    return alignment(elem_type, ptr_type)
  return ptr_size(ptr_type)

def alignment_record(fields, ptr_type):
  a = 1
  for f in fields:
    a = max(a, alignment(f.t, ptr_type))
  return a

def alignment_variant(cases, ptr_type):
  return max(alignment(discriminant_type(cases), ptr_type), max_case_alignment(cases, ptr_type))

def discriminant_type(cases):
  n = len(cases)
  assert(0 < n < (1 << 32))
  match math.ceil(math.log2(n)/8):
    case 0: return U8Type()
    case 1: return U8Type()
    case 2: return U16Type()
    case 3: return U32Type()

def max_case_alignment(cases, ptr_type):
  a = 1
  for c in cases:
    if c.t is not None:
      a = max(a, alignment(c.t, ptr_type))
  return a

def alignment_flags(labels):
  n = len(labels)
  assert(0 < n <= 32)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4

### Element Size

def elem_size(t, ptr_type):
  match despecialize(t):
    case BoolType()                  : return 1
    case S8Type() | U8Type()         : return 1
    case S16Type() | U16Type()       : return 2
    case S32Type() | U32Type()       : return 4
    case S64Type() | U64Type()       : return 8
    case F32Type()                   : return 4
    case F64Type()                   : return 8
    case CharType()                  : return 4
    case StringType()                : return 2 * ptr_size(ptr_type)
    case ErrorContextType()          : return 4
    case ListType(t, l)              : return elem_size_list(t, l, ptr_type)
    case RecordType(fields)          : return elem_size_record(fields, ptr_type)
    case VariantType(cases)          : return elem_size_variant(cases, ptr_type)
    case FlagsType(labels)           : return elem_size_flags(labels)
    case OwnType() | BorrowType()    : return 4
    case StreamType() | FutureType() : return 4

def elem_size_list(elem_type, maybe_length, ptr_type):
  if maybe_length is not None:
    return maybe_length * elem_size(elem_type, ptr_type)
  return 2 * ptr_size(ptr_type)

def elem_size_record(fields, ptr_type):
  s = 0
  for f in fields:
    s = align_to(s, alignment(f.t, ptr_type))
    s += elem_size(f.t, ptr_type)
  assert(s > 0)
  return align_to(s, alignment_record(fields, ptr_type))

def align_to(ptr, alignment):
  return math.ceil(ptr / alignment) * alignment

def elem_size_variant(cases, ptr_type):
  s = elem_size(discriminant_type(cases), ptr_type)
  s = align_to(s, max_case_alignment(cases, ptr_type))
  cs = 0
  for c in cases:
    if c.t is not None:
      cs = max(cs, elem_size(c.t, ptr_type))
  s += cs
  return align_to(s, alignment_variant(cases, ptr_type))

def elem_size_flags(labels):
  n = len(labels)
  assert(0 < n <= 32)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4

### Loading

def load(cx, ptr, t):
  assert(ptr == align_to(ptr, alignment(t, cx.opts.memory.ptr_type())))
  assert(ptr + elem_size(t, cx.opts.memory.ptr_type()) <= len(cx.opts.memory))
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
  begin = load_int(cx, ptr, cx.opts.memory.ptr_size())
  tagged_code_units = load_int(cx, ptr + cx.opts.memory.ptr_size(), cx.opts.memory.ptr_size())
  return load_string_from_range(cx, begin, tagged_code_units)

def utf16_tag(ptr_type):
  return 1 << (ptr_size(ptr_type) * 8 - 1)

REALLOC_I32_MAX = 2**32 - 1
MAX_STRING_BYTE_LENGTH = (1 << 28) - 1
assert(REALLOC_I32_MAX > 2 * MAX_STRING_BYTE_LENGTH)

def load_string_from_range(cx, ptr, tagged_code_units) -> String:
  tag = utf16_tag(cx.opts.memory.ptr_type())
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
      if bool(tagged_code_units & tag):
        byte_length = 2 * (tagged_code_units ^ tag)
        encoding = 'utf-16-le'
      else:
        byte_length = tagged_code_units
        encoding = 'latin-1'

  trap_if(byte_length > MAX_STRING_BYTE_LENGTH)
  trap_if(ptr != align_to(ptr, alignment))
  trap_if(ptr + byte_length > len(cx.opts.memory))
  try:
    s = cx.opts.memory[ptr : ptr+byte_length].decode(encoding)
  except UnicodeError:
    trap()

  return (s, cx.opts.string_encoding, tagged_code_units)

def lift_error_context(cx, i):
  errctx = cx.inst.handles.get(i)
  trap_if(not isinstance(errctx, ErrorContext))
  return errctx

MAX_LIST_BYTE_LENGTH = (1 << 28) - 1
assert(REALLOC_I32_MAX > 2 * MAX_LIST_BYTE_LENGTH)

def load_list(cx, ptr, elem_type, maybe_length):
  if maybe_length is not None:
    return load_list_from_valid_range(cx, ptr, maybe_length, elem_type)
  begin = load_int(cx, ptr, cx.opts.memory.ptr_size())
  length = load_int(cx, ptr + cx.opts.memory.ptr_size(), cx.opts.memory.ptr_size())
  return load_list_from_range(cx, begin, length, elem_type)

def load_list_from_range(cx, ptr, length, elem_type):
  trap_if(length * elem_size(elem_type, cx.opts.memory.ptr_type()) > MAX_LIST_BYTE_LENGTH)
  trap_if(ptr != align_to(ptr, alignment(elem_type, cx.opts.memory.ptr_type())))
  trap_if(ptr + length * elem_size(elem_type, cx.opts.memory.ptr_type()) > len(cx.opts.memory))
  return load_list_from_valid_range(cx, ptr, length, elem_type)

def load_list_from_valid_range(cx, ptr, length, elem_type):
  a = []
  for i in range(length):
    a.append(load(cx, ptr + i * elem_size(elem_type, cx.opts.memory.ptr_type()), elem_type))
  return a

def load_record(cx, ptr, fields):
  record = {}
  for field in fields:
    ptr = align_to(ptr, alignment(field.t, cx.opts.memory.ptr_type()))
    record[field.label] = load(cx, ptr, field.t)
    ptr += elem_size(field.t, cx.opts.memory.ptr_type())
  return record

def load_variant(cx, ptr, cases):
  disc_size = elem_size(discriminant_type(cases), cx.opts.memory.ptr_type())
  case_index = load_int(cx, ptr, disc_size)
  ptr += disc_size
  trap_if(case_index >= len(cases))
  c = cases[case_index]
  ptr = align_to(ptr, max_case_alignment(cases, cx.opts.memory.ptr_type()))
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
  h = cx.inst.handles.remove(i)
  trap_if(not isinstance(h, ResourceHandle))
  trap_if(h.rt is not t.rt)
  trap_if(h.num_lends != 0)
  trap_if(not h.own)
  return h.rep

def lift_borrow(cx, i, t):
  assert(isinstance(cx.borrow_scope, Subtask))
  h = cx.inst.handles.get(i)
  trap_if(not isinstance(h, ResourceHandle))
  trap_if(h.rt is not t.rt)
  cx.borrow_scope.add_lender(h)
  return h.rep

def lift_stream(cx, i, t):
  return lift_async_value(ReadableStreamEnd, cx, i, t)

def lift_future(cx, i, t):
  return lift_async_value(ReadableFutureEnd, cx, i, t)

def lift_async_value(ReadableEndT, cx, i, t):
  assert(not contains_borrow(t))
  e = cx.inst.handles.remove(i)
  trap_if(not isinstance(e, ReadableEndT))
  trap_if(e.shared.t != t)
  trap_if(e.state != CopyState.IDLE)
  return e.shared

### Storing

def store(cx, v, t, ptr):
  assert(ptr == align_to(ptr, alignment(t, cx.opts.memory.ptr_type())))
  assert(ptr + elem_size(t, cx.opts.memory.ptr_type()) <= len(cx.opts.memory))
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
  assert(0 <= i <= 0xD7FF or 0xE000 <= i <= 0x10FFFF)
  return i

def store_string(cx, v: String, ptr):
  begin, tagged_code_units = store_string_into_range(cx, v)
  store_int(cx, begin, ptr, cx.opts.memory.ptr_size())
  store_int(cx, tagged_code_units, ptr + cx.opts.memory.ptr_size(), cx.opts.memory.ptr_size())

def store_string_into_range(cx, v: String):
  src, src_encoding, src_tagged_code_units = v
  tag = utf16_tag(cx.opts.memory.ptr_type())

  if src_encoding == 'latin1+utf16':
    if bool(src_tagged_code_units & tag):
      src_simple_encoding = 'utf16'
      src_code_units = src_tagged_code_units ^ tag
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

def store_string_copy(cx, src, src_code_units, dst_code_unit_size, dst_alignment, dst_encoding):
  dst_byte_length = dst_code_unit_size * src_code_units
  assert(dst_byte_length <= REALLOC_I32_MAX)
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
  assert(src_code_units <= REALLOC_I32_MAX)
  ptr = cx.opts.realloc(0, 0, 1, src_code_units)
  trap_if(ptr + src_code_units > len(cx.opts.memory))
  for i,code_point in enumerate(src):
    if ord(code_point) < 2**7:
      cx.opts.memory[ptr + i] = ord(code_point)
    else:
      assert(worst_case_size <= REALLOC_I32_MAX)
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
  assert(worst_case_size <= REALLOC_I32_MAX)
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
  assert(src_code_units <= REALLOC_I32_MAX)
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
      assert(worst_case_size <= REALLOC_I32_MAX)
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
      tagged_code_units = int(len(encoded) / 2) | utf16_tag(cx.opts.memory.ptr_type())
      return (ptr, tagged_code_units)
  if dst_byte_length < src_code_units:
    ptr = cx.opts.realloc(ptr, src_code_units, 2, dst_byte_length)
    trap_if(ptr != align_to(ptr, 2))
    trap_if(ptr + dst_byte_length > len(cx.opts.memory))
  return (ptr, dst_byte_length)

def store_probably_utf16_to_latin1_or_utf16(cx, src, src_code_units):
  src_byte_length = 2 * src_code_units
  assert(src_byte_length <= REALLOC_I32_MAX)
  ptr = cx.opts.realloc(0, 0, 2, src_byte_length)
  trap_if(ptr != align_to(ptr, 2))
  trap_if(ptr + src_byte_length > len(cx.opts.memory))
  encoded = src.encode('utf-16-le')
  cx.opts.memory[ptr : ptr+len(encoded)] = encoded
  if any(ord(c) >= (1 << 8) for c in src):
    tagged_code_units = int(len(encoded) / 2) | utf16_tag(cx.opts.memory.ptr_type())
    return (ptr, tagged_code_units)
  latin1_size = int(len(encoded) / 2)
  for i in range(latin1_size):
    cx.opts.memory[ptr + i] = cx.opts.memory[ptr + 2*i]
  ptr = cx.opts.realloc(ptr, src_byte_length, 1, latin1_size)
  trap_if(ptr + latin1_size > len(cx.opts.memory))
  return (ptr, latin1_size)

def lower_error_context(cx, v):
  return cx.inst.handles.add(v)

def store_list(cx, v, ptr, elem_type, maybe_length):
  if maybe_length is not None:
    assert(maybe_length == len(v))
    store_list_into_valid_range(cx, v, ptr, elem_type)
    return
  begin, length = store_list_into_range(cx, v, elem_type)
  store_int(cx, begin, ptr, cx.opts.memory.ptr_size())
  store_int(cx, length, ptr + cx.opts.memory.ptr_size(), cx.opts.memory.ptr_size())

def store_list_into_range(cx, v, elem_type):
  byte_length = len(v) * elem_size(elem_type, cx.opts.memory.ptr_type())
  assert(byte_length <= REALLOC_I32_MAX)
  ptr = cx.opts.realloc(0, 0, alignment(elem_type, cx.opts.memory.ptr_type()), byte_length)
  trap_if(ptr != align_to(ptr, alignment(elem_type, cx.opts.memory.ptr_type())))
  trap_if(ptr + byte_length > len(cx.opts.memory))
  store_list_into_valid_range(cx, v, ptr, elem_type)
  return (ptr, len(v))

def store_list_into_valid_range(cx, v, ptr, elem_type):
  for i,e in enumerate(v):
    store(cx, e, elem_type, ptr + i * elem_size(elem_type, cx.opts.memory.ptr_type()))

def store_record(cx, v, ptr, fields):
  for f in fields:
    ptr = align_to(ptr, alignment(f.t, cx.opts.memory.ptr_type()))
    store(cx, v[f.label], f.t, ptr)
    ptr += elem_size(f.t, cx.opts.memory.ptr_type())

def store_variant(cx, v, ptr, cases):
  case_index, case_value = match_case(v, cases)
  disc_size = elem_size(discriminant_type(cases), cx.opts.memory.ptr_type())
  store_int(cx, case_index, ptr, disc_size)
  ptr += disc_size
  ptr = align_to(ptr, max_case_alignment(cases, cx.opts.memory.ptr_type()))
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
  return cx.inst.handles.add(h)

def lower_borrow(cx, rep, t):
  assert(isinstance(cx.borrow_scope, Task))
  if cx.inst is t.rt.impl:
    return rep
  h = ResourceHandle(t.rt, rep, own = False, borrow_scope = cx.borrow_scope)
  h.borrow_scope.num_borrows += 1
  return cx.inst.handles.add(h)

def lower_stream(cx, v, t):
  assert(isinstance(v, ReadableStream))
  assert(not contains_borrow(t))
  return cx.inst.handles.add(ReadableStreamEnd(v))

def lower_future(cx, v, t):
  assert(isinstance(v, ReadableFuture))
  assert(not contains_borrow(t))
  return cx.inst.handles.add(ReadableFutureEnd(v))

### Flattening

MAX_FLAT_PARAMS = 16
MAX_FLAT_ASYNC_PARAMS = 4
MAX_FLAT_RESULTS = 1

def flatten_functype(opts, ft, context):
  flat_params = flatten_types(ft.param_types(), opts)
  flat_results = flatten_types(ft.result_type(), opts)
  if not opts.async_:
    if len(flat_params) > MAX_FLAT_PARAMS:
      flat_params = [opts.memory.ptr_type()]
    if len(flat_results) > MAX_FLAT_RESULTS:
      match context:
        case 'lift':
          flat_results = [opts.memory.ptr_type()]
        case 'lower':
          flat_params += [opts.memory.ptr_type()]
          flat_results = []
    return CoreFuncType(flat_params, flat_results)
  else:
    match context:
      case 'lift':
        if len(flat_params) > MAX_FLAT_PARAMS:
          flat_params = [opts.memory.ptr_type()]
        if opts.callback:
          flat_results = ['i32']
        else:
          flat_results = []
      case 'lower':
        if len(flat_params) > MAX_FLAT_ASYNC_PARAMS:
          flat_params = [opts.memory.ptr_type()]
        if len(flat_results) > 0:
          flat_params += [opts.memory.ptr_type()]
        flat_results = ['i32']
    return CoreFuncType(flat_params, flat_results)

def flatten_types(ts, opts):
  return [ft for t in ts for ft in flatten_type(t, opts)]

def flatten_type(t, opts):
  match despecialize(t):
    case BoolType()                       : return ['i32']
    case U8Type() | U16Type() | U32Type() : return ['i32']
    case S8Type() | S16Type() | S32Type() : return ['i32']
    case S64Type() | U64Type()            : return ['i64']
    case F32Type()                        : return ['f32']
    case F64Type()                        : return ['f64']
    case CharType()                       : return ['i32']
    case StringType()                     : return [opts.memory.ptr_type(), opts.memory.ptr_type()]
    case ErrorContextType()               : return ['i32']
    case ListType(t, l)                   : return flatten_list(t, l, opts)
    case RecordType(fields)               : return flatten_record(fields, opts)
    case VariantType(cases)               : return flatten_variant(cases, opts)
    case FlagsType(labels)                : return ['i32']
    case OwnType() | BorrowType()         : return ['i32']
    case StreamType() | FutureType()      : return ['i32']

def flatten_list(elem_type, maybe_length, opts):
  if maybe_length is not None:
    return flatten_type(elem_type, opts) * maybe_length
  return [opts.memory.ptr_type(), opts.memory.ptr_type()]

def flatten_record(fields, opts):
  flat = []
  for f in fields:
    flat += flatten_type(f.t, opts)
  return flat

def flatten_variant(cases, opts):
  flat = []
  for c in cases:
    if c.t is not None:
      for i,ft in enumerate(flatten_type(c.t, opts)):
        if i < len(flat):
          flat[i] = join(flat[i], ft)
        else:
          flat.append(ft)
  return flatten_type(discriminant_type(cases), opts) + flat

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
  ptr = vi.next(cx.opts.memory.ptr_type())
  packed_length = vi.next(cx.opts.memory.ptr_type())
  return load_string_from_range(cx, ptr, packed_length)

def lift_flat_list(cx, vi, elem_type, maybe_length):
  if maybe_length is not None:
    a = []
    for i in range(maybe_length):
      a.append(lift_flat(cx, vi, elem_type))
    return a
  ptr = vi.next(cx.opts.memory.ptr_type())
  length = vi.next(cx.opts.memory.ptr_type())
  return load_list_from_range(cx, ptr, length, elem_type)

def lift_flat_record(cx, vi, fields):
  record = {}
  for f in fields:
    record[f.label] = lift_flat(cx, vi, f.t)
  return record

def lift_flat_variant(cx, vi, cases):
  flat_types = flatten_variant(cases, cx.opts)
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
  flat_types = flatten_variant(cases, cx.opts)
  assert(flat_types.pop(0) == 'i32')
  c = cases[case_index]
  if c.t is None:
    payload = []
  else:
    payload = lower_flat(cx, case_value, c.t)
    for i,(fv,have) in enumerate(zip(payload, flatten_type(c.t, cx.opts))):
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
  flat_types = flatten_types(ts, cx.opts)
  if len(flat_types) > max_flat:
    ptr = vi.next(cx.opts.memory.ptr_type())
    tuple_type = TupleType(ts)
    trap_if(ptr != align_to(ptr, alignment(tuple_type, cx.opts.memory.ptr_type())))
    trap_if(ptr + elem_size(tuple_type, cx.opts.memory.ptr_type()) > len(cx.opts.memory))
    return list(load(cx, ptr, tuple_type).values())
  else:
    return [ lift_flat(cx, vi, t) for t in ts ]

def lower_flat_values(cx, max_flat, vs, ts, out_param = None):
  cx.inst.may_leave = False
  flat_types = flatten_types(ts, cx.opts)
  if len(flat_types) > max_flat:
    tuple_type = TupleType(ts)
    tuple_value = {str(i): v for i,v in enumerate(vs)}
    if out_param is None:
      ptr = cx.opts.realloc(0, 0, alignment(tuple_type, cx.opts.memory.ptr_type()), elem_size(tuple_type, cx.opts.memory.ptr_type()))
      flat_vals = [ptr]
    else:
      ptr = out_param.next(cx.opts.memory.ptr_type())
      flat_vals = []
    trap_if(ptr != align_to(ptr, alignment(tuple_type, cx.opts.memory.ptr_type())))
    trap_if(ptr + elem_size(tuple_type, cx.opts.memory.ptr_type()) > len(cx.opts.memory))
    store(cx, tuple_value, tuple_type, ptr)
  else:
    flat_vals = []
    for i in range(len(vs)):
      flat_vals += lower_flat(cx, vs[i], ts[i])
  cx.inst.may_leave = True
  return flat_vals

### `canon lift`

def canon_lift(opts, inst, ft, callee, caller, on_start, on_resolve) -> Call:
  trap_if(call_might_be_recursive(caller, inst))
  task = Task(opts, inst, ft, caller, on_resolve)
  def thread_func(thread):
    if not task.enter(thread):
      return

    cx = LiftLowerContext(opts, inst, task)
    args = on_start()
    flat_args = lower_flat_values(cx, MAX_FLAT_PARAMS, args, ft.param_types())
    flat_ft = flatten_functype(opts, ft, 'lift')
    assert(types_match_values(flat_ft.params, flat_args))

    if not opts.async_:
      flat_results = call_and_trap_on_throw(callee, thread, flat_args)
      assert(types_match_values(flat_ft.results, flat_results))
      result = lift_flat_values(cx, MAX_FLAT_RESULTS, CoreValueIter(flat_results), ft.result_type())
      task.return_(result)
      if opts.post_return is not None:
        inst.may_leave = False
        [] = call_and_trap_on_throw(opts.post_return, thread, flat_results)
        inst.may_leave = True
      task.exit(thread)
      return

    if not opts.callback:
      [] = call_and_trap_on_throw(callee, thread, flat_args)
      assert(types_match_values(flat_ft.results, []))
      task.exit(thread)
      return

    [packed] = call_and_trap_on_throw(callee, thread, flat_args)
    code,si = unpack_callback_result(packed)
    while code != CallbackCode.EXIT:
      assert(inst.exclusive is task)
      inst.exclusive = None
      match code:
        case CallbackCode.YIELD:
          if thread.yield_until(lambda: not inst.exclusive, cancellable = True) == Cancelled.TRUE:
            event = (EventCode.TASK_CANCELLED, 0, 0)
          else:
            event = (EventCode.NONE, 0, 0)
        case CallbackCode.WAIT:
          trap_if(not task.may_block())
          wset = inst.handles.get(si)
          trap_if(not isinstance(wset, WaitableSet))
          event = wset.wait_until(lambda: not inst.exclusive, thread, cancellable = True)
        case _:
          trap()
      assert(inst.exclusive is None)
      inst.exclusive = task
      event_code, p1, p2 = event
      [packed] = call_and_trap_on_throw(opts.callback, thread, [event_code, p1, p2])
      code,si = unpack_callback_result(packed)
    task.exit(thread)
    return

  thread = Thread(task, thread_func)
  thread.resume(Cancelled.FALSE)
  return task

class CallbackCode(IntEnum):
  EXIT = 0
  YIELD = 1
  WAIT = 2
  MAX = 2

def unpack_callback_result(packed):
  code = packed & 0xf
  trap_if(code > CallbackCode.MAX)
  assert(packed < 2**32)
  assert(Table.MAX_LENGTH < 2**28)
  waitable_set_index = packed >> 4
  return (CallbackCode(code), waitable_set_index)

def call_and_trap_on_throw(callee, thread, args):
  try:
    return callee(thread, args)
  except CoreWebAssemblyException:
    trap()

### `canon lower`

def canon_lower(opts, ft, callee: FuncInst, thread, flat_args):
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block() and ft.async_ and not opts.async_)

  subtask = Subtask()
  cx = LiftLowerContext(opts, thread.task.inst, subtask)

  flat_ft = flatten_functype(opts, ft, 'lower')
  assert(types_match_values(flat_ft.params, flat_args))
  flat_args = CoreValueIter(flat_args)

  if not opts.async_:
    max_flat_params = MAX_FLAT_PARAMS
    max_flat_results = MAX_FLAT_RESULTS
  else:
    max_flat_params = MAX_FLAT_ASYNC_PARAMS
    max_flat_results = 0

  on_progress = lambda:()
  flat_results = None

  def on_start():
    on_progress()
    assert(subtask.state == Subtask.State.STARTING)
    subtask.state = Subtask.State.STARTED
    return lift_flat_values(cx, max_flat_params, flat_args, ft.param_types())

  def on_resolve(result):
    on_progress()
    if result is None:
      assert(subtask.cancellation_requested)
      if subtask.state == Subtask.State.STARTING:
        subtask.state = Subtask.State.CANCELLED_BEFORE_STARTED
      else:
        assert(subtask.state == Subtask.State.STARTED)
        subtask.state = Subtask.State.CANCELLED_BEFORE_RETURNED
    else:
      assert(subtask.state == Subtask.State.STARTED)
      subtask.state = Subtask.State.RETURNED
      nonlocal flat_results
      flat_results = lower_flat_values(cx, max_flat_results, result, ft.result_type(), flat_args)

  subtask.callee = callee(thread.task, on_start, on_resolve)
  assert(ft.async_ or subtask.state == Subtask.State.RETURNED)

  if not opts.async_:
    if not subtask.resolved():
      thread.wait_until(subtask.resolved)
    assert(types_match_values(flat_ft.results, flat_results))
    subtask.deliver_resolve()
    return flat_results
  else:
    if subtask.resolved():
      assert(flat_results == [])
      subtask.deliver_resolve()
      return [Subtask.State.RETURNED]
    else:
      subtaski = thread.task.inst.handles.add(subtask)
      def on_progress():
        def subtask_event():
          if subtask.resolved():
            subtask.deliver_resolve()
          return (EventCode.SUBTASK, subtaski, subtask.state)
        subtask.set_pending_event(subtask_event)
      assert(0 < subtaski <= Table.MAX_LENGTH < 2**28)
      assert(0 <= subtask.state < 2**4)
      return [subtask.state | (subtaski << 4)]

### `canon resource.new`

def canon_resource_new(rt, thread, rep):
  trap_if(not thread.task.inst.may_leave)
  h = ResourceHandle(rt, rep, own = True)
  i = thread.task.inst.handles.add(h)
  return [i]

### `canon resource.drop`

def canon_resource_drop(rt, thread, i):
  trap_if(not thread.task.inst.may_leave)
  inst = thread.task.inst
  h = inst.handles.remove(i)
  trap_if(not isinstance(h, ResourceHandle))
  trap_if(h.rt is not rt)
  trap_if(h.num_lends != 0)
  if h.own:
    assert(h.borrow_scope is None)
    if inst is rt.impl:
      if rt.dtor:
        rt.dtor(h.rep)
    else:
      caller_opts = CanonicalOptions(async_ = False)
      callee_opts = CanonicalOptions(async_ = rt.dtor_async, callback = rt.dtor_callback)
      ft = FuncType([U32Type()],[], async_ = False)
      dtor = rt.dtor or (lambda thread, rep: [])
      callee = partial(canon_lift, callee_opts, rt.impl, ft, dtor)
      [] = canon_lower(caller_opts, ft, callee, thread, [h.rep])
  else:
    h.borrow_scope.num_borrows -= 1
  return []

### `canon resource.rep`

def canon_resource_rep(rt, thread, i):
  h = thread.task.inst.handles.get(i)
  trap_if(not isinstance(h, ResourceHandle))
  trap_if(h.rt is not rt)
  return [h.rep]

### 🔀 `canon context.get`
MASK_32BIT = (1 << 32) - 1

def canon_context_get(t, i, thread):
  assert(t == 'i32' or t == 'i64')
  assert(i < len(thread.storage))
  result = thread.storage[i]
  if t == 'i32':
    result &= MASK_32BIT
  return [result]

### 🔀 `canon context.set`

def canon_context_set(t, i, thread, v):
  assert(t == 'i32' or t == 'i64')
  assert(v <= MASK_32BIT or t == 'i64')
  assert(i < len(thread.storage))
  thread.storage[i] = v
  return []

### 🔀 `canon backpressure.set`

def canon_backpressure_set(thread, flat_args):
  assert(len(flat_args) == 1)
  thread.task.inst.backpressure = int(bool(flat_args[0]))
  return []

### 🔀 `canon backpressure.{inc,dec}`

def canon_backpressure_inc(thread):
  assert(0 <= thread.task.inst.backpressure < 2**16)
  thread.task.inst.backpressure += 1
  trap_if(thread.task.inst.backpressure == 2**16)
  return []

def canon_backpressure_dec(thread):
  assert(0 <= thread.task.inst.backpressure < 2**16)
  thread.task.inst.backpressure -= 1
  trap_if(thread.task.inst.backpressure < 0)
  return []

### 🔀 `canon task.return`

def canon_task_return(thread, result_type, opts: LiftOptions, flat_args):
  task = thread.task
  trap_if(not task.inst.may_leave)
  trap_if(not task.opts.async_)
  trap_if(result_type != task.ft.result)
  trap_if(not LiftOptions.equal(opts, task.opts))
  cx = LiftLowerContext(opts, task.inst, task)
  result = lift_flat_values(cx, MAX_FLAT_PARAMS, CoreValueIter(flat_args), task.ft.result_type())
  task.return_(result)
  return []

### 🔀 `canon task.cancel`

def canon_task_cancel(thread):
  task = thread.task
  trap_if(not task.inst.may_leave)
  trap_if(not task.opts.async_)
  task.cancel()
  return []

### 🔀 `canon waitable-set.new`

def canon_waitable_set_new(thread):
  trap_if(not thread.task.inst.may_leave)
  return [ thread.task.inst.handles.add(WaitableSet()) ]

### 🔀 `canon waitable-set.wait`

def canon_waitable_set_wait(cancellable, mem, thread, si, ptr):
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block())
  wset = thread.task.inst.handles.get(si)
  trap_if(not isinstance(wset, WaitableSet))
  event = wset.wait(thread, cancellable)
  return unpack_event(mem, thread, ptr, event)

def unpack_event(mem, thread, ptr, e: EventTuple):
  event, p1, p2 = e
  cx = LiftLowerContext(LiftLowerOptions(memory = mem), thread.task.inst)
  store(cx, p1, U32Type(), ptr)
  store(cx, p2, U32Type(), ptr + 4)
  return [event]

### 🔀 `canon waitable-set.poll`

def canon_waitable_set_poll(cancellable, mem, thread, si, ptr):
  trap_if(not thread.task.inst.may_leave)
  wset = thread.task.inst.handles.get(si)
  trap_if(not isinstance(wset, WaitableSet))
  event = wset.poll(thread, cancellable)
  return unpack_event(mem, thread, ptr, event)

### 🔀 `canon waitable-set.drop`

def canon_waitable_set_drop(thread, i):
  trap_if(not thread.task.inst.may_leave)
  wset = thread.task.inst.handles.remove(i)
  trap_if(not isinstance(wset, WaitableSet))
  wset.drop()
  return []

### 🔀 `canon waitable.join`

def canon_waitable_join(thread, wi, si):
  trap_if(not thread.task.inst.may_leave)
  w = thread.task.inst.handles.get(wi)
  trap_if(not isinstance(w, Waitable))
  if si == 0:
    w.join(None)
  else:
    wset = thread.task.inst.handles.get(si)
    trap_if(not isinstance(wset, WaitableSet))
    w.join(wset)
  return []

### 🔀 `canon subtask.cancel`

BLOCKED = 0xffff_ffff

def canon_subtask_cancel(async_, thread, i):
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block() and not async_)
  subtask = thread.task.inst.handles.get(i)
  trap_if(not isinstance(subtask, Subtask))
  trap_if(subtask.resolve_delivered())
  trap_if(subtask.cancellation_requested)
  if subtask.resolved():
    assert(subtask.has_pending_event())
  else:
    subtask.cancellation_requested = True
    subtask.callee.request_cancellation()
    if not subtask.resolved():
      if not async_:
        thread.wait_until(subtask.resolved)
      else:
        return [BLOCKED]
  code,index,payload = subtask.get_pending_event()
  assert(code == EventCode.SUBTASK and index == i and payload == subtask.state)
  assert(subtask.resolve_delivered())
  return [subtask.state]

### 🔀 `canon subtask.drop`

def canon_subtask_drop(thread, i):
  trap_if(not thread.task.inst.may_leave)
  s = thread.task.inst.handles.remove(i)
  trap_if(not isinstance(s, Subtask))
  s.drop()
  return []

### 🔀 `canon {stream,future}.new`

def canon_stream_new(stream_t, thread):
  trap_if(not thread.task.inst.may_leave)
  shared = SharedStreamImpl(stream_t.t)
  ri = thread.task.inst.handles.add(ReadableStreamEnd(shared))
  wi = thread.task.inst.handles.add(WritableStreamEnd(shared))
  return [ ri | (wi << 32) ]

def canon_future_new(future_t, thread):
  trap_if(not thread.task.inst.may_leave)
  shared = SharedFutureImpl(future_t.t)
  ri = thread.task.inst.handles.add(ReadableFutureEnd(shared))
  wi = thread.task.inst.handles.add(WritableFutureEnd(shared))
  return [ ri | (wi << 32) ]

### 🔀 `canon stream.{read,write}`

def canon_stream_read(stream_t, opts, thread, i, ptr, n):
  return stream_copy(ReadableStreamEnd, WritableBufferGuestImpl, EventCode.STREAM_READ,
                     stream_t, opts, thread, i, ptr, n)

def canon_stream_write(stream_t, opts, thread, i, ptr, n):
  return stream_copy(WritableStreamEnd, ReadableBufferGuestImpl, EventCode.STREAM_WRITE,
                     stream_t, opts, thread, i, ptr, n)

def stream_copy(EndT, BufferT, event_code, stream_t, opts, thread, i, ptr, n):
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block() and not opts.async_)

  e = thread.task.inst.handles.get(i)
  trap_if(not isinstance(e, EndT))
  trap_if(e.shared.t != stream_t.t)
  trap_if(e.state != CopyState.IDLE)

  assert(not isinstance(stream_t, CharType))
  assert(not contains_borrow(stream_t))
  cx = LiftLowerContext(opts, thread.task.inst, borrow_scope = None)
  buffer = BufferT(stream_t.t, cx, ptr, n)

  def stream_event(result, reclaim_buffer):
    reclaim_buffer()
    if result == CopyResult.DROPPED:
      e.state = CopyState.DONE
    else:
      e.state = CopyState.IDLE
    assert(0 <= result < 2**4)
    assert(buffer.progress <= Buffer.MAX_LENGTH < 2**28)
    packed_result = result | (buffer.progress << 4)
    return (event_code, i, packed_result)

  def on_copy(reclaim_buffer):
    e.set_pending_event(partial(stream_event, CopyResult.COMPLETED, reclaim_buffer))

  def on_copy_done(result):
    e.set_pending_event(partial(stream_event, result, reclaim_buffer = lambda:()))

  e.copy(thread.task.inst, buffer, on_copy, on_copy_done)

  if not e.has_pending_event():
    if not opts.async_:
      e.state = CopyState.SYNC_COPYING
      thread.wait_until(e.has_pending_event)
    else:
      e.state = CopyState.ASYNC_COPYING
      return [BLOCKED]
  code,index,payload = e.get_pending_event()
  assert(code == event_code and index == i and payload != BLOCKED)
  return [payload]

### 🔀 `canon future.{read,write}`

def canon_future_read(future_t, opts, thread, i, ptr):
  return future_copy(ReadableFutureEnd, WritableBufferGuestImpl, EventCode.FUTURE_READ,
                     future_t, opts, thread, i, ptr)

def canon_future_write(future_t, opts, thread, i, ptr):
  return future_copy(WritableFutureEnd, ReadableBufferGuestImpl, EventCode.FUTURE_WRITE,
                     future_t, opts, thread, i, ptr)

def future_copy(EndT, BufferT, event_code, future_t, opts, thread, i, ptr):
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block() and not opts.async_)

  e = thread.task.inst.handles.get(i)
  trap_if(not isinstance(e, EndT))
  trap_if(e.shared.t != future_t.t)
  trap_if(e.state != CopyState.IDLE)

  assert(not contains_borrow(future_t))
  cx = LiftLowerContext(opts, thread.task.inst, borrow_scope = None)
  buffer = BufferT(future_t.t, cx, ptr, 1)

  def future_event(result):
    assert((buffer.remain() == 0) == (result == CopyResult.COMPLETED))
    if result == CopyResult.DROPPED or result == CopyResult.COMPLETED:
      e.state = CopyState.DONE
    else:
      e.state = CopyState.IDLE
    return (event_code, i, result)

  def on_copy_done(result):
    assert(result != CopyResult.DROPPED or event_code == EventCode.FUTURE_WRITE)
    e.set_pending_event(partial(future_event, result))

  e.copy(thread.task.inst, buffer, on_copy_done)

  if not e.has_pending_event():
    if not opts.async_:
      e.state = CopyState.SYNC_COPYING
      thread.wait_until(e.has_pending_event)
    else:
      e.state = CopyState.ASYNC_COPYING
      return [BLOCKED]
  code,index,payload = e.get_pending_event()
  assert(code == event_code and index == i)
  return [payload]

### 🔀 `canon {stream,future}.cancel-{read,write}`

def canon_stream_cancel_read(stream_t, async_, thread, i):
  return cancel_copy(ReadableStreamEnd, EventCode.STREAM_READ, stream_t, async_, thread, i)

def canon_stream_cancel_write(stream_t, async_, thread, i):
  return cancel_copy(WritableStreamEnd, EventCode.STREAM_WRITE, stream_t, async_, thread, i)

def canon_future_cancel_read(future_t, async_, thread, i):
  return cancel_copy(ReadableFutureEnd, EventCode.FUTURE_READ, future_t, async_, thread, i)

def canon_future_cancel_write(future_t, async_, thread, i):
  return cancel_copy(WritableFutureEnd, EventCode.FUTURE_WRITE, future_t, async_, thread, i)

def cancel_copy(EndT, event_code, stream_or_future_t, async_, thread, i):
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block() and not async_)
  e = thread.task.inst.handles.get(i)
  trap_if(not isinstance(e, EndT))
  trap_if(e.shared.t != stream_or_future_t.t)
  trap_if(e.state != CopyState.ASYNC_COPYING)
  e.state = CopyState.CANCELLING_COPY
  if not e.has_pending_event():
    e.shared.cancel()
    if not e.has_pending_event():
      if not async_:
        thread.wait_until(e.has_pending_event)
      else:
        return [BLOCKED]
  code,index,payload = e.get_pending_event()
  assert(not e.copying() and code == event_code and index == i)
  return [payload]

### 🔀 `canon {stream,future}.drop-{readable,writable}`

def canon_stream_drop_readable(stream_t, thread, i):
  return drop(ReadableStreamEnd, stream_t, thread, i)

def canon_stream_drop_writable(stream_t, thread, hi):
  return drop(WritableStreamEnd, stream_t, thread, hi)

def canon_future_drop_readable(future_t, thread, i):
  return drop(ReadableFutureEnd, future_t, thread, i)

def canon_future_drop_writable(future_t, thread, hi):
  return drop(WritableFutureEnd, future_t, thread, hi)

def drop(EndT, stream_or_future_t, thread, hi):
  trap_if(not thread.task.inst.may_leave)
  e = thread.task.inst.handles.remove(hi)
  trap_if(not isinstance(e, EndT))
  trap_if(e.shared.t != stream_or_future_t.t)
  e.drop()
  return []

### 🧵 `canon thread.index`

def canon_thread_index(thread):
  assert(thread.index is not None)
  return [thread.index]

### 🧵 `canon thread.new-indirect`

@dataclass
class CoreFuncRef:
  t: CoreFuncType
  callee: Callable[[Thread, list[CoreValType]], list[CoreValType]]

def canon_thread_new_indirect(ft, ftbl: Table[CoreFuncRef], thread, fi, c):
  task = thread.task
  trap_if(not task.inst.may_leave)
  f = ftbl.get(fi)
  assert(ft == CoreFuncType(['i32'], []) or ft == CoreFuncType(['i64'], []))
  trap_if(f.t != ft)
  def thread_func(thread):
    [] = call_and_trap_on_throw(f.callee, thread, [c])
    task.unregister_thread(new_thread)
  new_thread = Thread(task, thread_func)
  assert(new_thread.suspended())
  task.register_thread(new_thread)
  return [new_thread.index]

### 🧵 `canon thread.switch-to`

def canon_thread_switch_to(cancellable, thread, i):
  trap_if(not thread.task.inst.may_leave)
  other_thread = thread.task.inst.threads.get(i)
  trap_if(not other_thread.suspended())
  cancelled = thread.switch_to(cancellable, other_thread)
  return [cancelled]

### 🧵 `canon thread.suspend`

def canon_thread_suspend(cancellable, thread):
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block())
  cancelled = thread.suspend(cancellable)
  return [cancelled]

### 🧵 `canon thread.resume-later`

def canon_thread_resume_later(thread, i):
  trap_if(not thread.task.inst.may_leave)
  other_thread = thread.task.inst.threads.get(i)
  trap_if(not other_thread.suspended())
  other_thread.resume_later()
  return []

### 🧵 `canon thread.yield-to`

def canon_thread_yield_to(cancellable, thread, i):
  trap_if(not thread.task.inst.may_leave)
  other_thread = thread.task.inst.threads.get(i)
  trap_if(not other_thread.suspended())
  cancelled = thread.yield_to(cancellable, other_thread)
  return [cancelled]

### 🧵 `canon thread.yield`

def canon_thread_yield(cancellable, thread):
  trap_if(not thread.task.inst.may_leave)
  cancelled = thread.yield_(cancellable)
  return [cancelled]

### 📝 `canon error-context.new`

@dataclass
class ErrorContext:
  debug_message: String

def canon_error_context_new(opts, thread, ptr, tagged_code_units):
  trap_if(not thread.task.inst.may_leave)
  if DETERMINISTIC_PROFILE or random.randint(0,1):
    s = String(('', 'utf8', 0))
  else:
    cx = LiftLowerContext(opts, thread.task.inst)
    s = load_string_from_range(cx, ptr, tagged_code_units)
    s = host_defined_transformation(s)
  i = thread.task.inst.handles.add(ErrorContext(s))
  return [i]

### 📝 `canon error-context.debug-message`

def canon_error_context_debug_message(opts, thread, i, ptr):
  trap_if(not thread.task.inst.may_leave)
  errctx = thread.task.inst.handles.get(i)
  trap_if(not isinstance(errctx, ErrorContext))
  cx = LiftLowerContext(opts, thread.task.inst)
  store_string(cx, errctx.debug_message, ptr)
  return []

### 📝 `canon error-context.drop`

def canon_error_context_drop(thread, i):
  trap_if(not thread.task.inst.may_leave)
  errctx = thread.task.inst.handles.remove(i)
  trap_if(not isinstance(errctx, ErrorContext))
  return []
