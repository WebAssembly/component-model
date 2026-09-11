;; Validation requires elem_size(t, i64) < 2^28 for every defvaltype t.
;; See CanonicalABI.md#element-size.

;; valid boundaries (single component)

(component
  (type (list u8 268435455))
  (type (list u64 33554431))
  (type (list string 16777215))
  (type (map u8 (list u8 4)))
  (type (tuple (list u8 268435454) (list u8 1)))
  (type (record
    (field "a" (list u8 134217727))
    (field "b" (list u8 134217728))))
  (type (list (list u8 134217727) 2))
  (type (map u8 (list u8 268435455)))
  (type (option (map u8 (list u8 268435455))))
  (type (record (field "m" (map u8 (list u8 268435455)))))
  (type (stream (list u8 268435455)))
  (type (future (list u8 268435455)))
)

;; single fixed list just over the limit

(assert_invalid
  (component (type (list u8 268435456)))
  "exceeds maximum byte size")

;; fixed list whose product exceeds MAX

(assert_invalid
  (component (type (list u64 33554432)))
  "exceeds maximum byte size")

;; u32 wrap class: real byte size is 2^32 but naive u32 multiply wraps to 0

(assert_invalid
  (component (type (list u64 536870912)))
  "exceeds maximum byte size")

;; compound sum exceeds MAX

(assert_invalid
  (component
    (type (tuple (list u8 268435455) (list u8 1))))
  "exceeds maximum byte size")

(assert_invalid
  (component
    (type (record
      (field "a" (list u8 134217728))
      (field "b" (list u8 134217728)))))
  "exceeds maximum byte size")

;; nested fixed list

(assert_invalid
  (component (type (list (list u8 268435455) 2)))
  "exceeds maximum byte size")

;; pointer-width-sensitive rejection (passes i32, fails i64)

(assert_invalid
  (component (type (list string 16777216)))
  "exceeds maximum byte size")
