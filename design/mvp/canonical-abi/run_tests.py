import time

import definitions
from definitions import *

definitions.DETERMINISTIC_PROFILE = True

def equal_modulo_string_encoding(s, t):
  if s is None and t is None:
    return True
  if isinstance(s, (bool,int,float,str)) and isinstance(t, (bool,int,float,str)):
    return s == t
  if isinstance(s, tuple) and isinstance(t, tuple):
    assert(isinstance(s[0], str))
    assert(isinstance(t[0], str))
    return s[0] == t[0]
  if isinstance(s, dict) and isinstance(t, dict):
    return all(equal_modulo_string_encoding(sv,tv) for sv,tv in zip(s.values(), t.values(), strict=True))
  if isinstance(s, list) and isinstance(t, list):
    return all(equal_modulo_string_encoding(sv,tv) for sv,tv in zip(s, t, strict=True))
  assert(False)

class Heap:
  def __init__(self, arg):
    self.memory = bytearray(arg)
    self.last_alloc = 0

  def realloc(self, original_ptr, original_size, alignment, new_size):
    if original_ptr != 0 and new_size < original_size:
      return align_to(original_ptr, alignment)
    ret = align_to(self.last_alloc, alignment)
    self.last_alloc = ret + new_size
    if self.last_alloc > len(self.memory):
      trap()
    self.memory[ret : ret + original_size] = self.memory[original_ptr : original_ptr + original_size]
    return ret

def mk_opts(memory = bytearray(), encoding = 'utf8', realloc = None, post_return = None, sync_task_return = False, sync = True):
  opts = CanonicalOptions()
  opts.memory = memory
  opts.string_encoding = encoding
  opts.realloc = realloc
  opts.post_return = post_return
  opts.sync_task_return = sync_task_return
  opts.sync = sync
  opts.callback = None
  return opts

def mk_cx(memory = bytearray(), encoding = 'utf8', realloc = None, post_return = None):
  opts = mk_opts(memory, encoding, realloc, post_return)
  inst = ComponentInstance(Store())
  return LiftLowerContext(opts, inst)

def run_lift(opts, inst, ft, callee, on_start, on_resolve):
  lifted_func = partial(canon_lift, opts, inst, ft, callee)
  task = inst.store.invoke(lifted_func, None, on_start, on_resolve)
  while task.thread is not None:
    inst.store.tick()

def mk_task(caller, on_resolve, thread_func):
  inst = ComponentInstance(caller.inst.store)
  task = Task(None, inst, None, caller, on_resolve)
  thread = Thread(task, partial(thread_func, task))
  thread.resume()
  return task

def mk_done_task(caller):
  def empty(task):
    task.state = Task.State.RESOLVED
  return mk_task(caller, lambda _:(), empty)

def mk_str(s):
  return (s, 'utf8', len(s.encode('utf-8')))

def mk_tup(*a):
  def mk_tup_rec(x):
    if isinstance(x, list):
      return { str(i):mk_tup_rec(v) for i,v in enumerate(x) }
    return x
  return { str(i):mk_tup_rec(v) for i,v in enumerate(a) }

class RacyBool:
  b: bool
  def __init__(self, b):
    self.b = b
  def set(self):
    self.b = True
  def clear(self):
    self.b = False
  def is_set(self):
    return self.b
  def is_clear(self):
    return not self.b

def unpack_result(ret):
  assert(ret != 0xffff_ffff)
  return (ret & 0xf, ret >> 4)

def unpack_new_ends(packed):
  return (packed & 0xffff_ffff, packed >> 32)

def fail(msg):
  raise BaseException(msg)

def test(t, vals_to_lift, v,
         cx = mk_cx(),
         dst_encoding = None,
         lower_t = None,
         lower_v = None):
  def test_name():
    return "test({},{},{}):".format(t, vals_to_lift, v)

  vi = CoreValueIter(vals_to_lift)

  if v is None:
    try:
      got = lift_flat(cx, vi, t)
      fail("{} expected trap, but got {}".format(test_name(), got))
    except Trap:
      return

  got = lift_flat(cx, vi, t)
  assert(vi.i == len(vi.values))
  if got != v:
    fail("{} initial lift_flat() expected {} but got {}".format(test_name(), v, got))

  if lower_t is None:
    lower_t = t
  if lower_v is None:
    lower_v = v

  heap = Heap(5*len(cx.opts.memory))
  if dst_encoding is None:
    dst_encoding = cx.opts.string_encoding
  cx = mk_cx(heap.memory, dst_encoding, heap.realloc)
  lowered_vals = lower_flat(cx, v, lower_t)

  vi = CoreValueIter(lowered_vals)
  got = lift_flat(cx, vi, lower_t)
  if not equal_modulo_string_encoding(got, lower_v):
    fail("{} re-lift expected {} but got {}".format(test_name(), lower_v, got))

# Empty record types are not permitted yet.
#test(RecordType([]), [], {})
test(RecordType([FieldType('x',U8Type()),
                 FieldType('y',U16Type()),
                 FieldType('z',U32Type())]),
     [1,2,3],
     {'x':1,'y':2,'z':3})
test(TupleType([TupleType([U8Type(),U8Type()]),U8Type()]), [1,2,3], {'0':{'0':1,'1':2},'1':3})
test(ListType(U8Type(),3), [1,2,3], [1,2,3])
test(ListType(ListType(U8Type(),2),3), [1,2,3,4,5,6], [[1,2],[3,4],[5,6]])
# Empty flags types are not permitted yet.
#t = FlagsType([])
#test(t, [], {})
t = FlagsType(['a','b'])
test(t, [0], {'a':False,'b':False})
test(t, [2], {'a':False,'b':True})
test(t, [3], {'a':True,'b':True})
test(t, [4], {'a':False,'b':False})
test(FlagsType([str(i) for i in range(32)]), [0xffffffff], { str(i):True for i in range(32) })
t = VariantType([CaseType('x',U8Type()),CaseType('y',F32Type()),CaseType('z',None)])
test(t, [0,42], {'x': 42})
test(t, [0,256], {'x': 0})
test(t, [1,0x4048f5c3], {'y': 3.140000104904175})
test(t, [2,0xffffffff], {'z': None})
t = OptionType(F32Type())
test(t, [0,3.14], {'none':None})
test(t, [1,3.14], {'some':3.14})
t = ResultType(U8Type(),U32Type())
test(t, [0, 42], {'ok':42})
test(t, [1, 1000], {'error':1000})
t = VariantType([CaseType('w',U8Type()),
                 CaseType('y',U8Type())])
test(t, [0, 42], {'w':42})
test(t, [1, 42], {'y':42})
t2 = VariantType([CaseType('w',U8Type())])
test(t, [0, 42], {'w':42}, lower_t=t2, lower_v={'w':42})

def test_pairs(t, pairs):
  for arg,expect in pairs:
    test(t, [arg], expect)

test_pairs(BoolType(), [(0,False),(1,True),(2,True),(4294967295,True)])
test_pairs(U8Type(), [(127,127),(128,128),(255,255),(256,0),
                      (4294967295,255),(4294967168,128),(4294967167,127)])
test_pairs(S8Type(), [(127,127),(128,-128),(255,-1),(256,0),
                      (4294967295,-1),(4294967168,-128),(4294967167,127)])
test_pairs(U16Type(), [(32767,32767),(32768,32768),(65535,65535),(65536,0),
                       ((1<<32)-1,65535),((1<<32)-32768,32768),((1<<32)-32769,32767)])
test_pairs(S16Type(), [(32767,32767),(32768,-32768),(65535,-1),(65536,0),
                       ((1<<32)-1,-1),((1<<32)-32768,-32768),((1<<32)-32769,32767)])
test_pairs(U32Type(), [((1<<31)-1,(1<<31)-1),(1<<31,1<<31),(((1<<32)-1),(1<<32)-1)])
test_pairs(S32Type(), [((1<<31)-1,(1<<31)-1),(1<<31,-(1<<31)),((1<<32)-1,-1)])
test_pairs(U64Type(), [((1<<63)-1,(1<<63)-1), (1<<63,1<<63), ((1<<64)-1,(1<<64)-1)])
test_pairs(S64Type(), [((1<<63)-1,(1<<63)-1), (1<<63,-(1<<63)), ((1<<64)-1,-1)])
test_pairs(F32Type(), [(3.14,3.14)])
test_pairs(F64Type(), [(3.14,3.14)])
test_pairs(CharType(), [(0,'\x00'), (65,'A'), (0xD7FF,'\uD7FF'), (0xD800,None), (0xDFFF,None)])
test_pairs(CharType(), [(0xE000,'\uE000'), (0x10FFFF,'\U0010FFFF'), (0x110000,None), (0xFFFFFFFF,None)])
test_pairs(EnumType(['a','b']), [(0,{'a':None}), (1,{'b':None}), (2,None)])

def test_nan32(inbits, outbits):
  origf = decode_i32_as_float(inbits)
  f = lift_flat(mk_cx(), CoreValueIter([origf]), F32Type())
  if definitions.DETERMINISTIC_PROFILE:
    assert(encode_float_as_i32(f) == outbits)
  else:
    assert(not math.isnan(origf) or math.isnan(f))
  cx = mk_cx(int.to_bytes(inbits, 4, 'little'))
  f = load(cx, 0, F32Type())
  if definitions.DETERMINISTIC_PROFILE:
    assert(encode_float_as_i32(f) == outbits)
  else:
    assert(not math.isnan(origf) or math.isnan(f))

def test_nan64(inbits, outbits):
  origf = decode_i64_as_float(inbits)
  f = lift_flat(mk_cx(), CoreValueIter([origf]), F64Type())
  if definitions.DETERMINISTIC_PROFILE:
    assert(encode_float_as_i64(f) == outbits)
  else:
    assert(not math.isnan(origf) or math.isnan(f))
  cx = mk_cx(int.to_bytes(inbits, 8, 'little'))
  f = load(cx, 0, F64Type())
  if definitions.DETERMINISTIC_PROFILE:
    assert(encode_float_as_i64(f) == outbits)
  else:
    assert(not math.isnan(origf) or math.isnan(f))

test_nan32(0x7fc00000, CANONICAL_FLOAT32_NAN)
test_nan32(0x7fc00001, CANONICAL_FLOAT32_NAN)
test_nan32(0x7fe00000, CANONICAL_FLOAT32_NAN)
test_nan32(0x7fffffff, CANONICAL_FLOAT32_NAN)
test_nan32(0xffffffff, CANONICAL_FLOAT32_NAN)
test_nan32(0x7f800000, 0x7f800000)
test_nan32(0x3fc00000, 0x3fc00000)
test_nan64(0x7ff8000000000000, CANONICAL_FLOAT64_NAN)
test_nan64(0x7ff8000000000001, CANONICAL_FLOAT64_NAN)
test_nan64(0x7ffc000000000000, CANONICAL_FLOAT64_NAN)
test_nan64(0x7fffffffffffffff, CANONICAL_FLOAT64_NAN)
test_nan64(0xffffffffffffffff, CANONICAL_FLOAT64_NAN)
test_nan64(0x7ff0000000000000, 0x7ff0000000000000)
test_nan64(0x3ff0000000000000, 0x3ff0000000000000)

def test_string_internal(src_encoding, dst_encoding, s, encoded, tagged_code_units):
  heap = Heap(len(encoded))
  heap.memory[:] = encoded[:]
  cx = mk_cx(heap.memory, src_encoding)
  v = (s, src_encoding, tagged_code_units)
  test(StringType(), [0, tagged_code_units], v, cx, dst_encoding)

def test_string(src_encoding, dst_encoding, s):
  if src_encoding == 'utf8':
    encoded = s.encode('utf-8')
    tagged_code_units = len(encoded)
    test_string_internal(src_encoding, dst_encoding, s, encoded, tagged_code_units)
  elif src_encoding == 'utf16':
    encoded = s.encode('utf-16-le')
    tagged_code_units = int(len(encoded) / 2)
    test_string_internal(src_encoding, dst_encoding, s, encoded, tagged_code_units)
  elif src_encoding == 'latin1+utf16':
    try:
      encoded = s.encode('latin-1')
      tagged_code_units = len(encoded)
      test_string_internal(src_encoding, dst_encoding, s, encoded, tagged_code_units)
    except UnicodeEncodeError:
      pass
    encoded = s.encode('utf-16-le')
    tagged_code_units = int(len(encoded) / 2) | UTF16_TAG
    test_string_internal(src_encoding, dst_encoding, s, encoded, tagged_code_units)

encodings = ['utf8', 'utf16', 'latin1+utf16']

fun_strings = ['', 'a', 'hi', '\x00', 'a\x00b', '\x80', '\x80b', 'ab\xefc',
               '\u01ffy', 'xy\u01ff', 'a\ud7ffb', 'a\u02ff\u03ff\u04ffbc',
               '\uf123', '\uf123\uf123abc', 'abcdef\uf123']

for src_encoding in encodings:
  for dst_encoding in encodings:
    for s in fun_strings:
      test_string(src_encoding, dst_encoding, s)

def test_heap(t, expect, args, byte_array):
  heap = Heap(byte_array)
  cx = mk_cx(heap.memory)
  test(t, args, expect, cx)

# Empty record types are not permitted yet.
#test_heap(ListType(RecordType([])), [{},{},{}], [0,3], [])
test_heap(ListType(BoolType()), [True,False,True], [0,3], [1,0,1])
test_heap(ListType(BoolType()), [True,False,True], [0,3], [1,0,2])
test_heap(ListType(BoolType()), [True,False,True], [3,3], [0xff,0xff,0xff, 1,0,1])
test_heap(ListType(U8Type()), [1,2,3], [0,3], [1,2,3])
test_heap(ListType(U16Type()), [1,2,3], [0,3], [1,0, 2,0, 3,0 ])
test_heap(ListType(U16Type()), None, [1,3], [0, 1,0, 2,0, 3,0 ])
test_heap(ListType(U32Type()), [1,2,3], [0,3], [1,0,0,0, 2,0,0,0, 3,0,0,0])
test_heap(ListType(U64Type()), [1,2], [0,2], [1,0,0,0,0,0,0,0, 2,0,0,0,0,0,0,0])
test_heap(ListType(S8Type()), [-1,-2,-3], [0,3], [0xff,0xfe,0xfd])
test_heap(ListType(S16Type()), [-1,-2,-3], [0,3], [0xff,0xff,
                                                   0xfe,0xff,
                                                   0xfd,0xff])
test_heap(ListType(S32Type()), [-1,-2,-3], [0,3], [0xff,0xff,0xff,0xff,
                                                   0xfe,0xff,0xff,0xff,
                                                   0xfd,0xff,0xff,0xff])
test_heap(ListType(S64Type()), [-1,-2], [0,2], [0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
                                                0xfe,0xff,0xff,0xff,0xff,0xff,0xff,0xff])
test_heap(ListType(CharType()), ['A','B','c'], [0,3], [65,00,00,00, 66,00,00,00, 99,00,00,00])
test_heap(ListType(StringType()), [mk_str("hi"),mk_str("wat")], [0,2],
          [16,0,0,0, 2,0,0,0, 21,0,0,0, 3,0,0,0,
           ord('h'), ord('i'),   0xf,0xf,0xf,   ord('w'), ord('a'), ord('t')])
test_heap(ListType(ListType(U8Type())), [[3,4,5],[],[6,7]], [0,3],
          [24,0,0,0, 3,0,0,0, 0,0,0,0, 0,0,0,0, 27,0,0,0, 2,0,0,0,
          3,4,5,  6,7])
test_heap(ListType(ListType(U16Type())), [[5,6]], [0,1],
          [8,0,0,0, 2,0,0,0,
          5,0, 6,0])
test_heap(ListType(ListType(U16Type())), None, [0,1],
          [9,0,0,0, 2,0,0,0,
          0, 5,0, 6,0])
test_heap(ListType(ListType(U8Type(),2)), [[1,2],[3,4]], [0,2],
          [1,2, 3,4])
test_heap(ListType(ListType(U32Type(),2)), [[1,2],[3,4]], [0,2],
          [1,0,0,0,2,0,0,0, 3,0,0,0,4,0,0,0])
test_heap(ListType(ListType(U32Type(),2)), None, [1,2],
          [0, 1,0,0,0,2,0,0,0, 3,0,0,0,4,0,0,0])
test_heap(ListType(TupleType([U8Type(),U8Type(),U16Type(),U32Type()])),
          [mk_tup(6,7,8,9),mk_tup(4,5,6,7)],
          [0,2],
          [6, 7, 8,0, 9,0,0,0,   4, 5, 6,0, 7,0,0,0])
test_heap(ListType(TupleType([U8Type(),U16Type(),U8Type(),U32Type()])),
          [mk_tup(6,7,8,9),mk_tup(4,5,6,7)],
          [0,2],
          [6,0xff, 7,0, 8,0xff,0xff,0xff, 9,0,0,0,   4,0xff, 5,0, 6,0xff,0xff,0xff, 7,0,0,0])
test_heap(ListType(TupleType([U16Type(),U8Type()])),
          [mk_tup(6,7),mk_tup(8,9)],
          [0,2],
          [6,0, 7, 0x0ff, 8,0, 9, 0xff])
test_heap(ListType(TupleType([TupleType([U16Type(),U8Type()]),U8Type()])),
          [mk_tup([4,5],6),mk_tup([7,8],9)],
          [0,2],
          [4,0, 5,0xff, 6,0xff,  7,0, 8,0xff, 9,0xff])
# Empty flags types are not permitted yet.
#t = ListType(FlagsType([]))
#test_heap(t, [{},{},{}], [0,3],
#          [])
#t = ListType(TupleType([FlagsType([]), U8Type()]))
#test_heap(t, [mk_tup({}, 42), mk_tup({}, 43), mk_tup({}, 44)], [0,3],
#          [42,43,44])
t = ListType(FlagsType(['a','b']))
test_heap(t, [{'a':False,'b':False},{'a':False,'b':True},{'a':True,'b':True}], [0,3],
          [0,2,3])
test_heap(t, [{'a':False,'b':False},{'a':False,'b':True},{'a':False,'b':False}], [0,3],
          [0,2,4])
t = ListType(FlagsType([str(i) for i in range(9)]))
v = [{ str(i):b for i in range(9) } for b in [True,False]]
test_heap(t, v, [0,2],
          [0xff,0x1, 0,0])
test_heap(t, v, [0,2],
          [0xff,0x3, 0,0])
t = ListType(FlagsType([str(i) for i in range(17)]))
v = [{ str(i):b for i in range(17) } for b in [True,False]]
test_heap(t, v, [0,2],
          [0xff,0xff,0x1,0, 0,0,0,0])
test_heap(t, v, [0,2],
          [0xff,0xff,0x3,0, 0,0,0,0])
t = ListType(FlagsType([str(i) for i in range(32)]))
v = [{ str(i):b for i in range(32) } for b in [True,False]]
test_heap(t, v, [0,2],
          [0xff,0xff,0xff,0xff, 0,0,0,0])

def test_flatten(t, params, results):
  expect = CoreFuncType(params, results)

  if len(params) > definitions.MAX_FLAT_PARAMS:
    expect.params = ['i32']

  if len(results) > definitions.MAX_FLAT_RESULTS:
    expect.results = ['i32']
  got = flatten_functype(CanonicalOptions(), t, 'lift')
  assert(got == expect)

  if len(results) > definitions.MAX_FLAT_RESULTS:
    expect.params += ['i32']
    expect.results = []
  got = flatten_functype(CanonicalOptions(), t, 'lower')
  assert(got == expect)

test_flatten(FuncType([U8Type(),F32Type(),F64Type()],[]), ['i32','f32','f64'], [])
test_flatten(FuncType([U8Type(),F32Type(),F64Type()],[F32Type()]), ['i32','f32','f64'], ['f32'])
test_flatten(FuncType([U8Type(),F32Type(),F64Type()],[U8Type()]), ['i32','f32','f64'], ['i32'])
test_flatten(FuncType([U8Type(),F32Type(),F64Type()],[TupleType([F32Type()])]), ['i32','f32','f64'], ['f32'])
test_flatten(FuncType([U8Type(),F32Type(),F64Type()],[TupleType([F32Type(),F32Type()])]), ['i32','f32','f64'], ['f32','f32'])
test_flatten(FuncType([U8Type(),F32Type(),F64Type()],[F32Type(),F32Type()]), ['i32','f32','f64'], ['f32','f32'])
test_flatten(FuncType([U8Type() for _ in range(17)],[]), ['i32' for _ in range(17)], [])
test_flatten(FuncType([U8Type() for _ in range(17)],[TupleType([U8Type(),U8Type()])]), ['i32' for _ in range(17)], ['i32','i32'])


def test_roundtrips():
  def test_roundtrip(t, v):
    before = definitions.MAX_FLAT_RESULTS
    definitions.MAX_FLAT_RESULTS = 16

    store = Store()

    ft = FuncType([t],[t])
    def callee(task, x):
      return x

    callee_heap = Heap(1000)
    callee_opts = mk_opts(callee_heap.memory, 'utf8', callee_heap.realloc)
    callee_inst = ComponentInstance(store)
    lifted_callee = partial(canon_lift, callee_opts, callee_inst, ft, callee)

    got = None
    def on_start():
      return [v]
    def on_resolve(result):
      nonlocal got
      [got] = result
    run_lift(callee_opts, callee_inst, ft, callee, on_start, on_resolve)

    if got != v:
      fail("test_roundtrip({},{}) got {}".format(t, v, got))

    definitions.MAX_FLAT_RESULTS = before

  test_roundtrip(S8Type(), -1)
  test_roundtrip(TupleType([U16Type(),U16Type()]), mk_tup(3,4))
  test_roundtrip(ListType(StringType()), [mk_str("hello there")])
  test_roundtrip(ListType(ListType(StringType())), [[mk_str("one"),mk_str("two")],[mk_str("three")]])
  test_roundtrip(ListType(OptionType(TupleType([StringType(),U16Type()]))), [{'some':mk_tup(mk_str("answer"),42)}])
  test_roundtrip(VariantType([CaseType('x', TupleType([U32Type(),U32Type(),U32Type(),U32Type(),
                                                       U32Type(),U32Type(),U32Type(),U32Type(),
                                                       U32Type(),U32Type(),U32Type(),U32Type(),
                                                       U32Type(),U32Type(),U32Type(),U32Type(),
                                                       StringType()]))]),
                       {'x': mk_tup(1,2,3,4, 5,6,7,8, 9,10,11,12, 13,14,15,16, mk_str("wat"))})


def test_handles():
  before = definitions.MAX_FLAT_RESULTS
  definitions.MAX_FLAT_RESULTS = 16

  dtor_value = None
  def dtor(task, args):
    nonlocal dtor_value
    assert(len(args) == 1)
    dtor_value = args[0]
    return []

  store = Store()
  rt = ResourceType(ComponentInstance(store), dtor) # usable in imports and exports
  inst = ComponentInstance(store)
  rt2 = ResourceType(inst, dtor) # only usable in exports
  opts = mk_opts()

  def host_import(caller, on_start, on_resolve):
    args = on_start()
    assert(len(args) == 2)
    assert(args[0] == 42)
    assert(args[1] == 44)
    on_resolve([45])
    return mk_done_task(caller)

  def core_wasm(task, args):
    nonlocal dtor_value

    assert(len(args) == 4)
    assert(len(inst.table.array) == 4)
    assert(inst.table.array[0] is None)
    assert(args[0] == 1)
    assert(args[1] == 2)
    assert(args[2] == 3)
    assert(args[3] == 13)
    assert((canon_resource_rep(rt, task, 1))[0] == 42)
    assert((canon_resource_rep(rt, task, 2))[0] == 43)
    assert((canon_resource_rep(rt, task, 3))[0] == 44)

    host_ft = FuncType([
      BorrowType(rt),
      BorrowType(rt)
    ],[
      OwnType(rt)
    ])
    args = [
      1,
      3
    ]
    results = canon_lower(opts, host_ft, host_import, task, args)
    assert(len(results) == 1)
    assert(results[0] == 4)
    assert((canon_resource_rep(rt, task, 4))[0] == 45)

    dtor_value = None
    canon_resource_drop(rt, True, task, 1)
    assert(dtor_value == 42)
    assert(len(inst.table.array) == 5)
    assert(inst.table.array[1] is None)
    assert(len(inst.table.free) == 1)

    h = (canon_resource_new(rt, task, 46))[0]
    assert(h == 1)
    assert(len(inst.table.array) == 5)
    assert(inst.table.array[1] is not None)
    assert(len(inst.table.free) == 0)

    dtor_value = None
    canon_resource_drop(rt, True, task, 3)
    assert(dtor_value is None)
    assert(len(inst.table.array) == 5)
    assert(inst.table.array[3] is None)
    assert(len(inst.table.free) == 1)

    return [1, 2, 4]

  ft = FuncType([
    OwnType(rt),
    OwnType(rt),
    BorrowType(rt),
    BorrowType(rt2)
  ],[
    OwnType(rt),
    OwnType(rt),
    OwnType(rt)
  ])

  def on_start():
    return [ 42, 43, 44, 13 ]

  got = None
  def on_resolve(results):
    nonlocal got
    got = results

  run_lift(opts, inst, ft, core_wasm, on_start, on_resolve)

  assert(len(got) == 3)
  assert(got[0] == 46)
  assert(got[1] == 43)
  assert(got[2] == 45)
  assert(len(inst.table.array) == 5)
  assert(all(inst.table.array[i] is None for i in range(4)))
  assert(len(inst.table.free) == 4)
  definitions.MAX_FLAT_RESULTS = before


def test_async_to_async():
  producer_heap = Heap(10)
  producer_opts = mk_opts(producer_heap.memory)
  producer_opts.sync = False

  store = Store()
  producer_inst = ComponentInstance(store)

  eager_ft = FuncType([], [U8Type()])
  def core_eager_producer(task, args):
    assert(len(args) == 0)
    [] = canon_task_return(task, [U8Type()], producer_opts, [43])
    return []
  eager_callee = partial(canon_lift, producer_opts, producer_inst, eager_ft, core_eager_producer)

  toggle_ft = FuncType([], [])
  fut1_1 = RacyBool(False)
  fut1_2 = RacyBool(False)
  def core_toggle(task, args):
    assert(len(args) == 0)
    [] = canon_backpressure_inc(task)
    task.thread.suspend_until(fut1_1.is_set)
    [] = canon_task_return(task, [], producer_opts, [])
    task.thread.suspend_until(fut1_2.is_set)
    [] = canon_backpressure_dec(task)
    return []
  toggle_callee = partial(canon_lift, producer_opts, producer_inst, toggle_ft, core_toggle)

  fut2, fut3, fut4 = RacyBool(False), RacyBool(False), RacyBool(False)
  blocking_ft = FuncType([U8Type()], [U8Type()])
  def core_blocking_producer(task, args):
    [x] = args
    assert(x == 83)
    task.thread.suspend_until(fut2.is_set)
    [] = canon_task_return(task, [U8Type()], producer_opts, [44])
    task.thread.suspend_until(fut3.is_set)
    fut4.set()
    return []
  blocking_callee = partial(canon_lift, producer_opts, producer_inst, blocking_ft, core_blocking_producer)

  consumer_heap = Heap(20)
  consumer_opts = mk_opts(consumer_heap.memory)
  consumer_opts.sync = False

  def consumer(task, args):
    [b] = args
    [seti] = canon_waitable_set_new(task)
    ptr = consumer_heap.realloc(0, 0, 1, 1)
    [ret] = canon_lower(consumer_opts, eager_ft, eager_callee, task, [ptr])
    assert(ret == Subtask.State.RETURNED)
    u8 = consumer_heap.memory[ptr]
    assert(u8 == 43)
    [ret] = canon_lower(consumer_opts, toggle_ft, toggle_callee, task, [])
    state,subi1 = unpack_result(ret)
    assert(subi1 == 2)
    assert(state == Subtask.State.STARTED)
    [] = canon_waitable_join(task, subi1, seti)
    retp = ptr
    consumer_heap.memory[retp] = 13
    [ret] = canon_lower(consumer_opts, blocking_ft, blocking_callee, task, [83, retp])
    state,subi2 = unpack_result(ret)
    assert(subi2 == 3)
    assert(state == Subtask.State.STARTING)
    assert(consumer_heap.memory[retp] == 13)
    [] = canon_waitable_join(task, subi2, seti)
    fut1_1.set()

    waitretp = consumer_heap.realloc(0, 0, 8, 4)
    [event] = canon_waitable_set_wait(True, consumer_heap.memory, task, seti, waitretp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_heap.memory[waitretp] == subi1)
    assert(consumer_heap.memory[waitretp+4] == Subtask.State.RETURNED)
    [] = canon_subtask_drop(task, subi1)
    fut1_2.set()

    [event] = canon_waitable_set_wait(True, consumer_heap.memory, task, seti, waitretp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_heap.memory[waitretp] == subi2)
    assert(consumer_heap.memory[waitretp+4] == Subtask.State.STARTED)
    assert(consumer_heap.memory[retp] == 13)
    fut2.set()

    [event] = canon_waitable_set_wait(True, consumer_heap.memory, task, seti, waitretp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_heap.memory[waitretp] == subi2)
    assert(consumer_heap.memory[waitretp+4] == Subtask.State.RETURNED)
    assert(consumer_heap.memory[retp] == 44)
    [] = canon_subtask_drop(task, subi2)
    fut3.set()
    task.thread.suspend_until(fut4.is_set)

    dtor_fut = RacyBool(False)
    dtor_value = None
    def dtor(task, args):
      nonlocal dtor_value
      assert(len(args) == 1)
      task.thread.suspend_until(dtor_fut.is_set)
      dtor_value = args[0]
      return []
    rt = ResourceType(producer_inst, dtor)

    [resi] = canon_resource_new(rt, task, 50)
    assert(resi == 3)
    assert(dtor_value is None)
    [ret] = canon_resource_drop(rt, False, task, resi)
    state,dtorsubi = unpack_result(ret)
    assert(dtorsubi == 3)
    assert(state == Subtask.State.STARTED)
    assert(dtor_value is None)
    dtor_fut.set()

    [] = canon_waitable_join(task, dtorsubi, seti)
    [event] = canon_waitable_set_wait(True, consumer_heap.memory, task, seti, waitretp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_heap.memory[waitretp] == dtorsubi)
    assert(consumer_heap.memory[waitretp+4] == Subtask.State.RETURNED)
    assert(dtor_value == 50)
    [] = canon_subtask_drop(task, dtorsubi)
    [] = canon_waitable_set_drop(task, seti)

    [] = canon_task_return(task, [U8Type()], consumer_opts, [42])
    return []

  ft = FuncType([BoolType()],[U8Type()])

  def on_start():
    return [ True ]

  got = None
  def on_resolve(results):
    nonlocal got
    got = results

  consumer_inst = ComponentInstance(store)
  run_lift(consumer_opts, consumer_inst, ft, consumer, on_start, on_resolve)
  assert(len(got) == 1)
  assert(got[0] == 42)


def test_async_callback():
  store = Store()
  producer_inst = ComponentInstance(store)
  producer_opts = mk_opts()
  producer_opts.sync = False
  producer_ft = FuncType([], [])

  def core_producer_pre(fut, task, args):
    assert(len(args) == 0)
    task.thread.suspend_until(fut.is_set)
    canon_task_return(task, [], producer_opts, [])
    return []
  fut1 = RacyBool(False)
  core_producer1 = partial(core_producer_pre, fut1)
  producer1 = partial(canon_lift, producer_opts, producer_inst, producer_ft, core_producer1)
  fut2 = RacyBool(False)
  core_producer2 = partial(core_producer_pre, fut2)
  producer2 = partial(canon_lift, producer_opts, producer_inst, producer_ft, core_producer2)

  consumer_ft = FuncType([],[U32Type()])
  seti = 0
  def consumer(task, args):
    assert(len(args) == 0)

    [ret] = canon_lower(opts, producer_ft, producer1, task, [])
    state,subi1 = unpack_result(ret)
    assert(subi1 == 1)
    assert(state == Subtask.State.STARTED)

    [ret] = canon_lower(opts, producer_ft, producer2, task, [])
    state,subi2 = unpack_result(ret)
    assert(subi2 == 2)
    assert(state == Subtask.State.STARTED)

    nonlocal seti
    [seti] = canon_waitable_set_new(task)
    assert(seti == 3)
    [] = canon_waitable_join(task, subi1, seti)
    [] = canon_waitable_join(task, subi2, seti)

    fut1.set()
    [] = canon_context_set('i32', 0, task, 42)
    return [definitions.CallbackCode.WAIT|(seti << 4)]

  def callback(task, args):
    assert(len(args) == 3)
    [ctx] = canon_context_get('i32', 0, task)
    match ctx:
      case 42:
        assert(args[0] == EventCode.SUBTASK)
        assert(args[1] == 1)
        assert(args[2] == Subtask.State.RETURNED)
        canon_subtask_drop(task, 1)
        [] = canon_context_set('i32', 0, task, 52)
        return [definitions.CallbackCode.YIELD]
      case 52:
        assert(args[0] == EventCode.NONE)
        assert(args[1] == 0)
        assert(args[2] == 0)
        fut2.set()
        [] = canon_context_set('i32', 0, task, 62)
        return [definitions.CallbackCode.WAIT | (seti << 4)]
      case 62:
        assert(args[0] == EventCode.SUBTASK)
        assert(args[1] == 2)
        assert(args[2] == Subtask.State.RETURNED)
        canon_subtask_drop(task, 2)
        [] = canon_task_return(task, [U32Type()], opts, [83])
        return [definitions.CallbackCode.EXIT]
      case _:
        assert(False)

  consumer_inst = ComponentInstance(store)
  def on_start(): return []

  got = None
  def on_resolve(results):
    nonlocal got
    got = results

  opts = mk_opts()
  opts.sync = False
  opts.callback = callback

  run_lift(opts, consumer_inst, consumer_ft, consumer, on_start, on_resolve)
  assert(got[0] == 83)


def test_callback_interleaving():
  store = Store()
  producer_inst = ComponentInstance(store)
  producer_ft = FuncType([U32Type(), FutureType(None),FutureType(None),FutureType(None)],[U32Type()])
  fut3s = [None,None]
  def core_producer(task, args):
    [i,fut1,fut2,fut3] = args
    fut3s[i] = fut3

    [] = canon_context_set('i32', 0, task, i)

    sync_opts = mk_opts()
    [ret] = canon_future_read(FutureType(None), sync_opts, task, fut1, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    [seti] = canon_waitable_set_new(task)

    async_opts = mk_opts(sync = False)
    [ret] = canon_future_read(FutureType(None), async_opts, task, fut2, 0xdeadbeef)
    assert(ret == definitions.BLOCKED)

    [] = canon_waitable_join(task, fut2, seti)
    return [CallbackCode.WAIT|(seti << 4)]

  def core_producer_callback(task, args):
    [event,payload1,payload2] = args
    assert(event == EventCode.FUTURE_READ)
    assert(payload2 == CopyResult.COMPLETED)

    [i] = canon_context_get('i32', 0, task)
    [] = canon_task_return(task, [U32Type()], mk_opts(), [42 + i])

    fut3 = fut3s[i]
    sync_opts = mk_opts()
    [ret] = canon_future_read(FutureType(None), sync_opts, task, fut3, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    return [CallbackCode.EXIT]
  producer_opts = mk_opts()
  producer_opts.sync = False
  producer_opts.callback = core_producer_callback
  producer_callee = partial(canon_lift, producer_opts, producer_inst, producer_ft, core_producer)

  sync_callee_ft = FuncType([], [U32Type()])
  def core_sync_callee(task, args):
    assert(len(args) == 0)
    return [100]
  sync_callee_opts = mk_opts()
  sync_callee = partial(canon_lift, sync_callee_opts, producer_inst, sync_callee_ft, core_sync_callee)

  consumer_inst = ComponentInstance(store)
  consumer_ft = FuncType([], [])
  consumer_mem = bytearray(24)
  consumer_opts = mk_opts(consumer_mem, sync = False)
  def core_consumer(task, args):
    assert(len(args) == 0)

    [packed] = canon_future_new(FutureType(None), task)
    rfut11,wfut11 = unpack_new_ends(packed)
    [packed] = canon_future_new(FutureType(None), task)
    rfut12,wfut12 = unpack_new_ends(packed)
    [packed] = canon_future_new(FutureType(None), task)
    rfut13,wfut13 = unpack_new_ends(packed)
    [packed] = canon_future_new(FutureType(None), task)
    rfut21,wfut21 = unpack_new_ends(packed)
    [packed] = canon_future_new(FutureType(None), task)
    rfut22,wfut22 = unpack_new_ends(packed)
    [packed] = canon_future_new(FutureType(None), task)
    rfut23,wfut23 = unpack_new_ends(packed)

    producer_inst.backpressure = True
    [ret] = canon_lower(consumer_opts, producer_ft, producer_callee, task, [0, rfut11, rfut12, rfut13, 0xdeadbeef])
    state,todie = unpack_result(ret)
    assert(state == Subtask.State.STARTING)
    [ret] = canon_subtask_cancel(True, task, todie)
    assert(ret == Subtask.State.CANCELLED_BEFORE_STARTED)
    producer_inst.backpressure = False

    subi1ret = 12
    [ret] = canon_lower(consumer_opts, producer_ft, producer_callee, task, [0, rfut11, rfut12, rfut13, subi1ret])
    state,subi1 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)

    [ret] = canon_lower(consumer_opts, producer_ft, producer_callee, task, [1, rfut21, rfut22, rfut23, 0xdeadbeef])
    state,todie = unpack_result(ret)
    assert(state == Subtask.State.STARTING)

    [ret] = canon_subtask_cancel(True, task, todie)
    assert(ret == Subtask.State.CANCELLED_BEFORE_STARTED)

    subi2ret = 16
    [ret] = canon_lower(consumer_opts, producer_ft, producer_callee, task, [1, rfut21, rfut22, rfut23, subi2ret])
    state,subi2 = unpack_result(ret)
    assert(state == Subtask.State.STARTING)

    [seti] = canon_waitable_set_new(task)
    [] = canon_waitable_join(task, subi1, seti)
    [] = canon_waitable_join(task, subi2, seti)

    [ret] = canon_future_write(FutureType(None), consumer_opts, task, wfut11, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    retp = 0
    [event] = canon_waitable_set_wait(True, consumer_mem, task, seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_mem[retp+0] == subi2)
    assert(consumer_mem[retp+4] == Subtask.State.STARTED)

    [ret] = canon_future_write(FutureType(None), consumer_opts, task, wfut12, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    for i in range(10):
      [ret] = canon_yield(True, task)
      assert(ret == 0)
      retp = 0
      [ret] = canon_waitable_set_poll(True, consumer_mem, task, seti, retp)
      assert(ret == EventCode.NONE)

    [ret] = canon_future_write(FutureType(None), consumer_opts, task, wfut21, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    retp = 0
    [event] = canon_waitable_set_wait(True, consumer_mem, task, seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_mem[retp+0] == subi1)
    assert(consumer_mem[retp+4] == Subtask.State.RETURNED)
    assert(consumer_mem[subi1ret] == 42)
    [] = canon_subtask_drop(task, subi1)

    [ret] = canon_future_write(FutureType(None), consumer_opts, task, wfut22, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    for i in range(10):
      [ret] = canon_yield(True, task)
      assert(ret == 0)
      retp = 0
      [ret] = canon_waitable_set_poll(True, consumer_mem, task, seti, retp)
      assert(ret == EventCode.NONE)

    [ret] = canon_future_write(FutureType(None), consumer_opts, task, wfut13, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    retp = 0
    [event] = canon_waitable_set_wait(True, consumer_mem, task, seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_mem[retp+0] == subi2)
    assert(consumer_mem[retp+4] == Subtask.State.RETURNED)
    assert(consumer_mem[subi2ret] == 43)
    [] = canon_subtask_drop(task, subi2)

    subi3ret = 20
    [ret] = canon_lower(consumer_opts, sync_callee_ft, sync_callee, task, [subi3ret])
    state,subi3 = unpack_result(ret)
    assert(state == Subtask.State.STARTING)
    [] = canon_waitable_join(task, subi3, seti)

    [ret] = canon_future_write(FutureType(None), consumer_opts, task, wfut23, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    retp = 0
    [event] = canon_waitable_set_wait(True, consumer_mem, task, seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_mem[retp+0] == subi3)
    assert(consumer_mem[retp+4] == Subtask.State.RETURNED)
    assert(consumer_mem[subi3ret] == 100)

    return []

  run_lift(mk_opts(), consumer_inst, consumer_ft, core_consumer, lambda:[], lambda _:())


def test_async_to_sync():
  store = Store()
  producer_opts = CanonicalOptions()
  producer_inst = ComponentInstance(store)

  producer_ft = FuncType([],[])
  fut = RacyBool(False)
  producer1_done = False
  def producer1_core(task, args):
    nonlocal producer1_done
    assert(len(args) == 0)
    task.thread.suspend_until(fut.is_set)
    producer1_done = True
    return []

  producer2_done = False
  def producer2_core(task, args):
    nonlocal producer2_done
    assert(len(args) == 0)
    assert(producer1_done == True)
    producer2_done = True
    return []

  producer1 = partial(canon_lift, producer_opts, producer_inst, producer_ft, producer1_core)
  producer2 = partial(canon_lift, producer_opts, producer_inst, producer_ft, producer2_core)

  consumer_heap = Heap(20)
  consumer_opts = mk_opts(consumer_heap.memory)
  consumer_opts.sync = False

  consumer_ft = FuncType([],[U8Type()])
  def consumer(task, args):
    assert(len(args) == 0)

    [ret] = canon_lower(consumer_opts, producer_ft, producer1, task, [])
    state,subi1 = unpack_result(ret)
    assert(subi1 == 1)
    assert(state == Subtask.State.STARTED)

    [ret] = canon_lower(consumer_opts, producer_ft, producer2, task, [])
    state,subi2 = unpack_result(ret)
    assert(subi2 == 2)
    assert(state == Subtask.State.STARTING)

    [seti] = canon_waitable_set_new(task)
    [] = canon_waitable_join(task, subi1, seti)
    [] = canon_waitable_join(task, subi2, seti)

    fut.set()
    assert(producer1_done == False)
    assert(producer2_done == False)

    remain = [subi1, subi2]
    while remain:
      retp = 8
      [event] = canon_waitable_set_poll(True, consumer_heap.memory, task, seti, retp)
      if event == EventCode.NONE:
        continue
      assert(event == EventCode.SUBTASK)
      assert(consumer_heap.memory[retp+4] == Subtask.State.RETURNED)
      subi = consumer_heap.memory[retp]
      remain.remove(subi)
      canon_subtask_drop(task, subi)

    assert(producer1_done == True)
    assert(producer2_done == True)

    [] = canon_waitable_set_drop(task, seti)

    canon_task_return(task, [U8Type()], consumer_opts, [83])
    return []

  consumer_inst = ComponentInstance(store)
  def on_start(): return []

  got = None
  def on_resolve(results):
    nonlocal got
    got = results

  run_lift(consumer_opts, consumer_inst, consumer_ft, consumer, on_start, on_resolve)
  assert(got[0] == 83)


def test_async_backpressure():
  store = Store()
  producer_opts = CanonicalOptions()
  producer_opts.sync = False
  producer_inst = ComponentInstance(store)

  producer_ft = FuncType([],[])
  fut = RacyBool(False)
  producer1_done = False
  def producer1_core(task, args):
    nonlocal producer1_done
    canon_backpressure_inc(task)
    task.thread.suspend_until(fut.is_set)
    canon_backpressure_dec(task)
    canon_task_return(task, [], producer_opts, [])
    producer1_done = True
    return []

  producer2_done = False
  def producer2_core(task, args):
    nonlocal producer2_done
    assert(producer1_done == True)
    canon_task_return(task, [], producer_opts, [])
    producer2_done = True
    return []

  producer1 = partial(canon_lift, producer_opts, producer_inst, producer_ft, producer1_core)
  producer2 = partial(canon_lift, producer_opts, producer_inst, producer_ft, producer2_core)

  consumer_heap = Heap(20)
  consumer_opts = mk_opts(consumer_heap.memory, sync = False)

  consumer_ft = FuncType([],[U8Type()])
  def consumer(task, args):
    assert(len(args) == 0)

    [ret] = canon_lower(consumer_opts, producer_ft, producer1, task, [])
    state,subi1 = unpack_result(ret)
    assert(subi1 == 1)
    assert(state == Subtask.State.STARTED)

    [ret] = canon_lower(consumer_opts, producer_ft, producer2, task, [])
    state,subi2 = unpack_result(ret)
    assert(subi2 == 2)
    assert(state == Subtask.State.STARTING)

    [seti] = canon_waitable_set_new(task)
    [] = canon_waitable_join(task, subi1, seti)
    [] = canon_waitable_join(task, subi2, seti)

    fut.set()
    assert(producer1_done == False)
    assert(producer2_done == False)

    remain = [subi1, subi2]
    while remain:
      retp = 8
      [event] = canon_waitable_set_wait(True, consumer_heap.memory, task, seti, retp)
      assert(event == EventCode.SUBTASK)
      assert(consumer_heap.memory[retp+4] == Subtask.State.RETURNED)
      subi = consumer_heap.memory[retp]
      remain.remove(subi)
      canon_subtask_drop(task, subi)

    assert(producer1_done == True)
    assert(producer2_done == True)

    [] = canon_waitable_set_drop(task, seti)

    canon_task_return(task, [U8Type()], consumer_opts, [84])
    return []

  consumer_inst = ComponentInstance(store)
  def on_start(): return []

  got = None
  def on_resolve(results):
    nonlocal got
    got = results

  run_lift(consumer_opts, consumer_inst, consumer_ft, consumer, on_start, on_resolve)
  assert(got[0] == 84)


def test_sync_using_wait():
  store = Store()
  hostcall_opts = mk_opts()
  hostcall_opts.sync = False
  hostcall_inst = ComponentInstance(store)
  ft = FuncType([], [])

  def core_hostcall_pre(fut, task, args):
    task.thread.suspend_until(fut.is_set)
    [] = canon_task_return(task, [], hostcall_opts, [])
    return []
  fut1 = RacyBool(False)
  core_hostcall1 = partial(core_hostcall_pre, fut1)
  hostcall1 = partial(canon_lift, hostcall_opts, hostcall_inst, ft, core_hostcall1)
  fut2 = RacyBool(False)
  core_hostcall2 = partial(core_hostcall_pre, fut2)
  hostcall2 = partial(canon_lift, hostcall_opts, hostcall_inst, ft, core_hostcall2)

  lower_heap = Heap(20)
  lower_opts = mk_opts(lower_heap.memory)
  lower_opts.sync = False

  def core_func(task, args):
    [ret] = canon_lower(lower_opts, ft, hostcall1, task, [])
    state,subi1 = unpack_result(ret)
    assert(subi1 == 1)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_lower(lower_opts, ft, hostcall2, task, [])
    state,subi2 = unpack_result(ret)
    assert(subi2 == 2)
    assert(state == Subtask.State.STARTED)

    [seti] = canon_waitable_set_new(task)
    [] = canon_waitable_join(task, subi1, seti)
    [] = canon_waitable_join(task, subi2, seti)

    fut1.set()

    retp = lower_heap.realloc(0,0,8,4)
    [event] = canon_waitable_set_wait(True, lower_heap.memory, task, seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(lower_heap.memory[retp] == subi1)
    assert(lower_heap.memory[retp+4] == Subtask.State.RETURNED)

    fut2.set()

    [event] = canon_waitable_set_wait(True, lower_heap.memory, task, seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(lower_heap.memory[retp] == subi2)
    assert(lower_heap.memory[retp+4] == Subtask.State.RETURNED)

    canon_subtask_drop(task, subi1)
    canon_subtask_drop(task, subi2)
    canon_waitable_set_drop(task, seti)

    return []

  inst = ComponentInstance(store)
  def on_start(): return []
  def on_resolve(results): pass
  run_lift(mk_opts(), inst, ft, core_func, on_start, on_resolve)


class HostSource(ReadableStream):
  remaining: list[int]
  destroy_if_empty: bool
  chunk: int
  cancel_lock: Optional[threading.Lock]
  cancelled_lock: Optional[threading.Lock]
  pending_dst: Optional[WritableBuffer]
  pending_on_copy: Optional[OnCopy]
  pending_on_copy_done: Optional[OnCopyDone]

  def __init__(self, t, contents, chunk, destroy_if_empty = True):
    self.t = t
    self.remaining = contents
    self.destroy_if_empty = destroy_if_empty
    self.chunk = chunk
    self.cancel_lock = None
    self.cancelled_lock = None
    self.reset_pending()
  def reset_pending(self):
    self.pending_dst = None
    self.pending_on_copy = None
    self.pending_on_copy_done = None

  def closed(self):
    return not self.remaining and self.destroy_if_empty

  def drop(self):
    self.remaining = []
    self.destroy_if_empty = True
    if self.pending_dst:
      self.pending_on_copy_done(CopyResult.DROPPED)
      self.reset_pending()

  def destroy_once_empty(self):
    self.destroy_if_empty = True
    if not self.remaining:
      self.drop()

  def read(self, inst, dst, on_copy, on_copy_done):
    if self.closed():
      on_copy_done(CopyResult.DROPPED)
    elif self.remaining:
      self.actually_copy(dst)
      if self.closed():
        on_copy_done(CopyResult.DROPPED)
      else:
        on_copy_done(CopyResult.COMPLETED)
    else:
      self.pending_dst = dst
      self.pending_on_copy = on_copy
      self.pending_on_copy_done = on_copy_done

  def actually_copy(self, dst):
    n = min(dst.remain(), len(self.remaining), self.chunk)
    dst.write(self.remaining[:n])
    del self.remaining[:n]

  def block_cancel(self):
    self.cancel_lock = threading.Lock()
    self.cancel_lock.acquire()
    self.cancelled_lock = threading.Lock()
    self.cancelled_lock.acquire()

  def unblock_cancel(self):
    self.cancel_lock.release()
    self.cancelled_lock.acquire()

  def cancel(self):
    if not self.cancel_lock:
      self.actually_cancel()
    else:
      def async_cancel():
        self.cancel_lock.acquire()
        self.actually_cancel()
        self.cancelled_lock.release()
      threading.Thread(target = async_cancel).start()

  def actually_cancel(self):
    self.pending_on_copy_done(CopyResult.CANCELLED)
    self.reset_pending()

  def write(self, vs):
    assert(vs and not self.closed())
    self.remaining += vs
    if self.pending_dst:
      self.actually_copy(self.pending_dst)
      if self.pending_dst.remain():
        self.pending_on_copy(self.reset_pending)
      else:
        self.pending_on_copy_done(CopyResult.COMPLETED)
        self.reset_pending()

class HostSink:
  shared: ReadableStream
  t: ValType
  received: list[int]
  chunk: int
  write_remain: int
  write_event: threading.Event
  ready_to_consume: bool
  closed: bool

  def __init__(self, shared, chunk, remain = 2**64):
    self.shared = shared
    self.t = shared.t
    self.received = []
    self.chunk = chunk
    self.write_remain = remain
    self.write_event = threading.Event()
    if remain:
      self.write_event.set()
    self.ready_to_consume = threading.Event()
    self.closed = False
    def read_all():
      while True:
        self.write_event.wait()
        copy_event = threading.Event()
        def on_copy(reclaim_buffer):
          reclaim_buffer()
          copy_event.set()
        def on_copy_done(result):
          if result == CopyResult.DROPPED:
            self.closed = True
          copy_event.set()
        self.shared.read(None, self, on_copy, on_copy_done)
        copy_event.wait()
        if self.closed:
          break
      self.ready_to_consume.set()
    threading.Thread(target = read_all).start()

  def set_remain(self, n):
    self.write_remain = n
    if self.write_remain > 0:
      self.write_event.set()

  def remain(self):
    return self.write_remain

  def write(self, vs):
    self.received += vs
    self.ready_to_consume.set()
    self.write_remain -= len(vs)
    if self.write_remain == 0:
      self.write_event.clear()

  def consume(self, n):
    while n > len(self.received):
      if self.closed:
        return None
      self.ready_to_consume.clear()
      self.ready_to_consume.wait()
    ret = self.received[:n];
    del self.received[:n]
    return ret

def test_eager_stream_completion():
  store = Store()
  ft = FuncType([StreamType(U8Type())], [StreamType(U8Type())])
  inst = ComponentInstance(store)
  mem = bytearray(20)
  opts = mk_opts(memory=mem, sync=False)
  sync_opts = mk_opts(memory=mem, sync=True)

  def host_import(caller, on_start, on_resolve):
    args = on_start()
    assert(len(args) == 1)
    assert(isinstance(args[0], ReadableStream))
    incoming = HostSink(args[0], chunk=4)
    outgoing = HostSource(U8Type(), [], chunk=4, destroy_if_empty=False)
    on_resolve([outgoing])
    def add10():
      while (vs := incoming.consume(4)):
        for i in range(len(vs)):
          vs[i] += 10
        outgoing.write(vs)
      outgoing.drop()
    threading.Thread(target = add10).start()
    return mk_done_task(caller)

  src_stream = HostSource(U8Type(), [1,2,3,4,5,6,7,8], chunk=4)
  def on_start():
    return [src_stream]

  dst_stream = None
  def on_resolve(results):
    assert(len(results) == 1)
    nonlocal dst_stream
    dst_stream = HostSink(results[0], chunk=4)

  def core_func(task, args):
    assert(len(args) == 1)
    rsi1 = args[0]
    assert(rsi1 == 1)
    [packed] = canon_stream_new(StreamType(U8Type()), task)
    rsi2,wsi2 = unpack_new_ends(packed)
    [] = canon_task_return(task, [StreamType(U8Type())], opts, [rsi2])
    [ret] = canon_stream_read(StreamType(U8Type()), opts, task, rsi1, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    assert(mem[0:4] == b'\x01\x02\x03\x04')
    [packed] = canon_stream_new(StreamType(U8Type()), task)
    rsi3,wsi3 = unpack_new_ends(packed)
    retp = 12
    [ret] = canon_lower(opts, ft, host_import, task, [rsi3, retp])
    assert(ret == Subtask.State.RETURNED)
    rsi4 = mem[retp]
    [ret] = canon_stream_write(StreamType(U8Type()), opts, task, wsi3, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(U8Type()), sync_opts, task, rsi4, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, task, wsi2, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(U8Type()), opts, task, rsi1, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.DROPPED)
    assert(mem[0:4] == b'\x05\x06\x07\x08')
    [ret] = canon_stream_write(StreamType(U8Type()), sync_opts, task, wsi3, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(U8Type()), sync_opts, task, rsi4, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_write(StreamType(U8Type()), sync_opts, task, wsi2, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_readable(StreamType(U8Type()), task, rsi1)
    [] = canon_stream_drop_readable(StreamType(U8Type()), task, rsi4)
    [] = canon_stream_drop_writable(StreamType(U8Type()), task, wsi2)
    [] = canon_stream_drop_writable(StreamType(U8Type()), task, wsi3)
    return []

  run_lift(opts, inst, ft, core_func, on_start, on_resolve)
  assert(dst_stream.received == [11,12,13,14,15,16,17,18])


def test_async_stream_ops():
  store = Store()
  ft = FuncType([StreamType(U8Type())], [StreamType(U8Type())])
  inst = ComponentInstance(store)
  mem = bytearray(24)
  opts = mk_opts(memory=mem, sync=False)
  sync_opts = mk_opts(memory=mem, sync=True)

  host_import_incoming = None
  host_import_outgoing = None
  def host_import(caller, on_start, on_resolve):
    def thread_func(task):
      nonlocal host_import_incoming, host_import_outgoing
      args = on_start()
      assert(len(args) == 1)
      assert(isinstance(args[0], ReadableStream))
      host_import_incoming = HostSink(args[0], chunk=4, remain = 0)
      host_import_outgoing = HostSource(U8Type(), [], chunk=4, destroy_if_empty=False)
      task.return_([host_import_outgoing])
      while True:
        vs = None
        results_ready = RacyBool(False)
        def consume_results():
          nonlocal vs
          vs = host_import_incoming.consume(4)
          results_ready.set()
        threading.Thread(target = consume_results).start()
        task.thread.suspend_until(results_ready.is_set)
        if vs:
          for i in range(len(vs)):
            vs[i] += 10
        else:
          break
        host_import_outgoing.write(vs)
      host_import_outgoing.destroy_once_empty()

    return mk_task(caller, on_resolve, thread_func)

  src_stream = HostSource(U8Type(), [], chunk=4, destroy_if_empty = False)
  def on_start():
    return [src_stream]

  dst_stream = None
  def on_resolve(results):
    assert(len(results) == 1)
    nonlocal dst_stream
    dst_stream = HostSink(results[0], chunk=4, remain = 0)

  def core_func(task, args):
    [rsi1] = args
    assert(rsi1 == 1)
    [packed] = canon_stream_new(StreamType(U8Type()), task)
    rsi2,wsi2 = unpack_new_ends(packed)
    [] = canon_task_return(task, [StreamType(U8Type())], opts, [rsi2])
    [ret] = canon_stream_read(StreamType(U8Type()), opts, task, rsi1, 0, 4)
    assert(ret == definitions.BLOCKED)
    src_stream.write([1,2,3,4])
    retp = 16
    [seti] = canon_waitable_set_new(task)
    [] = canon_waitable_join(task, rsi1, seti)
    definitions.throw_it = True
    [event] = canon_waitable_set_wait(True, mem, task, seti, retp)
    assert(event == EventCode.STREAM_READ)
    assert(mem[retp+0] == rsi1)
    result,n = unpack_result(mem[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)
    assert(mem[0:4] == b'\x01\x02\x03\x04')
    [packed] = canon_stream_new(StreamType(U8Type()), task)
    rsi3,wsi3 = unpack_new_ends(packed)
    [ret] = canon_lower(opts, ft, host_import, task, [rsi3, retp])
    assert(ret == Subtask.State.RETURNED)
    rsi4 = mem[16]
    assert(rsi4 == 4)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, task, wsi3, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_import_incoming.set_remain(100)
    [] = canon_waitable_join(task, wsi3, seti)
    [event] = canon_waitable_set_wait(True, mem, task, seti, retp)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem[retp+0] == wsi3)
    result,n = unpack_result(mem[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(U8Type()), sync_opts, task, rsi4, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, task, wsi2, 0, 4)
    assert(ret == definitions.BLOCKED)
    dst_stream.set_remain(100)
    [] = canon_waitable_join(task, wsi2, seti)
    [event] = canon_waitable_set_wait(True, mem, task, seti, retp)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem[retp+0] == wsi2)
    result,n = unpack_result(mem[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)
    src_stream.write([5,6,7,8])
    src_stream.destroy_once_empty()
    [ret] = canon_stream_read(StreamType(U8Type()), opts, task, rsi1, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.DROPPED)
    [] = canon_stream_drop_readable(StreamType(U8Type()), task, rsi1)
    assert(mem[0:4] == b'\x05\x06\x07\x08')
    [ret] = canon_stream_write(StreamType(U8Type()), opts, task, wsi3, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_writable(StreamType(U8Type()), task, wsi3)
    [ret] = canon_stream_read(StreamType(U8Type()), opts, task, rsi4, 0, 4)
    assert(ret == definitions.BLOCKED)
    [] = canon_waitable_join(task, rsi4, seti)
    [event] = canon_waitable_set_wait(True, mem, task, seti, retp)
    assert(event == EventCode.STREAM_READ)
    assert(mem[retp+0] == rsi4)
    result,n = unpack_result(mem[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(U8Type()), sync_opts, task, rsi4, 0, 4)
    assert(ret == CopyResult.DROPPED)
    [] = canon_stream_drop_readable(StreamType(U8Type()), task, rsi4)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, task, wsi2, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_writable(StreamType(U8Type()), task, wsi2)
    [] = canon_waitable_set_drop(task, seti)
    return []

  run_lift(opts, inst, ft, core_func, on_start, on_resolve)
  assert(dst_stream.received == [11,12,13,14,15,16,17,18])


def test_stream_forward():
  src_stream = HostSource(U8Type(), [1,2,3,4], chunk=4)
  def on_start():
    return [src_stream]

  dst_stream = None
  def on_resolve(results):
    assert(len(results) == 1)
    nonlocal dst_stream
    dst_stream = results[0]

  def core_func(task, args):
    assert(len(args) == 1)
    rsi1 = args[0]
    assert(rsi1 == 1)
    return [rsi1]

  opts = mk_opts()
  inst = ComponentInstance(Store())
  ft = FuncType([StreamType(U8Type())], [StreamType(U8Type())])
  run_lift(opts, inst, ft, core_func, on_start, on_resolve)
  assert(src_stream is dst_stream)


def test_receive_own_stream():
  store = Store()
  inst = ComponentInstance(store)
  mem = bytearray(20)
  opts = mk_opts(memory=mem, sync=False)

  host_ft = FuncType([StreamType(U8Type())], [StreamType(U8Type())])
  def host_import(caller, on_start, on_resolve):
    args = on_start()
    assert(len(args) == 1)
    assert(isinstance(args[0], ReadableStream))
    on_resolve(args)
    return mk_done_task(caller)

  def core_func(task, args):
    assert(len(args) == 0)
    [packed] = canon_stream_new(StreamType(U8Type()), task)
    rsi,wsi = unpack_new_ends(packed)
    assert(rsi == 1)
    assert(wsi == 2)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, task, wsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    retp = 8
    [ret] = canon_lower(opts, host_ft, host_import, task, [rsi, retp])
    assert(ret == Subtask.State.RETURNED)
    rsi2 = int.from_bytes(mem[retp : retp+4], 'little', signed=False)
    assert(rsi2 == 1)
    try:
      canon_stream_cancel_write(StreamType(U8Type()), True, task, wsi)
    except Trap:
      pass
    [] = canon_stream_drop_writable(StreamType(U8Type()), task, wsi)
    return []

  def on_start(): return []
  def on_resolve(results): assert(len(results) == 0)
  ft = FuncType([],[])
  run_lift(mk_opts(), inst, ft, core_func, on_start, on_resolve)


def test_host_partial_reads_writes():
  mem = bytearray(20)
  opts = mk_opts(memory=mem, sync=False)

  src = HostSource(U8Type(), [1,2,3,4], chunk=2, destroy_if_empty = False)
  source_ft = FuncType([], [StreamType(U8Type())])
  def host_source(caller, on_start, on_resolve):
    [] = on_start()
    on_resolve([src])
    return mk_done_task(caller)

  dst = None
  sink_ft = FuncType([StreamType(U8Type())], [])
  def host_sink(caller, on_start, on_resolve):
    nonlocal dst
    [s] = on_start()
    dst = HostSink(s, chunk=1, remain=2)
    on_resolve([])
    return mk_done_task(caller)

  def core_func(task, args):
    assert(len(args) == 0)
    retp = 4
    [ret] = canon_lower(opts, source_ft, host_source, task, [retp])
    assert(ret == Subtask.State.RETURNED)
    rsi = mem[retp]
    assert(rsi == 1)
    [ret] = canon_stream_read(StreamType(U8Type()), opts, task, rsi, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    assert(mem[0:2] == b'\x01\x02')
    [ret] = canon_stream_read(StreamType(U8Type()), opts, task, rsi, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    assert(mem[0:2] == b'\x03\x04')
    [ret] = canon_stream_read(StreamType(U8Type()), opts, task, rsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    src.write([5,6])

    [seti] = canon_waitable_set_new(task)
    [] = canon_waitable_join(task, rsi, seti)
    [event] = canon_waitable_set_wait(True, mem, task, seti, retp)
    assert(event == EventCode.STREAM_READ)
    assert(mem[retp+0] == rsi)
    result,n = unpack_result(mem[retp+4])
    assert(n == 2 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_readable(StreamType(U8Type()), task, rsi)

    [packed] = canon_stream_new(StreamType(U8Type()), task)
    rsi,wsi = unpack_new_ends(packed)
    assert(rsi == 1)
    assert(wsi == 3)
    [ret] = canon_lower(opts, sink_ft, host_sink, task, [rsi])
    assert(ret == Subtask.State.RETURNED)
    mem[0:6] = b'\x01\x02\x03\x04\x05\x06'
    [ret] = canon_stream_write(StreamType(U8Type()), opts, task, wsi, 0, 6)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, task, wsi, 2, 4)
    assert(ret == definitions.BLOCKED)
    dst.set_remain(4)
    [] = canon_waitable_join(task, wsi, seti)
    [event] = canon_waitable_set_wait(True, mem, task, seti, retp)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem[retp+0] == wsi)
    result,n = unpack_result(mem[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)
    assert(dst.received == [1,2,3,4,5,6])
    [] = canon_stream_drop_writable(StreamType(U8Type()), task, wsi)
    [] = canon_waitable_set_drop(task, seti)
    dst.set_remain(100)
    assert(dst.consume(100) is None)
    return []

  opts2 = mk_opts()
  inst = ComponentInstance(Store())
  def on_start(): return []
  def on_resolve(results): assert(len(results) == 0)
  ft = FuncType([],[])
  run_lift(opts2, inst, ft, core_func, on_start, on_resolve)


def test_wasm_to_wasm_stream():
  store = Store()
  fut1, fut2, fut3, fut4 = RacyBool(False), RacyBool(False), RacyBool(False), RacyBool(False)

  inst1 = ComponentInstance(store)
  mem1 = bytearray(24)
  opts1 = mk_opts(memory=mem1, sync=False)
  ft1 = FuncType([], [StreamType(U8Type())])
  def core_func1(task, args):
    assert(not args)
    [packed] = canon_stream_new(StreamType(U8Type()), task)
    rsi,wsi = unpack_new_ends(packed)
    [] = canon_task_return(task, [StreamType(U8Type())], opts1, [rsi])

    task.thread.suspend_until(fut1.is_set)

    mem1[0:4] = b'\x01\x02\x03\x04'
    [ret] = canon_stream_write(StreamType(U8Type()), opts1, task, wsi, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_write(StreamType(U8Type()), opts1, task, wsi, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)

    [ret] = canon_stream_write(StreamType(U8Type()), opts1, task, wsi, 0, 0)
    assert(ret == definitions.BLOCKED)
    [ret] = canon_stream_cancel_write(StreamType(U8Type()), False, task, wsi)
    result,n = unpack_result(ret)
    assert(n == 0 and result == CopyResult.CANCELLED)

    task.thread.suspend_until(fut2.is_set)

    mem1[0:8] = b'\x05\x06\x07\x08\x09\x0a\x0b\x0c'
    [ret] = canon_stream_write(StreamType(U8Type()), opts1, task, wsi, 0, 8)
    assert(ret == definitions.BLOCKED)

    fut3.set()

    retp = 16
    [seti] = canon_waitable_set_new(task)
    [] = canon_waitable_join(task, wsi, seti)
    [event] = canon_waitable_set_wait(True, mem1, task, seti, retp)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem1[retp+0] == wsi)
    result,n = unpack_result(mem1[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)

    [ret] = canon_stream_write(StreamType(U8Type()), opts1, task, wsi, 12345, 0)
    assert(ret == definitions.BLOCKED)

    fut4.set()

    [event] = canon_waitable_set_wait(True, mem1, task, seti, retp)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem1[retp+0] == wsi)
    assert(mem1[retp+4] == 0)

    [ret] = canon_stream_write(StreamType(U8Type()), opts1, task, wsi, 12345, 0)
    assert(ret == 0)

    [errctxi] = canon_error_context_new(opts1, task, 0, 0)
    [] = canon_stream_drop_writable(StreamType(U8Type()), task, wsi)
    [] = canon_waitable_set_drop(task, seti)
    [] = canon_error_context_drop(task, errctxi)
    return []

  func1 = partial(canon_lift, opts1, inst1, ft1, core_func1)

  inst2 = ComponentInstance(store)
  heap2 = Heap(24)
  mem2 = heap2.memory
  opts2 = mk_opts(memory=heap2.memory, realloc=heap2.realloc, sync=False)
  ft2 = FuncType([], [])
  def core_func2(task, args):
    assert(not args)
    [] = canon_task_return(task, [], opts2, [])

    retp = 16
    [ret] = canon_lower(opts2, ft1, func1, task, [retp])
    assert(ret == Subtask.State.RETURNED)
    rsi = mem2[retp]
    assert(rsi == 1)

    [ret] = canon_stream_read(StreamType(U8Type()), opts2, task, rsi, 0, 8)
    assert(ret == definitions.BLOCKED)

    fut1.set()

    [seti] = canon_waitable_set_new(task)
    [] = canon_waitable_join(task, rsi, seti)
    [event] = canon_waitable_set_wait(True, mem2, task, seti, retp)
    assert(event == EventCode.STREAM_READ)
    assert(mem2[retp+0] == rsi)
    result,n = unpack_result(mem2[retp+4])
    assert(n == 8 and result == CopyResult.COMPLETED)
    assert(mem2[0:8] == b'\x01\x02\x03\x04\x01\x02\x03\x04')

    fut2.set()
    task.thread.suspend_until(fut3.is_set)

    [ret] = canon_stream_read(StreamType(U8Type()), opts2, task, rsi, 12345, 0)
    assert(ret == 0)

    mem2[0:8] = bytes(8)
    [ret] = canon_stream_read(StreamType(U8Type()), opts2, task, rsi, 0, 2)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    assert(mem2[0:6] == b'\x05\x06\x00\x00\x00\x00')
    [ret] = canon_stream_read(StreamType(U8Type()), opts2, task, rsi, 2, 2)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    assert(mem2[0:6] == b'\x05\x06\x07\x08\x00\x00')

    task.thread.suspend_until(fut4.is_set)

    [ret] = canon_stream_read(StreamType(U8Type()), opts2, task, rsi, 12345, 0)
    assert(ret == definitions.BLOCKED)

    [event] = canon_waitable_set_wait(True, mem2, task, seti, retp)
    assert(event == EventCode.STREAM_READ)
    assert(mem2[retp+0] == rsi)
    p2 = int.from_bytes(mem2[retp+4 : retp+8], 'little', signed=False)
    assert(p2 == (CopyResult.DROPPED | 1))

    [] = canon_stream_drop_readable(StreamType(U8Type()), task, rsi)
    [] = canon_waitable_set_drop(task, seti)
    return []

  run_lift(opts2, inst2, ft2, core_func2, lambda:[], lambda _:())


def test_wasm_to_wasm_stream_empty():
  store = Store()
  fut1, fut2, fut3, fut4 = RacyBool(False), RacyBool(False), RacyBool(False), RacyBool(False)

  inst1 = ComponentInstance(store)
  mem1 = bytearray(24)
  opts1 = mk_opts(memory=mem1, sync=False)
  ft1 = FuncType([], [StreamType(None)])
  def core_func1(task, args):
    assert(not args)
    [packed] = canon_stream_new(StreamType(None), task)
    rsi,wsi = unpack_new_ends(packed)
    [] = canon_task_return(task, [StreamType(None)], opts1, [rsi])

    task.thread.suspend_until(fut1.is_set)

    [ret] = canon_stream_write(StreamType(None), opts1, task, wsi, 10000, 2)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_write(StreamType(None), opts1, task, wsi, 10000, 2)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)

    task.thread.suspend_until(fut2.is_set)

    [ret] = canon_stream_write(StreamType(None), opts1, task, wsi, 0, 8)
    assert(ret == definitions.BLOCKED)

    fut3.set()

    retp = 16
    [seti] = canon_waitable_set_new(task)
    [] = canon_waitable_join(task, wsi, seti)
    [event] = canon_waitable_set_wait(True, mem1, task, seti, retp)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem1[retp+0] == wsi)
    result,n = unpack_result(mem1[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)

    fut4.set()

    [errctxi] = canon_error_context_new(opts1, task, 0, 0)
    [] = canon_stream_drop_writable(StreamType(None), task, wsi)
    [] = canon_error_context_drop(task, errctxi)
    return []

  func1 = partial(canon_lift, opts1, inst1, ft1, core_func1)

  inst2 = ComponentInstance(store)
  heap2 = Heap(10)
  mem2 = heap2.memory
  opts2 = mk_opts(memory=heap2.memory, realloc=heap2.realloc, sync=False)
  ft2 = FuncType([], [])
  def core_func2(task, args):
    assert(not args)
    [] = canon_task_return(task, [], opts2, [])

    retp = 0
    [ret] = canon_lower(opts2, ft1, func1, task, [retp])
    assert(ret == Subtask.State.RETURNED)
    rsi = mem2[0]
    assert(rsi == 1)

    [ret] = canon_stream_read(StreamType(None), opts2, task, rsi, 0, 8)
    assert(ret == definitions.BLOCKED)

    fut1.set()

    [seti] = canon_waitable_set_new(task)
    [] = canon_waitable_join(task, rsi, seti)
    [event] = canon_waitable_set_wait(True, mem2, task, seti, retp)
    assert(event == EventCode.STREAM_READ)
    assert(mem2[retp+0] == rsi)
    result,n = unpack_result(mem2[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)

    fut2.set()
    task.thread.suspend_until(fut3.is_set)

    [ret] = canon_stream_read(StreamType(None), opts2, task, rsi, 1000000, 2)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(None), opts2, task, rsi, 1000000, 2)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)

    task.thread.suspend_until(fut4.is_set)

    [ret] = canon_stream_read(StreamType(None), opts2, task, rsi, 1000000, 2)
    result,n = unpack_result(ret)
    assert(n == 0 and result == CopyResult.DROPPED)
    [] = canon_stream_drop_readable(StreamType(None), task, rsi)
    return []

  run_lift(opts2, inst2, ft2, core_func2, lambda:[], lambda _:())


def test_cancel_copy():
  store = Store()
  inst = ComponentInstance(store)
  mem = bytearray(24)
  lower_opts = mk_opts(memory=mem, sync=False)

  host_ft1 = FuncType([StreamType(U8Type())],[])
  host_sink = None
  def host_func1(caller, on_start, on_resolve):
    nonlocal host_sink
    [stream] = on_start()
    host_sink = HostSink(stream, 2, remain = 0)
    on_resolve([])
    return mk_done_task(caller)

  host_ft2 = FuncType([], [StreamType(U8Type())])
  host_source = None
  def host_func2(caller, on_start, on_resolve):
    nonlocal host_source
    [] = on_start()
    host_source = HostSource(U8Type(), [], chunk=2, destroy_if_empty = False)
    on_resolve([host_source])
    return mk_done_task(caller)

  lift_opts = mk_opts()
  def core_func(task, args):
    assert(not args)

    [packed] = canon_stream_new(StreamType(U8Type()), task)
    rsi,wsi = unpack_new_ends(packed)
    [ret] = canon_lower(lower_opts, host_ft1, host_func1, task, [rsi])
    assert(ret == Subtask.State.RETURNED)
    mem[0:4] = b'\x0a\x0b\x0c\x0d'
    [ret] = canon_stream_write(StreamType(U8Type()), lower_opts, task, wsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_sink.set_remain(2)
    got = host_sink.consume(2)
    assert(got == [0xa, 0xb])
    [ret] = canon_stream_cancel_write(StreamType(U8Type()), True, task, wsi)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_writable(StreamType(U8Type()), task, wsi)
    host_sink.set_remain(100)
    assert(host_sink.consume(100) is None)

    [packed] = canon_stream_new(StreamType(U8Type()), task)
    rsi,wsi = unpack_new_ends(packed)
    [ret] = canon_lower(lower_opts, host_ft1, host_func1, task, [rsi])
    assert(ret == Subtask.State.RETURNED)
    mem[0:4] = b'\x01\x02\x03\x04'
    [ret] = canon_stream_write(StreamType(U8Type()), lower_opts, task, wsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_sink.set_remain(2)
    got = host_sink.consume(2)
    assert(got == [1, 2])
    [ret] = canon_stream_cancel_write(StreamType(U8Type()), False, task, wsi)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_writable(StreamType(U8Type()), task, wsi)
    host_sink.set_remain(100)
    assert(host_sink.consume(100) is None)

    retp = 16
    [ret] = canon_lower(lower_opts, host_ft2, host_func2, task, [retp])
    assert(ret == Subtask.State.RETURNED)
    rsi = mem[retp]
    [ret] = canon_stream_read(StreamType(U8Type()), lower_opts, task, rsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    [ret] = canon_stream_cancel_read(StreamType(U8Type()), True, task, rsi)
    result,n = unpack_result(ret)
    assert(n == 0 and result == CopyResult.CANCELLED)
    [] = canon_stream_drop_readable(StreamType(U8Type()), task, rsi)

    [ret] = canon_lower(lower_opts, host_ft2, host_func2, task, [retp])
    assert(ret == Subtask.State.RETURNED)
    rsi = mem[retp]
    [ret] = canon_stream_read(StreamType(U8Type()), lower_opts, task, rsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_source.block_cancel()
    [ret] = canon_stream_cancel_read(StreamType(U8Type()), False, task, rsi)
    assert(ret == definitions.BLOCKED)
    host_source.write([7,8])
    host_source.unblock_cancel()
    [seti] = canon_waitable_set_new(task)
    [] = canon_waitable_join(task, rsi, seti)
    [event] = canon_waitable_set_wait(True, mem, task, seti, retp)
    assert(event == EventCode.STREAM_READ)
    assert(mem[retp+0] == rsi)
    result,n = unpack_result(mem[retp+4])
    assert(n == 2 and result == CopyResult.CANCELLED)
    assert(mem[0:2] == b'\x07\x08')
    [] = canon_stream_drop_readable(StreamType(U8Type()), task, rsi)
    [] = canon_waitable_set_drop(task, seti)

    return []

  run_lift(lift_opts, inst, FuncType([],[]), core_func, lambda:[], lambda _:())


class HostFutureSink:
  t: ValType
  v: Optional[any]
  has_v: RacyBool

  def __init__(self, t):
    self.t = t
    self.v = None
    self.has_v = RacyBool(False)

  def remain(self):
    return 1 if self.v is None else 0

  def write(self, v):
    assert(not self.v)
    assert(len(v) == 1)
    self.v = v[0]
    self.has_v.set()

class HostFutureSource(ReadableFuture):
  v: Optional[any]
  pending_buffer: Optional[WritableBuffer]
  pending_on_copy_done: Optional[OnCopyDone]
  def __init__(self, t):
    self.t = t
    self.v = None
    self.reset_pending()
  def reset_pending(self):
    self.pending_buffer = None
    self.pending_on_copy_done = None
  def read(self, inst, buffer, on_copy_done):
    if self.v:
      buffer.write([self.v])
      on_copy_done(CopyResult.COMPLETED)
    else:
      self.pending_buffer = buffer
      self.pending_on_copy_done = on_copy_done
  def cancel(self):
    self.pending_on_copy_done(CopyResult.CANCELLED)
    self.reset_pending()
  def drop(self):
    pass
  def set_result(self, v):
    if self.pending_buffer:
      self.pending_buffer.write([v])
      self.pending_on_copy_done(CopyResult.COMPLETED)
      self.reset_pending()
    else:
      self.v = v

def test_futures():
  store = Store()
  inst = ComponentInstance(store)
  mem = bytearray(24)
  lower_opts = mk_opts(memory=mem, sync=False)

  host_ft1 = FuncType([FutureType(U8Type())],[FutureType(U8Type())])
  def host_func(caller, on_start, on_resolve):
    def thread_func(task):
      [future] = on_start()
      outgoing = HostFutureSource(U8Type())
      task.return_([outgoing])
      incoming = HostFutureSink(U8Type())
      future.read(None, incoming, lambda why:())
      task.thread.suspend_until(incoming.has_v.is_set)
      assert(incoming.v == 42)
      outgoing.set_result(43)
    return mk_task(caller, on_resolve, thread_func)

  lift_opts = mk_opts()
  def core_func(task, args):
    assert(not args)
    [packed] = canon_future_new(FutureType(U8Type()), task)
    rfi,wfi = unpack_new_ends(packed)
    retp = 16
    [ret] = canon_lower(lower_opts, host_ft1, host_func, task, [rfi, retp])
    assert(ret == Subtask.State.RETURNED)
    rfi = mem[retp]

    readp = 0
    [ret] = canon_future_read(FutureType(U8Type()), lower_opts, task, rfi, readp)
    assert(ret == definitions.BLOCKED)

    writep = 8
    mem[writep] = 42
    [ret] = canon_future_write(FutureType(U8Type()), lower_opts, task, wfi, writep)
    assert(ret == CopyResult.COMPLETED)

    [seti] = canon_waitable_set_new(task)
    [] = canon_waitable_join(task, rfi, seti)
    [event] = canon_waitable_set_wait(True, mem, task, seti, retp)
    assert(event == EventCode.FUTURE_READ)
    assert(mem[retp+0] == rfi)
    assert(mem[retp+4] == CopyResult.COMPLETED)
    assert(mem[readp] == 43)

    [] = canon_future_drop_writable(FutureType(U8Type()), task, wfi)
    [] = canon_future_drop_readable(FutureType(U8Type()), task, rfi)
    [] = canon_waitable_set_drop(task, seti)

    [packed] = canon_future_new(FutureType(U8Type()), task)
    rfi,wfi = unpack_new_ends(packed)
    [ret] = canon_lower(lower_opts, host_ft1, host_func, task, [rfi, retp])
    assert(ret == Subtask.State.RETURNED)
    rfi = mem[retp]

    readp = 0
    [ret] = canon_future_read(FutureType(U8Type()), lower_opts, task, rfi, readp)
    assert(ret == definitions.BLOCKED)

    writep = 8
    mem[writep] = 42
    [ret] = canon_future_write(FutureType(U8Type()), lower_opts, task, wfi, writep)
    assert(ret == CopyResult.COMPLETED)

    while not task.inst.table.get(rfi).has_pending_event():
      canon_yield(True, task)

    [ret] = canon_future_cancel_read(FutureType(U8Type()), True, task, rfi)
    assert(ret == CopyResult.COMPLETED)
    assert(mem[readp] == 43)

    [] = canon_future_drop_writable(FutureType(U8Type()), task, wfi)
    [] = canon_future_drop_readable(FutureType(U8Type()), task, rfi)

    [packed] = canon_future_new(FutureType(U8Type()), task)
    rfi,wfi = unpack_new_ends(packed)
    trapped = False
    try:
      canon_future_drop_writable(FutureType(U8Type()), task, wfi)
    except Trap:
      trapped = True
    assert(trapped)

    return []

  run_lift(lift_opts, inst, FuncType([],[]), core_func, lambda:[], lambda _:())


def test_cancel_subtask():
  ft = FuncType([U8Type()], [U8Type()])

  callee_heap = Heap(10)
  callee_opts = mk_opts(callee_heap.memory, sync = False)
  sync_callee_opts = mk_opts(callee_heap.memory, sync = True)
  store = Store()
  callee_inst = ComponentInstance(store)

  def core_callee1(task, args):
    assert(False)
  callee1 = partial(canon_lift, callee_opts, callee_inst, ft, core_callee1)

  def core_callee2(task, args):
    [x] = args
    [si] = canon_waitable_set_new(task)
    [ret] = canon_waitable_set_wait(True, callee_heap.memory, task, si, 0)
    assert(ret == EventCode.TASK_CANCELLED)
    match x:
      case 1:
        [] = canon_task_return(task, [U8Type()], callee_opts, [42])
      case 2:
        [] = canon_task_cancel(task)
      case 3:
        [_] = canon_yield(True, task)
        [] = canon_task_return(task, [U8Type()], callee_opts, [43])
      case 4:
        [_] = canon_yield(True, task)
        [] = canon_task_cancel(task)
      case _:
        assert(False)
    return []
  callee2 = partial(canon_lift, callee_opts, callee_inst, ft, core_callee2)

  def core_callee3(task, args):
    [x] = args
    [cancelled] = canon_yield(True, task)
    if cancelled:
      [] = canon_task_cancel(task)
    else:
      [] = canon_task_return(task, [U8Type()], callee_opts, [83])
    return []
  callee3 = partial(canon_lift, callee_opts, callee_inst, ft, core_callee3)

  host_fut4 = RacyBool(False)
  def host_import4(caller, on_start, on_resolve):
    def thread_func(task):
      args = on_start()
      assert(len(args) == 1)
      assert(args[0] == 42)
      task.thread.suspend_until(host_fut4.is_set)
      task.return_([43])
    return mk_task(caller, on_resolve, thread_func)
  def core_callee4(task, args):
    [x] = args
    [result] = canon_lower(sync_callee_opts, ft, host_import4, task, [42])
    assert(result == 43)
    try:
      [] = canon_task_cancel(task)
      assert(False)
    except Trap:
      pass
    [seti] = canon_waitable_set_new(task)
    [result] = canon_waitable_set_wait(True, callee_heap.memory, task, seti, 0)
    assert(result == EventCode.TASK_CANCELLED)
    [result] = canon_waitable_set_poll(True, callee_heap.memory, task, seti, 0)
    assert(result == EventCode.NONE)
    [] = canon_task_cancel(task)
    return []
  callee4 = partial(canon_lift, callee_opts, callee_inst, ft, core_callee4)

  host_fut5 = RacyBool(False)
  def host_import5(caller, on_start, on_resolve):
    def thread_func(task):
      args = on_start()
      assert(len(args) == 1)
      assert(args[0] == 42)
      task.thread.suspend_until(host_fut5.is_set)
      assert(task.state == Task.State.PENDING_CANCEL)
      task.thread.suspend_until(host_fut5.is_set)
      task.return_([43])
    return mk_task(caller, on_resolve, thread_func)
  def core_callee5(task, args):
    [x] = args
    [ret] = canon_lower(callee_opts, ft, host_import5, task, [42, 0])
    state,subi = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_subtask_cancel(True, task, subi)
    assert(ret == Subtask.State.RETURNED)
    [] = canon_task_return(task, [U8Type()], callee_opts, [44])
    return []
  callee5 = partial(canon_lift, callee_opts, callee_inst, ft, core_callee5)

  caller_heap = Heap(20)
  caller_opts = mk_opts(caller_heap.memory, sync = False)
  caller_inst = ComponentInstance(store)

  def core_caller(task, args):
    [x] = args
    assert(x == 1)

    [seti] = canon_waitable_set_new(task)

    callee_inst.backpressure = True
    [ret] = canon_lower(caller_opts, ft, callee1, task, [13, 0])
    state,subi1 = unpack_result(ret)
    assert(state == Subtask.State.STARTING)
    [ret] = canon_lower(caller_opts, ft, callee1, task, [13, 0])
    state,subi2 = unpack_result(ret)
    assert(state == Subtask.State.STARTING)
    [ret] = canon_subtask_cancel(True, task, subi2)
    assert(ret == Subtask.State.CANCELLED_BEFORE_STARTED)
    [ret] = canon_subtask_cancel(False, task, subi1)
    assert(ret == Subtask.State.CANCELLED_BEFORE_STARTED)
    callee_inst.backpressure = False

    [ret] = canon_lower(caller_opts, ft, callee2, task, [1, 0])
    state,subi1 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_lower(caller_opts, ft, callee2, task, [2, 0])
    state,subi2 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_lower(caller_opts, ft, callee2, task, [3, 0])
    state,subi3 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_lower(caller_opts, ft, callee2, task, [3, 0])
    state,subi3_2 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_lower(caller_opts, ft, callee2, task, [4, 0])
    state,subi4 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_lower(caller_opts, ft, callee2, task, [4, 0])
    state,subi4_2 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)

    caller_heap.memory[0] = 13
    [ret] = canon_subtask_cancel(True, task, subi1)
    assert(ret == Subtask.State.RETURNED)
    assert(caller_heap.memory[0] == 42)
    [] = canon_subtask_drop(task, subi1)

    caller_heap.memory[0] = 13
    [ret] = canon_subtask_cancel(False, task, subi2)
    assert(ret == Subtask.State.CANCELLED_BEFORE_RETURNED)
    assert(caller_heap.memory[0] == 13)
    [] = canon_subtask_drop(task, subi2)

    caller_heap.memory[0] = 13
    [ret] = canon_subtask_cancel(False, task, subi3)
    assert(ret == definitions.BLOCKED)
    assert(caller_heap.memory[0] == 13)
    [] = canon_waitable_join(task, subi3, seti)
    retp = 8
    [ret] = canon_waitable_set_wait(True, caller_heap.memory, task, seti, retp)
    assert(ret == EventCode.SUBTASK)
    assert(caller_heap.memory[retp+0] == subi3)
    assert(caller_heap.memory[retp+4] == Subtask.State.RETURNED)
    assert(caller_heap.memory[0] == 43)
    [] = canon_subtask_drop(task, subi3)

    caller_heap.memory[0] = 13
    [ret] = canon_subtask_cancel(True, task, subi3_2)
    assert(ret == Subtask.State.RETURNED)
    assert(caller_heap.memory[0] == 43)
    [] = canon_subtask_drop(task, subi3_2)

    caller_heap.memory[0] = 13
    [ret] = canon_subtask_cancel(False, task, subi4)
    assert(ret == definitions.BLOCKED)
    assert(caller_heap.memory[0] == 13)
    [] = canon_waitable_join(task, subi4, seti)
    retp = 8
    [ret] = canon_waitable_set_wait(True, caller_heap.memory, task, seti, retp)
    assert(ret == EventCode.SUBTASK)
    assert(caller_heap.memory[retp+0] == subi4)
    assert(caller_heap.memory[retp+4] == Subtask.State.CANCELLED_BEFORE_RETURNED)
    [] = canon_subtask_drop(task, subi4)

    caller_heap.memory[0] = 13
    [ret] = canon_subtask_cancel(True, task, subi4_2)
    assert(ret == Subtask.State.CANCELLED_BEFORE_RETURNED)
    assert(caller_heap.memory[0] == 13)
    [] = canon_subtask_drop(task, subi4_2)

    caller_heap.memory[0] = 13
    [ret] = canon_lower(caller_opts, ft, callee3, task, [0, 0])
    state,subi = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    while caller_inst.table.get(subi).state == Subtask.State.STARTED:
      [_] = canon_yield(True, task)
    [ret] = canon_subtask_cancel(False, task, subi)
    assert(ret == Subtask.State.RETURNED)
    assert(caller_heap.memory[0] == 83)
    [] = canon_subtask_drop(task, subi)

    caller_heap.memory[0] = 13
    [ret] = canon_lower(caller_opts, ft, callee3, task, [0, 0])
    state,subi = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_subtask_cancel(False, task, subi)
    assert(ret == Subtask.State.CANCELLED_BEFORE_RETURNED)
    assert(caller_heap.memory[0] == 13)
    [] = canon_subtask_drop(task, subi)

    caller_heap.memory[0] = 13
    [ret] = canon_lower(caller_opts, ft, callee4, task, [0, 0])
    state,subi = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_subtask_cancel(False, task, subi)
    assert(ret == definitions.BLOCKED)
    assert(caller_heap.memory[0] == 13)
    host_fut4.set()
    [] = canon_waitable_join(task, subi, seti)
    waitretp = 4
    [event] = canon_waitable_set_wait(True, caller_heap.memory, task, seti, waitretp)
    assert(event == EventCode.SUBTASK)
    assert(caller_heap.memory[waitretp] == subi)
    assert(caller_heap.memory[waitretp+4] == Subtask.State.CANCELLED_BEFORE_RETURNED)
    assert(caller_heap.memory[0] == 13)
    [] = canon_subtask_drop(task, subi)

    caller_heap.memory[0] = 13
    [ret] = canon_lower(caller_opts, ft, callee5, task, [0, 0])
    state,subi = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_subtask_cancel(False, task, subi)
    assert(ret == definitions.BLOCKED)
    assert(caller_heap.memory[0] == 13)
    host_fut5.set()
    [] = canon_waitable_join(task, subi, seti)
    waitretp = 4
    [event] = canon_waitable_set_wait(True, caller_heap.memory, task, seti, waitretp)
    assert(event == EventCode.SUBTASK)
    assert(caller_heap.memory[waitretp] == subi)
    assert(caller_heap.memory[waitretp+4] == Subtask.State.RETURNED)
    assert(caller_heap.memory[0] == 44)
    [] = canon_subtask_drop(task, subi)

    [] = canon_waitable_set_drop(task, seti)
    [] = canon_task_return(task, [U8Type()], caller_opts, [42])

    return []

  def on_start():
    return [ 1 ]

  got = None
  def on_resolve(results):
    nonlocal got
    got = results

  run_lift(caller_opts, caller_inst, ft, core_caller, on_start, on_resolve)

  assert(len(got) == 1)
  assert(got[0] == 42)


def test_self_empty():
  store = Store()
  inst = ComponentInstance(store)
  mem = bytearray(24)
  sync_opts = mk_opts(memory=mem, sync=True)
  async_opts = mk_opts(memory=mem, sync=False)

  ft = FuncType([],[])
  def core_func(task, args):
    [seti] = canon_waitable_set_new(task)

    [packed] = canon_future_new(FutureType(None), task)
    rfi,wfi = unpack_new_ends(packed)

    [ret] = canon_future_write(FutureType(None), async_opts, task, wfi, 0xdeadbeef)
    assert(ret == definitions.BLOCKED)

    [ret] = canon_future_read(FutureType(None), async_opts, task, rfi, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)
    [] = canon_future_drop_readable(FutureType(None), task, rfi)

    [] = canon_waitable_join(task, wfi, seti)
    [event] = canon_waitable_set_wait(True, mem, task, seti, 0)
    assert(event == EventCode.FUTURE_WRITE)
    assert(mem[0] == wfi)
    assert(mem[4] == CopyResult.COMPLETED)
    [] = canon_future_drop_writable(FutureType(None), task, wfi)

    [packed] = canon_stream_new(StreamType(None), task)
    rsi,wsi = unpack_new_ends(packed)
    [ret] = canon_stream_write(StreamType(None), async_opts, task, wsi, 10000, 3)
    assert(ret == definitions.BLOCKED)

    [ret] = canon_stream_read(StreamType(None), async_opts, task, rsi, 2000, 1)
    result,n = unpack_result(ret)
    assert(n == 1 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(None), async_opts, task, rsi, 2000, 4)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_readable(StreamType(None), task, rsi)

    [] = canon_waitable_join(task, wsi, seti)
    [event] = canon_waitable_set_wait(True, mem, task, seti, 0)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem[0] == wsi)
    result,n = unpack_result(mem[4])
    assert(result == CopyResult.DROPPED)
    assert(n == 3)
    [] = canon_stream_drop_writable(StreamType(None), task, wsi)

    [] = canon_waitable_set_drop(task, seti)
    return []

  run_lift(sync_opts, inst, ft, core_func, lambda:[], lambda _:())


def test_async_flat_params():
  store = Store()
  heap = Heap(1000)
  opts = mk_opts(heap.memory, 'utf8', heap.realloc, sync = False)

  ft1 = FuncType([F32Type(), F64Type(), U32Type(), S64Type()],[])
  def f1(caller, on_start, on_resolve):
    args = on_start()
    assert(len(args) == 4)
    assert(args[0] == 1.1)
    assert(args[1] == 2.2)
    assert(args[2] == 3)
    assert(args[3] == 4)
    on_resolve([])
    return mk_done_task(caller)

  ft2 = FuncType([U32Type(),U8Type(),U8Type(),U8Type()],[])
  def f2(caller, on_start, on_resolve):
    args = on_start()
    assert(len(args) == 4)
    assert(args == [1,2,3,4])
    on_resolve([])
    return mk_done_task(caller)

  ft3 = FuncType([U32Type(),U8Type(),U8Type(),U8Type(),U8Type()],[])
  def f3(caller, on_start, on_resolve):
    args = on_start()
    assert(len(args) == 5)
    assert(args == [1,2,3,4,5])
    on_resolve([])
    return mk_done_task(caller)

  def core_func(thread, args):
    [ret] = canon_lower(opts, ft1, f1, thread, [1.1, 2.2, 3, 4])
    assert(ret == Subtask.State.RETURNED)

    [ret] = canon_lower(opts, ft2, f2, thread, [1,2,3,4])
    assert(ret == Subtask.State.RETURNED)

    heap.memory[12:20] = b'\x01\x00\x00\x00\x02\x03\x04\x05'
    [ret] = canon_lower(opts, ft3, f3, thread, [12])
    assert(ret == Subtask.State.RETURNED)

    canon_task_return(thread, [], opts, [])
    return []

  inst = ComponentInstance(store)
  run_lift(opts, inst, FuncType([], []), core_func, lambda:[], lambda _:())

test_roundtrips()
test_handles()
test_async_to_async()
test_async_callback()
test_callback_interleaving()
test_async_to_sync()
test_async_backpressure()
test_sync_using_wait()
test_eager_stream_completion()
test_async_stream_ops()
test_stream_forward()
test_receive_own_stream()
test_host_partial_reads_writes()
test_wasm_to_wasm_stream()
test_wasm_to_wasm_stream_empty()
test_cancel_copy()
test_futures()
test_cancel_subtask()
test_self_empty()
test_async_flat_params()

print("All tests passed")
