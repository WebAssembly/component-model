# 🔀 Async Explainer

*This explainer describes a feature that is part of the forthcoming "Preview 3"
release of the Component Model. The relevant parts of the [AST explainer],
[binary format] and [Canonical ABI explainer] are gated by the 🔀 emoji.*

This explainer provides a high-level summary of the native async support in the
Component Model. For a detailed presentation of the runtime semantics, see the
[Canonical ABI explainer]. See also the [Wasm I/O 2024 presentation] for a
summary of the motivation and animated sketch of the design in action.

* [Goals](#goals)
* [High-level Approach](#high-level-approach)
* [Concepts](#concepts)
  * [Sync and Async Functions](#sync-and-async-functions)
  * [Task](#task)
  * [Current task](#current-task)
  * [Context-Local Storage](#context-local-storage)
  * [Structured concurrency](#structured-concurrency)
  * [Streams and Futures](#streams-and-futures)
  * [Waiting](#waiting)
  * [Backpressure](#backpressure)
  * [Returning](#returning)
  * [Borrows](#borrows)
  * [Cancellation](#cancellation)
  * [Nondeterminism](#nondeterminism)
* [Async ABI](#async-abi)
  * [Async Import ABI](#async-import-abi)
  * [Async Export ABI](#async-export-abi)
* [Examples](#examples)
* [Interaction with the start function](#interaction-with-the-start-function)
* [Interaction with multi-threading](#interaction-with-multi-threading)
* [TODO](#todo)


## Goals

Given only *synchronous* functions with values and resources, when a component
needs to do concurrent (i.e., overlapping, interleaved, streaming) I/O, the
resulting [WIT] interfaces and implementations end up being complex,
hard to compose, and less efficient. By extending the Component Model with
built-in **asynchronous** support, these pain points can be addressed.

The Component Model's [goals] and intended [use cases] suggest the following
additional goals and requirements for native async support:

* Be independent-of but complementary-to the Core WebAssembly [stack-switching]
  proposal; don't depend on this proposal being fully standard or implemented
  (just like [JSPI]).
* Be independent-of but complementary-to the Core WebAssembly
  [shared-everything-threads] proposal; don't depend on this proposal being
  fully standard or implemented and ensure that components can achieve a high
  degree of concurrency using only one.
* Avoid partitioning interfaces and components into separate strata; don't give
  functions (or components) a [color].
* Enable tight integration (e.g., automatic bindings generation) with a wide
  variety of source languages' built-in concurrency features.
* Maintain meaningful cross-language call stacks (for the benefit of debugging,
  logging and tracing).
* Provide mechanisms for applying and observing backpressure.
* Allow non-reentrant synchronous and event-loop-driven core wasm code (that,
  e.g., assumes a single global linear memory stack) to not have to worry about
  additional reentrancy.


## High-level Approach

Based on the above goals, the Component Model's approach to native async starts
by allowing components to import and export "async" functions which abstract
over, and can be implemented by, idiomatic concurrency in a variety of
programming languages:
* `async` functions in languages like C#, JS, Python, Rust and Swift
* stackful coroutines in languages like Kotlin, Perl, PHP and (recently) C++
* green threads as-if running on a single OS thread in languages like Go and
  (initially and recently again) Java
* callbacks, in languages with no explicit async support

The Component Model supports this wide variety of language features by
specifying a common low-level "async" ABI which the different languages'
compilers and runtimes can bind their different language-level concurrency
features to. This is similar to how a native OS exposes APIs for concurrency
(such as `epoll`, `io_uring`, `kqueue` or Overlapped I/O) to which most of
these languages' concurrency features are already bound (making the Component
Model "just another OS" from the language toolchains' perspective).

Moreover, this async ABI does not require components to use preemptive
multi-threading ([`thread.spawn*`]) in order to achieve concurrency. Instead,
concurrency can be achieved by cooperatively switching between different
logical tasks running on a single thread using [fibers] or a [CPS transform] in
the wasm runtime as necessary.

To avoid partitioning the world along sync/async lines as mentioned in the
Goals section, the Component Model allows *every* component-level function type
to be both implemented and called in either a synchronous or asynchronous
manner. Thus, function types do not dictate synchrony or asynchrony and all 4
combinations of {sync, async} x {caller, callee} are supported and given a
well-defined behavior. Specifically, the caller and callee can independently
specify `async` as an immediate flags on the [lift and lower definitions] used
to define their imports and exports.

To provide wasm runtimes with additional optimization opportunities for
languages with "stackless" concurrency (e.g. languages using `async`/`await`),
two `async` ABI sub-options are provided: a "stackless" ABI selected by
providing a `callback` function and a "stackful" ABI selected by *not*
providing a `callback` function. The stackless ABI allows core wasm to
repeatedly return to an [event loop] to receive events concerning a selected
set of "waitables", thereby clearing the native stack when waiting for events
and allowing the runtime to reuse stack segments between events. In the
[future](#TODO), a `strict-callback` option may be added to require (via
runtime traps) *all* waiting to happen via the event loop, thereby giving the
engine more up-front information that the engine can use to avoid allocating
[fibers] in more cases. In the meantime, to support complex applications with
mixed dependencies and concurrency models, the `callback` immediate allows
*both* returning to the event loop *and* making blocking calls to wait for
event.

To propagate backpressure, it's necessary for a component to be able to say
"there are too many async export calls already in progress, don't start any
more until I let some of them complete". Thus, the low-level async ABI provides
a way to apply and release backpressure.

With this backpressure protocol in place, there is a natural way for sync and
async code to interoperate:
1. If an async component calls a sync component and the sync component blocks,
   execution is immediately returned to the async component, effectively
   suspending the sync component.
2. If anyone tries to reenter the now-suspended sync component, the Component
   Model automatically signals backpressure on the suspended component's
   behalf.

Thus, backpressure combined with the partitioning of low-level state provided
by the Component Model enables sync and async code to interoperate while
preserving the expectations of both.

Lastly, WIT is extended with two new type constructors—`future<T>` and
`stream<T>`—to allow new WIT interfaces to explicitly represent concurrency in
*both* the sync and async ABIs in way that can be bound to many language's
idiomatic futures, promises, streams and channels. Futures and streams are,
semantically, unidirectional unbuffered channels with a dynamically-enforced
[session type] describing the passing of exactly 1 or 0..N values, resp., with
the additional ability for the reader end to signal a loss of interest
to the writer end. Thus, futures and streams are more primitive concepts than,
e.g., Unix pipes (which have an associated intermediate memory buffer that
values are copied into and out of). Rather, streams could be used to *define*
higher-level concepts like pipes, HTTP response bodies or stream transformers.
E.g.:
```wit
resource pipe {
  constructor(buffer-size: u32);
  write: func(bytes: stream<u8>) -> result;
  read: func() -> stream<u8>;
}
resource response {
  constructor(body: stream<u8>);
  consume-body: func() -> stream<u8>;
}
transform: func(in: stream<point>) -> stream<point>;
```
A `future` or `stream` in a function signature always refers to the transfer of
unique ownership of the *readable end* of the future or stream. To get a
*writable end*, a component must first internally create a (readable, writable)
end pair (via the [`{stream,future}.new`] built-ins) and then pass the readable
end elsewhere (e.g., in the above WIT, as a parameter to an imported
`pipe.write` or as a result of an exported `transform`). Given the readable or
writable end of a future or stream (represented as an `i32` index into the
component instance's handle table), Core WebAssembly can then call a
[`{stream,future}.{read,write}`] built-in to synchronously or asynchronously
copy into or out of a caller-provided buffer of Core WebAssembly linear (or,
soon, GC) memory.

## Concepts

The following concepts are defined as part of the Component Model's native
async support.

### Sync and Async Functions

The distinction between sync and async functions does not appear in the
component-level function type (nor in WIT). Rather, an "async" function is a
component-level function that has been [lifted] from Core WebAssembly with the
`async` option set. Symmetrically, a "sync" function is a component-level
function that does not have the `async` option set (which is the default and
only option prior to Preview 3). Thus, the sync/async distinction appears
only independently in how a component-level function is *implemented* or
*called*. This lack of distinction helps to avoid the classic ["What Color Is
Your Function?"][Color] problem.

Functions *may* however be annotated (in both WIT and component binaries) with
`async` as a *hint*. This hint is intended to inform the default language
bindings generation, indicating whether to use a source-level `async` function
or not in languages that have such a distinction (e.g., JS, Python, C# and
Rust). In the absence of such a hint, a bindings generator would be forced to
make a uniform decision for what to do by default for all functions or require
manual programmer directives. However, because `async` is just a hint, there is
no prohibition against non-`async`-exported functions calling imported `async`
functions. This does mean that non-`async` functions may end up blocking
their caller, but (1) any loss in performance is the callee's "fault", (2) the
caller can still lower `async` if they want to (overriding the default hint),
(3) any *transitive* caller an lower `async` to avoid blocking.

For example, given this interface:
```wit
interface filesystem {
  resource file {
    constructor();
    is-closed: func() -> bool;
    read: async func(num-bytes: u32) -> result<list<u8>>;
    from-bytes: static func(bytes: list<u8>) -> file;
    from-stream: static async func(bytes: stream<u8>) -> file;
  }
}
```
A bindings generator processing the above WIT for a language with `async` would
only emit `async` functions for `read` and `from-stream`.

Since in many languages `new` expressions cannot be async, there is no
`async constructor`. Use cases requiring asynchronous construction can instead
use `static async` functions, similar to `from-stream` in this example.

### Task

Every time a lifted function is called (e.g., when a component's export is
called by the outside world), a new **task** is created that logically contains
all the transitive control-flow state of the export call and will be destroyed
when the export call finishes.

When all of a component's exports are lifted synchronously, there will be at most one
task alive at any one time. However, when a component exports asynchronously-lifted
functions, there can be multiple tasks alive at once.

In the Canonical ABI explainer, a "task" is represented with the Python
[`Task`] class. A new `Task` object is created (by [`canon_lift`]) each time
a component export is called.

### Current Task

At any point in time when executing in Core WebAssembly code, there is a
well-defined **current task**. Thus, whenever a [canonical built-in] is called
by Core WebAssembly code, it is meaningful for the built-in to work in terms
"the current task".

The "current task" is modelled in the Canonical ABI's Python code
by implicitly threading the `Task` object created by [`canon_lift`] through all
the Python functions transitively called by `canon_lift`. Thus, although there
can be multiple live `Task` objects in a component instance, "the current one"
is always clear: it's the one passed to the current function as a parameter.

### Context-Local Storage

Each task contains a distinct mutable **context-local storage** array. The
current task's context-local storage can be read and written from core wasm
code by calling the [`context.get`] and [`context.set`] built-ins.

The context-local storage array's length is currently fixed to contain exactly
1 `i32` with the goal of allowing this array to be stored inline in whatever
existing runtime data structure is already efficiently reachable from ambient
compiled wasm code. Because module instantiation is declarative in the
Component Model, the imported `context.{get,set}` built-ins can be inlined by
the core wasm compiler as-if they were instructions, allowing the generated
machine code to be a single load or store. This makes context-local storage a
good place to store the pointer to the struct used to implement [thread-local
storage] APIs used by guest code.

When [memory64] is integrated into the Component Model's Canonical ABI,
`context.{get,set}` will be backwards-compatibly relaxed to allow `i64`
pointers (overlaying the `i32` values like hardware 32/64-bit registers). When
[wasm-gc] is integrated, these integral context values can serve as indices
into guest-managed tables of typed GC references.

When [threads are added](#interaction-with-multi-threading), each thread will
also get its own distinct mutable context-local storage array. This is the
reason why "context-local" storage is not called "task-local" storage (where a
"context" is a finer-grained unit of execution than either a "task" or a
"thread"). As part of this, the context-local storage array length will be
increased to 2, allowing the linear-memory stack pointer to be moved from a
core wasm `global` into context-local storage.

Since the same mutable context-local storage cells are shared by all core wasm
running under the same task/thread in the same component, the cells' contents
must be carefully coordinated in the same way as native code has to carefully
coordinate native ISA state (e.g., the [FS or GS segment base address]). In the
common case, context-local storage is only `context.set` by the entry
trampoline invoked by [`canon_lift`] and then all transitively reachable core
wasm code (including from any `callback`) assumes `context.get` returns the
same value. Thus, if any *non*-entry-trampoline code calls `context.set`, it is
the responsibility of *that code* to restore this default assumption before
allowing control flow to escape into the wild.

For details, see [`context.get`] in the AST explainer and [`canon_context_get`]
in the Canonical ABI explainer.

### Structured concurrency

Calling *into* a component creates a `Task` to track ABI state related to the
*callee* (like "number of outstanding borrows").

Calling *out* of a component creates a `Subtask` to track ABI state related to
the *caller* (like "which handles have been lent").

When one component calls another, there is thus a `Subtask`+`Task` pair that
collectively maintains the overall state of the call and enforces that both
components uphold their end of the ABI contract. But when the host calls into
a component, there is only a `Task` and, symmetrically, when a component calls
into the host, there is only a `Subtask`.

Based on this, the call stack when a component calls a host-defined import will
have the general form:
```
[Host]
  ↓ host calls component export
[Component Task]
  ↓ component calls import implemented by another component's export 0..N times
[Component Subtask <> Component Task]*
  ↓ component calls import implemented by the host
[Component Subtask <> Host task]
```
Here, the `<-` arrow represents the `supertask` relationship that is immutably
established when first making the call. A paired `Subtask` and `Task` have the
same `supertask` and can thus be visualized as a single node in the callstack.

(These concepts are represented in the Canonical ABI Python code via the
[`Task`] and [`Subtask`] classes.)

One semantically-observable use of this async call stack is to distinguish
between hazardous **recursive reentrance**, in which a component instance is
reentered when one of its tasks is already on the callstack, from
business-as-usual **sibling reentrance**, in which a component instance is
freshly reentered when its other tasks are suspended waiting on I/O. Recursive
reentrance currently always traps, but may be allowed (and indicated to core
wasm) in an opt-in manner in the [future](#TODO).

The async call stack is also useful for non-semantic purposes such as providing
backtraces when debugging, profiling and distributed tracing. While particular
languages can and do maintain their own async call stacks in core wasm state,
without the Component Model's async call stack, linkage *between* different
languages would be lost at component boundaries, leading to a loss of overall
context in multi-component applications.

There is an important nuance to the Component Model's minimal form of
Structured Concurrency compared to Structured Concurrency support that appears
in popular source language features/libraries. Often, "Structured Concurrency"
refers to an invariant that all "child" tasks finish or are cancelled before a
"parent" task completes. However, the Component Model doesn't force subtasks to
[return](#returning) or be cancelled before the supertask returns (this is left
as an option to particular source languages to enforce or not). The reason for
not enforcing a stricter form of Structured Concurrency at the Component
Model level is that there are important use cases where forcing a supertask to
stay resident simply to wait for a subtask to finish would waste resources
without tangible benefit. Instead, we can say that once the core wasm
implementing a supertask finishes execution, the supertask semantically "tail
calls" any still-live subtasks, staying technically-alive until they complete,
but not consuming real resources. Concretely, this means that a supertask that
finishes executing stays on the callstack of any still-executing subtasks for
the abovementioned purposes until all transitive subtasks finish.

For scenarios where one component wants to *non-cooperatively* put an upper
bound on execution of a call into another component, a separate "[blast zone]"
feature is necessary in any case (due to iloops and traps).

### Streams and Futures

Streams and Futures have two "ends": a *readable end* and *writable end*. When
*consuming* a `stream` or `future` value as a parameter (of an export call with
a `stream` or `future` somewhere in the parameter types) or result (of an
import call with a `stream` or `future` somewhere in the result type), the
receiver always gets *unique ownership* of the *readable end* of the `stream`
or `future`. When *producing* a `stream` or `future` value as a parameter (of
an import call) or result (of an export call), the producer can *transfer
ownership* of a readable end that it has either been given by the outside world
or freshly created via `{stream,future}.new` (which also return a fresh paired
writable end that is permanently owned by the calling component instance).

Based on this, `stream<T>` and `future<T>` values can be passed between
functions as if they were synchronous `list<T>` and `T` values, resp. For
example, given `f` and `g` with types:
```wit
f: func(x: whatever) -> stream<T>;
g: func(s: stream<T>) -> stuff;
```
Given this, `g(f(x))` works as you might hope, concurrently streaming the
results of `f` into `g`.

Given the readable or writable end of a stream, core wasm code can call the
imported `stream.read` or `stream.write` canonical built-ins, resp., passing the
pointer and length of a linear-memory buffer to write-into or read-from, resp.
These built-ins can either return immediately if >0 elements were able to be
written or read immediately (without blocking) or return a sentinel "blocked"
value indicating that the read or write will execute concurrently. The readable
and writable ends of streams and futures can then be [waited](#waiting) on to
make progress. Notification of progress signals *completion* of a read or write
(i.e., the bytes have already been copied into the buffer). Additionally,
*readiness* (to perform a read or write in the future) can be queried and
signalled by performing a `0`-length read or write (see the [Stream State]
section in the Canonical ABI explainer for details).

As a temporary limitation, if a `read` and `write` for a single stream or
future occur from within the same component and the element type is non-empty,
there is a trap. In the future this limitation will be removed.

The `T` element type of streams and futures is optional, such that `future` and
`stream` can be written in WIT without a trailing `<T>`. In this case, the
asynchronous "values(s)" being delivered are effectively meaningless [unit]
values. However, the *timing* of delivery is meaningful and thus `future` and
`stream` can used to convey timing-related information. Note that, since
functions are asynchronous by default, a plain `f: func()` conveys completion
without requiring an explicit `future` return type. Thus, a function like
`f2: func() -> future` would convey *two* events: first, the return of `f2`, at
which point the caller receives the readable end of a `future` that, when
successfully read, conveys the completion of a second event.

The [Stream State] and [Future State] sections describe the runtime state
maintained for streams and futures by the Canonical ABI.

### Waiting

When a component asynchronously lowers an import, it is explicitly requesting
that, if the import blocks, control flow be returned back to the calling task
so that it can do something else. Similarly, if `stream.read` or `stream.write`
are called asynchronously and would block, they return a "blocked" code so that
the caller can continue to make progress on other things. But eventually, a
task will run out of other things to do and will need to **wait** for progress
on one of the task's subtasks, reads or writes, which are collectively called
its **waitables**. The Canonical ABI Python represents waitables with the
[`Waitable`] base class. While a task is waiting, the Component Model runtime
can switch to other running tasks or start new tasks by invoking exports.

To avoid the O(N) cost of processing an N-ary list of waitables every time a
task needs to wait (which is the classic performance bottleneck of, e.g., POSIX
`select()`), the Canonical ABI allows waitables to be maintained in **waitable
sets** which (like `epoll()`) can be waited upon as a whole for any one of the
member waitables to make progress. Waitable sets are independent of tasks;
tasks can wait on different waitable sets over time and a single waitable set
can be waited upon by multiple tasks at once. Waitable sets are local to a
component instance and cannot be shared across component boundaries.

The Canonical ABI provides two ways for a task to wait on a waitable set:
* Core wasm can pass (the index of) the waitable set as a parameter to the
  [`waitable-set.wait`] built-in which blocks and returns the event that
  occurred.
* If the task uses a `callback` function, core wasm can return (the index of)
  the waitable set as a return value to the event loop, which will block and
  then pass the event that occurred as a parameter to the `callback`.

While the two approaches have significant runtime implementation differences,
semantically they do the same thing which, in the Canonical ABI Python code, is
factored out into the [`Task.wait_for_event`] method. Thus, the difference between
`callback` and non-`callback` is one of optimization (as described
[above](#high-level-approach)), not expressivity.

In addition to waiting for an event to occur, a task can also **poll** for
whether an event has already occurred. Polling does not block, but does allow
other tasks to be switched to and executed. Polling is opportunistic, allowing
the servicing of higher-priority events in the middle of longer-running
computations; when there is nothing left to do, a task must *wait*. A task
can poll by either calling [`waitable-set.poll`] or, when using a
`callback`, by returning the Canonical-ABI-defined "poll" code to the event loop
along with (the index of) the waitable set to poll.

Lastly, if a long-running task wants to allow other tasks to execute, without
having any of its own subtasks to wait on, it can **yield**, allowing other
tasks to be scheduled before continuing execution of the current task. A task
can yield by either calling [`yield`] or, when using a `callback`, by returning
the Canonical-ABI-defined "yield" code to the event loop.

### Backpressure

Once a component exports asynchronously-lifted functions, multiple concurrent
export calls can start piling up, each consuming some of the component's finite
private resources (like linear memory), requiring the component to be able to
exert *backpressure* to allow some tasks to finish (and release private
resources) before admitting new async export calls. To do this, a component may
call the [`backpressure.set`] built-in to set a component-instance-wide
"backpressure" flag that causes subsequent export calls to immediately return
in the "starting" state without calling the component's Core WebAssembly code.

See the [`canon_backpressure_set`] function and [`Task.enter`] method in the
Canonical ABI explainer for the setting and implementation of backpressure.

In addition to *explicit* backpressure set by wasm code, there is also an
*implicit* source of backpressure used to protect non-reentrant core wasm
code. In particular, when an export is lifted synchronously or using an
`async callback`, a component-instance-wide lock is implicitly acquired every
time core wasm is executed. By returning to the event loop after every event
(instead of once at the end of the task), `async callback` exports release
the lock between every event, allowing a higher degree of concurrency than
synchronous exports. `async` (stackful) exports ignore the lock entirely and
thus achieve the highest degree of (cooperative) concurrency.

Once a task is allowed to start according to these backpressure rules, its
arguments are lowered into the callee's linear memory and the task is in
the "started" state.

### Returning

The way an async function returns its value is by calling [`task.return`],
passing the core values that are to be lifted as *parameters*.

Returning values by calling `task.return` allows a task to continue executing
even after it has passed its initial results to the caller. This can be useful
for various finalization tasks (freeing memory or performing logging, billing
or metrics operations) that don't need to be on the critical path of returning
a value to the caller, but the major use of executing code after `task.return`
is to continue to read and write from streams and futures. For example, a
stream transformer function of type `func(in: stream<T>) -> stream<U>` will
immediately `task.return` a stream created via `stream.new` and then sit in a
loop interleaving `stream.read`s (of the readable end passed for `in`) and
`stream.write`s (of the writable end it `stream.new`ed) before exiting the
task.

Once `task.return` is called, the task is in the "returned" state and can
finish execution any time thereafter. See the [`canon_task_return`] function in
the Canonical ABI explainer for more details.

### Borrows

Component Model async support is careful to ensure that `borrow`ed handles work
as expected in an asynchronous setting, extending the dynamic enforcement used
for synchronous code:

When a caller initially lends an `own`ed or `borrow`ed handle to a callee, a
`num_lends` counter on the lent handle is incremented when the subtask starts
and decremented when the caller is notified that the subtask has
[returned](#returning). If the caller tries to drop a handle while the handle's
`num_lends` is greater than zero, the caller traps. Symmetrically, each
`borrow` handle passed to a callee increments a `num_borrows` counter on the
callee task that is decremented when the `borrow` handle is dropped. If a
callee task attempts to return when its `num_borrows` is greater than zero, the
callee traps.

In an asynchronous setting, the only generalization necessary is that, since
there can be multiple overlapping async tasks executing in a component
instance, a borrowed handle must track *which* task's `num_borrow`s was
incremented so that the correct counter can be decremented.

### Cancellation

Once an async call has started, blocked and been added to the caller's table,
the caller may decide that it no longer needs the results or effects of the
subtask. In this case, the caller may **cancel** the subtask by calling the
[`subtask.cancel`] built-in.

Once cancellation is requested, since the subtask may have already racily
returned a value, the caller may still receive a return value. However, the
caller may also be notified that the subtask is in one of two additional
terminal states:
* the subtask was **cancelled before it started**, in which case the caller's
  arguments were not passed to the callee (in particular, owned handles were
  not transferred); or
* the subtask was **cancelled before it returned**, in which case the arguments
  were passed, but no values were returned. However, all borrowed handles lent
  during the call have been dropped.

Thus there are *three* terminal states for a subtask: returned,
cancelled-before-started and cancelled-before-returned. A subtask in one of
these terminal states is said to be **resolved**. A resolved subtask has always
dropped all the borrowed handles that it was lent during the call.

As with the rest of async, cancellation is *cooperative*, allowing the subtask
a chance to execute and clean up before it transitions to a resolved state (and
relinquishes its borrowed handles). Since there are valid use cases where
successful cancellation requires performing additional I/O using borrowed
handles and potentially blocking in the process, the Component Model does not
impose any limits on what a subtask can do after receiving a cancellation
request nor is there a non-cooperative option to force termination (instead,
this functionality would come as part of a future "[blast zone]" feature).
Thus, the `subtask.cancel` built-in can block and works just like an import
call in that it can be called synchronously or asynchronously.

On the callee side of cancellation: when a caller requests cancellation via
`subtask.cancel`, the callee receives a [`TASK_CANCELLED`] event (as produced
by one of the `waitable-set.{wait,poll}` or `yield` built-ins or as received by
the `callback` function). Upon receiving notice of cancellation, the callee can
call the [`task.cancel`] built-in to resolve the subtask without returning a
value. Alternatively, the callee can still call [`task.return`] as-if there
were no cancellation. `task.cancel` doesn't take a value to return but does
enforce the same [borrow](#borrows) rules as `task.return`. Ideally, a callee
will `task.cancel` itself as soon as possible after receiving a
`TASK_CANCELLED` event so that any caller waiting for the recovery of lent
handles is unblocked ASAP. As with `task.return`, after calling `task.cancel`,
a callee can continue executing before exiting the task.

See the [`canon_subtask_cancel`] and [`canon_task_cancel`] functions in the
Canonical ABI explainer for more details.

### Nondeterminism

Given the general goal of supporting concurrency, Component Model async
necessarily introduces a degree of nondeterminism. Async concurrency is however
[cooperative], meaning that nondeterministic behavior can only be observed at
well-defined points in the program. This contrasts with non-cooperative
[multithreading] in which nondeterminism can be observed at every core wasm
instruction.

One inherent source of potential nondeterminism that is independent of async is
the behavior of host-defined import and export calls. Async extends this
host-dependent nondeterminism to the behavior of the `read` and `write`
built-ins called on `stream`s and `future`s that have been passed to and from
the host via host-defined import and export calls. However, just as with import
and export calls, it is possible for a host to define a deterministic ordering
of `stream` and `future` `read` and `write` behavior such that overall
component execution is deterministic.

In addition to the inherent host-dependent nondeterminism, the Component Model
adds several internal sources of nondeterministic behavior that are described
next. However, each of these sources of nondeterminism can be removed by a host
implementing the WebAssembly [Determinsic Profile], maintaining the ability for
a host to provide spec-defined deterministic component execution for components
even when they use async.

The following sources of nondeterminism arise via internal built-in operations
defined by the Component Model:
* If there are multiple waitables with a pending event in a waitable set that
  is being waited on or polled, there is a nondeterministic choice of which
  waitable's event is delivered first.
* If multiple tasks wait on or poll the same waitable set at the same time,
  the distribution of events to tasks is nondeterministic.
* If multiple tasks that previously blocked are unblocked at the same time, the
  sequential order in which they are executed is nondeterministic.
* Whenever a task yields or waits on (or polls) a waitable set with an already
  pending event, whether the task "blocks" and transfers execution to its async
  caller is nondeterministic.
* If multiple tasks are waiting on [backpressure](#backpressure), and the
  backpressure is disabled, the order in which these pending tasks (and new
  tasks started while there are still pending tasks) start is nondeterministic.

Despite the above, the following scenarios do behave deterministically:
* If a component `a` asynchronously calls the export of another component `b`,
  control flow deterministically transfers to `b` and then back to `a` when
  `b` returns or blocks.
* If a component `a` asynchronously cancels a subtask in another component `b`,
  control flow deterministically transfers to `b` and then back to `a` when `b`
  resolves or blocks.
* If a component `a` asynchronously cancels a subtask in another component `b`
  that was blocked before starting due to backpressure, cancellation completes
  deterministically and immediately.
* When both ends of a stream or future are owned by wasm components, the
  behavior of all read, write, cancel and drop operations is deterministic
  (modulo any nondeterminitic execution that determines the ordering in which
  the operations are performed).


## Async ABI

At an ABI level, native async in the Component Model defines for every WIT
function an async-oriented core function signature that can be used instead of
or in addition to the existing (Preview-2-defined) synchronous core function
signature. This async-oriented core function signature is intended to be called
or implemented by generated bindings which then map the low-level core async
protocol to the languages' higher-level native concurrency features. Because
the WIT-level `async` attribute is purely a *hint* (as mentioned
[above](#sync-and-async-functions)), *every* WIT function has an async core
function signature; `async` just provides hints to the bindings generator for
which to use by default.

### Async Import ABI

Given these imported WIT functions (using the fixed-length-list feature 🔧):
```wit
world w {
  import foo: func(s: string) -> u32;
  import bar: func(s: string) -> string;
  import baz: func(t: list<u64; 5>) -> string;
  import quux: func(t: list<u32; 17>) -> string;
}
```
the default/synchronous lowered import function signatures are:
```wat
;; sync
(func $foo (param $s-ptr i32) (param $s-len i32) (result i32))
(func $bar (param $s-ptr i32) (param $s-len i32) (param $out-ptr i32))
(func $baz (param i64 i64 i64 i64 i64) (param $out-ptr i32))
(func $quux (param $in-ptr i32) (param $out-ptr i32))
```
Here: `foo`, `bar` and `baz` pass their parameters as "flattened" core value
types while `quux` passes its parameters via the `$in-ptr` linear memory
pointer (due to the Canonical ABI limitation of 16 maximum flattened
parameters). Similarly, `foo` returns its result as a single core value while
`bar`, `baz` and `quux` return their results via the `$out-ptr` linear memory
pointer (due to the current Canonical ABI limitation of 1 maximum flattened
result).

The corresponding asynchronous lowered import function signatures are:
```wat
;; async
(func $foo (param $s-ptr i32) (param $s-len i32) (param $out-ptr i32) (result i32))
(func $bar (param $s-ptr i32) (param $s-len i32) (param $out-ptr i32) (result i32))
(func $baz (param $in-ptr i32) (param $out-ptr i32) (result i32))
(func $quux (param $in-ptr i32) (param $out-ptr i32) (result i32))
```
Comparing signatures, the differences are:
* Async-lowered functions have a maximum of 4 flat parameters (not 16).
* Async-lowered functions always return their value via linear memory pointer.
* Async-lowered functions always have a single `i32` "status" code.

Additionally, *when* the parameter and result pointers are read/written depends
on the status code:
* If the low 4 bits of the status are `0`, the call didn't even start and so
  `$in-ptr` hasn't been read and `$out-ptr` hasn't been written and the high
  28 bits are the index of a new async subtask to wait on.
* If the low 4 bits of the status are `1`, the call started, `$in-ptr` was
  read, but `$out-ptr` hasn't been written and the high 28 bits are the index
  of a new async subtask to wait on.
* If the low 4 bits of the status are `2`, the call returned and so `$in-ptr`
  and `$out-ptr` have been read/written and the high 28 bits are `0` because
  there is no async subtask to wait on.

When a parameter/result pointer hasn't yet been read/written, the async caller
must take care to keep the region of memory allocated to the call until
receiving an event indicating that the async subtask has started/returned.

Other example asynchronous lowered signatures:

| WIT function type                         | Async ABI             |
| ----------------------------------------- | --------------------- |
| `func()`                                  | `(func (result i32))` |
| `func() -> string`                        | `(func (param $out-ptr i32) (result i32))` |
| `func(x: f32) -> f32`                     | `(func (param $x f32) (param $out-ptr i32) (result i32))` |
| `func(s: string, t: string)`              | `(func (param $s-ptr i32) (param $s-len i32) (result $t-ptr i32) (param $t-len i32) (result i32))` |

`future` and `stream` can appear anywhere in the parameter or result types. For example:
```wit
func(s1: stream<future<string>>, s2: list<stream<string>>) -> result<stream<string>, stream<error>>
```
In *both* the sync and async ABIs, a `future` or `stream` in the WIT-level type
translates to a single `i32` in the ABI.  This `i32` is an index into the
current component instance's table. For example, for the WIT function type:
```wit
func(f: future<string>) -> future<u32>
```
the synchronous ABI has signature:
```wat
(func (param $f i32) (result i32))
```
and the asynchronous ABI has the signature:
```wat
(func (param $f i32) (param $out-ptr i32) (result i32))
```
where `$f` is the index of a future (not a pointer to one) while while
`$out-ptr` is a pointer to a linear memory location that will receive an `i32`
index.

For the runtime semantics of this `i32` index, see `lift_stream`,
`lift_future`, `lower_stream` and `lower_future` in the [Canonical ABI
Explainer]. For a complete description of how async imports work, see
[`canon_lower`] in the Canonical ABI Explainer.


#### Async Export ABI

Given an exported WIT function:
```wit
world w {
  export foo: func(s: string) -> string;
}
```

The default sync export function signature for export `foo` is:
```wat
;; sync
(func (param $s-ptr i32) (param $s-len i32) (result $retp i32))
```
where (working around the continued lack of multi-return support throughout
the core wasm toolchain) `$retp` must be a 4-byte-aligned pointer into linear
memory from which the 8-byte (pointer, length) of the string result can be
loaded.

The async export ABI provides two flavors: stackful and stackless.

##### Stackful Async Exports

The stackful ABI is currently gated by the 🚟 feature.

The async stackful export function signature for export `foo` (defined above
in world `w`) is:
```wat
;; async, no callback
(func (param $s-ptr i32) (param $s-len i32))
```

The parameters work just like synchronous parameters.

There is no core function result because a callee [returns](#returning) their
value by *calling* the *imported* `task.return` function which has signature:
```wat
;; task.return
(func (param $ret-ptr i32) (param $ret-len i32))
```

The parameters of `task.return` work the same as if the WIT return type was the
WIT parameter type of a synchronous function. For example, if more than 16
core parameters would be needed, a single `i32` pointer into linear memory is
used.

##### Stackless Async Exports

The async stackless export function signature for export `foo` (defined above
in world `w`) is:
```wat
;; async, callback
(func (param $s-ptr i32) (param $s-len i32) (result i32))
```

The parameters also work just like synchronous parameters. The callee returns
their value by calling `task.return` just like the stackful case.

The `(result i32)` lets the core function return what it wants the runtime to do next:
* If the low 4 bits are `0`, the callee completed (and called `task.return`)
  without blocking.
* If the low 4 bits are `1`, the callee wants to yield, allowing other code
  to run, but resuming thereafter without waiting on anything else.
* If the low 4 bits are `2`, the callee wants to wait for an event to occur in
  the waitable set whose index is stored in the high 28 bits.
* If the low 4 bits are `3`, the callee wants to poll for any events that have
  occurred in the waitable set whose index is stored in the high 28 bits.

When an async stackless function is exported, a companion "callback" function
must also be exported with signature:
```wat
(func (param i32 i32 i32) (result i32))
```

The `(result i32)` has the same interpretation as the stackless export function
and the runtime will repeatedly call the callback until a value of `0` is
returned. The `i32` parameters describe what happened that caused the callback
to be called again.

For a complete description of how async exports work, see [`canon_lift`] in the
Canonical ABI Explainer.


## Examples

For a list of working examples expressed as executable WebAssembly Test (WAST)
files, see [this directory](../../test/async).

This rest of this section sketches the shape of a component that uses `async`
to lift and lower its imports and exports with both the stackful and stackless
ABI options.

### Stackful ABI example

Starting with the stackful ABI, the meat of this example component is replaced
with `...` to focus on the overall flow of function calls:
```wat
(component
  (import "fetch" (func $fetch (param "url" string) (result (list u8))))
  (core module $Libc
    (memory (export "mem") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) ...)
    ...
  )
  (core module $Main
    (import "" "mem" (memory 1))
    (import "" "realloc" (func (param i32 i32 i32 i32) (result i32)))
    (import "" "fetch" (func $fetch (param i32 i32 i32) (result i32)))
    (import "" "waitable-set.new" (func $new_waitable_set (result i32)))
    (import "" "waitable-set.wait" (func $wait (param i32 i32) (result i32)))
    (import "" "waitable.join" (func $join (param i32 i32)))
    (import "" "task.return" (func $task_return (param i32 i32)))
    (global $wsi (mut i32))
    (func $start
      (global.set $wsi (call $new_waitable_set))
    )
    (start $start)
    (func (export "summarize") (param i32 i32)
      ...
      loop
        ...
        call $fetch      ;; pass a string pointer, string length and pointer-to-list-of-bytes outparam
        ...              ;; ... and receive the index of a new async subtask
        global.get $wsi
        call $join       ;; ... and add it to the waitable set
        ...
      end
      loop               ;; loop as long as there are any subtasks
        ...
        global.get $wsi
        call $wait       ;; wait for a subtask in the waitable set to make progress
        ...
      end
      ...
      call $task_return  ;; return the string result (pointer,length)
      ...
    )
  )
  (core instance $libc (instantiate $Libc))
  (alias $libc "mem" (core memory $mem))
  (alias $libc "realloc" (core func $realloc))
  ;; requires 🚟 for the stackful abi
  (canon lower $fetch async (memory $mem) (realloc $realloc) (core func $fetch'))
  (canon waitable-set.new (core func $new))
  (canon waitable-set.wait async (memory $mem) (core func $wait))
  (canon waitable.join (core func $join))
  (canon task.return (result string) (memory $mem) (core func $task_return))
  (core instance $main (instantiate $Main (with "" (instance
    (export "mem" (memory $mem))
    (export "realloc" (func $realloc))
    (export "fetch" (func $fetch'))
    (export "waitable-set.new" (func $new))
    (export "waitable-set.wait" (func $wait))
    (export "waitable.join" (func $join))
    (export "task.return" (func $task_return))
  ))))
  (canon lift (core func $main "summarize")
    async (memory $mem) (realloc $realloc)
    (func $summarize (param "urls" (list string)) (result string)))
  (export "summarize" (func $summarize))
)
```
Because the imported `fetch` function is `canon lower`ed with `async`, its core
function type (shown in the first import of `$Main`) takes pointers to the
parameter and results (which are asynchronously read-from and written-to) and
returns the index of a new subtask. `summarize` calls `waitable-set.wait`
repeatedly until all `fetch` subtasks have finished, noting that
`waitable-set.wait` can return intermediate progress (as subtasks transition
from "starting" to "started" to "returned") which tell the surrounding core
wasm code that it can reclaim the memory passed arguments or use the results
that have now been written to the outparam memory.

Because the `summarize` function is `canon lift`ed with `async`, its core
function type has no results; results are passed out via `task.return`. It also
means that multiple `summarize` calls can be active at once: once the first
call to `waitable-set.wait` blocks, the runtime will suspend its callstack
(fiber) and start a new stack for the new call to `summarize`. Thus,
`summarize` must be careful to allocate a separate linear-memory stack in its
entry point and store it in context-local storage (via `context.set`) instead
of simply using a `global`, as in a synchronous function.

### Stackless ABI example

The stackful example can be re-written to use the `callback` immediate (thereby
avoiding the need for fibers) as follows.

Note that the internal structure of this component is almost the same as the
previous one (other than that `summarize` is now lifted from *two* core wasm
functions instead of one) and the public signature of this component is
the exact same.

Thus, the difference is just about whether the stack is cleared by the
core wasm code between events, not externally-visible behavior.

```wat
(component
  (import "fetch" (func $fetch (param "url" string) (result (list u8))))
  (core module $Libc
    (memory (export "mem") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) ...)
    ...
  )
  (core module $Main
    (import "libc" "mem" (memory 1))
    (import "libc" "realloc" (func (param i32 i32 i32 i32) (result i32)))
    (import "" "fetch" (func $fetch (param i32 i32 i32) (result i32)))
    (import "" "waitable-set.new" (func $new_waitable_set (result i32)))
    (import "" "waitable.join" (func $join (param i32 i32)))
    (import "" "task.return" (func $task_return (param i32 i32)))
    (global $wsi (mut i32))
    (func $start
      (global.set $wsi (call $new_waitable_set))
    )
    (start $start)
    (func (export "summarize") (param i32 i32) (result i32)
      ...
      loop
        ...
        call $fetch           ;; pass a string pointer, string length and pointer-to-list-of-bytes outparam
        ...                   ;; ... and receive the index of a new async subtask
        global.get $wsi
        call $join            ;; ... and add it to the waitable set
        ...
      end
      (i32.or                 ;; return (WAIT | ($wsi << 4))
        (i32.const 2)         ;; 2 -> WAIT
        (i32.shl
          (global.get $wsi)
          (i32.const 4)))
    )
    (func (export "cb") (param $event i32) (param $p1 i32) (param $p2 i32)
      ...
      if (result i32)         ;; if subtasks remain:
        (i32.or               ;; return (WAIT | ($wsi << 4))
          (i32.const 2)
          (i32.shl
            (global.get $wsi)
            (i32.const 4)))
      else                    ;; if no subtasks remain:
        ...
        call $task_return     ;; return the string result (pointer,length)
        ...
        i32.const 0           ;; return EXIT
      end
    )
  )
  (core instance $libc (instantiate $Libc))
  (alias $libc "mem" (core memory $mem))
  (alias $libc "realloc" (core func $realloc))
  (canon lower $fetch async (memory $mem) (realloc $realloc) (core func $fetch'))
  (canon waitable-set.new (core func $new))
  (canon waitable.join (core func $join))
  (canon task.return (result string) async (memory $mem) (realloc $realloc) (core func $task_return))
  (core instance $main (instantiate $Main (with "" (instance
    (export "mem" (memory $mem))
    (export "realloc" (func $realloc))
    (export "fetch" (func $fetch'))
    (export "waitable-set.new" (func $new))
    (export "waitable.join" (func $join))
    (export "task.return" (func $task_return))
  ))))
  (canon lift (core func $main "summarize")
    async (callback (core func $main "cb")) (memory $mem) (realloc $realloc)
    (func $summarize (param "urls" (list string)) (result string)))
  (export "summarize" (func $summarize))
)
```
For an explanation of the bitpacking of the `i32` callback return value,
see [`unpack_callback_result`] in the Canonical ABI explainer.

While this example spawns all the subtasks in the initial call to `summarize`,
subtasks can also be spawned from `cb` (even after the call to `task.return`).
It's also possible for `summarize` to call `task.return` called eagerly in the
initial core `summarize` call.

The `$event`, `$p1` and `$p2` parameters passed to `cb` are the same as the
return values from `task.wait` in the previous example. The precise meaning of
these values is defined by the Canonical ABI.


## Interaction with the start function

Since any component-level function with an empty signature can be used as a
[`start`] function, there's nothing to stop an `async`-lifted function from
being used as a `start` function. Async start functions are useful when
executing general-purpose code at initialization time, e.g.:
* If the top-level scripts of a scripting language are executed by the `start`
  function, asychrony arises from regular use of the language's concurrency
  features. For example, in JS, this takes the form of [top-level `await`].
* If C++ or other OOPLs global object constructors are executed by the `start`
  function, these can execute general-purpose code which may use concurrent
  I/O APIs.

Since component `start` functions are already defined to be executed
synchronously before the component is considered initialized and ready for its
exports to be called, the natural thing for `start` to do when calling an
`async`-lifted function is wait for the callee to reach the ["returned"
state](#returning). This gives `async` `start` functions a simple way to do
concurrent initialization and signal completion using the same language
bindings as regular `async` `export` functions.

However, as explained above, an async task can always continue executing after
reaching the "returned" state and thus an async task spawned by `start` may
continue executing even after the component instance is initialized and
receiving export calls. These post-return `start`-tasks can be used by the
language toolchain to implement traditional "background tasks" (e.g., the
`setInterval()` or `requestIdleCallback()` JavaScript APIs). From the
perspective of [structured concurrency], these background tasks are new task
tree roots (siblings to the roots created when component exports are
called by the host). Thus, subtasks and threads spawned by the background task
will have proper async callstacks as used to define reentrancy and support
debugging/profiling/tracing.

In future, when [runtime instantiation] is added to the Component Model, the
component-level function used to create a component instance could be lowered
with `async` to allow a parent component to instantiate child components
concurrently, relaxing the fully synchronous model of instantiation supported
by declarative instantiation and `start` above.


## Interaction with multi-threading

For now, the integration between multi-threading (via [`thread.spawn*`]) and
native async is limited. In particular, because all [lift and lower definitions]
produce non-`shared` functions, any threads spawned by a component via
`thread.spawn*` will not be able to directly call imports (synchronously *or*
asynchronously) and will thus have to use Core WebAssembly `atomics.*`
instructions to switch back to a non-`shared` function running on the "main"
thread (i.e., whichever thread was used to call the component's exports).

However, a future addition to this proposal (in the [TODO](#todo)s below) would
be to allow lifting and lowering with `async` + `shared`. What's exciting about
this approach is that a non-`shared` component-level function could be safely
lowered with `async shared`. In the case that the lifted function being lowered
was also `async shared`, the entire call could happen on the non-main thread
without a context switch. But if the lifting side was non-`shared`, then the
Component Model could automatically handle the synchronization of enqueuing a
call to the export (as in the backpressure case mentioned above), returning a
subtask for the async caller to wait on as usual. Thus, the sync+async
composition story described above could naturally be extended to a
sync+async+shared composition story, continuing to avoid the "what color is
your function" problem (where `shared` is the [color]).

Even without any use of [`thread.spawn*`], native async provides an opportunity
to achieve some automatic parallelism "for free". In particular, due to the
shared-nothing nature of components, each component instance could be given a
separate thread on which to interleave all tasks executing in that instance.
Thus, in a cross-component call from `C1` to `C2`, `C2`'s task can run in a
separate thread that is automatically synchronized with `C1` by the runtime.
This is analogous to how traditional OS processes can run in separate threads,
except that the component model is *allowing*, but not *requiring* the separate
threads. While it's unclear how much parallelism this would unlock in practice,
it does present interesting opportunities to experiment with optimizations over
time as applications are built with more components.


## TODO

Native async support is being proposed incrementally. The following features
will be added in future chunks roughly in the order listed to complete the full
"async" story, with a TBD cutoff between what's in [WASI Preview 3] and what
comes after:
* remove the temporary trap mentioned above that occurs when a `read` and
  `write` of a stream/future happen from within the same component instance
* zero-copy forwarding/splicing
* some way to say "no more elements are coming for a while"
* `recursive` function type attribute: allow a function to opt in to
  recursive [reentrance], extending the ABI to link the inner and
  outer activations
* add a `strict-callback` option that adds extra trapping conditions to
  provide the semantic guarantees needed for engines to statically avoid
  fiber creation at component-to-component `async` call boundaries
* add `stringstream` specialization of `stream<char>` (just like `string` is
  a specialization of `list<char>`)
* allow pipelining multiple `stream.read`/`write` calls
* allow chaining multiple async calls together ("promise pipelining")
* integrate with `shared`: define how to lift and lower functions `async` *and*
  `shared`


[Wasm I/O 2024 presentation]: https://www.youtube.com/watch?v=y3x4-nQeXxc
[Color]: https://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/

[Fibers]: https://en.wikipedia.org/wiki/Fiber_(computer_science)
[CPS Transform]: https://en.wikipedia.org/wiki/Continuation-passing_style
[Event Loop]: https://en.wikipedia.org/wiki/Event_loop
[Structured Concurrency]: https://en.wikipedia.org/wiki/Structured_concurrency
[Session Types]: https://en.wikipedia.org/wiki/Session_type
[Unit]: https://en.wikipedia.org/wiki/Unit_type
[Thread-local Storage]: https://en.wikipedia.org/wiki/Thread-local_storage
[FS or GS Segment Base Address]: https://docs.kernel.org/arch/x86/x86_64/fsgs.html
[Cooperative]: https://en.wikipedia.org/wiki/Cooperative_multitasking
[Multithreading]: https://en.wikipedia.org/wiki/Multithreading_(computer_architecture)

[AST Explainer]: Explainer.md
[Lift and Lower Definitions]: Explainer.md#canonical-definitions
[Lifted]: Explainer.md#canonical-definitions
[Canonical Built-in]: Explainer.md#canonical-built-ins
[`context.get`]: Explainer.md#-contextget
[`context.set`]: Explainer.md#-contextset
[`backpressure.set`]: Explainer.md#-backpressureset
[`task.return`]: Explainer.md#-taskreturn
[`task.cancel`]: Explainer.md#-taskcancel
[`subtask.cancel`]: Explainer.md#-subtaskcancel
[`yield`]: Explainer.md#-yield
[`waitable-set.wait`]: Explainer.md#-waitable-setwait
[`waitable-set.poll`]: Explainer.md#-waitable-setpoll
[`thread.spawn*`]: Explainer.md#-threadspawn_ref
[`{stream,future}.new`]: Explainer.md#-streamnew-and-futurenew
[`{stream,future}.{read,write}`]: Explainer.md#-streamread-and-streamwrite
[ESM-integration]: Explainer.md#ESM-integration

[Canonical ABI Explainer]: CanonicalABI.md
[ABI Options]: CanonicalABI.md#canonical-abi-options
[`canon_lift`]: CanonicalABI.md#canon-lift
[`unpack_callback_result`]: CanonicalABI.md#canon-lift
[`canon_lower`]: CanonicalABI.md#canon-lower
[`canon_context_get`]: CanonicalABI.md#-canon-contextget
[`canon_backpressure_set`]: CanonicalABI.md#-canon-backpressureset
[`canon_waitable_set_wait`]: CanonicalABI.md#-canon-waitable-setwait
[`canon_task_return`]: CanonicalABI.md#-canon-taskreturn
[`canon_task_cancel`]: CanonicalABI.md#-canon-taskcancel
[`canon_subtask_cancel`]: CanonicalABI.md#-canon-subtaskcancel
[`Task`]: CanonicalABI.md#task-state
[`Task.enter`]: CanonicalABI.md#task-state
[`Task.wait_for_event`]: CanonicalABI.md#task-state
[`Waitable`]: CanonicalABI.md#waitable-state
[`TASK_CANCELLED`]: CanonicalABI.md#waitable-state
[`Task`]: CanonicalABI.md#task-state
[`Subtask`]: CanonicalABI.md#subtask-state
[Stream State]: CanonicalABI.md#stream-state
[Future State]: CanonicalABI.md#future-state

[Binary Format]: Binary.md
[WIT]: WIT.md
[Goals]: ../high-level/Goals.md
[Use Cases]: ../high-level/UseCases.md
[Blast Zone]: FutureFeatures.md#blast-zones
[Reentrance]: Explainer.md#component-invariants
[`start`]: Explainer.md#start-definitions

[Store]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-store
[Deterministic Profile]: https://webassembly.github.io/spec/versions/core/WebAssembly-3.0-draft.pdf#subsubsection*.798

[stack-switching]: https://github.com/WebAssembly/stack-switching/
[JSPI]: https://github.com/WebAssembly/js-promise-integration/
[shared-everything-threads]: https://github.com/webAssembly/shared-everything-threads
[memory64]: https://github.com/webAssembly/memory64
[wasm-gc]: https://github.com/WebAssembly/gc/blob/main/proposals/gc/MVP.md

[WASI Preview 3]: https://github.com/WebAssembly/WASI/tree/main/wasip2#looking-forward-to-preview-3
[`wasi:http/handler.handle`]: https://github.com/WebAssembly/wasi-http/blob/main/wit-0.3.0-draft/handler.wit
[Runtime Instantiation]: https://github.com/WebAssembly/component-model/issues/423

[Top-level `await`]: https://github.com/tc39/proposal-top-level-await
