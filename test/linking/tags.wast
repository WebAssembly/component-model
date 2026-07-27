;; Linking tests for core tags: satisfying tag imports from real and
;; synthesized core instances, aliasing tags out of instances, and
;; per-instance generativity of tags.

;; A tag defined in its own module and imported by a thrower and a catcher
;; via whole-instance arguments: the catch matches exactly the thrower's tag.
(component
  (core module $Tag (tag (export "t") (param i32)))
  (core module $Thrower
    (import "tag" "t" (tag $t (param i32)))
    (func (export "throw-if") (param i32)
      (if (local.get 0)
        (then (throw $t (local.get 0))))))
  (core module $Catcher
    (import "tag" "t" (tag $t (param i32)))
    (import "thrower" "throw-if" (func $throw-if (param i32)))
    (func (export "run") (param i32) (result i32)
      (block $h (result i32)
        (try_table (catch $t $h)
          (call $throw-if (local.get 0)))
        (return (i32.const 99)))))
  (core instance $tag (instantiate $Tag))
  (core instance $thrower (instantiate $Thrower (with "tag" (instance $tag))))
  (core instance $catcher (instantiate $Catcher
    (with "tag" (instance $tag))
    (with "thrower" (instance $thrower))))
  (func (export "run") (param "x" u32) (result u32)
    (canon lift (core func $catcher "run")))
)

(assert_return (invoke "run" (u32.const 42)) (u32.const 42))
(assert_return (invoke "run" (u32.const 0)) (u32.const 99))

;; Renaming a tag export to satisfy an import: synthesized instances alias
;; the same underlying tag "t" as "exn", so the catch still matches.
(component
  (core module $Tag (tag (export "t") (param i32)))
  (core module $Thrower
    (import "env" "exn" (tag $t (param i32)))
    (func (export "throw") (param i32)
      (throw $t (local.get 0))))
  (core module $Catcher
    (import "env" "exn" (tag $t (param i32)))
    (import "thrower" "throw" (func $throw (param i32)))
    (func (export "run") (param i32) (result i32)
      (block $h (result i32)
        (try_table (catch $t $h)
          (call $throw (local.get 0)))
        (return (i32.const 99)))))
  (core instance $tag (instantiate $Tag))
  (core instance $thrower (instantiate $Thrower
    (with "env" (instance (export "exn" (tag $tag "t"))))))
  (core instance $catcher (instantiate $Catcher
    (with "env" (instance (export "exn" (tag $tag "t"))))
    (with "thrower" (instance $thrower))))
  (func (export "run") (param "x" u32) (result u32)
    (canon lift (core func $catcher "run")))
)

(assert_return (invoke "run" (u32.const 7)) (u32.const 7))

;; Aliasing a core tag out of an instance and tupling it into a synthesized
;; instance: the tag still identifies the original.
(component
  (core module $Tag (tag (export "t") (param i32)))
  (core module $Thrower
    (import "tag" "t" (tag $t (param i32)))
    (func (export "throw") (param i32)
      (throw $t (local.get 0))))
  (core module $Catcher
    (import "tag" "t" (tag $t (param i32)))
    (import "thrower" "throw" (func $throw (param i32)))
    (func (export "run") (param i32) (result i32)
      (block $h (result i32)
        (try_table (catch $t $h)
          (call $throw (local.get 0)))
        (return (i32.const 99)))))
  (core instance $tag (instantiate $Tag))
  (alias core export $tag "t" (core tag $t))
  (core instance $syn (export "t" (tag $t)))
  (core instance $thrower (instantiate $Thrower (with "tag" (instance $syn))))
  (core instance $catcher (instantiate $Catcher
    (with "tag" (instance $syn))
    (with "thrower" (instance $thrower))))
  (func (export "run") (param "x" u32) (result u32)
    (canon lift (core func $catcher "run")))
)

(assert_return (invoke "run" (u32.const 13)) (u32.const 13))

;; Tags are generative per instance: two instances of one tag module define
;; distinct tags, so a catch only matches throws of the tag it imported.
(component
  (core module $Tag (tag (export "t") (param i32)))
  (core module $Thrower
    (import "tag" "t" (tag $t (param i32)))
    (func (export "throw") (param i32)
      (throw $t (local.get 0))))
  (core module $Catcher
    (import "tag" "t" (tag $t (param i32)))
    (import "a" "throw" (func $throw-a (param i32)))
    (import "b" "throw" (func $throw-b (param i32)))
    (func (export "run-a") (param i32) (result i32)
      (block $all
        (block $h (result i32)
          (try_table (catch $t $h) (catch_all $all)
            (call $throw-a (local.get 0)))
          (return (i32.const 99)))
        (return))
      (i32.const 77))
    (func (export "run-b") (param i32) (result i32)
      (block $all
        (block $h (result i32)
          (try_table (catch $t $h) (catch_all $all)
            (call $throw-b (local.get 0)))
          (return (i32.const 99)))
        (return))
      (i32.const 77)))
  (core instance $tag-a (instantiate $Tag))
  (core instance $tag-b (instantiate $Tag))
  (core instance $ta (instantiate $Thrower (with "tag" (instance $tag-a))))
  (core instance $tb (instantiate $Thrower (with "tag" (instance $tag-b))))
  (core instance $c (instantiate $Catcher
    (with "tag" (instance $tag-a))
    (with "a" (instance $ta))
    (with "b" (instance $tb))))
  (func (export "run-a") (param "x" u32) (result u32)
    (canon lift (core func $c "run-a")))
  (func (export "run-b") (param "x" u32) (result u32)
    (canon lift (core func $c "run-b")))
)

(assert_return (invoke "run-a" (u32.const 42)) (u32.const 42))
(assert_return (invoke "run-b" (u32.const 42)) (u32.const 77))

;; Aliasing a non-tag export as a core tag is a sort mismatch.
(assert_invalid
  (component
    (core module $M (func (export "f")))
    (core instance $i (instantiate $M))
    (alias core export $i "f" (core tag $t)))
  "export `f` for core instance 0 is not a tag")

;; A synthesized core instance cannot export an out-of-bounds tag index.
(assert_invalid
  (component
    (core module $M (func (export "f")))
    (core instance $i (instantiate $M))
    (core instance (export "t" (tag 0))))
  "unknown tag 0: tag index out of bounds")
