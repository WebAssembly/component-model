# Canonical ABI Explainer

This document defines the Canonical ABI used to convert between the values and
functions of components in the Component Model and the values and functions
of modules in Core WebAssembly. See the [AST explainer](Explainer.md) for a
walkthrough of the static structure of a component and the
[async explainer](Async.md) for a high-level description of the async model
being specified here.

* [Supporting definitions](#supporting-definitions)
  * [Lifting and Lowering Context](#lifting-and-lowering-context)
  * [Canonical ABI Options](#canonical-abi-options)
  * [Runtime State](#runtime-state)
    * [Component Instance State](#component-instance-state)
    * [Table State](#table-state)
    * [Resource State](#resource-state)
    * [Buffer State](#buffer-state)
    * [Task State](#task-state)
    * [Waitable State](#waitable-state)
    * [Subtask State](#subtask-state)
    * [Stream State](#stream-state)
    * [Future State](#future-state)
  * [Despecialization](#despecialization)
  * [Type Predicates](#type-predicates)
  * [Alignment](#alignment)
  * [Element Size](#element-size)
  * [Loading](#loading)
  * [Storing](#storing)
  * [Flattening](#flattening)
  * [Flat Lifting](#flat-lifting)
  * [Flat Lowering](#flat-lowering)
  * [Lifting and Lowering Values](#lifting-and-lowering-values)
* [Canonical definitions](#canonical-definitions)
  * [`canon lift`](#canon-lift)
  * [`canon lower`](#canon-lower)
  * [`canon resource.new`](#canon-resourcenew)
  * [`canon resource.drop`](#canon-resourcedrop)
  * [`canon resource.rep`](#canon-resourcerep)
  * [`canon context.get`](#-canon-contextget) 🔀
  * [`canon context.set`](#-canon-contextset) 🔀
  * [`canon backpressure.set`](#-canon-backpressureset) 🔀
  * [`canon task.return`](#-canon-taskreturn) 🔀
  * [`canon yield`](#-canon-yield) 🔀
  * [`canon waitable-set.new`](#-canon-waitable-setnew) 🔀
  * [`canon waitable-set.wait`](#-canon-waitable-setwait) 🔀
  * [`canon waitable-set.poll`](#-canon-waitable-setpoll) 🔀
  * [`canon waitable-set.drop`](#-canon-waitable-setdrop) 🔀
  * [`canon waitable.join`](#-canon-waitablejoin) 🔀
  * [`canon subtask.drop`](#-canon-subtaskdrop) 🔀
  * [`canon {stream,future}.new`](#-canon-streamfuturenew) 🔀
  * [`canon {stream,future}.{read,write}`](#-canon-streamfuturereadwrite) 🔀
  * [`canon {stream,future}.cancel-{read,write}`](#-canon-streamfuturecancel-readwrite) 🔀
  * [`canon {stream,future}.close-{readable,writable}`](#-canon-streamfutureclose-readablewritable) 🔀
  * [`canon error-context.new`](#-canon-error-contextnew) 🔀
  * [`canon error-context.debug-message`](#-canon-error-contextdebug-message) 🔀
  * [`canon error-context.drop`](#-canon-error-contextdrop) 🔀
  * [`canon thread.spawn`](#-canon-threadspawn) 🧵
  * [`canon thread.available_parallelism`](#-canon-threadavailable_parallelism) 🧵

## Supporting definitions

The Canonical ABI specifies, for each component function signature, a
corresponding core function signature and the process for reading
component-level values into and out of linear memory. While a full formal
specification would specify the Canonical ABI in terms of macro-expansion into
Core WebAssembly instructions augmented with a new set of (spec-internal)
[administrative instructions], the informal presentation here instead specifies
the process in terms of Python code that would be logically executed at
validation- and run-time by a component model implementation. The Python code
is presented by interleaving definitions with descriptions and eliding some
boilerplate. For a complete listing of all Python definitions in a single
executable file with a small unit test suite, see the
[`canonical-abi`](canonical-abi/) directory.

The convention followed by the Python code below is that all traps are raised
by explicit `trap()`/`trap_if()` calls; Python `assert()` statements should
never fire and are only included as hints to the reader. Similarly, there
should be no uncaught Python exceptions.

While the Python code for lifting and lowering values appears to create an
intermediate copy when lifting linear memory into high-level Python values, a
real implementation should be able to fuse lifting and lowering into a single
direct copy from the source linear memory into the destination linear memory.
Similarly, while the Python code specifies [async](Async.md) using Python's
[`asyncio`] library, a real implementation is expected to implement this
specified behavior using other lower-level concurrency primitives such as
fibers or Core WebAssembly [stack-switching].

Lastly, independently of Python, the Canonical ABI defined below assumes that
out-of-memory conditions (such as `memory.grow` returning `-1` from within
`realloc`) will trap (via `unreachable`). This significantly simplifies the
Canonical ABI by avoiding the need to support the complicated protocols
necessary to support recovery in the middle of nested allocations. (Note: by
nature of eliminating `realloc`, switching to
[lazy lowering](https://github.com/WebAssembly/component-model/issues/383)
would obviate this issue, allowing guest wasm code to handle failure by eagerly
returning some value of the declared return type to indicate failure.


### Lifting and Lowering Context

Most Canonical ABI definitions depend on some ambient information which is
established by the `canon lift`- or `canon lower`-defined function that is
being called:
* the ABI options supplied via [`canonopt`]
* the containing component instance
* the `Task` or `Subtask` used to lower or lift, resp., `borrow` handles

These three pieces of ambient information are stored in an `LiftLowerContext`
object that is threaded through all the Python functions below as the `cx`
parameter/field.
```python
class LiftLowerContext:
  opts: LiftLowerOptions
  inst: ComponentInstance
  borrow_scope: Optional[Task|Subtask]

  def __init__(self, opts, inst, borrow_scope = None):
    self.opts = opts
    self.inst = inst
    self.borrow_scope = borrow_scope
```
The `borrow_scope` field may be `None` if the types being lifted/lowered are
known to not contain `borrow`. The `CanonicalOptions`, `ComponentInstance`,
`Task` and `Subtask` classes are defined next.


### Canonical ABI Options

The following two classes list the various Canonical ABI options ([`canonopt`])
that can be set on various Canonical ABI definitions. The default values of the
Python fields are the default values when the associated `canonopt` is not
present in the binary or text format definition.

The `LiftLowerContext` class contains the subset of [`canonopt`] which are
used to lift and lower the individual parameters and results of function
calls:
```python
@dataclass
class LiftLowerOptions:
  string_encoding: str = 'utf8'
  memory: Optional[bytearray] = None
  realloc: Optional[Callable] = None

  def __eq__(self, other):
    return self.string_encoding == other.string_encoding and \
           self.memory is other.memory and \
           self.realloc is other.realloc

  def copy(opts):
    return LiftLowerOptions(opts.string_encoding, opts.memory, opts.realloc)
```
The `__eq__` override specifies that equality of `LiftLowerOptions` (as used
by, e.g., `canon_task_return` below) is defined in terms of the identity of
the memory and `realloc`-function instances.

The `CanonicalOptions` class contains the rest of the [`canonopt`] options
that affect how an overall function is lifted/lowered:
```python
@dataclass
class CanonicalOptions(LiftLowerOptions):
  post_return: Optional[Callable] = None
  sync: bool = True # = !canonopt.async
  callback: Optional[Callable] = None
  always_task_return: bool = False
```
(Note that the `async` `canonopt` is inverted to `sync` here for the practical
reason that `async` is a keyword and most branches below want to start with the
`sync = True` case.)


### Runtime State

The following Python classes define spec-internal state and utility methods
that are used to define the externally-visible behavior of Canonical ABI's
lifting, lowering and built-in definitions below. These fields are chosen for
simplicity over performance and thus an optimizing implementation is expected
to use a more optimized representations as long as it preserves the same
externally-visible behavior. Some specific examples of expected optimizations
are noted below.


#### Component Instance State

The `ComponentInstance` class contains all the relevant per-component-instance
state that the definitions below use to implement the Component Model's runtime
behavior and enforce invariants.
```python
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
```
These fields will be described as they are used by the following definitions.


#### Table State

The generic `Table` class, used by the `resources`, `waitables` and
`error_contexts` fields of `ComponentInstance` above, encapsulates a single
mutable, growable array of elements that are represented in Core WebAssembly as
`i32` indices into the array.
```python
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
```
`Table` maintains a dense array of elements that can contain holes created by
the `remove` method (defined below). When table elements are accessed (e.g., by
`canon_lift` and `resource.rep`, below), there are thus both a bounds check and
hole check necessary. Upon initialization, table element `0` is allocated and
set to `None`, effectively reserving index `0` which is both useful for
catching null/uninitialized accesses and allowing `0` to serve as a sentinel
value.

The `add` and `remove` methods work together to maintain a free list of holes
that are used in preference to growing the table. The free list is represented
as a Python list here, but an optimizing implementation could instead store the
free list in the free elements of `array`.

The limit of `2**30` ensures that the high 2 bits of table indices are unset
and available for other use in guest code (e.g., for tagging, packed words or
sentinel values).


#### Resource State

The `ResourceHandle` class defines the elements of the `resources` field of
`ComponentInstance`:
```python
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
```
The `rt` and `rep` fields of `ResourceHandle` store the `rt` and `rep`
parameters passed to the `resource.new` call that created this handle. The
`rep` field is currently fixed to be an `i32`, but will be generalized in the
future to other types.

The `own` field indicates whether this element was created from an `own` type
(or, if false, a `borrow` type).

The `borrow_scope` field stores the `Task` that lowered the borrowed handle as a
parameter. When a component only uses sync-lifted exports, due to lack of
reentrance, there is at most one `Task` alive in a component instance at any
time and thus an optimizing implementation doesn't need to store the `Task`
per `ResourceHandle`.

The `num_lends` field maintains a conservative approximation of the number of
live handles that were lent from this `own` handle (by calls to `borrow`-taking
functions). This count is maintained by the `ImportCall` bookkeeping functions
(above) and is ensured to be zero when an `own` handle is dropped.

The `ResourceType` class represents a runtime instance of a resource type that
has been created either by the host or a component instance (where multiple
component instances of the same static component create multiple `ResourceType`
instances). `ResourceType` Python object identity is used by trapping guards on
the `rt` field of `ResourceHandle` (above) and thus resource type equality is
*not* defined structurally (on the contents of `ResourceType`).
```python
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
```


#### Buffer State

A "buffer" is an abstract region of memory that can either be read-from or
written-to. This region of memory can either be owned by the host or by wasm.
Currently wasm memory is always 32-bit linear memory, but soon 64-bit and GC
memory will be added. Thus, buffers provide an abstraction over at least 4
different "kinds" of memory.

(Currently, buffers are only created implicitly as part of stream and future
built-ins such as `stream.read`. However, in the
[future](https://github.com/WebAssembly/component-model/issues/369#issuecomment-2248574765),
explicit component-level buffer types and canonical built-ins may be added to
allow explicitly creating buffers and passing them between components.)

All buffers have an associated component-level value type `t` and a `remain`
method that returns how many `t` values may still be read or written. Thus
buffers hide their original/complete size. A "readable buffer" allows reading
`t` values *from* the buffer's memory. A "writable buffer" allows writing `t`
values *into* the buffer's memory. Buffers are represented by the following 3
abstract Python classes:
```python
class Buffer:
  MAX_LENGTH = 2**30 - 1
  t: ValType
  remain: Callable[[], int]

class ReadableBuffer(Buffer):
  read: Callable[[int], list[any]]

class WritableBuffer(Buffer):
  write: Callable[[list[any]]]
```
As preconditions (internally ensured by the Canonical ABI code below):
* `read` may only be passed a positive number less than or equal to `remain`
* `write` may only be passed a non-empty list of length less than or equal to
  `remain` containing values of type `t`

Since `read` and `write` are synchronous Python functions, buffers inherently
guarantee synchronous access to a fixed-size backing memory and are thus
distinguished from streams (which provide *asynchronous* operations for reading
and writing an unbounded number of values to potentially-different regions of
memory over time).

The `ReadableBuffer` and `WritableBuffer` abstract classes may either be
implemented by the host or by another wasm component. In the latter case, these
abstract classes are implemented by the concrete `ReadableBufferGuestImpl` and
`WritableBufferGuestImpl` classes which eagerly check alignment and range
when the buffer is constructed so that `read` and `write` are infallible
operations (modulo traps):
```python
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
```
When `t` is `None` (arising from `stream` and `future` with empty element
types), the core-wasm-supplied `ptr` is entirely ignored, while the `length`
and `progress` are still semantically meaningful. Source bindings may represent
this case with a generic stream/future of [unit] type or a distinct type that
conveys events without values.

The `load_list_from_valid_range` and `store_list_into_valid_range` functions
that do all the heavy lifting are shared with function parameter/result lifting
and lowering and defined below.


#### Context-Local Storage

The `ContextLocalStorage` class implements [context-local storage], with each
new `Task` getting a fresh, zero-initialized `ContextLocalStorage` that can be
accessed by core wasm code using `canon context.{get,set}`. (In the future,
when threads are integrated, each `thread.spawn`ed thread would also get a
fresh, zero-initialized `ContextLocalStorage`.)
```python
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
```


#### Task State

A `Task` object is created for each call to `canon_lift` and is implicitly
threaded through all core function calls. This implicit `Task` parameter
represents the "[current task]". This section will introduce the `Task` class
in pieces, starting with the fields and initialization:
```python
class Task:
  opts: CanonicalOptions
  inst: ComponentInstance
  ft: FuncType
  caller: Optional[Task]
  on_return: Optional[Callable]
  on_block: Callable[[Awaitable], Awaitable]
  num_subtasks: int
  num_borrows: int
  context: ContextLocalStorage

  def __init__(self, opts, inst, ft, caller, on_return, on_block):
    self.opts = opts
    self.inst = inst
    self.ft = ft
    self.caller = caller
    self.on_return = on_return
    self.on_block = on_block
    self.num_subtasks = 0
    self.num_borrows = 0
    self.context = ContextLocalStorage()
```
Using a conservative syntactic analysis of a complete component, an optimizing
implementation can statically eliminate fields when a particular feature (such
as `borrow` or `async`) is not present in the component definition.

There is a global singleton `asyncio.Lock` named `Task.current` upon which all
non-[current task]s are parked `await`ing. When the Canonical ABI specifies
that the current task may cooperatively yield to another task, it does so by
having the current task release and reacquire `Task.current`, allowing a
non-current task to acquire `Task.current` to become the current task. Without
this extra layer of synchronization, normal Python `async`/`await` semantics
would imply that execution could switch at *any* `await` point, which would
behave more like preemptive multi-threading instead of cooperative asynchronous
functions.

By default, current-task-switching happens when a task blocks on an
`asyncio.Awaitable` to resolve via the `sync_on_block` function:
```python
  current = asyncio.Lock()

  async def sync_on_block(a: Awaitable):
    Task.current.release()
    v = await a
    await Task.current.acquire()
    return v
```
The `on_block` field of `Task` either stores `sync_on_block` or
`async_on_block` (defined below) and is implicitly supplied as an argument by
the task's caller to allow the caller to configure what happens when the callee
blocks.

The `Task.enter` method is called immediately after constructing a `Task` to
perform all the guards and lowering necessary before the task's core wasm entry
point can start running:
```python
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
```
The `trap_if_on_the_stack` method (defined next) prevents unexpected
reentrance, enforcing a [component invariant].

The `may_enter` guard enforces [backpressure](Async.md#backpressure).
Backpressure allows an overloaded component instance to safely avoid being
forced to continually allocate more memory (for lowered arguments and per-task
state) until OOM. Backpressure is also applied automatically when attempting
to enter a component instance that is in the middle of a synchronous operation
and thus non-reentrant. If `may_enter` (defined below) signals that
backpressure is needed, `enter` blocks by putting itself into the
per-`ComponentInstance` `pending_tasks` queue and blocking until released by
`maybe_start_pending_task` (defined below). The `or self.inst.pending_tasks`
disjunct ensures fairness, preventing continual new tasks from starving pending
tasks.

The `calling_sync_export` flag set by `enter` (and cleared by `exit`) is used
by `may_enter` to prevent sync-lifted export calls from overlapping.

Once all the guards and bookkeeping has been done, the `enter` method lowers
the given arguments into the callee's memory (possibly executing `realloc`)
returning the final set of flat arguments to pass into the core wasm callee.

The `Task.trap_if_on_the_stack` method called by `enter` prevents reentrance
using the `caller` field of `Task` which points to the task's supertask in the
async call tree defined by [structured concurrency]. Structured concurrency
is necessary to distinguish between the deadlock-hazardous kind of reentrance
(where the new task is a transitive subtask of a task already running in the
same component instance) and the normal kind of async reentrance (where the new
task is just a sibling of any existing tasks running in the component
instance). Note that, in the [future](Async.md#TODO), there will be a way for a
function to opt in (via function type attribute) to the hazardous kind of
reentrance, which will nuance this test.
```python
  def trap_if_on_the_stack(self, inst):
    c = self.caller
    while c is not None:
      trap_if(c.inst is inst)
      c = c.caller
```
An optimizing implementation can avoid the O(n) loop in `trap_if_on_the_stack`
in several ways:
* Reentrance by a child component can (often) be statically ruled out when the
  parent component doesn't both lift and lower the child's imports and exports
  (i.e., "donut wrapping").
* Reentrance of the root component by the host can either be asserted not to
  happen or be tracked in a per-root-component-instance flag.
* When a potentially-reenterable child component only lifts and lowers
  synchronously, reentrance can be tracked in a per-component-instance flag.
* For the remaining cases, the live instances on the stack can be maintained in
  a packed bit-vector (assigning each potentially-reenterable async component
  instance a static bit position) that is passed by copy from caller to callee.

The `Task.may_enter` method called by `enter` blocks a new task from starting
for three reasons:
* The core wasm code has explicitly indicated that it is overloaded by calling
  `task.backpressure` to set the `backpressure` field of `Task`.
* The component instance is currently blocked on a synchronous call from core
  wasm into a Canonical ABI built-in and is thus not currently in a reentrant
  state.
* The current pending call is to a synchronously-lifted export and there is
  already a synchronously-lifted export in progress.
```python
  def may_enter(self, pending_task):
    return not self.inst.backpressure and \
           not self.inst.calling_sync_import and \
           not (self.inst.calling_sync_export and pending_task.opts.sync)
```
Notably, the above definition of `may_enter` only prevents *synchronously*
lifted tasks from overlapping. *Asynchronously* lifted tasks are allowed to
freely overlap (with each other and synchronously-lifted tasks). This allows
purely-synchronous toolchains to stay simple and ignore asynchrony while
enabling more-advanced hybrid use cases (such as "background tasks"), putting
the burden of not interfering with the synchronous tasks on the toolchain.

The `Task.maybe_start_pending_task` method unblocks pending tasks enqueued by
`enter` above once `may_enter` is true for the pending task. One key property
ensured by the trio of `enter`, `may_enter` and `maybe_start_pending_task` is
that `pending_tasks` are only allowed to start one at a time, ensuring that if
an overloaded component instance enables backpressures, builds up a large queue
of pending tasks, and then disables backpressure, there will not be a
thundering herd of tasks started all at once that OOM the component before it
has a chance to re-enable backpressure. To ensure this property, the
`starting_pending_task` flag is set here and cleared when the pending task
actually resumes execution in `enter`, preventing more pending tasks from being
started in the interim. Lastly, `maybe_start_pending_task` is only called at
specific points (`wait_on` and `exit`, below) where the core wasm code has had
the opportunity to re-enable backpressure if need be.
```python
  def maybe_start_pending_task(self):
    if self.inst.starting_pending_task:
      return
    for i,(pending_task,pending_future) in enumerate(self.inst.pending_tasks):
      if self.may_enter(pending_task):
        self.inst.pending_tasks.pop(i)
        self.inst.starting_pending_task = True
        pending_future.set_result(None)
        return
```
Notably, the loop in `maybe_start_pending_task` allows pending async tasks to
start even when there is a blocked pending sync task ahead of them in the
`pending_tasks` queue.

The `Task.yield_` method is called by `canon yield` or, when a `callback`
is used, when core wasm returns the "yield" code to the event loop. Yielding
allows the runtime to switch execution to another task without having to wait
for any external I/O as emulated in the Python definition by waiting on
`asyncio.sleep(0)` using the `wait_on` method (defined next):
```python
  async def yield_(self, sync):
    await self.wait_on(asyncio.sleep(0), sync)
```

The `Task.wait_on` method defines how to block the current task until a given
Python awaitable is resolved. By calling the `on_block` callback, `wait_on`
allows other tasks to execute before the current task resumes, but *which*
other tasks depends on the `sync` boolean parameter:

When blocking *synchronously*, only tasks in *other* component instances may
execute; the current component instance must not observe any interleaved
execution. This is achieved by setting `calling_sync_import` during
`on_block`, which is checked by both `may_enter` (to prevent reentrance) as
well as `wait_on` itself in the asynchronous case (to prevent resumption of
already-started async tasks).

When blocking *asynchronously*, other tasks in the *same* component instance
may execute. In this case, it's possible that one of those other tasks
performed a synchronous `wait_on` (which set `calling_sync_import`) in which
case *this* task must wait until it is reenabled. This reenablement is
signalled asynchronously via the `async_waiting_tasks` [`asyncio.Condition`].
```python
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
        Task.current.release()
        await self.async_waiting_tasks.wait()
    return v
```

The `Task.call_sync` method is used by `canon_lower` to make a synchronous call
to `callee` given `*args` and works just like the `sync` case of `wait_on`
above except that `call_sync` avoids unconditionally blocking (by calling
`on_block`). Instead, the caller simply passes its own `on_call` callback to
the callee, so that the caller blocks iff the callee blocks. This means that
N-deep synchronous callstacks avoid the overhead of async calls if none of the
calls in the stack actually block on external I/O.
```python
  async def call_sync(self, callee, *args):
    assert(not self.inst.calling_sync_import)
    self.inst.calling_sync_import = True
    v = await callee(*args, self.on_block)
    self.inst.calling_sync_import = False
    self.async_waiting_tasks.notify_all()
    return v
```

The `Task.call_async` method is used by `canon_lower` to make an asynchronous
call to `callee`. To implement an "asynchronous" call using Python's `asyncio`
machinery, `call_async` spawns the call to `callee` in a separate
`asyncio.Task` and waits until either this `asyncio.Task` blocks (by calling
the given `async_on_block` callback) or returns without blocking:
```python
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
```
An important behavioral property specified by this code is that whether or not
the callee blocks, control flow is unconditionally transferred back to the
`async` caller without releasing the `Task.current` lock, meaning that no other
tasks get to run (like `call_sync` and unlike `wait_on`). In particular, the
`acquire()` and `release()` of `Task.current` in this code only happens in the
callee's `asyncio.Task` once the callee has blocked the first time and
transferred control flow back to the `async` caller. The net effect is that an
async call starts like a normal sync call and only forks off an async execution
context) if the callee blocks. This is useful for enabling various
optimizations biased towards the non-blocking case.

Another important behavioral property specified by this code is that, when an
`async` call is made, even if the callee makes nested synchronous
cross-component calls, if *any* transitive callee blocks, control flow is
promptly returned back to the `async` caller, setting aside the whole
synchronous segment of the call stack that blocked. This is enabled by (and the
entire point of) `on_block` being a dynamical closure value determined by the
caller.

As a side note: this whole idiosyncratic use of `asyncio` (with `Task.current`
and `on_block`) is emulating algebraic effects as realized by the Core
WebAssembly [stack-switching] proposal. If Python had the equivalent of
[stack-switching]'s `suspend` and `resume` instructions, `Task.current` and
`on_block` would disappear; all callsites of `on_block` would `suspend` with a
`block` effect and `call_async` would `resume` with a `block` handler. Indeed,
a runtime that has implemented [stack-switching] could implement `async`
by compiling down to Core WebAssembly using `cont.new`/`suspend`/`resume`.

The `Task.return_` method is called by either `canon_task_return` or
`canon_lift` (both defined below) to lift result values and pass them to the
caller using the caller's `on_return` callback. Using a callback instead of
simply returning the values from `canon_lift` enables the callee to keep
executing after returning its results. There is a dynamic error if
`task.return` is not called exactly once and if the callee has not dropped all
borrowed handles by the time `task.return` is called. This means that the
caller can assume that ownership all its lent borrowed handles has been
returned to it when it is notified that the `Subtask` has reached the
`RETURNED` state.
```python
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
```
The maximum flattened core wasm values depends on whether this is a normal
synchronous call (in which return values are returned by core wasm) or a newer
async or synchronous-using-`always-task-return` call, in which case return
values are passed as parameters to `canon task.return`.

Lastly, the `Task.exit` method is called when the task has signalled that it
intends to exit. This method guards that the various obligations of the callee
implied by the Canonical ABI have in fact been met and also performs final
bookkeeping that matches initial bookkeeping performed by `enter`. Lastly, when
a `Task` exits, it attempts to start another pending task which, in particular,
may be a synchronous task unblocked by the clearing of `calling_sync_export`.
```python
  def exit(self):
    assert(Task.current.locked())
    trap_if(self.num_subtasks > 0)
    trap_if(self.on_return)
    assert(self.num_borrows == 0)
    if self.opts.sync:
      assert(self.inst.calling_sync_export)
      self.inst.calling_sync_export = False
    self.maybe_start_pending_task()
```


#### Waitable State

A "waitable" is anything that can be stored in the component instance's
`waitables` table. Currently, there are 5 different kinds of waitables:
[subtasks](Async.md#subtask-and-supertask) and the 4 combinations of the
[readable and writable ends of futures and streams](Async.md#streams-and-futures).

Waitables deliver "events" which are values of the following `EventTuple` type.
The two `int` "payload" fields of `EventTuple` store core wasm `i32`s and are
to be interpreted based on the `EventCode`. The meaning of the different
`EventCode`s and their payloads will be introduced incrementally below by the
code that produces the events (specifically, in `subtask_event` and
`copy_event`).
```python
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
```

The `Waitable` class factors out the state and behavior common to all 5 kinds
of waitables, which are each defined as subclasses of `Waitable` below. Every
`Waitable` can store at most one pending event in its `pending_event` field
which will be delivered to core wasm as soon as the core wasm code explicitly
waits on this `Waitable` (which may take an arbitrarily long time). A
`pending_event` is represented in the Python code below as a *closure* so that
the closure can specify behaviors that trigger *right before* events are
delivered to core wasm and so that the closure can compute the event based on
the state of the world at delivery time (as opposed to when `pending_event` was
first set). Currently, `pending_event` holds a closure of either the
`subtask_event` or `copy_event` functions defined below. An optimizing
implementation would avoid closure allocation by inlining a union containing
the closure fields directly in the `Waitable` element of the `waitables` table.

A waitable can belong to at most one "waitable set" (defined next) which is
referred to by the `maybe_waitable_set` field. A `Waitable`'s `pending_event`
is delivered when core wasm code waits on a task's waitable set (via
`task.wait` or, when using `callback`, by returning to the event loop). The
`maybe_has_pending_event` field of `WaitableSet` stores an [`asyncio.Event`]
boolean which is used to wait for *any* `Waitable` element to make progress. As
the name implies, `maybe_has_pending_event` is allowed to have false positives
(but not false negatives) and thus it's not `clear()`ed even when a
`Waitable`'s `pending_event` is cleared (because other `Waitable`s in the set
may still have a pending event).

In addition to being waited on as a member of a task, a `Waitable` can also be
waited on individually (e.g., as part of a synchronous `stream.cancel-read`).
This is enabled by the `has_pending_event_` field which stores an
[`asyncio.Event`] boolean that `is_set()` iff `pending_event` is set.

Based on all this, the `Waitable` class is defined as follows:
```python
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
```

A "waitable set" contains a collection of waitables that can be waited on or
polled for *any* element to make progress. Although the `WaitableSet` class
below represents `elems` as a `list` and implements `poll` with an O(n) search,
because a waitable can be associated with at most one set and can contain at
most one pending event, a real implementation could instead store a list of
waitables-with-pending-events as a linked list embedded directly in the
`Waitable` table element to avoid the separate allocation while providing O(1)
polling.
```python
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
```
The `WaitableSet.drop` method traps if dropped while it still contains elements
(whose `Waitable.waitable_set` field would become dangling) or if it is being
waited-upon by another `Task`.

Note: the `random.shuffle` in `poll` is meant to give runtimes the semantic
freedom to schedule delivery of events non-deterministically (e.g., taking into
account priorities); runtimes do not have to literally randomize event
delivery.


#### Subtask State

While `canon_lift` creates `Task` objects when called, `canon_lower` creates
`Subtask` objects when called. If the callee (being `canon_lower`ed) is another
component's (`canon_lift`ed) function, there will thus be a `Subtask`+`Task`
pair created. However, if the callee is a host-defined function, the `Subtask`
will stand alone. Thus, in general, the call stack at any point in time when
wasm calls a host-defined import will have the form:
```
[Host caller] -> [Task] -> [Subtask+Task]* -> [Subtask] -> [Host callee]
```

The `Subtask` class is simpler than `Task` and only manages a few fields of
state that are relevant to the caller. As with `Task`, this section will
introduce `Subtask` incrementally, starting with its fields and initialization:
```python
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
```
The `state` field of `Subtask` holds a `CallState` enum value (defined above as
part of the definition of `EventCode`) that describes the callee's current
state along the linear progression from [`STARTING`](Async.md#backpressure) to
`STARTED` to [`RETURNED`](Async.md#returning).

Although `Subtask` derives `Waitable`, `__init__` does not initialize the
`Waitable` base object. Instead, the `Waitable` base is only initialized when
the `Subtask` is added to the component instance's `waitables` table which in
turn only happens if the call is `async` *and* blocks. In this case, the
`Subtask.add_to_waitables` method is called:
```python
  def add_to_waitables(self, task):
    assert(not self.supertask)
    self.supertask = task
    self.supertask.num_subtasks += 1
    Waitable.__init__(self)
    return task.inst.waitables.add(self)
```
The `num_subtasks` increment ensures that the parent `Task` cannot `exit`
without having waited for all its subtasks to return (or, in the
[future](Async.md#TODO) be cancelled), thereby preserving [structured
concurrency].

The `Subtask.add_lender` method is called by `lift_borrow` (below). This method
increments the `num_lends` counter on the handle being lifted, which is guarded
to be zero by `canon_resource_drop` (below). The `Subtask.finish` method is
called when the subtask returns its value to the caller, at which point all the
borrowed handles are logically returned to the caller by decrementing all the
`num_lend` counts that were initially incremented.
```python
  def add_lender(self, lending_handle):
    assert(not self.finished and self.state != CallState.RETURNED)
    lending_handle.num_lends += 1
    self.lenders.append(lending_handle)

  def finish(self):
    assert(not self.finished and self.state == CallState.RETURNED)
    for h in self.lenders:
      h.num_lends -= 1
    self.finished = True
```
Note, the `lenders` list usually has a fixed size (in all cases except when a
function signature has `borrow`s in `list`s or `stream`s) and thus can be
stored inline in the native stack frame.

The `Subtask.drop` method is only called for `Subtask`s that have been
`add_to_waitables()`ed and checks that the callee has been allowed to return
its value to the caller.
```python
  def drop(self):
    trap_if(not self.finished)
    assert(self.state == CallState.RETURNED)
    self.supertask.num_subtasks -= 1
    Waitable.drop(self)
```


#### Stream State

Values of `stream` type are represented in the Canonical ABI as `i32` indices
into the component instance's `waitables` table referring to either the
[readable or writable end](Async.md#streams-and-futures) of a stream. Reading
from the readable end of a stream is achieved by calling `stream.read` and
supplying a `WritableBuffer`. Conversely, writing to the writable end of a
stream is achieved by calling `stream.write` and supplying a `ReadableBuffer`.
The runtime waits until both a readable and writable buffer have been supplied
and then performs a direct copy between the two buffers. This rendezvous-based
design avoids the need for an intermediate buffer and copy (unlike, e.g., a
Unix pipe; a Unix pipe would instead be implemented as a resource type owning
the buffer memory and *two* streams; on going in and one coming out).

As with functions and buffers, native host code can be on either side of a
stream. Thus, streams are defined in terms of an abstract interface that can be
implemented and consumed by wasm or host code (with all {wasm,host} pairings
being possible and well-defined). Since a `stream` in a function parameter or
result type always represents the transfer of the *readable* end of a stream,
the abstract stream interface is `ReadableStream` and allows a (wasm or host)
client to asynchronously read multiple values from a (wasm or host) producer.
(The absence of a dual `WritableStream` abstract interface reflects the fact
that there is no Component Model type for passing the writable end of a
stream.)
```python
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
```
The key operation is `read` which works as follows:
* `read` is non-blocking, returning `'blocked'` if it would have blocked.
* The `On*` callbacks are only called *after* `read` returns `'blocked'`.
* `OnCopyDone` is called to indicate that the caller has regained ownership of
  the buffer.
* `OnPartialCopy` is called to indicate a partial write has been made to the
  buffer, but there may be further writes made in the future, so the caller
  has *not* regained ownership of the buffer.
* The `RevokeBuffer` callback passed to `OnPartialCopy` allows the caller
  of `read` to *synchronously* regain ownership of the buffer.
* `cancel` is also non-blocking, but does **not** guarantee that ownership of
  the buffer has been returned; `cancel` only lets the caller *request* that
  `read` call one of the `On*` callbacks ASAP (which may or may not happen
  during `cancel`).
* The client may not call `read` or `close` while there is still an unfinished
  `read` of the same `ReadableStream`.

The `On*` callbacks are a spec-internal detail used to specify the allowed
concurrent behaviors of `stream.{read,write}` and not exposed directly to core
wasm code. Specifically, the point of the `On*` callbacks is to specify that
*multiple* writes are allowed into the same `WritableBuffer` up until the point
where either the buffer is full (at which point `OnCopyDone` is called) or the
calling core wasm code receives the `STREAM_READ` progress event (in which case
`RevokeBuffer` is called). This reduces the number of task-switches required
by the spec, particularly when streaming between two components.

The `ReadableStreamGuestImpl` class implements `ReadableStream` for streams
created by wasm (via `stream.new`) and tracks the common state shared by both
the readable and writable ends of streams (defined below). Introducing the
class in chunks, starting with the fields and initialization:
```python
class ReadableStreamGuestImpl(ReadableStream):
  impl: ComponentInstance
  closed_: bool
  maybe_errctx: Optional[ErrorContext]
  pending_buffer: Optional[Buffer]
  pending_on_partial_copy: Optional[OnPartialCopy]
  pending_on_copy_done: Optional[OnCopyDone]

  def __init__(self, t, inst):
    self.t = t
    self.impl = inst
    self.closed_ = False
    self.maybe_errctx = None
    self.reset_pending()

  def reset_pending(self):
    self.pending_buffer = None
    self.pending_on_partial_copy = None
    self.pending_on_copy_done = None
```
The `impl` field records the component instance that created this stream and is
used by `lower_stream` below.

If set, the `pending_*` fields record the `Buffer` and `On*` callbacks of a
`read` or `write` that is waiting to rendezvous with a complementary `write` or
`read`. Closing the readable or writable end of a stream or cancelling a `read`
or `write` notifies any pending `read` or `write` via its `OnCopyDone`
callback, which lets the other side know that ownership of the `Buffer` has
been returned:
```python
  def reset_and_notify_pending(self):
    pending_on_copy_done = self.pending_on_copy_done
    self.reset_pending()
    pending_on_copy_done()

  def cancel(self):
    self.reset_and_notify_pending()

  def close(self, maybe_errctx):
    if not self.closed_:
      self.closed_ = True
      self.maybe_errctx = maybe_errctx
      if self.pending_buffer:
        self.reset_and_notify_pending()

  def closed(self):
    return self.closed_

  def closed_with(self):
    assert(self.closed_)
    return self.maybe_errctx
```
While the abstract `ReadableStream` interface *allows* `cancel` to return
without having returned ownership of the buffer (which, in general, is
necessary for [various][OIO] [host][io_uring] APIs), when *wasm* is
implementing the stream, `cancel` always returns ownership of the buffer
immediately.

Note that `cancel` and `close` notify in opposite directions:
* `cancel` *must* be called on a readable or writable end with an operation
  pending, and thus `cancel` notifies the same end that called it.
* `close` *must not* be called on a readable or writable end with an operation
  pending, and thus `close` notifies the opposite end.

Finally, the meat of the class is the `read` method that is called through the
abstract `ReadableStream` interface (by the host or another component). There
is also a symmetric `write` method that follows the same rules as `read`,
but in the opposite direction. Both are implemented by a single underlying
`copy` method parameterized by the direction of the copy:
```python
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
```

Given the above, we can define the `{Readable,Writable}StreamEnd` classes that
are actually stored in the `waitables` table. The classes are almost entirely
symmetric, with the only difference being that `WritableStreamEnd` has an
additional `paired` boolean field that is used by `{lift,lower}_stream` below
to ensure that there is at most one readable end of a stream. The `copying`
field tracks whether there is an asynchronous read or write in progress and is
maintained by the definitions of `stream.{read,write}` below. Importantly,
`paired`, `copying`, and the inherited fields of `Waitable` are per-*end*, not
per-*stream* (unlike the fields of `ReadableStreamGuestImpl` shown above, which
are per-stream and shared by both ends via their common `stream` field).
```python
class StreamEnd(Waitable):
  stream: ReadableStream
  copying: bool

  def __init__(self, stream):
    Waitable.__init__(self)
    self.stream = stream
    self.copying = False

  def drop(self, maybe_errctx):
    trap_if(self.copying)
    self.stream.close(maybe_errctx)
    Waitable.drop(self)

class ReadableStreamEnd(StreamEnd):
  def copy(self, dst, on_partial_copy, on_copy_done):
    return self.stream.read(dst, on_partial_copy, on_copy_done)

class WritableStreamEnd(StreamEnd):
  paired: bool = False
  def copy(self, src, on_partial_copy, on_copy_done):
    return self.stream.write(src, on_partial_copy, on_copy_done)
```
Dropping a stream end from the `waitables` table while an asynchronous read or
write is in progress traps since the async read or write cannot be cancelled
without blocking and `drop` (called by `stream.close-{readable,writable}`) is
synchronous and non-blocking. This means that client code must take care to
wait for these operations to finish before closing.

The `{Readable,Writable}StreamEnd.copy` method is called polymorphically by the
shared definition of `stream.{read,write}` below. While the static type of
`StreamEnd.stream` is `ReadableStream`, a `WritableStreamEnd` always points to
a `ReadableStreamGuestImpl` object which is why `WritableStreamEnd.copy` can
unconditionally call `stream.write`.


#### Future State

Given the above definitions for `stream`, `future` can be simply defined as a
`stream` that transmits only 1 value before automatically closing itself. This
can be achieved by simply wrapping the `on_copy_done` callback (defined above)
and closing once a value has been read-from or written-to the given buffer:
```python
class FutureEnd(StreamEnd):
  def close_after_copy(self, copy_op, buffer, on_copy_done):
    assert(buffer.remain() == 1)
    def on_copy_done_wrapper():
      if buffer.remain() == 0:
        self.stream.close(maybe_errctx = None)
      on_copy_done()
    ret = copy_op(buffer, on_partial_copy = None, on_copy_done = on_copy_done_wrapper)
    if ret == 'done' and buffer.remain() == 0:
      self.stream.close(maybe_errctx = None)
    return ret

class ReadableFutureEnd(FutureEnd):
  def copy(self, dst, on_partial_copy, on_copy_done):
    return self.close_after_copy(self.stream.read, dst, on_copy_done)

class WritableFutureEnd(FutureEnd):
  paired: bool = False
  def copy(self, src, on_partial_copy, on_copy_done):
    return self.close_after_copy(self.stream.write, src, on_copy_done)
  def drop(self, maybe_errctx):
    trap_if(not self.stream.closed() and not maybe_errctx)
    FutureEnd.drop(self, maybe_errctx)
```
The `future.{read,write}` built-ins fix the buffer length to `1`, ensuring the
`assert(buffer.remain() == 1)` holds. Because of this, there are no partial
copies and `on_partial_copy` is never called.

The additional `trap_if` in `WritableFutureEnd.drop` ensures that the only
valid way close a future without writing its value is to close it in error.


### Despecialization

[In the explainer][Type Definitions], component value types are classified as
either *fundamental* or *specialized*, where the specialized value types are
defined by expansion into fundamental value types. In most cases, the canonical
ABI of a specialized value type is the same as its expansion so, to avoid
repetition, the other definitions below use the following `despecialize`
function to replace specialized value types with their expansion:
```python
def despecialize(t):
  match t:
    case TupleType(ts)       : return RecordType([ FieldType(str(i), t) for i,t in enumerate(ts) ])
    case EnumType(labels)    : return VariantType([ CaseType(l, None) for l in labels ])
    case OptionType(t)       : return VariantType([ CaseType("none", None), CaseType("some", t) ])
    case ResultType(ok, err) : return VariantType([ CaseType("ok", ok), CaseType("error", err) ])
    case _                   : return t
```
The specialized value types `string` and `flags` are missing from this list
because they are given specialized canonical ABI representations distinct from
their respective expansions.


### Type Predicates

The `contains_borrow` and `contains_async_value` predicates return whether the
given type contains a `borrow` or `future/`stream`, respectively.
```python
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
```

### Alignment

Each value type is assigned an [alignment] which is used by subsequent
Canonical ABI definitions. Presenting the definition of `alignment` piecewise,
we start with the top-level case analysis:
```python
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
```

List alignment is the same as tuple alignment when the length is fixed and
otherwise uses the alignment of pointers.
```python
def alignment_list(elem_type, maybe_length):
  if maybe_length is not None:
    return alignment(elem_type)
  return 4
```

Record alignment is tuple alignment, with the definitions split for reuse below:
```python
def alignment_record(fields):
  a = 1
  for f in fields:
    a = max(a, alignment(f.t))
  return a
```

As an optimization, `variant` discriminants are represented by the smallest integer
covering the number of cases in the variant (with cases numbered in order from
`0` to `len(cases)-1`). Depending on the payload type, this can allow more
compact representations of variants in memory. This smallest integer type is
selected by the following function, used above and below:
```python
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
```

As an optimization, `flags` are represented as packed bit-vectors. Like variant
discriminants, `flags` use the smallest integer that fits all the bits, falling
back to sequences of `i32`s when there are more than 32 flags.
```python
def alignment_flags(labels):
  n = len(labels)
  assert(0 < n <= 32)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4
```


### Element Size

Each value type is also assigned an `elem_size` which is the number of bytes
used when values of the type are stored as elements of a `list`. Having this
byte size be a static property of the type instead of attempting to use a
variable-length element-encoding scheme both simplifies the implementation and
maps well to languages which represent `list`s as random-access arrays. Empty
types, such as records with no fields, are not permitted, to avoid
complications in source languages.
```python
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
```

### Loading

The `load` function defines how to read a value of a given value type `t`
out of linear memory starting at offset `ptr`, returning the value represented
as a Python value. Presenting the definition of `load` piecewise, we start with
the top-level case analysis:
```python
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
```

Integers are loaded directly from memory, with their high-order bit interpreted
according to the signedness of the type.
```python
def load_int(cx, ptr, nbytes, signed = False):
  return int.from_bytes(cx.opts.memory[ptr : ptr+nbytes], 'little', signed = signed)
```

Integer-to-boolean conversions treats `0` as `false` and all other bit-patterns
as `true`:
```python
def convert_int_to_bool(i):
  assert(i >= 0)
  return bool(i)
```

Floats are loaded directly from memory, with the sign and payload information
of NaN values discarded. Consequently, there is only one unique NaN value per
floating-point type. This reflects the practical reality that some languages
and protocols do not preserve these bits. In the Python code below, this is
expressed as canonicalizing NaNs to a particular bit pattern.

See the comments about lowering of float values for a discussion of possible
optimizations.
```python
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
```

An `i32` is converted to a `char` (a [Unicode Scalar Value]) by dynamically
testing that its unsigned integral value is in the valid [Unicode Code Point]
range and not a [Surrogate]:
```python
def convert_i32_to_char(cx, i):
  assert(i >= 0)
  trap_if(i >= 0x110000)
  trap_if(0xD800 <= i <= 0xDFFF)
  return chr(i)
```

Strings are loaded from two `i32` values: a pointer (offset in linear memory)
and a number of bytes. There are three supported string encodings in [`canonopt`]:
[UTF-8], [UTF-16] and `latin1+utf16`. This last options allows a *dynamic*
choice between [Latin-1] and UTF-16, indicated by the high bit of the second
`i32`. String values include their original encoding and byte length as a
"hint" that enables `store_string` (defined below) to make better up-front
allocation size choices in many cases. Thus, the value produced by
`load_string` isn't simply a Python `str`, but a *tuple* containing a `str`,
the original encoding and the original byte length.
```python
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
```

Error context values are lifted directly from the per-component-instance
`error_contexts` table:
```python
def lift_error_context(cx, i):
  return cx.inst.error_contexts.get(i)
```

Lists and records are loaded by recursively loading their elements/fields:
```python
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
```
As a technical detail: the `align_to` in the loop in `load_record` is
guaranteed to be a no-op on the first iteration because the record as
a whole starts out aligned (as asserted at the top of `load`).

Variants are loaded using the order of the cases in the type to determine the
case index, assigning `0` to the first case, `1` to the next case, etc.
While the code below appears to perform case-label lookup at runtime, a normal
implementation can build the appropriate index tables at compile-time so that
variant-passing is always O(1) and not involving string operations.
```python
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
```

Flags are converted from a bit-vector to a dictionary whose keys are
derived from the ordered labels of the `flags` type. The code here takes
advantage of Python's support for integers of arbitrary width.
```python
def load_flags(cx, ptr, labels):
  i = load_int(cx, ptr, elem_size_flags(labels))
  return unpack_flags_from_int(i, labels)

def unpack_flags_from_int(i, labels):
  record = {}
  for l in labels:
    record[l] = bool(i & 1)
    i >>= 1
  return record
```

`own` handles are lifted by removing the handle from the current component
instance's handle table, so that ownership is *transferred* to the lowering
component. The lifting operation fails if unique ownership of the handle isn't
possible, for example if the index was actually a `borrow` or if the `own`
handle is currently being lent out as borrows.
```python
def lift_own(cx, i, t):
  h = cx.inst.resources.remove(i)
  trap_if(h.rt is not t.rt)
  trap_if(h.num_lends != 0)
  trap_if(not h.own)
  return h.rep
```
The abstract lifted value for handle types is currently just the internal
resource representation `i32`, which is kept opaque from the receiving
component (it's stored in the handle table and only accessed indirectly via
index). (This assumes that resource representations are immutable. If
representations were to become mutable, the address of the mutable cell would
be passed as the lifted value instead.)

In contrast to `own`, `borrow` handles are lifted by reading the representation
from the source handle, leaving the source handle intact in the current
component instance's handle table:
```python
def lift_borrow(cx, i, t):
  assert(isinstance(cx.borrow_scope, Subtask))
  h = cx.inst.resources.get(i)
  trap_if(h.rt is not t.rt)
  cx.borrow_scope.add_lender(h)
  return h.rep
```
The `Subtask.add_lender` participates in the enforcement of the dynamic borrow
rules, which keep the source handle alive until the end of the call (as a
conservative upper bound on how long the `borrow` handle can be held). Note
that `add_lender` is called for borrowed source handles so that they must be
kept alive until the subtask completes, which in turn prevents the current task
from `task.return`ing while its non-returned subtask still holds a
transitively-borrowed handle.

Streams and futures are lifted in almost the same way, with the only difference
being that it is a dynamic error to attempt to lift a `future` that has already
been successfully read (which will leave it `closed()`):
```python
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
```
Since the `waitables` table is heterogeneous, dynamic checks are
necessary to ensure that `i` index actually refers to stream/future end
of the correct type.

Lifting the readable end (of a stream or future) transfers ownership of the
readable end and traps if a read was in progress (which would now be dangling).

Lifting the writable end of a stream leaves the writable end in place (allowing
there to be a write in progress) and shares the writable end's contained
`ReadableStreamGuestImpl` object with the readable end created by
`lower_stream`, pairing the two ends together. As an invariant, each stream can
have at most one readable and writable end, so the `paired` field of
`Writable{Stream,Future}End` is used to track whether there is already a
readable end and trapping if another would be created.


### Storing

The `store` function defines how to write a value `v` of a given value type
`t` into linear memory starting at offset `ptr`. Presenting the definition of
`store` piecewise, we start with the top-level case analysis:
```python
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
```

Integers are stored directly into memory. Because the input domain is exactly
the integers in range for the given type, no extra range checks are necessary;
the `signed` parameter is only present to ensure that the internal range checks
of `int.to_bytes` are satisfied.
```python
def store_int(cx, v, ptr, nbytes, signed = False):
  cx.opts.memory[ptr : ptr+nbytes] = int.to_bytes(v, nbytes, 'little', signed = signed)
```

Floats are stored directly into memory, with the sign and payload bits of NaN
values modified non-deterministically. This reflects the practical reality that
different languages, protocols and CPUs have different effects on NaNs.

Although this non-determinism is expressed in the Python code below as
generating a "random" NaN bit-pattern, native implementations do not need to
use the same "random" algorithm, or even any random algorithm at all. Hosts
may instead chose to canonicalize to an arbitrary fixed NaN value, or even to
the original value of the NaN before lifting, allowing them to optimize away
both the canonicalization of lifting and the randomization of lowering.

When a host implements the [deterministic profile], NaNs are canonicalized to
a particular NaN bit-pattern.
```python
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
```

The integral value of a `char` (a [Unicode Scalar Value]) is a valid unsigned
`i32` and thus no runtime conversion or checking is necessary:
```python
def char_to_i32(c):
  i = ord(c)
  assert(0 <= i <= 0xD7FF or 0xD800 <= i <= 0x10FFFF)
  return i
```

Storing strings is complicated by the goal of attempting to optimize the
different transcoding cases. In particular, one challenge is choosing the
linear memory allocation size *before* examining the contents of the string.
The reason for this constraint is that, in some settings where single-pass
iterators are involved (host calls and post-MVP [adapter functions]), examining
the contents of a string more than once would require making an engine-internal
temporary copy of the whole string, which the component model specifically aims
not to do. To avoid multiple passes, the canonical ABI instead uses a `realloc`
approach to update the allocation size during the single copy. A blind
`realloc` approach would normally suffer from multiple reallocations per string
(e.g., using the standard doubling-growth strategy). However, as already shown
in `load_string` above, string values come with two useful hints: their
original encoding and byte length. From this hint data, `store_string` can do a
much better job minimizing the number of reallocations.

We start with a case analysis to enumerate all the meaningful encoding
combinations, subdividing the `latin1+utf16` encoding into either `latin1` or
`utf16` based on the `UTF16_BIT` flag set by `load_string`:
```python
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
```

The simplest 4 cases above can compute the exact destination size and then copy
with a simply loop (that possibly inflates Latin-1 to UTF-16 by injecting a 0
byte after every Latin-1 byte).
```python
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
```
The choice of `MAX_STRING_BYTE_LENGTH` constant ensures that the high bit of a
string's byte length is never set, keeping it clear for `UTF16_BIT`.

The 2 cases of transcoding into UTF-8 share an algorithm that starts by
optimistically assuming that each code unit of the source string fits in a
single UTF-8 byte and then, failing that, reallocates to a worst-case size,
finishes the copy, and then finishes with a shrinking reallocation.
```python
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
```

Converting from UTF-8 to UTF-16 performs an initial worst-case size allocation
(assuming each UTF-8 byte encodes a whole code point that inflates into a
two-byte UTF-16 code unit) and then does a shrinking reallocation at the end
if multiple UTF-8 bytes were collapsed into a single 2-byte UTF-16 code unit:
```python
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
```

The next transcoding case handles `latin1+utf16` encoding, where there general
goal is to fit the incoming string into Latin-1 if possible based on the code
points of the incoming string. The algorithm speculates that all code points
*do* fit into Latin-1 and then falls back to a worst-case allocation size when
a code point is found outside Latin-1. In this fallback case, the
previously-copied Latin-1 bytes are inflated *in place*, inserting a 0 byte
after every Latin-1 byte (iterating in reverse to avoid clobbering later
bytes):
```python
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
```

The final transcoding case takes advantage of the extra heuristic
information that the incoming UTF-16 bytes were intentionally chosen over
Latin-1 by the producer, indicating that they *probably* contain code points
outside Latin-1 and thus *probably* require inflation. Based on this
information, the transcoding algorithm pessimistically allocates storage for
UTF-16, deflating at the end if indeed no non-Latin-1 code points were
encountered. This Latin-1 deflation ensures that if a group of components
are all using `latin1+utf16` and *one* component over-uses UTF-16, other
components can recover the Latin-1 compression. (The Latin-1 check can be
inexpensively fused with the UTF-16 validate+copy loop.)
```python
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
```

Error context values are lowered by storing them directly into the
per-component-instance `error_contexts` table and passing the `i32` index to
wasm.
```python
def lower_error_context(cx, v):
  return cx.inst.error_contexts.add(v)
```

Lists and records are stored by recursively storing their elements and
are symmetric to the loading functions. Unlike strings, lists can
simply allocate based on the up-front knowledge of length and static
element size.
```python
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
```

Variant values are represented as Python dictionaries containing exactly one
entry whose key is the label of the lifted case and whose value is the
(optional) case payload. While this code appears to do an O(n) search of the
`variant` type for a matching case label, a normal implementation can
statically fuse `store_variant` with its matching `load_variant` to ultimately
build a dense array that maps producer's case indices to the consumer's case
indices.
```python
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
```

Flags are converted from a dictionary to a bit-vector by iterating
through the case-labels of the variant in the order they were listed in the
type definition and OR-ing all the bits together. Flag lifting/lowering can be
statically fused into array/integer operations (with a simple byte copy when
the case lists are the same) to avoid any string operations in a similar manner
to variants.
```python
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
```

Finally, `own` and `borrow` handles are lowered by initializing new handle
elements in the current component instance's `resources` table. The increment
of `num_borrows` is complemented by a decrement in `canon_resource_drop` and
ensures that all borrowed handles are dropped before the end of the task.
```python
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
```
The special case in `lower_borrow` is an optimization, recognizing that, when
a borrowed handle is passed to the component that implemented the resource
type, the only thing the borrowed handle is good for is calling
`resource.rep`, so lowering might as well avoid the overhead of creating an
intermediate borrow handle.

Lowering a `stream` or `future` is almost entirely symmetric. The
`trap_if(v.closed())` in `lift_future` ensures the validity of the
`assert(not v.closed())` in `lower_future`.
```python
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
```
In the ordinary (`else`) case, the `ReadableStream` value (which may be
implemented by the host or wasm) is stored in a new readable end in the
`waitables` table.

The interesting case is when a component instance receives a `ReadableStream`
for which the component instance already holds writable end. Without specially
handling this case, this would lead to copies from a single linear memory into
itself which is both inefficient and raises subtle semantic interleaving
questions that we would rather avoid. To avoid both, this case is detected and
the index of the existing writable end is returned instead of a new readable
end, setting the high bit to signal this fact to guest code. Guest code must
therefore handle this special case by collapsing the two ends of the stream to
work fully within guest code (since the Canonical ABI is now wholly unnecessary
to pass values from writer to reader). The O(N) search through the `waitables`
table is expected to be optimized away by instead storing a pointer or index
of the writable end in the stream itself (alongside the `impl` field).


### Flattening

With only the definitions above, the Canonical ABI would be forced to place all
parameters and results in linear memory. While this is necessary in the general
case, in many cases performance can be improved by passing small-enough values
in registers by using core function parameters and results. To support this
optimization, the Canonical ABI defines `flatten_functype` to map component
function types to core function types by attempting to decompose all the
non-dynamically-sized component value types into core value types.

For a variety of [practical][Implementation Limits] reasons, we need to limit
the total number of flattened parameters and results, falling back to storing
everything in linear memory. The number of flattened results is currently
limited to 1 due to various parts of the toolchain (notably the C ABI) not yet
being able to express [multi-value] returns. Hopefully this limitation is
temporary and can be lifted before the Component Model is fully standardized.

When there are too many flat values, in general, a single `i32` pointer can be
passed instead (pointing to a tuple in linear memory). When lowering *into*
linear memory, this requires the Canonical ABI to call `realloc` (in `lower`
below) to allocate space to put the tuple. As an optimization, when lowering
the return value of an imported function (via `canon lower`), the caller can
have already allocated space for the return value (e.g., efficiently on the
stack), passing in an `i32` pointer as an parameter instead of returning an
`i32` as a return value.

Given all this, the top-level definition of `flatten_functype` is:
```python
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
```
As shown here, the core signatures `async` functions use a lower limit on the
maximum number of parameters (1) and results (0) passed as scalars before
falling back to passing through memory.

Presenting the definition of `flatten_type` piecewise, we start with the
top-level case analysis:
```python
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
```

List flattening of a fixed-length list uses the same flattening as a tuple
(via `flatten_record` below).
```python
def flatten_list(elem_type, maybe_length):
  if maybe_length is not None:
    return flatten_type(elem_type) * maybe_length
  return ['i32', 'i32']
```

Record flattening simply flattens each field in sequence.
```python
def flatten_record(fields):
  flat = []
  for f in fields:
    flat += flatten_type(f.t)
  return flat
```

Variant flattening is more involved due to the fact that each case payload can
have a totally different flattening. Rather than giving up when there is a type
mismatch, the Canonical ABI relies on the fact that the 4 core value types can
be easily bit-cast between each other and defines a `join` operator to pick the
tightest approximation. What this means is that, regardless of the dynamic
case, all flattened variants are passed with the same static set of core types,
which may involve, e.g., reinterpreting an `f32` as an `i32` or zero-extending
an `i32` into an `i64`.
```python
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
```

### Flat Lifting

Values are lifted by iterating over a list of parameter or result Core
WebAssembly values:
```python
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
```
The `match` is only used for spec-level assertions; no runtime typecase is
required.

The `lift_flat` function defines how to convert a list of core values into a
single high-level value of type `t`. Presenting the definition of `lift_flat`
piecewise, we start with the top-level case analysis:
```python
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
```

Integers are lifted from core `i32` or `i64` values using the signedness of the
target type to interpret the high-order bit. When the target type is narrower
than an `i32`, the Canonical ABI ignores the unused high bits (like `load_int`).
The conversion logic here assumes that `i32` values are always represented as
unsigned Python `int`s and thus lifting to a signed type performs a manual 2s
complement conversion in the Python (which would be a no-op in hardware).
```python
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
```

The contents of strings and variable-length lists are stored in memory so
lifting these types is essentially the same as loading them from memory; the
only difference is that the pointer and length come from `i32` values instead
of from linear memory. Fixed-length lists are lifted the same way as a
tuple (via `lift_flat_record` below).
```python
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
```

Records are lifted by recursively lifting their fields:
```python
def lift_flat_record(cx, vi, fields):
  record = {}
  for f in fields:
    record[f.label] = lift_flat(cx, vi, f.t)
  return record
```

Variants are also lifted recursively. Lifting a variant must carefully follow
the definition of `flatten_variant` above, consuming the exact same core types
regardless of the dynamic case payload being lifted. Because of the `join`
performed by `flatten_variant`, we need a more-permissive value iterator that
reinterprets between the different types appropriately and also traps if the
high bits of an `i64` are set for a 32-bit type:
```python
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
```

Finally, flags are lifted by lifting to a record the same way as when loading
flags from linear memory.
```python
def lift_flat_flags(vi, labels):
  assert(0 < len(labels) <= 32)
  i = vi.next('i32')
  return unpack_flags_from_int(i, labels)
```

### Flat Lowering

The `lower_flat` function defines how to convert a value `v` of a given type
`t` into zero or more core values. Presenting the definition of `lower_flat`
piecewise, we start with the top-level case analysis:
```python
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
```

Since component-level values are assumed in-range and, as previously stated,
core `i32` values are always internally represented as unsigned `int`s,
unsigned integer values need no extra conversion. Signed integer values are
converted to unsigned core `i32`s by 2s complement arithmetic (which again
would be a no-op in hardware):
```python
def lower_flat_signed(i, core_bits):
  if i < 0:
    i += (1 << core_bits)
  return [i]
```

Since strings and variable-length lists are stored in linear memory, lifting
can reuse the previous definitions; only the resulting pointers are returned
differently (as `i32` values instead of as a pair in linear memory).
Fixed-length lists are lowered the same way as tuples (via `lower_flat_record`
below).
```python
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
```

Records are lowered by recursively lowering their fields:
```python
def lower_flat_record(cx, v, fields):
  flat = []
  for f in fields:
    flat += lower_flat(cx, v[f.label], f.t)
  return flat
```

Variants are also lowered recursively. Symmetric to `lift_flat_variant` above,
`lower_flat_variant` must consume all flattened types of `flatten_variant`,
manually coercing the otherwise-incompatible type pairings allowed by `join`:
```python
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
```

Finally, flags are lowered by packing the flags into an `i32` bitvector.
```python
def lower_flat_flags(v, labels):
  assert(0 < len(labels) <= 32)
  return [pack_flags_into_int(v, labels)]
```

### Lifting and Lowering Values

The `lift_flat_values` function defines how to lift a list of core
parameters or results (given by the `CoreValueIter` `vi`) into a tuple
of component-level values with types `ts`.
```python
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
```

Symmetrically, the `lower_flat_values` function defines how to lower a
list of component-level values `vs` of types `ts` into a list of core
values. As already described for [`flatten_functype`](#flattening) above,
lowering handles the greater-than-`max_flat` case by either allocating
storage with `realloc` or accepting a caller-allocated buffer as an
out-param:
```python
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
```
The `may_leave` flag is guarded by `canon_lower` below to prevent a component
from calling out of the component while in the middle of lowering, ensuring
that the relative ordering of the side effects of lifting followed by lowering
cannot be observed and thus an implementation may reliably fuse lifting with
lowering when making a cross-component call to avoid the intermediate copy.


## Canonical Definitions

Using the above supporting definitions, we can describe the static and dynamic
semantics of component-level [`canon`] definitions. The following subsections
cover each of these `canon` cases.

### `canon lift`

For a canonical definition:
```wat
(canon lift $callee:<funcidx> $opts:<canonopt>* (func $f (type $ft)))
```
validation specifies:
* `$callee` must have type `flatten_functype($opts, $ft, 'lift')`
* `$f` is given type `$ft`
* a `memory` is present if required by lifting and is a subtype of `(memory 1)`
* a `realloc` is present if required by lifting and has type `(func (param i32 i32 i32 i32) (result i32))`
* if `async` is set, a `post-return` function may not be set
* if a `post-return` is present, it has type `(func (param flatten_functype({}, $ft, 'lift').results))`

When instantiating component instance `$inst`:
* Define `$f` to be the partially-bound closure `canon_lift($opts, $inst, $ft, $callee)`

The resulting function `$f` takes 4 runtime arguments:
* `caller`: the caller's `Task` or, if this lifted function is being called by
  the host, `None`
* `on_start`: a nullary function that must be called to return the caller's
  arguments as a list of component-level values
* `on_return`: a unary function that must be called after `on_start`,
  passing the list of component-level return values
* `on_block`: a unary async function taking an `asyncio.Future` to `await`,
  and returning the future's result. This function will be called (by the
  Canonical ABI) instead of raw `await` for any blocking operation.

The indirection of `on_start` and `on_return` are used to model the
interleaving of reading arguments out of the caller's stack and memory and
writing results back into the caller's stack and memory, which will vary in
async calls.

If `$f` ends up being called by the host, the host is responsible for, in a
host-defined manner, conjuring up component-level values suitable for passing
into `lower` and, conversely, consuming the component values produced by
`lift`. For example, if the host is a native JS runtime, the [JavaScript
embedding] would specify how native JavaScript values are converted to and from
component values. Alternatively, if the host is a Unix CLI that invokes
component exports directly from the command line, the CLI could choose to
automatically parse `argv` into component-level values according to the
declared types of the export. In any case, `canon lift` specifies how these
variously-produced values are consumed as parameters (and produced as results)
by a *single host-agnostic component*.

Based on this, `canon_lift` is defined in chunks as follows:
```python
async def canon_lift(opts, inst, ft, callee, caller, on_start, on_return, on_block):
  task = Task(opts, inst, ft, caller, on_return, on_block)
  flat_args = await task.enter(on_start)
  flat_ft = flatten_functype(opts, ft, 'lift')
  assert(types_match_values(flat_ft.params, flat_args))
```
Each call to `canon lift` creates a new `Task` and waits to enter the task,
allowing the task to express backpressure (for several independent reasons
listed in `Task.may_enter` above) before lowering the arguments into the
callee's memory.

In the synchronous case, if `always-task-return` ABI option is set, the lifted
core wasm code must call `canon task.return` to return a value before returning
to `canon lift` (or else there will be a trap in `task.exit()`), which allows
the core wasm to do cleanup and finalization before returning. Otherwise,
if `always-task-return` is *not* set, `canon lift` calls `task.return` when
core wasm returns (which lifts the values return by core wasm) and then calls
the `post-return` function to let core wasm do cleanup and finalization. In
the future, `post-return` and the option to not set `always-task-return` may
be deprecated and removed.
```python
  if opts.sync:
    flat_results = await call_and_trap_on_throw(callee, task, flat_args)
    if not opts.always_task_return:
      assert(types_match_values(flat_ft.results, flat_results))
      task.return_(flat_results)
      if opts.post_return is not None:
        [] = await call_and_trap_on_throw(opts.post_return, task, flat_results)
    task.exit()
    return
```
Next, the asynchronous non-`callback` case is simple and requires `task.return`
to be called, effectively implying `always-task-return`. Asynchronous waiting
happens by core wasm calling `waitable-set.wait`.
```python
  else:
    if not opts.callback:
      [] = await call_and_trap_on_throw(callee, task, flat_args)
      assert(types_match_values(flat_ft.results, []))
      task.exit()
      return
```
In contrast, the asynchronous `callback` case does asynchronous waiting in
the event loop, with core wasm (repeatedly) returning instructions for what
to do next:
```python
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
            await task.yield_(opts.sync)
            e = None
          case CallbackCode.WAIT:
            trap_if(not s)
            e = await task.wait_on(s.wait(), sync = False)
          case CallbackCode.POLL:
            trap_if(not s)
            await task.yield_(opts.sync)
            e = s.poll()
        if e:
          event, p1, p2 = e
        else:
          event, p1, p2 = (EventCode.NONE, 0, 0)
        [packed] = await call_and_trap_on_throw(opts.callback, task, [event, p1, p2])
```
One detail worth noting here is that the index of the waitable set does not
need to be returned every time; as an optimization to avoid a `waitable_sets`
table access on every turn of the event loop, if the returned waitable set
index is `0` (which is an invalid table index anyways), the previous waitable
set will be used.

The bit-packing scheme used for the `i32` `packed` return value is defined as
follows:
```python
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
```
The ability to asynchronously wait, poll, yield and exit is thus available to
both the `callback` and non-`callback` cases, making `callback` just an
optimization to avoid allocating stacks for async languages that have avoided
the need for [stack-switching] by design (e.g., `async`/`await` in JS, Python,
C# and Rust).

Uncaught Core WebAssembly [exceptions] result in a trap at component
boundaries. Thus, if a component wishes to signal an error, it must use some
sort of explicit type such as `result` (whose `error` case particular language
bindings may choose to map to and from exceptions):
```python
async def call_and_trap_on_throw(callee, task, args):
  try:
    return await callee(task, args)
  except CoreWebAssemblyException:
    trap()
```


### `canon lower`

For a canonical definition:
```wat
(canon lower $callee:<funcidx> $opts:<canonopt>* (core func $f))
```
where `$callee` has type `$ft`, validation specifies:
* `$f` is given type `flatten_functype($opts, $ft, 'lower')`
* a `memory` is present if required by lifting and is a subtype of `(memory 1)`
* a `realloc` is present if required by lifting and has type `(func (param i32 i32 i32 i32) (result i32))`
* there is no `post-return` in `$opts`
* if `contains_async_value($ft)`, then `$opts.async` must be set

When instantiating component instance `$inst`:
* Define `$f` to be the partially-bound closure: `canon_lower($opts, $ft, $callee)`

The resulting function `$f` takes 2 runtime arguments:
* `task`: the `Task` that was created by `canon_lift` when entering the current
  component instance
* `flat_args`: the list of core values passed by the core function calller

Given this, `canon_lower` is defined in chunks as follows:
```python
async def canon_lower(opts, ft, callee, task, flat_args):
  trap_if(not task.inst.may_leave)
  subtask = Subtask()
  cx = LiftLowerContext(opts, task.inst, subtask)
```
Each call to `canon lower` creates a new `Subtask`. However, this `Subtask` is
only added to the `waitables` table if `async` is specified and the callee
blocks. In any case, this `Subtask` is used as the `borrow_scope` for `borrow`
lifted during the call, ensuring that owned handles are not dropped before
`Subtask.finish()` is called.

The `on_start` and `on_return` callbacks are called by the `callee`
(which is `canon_lift`, when wasm calls wasm) to produce and consume
lifted arguments and results, resp. These callbacks are also used
by `canon_lift` to update the `CallState` of the `Subtask` and notify
the async caller of progress via the `on_progress` local callback,
which is assigned to do something useful in the `async`-blocked case
below.
```python
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
```
The `max_flat_{params,results}` variables used above are defined in
the synchronous and asynchronous branches next:
```python
  if opts.sync:
    assert(not contains_async_value(ft))
    max_flat_params = MAX_FLAT_PARAMS
    max_flat_results = MAX_FLAT_RESULTS
    await task.call_sync(callee, task, on_start, on_return)
    assert(subtask.state == CallState.RETURNED)
    subtask.finish()
    assert(types_match_values(flat_ft.results, flat_results))
```
In the synchronous case, `Task.call_sync` ensures a fully-synchronous
call to `callee` (that prevents any interleaved execution until
`callee` returns). The `not contains_async_value(ft)` assertion is
ensured by validation and reflects the fact that a function that takes
or returns a `future` or `stream` is extremely likely to deadlock if
called in this manner (since the whole point of these types is to
allow control flow to switch back and forth between caller and
callee).

The asynchronous case uses the `Task.call_async` method (defined above) to
immediately return control flow back to the `async` caller if `callee` blocks:
```python
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
```
If the `callee` reached the `RETURNED` state, the call returns `0`, signalling
to the caller that the parameters have been read and the results have been
written to the outparam buffer. Note that the callee may have blocked *after*
calling `task.return` and thus the callee may still be executing concurrently.
However, all the caller needs to know is that it has received its return value
(and all borrowed handles have been returned) and thus the subtask is ready to
be dropped (via `subtask.drop`).

If `callee` did not reach the `RETURNED` state, it must have blocked and so
the `Subtask` is added to the current component instance's `waitables` table,
eagerly returning the `i32` index packed with the `CallState` of the `Subtask`.
If the returned `CallState` is `STARTING`, the caller must keep the memory
pointed to by the first `i32` parameter valid until `task.wait` indicates that
subtask `i` has advanced to `STARTED` or `RETURNED`. Similarly, if the returned
state is `STARTED`, the caller must keep the memory pointed to by the final
`i32` parameter valid until `task.wait` indicates that the subtask has advanced
to `RETURNED`.

The `on_progress` callback is called by `on_start` and `on_return` above and
sets a pending event on the `Subtask` any time there is progress. If the
subtask advances `CallState` multiple times before the pending event is
delivered, the pending event is overwritten in-place, delivering only the
most-recent `CallState` to wasm. Once `CallState.RETURNED` is delivered, the
subtask is `finish()`ed, which returns ownership of borrowed handles to the
caller and allows the subtask to be dropped from the `waitables` table.

The above definitions of sync/async `canon_lift`/`canon_lower` ensure that a
sync-or-async `canon_lift` may call a sync-or-async `canon_lower`, with all
combinations working. This is why the `Task` class, which is used for both sync
and async `canon_lift` calls, contains the code for handling async-lowered
subtasks. As mentioned above, conservative syntactic analysis of all `canon`
definitions in a component can statically rule out combinations so that, e.g.,
a DAG of all-sync components use a plain synchronous callstack and a DAG of all
`async callback` components use only an event loop without fibers. It's only
when `async` (without a `callback`) or various compositions of async and sync
components are used that fibers (or [Asyncify]) are required to implement the
above async rules.

Since any cross-component call necessarily transits through a statically-known
`canon_lower`+`canon_lift` call pair, an AOT compiler can fuse `canon_lift` and
`canon_lower` into a single, efficient trampoline. In the future this may allow
efficient compilation of permissive subtyping between components (including the
elimination of string operations on the labels of records and variants) as well
as post-MVP [adapter functions].


### `canon resource.new`

For a canonical definition:
```wat
(canon resource.new $rt (core func $f))
```
validation specifies:
* `$rt` must refer to locally-defined (not imported) resource type
* `$f` is given type `(func (param $rt.rep) (result i32))`, where `$rt.rep` is
  currently fixed to be `i32`.

Calling `$f` invokes the following function, which adds an owning handle
containing the given resource representation in the current component
instance's `resources` table:
```python
async def canon_resource_new(rt, task, rep):
  trap_if(not task.inst.may_leave)
  h = ResourceHandle(rt, rep, own = True)
  i = task.inst.resources.add(h)
  return [i]
```


### `canon resource.drop`

For a canonical definition:
```wat
(canon resource.drop $rt $async? (core func $f))
```
validation specifies:
* `$rt` must refer to resource type
* `$f` is given type `(func (param i32))`

Calling `$f` invokes the following function, which removes the handle from the
current component instance's `resources` table and, if the handle was owning,
calls the resource's destructor.
```python
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
```
In general, the call to a resource's destructor is treated like a
cross-component call (as-if the destructor was exported by the component
defining the resource type). This means that cross-component destructor calls
follow the same concurrency rules as normal exports. However, since there are
valid reasons to call `resource.drop` in the same component instance that
defined the resource, which would otherwise trap at the reentrance guard of
`Task.enter`, an exception is made when the resource type's
implementation-instance is the same as the current instance (which is
statically known for any given `canon resource.drop`).

When a destructor isn't present, the rules still perform a reentrance check
since this is the caller's responsibility and the presence or absence of a
destructor is an encapsualted implementation detail of the resource type.


### `canon resource.rep`

For a canonical definition:
```wat
(canon resource.rep $rt (core func $f))
```
validation specifies:
* `$rt` must refer to a locally-defined (not imported) resource type
* `$f` is given type `(func (param i32) (result $rt.rep))`, where `$rt.rep` is
  currently fixed to be `i32`.

Calling `$f` invokes the following function, which extracts the resource
representation from the handle.
```python
async def canon_resource_rep(rt, task, i):
  h = task.inst.resources.get(i)
  trap_if(h.rt is not rt)
  return [h.rep]
```
Note that the "locally-defined" requirement above ensures that only the
component instance defining a resource can access its representation.


### 🔀 `canon context.get`

For a canonical definition:
```wat
(canon context.get $t $i (core func $f))
```
validation specifies:
* `$t` must be `i32` (for now; see [here][context-local storage])
* `$i` must be less than `2`
* `$f` is given type `(func (result i32))`

Calling `$f` invokes the following function, which reads the [context-local
storage] of the [current task]:
```python
async def canon_context_get(t, i, task):
  assert(t == 'i32')
  assert(i < ContextLocalStorage.LENGTH)
  return [task.context.get(i)]
```


### 🔀 `canon context.set`

For a canonical definition:
```wat
(canon context.set $t $i (core func $f))
```
validation specifies:
* `$t` must be `i32` (for now; see [here][context-local storage])
* `$i` must be less than `2`
* `$f` is given type `(func (param $v i32))`

Calling `$f` invokes the following function, which writes to the [context-local
storage] of the [current task]:
```python
async def canon_context_set(t, i, task, v):
  assert(t == 'i32')
  assert(i < ContextLocalStorage.LENGTH)
  task.context.set(i, v)
  return []
```


### 🔀 `canon backpressure.set`

For a canonical definition:
```wat
(canon backpressure.set (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $enabled i32))`

Calling `$f` invokes the following function, which sets the `backpressure`
flag on the current `ComponentInstance`:
```python
async def canon_backpressure_set(task, flat_args):
  trap_if(task.opts.sync)
  task.inst.backpressure = bool(flat_args[0])
  return []
```
The `backpressure` flag is read by `Task.enter` (defined above) to prevent new
tasks from entering the component instance and forcing the guest code to
consume resources.


### 🔀 `canon task.return`

For a canonical definition:
```wat
(canon task.return (result $t)? $opts (core func $f))
```
validation specifies:
* `$f` is given type `flatten_functype($opts, (func (param $t)?), 'lower')`
* `$opts` may only contain `memory`, `string-encoding` and `realloc`

Calling `$f` invokes the following function which uses `Task.return_` to lift
and pass the results to the caller:
```python
async def canon_task_return(task, result_type, opts: LiftLowerOptions, flat_args):
  trap_if(not task.inst.may_leave)
  trap_if(task.opts.sync and not task.opts.always_task_return)
  trap_if(result_type != task.ft.results)
  trap_if(opts != LiftLowerOptions.copy(task.opts))
  task.return_(flat_args)
  return []
```
The `trap_if(result_type != task.ft.results)` guard ensures that, in a
component with multiple exported functions of different types, `task.return` is
not called with a mismatched result type (which, due to indirect control flow,
can in general only be caught dynamically).

The `trap_if(opts != LiftLowerOptions.copy(task.opts))` guard ensures that
the return value is lifted the same way as the `canon lift` from which this
`task.return` is returning. This ensures that AOT fusion of `canon lift` and
`canon lower` can generate a thunk that is indirectly called by `task.return`
after these guards. The `LiftLowerOptions.copy` method is used to select just
the `LiftLowerOptions` subset of `CanonicalOptions` (since fields like
`async` and `callback` aren't relevant to `task.return`).


### 🔀 `canon yield`

For a canonical definition:
```wat
(canon yield $async? (core func $f))
```
validation specifies:
* `$f` is given type `(func)`

Calling `$f` calls `Task.yield_` to allow other tasks to execute:
```python
async def canon_yield(sync, task):
  trap_if(not task.inst.may_leave)
  trap_if(task.opts.callback and not sync)
  await task.yield_(sync)
  return []
```
If `async` is not set, no other tasks *in the same component instance* can
execute, however tasks in *other* component instances may execute. This allows
a long-running task in one component to avoid starving other components without
needing support full reentrancy.

The guard preventing `async` use of `task.poll` when a `callback` has
been used preserves the invariant that producer toolchains using
`callback` never need to handle multiple overlapping callback
activations.


### 🔀 `canon waitable-set.new`

For a canonical definition:
```wat
(canon waitable-set.new (core func $f))
```
validation specifies:
* `$f` is given type `(func (result i32))`

Calling `$f` invokes the following function, which adds an empty waitable set
to the component instance's `waitable_sets` table:
```python
async def canon_waitable_set_new(task):
  trap_if(not task.inst.may_leave)
  return [ task.inst.waitable_sets.add(WaitableSet()) ]
```


### 🔀 `canon waitable-set.wait`

For a canonical definition:
```wat
(canon waitable-set.wait $async? (memory $mem) (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $si) (param $ptr i32) (result i32))`

Calling `$f` invokes the following function which waits for progress to be made
on a waitable in the given waitable set (indicated by index `$si`) and then
returning its `EventCode` and writing the payload values into linear memory:
```python
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
```
If `async` is not set, `wait_on` will prevent other tasks from executing in
the same component instance, which can be useful for producer toolchains in
situations where interleaving is not supported. However, this is generally
worse for concurrency and thus producer toolchains should set `async` when
possible.

`wait` can be called from a synchronously-lifted export so that even
synchronous code can make concurrent import calls. In these synchronous cases,
though, the automatic backpressure (applied by `Task.enter`) will ensure there
is only ever at most once synchronously-lifted task executing in a component
instance at a time.

The guard preventing `async` use of `wait` when a `callback` has been used
preserves the invariant that producer toolchains using `callback` never need to
handle multiple overlapping callback activations.


### 🔀 `canon waitable-set.poll`

For a canonical definition:
```wat
(canon waitable-set.poll $async? (memory $mem) (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $si i32) (param $ptr i32) (result i32))`

Calling `$f` invokes the following function, which returns `NONE` (`0`) instead
of blocking if there is no event available, and otherwise returns the event the
same way as `wait`.
```python
async def canon_waitable_set_poll(sync, mem, task, si, ptr):
  trap_if(not task.inst.may_leave)
  trap_if(task.opts.callback and not sync)
  s = task.inst.waitable_sets.get(si)
  await task.yield_(sync)
  if (e := s.poll()):
    return unpack_event(mem, task, ptr, e)
  return [EventCode.NONE]
```
When `async` is set, `task.poll` can yield to other tasks (in this or other
components) as part of polling for an event.

The guard preventing `async` use of `task.poll` when a `callback` has
been used preserves the invariant that producer toolchains using
`callback` never need to handle multiple overlapping callback
activations.


### 🔀 `canon waitable-set.drop`

For a canonical definition:
```wat
(canon waitable-set.drop (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32))`

Calling `$f` invokes the following function, which removes the given
waitable set from the component instance table, performing the guards defined
by `WaitableSet.drop` above:
```python
async def canon_waitable_set_drop(task, i):
  trap_if(not task.inst.may_leave)
  s = task.inst.waitable_sets.remove(i)
  s.drop()
  return []
```


### 🔀 `canon waitable.join`

For a canonical definition:
```wat
(canon waitable.join (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $wi i32) (param $si i32))`

Calling `$f` invokes the following function:
```python
async def canon_waitable_join(task, wi, si):
  trap_if(not task.inst.may_leave)
  w = task.inst.waitables.get(wi)
  if si == 0:
    w.join(None)
  else:
    w.join(task.inst.waitable_sets.get(si))
  return []
```
Note that tables do not allow elements at index `0`, so `0` is a valid sentinel
that tells `join` to remove the given waitable from any set that it is
currently a part of. Waitables can be a member of at most one set, so if the
given waitable is already in one set, it will be transferred.


### 🔀 `canon subtask.drop`

For a canonical definition:
```wat
(canon subtask.drop (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32))`

Calling `$f` removes the subtask at the given index from the current
component instance's `watiable` table, performing the guards and bookkeeping
defined by `Subtask.drop()`.
```python
async def canon_subtask_drop(task, i):
  trap_if(not task.inst.may_leave)
  s = task.inst.waitables.remove(i)
  trap_if(not isinstance(s, Subtask))
  s.drop()
  return []
```


### 🔀 `canon {stream,future}.new`

For canonical definitions:
```wat
(canon stream.new $t (core func $f))
(canon future.new $t (core func $f))
```
validation specifies:
* `$f` is given type `(func (result i32))`

Calling `$f` calls `canon_{stream,future}_new` which creates a new abstract
{stream, future} and adds a new writable end for it to the `waitables` table
and returns its index.
```python
async def canon_stream_new(elem_type, task):
  trap_if(not task.inst.may_leave)
  stream = ReadableStreamGuestImpl(elem_type, task.inst)
  return [ task.inst.waitables.add(WritableStreamEnd(stream)) ]

async def canon_future_new(t, task):
  trap_if(not task.inst.may_leave)
  future = ReadableStreamGuestImpl(t, task.inst)
  return [ task.inst.waitables.add(WritableFutureEnd(future)) ]
```
Because futures are just streams with extra limitations, here we see that a
`WritableFutureEnd` shares the same `ReadableStreamGuestImpl` type as
`WritableStreamEnd`; the extra limitations are added by `WritableFutureEnd` and
the future built-ins below.


### 🔀 `canon {stream,future}.{read,write}`

For canonical definitions:
```wat
(canon stream.read $t $opts (core func $f))
(canon stream.write $t $opts (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32 i32 i32) (result i32))`

For canonical definitions:
```wat
(canon future.read $t $opts (core func $f))
(canon future.write $t $opts (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32 i32) (result i32))`

The implementation of these four built-ins all funnel down to a single
parameterized `copy` function:
```python
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
```

Introducing the `copy` function in chunks, `copy` first checks that the
`Waitable` at index `i` is the right type and that there is not already a copy
in progress. (In the future, this restriction could be relaxed, allowing a
finite number of pipelined reads or writes.) Then a readable or writable buffer
is created which (in `Buffer`'s constructor) eagerly checks the alignment and
bounds of (`i`, `n`).
```python
async def copy(EndT, BufferT, event_code, t, opts, task, i, ptr, n):
  trap_if(not task.inst.may_leave)
  e = task.inst.waitables.get(i)
  trap_if(not isinstance(e, EndT))
  trap_if(e.stream.t != t)
  trap_if(e.copying)
  assert(not contains_borrow(t))
  cx = LiftLowerContext(opts, task.inst, borrow_scope = None)
  buffer = BufferT(t, cx, ptr, n)
```

Next, in the synchronous case, `Task.wait_on` is used to synchronously and
uninterruptibly wait for the `on_*` callbacks to indicate that the copy has made
progress. In the case of `on_partial_copy`, this code carefully delays the call
to `revoke_buffer` until right before control flow is returned back to the
calling core wasm code. This enables another task to potentially complete
multiple partial copies before having to context-switch back.
```python
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
```

In the asynchronous case, the `on_*` callbacks set a pending event on the
`Waitable` which will be delivered to core wasm when core wasm calls
`task.{wait,poll}` or, if using `callback`, returns to the event loop.
Symmetric to the synchronous case, this code carefully delays calling
`revoke_buffer` until the copy event is actually delivered to core wasm,
allowing multiple partial copies to complete in the interim, reducing overall
context-switching overhead.
```python
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
```
However the copy completes, the results are reported to the caller via
`pack_copy_result`:
```python
BLOCKED = 0xffff_ffff
CLOSED  = 0x8000_0000

def pack_copy_result(task, buffer, e):
  if buffer.progress or not e.stream.closed():
    assert(buffer.progress <= Buffer.MAX_LENGTH < BLOCKED)
    assert(not (buffer.progress & CLOSED))
    return buffer.progress
  else:
    if (maybe_errctx := e.stream.closed_with()):
      errctxi = task.inst.error_contexts.add(maybe_errctx)
      assert(errctxi != 0)
    else:
      errctxi = 0
    assert(errctxi <= Table.MAX_LENGTH < BLOCKED)
    assert(not (errctxi & CLOSED))
    return errctxi | CLOSED
```
The order of tests here indicates that, if some progress was made and then the
stream was closed, only the progress is reported and the `CLOSED` status is
left to be discovered next time.


### 🔀 `canon {stream,future}.cancel-{read,write}`

For canonical definitions:
```wat
(canon stream.cancel-read $t $async? (core func $f))
(canon stream.cancel-write $t $async? (core func $f))
(canon future.cancel-read $t $async? (core func $f))
(canon future.cancel-write $t $async? (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32) (result i32))`

The implementation of these four built-ins all funnel down to a single
parameterized `cancel_copy` function:
```python
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
```
The *first* check for `e.has_pending_event()` catches the case where the copy has
already racily finished, in which case we must *not* call `stream.cancel()`.
Calling `stream.cancel()` may, but is not required to, recursively call one of
the `on_*` callbacks (passed by `canon_{stream,future}_{read,write}` above)
which will set a pending event that is caught by the *second* check for
`e.has_pending_event()`.

If the copy hasn't been cancelled, the synchronous case uses `Task.wait_on` to
synchronously and uninterruptibly wait for one of the `on_*` callbacks to
eventually be called (which will set the pending event).

The asynchronous case simply returns `BLOCKING` and the client code must wait
as usual for a `{STREAM,FUTURE}_{READ,WRITE}` event. In this case, cancellation
has served only to asynchronously request that the host relinquish the buffer
ASAP without waiting for anything to be read or written.

If `BLOCKING` is *not* returned, the pending event (which is necessarily a
`copy_event`) is eagerly delivered to core wasm as the return value, thereby
saving an additional turn of the event loop. In this case, the core wasm
caller can assume that ownership of the buffer has been returned.


### 🔀 `canon {stream,future}.close-{readable,writable}`

For canonical definitions:
```wat
(canon stream.close-readable $t (core func $f))
(canon stream.close-writable $t (core func $f))
(canon future.close-readable $t (core func $f))
(canon future.close-writable $t (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32 i32))`

Calling `$f` removes the readable or writable end of the stream or future at
the given index from the current component instance's `waitable` table,
performing the guards and bookkeeping defined by
`{Readable,Writable}{Stream,Future}End.drop()` above.
```python
async def canon_stream_close_readable(t, task, i, errctxi):
  return await close(ReadableStreamEnd, t, task, i, errctxi)

async def canon_stream_close_writable(t, task, hi, errctxi):
  return await close(WritableStreamEnd, t, task, hi, errctxi)

async def canon_future_close_readable(t, task, i, errctxi):
  return await close(ReadableFutureEnd, t, task, i, errctxi)

async def canon_future_close_writable(t, task, hi, errctxi):
  return await close(WritableFutureEnd, t, task, hi, errctxi)

async def close(EndT, t, task, hi, errctxi):
  trap_if(not task.inst.may_leave)
  e = task.inst.waitables.remove(hi)
  if errctxi == 0:
    maybe_errctx = None
  else:
    maybe_errctx = task.inst.error_contexts.get(errctxi)
  trap_if(not isinstance(e, EndT))
  trap_if(e.stream.t != t)
  e.drop(maybe_errctx)
  return []
```
Passing a non-zero `errctxi` index indicates that this stream end is being
closed due to an error, with the given `error-context` providing information
that can be printed to aid in debugging. While, as explained above, the
*contents* of the `error-context` value are non-deterministic (and may, e.g.,
be empty), the presence or absence of an `error-context` value is semantically
meaningful for distinguishing between success or failure. Concretely, the
packed `i32` returned by `{stream,future}.{read,write}` operations indicates
success or failure by whether the `error-context` index is `0` or not.


### 🔀 `canon error-context.new`

For a canonical definition:
```wat
(canon error-context.new $opts (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32 i32) (result i32))`

Calling `$f` calls the following function which uses the `$opts` immediate to
(non-deterministically) lift the debug message, create a new `ErrorContext`
value, store it in the per-component-instance `error_contexts` table and
returns its index.
```python
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
```
Supporting the requirement (introduced in the
[explainer](Explainer.md#error-context-type)) that wasm code does not depend on
the contents of `error-context` values for behavioral correctness, the debug
message is completely discarded non-deterministically or, in the deterministic
profile, always. Importantly (for performance), when the debug message is
discarded, it is not even lifted and thus the O(N) well-formedness conditions
are not checked. (Note that `host_defined_transformation` is not defined by the
Canonical ABI and stands for an arbitrary host-defined function.)


### 🔀 `canon error-context.debug-message`

For a canonical definition:
```wat
(canon error-context.debug-message $opts (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32 i32))`

Calling `$f` calls the following function which uses the `$opts` immediate to
lowers the `ErrorContext`'s debug message. While *producing* an `error-context`
value may non-deterministically discard or transform the debug message, a
single `error-context` value must return the same debug message from
`error.debug-message` over time.
```python
async def canon_error_context_debug_message(opts, task, i, ptr):
  trap_if(not task.inst.may_leave)
  errctx = task.inst.error_contexts.get(i)
  cx = LiftLowerContext(opts, task.inst)
  store_string(cx, errctx.debug_message, ptr)
  return []
```
Note that `ptr` points to an 8-byte region of memory into which will be stored
the pointer and length of the debug string (allocated via `opts.realloc`).

### 🔀 `canon error-context.drop`

For a canonical definition:
```wat
(canon error-context.drop (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32))`

Calling `$f` calls the following function, which drops the `error-context`
value from the current component instance's `error_contexts` table.
```python
async def canon_error_context_drop(task, i):
  trap_if(not task.inst.may_leave)
  task.inst.error_contexts.remove(i)
  return []
```


### 🧵 `canon thread.spawn_ref`

For a canonical definition:
```wat
(canon thread.spawn_ref (type $ft) (core func $st))
```
validation specifies:
* `$ft` must refer to a `shared` function type; initially, only the type
  `(shared (func (param $c i32)))` is allowed (see explanation below)
* `$st` is given type `(func (param $f (ref null $ft)) (param $c i32) (result $e
  i32))`.

> Note: ideally, a thread could be spawned with [arbitrary thread parameters].
> Currently, that would require additional work in the toolchain to support so,
> for simplicity, the current proposal simply fixes a single `i32` parameter
> type. However, `thread.spawn_ref` could be extended to allow arbitrary thread
> parameters in the future, once it's concretely beneficial to the toolchain.
> The inclusion of `$ft` ensures backwards compatibility for when arbitrary
> parameters are allowed.

Calling `$st` checks that the reference `$f` is not null. Then, it spawns a
thread which:
  - invokes `$f` with `$c`
  - executes `$f` until completion or trap in a `shared` context as described by
    the [shared-everything threads] proposal.

In pseudocode, `$st` looks like:

```python
def canon_thread_spawn_ref(f, c):
  trap_if(f is None)
  if DETERMINISTIC_PROFILE:
    return [-1]

  def thread_start():
    try:
      f(c)
    except CoreWebAssemblyException:
      trap()

  if spawn(thread_start):
    return [0]
  else:
    return [-1]
```


### 🧵 `canon thread.spawn_indirect`

For a canonical definition:
```wat
(canon thread.spawn_indirect (type $ft) (table $t) (core func $st))
```
validation specifies:
* `$ft` must refer to a `shared` function type; initially, only the type
  `(shared (func (param $c i32)))` is allowed (see explanation in
  `thread.spawn_ref` above)
* `$tbl` must refer to a table with type `(table (ref null (shared func)) shared)`
* `$st` is given type `(func (param $i i32) (param $c i32) (result $e
  i32))`.

Calling `$spawn_indirect` retrieves a reference to function `$f` from table `$tbl` and checks
that `$f` is of type `$ft`. If that succeeds, it spawns a thread which:
  - invokes `$f` with `$c`
  - executes `$f` until completion or trap in a `shared` context as described by
    the [shared-everything threads] proposal.

In pseudocode, `$st` looks like:

```python
def canon_thread_spawn_indirect(t, i, c):
  trap_if(t[i] is None)
  f = t[i]
  if DETERMINISTIC_PROFILE:
    return [-1]

  def thread_start():
    try:
      f(c)
    except CoreWebAssemblyException:
      trap()

  if spawn(thread_start):
    return [0]
  else:
    return [-1]
```


### 🧵 `canon thread.available_parallelism`

For a canonical definition:
```wat
(canon thread.available_parallelism (core func $f))
```
validation specifies:
* `$f` is given type `(func shared (result i32))`.

Calling `$f` returns the number of threads the underlying hardware can be
expected to execute in parallel. This value can be artificially limited by
engine configuration and is not allowed to change over the lifetime of a
component instance.

```python
def canon_thread_available_parallelism():
  if DETERMINISTIC_PROFILE:
    return [1]
  else:
    return [NUM_ALLOWED_THREADS]
```


[Virtualization Goals]: Goals.md
[Canonical Definitions]: Explainer.md#canonical-definitions
[`canonopt`]: Explainer.md#canonical-definitions
[`canon`]: Explainer.md#canonical-definitions
[Type Definitions]: Explainer.md#type-definitions
[Component Invariant]: Explainer.md#component-invariants
[Component Invariants]: Explainer.md#component-invariants
[JavaScript Embedding]: Explainer.md#JavaScript-embedding
[Adapter Functions]: FutureFeatures.md#custom-abis-via-adapter-functions
[Shared-Everything Dynamic Linking]: examples/SharedEverythingDynamicLinking.md
[Structured Concurrency]: Async.md#structured-concurrency
[Current Task]: Async.md#current-task
[Readable and Writable Ends]: Async.md#streams-and-futures
[Context-Local Storage]: Async.md#context-local-storage

[Administrative Instructions]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-instr-admin
[Implementation Limits]: https://webassembly.github.io/spec/core/appendix/implementation.html
[Function Instance]: https://webassembly.github.io/spec/core/exec/runtime.html#function-instances
[Two-level]: https://webassembly.github.io/spec/core/syntax/modules.html#syntax-import

[Multi-value]: https://github.com/WebAssembly/multi-value/blob/master/proposals/multi-value/Overview.md
[Exceptions]: https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md
[WASI]: https://github.com/webassembly/wasi
[Deterministic Profile]: https://github.com/WebAssembly/profiles/blob/main/proposals/profiles/Overview.md
[stack-switching]: https://github.com/WebAssembly/stack-switching

[Alignment]: https://en.wikipedia.org/wiki/Data_structure_alignment
[UTF-8]: https://en.wikipedia.org/wiki/UTF-8
[UTF-16]: https://en.wikipedia.org/wiki/UTF-16
[Latin-1]: https://en.wikipedia.org/wiki/ISO/IEC_8859-1
[Unicode Scalar Value]: https://unicode.org/glossary/#unicode_scalar_value
[Unicode Code Point]: https://unicode.org/glossary/#code_point
[Surrogate]: https://unicode.org/faq/utf_bom.html#utf16-2
[Name Mangling]: https://en.wikipedia.org/wiki/Name_mangling
[Fibers]: https://en.wikipedia.org/wiki/Fiber_(computer_science)
[Asyncify]: https://emscripten.org/docs/porting/asyncify.html

[`import_name`]: https://clang.llvm.org/docs/AttributeReference.html#import-name
[`export_name`]: https://clang.llvm.org/docs/AttributeReference.html#export-name

[Arbitrary Thread Parameters]: https://github.com/WebAssembly/shared-everything-threads/discussions/3
[wasi-libc Convention]: https://github.com/WebAssembly/wasi-libc/blob/925ad6d7/libc-top-half/musl/src/thread/pthread_create.c#L318
[Shared-Everything Threads]: https://github.com/WebAssembly/shared-everything-threads/blob/main/proposals/shared-everything-threads/Overview.md

[`asyncio`]: https://docs.python.org/3/library/asyncio.html
[`asyncio.Event`]: https://docs.python.org/3/library/asyncio-sync.html#event
[`asyncio.Condition`]: https://docs.python.org/3/library/asyncio-sync.html#condition

[OIO]: https://en.wikipedia.org/wiki/Overlapped_I/O
[io_uring]: https://en.wikipedia.org/wiki/Io_uring
