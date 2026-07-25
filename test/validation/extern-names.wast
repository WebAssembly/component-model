;; Test the extern-name grammar beyond plain kebab names (covered by
;; kebab.wast): versioned interface names, semver parsing, exclusion of
;; non-name forms and the (interface "...") id-form sugar.

;; the same interface name may coexist unversioned and at multiple versions,
;; but exact duplicates still conflict

(component definition
  (import "wasi:http/types" (func))
  (import "wasi:http/types@1.0.0" (func))
  (import "wasi:http/types@2.0.0" (func))
  (import "a-b:c-d/e-f@123456.7890.488" (func))
  (import "a:b/c@0.0.0+abcd" (func))
  (import "a:b/c@0.0.0+abcd-efg" (func))
  (import "a:b/c@0.0.0-abcd+efg" (func))
  (import "a:b/c@0.0.0-abcd.1.2+efg.4.ee.5" (func))
)
(assert_invalid
  (component
    (import "wasi:http/types@1.0.0" (func))
    (import "wasi:http/types@1.0.0" (func)))
  "conflicts with previous name")

;; malformed versions

(assert_invalid
  (component (import "a:b/c@" (func)))
  "empty string")
(assert_invalid
  (component (import "a:b/c@." (func)))
  "unexpected character '.'")
(assert_invalid
  (component (import "a:b/c@1." (func)))
  "unexpected end of input")
(assert_invalid
  (component (import "a:b/c@a.2" (func)))
  "unexpected character 'a'")
(assert_invalid
  (component (import "a:b/c@2.b" (func)))
  "unexpected character 'b'")
(assert_invalid
  (component (import "a:b/c@2.0x0" (func)))
  "unexpected character 'x'")
(assert_invalid
  (component (import "a:b/c@2.0.0+" (func)))
  "empty identifier segment")
(assert_invalid
  (component (import "a:b/c@2.0.0-" (func)))
  "empty identifier segment")

;; nested namespaces and nested projections are gated (🪺) future syntax

(assert_invalid
  (component (import "foo:bar:baz/qux" (func)))
  "expected `/` after package name")
(assert_invalid
  (component (import "foo:bar/baz/qux" (func)))
  "trailing characters found: `/qux`")
