;; This test validates that the inst.may_block flag is a per-ComponentInstance
;; property shared across all tasks.
;;
;; "trap-on-block-before-return": an async task on $C creates a cooperative
;; thread (via thread.new-indirect) and blocks via the WAIT callback code. $D
;; then creates a ready-to-run cooperative thread (that would trap with
;; "unreachable" if scheduled) and calls a sync function on $C, which sets
;; inst.may_block = False and switches to the cooperative thread. When that
;; thread attempts thread.suspend, it traps with "cannot block" without ever
;; running $D's thread.
;;
;; "ok-if-block-after-return": same setup, but the sync function on $C is lifted
;; with async callback so it can call task.return (restoring inst.may_block to
;; True) before switching to the cooperative thread, whose thread.suspend
;; succeeds.
(component definition $Tester
  (component $C
    (core module $Table
      (table (export "ftbl") 1 funcref))
    (core instance $table (instantiate $Table))
    (core module $CM
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.suspend" (func $thread.suspend (result i32)))
      (import "" "thread.suspend-to-suspended" (func $thread.suspend-to-suspended (param i32) (result i32)))
      (import "" "task.return" (func $task.return))
      (import "" "ftbl" (table $ftbl 1 funcref))

      (global $thread-idx (mut i32) (i32.const -1))

      (func $thread-start (param i32)
        (drop (call $thread.suspend))
        unreachable
      )
      (elem (table $ftbl) (i32.const 0) func $thread-start)

      (func (export "setup-thread") (result i32)
        (global.set $thread-idx (call $thread.new-indirect (i32.const 0) (i32.const 0)))
        (i32.or
          (i32.const 2 (; WAIT ;))
          (i32.shl (call $waitable-set.new) (i32.const 4)))
      )
      (func (export "setup-thread-cb") (param i32 i32 i32) (result i32)
        unreachable
      )

      (func (export "switch-before-return")
        (drop (call $thread.suspend-to-suspended (global.get $thread-idx)))
        unreachable
      )

      (func (export "switch-after-return") (result i32)
        (call $task.return)
        (drop (call $thread.suspend-to-suspended (global.get $thread-idx)))
        unreachable
      )
      (func (export "switch-after-return-cb") (param i32 i32 i32) (result i32)
        unreachable
      )
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "ftbl" (core table $ftbl))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon thread.new-indirect $start-func-ty (table $ftbl)
      (core func $thread.new-indirect))
    (canon thread.suspend (core func $thread.suspend))
    (canon thread.suspend-to-suspended (core func $thread.suspend-to-suspended))
    (canon task.return (core func $task.return))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "waitable-set.new" (func $waitable-set.new))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.suspend" (func $thread.suspend))
      (export "thread.suspend-to-suspended" (func $thread.suspend-to-suspended))
      (export "task.return" (func $task.return))
      (export "ftbl" (table $ftbl))
    ))))
    (func (export "setup-thread") async (canon lift
      (core func $cm "setup-thread") async (callback (func $cm "setup-thread-cb"))))
    (func (export "switch-before-return") (canon lift (core func $cm "switch-before-return")))
    (func (export "switch-after-return") (canon lift
      (core func $cm "switch-after-return") async (callback (func $cm "switch-after-return-cb"))))
  )
  (component $D
    (import "c" (instance $c
      (export "setup-thread" (func async))
      (export "switch-before-return" (func))
      (export "switch-after-return" (func))
    ))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $Table
      (table (export "ftbl") 1 funcref))
    (core instance $table (instantiate $Table))
    (core module $Core
      (import "" "setup-thread" (func $setup-thread (result i32)))
      (import "" "switch-before-return" (func $switch-before-return))
      (import "" "switch-after-return" (func $switch-after-return))
      (import "" "thread.new-indirect" (func $thread.new-indirect (param i32 i32) (result i32)))
      (import "" "thread.unsuspend" (func $thread.unsuspend (param i32)))
      (import "" "ftbl" (table $ftbl 1 funcref))

      ;; this thread should never get to run:
      (func $thread-start-unreachable (param i32) unreachable)
      (elem (table $ftbl) (i32.const 0) func $thread-start-unreachable)

      (func (export "trap-on-block-before-return")
        (local $ret i32)
        (local.set $ret (call $setup-thread))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))

        ;; even though its ready, this thread should never get to run before the
        ;; trap in $switch-before-return
        (call $thread.unsuspend
          (call $thread.new-indirect (i32.const 0) (i32.const 0)))

        (call $switch-before-return)
        unreachable
      )

      (func (export "ok-if-block-after-return") (result i32)
        (local $ret i32)
        (local.set $ret (call $setup-thread))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (call $switch-after-return)
        (i32.const 42)
      )
    )
    (core type $start-func-ty (func (param i32)))
    (alias core export $table "ftbl" (core table $ftbl))
    (canon thread.new-indirect $start-func-ty (table $ftbl)
      (core func $thread.new-indirect))
    (canon thread.unsuspend (core func $thread.unsuspend))
    (canon lower (func $c "setup-thread") (memory $memory "mem") async (core func $setup-thread'))
    (canon lower (func $c "switch-before-return") (core func $switch-before-return'))
    (canon lower (func $c "switch-after-return") (core func $switch-after-return'))
    (core instance $core (instantiate $Core (with "" (instance
      (export "setup-thread" (func $setup-thread'))
      (export "switch-before-return" (func $switch-before-return'))
      (export "switch-after-return" (func $switch-after-return'))
      (export "thread.new-indirect" (func $thread.new-indirect))
      (export "thread.unsuspend" (func $thread.unsuspend))
      (export "ftbl" (table $ftbl))
    ))))
    (func (export "trap-on-block-before-return") (canon lift (core func $core "trap-on-block-before-return")))
    (func (export "ok-if-block-after-return") (result u32) (canon lift (core func $core "ok-if-block-after-return")))
  )
  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "trap-on-block-before-return") (alias export $d "trap-on-block-before-return"))
  (func (export "ok-if-block-after-return") (alias export $d "ok-if-block-after-return"))
)

(component instance $i $Tester)
(assert_trap (invoke "trap-on-block-before-return") "cannot block")

(component instance $i $Tester)
(assert_return (invoke "ok-if-block-after-return") (u32.const 42))
