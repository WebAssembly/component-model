# Canonical ABI Explainer

This document defines the Canonical ABI used to convert between the values and
functions of components in the Component Model and the values and functions
of modules in Core WebAssembly. See the [AST explainer](Explainer.md) for a
walkthrough of the static structure of a component and the
[async explainer](Async.md) for a high-level description of the async model
being specified here.

* [Supporting definitions](#supporting-definitions)
  * [Call Context](#call-context)
  * [Canonical ABI Options](#canonical-abi-options)
  * [Runtime State](#runtime-state)
  * [Despecialization](#despecialization)
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
  * [`canon task.backpressure`](#-canon-taskbackpressure) 🔀
  * [`canon task.return`](#-canon-taskreturn) 🔀
  * [`canon task.wait`](#-canon-taskwait) 🔀
  * [`canon task.poll`](#-canon-taskpoll) 🔀
  * [`canon task.yield`](#-canon-taskyield) 🔀


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

While the Python code appears to perform a copy as part of lifting
the contents of linear memory into high-level Python values, a normal
implementation should never need to make this extra intermediate copy.
This claim is expanded upon [below](#calling-into-a-component).

Lastly, independently of Python, the Canonical ABI defined below assumes that
out-of-memory conditions (such as `memory.grow` returning `-1` from within
`realloc`) will trap (via `unreachable`). This significantly simplifies the
Canonical ABI by avoiding the need to support the complicated protocols
necessary to support recovery in the middle of nested allocations. In the MVP,
for large allocations that can OOM, [streams](Async.md#todo) would usually
be the appropriate type to use and streams will be able to explicitly express
failure in their type. Post-MVP, [adapter functions] would allow fully custom
OOM handling for all component-level types, allowing a toolchain to
intentionally propagate OOM into the appropriate explicit return value of the
function's declared return type.


### Call Context

The subsequent definitions depend on three kinds of ambient information:
* static ABI options supplied via [`canonopt`]
* dynamic state in the containing component instance
* dynamic state in the [current task]

These sources of ambient context are stored as the respective `opts`, `inst`
and `task` fields of the `CallContext` object:
```python
class CallContext:
  opts: CanonicalOptions
  inst: ComponentInstance
  task: Task

  def __init__(self, opts, inst, task):
    self.opts = opts
    self.inst = inst
    self.task = task
```
The `cx` parameter in functions below refers to the ambient `CallContext`. The
`Task` and `Subtask` classes derive `CallContext` and thus having a `task` or
`subtask` also establishes the ambient `CallContext`.


### Canonical ABI Options

The `opts` field of `CallContext` contains all the possible [`canonopt`]
immediates that can be passed to the `canon` definition being implemented.
```python
@dataclass
class CanonicalOptions:
  memory: Optional[bytearray] = None
  string_encoding: Optional[str] = None
  realloc: Optional[Callable] = None
  post_return: Optional[Callable] = None
  sync: bool = True # = !canonopt.async
  callback: Optional[Callable] = None
```
(Note that the `async` `canonopt` is inverted to `sync` here for the practical
reason that `async` is a keyword and most branches below want to start with the
`sync = True` case.)


### Runtime State

The `inst` field of `CallContext` points to the component instance which the
`canon`-generated function is closed over. Component instances contain all the
core wasm instance as well as some extra state that is used exclusively by the
Canonical ABI and introduced below as the fields are used.
```python
class ComponentInstance:
  resources: ResourceTables
  async_subtasks: Table[Subtask]
  num_tasks: int
  may_leave: bool
  backpressure: bool
  interruptible: asyncio.Event
  pending_tasks: list[tuple[Task, asyncio.Future]]

  def __init__(self):
    self.resources = ResourceTables()
    self.async_subtasks = Table[Subtask]()
    self.num_tasks = 0
    self.may_leave = True
    self.backpressure = False
    self.interruptible = asyncio.Event()
    self.interruptible.set()
    self.pending_tasks = []
```

The `ResourceTables` stored in the `resources` field maps `ResourceType`s to
`Table`s of `ResourceHandle`s (defined next), establishing a separate
`i32`-indexed array per resource type:
```python
class ResourceTables:
  rt_to_table: MutableMapping[ResourceType, Table[ResourceHandle]]

  def __init__(self):
    self.rt_to_table = dict()

  def table(self, rt):
    if rt not in self.rt_to_table:
      self.rt_to_table[rt] = Table[ResourceHandle]()
    return self.rt_to_table[rt]

  def get(self, rt, i):
    return self.table(rt).get(i)
  def add(self, rt, h):
    return self.table(rt).add(h)
  def remove(self, rt, i):
    return self.table(rt).remove(i)
```
While this Python code performs a dynamic hash-table lookup on each handle
table access, as we'll see below, the `rt` parameter is always statically known
such that a normal implementation can statically enumerate all `Table` objects
at compile time and then route the calls to `get`, `add` and `remove` to the
correct `Table` at the callsite. The net result is that each component instance
will contain one handle table per resource type used by the component, with
each compiled adapter function accessing the correct handle table as-if it were
a global variable.

The `ResourceType` class represents a concrete resource type that has been
created by the component instance `impl`. `ResourceType` objects are used as
keys by `ResourceTables` above and thus we assume that Python object identity
corresponds to resource type equality, as defined by [type checking] rules.
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
The `Table` class, used by `ResourceTables` above, encapsulates a single
mutable, growable array of generic elements, indexed by Core WebAssembly
`i32`s.
```python
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

The `ResourceHandle` class defines the elements of the per-resource-type
`Table`s stored in `ResourceTables`:
```python
class ResourceHandle:
  rep: int
  own: bool
  scope: Optional[Task]
  lend_count: int

  def __init__(self, rep, own, scope = None):
    self.rep = rep
    self.own = own
    self.scope = scope
    self.lend_count = 0
```
The `rep` field of `ResourceHandle` stores the resource representation
(currently fixed to be an `i32`) passed to `resource.new`.

The `own` field indicates whether this element was created from an `own` type
(or, if false, a `borrow` type).

The `scope` field stores the `Task` that created the borrowed handle. When a
component only uses sync-lifted exports, due to lack of reentrance, there is
at most one `Task` alive in a component instance at any time and thus an
optimizing implementation doesn't need to store the `Task` per
`ResourceHandle`.

The `lend_count` field maintains a conservative approximation of the number of
live handles that were lent from this `own` handle (by calls to `borrow`-taking
functions). This count is maintained by the `ImportCall` bookkeeping functions
(above) and is ensured to be zero when an `own` handle is dropped.

An optimizing implementation can enumerate the canonical definitions present
in a component to statically determine that a given resource type's handle
table only contains `own` or `borrow` handles and then, based on this,
statically eliminate the `own` and the `lend_count` xor `scope` fields,
and guards thereof.

Additional runtime state is required to implement the canonical built-ins and
check that callers and callees uphold their respective parts of the call
contract. This additional call state derives from `CallContext`, adding extra
mutable fields. There are two subclasses of `CallContext`: `Task`, which is
created by `canon_lift` and `Subtask`, which is created by `canon_lower`.

The `Task` class and its subclasses depend on the following type definitions:
```python
class CallState(IntEnum):
  STARTING = 0
  STARTED = 1
  RETURNED = 2
  DONE = 3

class EventCode(IntEnum):
  CALL_STARTING = CallState.STARTING
  CALL_STARTED = CallState.STARTED
  CALL_RETURNED = CallState.RETURNED
  CALL_DONE = CallState.DONE
  YIELDED = 4

EventTuple = tuple[EventCode, int]
EventCallback = Callable[[], EventTuple]
OnBlockCallback = Callable[[Awaitable], Any]
```
The `CallState` enum describes the linear sequence of states that an async call
necessarily transitions through: [`STARTING`](Async.md#backpressure), `STARTED`,
[`RETURNING`](Async.md#returning) and `DONE`. The `EventCode` enum shares
common code values with `CallState` to define the set of integer event codes
that are delivered to [waiting](Async.md#waiting) or polling tasks.

The `current_task` global holds an `asyncio.Lock` that starts out locked and is
strategically released and reacquired to control when and where the runtime can
switch between concurrent tasks. Without this lock, Python's normal async
semantics would allow switching at *every* `await` point, which would look more
like preemptive multi-threading from the perspective of wasm code.
```python
current_task = asyncio.Lock()
asyncio.run(current_task.acquire())
```
The `current_task` lock is exclusively acquired and released by the following
two functions which, as described below, are meant to be implementable in terms
of the Core WebAssembly [stack-switching] proposal's `suspend`, `resume` and
`cont.new` instructions. As defined below, every `Task` stores a
caller-supplied `on_block` callback that works like `await` and is called by
the Canonical ABI *instead of* `await` when performing blocking I/O. When a
component is called directly from the host, the `on_block` callback defaults to
`default_on_block` which simply releases and reacquires `current_task` so that
other tasks can make progress while this task is blocked. However, when making
an `async`-lowered import call, `call_and_handle_blocking` supplies a custom
`on_block` closure that directly transfers control flow from the callee back to
the caller.
```python
async def default_on_block(f):
  current_task.release()
  v = await f
  await current_task.acquire()
  return v

class Blocked: pass
class Returned: pass

async def call_and_handle_blocking(callee, *args) -> Blocked|Returned:
  ret = asyncio.Future[Blocked|Returned]()
  async def on_block(f):
    if not ret.done():
      ret.set_result(Blocked())
    else:
      current_task.release()
    v = await f
    await current_task.acquire()
    return v
  async def do_call():
    await callee(*args, on_block)
    if not ret.done():
      ret.set_result(Returned())
    else:
      current_task.release()
  asyncio.create_task(do_call())
  return await ret
```
Talking through this little Python pretzel of control flow:
1. `call_and_handle_blocking` starts by running `do_call` in a fresh Python
   task and then immediately `await`ing `ret`, which will be resolved by
   `do_call`. Since `current_task` isn't `release()`d or `acquire()`d as part
   of this process, the net effect is to directly transfer control flow from
   `call_and_handle_blocking` to `do_call` task without allowing other tasks
   to run (as if by the `cont.new` and `resume` instructions of
   [stack-switching]).
2. `do_call` passes the local `on_block` closure to `callee`, which the
   Canonical ABI ensures will be called whenever there is a need to block on
   I/O (represented by the future `f`).
3. If `on_block` is called, the first time it is called it will signal that
   the `callee` has blocked by setting `ret` to `Blocked()` before `await`.
   Because the `current_task` lock is not `release()`d , control flow is
   transferred directly from `on_block` to `call_and_handle_blocking` without
   allowing any other tasks to execute (as if by the `suspend` instruction of
   [stack-switching]).
4. If `on_block` is called more than once, there is no longer a caller to
   directly switch to, so the `current_task` lock is `release()`d so that the
   Python async scheduler can pick another task to switch to.
5. If `callee` returns and `ret` hasn't been set, then `on_block` hasn't been
   called and thus `callee` was never suspsended, so `ret` is set to
   `Returned`.

With these tricky primitives defined, the rest of the logic below can simply
use `on_block` when there is a need to block and `call_and_handle_blocking`
when there is a need to make an `async` call.

A `Task` object is created for each call to `canon_lift` and is implicitly
threaded through all core function calls. This implicit `Task` parameter
represents the "[current task]". A `Task` is-a `CallContext`, with its `ft`
and `opts` derived from the `canon lift` definition that created this `Task`.
```python
class Task(CallContext):
  ft: FuncType
  caller: Optional[Task]
  on_return: Optional[Callable]
  on_block: OnBlockCallback
  need_to_drop: int
  events: list[EventCallback]
  has_events: asyncio.Event

  def __init__(self, opts, inst, ft, caller, on_return, on_block):
    super().__init__(opts, inst, self)
    self.ft = ft
    self.caller = caller
    self.on_return = on_return
    self.on_block = on_block
    self.need_to_drop = 0
    self.events = []
    self.has_events = asyncio.Event()
```
The fields of `Task` are introduced in groups of related `Task` methods next.
Using a conservative syntactic analysis of the component-level definitions of
a linked component DAG, an optimizing implementation can statically eliminate
these fields when the particular feature (`borrow` handles, `async` imports)
is not used.

The `trap_if_on_stack` helper method is called (below) to prevent reentrance.
The definition uses the `caller` field which points to the task's supertask in
the async call tree defined by Component Model [structured concurrency].
```python
  def trap_if_on_the_stack(self, inst):
    c = self.caller
    while c is not None:
      trap_if(c.inst is inst)
      c = c.caller
```
By analyzing a linked component DAG, an optimized implementation can avoid the
O(n) loop in `trap_if_on_the_stack`:
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

The `enter` method is called immediately after constructing a `Task` and, along
with `may_enter` and `may_start_pending_task`, enforces backpressure before
lowering the arguments into the callee's memory. In particular, if `may_enter`
signals that backpressure is needed, `enter` blocks by putting itself into a
`pending_tasks` queue and waiting (via `wait_on`, defined next) to be released
by `maybe_start_pending_task`. One key property of `maybe_start_pending_task`
is that `pending_tasks` are only popped one at a time, ensuring that if an
overloaded component instance enables and then disables backpressure, there
will not be an unstoppable thundering herd of pending tasks started all at once
that OOM the component before it can re-enable backpressure.
```python
  async def enter(self, on_start):
    assert(current_task.locked())
    self.trap_if_on_the_stack(self.inst)
    if not self.may_enter(self) or self.inst.pending_tasks:
      f = asyncio.Future()
      self.inst.pending_tasks.append((self, f))
      await self.wait_on(f)
    if self.opts.sync:
      assert(self.inst.interruptible.is_set())
      self.inst.interruptible.clear()
    self.inst.num_tasks += 1
    return lower_flat_values(self, MAX_FLAT_PARAMS, on_start(), self.ft.param_types())

  def may_enter(self, pending_task):
    return self.inst.interruptible.is_set() and \
           not (pending_task.opts.sync and self.inst.num_tasks > 0) and \
           not self.inst.backpressure

  def maybe_start_pending_task(self):
    if self.inst.pending_tasks:
      pending_task, future = self.inst.pending_tasks[0]
      if self.may_enter(pending_task):
        self.inst.pending_tasks.pop(0)
        future.set_result(None)
```
The conditions in `may_enter` ensure two invariants:
* While a synchronously-lifted export or synchronously-lowered import is being
  called, concurrent/interleaved execution is disabled.
* While the wasm-controlled `backpressure` flag is set, no new tasks start
  execution.

The `wait_on` method, called by `enter`, `wait` and `yield_`, blocks the
current task until the given future is resolved, allowing other tasks to make
progress in the meantime. While blocked, another asynchronous task can make a
synchronous import call via `call_sync`, in which case, to preserve
synchronicity, `wait_on` must wait until the synchronous import call is
finished (signalled by `interrupt` being re-set).
```python
  async def wait_on(self, f):
    if self.inst.interruptible.is_set():
      v = await self.on_block(f)
      while not self.inst.interruptible.is_set():
        await self.on_block(self.inst.interruptible.wait())
    else:
      v = await self.on_block(f)
    return v

  async def call_sync(self, callee, *args):
    if self.inst.interruptible.is_set():
      self.inst.interruptible.clear()
      await callee(*args, self.on_block)
      self.inst.interruptible.set()
    else:
      await callee(*args, self.on_block)
```
If `wait_on` or `call_sync` are called when `interruptible` is *initially*
clear, then the current task must have been created for a synchronously-lifted
export call and so there are no other tasks to worry about and thus `wait_on`
*must not* wait for `interrupt` to be re-set (which won't happen until the
current task finishes via `exit`, defined below).

While a task is running, it may call `wait` or `poll` (via `canon` built-ins
`task.wait`/`task.poll` or, when using a `callback`, by returning to the event
loop) to learn about progress on async subtasks. `poll` returns either an event
or `None` without ever blocking while `wait` blocks until there is an event.
When there are multiple events ready to be delivered, the Python code selects a
random event as a way to specify that the event delivery order is
non-deterministic.
```python
  async def wait(self) -> EventTuple:
    self.maybe_start_pending_task()
    while not (e := self.poll()):
      await self.wait_on(self.has_events.wait())
    return e

  def poll(self) -> Optional[EventTuple]:
    if self.events:
      if DETERMINISTIC_PROFILE:
        i = 0
      else:
        i = random.randrange(len(self.events))
      event = self.events.pop(i)
      if not self.events:
        self.has_events.clear()
      return event()
    return None

  def notify(self, event: EventCallback):
    self.events.append(event)
    self.has_events.set()
```
Note that events are represented as *first-class functions* that are called by
`next_event` to produce the tuple of scalar values that are actually delivered
to core wasm. This allows an event source to report the latest status when the
event is handed to the core wasm code instead of the status when the event was
first generated. This allows multiple redundant events to be collapsed into
one, reducing overhead.

Although this Python code represents events as a list of closures, an
optimizing implementation should be able to avoid actually allocating these
things and instead embed a linked list of "ready" events into the table
elements associated with the events.

Lastly, a task may cooperatively yield (via `canon task.yield`), allowing the
runtime to switch execution to another task without having to wait for any
external I/O (as emulated in the Python code by awaiting `sleep(0)`:
```python
  async def yield_(self):
    self.maybe_start_pending_task()
    await self.wait_on(asyncio.sleep(0))
```

The `return_` method is called by either `canon_task_return` or `canon_lift`
(both defined below) to lift and return results to the caller using the
`on_return` callback that was supplied by the caller to `canon_lift`. Using a
callback instead of simply returning the values from `canon_lift` enables the
callee to keep executing after returning its results. However, it does
introduce a dynamic error condition if `canon task.return` is called less or
more than once which must be checked by `return_` and `exit`.
```python
  def return_(self, flat_results):
    trap_if(not self.on_return)
    if self.opts.sync:
      maxflat = MAX_FLAT_RESULTS
    else:
      maxflat = MAX_FLAT_PARAMS
    ts = self.ft.result_types()
    vs = lift_flat_values(self, maxflat, CoreValueIter(flat_results), ts)
    self.on_return(vs)
    self.on_return = None
```

Lastly, when a task exits, the runtime enforces the guard conditions mentioned
above and allows a pending task to start. The `need_to_drop` counter is
incremented and decremented below as a way of ensuring that a task does
something (like dropping a resource or subtask handle) before the task exits.
```python
  def exit(self):
    assert(current_task.locked())
    assert(not self.events)
    assert(self.inst.num_tasks >= 1)
    trap_if(self.on_return)
    trap_if(self.need_to_drop != 0)
    self.inst.num_tasks -= 1
    if self.opts.sync:
      assert(not self.inst.interruptible.is_set())
      self.inst.interruptible.set()
    self.maybe_start_pending_task()
```

While `canon_lift` creates `Task`s, `canon_lower` creates `Subtask` objects.
Like `Task`, `Subtask` is a subclass of `CallContext` and stores the `ft` and
`opts` of its `canon lower`. Importantly, the `task` field of a `Subtask`
refers to the [current task] which called `canon lower`, thereby linking all
subtasks to their supertask, maintaining the (possibly asynchronous) call
tree.
```python
class Subtask(CallContext):
  ft: FuncType
  flat_args: CoreValueIter
  flat_results: Optional[list[Any]]
  state: CallState
  lenders: list[ResourceHandle]
  notify_supertask: bool
  enqueued: bool

  def __init__(self, opts, ft, task, flat_args):
    super().__init__(opts, task.inst, task)
    self.ft = ft
    self.flat_args = CoreValueIter(flat_args)
    self.flat_results = None
    self.state = CallState.STARTING
    self.lenders = []
    self.notify_supertask = False
    self.enqueued = False
```

The `lenders` field of `Subtask` maintains a list of all the owned handles
that have been lent to a subtask and must therefor not be dropped until the
subtask completes. The `add_lender` method is called (below) when lifting an
owned handle and increments the `lend_count` of the owned handle, which is
guarded to be zero by `canon_resource_drop` (below). The `release_lenders`
method releases all the `lend_count`s of all such handles lifted for the
subtask and is called (below) when the subtask finishes.
```python
  def add_lender(self, lending_handle):
    assert(lending_handle.own)
    lending_handle.lend_count += 1
    self.lenders.append(lending_handle)

  def release_lenders(self):
    for h in self.lenders:
      h.lend_count -= 1
```
Note, the `lenders` list usually has a fixed size (in all cases except when a
function signature has `borrow`s in `list`s or `stream`s) and thus can be
stored inline in the native stack frame.

The `maybe_notify_supertask` method called by `on_start`, `on_return` and
`finish` (next) only sends events to the supertask if this `Subtask` actually
blocked and got added to the `async_subtasks` table (signalled by
`notify_supertask` being set). Additionally, `maybe_notify_supertask` uses the
`enqueued` flag and the fact that "events" are first-class functions to
collapse N events down to 1 if a subtask advances state multiple times before
the supertask receives the event which, in turn, avoids unnecessarily spamming
the event loop when only the most recent state matters.
```python
  def maybe_notify_supertask(self):
    if self.notify_supertask and not self.enqueued:
      self.enqueued = True
      def subtask_event():
        self.enqueued = False
        i = self.inst.async_subtasks.array.index(self)
        if self.state == CallState.DONE:
          self.release_lenders()
        return (EventCode(self.state), i)
      self.task.notify(subtask_event)
```

The `on_start` and `on_return` methods of `Subtask` are passed (by
`canon_lower` below) to the callee to be called to lift its arguments and
lower its results. Using callbacks provides the callee the flexibility to
control when arguments are lowered (which can vary due to backpressure) and
when results are lifted (which can also vary due to when `task.return` is
called).
```python
  def on_start(self):
    assert(self.state == CallState.STARTING)
    self.state = CallState.STARTED
    self.maybe_notify_supertask()
    max_flat = MAX_FLAT_PARAMS if self.opts.sync else 1
    ts = self.ft.param_types()
    return lift_flat_values(self, max_flat, self.flat_args, ts)

  def on_return(self, vs):
    assert(self.state == CallState.STARTED)
    self.state = CallState.RETURNED
    self.maybe_notify_supertask()
    max_flat = MAX_FLAT_RESULTS if self.opts.sync else 0
    ts = self.ft.result_types()
    self.flat_results = lower_flat_values(self, max_flat, vs, ts, self.flat_args)
```

When a `Subtask` finishes, it calls `release_lenders` to allow owned handles
passed to this subtask to be dropped. In the synchronous or eager case this
happens immediately before returning to the caller. In the
asynchronous+blocking case, this happens right before the `CallState.DONE`
event is delivered to the guest program.
```python
  def finish(self):
    assert(self.state == CallState.RETURNED)
    self.state = CallState.DONE
    if self.opts.sync or not self.notify_supertask:
      self.release_lenders()
    else:
      self.maybe_notify_supertask()
    return self.flat_results
```

Lastly, after a `Subtask` has finished and notified its supertask (thereby
clearing `enqueued`), it may be dropped from the `async_subtasks` table:
```python
  def drop(self):
    trap_if(self.enqueued)
    trap_if(self.state != CallState.DONE)
    self.task.need_to_drop -= 1
```

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
    case ListType(t, l)              : return alignment_list(t, l)
    case RecordType(fields)          : return alignment_record(fields)
    case VariantType(cases)          : return alignment_variant(cases)
    case FlagsType(labels)           : return alignment_flags(labels)
    case OwnType() | BorrowType()    : return 4
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

Handle types are passed as `i32` indices into the `Table[ResourceHandle]`
introduced below.


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
    case ListType(t, l)              : return elem_size_list(t, l)
    case RecordType(fields)          : return elem_size_record(fields)
    case VariantType(cases)          : return elem_size_variant(cases)
    case FlagsType(labels)           : return elem_size_flags(labels)
    case OwnType() | BorrowType()    : return 4

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
    case S8Type()           : return load_int(cx, ptr, 1, signed=True)
    case S16Type()          : return load_int(cx, ptr, 2, signed=True)
    case S32Type()          : return load_int(cx, ptr, 4, signed=True)
    case S64Type()          : return load_int(cx, ptr, 8, signed=True)
    case F32Type()          : return decode_i32_as_float(load_int(cx, ptr, 4))
    case F64Type()          : return decode_i64_as_float(load_int(cx, ptr, 8))
    case CharType()         : return convert_i32_to_char(cx, load_int(cx, ptr, 4))
    case StringType()       : return load_string(cx, ptr)
    case ListType(t, l)     : return load_list(cx, ptr, t, l)
    case RecordType(fields) : return load_record(cx, ptr, fields)
    case VariantType(cases) : return load_variant(cx, ptr, cases)
    case FlagsType(labels)  : return load_flags(cx, ptr, labels)
    case OwnType()          : return lift_own(cx, load_int(cx, ptr, 4), t)
    case BorrowType()       : return lift_borrow(cx, load_int(cx, ptr, 4), t)
```

Integers are loaded directly from memory, with their high-order bit interpreted
according to the signedness of the type.
```python
def load_int(cx, ptr, nbytes, signed = False):
  return int.from_bytes(cx.opts.memory[ptr : ptr+nbytes], 'little', signed=signed)
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
case index, assigning `0` to the first case, `1` to the next case, etc. To
support the subtyping allowed by `refines`, a lifted variant value semantically
includes a full ordered list of its `refines` case labels so that the lowering
code (defined below) can search this list to find a case label it knows about.
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
  h = cx.inst.resources.remove(t.rt, i)
  trap_if(h.lend_count != 0)
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
  assert(isinstance(cx, Subtask))
  h = cx.inst.resources.get(t.rt, i)
  if h.own:
    cx.add_lender(h)
  return h.rep
```
The `add_lender` call to `CallContext` participates in the enforcement of the
dynamic borrow rules, which keep the source `own` handle alive until the end
of the call (as an intentionally-conservative upper bound on how long the
`borrow` handle can be held). This tracking is only required when `h` is an
`own` handle because, when `h` is a `borrow` handle, this tracking has already
happened (when the originating `own` handle was lifted) for a strictly longer
call scope than the current call.


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
    case S8Type()           : store_int(cx, v, ptr, 1, signed=True)
    case S16Type()          : store_int(cx, v, ptr, 2, signed=True)
    case S32Type()          : store_int(cx, v, ptr, 4, signed=True)
    case S64Type()          : store_int(cx, v, ptr, 8, signed=True)
    case F32Type()          : store_int(cx, encode_float_as_i32(v), ptr, 4)
    case F64Type()          : store_int(cx, encode_float_as_i64(v), ptr, 8)
    case CharType()         : store_int(cx, char_to_i32(v), ptr, 4)
    case StringType()       : store_string(cx, v, ptr)
    case ListType(t, l)     : store_list(cx, v, ptr, t, l)
    case RecordType(fields) : store_record(cx, v, ptr, fields)
    case VariantType(cases) : store_variant(cx, v, ptr, cases)
    case FlagsType(labels)  : store_flags(cx, v, ptr, labels)
    case OwnType()          : store_int(cx, lower_own(cx, v, t), ptr, 4)
    case BorrowType()       : store_int(cx, lower_borrow(cx, v, t), ptr, 4)
```

Integers are stored directly into memory. Because the input domain is exactly
the integers in range for the given type, no extra range checks are necessary;
the `signed` parameter is only present to ensure that the internal range checks
of `int.to_bytes` are satisfied.
```python
def store_int(cx, v, ptr, nbytes, signed = False):
  cx.opts.memory[ptr : ptr+nbytes] = int.to_bytes(v, nbytes, 'little', signed=signed)
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

Variants are stored using the `|`-separated list of `refines` cases built
by `case_label_with_refinements` (above) to iteratively find a matching case (which
validation guarantees will succeed). While this code appears to do O(n) string
matching, a normal implementation can statically fuse `store_variant` with its
matching `load_variant` to ultimately build a dense array that maps producer's
case indices to the consumer's case indices.
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
  assert(len(v.keys()) == 1)
  key = list(v.keys())[0]
  value = list(v.values())[0]
  for label in key.split('|'):
    case_index = find_case(label, cases)
    if case_index != -1:
      return (case_index, value)
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
elements in the current component instance's handle table. The increment of
`need_to_drop` is complemented by a decrement in `canon_resource_drop` and
ensures that all borrowed handles are dropped before the end of the task. 
```python
def lower_own(cx, rep, t):
  h = ResourceHandle(rep, own=True)
  return cx.inst.resources.add(t.rt, h)

def lower_borrow(cx, rep, t):
  assert(isinstance(cx, Task))
  if cx.inst is t.rt.impl:
    return rep
  h = ResourceHandle(rep, own=False, scope=cx)
  cx.need_to_drop += 1
  return cx.inst.resources.add(t.rt, h)
```
The special case in `lower_borrow` is an optimization, recognizing that, when
a borrowed handle is passed to the component that implemented the resource
type, the only thing the borrowed handle is good for is calling
`resource.rep`, so lowering might as well avoid the overhead of creating an
intermediate borrow handle.


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
        flat_params = []
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
    case ListType(t, l)                   : return flatten_list(t, l)
    case RecordType(fields)               : return flatten_record(fields)
    case VariantType(cases)               : return flatten_variant(cases)
    case FlagsType(labels)                : return ['i32']
    case OwnType() | BorrowType()         : return ['i32']
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
    case ListType(t, l)     : return lift_flat_list(cx, vi, t, l)
    case RecordType(fields) : return lift_flat_record(cx, vi, fields)
    case VariantType(cases) : return lift_flat_variant(cx, vi, cases)
    case FlagsType(labels)  : return lift_flat_flags(vi, labels)
    case OwnType()          : return lift_own(cx, vi.next('i32'), t)
    case BorrowType()       : return lift_borrow(cx, vi.next('i32'), t)
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
  return { case_label_with_refinements(c, cases): v }

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
    case ListType(t, l)     : return lower_flat_list(cx, v, t, l)
    case RecordType(fields) : return lower_flat_record(cx, v, fields)
    case VariantType(cases) : return lower_flat_variant(cx, v, cases)
    case FlagsType(labels)  : return lower_flat_flags(v, labels)
    case OwnType()          : return [lower_own(cx, v, t)]
    case BorrowType()       : return [lower_borrow(cx, v, t)]
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
```wasm
(canon lift $callee:<funcidx> $opts:<canonopt>* (func $f (type $ft)))
```
validation specifies:
* `$callee` must have type `flatten_functype($opts, $ft, 'lift')`
* `$f` is given type `$ft`
* a `memory` is present if required by lifting and is a subtype of `(memory 1)`
* a `realloc` is present if required by lifting and has type `(func (param i32 i32 i32 i32) (result i32))`
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
async calls. The `on_block` callback is described above and defaults to
`default_on_block`, also described above.

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

Based on this, `canon_lift` is defined:
```python
async def canon_lift(opts, inst, ft, callee, caller, on_start, on_return, on_block = default_on_block):
  task = Task(opts, inst, ft, caller, on_return, on_block)
  flat_args = await task.enter(on_start)
  if opts.sync:
    flat_results = await call_and_trap_on_throw(callee, task, flat_args)
    task.return_(flat_results)
    if opts.post_return is not None:
      [] = await call_and_trap_on_throw(opts.post_return, task, flat_results)
  else:
    if not opts.callback:
      [] = await call_and_trap_on_throw(callee, task, flat_args)
    else:
      [packed_ctx] = await call_and_trap_on_throw(callee, task, flat_args)
      while packed_ctx != 0:
        is_yield = bool(packed_ctx & 1)
        ctx = packed_ctx & ~1
        if is_yield:
          await task.yield_()
          event, payload = (EventCode.YIELDED, 0)
        else:
          event, payload = await task.wait()
        [packed_ctx] = await call_and_trap_on_throw(opts.callback, task, [ctx, event, payload])
  task.exit()
```
In the `async` case, there are two sub-cases depending on whether the
`callback` `canonopt` was set. When `callback` is present, waiting happens in
an "event loop" inside `canon_lift` which also allows yielding (i.e., allowing
other tasks to run without blocking) by setting the LSB of the returned `i32`.
Otherwise, waiting must happen by calling `task.wait` (defined below), which
potentially requires the runtime implementation to use a fiber (aka. stackful
coroutine) to switch to another task. Thus, `callback` is an optimization for
avoiding fiber creation for async languages that don't need it (e.g., JS,
Python, C# and Rust).

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
```wasm
(canon lower $callee:<funcidx> $opts:<canonopt>* (core func $f))
```
where `$callee` has type `$ft`, validation specifies:
* `$f` is given type `flatten_functype($opts, $ft, 'lower')`
* a `memory` is present if required by lifting and is a subtype of `(memory 1)`
* a `realloc` is present if required by lifting and has type `(func (param i32 i32 i32 i32) (result i32))`
* there is no `post-return` in `$opts`

When instantiating component instance `$inst`:
* Define `$f` to be the partially-bound closure: `canon_lower($opts, $ft, $callee)`

The resulting function `$f` takes 2 runtime arguments:
* `task`: the `Task` that was created by `canon_lift` when entering the current
  component instance
* `flat_args`: the list of core values passed by the core function calller

Given this, `canon_lower` is defined:
```python
async def canon_lower(opts, ft, callee, task, flat_args):
  trap_if(not task.inst.may_leave)
  subtask = Subtask(opts, ft, task, flat_args)
  if opts.sync:
    await task.call_sync(callee, task, subtask.on_start, subtask.on_return)
    flat_results = subtask.finish()
  else:
    async def do_call(on_block):
      await callee(task, subtask.on_start, subtask.on_return, on_block)
      [] = subtask.finish()
    match await call_and_handle_blocking(do_call):
      case Blocked():
        subtask.notify_supertask = True
        task.need_to_drop += 1
        i = task.inst.async_subtasks.add(subtask)
        flat_results = [pack_async_result(i, subtask.state)]
      case Returned():
        flat_results = [0]
  return flat_results
```
In the asynchronous case, if `do_call` blocks before `Subtask.finish`
(signalled by `callee` calling `on_block`), the `Subtask` is added to an
instance-wide table and given an `i32` index that is later returned by
`task.wait` to signal subtask's progress. The `need_to_drop` increment is
matched by a decrement in `canon_subtask_drop` and ensures that all subtasks
of a supertask are allowed to complete before the supertask completes. The
`notify_supertask` flag is set to tell `Subtask` methods (below) to
asynchronously notify the supertask of progress. Lastly, the current progress
of the subtask is returned to the caller, packed with the `i32` subtask index:
```python
def pack_async_result(i, state):
  assert(0 < i < 2**30)
  assert(0 <= int(state) < 2**2)
  return i | (int(state) << 30)
```
If the returned `state` is `CallState.STARTING`, the caller must keep the
memory pointed by `flat_args` valid until `task.wait` indicates that subtask
`i` has advanced to `STARTED`, `RETURNED` or `DONE`. Similarly, if the returned
state is `STARTED`, the caller must keep the memory pointed to by the final
`i32` parameter of `flat_args` valid until `task.wait` indicates that the
subtask has advanced to `RETURNED` or `DONE`.

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
```wasm
(canon resource.new $rt (core func $f))
```
validation specifies:
* `$rt` must refer to locally-defined (not imported) resource type
* `$f` is given type `(func (param $rt.rep) (result i32))`, where `$rt.rep` is
  currently fixed to be `i32`.

Calling `$f` invokes the following function, which adds an owning handle
containing the given resource representation in the current component
instance's handle table:
```python
async def canon_resource_new(rt, task, rep):
  trap_if(not task.inst.may_leave)
  h = ResourceHandle(rep, own=True)
  i = task.inst.resources.add(rt, h)
  return [i]
```

### `canon resource.drop`

For a canonical definition:
```wasm
(canon resource.drop $rt $async? (core func $f))
```
validation specifies:
* `$rt` must refer to resource type
* `$f` is given type `(func (param i32))`

Calling `$f` invokes the following function, which removes the handle from the
current component instance's handle table and, if the handle was owning, calls
the resource's destructor.
```python
async def canon_resource_drop(rt, sync, task, i):
  trap_if(not task.inst.may_leave)
  inst = task.inst
  h = inst.resources.remove(rt, i)
  flat_results = [] if sync else [0]
  if h.own:
    assert(h.scope is None)
    trap_if(h.lend_count != 0)
    if inst is rt.impl:
      if rt.dtor:
        await rt.dtor(h.rep)
    else:
      if rt.dtor:
        caller_opts = CanonicalOptions(sync = sync)
        callee_opts = CanonicalOptions(sync = rt.dtor_sync, callback = rt.dtor_callback)
        ft = FuncType([U32Type()],[])
        callee = partial(canon_lift, callee_opts, rt.impl, ft, rt.dtor)
        flat_results = await canon_lower(caller_opts, ft, callee, task, [h.rep, 0])
      else:
        task.trap_if_on_the_stack(rt.impl)
  else:
    h.scope.need_to_drop -= 1
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
```wasm
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
  h = task.inst.resources.get(rt, i)
  return [h.rep]
```
Note that the "locally-defined" requirement above ensures that only the
component instance defining a resource can access its representation.

### 🔀 `canon task.backpressure`

For a canonical definition:
```wasm
(canon task.backpressure (core func $f))
```
validation specifies:
* `$f` is given type `[i32] -> []`

Calling `$f` invokes the following function, which sets the `backpressure`
flag on the current `ComponentInstance`:
```python
async def canon_task_backpressure(task, flat_args):
  trap_if(task.opts.sync)
  task.inst.backpressure = bool(flat_args[0])
  return []
```
The `backpressure` flag is read by `Task.enter` (defined above) to prevent new
tasks from entering the component instance and forcing the guest code to
consume resources.

### 🔀 `canon task.return`

For a canonical definition:
```wasm
(canon task.return $ft (core func $f))
```
validation specifies:
* `$f` is given type `$ft`, which validation requires to be a (core) function type

Calling `$f` invokes the following function which uses `Task.return_` to lift
and pass the results to the caller:
```python
async def canon_task_return(task, core_ft, flat_args):
  trap_if(not task.inst.may_leave)
  trap_if(task.opts.sync)
  trap_if(core_ft != flatten_functype(CanonicalOptions(), FuncType(task.ft.results, []), 'lower'))
  task.return_(flat_args)
  return []
```
An expected implementation of `task.return` would generate a core wasm function
for each lowering of an `async`-lifted export that performs the fused copy of
the results into the caller, storing the index of this function in the `Task`
structure and using `call_indirect` to perform the function-type-equality check
required here.

### 🔀 `canon task.wait`

For a canonical definition:
```wasm
(canon task.wait (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32) (result i32))`

Calling `$f` waits for progress to be made in a subtask of the current task,
returning the event (which is currently simply an `CallState` value)
and writing the subtask index as an outparam:
```python
async def canon_task_wait(task, ptr):
  trap_if(not task.inst.may_leave)
  trap_if(task.opts.callback is not None)
  event, payload = await task.wait()
  store(task, payload, U32Type(), ptr)
  return [event]
```
The `trap_if` ensures that, when a component uses a `callback` all events flow
through the event loop at the base of the stack.

Note that `task.wait` will only block the current `Task`, allowing other tasks
to run. Note also that `task.wait` can be called from a synchronously-lifted
export so that even synchronous code can make concurrent import calls. In these
synchronous cases, though, the automatic backpressure (applied by `Task.enter`)
will ensure there is only ever at most once synchronously-lifted task executing
in a component instance at a time.

### 🔀 `canon task.poll`

For a canonical definition:
```wasm
(canon task.poll (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32) (result i32))`

Calling `$f` does a non-blocking check for whether an event is already
available, returning whether or not there was such an event as a boolean and,
if there was an event, storing the `i32` event+payload pair as an outparam.
```python
async def canon_task_poll(task, ptr):
  trap_if(not task.inst.may_leave)
  ret = task.poll()
  if ret is None:
    return [0]
  store(task, ret, TupleType([U32Type(), U32Type()]), ptr)
  return [1]
```
Note that there is no `await` of `poll` and thus no possible task switching.

### 🔀 `canon task.yield`

For a canonical definition:
```wasm
(canon task.yield (core func $f))
```
validation specifies:
* `$f` is given type `(func)`

Calling `$f` calls `Task.yield_`, trapping if called when there is a `callback`.
(When there is a callback, yielding is achieved by returning with the LSB set.)
```python
async def canon_task_yield(task):
  trap_if(not task.inst.may_leave)
  trap_if(task.opts.callback is not None)
  await task.yield_()
  return []
```

### 🔀 `canon subtask.drop`

For a canonical definition:
```wasm
(canon subtask.drop (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32))`

Calling `$f` removes the indicated subtask from the instance's table, trapping
if various conditions aren't met in `Subtask.drop()`.
```python
async def canon_subtask_drop(task, i):
  trap_if(not task.inst.may_leave)
  task.inst.async_subtasks.remove(i).drop()
  return []
```

### 🧵 `canon thread.spawn`

For a canonical definition:
```wasm
(canon thread.spawn (type $ft) (core func $st))
```
validation specifies:
* `$ft` must refer to a `shared` function type; initially, only the type `(func
  shared (param $c i32))` is allowed (see explanation below)
* `$st` is given type `(func (param $f (ref null $ft)) (param $c i32) (result $e
  i32))`.

> Note: ideally, a thread could be spawned with [arbitrary thread parameters].
> Currently, that would require additional work in the toolchain to support so,
> for simplicity, the current proposal simply fixes a single `i32` parameter type.
> However, `thread.spawn` could be extended to allow arbitrary thread parameters
> in the future, once it's concretely beneficial to the toolchain.
> The inclusion of `$ft` ensures backwards compatibility for when arbitrary
> parameters are allowed.

Calling `$st` checks that the reference `$f` is not null. Then, it spawns a
thread which:
  - invokes `$f` with `$c`
  - executes `$f` until completion or trap in a `shared` context as described by
    the [shared-everything threads] proposal.

In pseudocode, `$st` looks like:

```python
def canon_thread_spawn(f, c):
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

### 🧵 `canon thread.hw_concurrency`

For a canonical definition:
```wasm
(canon thread.hw_concurrency (core func $f))
```
validation specifies:
* `$f` is given type `(func shared (result i32))`.

Calling `$f` returns the number of threads the underlying hardware can be
expected to execute concurrently. This value can be artificially limited by
engine configuration and is not allowed to change over the lifetime of a
component instance.

```python
def canon_thread_hw_concurrency():
  if DETERMINISTIC_PROFILE:
    return [1]
  else:
    return [NUM_ALLOWED_THREADS]
```

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
