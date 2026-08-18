;; This test tests that thread.{suspend,yield}-then-{resume,promote} and
;; thread.suspend never report pending cancellation early: they always perform
;; their operation and only deliver pending cancellation (if 'cancellable' was
;; set) after that, right before returning.
(component
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Table (table (export "tbl") 3 funcref))
    (core instance $table (instantiate $Table))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "tbl" (table $tbl 3 funcref))
      (import "" "task.cancel" (func $task.cancel))
      (import "" "future.read" (func $future.read (param i32 i32) (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "thread.index" (func $thread.index (result i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.resume-later" (func $thread.resume-later (param i32)))
      (import "" "thread.suspend-cancellable" (func $thread.suspend-cancellable (result i32)))
      (import "" "thread.suspend-then-resume-cancellable" (func $thread.suspend-then-resume-cancellable (param i32) (result i32)))
      (import "" "thread.yield-then-resume-cancellable" (func $thread.yield-then-resume-cancellable (param i32) (result i32)))
      (import "" "thread.suspend-then-promote-cancellable" (func $thread.suspend-then-promote-cancellable (param i32) (result i32)))
      (import "" "thread.yield-then-promote-cancellable" (func $thread.yield-then-promote-cancellable (param i32) (result i32)))

      (global $main-thread (mut i32) (i32.const 0))
      (global $helper-ran (mut i32) (i32.const 0))

      ;; table 0: switched/resumed to while the main thread is suspended, so it
      ;; must also hand control back via thread.resume-later
      (func $resumes-main (param i32)
        (global.set $helper-ran (i32.const 1))
        (call $thread.resume-later (global.get $main-thread)))
      ;; table 1: switched to while the main thread is merely yielding, which
      ;; leaves it ready, so it must not be resumed again
      (func $plain (param i32)
        (global.set $helper-ran (i32.const 1)))
      ;; table 2: never made ready, used as a not-ready promote target
      (func $idle (param i32))
      (elem (table $tbl) (i32.const 0) func $resumes-main $plain $idle)

      ;; Block non-cancellably until $D writes the future. $D requests
      ;; cancellation while we are parked here; because this wait is not
      ;; cancellable there is no candidate thread, so the request can only be
      ;; recorded as pending.
      (func $block-until-pending (param $futr i32)
        (local $ret i32) (local $ws i32) (local $ec i32)
        (global.set $main-thread (call $thread.index))
        (global.set $helper-ran (i32.const 0))
        (local.set $ws (call $waitable-set.new))
        (local.set $ret (call $future.read (local.get $futr) (i32.const 0)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        (call $waitable.join (local.get $futr) (local.get $ws))
        (local.set $ec (call $waitable-set.wait (local.get $ws) (i32.const 0)))
        (if (i32.ne (i32.const 4 (; FUTURE_READ ;)) (local.get $ec))
          (then unreachable))
      )

      ;; The built-in must report the cancellation, and must have performed its
      ;; suspend/switch first -- otherwise the helper thread never ran.
      (func $check (param $ret i32)
        (if (i32.ne (i32.const 1 (; CANCELLED ;)) (local.get $ret))
          (then unreachable))
        (if (i32.eqz (global.get $helper-ran))
          (then unreachable))
      )

      (func (export "suspend") (param $futr i32) (result i32)
        (call $block-until-pending (local.get $futr))
        (call $thread.resume-later (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $check (call $thread.suspend-cancellable))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      (func (export "suspend-then-resume") (param $futr i32) (result i32)
        (call $block-until-pending (local.get $futr))
        (call $check (call $thread.suspend-then-resume-cancellable
          (call $thread.new-indirect (i32.const 0) (i32.const 0))))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      (func (export "yield-then-resume") (param $futr i32) (result i32)
        (call $block-until-pending (local.get $futr))
        (call $check (call $thread.yield-then-resume-cancellable
          (call $thread.new-indirect (i32.const 1) (i32.const 0))))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      (func (export "suspend-then-promote-ready") (param $futr i32) (result i32)
        (local $other i32)
        (call $block-until-pending (local.get $futr))
        (local.set $other (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $thread.resume-later (local.get $other))
        (call $check (call $thread.suspend-then-promote-cancellable (local.get $other)))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      (func (export "yield-then-promote-ready") (param $futr i32) (result i32)
        (local $other i32)
        (call $block-until-pending (local.get $futr))
        (local.set $other (call $thread.new-indirect (i32.const 1) (i32.const 0)))
        (call $thread.resume-later (local.get $other))
        (call $check (call $thread.yield-then-promote-cancellable (local.get $other)))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      (func (export "suspend-then-promote-not-ready") (param $futr i32) (result i32)
        (local $idle i32)
        (call $block-until-pending (local.get $futr))
        (local.set $idle (call $thread.new-indirect (i32.const 2) (i32.const 0)))
        (call $thread.resume-later (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (call $check (call $thread.suspend-then-promote-cancellable (local.get $idle)))
        (call $thread.resume-later (local.get $idle))
        (call $task.cancel)
        (i32.const 0 (; EXIT ;))
      )

      ;; callback that should never be called
      (func (export "unreachable-cb") (param i32 i32 i32) (result i32)
        unreachable
      )
    )
    (type $FT (future))
    (alias core export $table "tbl" (core table $tbl))
    (core type $start-func-ty (func (param i32)))
    (canon task.cancel (core func $task.cancel))
    (canon future.read $FT async (memory (core memory $memory "mem")) (core func $future.read))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon thread.index (core func $thread.index))
    (core func $thread.new-indirect (canon thread.new-indirect $start-func-ty (core table $tbl)))
    (canon thread.resume-later (core func $thread.resume-later))
    (canon thread.suspend cancellable (core func $thread.suspend-cancellable))
    (canon thread.suspend-then-resume cancellable (core func $thread.suspend-then-resume-cancellable))
    (canon thread.yield-then-resume cancellable (core func $thread.yield-then-resume-cancellable))
    (canon thread.suspend-then-promote cancellable (core func $thread.suspend-then-promote-cancellable))
    (canon thread.yield-then-promote cancellable (core func $thread.yield-then-promote-cancellable))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "tbl" (table $tbl))
      (export "task.cancel" (func $task.cancel))
      (export "future.read" (func $future.read))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "thread.index" (func $thread.index))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.resume-later" (func $thread.resume-later))
      (export "thread.suspend-cancellable" (func $thread.suspend-cancellable))
      (export "thread.suspend-then-resume-cancellable" (func $thread.suspend-then-resume-cancellable))
      (export "thread.yield-then-resume-cancellable" (func $thread.yield-then-resume-cancellable))
      (export "thread.suspend-then-promote-cancellable" (func $thread.suspend-then-promote-cancellable))
      (export "thread.yield-then-promote-cancellable" (func $thread.yield-then-promote-cancellable))
    ))))
    (func (export "suspend") async (param "fut" $FT) (result u32) (canon lift
      (core func $cm "suspend")
      async (callback (core func $cm "unreachable-cb"))
    ))
    (func (export "suspend-then-resume") async (param "fut" $FT) (result u32) (canon lift
      (core func $cm "suspend-then-resume")
      async (callback (core func $cm "unreachable-cb"))
    ))
    (func (export "yield-then-resume") async (param "fut" $FT) (result u32) (canon lift
      (core func $cm "yield-then-resume")
      async (callback (core func $cm "unreachable-cb"))
    ))
    (func (export "suspend-then-promote-ready") async (param "fut" $FT) (result u32) (canon lift
      (core func $cm "suspend-then-promote-ready")
      async (callback (core func $cm "unreachable-cb"))
    ))
    (func (export "yield-then-promote-ready") async (param "fut" $FT) (result u32) (canon lift
      (core func $cm "yield-then-promote-ready")
      async (callback (core func $cm "unreachable-cb"))
    ))
    (func (export "suspend-then-promote-not-ready") async (param "fut" $FT) (result u32) (canon lift
      (core func $cm "suspend-then-promote-not-ready")
      async (callback (core func $cm "unreachable-cb"))
    ))
  )

  (component $D
    (type $FT (future))
    (import "suspend" (func $suspend async (param "fut" $FT) (result u32)))
    (import "suspend-then-resume" (func $suspend-then-resume async (param "fut" $FT) (result u32)))
    (import "yield-then-resume" (func $yield-then-resume async (param "fut" $FT) (result u32)))
    (import "suspend-then-promote-ready" (func $suspend-then-promote-ready async (param "fut" $FT) (result u32)))
    (import "yield-then-promote-ready" (func $yield-then-promote-ready async (param "fut" $FT) (result u32)))
    (import "suspend-then-promote-not-ready" (func $suspend-then-promote-not-ready async (param "fut" $FT) (result u32)))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $DM
      (import "" "mem" (memory 1))
      (import "" "subtask.cancel" (func $subtask.cancel (param i32) (result i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "future.new" (func $future.new (result i64)))
      (import "" "future.write" (func $future.write (param i32 i32) (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "suspend" (func $suspend (param i32 i32) (result i32)))
      (import "" "suspend-then-resume" (func $suspend-then-resume (param i32 i32) (result i32)))
      (import "" "yield-then-resume" (func $yield-then-resume (param i32 i32) (result i32)))
      (import "" "suspend-then-promote-ready" (func $suspend-then-promote-ready (param i32 i32) (result i32)))
      (import "" "yield-then-promote-ready" (func $yield-then-promote-ready (param i32 i32) (result i32)))
      (import "" "suspend-then-promote-not-ready" (func $suspend-then-promote-not-ready (param i32 i32) (result i32)))

      (global $futr (mut i32) (i32.const 0))
      (global $futw (mut i32) (i32.const 0))

      (func $new-future
        (local $ret64 i64)
        (local.set $ret64 (call $future.new))
        (global.set $futr (i32.wrap_i64 (local.get $ret64)))
        (global.set $futw (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
      )

      (func $started (param $ret i32) (result i32)
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (i32.shr_u (local.get $ret) (i32.const 4))
      )

      ;; The callee is parked in a non-cancellable wait, so cancellation must
      ;; block; unblock it and require that it ends up cancelled, which it can
      ;; only do by delivering the now-pending cancellation through the
      ;; cancellable built-in it runs next.
      (func $finish (param $subtask i32)
        (local $ret i32) (local $ws i32) (local $ec i32)
        (local.set $ret (call $subtask.cancel (local.get $subtask)))
        (if (i32.ne (i32.const -1 (; BLOCKED ;)) (local.get $ret))
          (then unreachable))
        (local.set $ret (call $future.write (global.get $futw) (i32.const 0)))
        (if (i32.ne (i32.const 0 (; COMPLETED ;)) (local.get $ret))
          (then unreachable))
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $subtask) (local.get $ws))
        (local.set $ec (call $waitable-set.wait (local.get $ws) (i32.const 8)))
        (if (i32.ne (i32.const 1 (; SUBTASK ;)) (local.get $ec))
          (then unreachable))
        (if (i32.ne (local.get $subtask) (i32.load (i32.const 8)))
          (then unreachable))
        (if (i32.ne (i32.const 4 (; CANCELLED_BEFORE_RETURNED ;)) (i32.load offset=4 (i32.const 8)))
          (then unreachable))
        (call $subtask.drop (local.get $subtask))
      )

      (func $run (export "run") (result i32)
        (call $new-future)
        (call $finish (call $started
          (call $suspend (global.get $futr) (i32.const 4))))

        (call $new-future)
        (call $finish (call $started
          (call $suspend-then-resume (global.get $futr) (i32.const 4))))

        (call $new-future)
        (call $finish (call $started
          (call $yield-then-resume (global.get $futr) (i32.const 4))))

        (call $new-future)
        (call $finish (call $started
          (call $suspend-then-promote-ready (global.get $futr) (i32.const 4))))

        (call $new-future)
        (call $finish (call $started
          (call $yield-then-promote-ready (global.get $futr) (i32.const 4))))

        (call $new-future)
        (call $finish (call $started
          (call $suspend-then-promote-not-ready (global.get $futr) (i32.const 4))))

        ;; all tests passed
        (i32.const 42)
      )
    )
    (canon subtask.cancel async (core func $subtask.cancel))
    (canon subtask.drop (core func $subtask.drop))
    (canon future.new $FT (core func $future.new))
    (canon future.write $FT async (memory (core memory $memory "mem")) (core func $future.write))
    (canon waitable.join (core func $waitable.join))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon lower (func $suspend) async (memory (core memory $memory "mem")) (core func $suspend'))
    (canon lower (func $suspend-then-resume) async (memory (core memory $memory "mem")) (core func $suspend-then-resume'))
    (canon lower (func $yield-then-resume) async (memory (core memory $memory "mem")) (core func $yield-then-resume'))
    (canon lower (func $suspend-then-promote-ready) async (memory (core memory $memory "mem")) (core func $suspend-then-promote-ready'))
    (canon lower (func $yield-then-promote-ready) async (memory (core memory $memory "mem")) (core func $yield-then-promote-ready'))
    (canon lower (func $suspend-then-promote-not-ready) async (memory (core memory $memory "mem")) (core func $suspend-then-promote-not-ready'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "subtask.cancel" (func $subtask.cancel))
      (export "subtask.drop" (func $subtask.drop))
      (export "future.new" (func $future.new))
      (export "future.write" (func $future.write))
      (export "waitable.join" (func $waitable.join))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "suspend" (func $suspend'))
      (export "suspend-then-resume" (func $suspend-then-resume'))
      (export "yield-then-resume" (func $yield-then-resume'))
      (export "suspend-then-promote-ready" (func $suspend-then-promote-ready'))
      (export "yield-then-promote-ready" (func $yield-then-promote-ready'))
      (export "suspend-then-promote-not-ready" (func $suspend-then-promote-not-ready'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $dm "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "suspend" (func $c "suspend"))
    (with "suspend-then-resume" (func $c "suspend-then-resume"))
    (with "yield-then-resume" (func $c "yield-then-resume"))
    (with "suspend-then-promote-ready" (func $c "suspend-then-promote-ready"))
    (with "yield-then-promote-ready" (func $c "yield-then-promote-ready"))
    (with "suspend-then-promote-not-ready" (func $c "suspend-then-promote-not-ready"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))
