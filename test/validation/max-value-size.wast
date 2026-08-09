;; Validation rejects defvaltypes whose resolved structural AST exceeds
;; MAX_VALUE_BYTE_LENGTH (2^28 - 1 bytes). See CanonicalABI.md#element-size.

;; valid boundaries

(component
  (type (list u8 268435455))
)

(component
  (type (list u64 33554431))
)

(component
  (type (list string 16777215))
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

;; map despecialization: inner list valid alone, pair record is MAX + 1

(assert_invalid
  (component (type (map u8 (list u8 268435455))))
  "exceeds maximum byte size")

;; nested fixed list

(assert_invalid
  (component (type (list (list u8 268435455) 2)))
  "exceeds maximum byte size")

;; pointer-width-sensitive rejection (passes i32, fails i64)

(assert_invalid
  (component (type (list string 16777216)))
  "exceeds maximum byte size")
