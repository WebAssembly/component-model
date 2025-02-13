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
  * [Subtask and Supertask](#subtask-and-supertask)
  * [Structured concurrency](#structured-concurrency)
  * [Streams and Futures](#streams-and-futures)
  * [Waiting](#waiting)
  * [Backpressure](#backpressure)
  * [Returning](#returning)
* [Examples](#examples)
* [Interaction with multi-threading](#interaction-with-multi-threading)
* [Interaction with the start function](#interaction-with-the-start-function)
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


## High-level Approach

Based on the above goals, the Component Model's approach to native async starts
by allowing components to import and export "async" functions which abstract
over, and can be implemented by, idiomatic concurrency in a variety of
programming languages:
* `async` functions in languages like C#, JS, Python, Rust and Swift
  (implemented using [`callback` functions](#waiting))
* stackful coroutines in languages like Kotlin, Perl, PHP and (recently) C++
* green threads as-if running on a single OS thread in languages like Go and
  (initially and recently again) Java
* callbacks, in languages with no explicit async support
  (also implemented using [`callback` functions](#waiting))

The Component Model supports this wide variety of language features by
specifying a common low-level "async" ABI which the different languages'
compilers and runtimes can bind their different language-level concurrency
features to. This is similar to how a native OS exposes APIs for concurrency
(such as `epoll`, `io_uring`, `kqueue` or Overlapped I/O) to which most of
these languages' concurrency features are already bound (making the Component
Model "just another OS" from the language toolchains' perspective).

Moreover, this async ABI does not require components to use preemptive
multi-threading ([`thread.spawn`]) in order to achieve concurrency. Instead,
concurrency can be achieved by cooperatively switching between different
logical tasks running on a single thread. This switching may require the use of
[fibers] or a [CPS transform], but may also be avoided entirely when a
component's producer toolchain is engineered to always return to an
[event loop].

To avoid partitioning the world along sync/async lines as mentioned in the
Goals section, the Component Model allows *every* component-level function type
to be both implemented and called in either a synchronous or asynchronous
manner. Thus, function types do not dictate synchrony or asynchrony and all 4
combinations of {sync, async} x {caller, callee} are supported and given a
well-defined behavior. Specifically, the caller and callee can independently
specify `async` as an immediate flags on the [lift and lower definitions] used
to define their imports and exports.

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

In addition to being able to define and call whole functions asynchronously,
the `stream` and `future` types can be used in function signatures to pass
parameters and results incrementally over time, achieving finer-grained
concurrency. Streams and futures are thus not defined to be free-standing
resources with their own internal memory buffers (like a traditional channel or
pipe) but, rather, more-primitive control-flow mechanisms that synchronize the
incremental passing of parameters and results during cross-component calls.
Higher-level resources like channels and pipes could then be defined in terms
of these lower-level `stream` and `future` primitives, e.g.:

```wit
resource pipe {
    constructor(buffer-size: u32);
    write: func(bytes: stream<u8>) -> result;
    read: func() -> stream<u8>;
}
```

but also many other domain-specific concurrent resources like WASI HTTP request
and response bodies or WASI blobs. Streams and futures are however high-level
enough to be bound automatically to many source languages' built-in concurrency
features like futures, promises, streams, generators and iterators, unlike
lower-level concurrency primitives (like callbacks or `wasi:io@0.2.0`
`pollable`s). Thus, the Component Model seeks to provide the lowest-level
fine-grained concurrency primitives that are high-level and idiomatic enough to
enable automatic generation of usable language-integrated bindings.


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
*called*.

### Task

Every time a lifted function is called (e.g., when a component's export is
called by the outside world), a new **task** is created that logically contains
all the transitive control-flow state of the export call and will be destroyed
when the export call finishes. When all of a component's exports are lifted
synchronously, there will be at most one task alive at any one time. However,
when a component exports asynchronously-lifted functions, there can be multiple
tasks alive at once.

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
the `async def` Python functions transitively called by `canon_lift`. Thus,
although there can be multiple live `Task` objects in a component instance,
"the current one" is always clear: it's the one passed to the current function
as a parameter.

### Context-Local Storage

Each task contains a distinct mutable **context-local storage** array. The
current task's context-local storage can be read and written from core wasm
code by calling the [`context.get`] and [`context.set`] built-ins.

The context-local storage array's length is currently fixed to contain exactly
2 `i32`s with the goal of allowing this array to be stored inline in whatever
existing runtime data structure is already efficiently reachable from ambient
compiled wasm code. Because module instantiation is declarative in the
Component Model, the imported `context.{get,set}` built-ins can be inlined by
the core wasm compiler as-if they were instructions, allowing the generated
machine code to be a single load or store. This makes context-local storage a
good place to store the linear-memory shadow stack pointer as well as the
pointer to the struct used to implement [thread-local storage] APIs used by
guest code.

When [memory64] is integrated into the Component Model's Canonical ABI,
`context.{get,set}` will be backwards-compatibly relaxed to allow `i64`
pointers (overlaying the `i32` values like hardware 32/64-bit registers). When
[wasm-gc] is integrated, these integral context values can serve as indices
into guest-managed tables of typed GC references.

When [threads are added](#interaction-with-multi-threading), each thread will
also get its own distinct mutable context-local storage array. This is the
reason why "context-local" storage is not called "task-local" storage (where a
"context" is a finer-grained unit of execution than either a "task" or a
"thread").

For details, see [`context.get`] in the AST explainer and [`canon_context_get`]
in the Canonical ABI explainer.

### Subtask and Supertask

Each component-to-component call necessarily creates a new task in the callee.
The callee task is a **subtask** of the calling task (and, conversely, the
calling task is a **supertask** of the callee task. This sub/super relationship
is immutable and doesn't change over time (until the callee task completes and
is destroyed).

The Canonical ABI's Python code represents the subtask relationship between a
caller `Task` and a callee `Task` via the Python [`Subtask`] class. Whereas a
`Task` object is created by each call to [`canon_lift`], a `Subtask` object is
created by each call to [`canon_lower`]. This allows `Subtask`s to store the
state that enforces the caller side of the Canonical ABI rules.

### Structured concurrency

To realize the above goals of always having a well-defined cross-component
async callstack, the Component Model's Canonical ABI enforces [Structured
Concurrency] by dynamically requiring that a task waits for all its subtasks to
[return](#returning) before the task itself is allowed to finish. This means
that a subtask cannot be orphaned and there will always be an async callstack
rooted at an invocation of an export by the host. Moreover, at any one point in
time, the set of tasks active in a linked component graph form a forest of
async call trees which e.g., can be visualized using a traditional flamegraph.

The Canonical ABI's Python code enforces Structured Concurrency by incrementing
a per-task "`num_subtasks`" counter when a subtask is created, decrementing
when the subtask [returns](#returning), and trapping if `num_subtasks > 0` when
a task attempts to exit.

There is a subtle nuance to these Structured Concurrency rules deriving from
the fact that subtasks may continue execution after [returning](#returning)
their value to their caller. The ability to execute after returning value is
necessary for being able to do work off the caller's critical path. A concrete
example is an HTTP service that does some logging or billing operations after
finishing an HTTP response, where the HTTP response is the return value of the
[`wasi:http/handler.handle`] function. Since the `num_subtasks` counter is
decremented when a subtask *returns* (as opposed to *exits*), this means that
subtasks may continue execution even once their supertask has exited. To
maintain Structured Concurrency (for purposes of checking [reentrance],
scheduler prioritization and debugging/observability), we can consider
the supertask to still be alive but in the process of "asynchronously
tail-calling" its still-executing subtasks. (For scenarios where one
component wants to non-cooperatively bound the execution of another
component, a separate "[blast zone]" feature is necessary in any
case.)

This async call tree provided by Structured Concurrency interacts naturally
with the `borrow` handle type and its associated dynamic rules for preventing
use-after-free. When a caller initially lends an `own`ed or `borrow`ed handle
to a callee, a "`num_lends`" counter on the lent handle is incremented when the
subtask starts and decremented when the caller is notified that the subtask has
[returned](#returning). If the caller tries to drop a handle while the handle's
`num_lends` is greater than zero, it traps. Symmetrically, each `borrow` handle
passed to a callee task increments a "`num_borrows`" counter on the task that
is decremented when the `borrow` handle is dropped. With async calls, there can
of course be multiple overlapping async tasks and thus `borrow` handles must
remember which particular task's `num_borrows` counter to drop. If a task
attempts to return (which, for `async` tasks, means calling `task.return`) when
its `num_borrows` is greater than zero, it traps. These interlocking rules for
the `num_lends` and `num_borrows` fields inductively ensure that nested async
call trees that transitively propagate `borrow`ed handles maintain the
essential invariant that dropping an `own`ed handle never destroys a resource
while there is any `borrow` handle anywhere pointing to that resource.

### Streams and Futures

Streams and Futures have two "ends": a *readable end* and *writable end*. When
*consuming* a `stream` or `future` value as a parameter (of an export call with
a `stream` or `future` somewhere in the parameter types) or result (of an
import call with a `stream` or `future` somewhere in the result type), the
receiver always gets *unique ownership* of the *readable end* of the `stream`
or `future`. When *producing* a `stream` or `future` value as a parameter (of
an import call) or result (of an export call), the producer can either
*transfer ownership* of a readable end it has already received or it can create
a fresh writable end (via `stream.new` or `future.new`) and then lift this
writable end to create a fresh readable end in the consumer while maintaining
ownership of the writable end in the producer. To maintain the invariant that
readable ends are unique, a writable end can be lifted at most once, trapping
otherwise.

Based on this, `stream<T>` and `future<T>` values can be passed between
functions as if they were synchronous `list<T>` and `T` values, resp. For
example, given `f` and `g` with types:
```wit
f: func(x: whatever) -> stream<T>;
g: func(s: stream<T>) -> stuff;
```
`g(f(x))` works as you might hope, concurrently streaming `x` into `f` which
concurrently streams its results into `g`. If `f` has an error, it can close
its returned `stream<T>` with an [`error-context`](Explainer.md#error-context-type)
value which `g` will receive along with the notification that its readable
stream was closed.

If a component instance *would* receive the readable end of a stream for which
it already owns the writable end, the readable end disappears and the existing
writable end is received instead (since the guest can now handle the whole
stream more efficiently wholly from within guest code). E.g., if the same
component instance defined `f` and `g` above, the composition `g(f(x))` would
just instruct the guest to stream directly from `f` into `g` without crossing a
component boundary or performing any extra copies. Thus, strengthening the
previously-mentioned invariant, the readable and writable ends of a stream are
unique *and never in the same component*.

Given the readable or writable end of a stream, core wasm code can call the
imported `stream.read` or `stream.write` canonical built-ins, resp., passing the
pointer and length of a linear-memory buffer to write-into or read-from, resp.
These built-ins can either return immediately if >0 elements were able to be
written or read immediately (without blocking) or return a sentinel "blocked"
value indicating that the read or write will execute concurrently. The readable
and writable ends of streams and futures can then be [waited](#waiting) on to
make progress.

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

From a [structured-concurrency](#structured-concurrency) perspective, the
readable and writable ends of streams and futures are leaves of the async call
tree. Unlike subtasks, the parent of the readable ends of streams and future
*can* change over time (when transferred via function call, as mentioned
above). However, there is always *some* parent `Task` and this parent `Task`
is prevented from orphaning its children using the same reference-counting
guard mentioned above for subtasks.

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

While the two approaches have significant runtime implementation differences
(the former requires [fibers] or a [CPS transform] while the latter only
requires storing fixed-size context-local storage and [`Task`] state),
semantically they do the same thing which, in the Canonical ABI Python code, is
factored out into the [`Task.wait`] method. Thus, the difference between
`callback` and non-`callback` is one of optimization, not expressivity.

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

Once task enables backpressure, it can [wait](#waiting) for existing tasks to
finish and release their associated resources. Thus, a task can choose to
[wait](#waiting) with or without backpressure enabled, depending on whether it
wants to accept new accept new export calls while waiting or not.

See the [`canon_backpressure_set`] function and [`Task.enter`] method in the
Canonical ABI explainer for the setting and implementation of backpressure.

Once a task is allowed to start according to these backpressure rules, its
arguments are lowered into the callee's linear memory and the task is in
the "started" state.

### Returning

The way an async function returns its value is by calling [`task.return`],
passing the core values that are to be lifted as *parameters*. Additionally,
when the `always-task-return` `canonopt` is set, synchronous functions also
return their values by calling `task.return` (as a more expressive and
general alternative to `post-return`).

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

A task may not call `task.return` unless it is in the "started" state. Once
`task.return` is called, the task is in the "returned" state. A task can only
finish once it is in the "returned" state. See the [`canon_task_return`]
function in the Canonical ABI explainer for more details.


## Examples

With that background, we can sketch the shape of an async component that lifts
and lowers its imports and exports with `async`. The meat of this component is
replaced with `...` to focus on the overall flow of function calls.
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
    (import "" "fetch" (func $fetch (param i32 i32) (result i32)))
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
        call $fetch      ;; pass a pointer-to-string and pointer-to-list-of-bytes outparam
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
  (canon lower $fetch async (memory $mem) (realloc $realloc) (core func $fetch'))
  (canon waitable-set.new (core func $new))
  (canon waitable-set.wait async (memory $mem) (core func $wait))
  (canon waitable.join (core func $join))
  (canon task.return (result string) async (memory $mem) (realloc $realloc) (core func $task_return))
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

This same example can be re-written to use the `callback` immediate (thereby
avoiding the need for fibers) as follows. Note that the internal structure of
this component is almost the same as the previous one (other than that
`summarize` is now lifted from *two* core wasm functions instead of one) and
the public signature of this component is the exact same. Thus, the difference
is just about whether the stack is cleared by the core wasm code between events,
not externally-visible behavior.
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
    (import "" "fetch" (func $fetch (param i32 i32) (result i32)))
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
        call $fetch           ;; pass a pointer-to-string and pointer-to-list-of-bytes outparam
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
        i32.const 2           ;; return WAIT
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


## Interaction with multi-threading

For now, the integration between multi-threading (via [`thread.spawn`]) and
native async is limited. In particular, because all [lift and lower
definitions] produce non-`shared` functions, any threads spawned by a component
via `thread.spawn` will not be able to directly call imports (synchronously
*or* asynchronously) and will thus have to use Core WebAssembly `atomics.*`
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

Even without any use of `thread.new`, native async provides an opportunity to
achieve some automatic parallelism "for free". In particular, due to the
shared-nothing nature of components, each component instance could be given a
separate thread on which to interleave all tasks executing in that instance.
Thus, in a cross-component call from `C1` to `C2`, `C2`'s task can run in a
separate thread that is automatically synchronized with `C1` by the runtime.
This is analogous to how traditional OS processes can run in separate threads,
except that the component model is *allowing*, but not *requiring* the separate
threads. While it's unclear how much parallelism this would unlock in practice,
it does present interesting opportunities to experiment with optimizations over
time as applications are built with more components.


## Interaction with the start function

Since component-level start functions can be any component-level function (with
type `[] -> []`), async functions can be start functions. This raises some
interesting questions concerning how much concurrency during instantiation (of
a whole component DAG) is allowed and how parent components can control this.
For now, this remains a [TODO](#todo) and validation will reject `async`-lifted
`start` functions.


## TODO

Native async support is being proposed incrementally. The following features
will be added in future chunks roughly in the order list to complete the full
"async" story, with a TBD cutoff between what's in [WASI Preview 3] and what
comes after:
* `nonblocking` function type attribute: allow a function to declare in its
  type that it will not transitively do anything blocking
* define what `async` means for `start` functions (top-level await + background
  tasks), along with cross-task coordination built-ins
* `subtask.cancel`: allow a supertask to signal to a subtask that its result is
  no longer wanted and to please wrap it up promptly
* zero-copy forwarding/splicing
* some way to say "no more elements are coming for a while"
* `recursive` function type attribute: allow a function to opt in to
  recursive [reentrance], extending the ABI to link the inner and
  outer activations
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
[Unit]: https://en.wikipedia.org/wiki/Unit_type
[Thread-local Storage]: https://en.wikipedia.org/wiki/Thread-local_storage

[AST Explainer]: Explainer.md
[Lift and Lower Definitions]: Explainer.md#canonical-definitions
[Lifted]: Explainer.md#canonical-definitions
[Canonical Built-in]: Explainer.md#canonical-built-ins
[`context.get`]: Explainer.md#-contextget
[`context.set`]: Explainer.md#-contextset
[`backpressure.set`]: Explainer.md#-backpressureset
[`task.return`]: Explainer.md#-taskreturn
[`yield`]: Explainer.md#-yield
[`waitable-set.wait`]: Explainer.md#-waitable-setwait
[`waitable-set.poll`]: Explainer.md#-waitable-setpoll
[`thread.spawn`]: Explainer.md#-threadspawn
[ESM-integration]: Explainer.md#ESM-integration

[Canonical ABI Explainer]: CanonicalABI.md
[`canon_lift`]: CanonicalABI.md#canon-lift
[`unpack_callback_result`]: CanonicalABI.md#canon-lift
[`canon_lower`]: CanonicalABI.md#canon-lower
[`canon_context_get`]: CanonicalABI.md#-canon-contextget
[`canon_backpressure_set`]: CanonicalABI.md#-canon-backpressureset
[`canon_waitable_set_wait`]: CanonicalABI.md#-canon-waitable-setwait
[`canon_task_return`]: CanonicalABI.md#-canon-taskreturn
[`Task`]: CanonicalABI.md#task-state
[`Task.enter`]: CanonicalABI.md#task-state
[`Task.wait`]: CanonicalABI.md#task-state
[`Waitable`]: CanonicalABI.md#waitable-state
[`Subtask`]: CanonicalABI.md#subtask-state
[Stream State]: CanonicalABI.md#stream-state
[Future State]: CanonicalABI.md#future-state

[Binary Format]: Binary.md
[WIT]: WIT.md
[Goals]: ../high-level/Goals.md
[Use Cases]: ../high-level/UseCases.md
[Blast Zone]: FutureFeatures.md#blast-zones
[Reentrance]: Explainer.md#component-invariants

[stack-switching]: https://github.com/WebAssembly/stack-switching/
[JSPI]: https://github.com/WebAssembly/js-promise-integration/
[shared-everything-threads]: https://github.com/webAssembly/shared-everything-threads
[memory64]: https://github.com/webAssembly/memory64
[wasm-gc]: https://github.com/WebAssembly/gc/blob/main/proposals/gc/MVP.md

[WASI Preview 3]: https://github.com/WebAssembly/WASI/tree/main/wasip2#looking-forward-to-preview-3
[`wasi:http/handler.handle`]: https://github.com/WebAssembly/wasi-http/blob/main/wit-0.3.0-draft/handler.wit
