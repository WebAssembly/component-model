import definitions
from definitions import *
from functools import partial

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

  def realloc(self, args):
    original_ptr, original_size, alignment, new_size = args
    if original_ptr != 0 and new_size < original_size:
      return [align_to(original_ptr, alignment)]
    ret = align_to(self.last_alloc, alignment)
    self.last_alloc = ret + new_size
    if self.last_alloc > len(self.memory):
      trap()
    self.memory[ret : ret + original_size] = self.memory[original_ptr : original_ptr + original_size]
    return [ret]

def mk_opts(memory = MemInst(bytearray(), 'i32'), encoding = 'utf8', realloc = None, post_return = None, sync_task_return = False, async_ = False):
  opts = CanonicalOptions()
  opts.memory = memory
  opts.string_encoding = encoding
  opts.realloc = realloc
  opts.post_return = post_return
  opts.sync_task_return = sync_task_return
  opts.async_ = async_
  opts.callback = None
  return opts

def mk_cx(memory = MemInst(bytearray(), 'i32'), encoding = 'utf8', realloc = None, post_return = None):
  opts = mk_opts(memory, encoding, realloc, post_return)
  inst = ComponentInstance(Store())
  return LiftLowerContext(opts, inst)

def lift_and_run(opts, inst, ft, callee, on_start, on_resolve):
  func_inst = inst.store.lift(callee, ft, opts, inst)
  _ = inst.store.invoke(func_inst, on_start, on_resolve)
  while inst.store.waiting:
    inst.store.tick()

def mk_host_func(store, host_func, ft):
  def func_inst(on_start, on_resume) -> OnCancel:
    def thread_func():
      wait_until = lambda rf: host_thread.wait_until(rf)
      host_func(on_start, on_resume, wait_until)
    inst = ComponentInstance(store)
    task = Task(ft, CanonicalOptions(), inst, on_start, on_resume)
    host_thread = Thread(task, thread_func)
    host_thread.resume()
    def on_cancel():
      pass
    return on_cancel
  return func_inst

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
  cx = mk_cx(MemInst(heap.memory, cx.opts.memory.ptr_type()), dst_encoding, heap.realloc)
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
  cx = mk_cx(MemInst(int.to_bytes(inbits, 4, 'little'), 'i32'))
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
  cx = mk_cx(MemInst(int.to_bytes(inbits, 8, 'little'), 'i32'))
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

def test_string_internal(src_encoding, dst_encoding, s, encoded, tagged_code_units, addr_type='i32'):
  heap = Heap(len(encoded))
  heap.memory[:] = encoded[:]
  cx = mk_cx(MemInst(heap.memory, addr_type), src_encoding)
  v = (s, src_encoding, tagged_code_units)
  test(StringType(), [0, tagged_code_units], v, cx, dst_encoding)

def test_string(src_encoding, dst_encoding, s, addr_type='i32'):
  if src_encoding == 'utf8':
    encoded = s.encode('utf-8')
    tagged_code_units = len(encoded)
    test_string_internal(src_encoding, dst_encoding, s, encoded, tagged_code_units, addr_type)
  elif src_encoding == 'utf16':
    encoded = s.encode('utf-16-le')
    tagged_code_units = int(len(encoded) / 2)
    test_string_internal(src_encoding, dst_encoding, s, encoded, tagged_code_units, addr_type)
  elif src_encoding == 'latin1+utf16':
    try:
      encoded = s.encode('latin-1')
      tagged_code_units = len(encoded)
      test_string_internal(src_encoding, dst_encoding, s, encoded, tagged_code_units, addr_type)
    except UnicodeEncodeError:
      pass
    encoded = s.encode('utf-16-le')
    tagged_code_units = int(len(encoded) / 2) | utf16_tag(addr_type)
    test_string_internal(src_encoding, dst_encoding, s, encoded, tagged_code_units, addr_type)

encodings = ['utf8', 'utf16', 'latin1+utf16']

fun_strings = ['', 'a', 'hi', '\x00', 'a\x00b', '\x80', '\x80b', 'ab\xefc',
               '\u01ffy', 'xy\u01ff', 'a\ud7ffb', 'a\u02ff\u03ff\u04ffbc',
               '\uf123', '\uf123\uf123abc', 'abcdef\uf123']

for addr_type in ['i32', 'i64']:
  for src_encoding in encodings:
    for dst_encoding in encodings:
      for s in fun_strings:
        test_string(src_encoding, dst_encoding, s, addr_type)

def test_heap(t, expect, args, byte_array, addr_type='i32'):
  heap = Heap(byte_array)
  cx = mk_cx(MemInst(heap.memory, addr_type))
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
test_heap(ListType(StringType()), [mk_str("hi"),mk_str("wat")], [0,2],
          [32,0,0,0,0,0,0,0, 2,0,0,0,0,0,0,0,
           37,0,0,0,0,0,0,0, 3,0,0,0,0,0,0,0,
           ord('h'), ord('i'),   0xf,0xf,0xf,   ord('w'), ord('a'), ord('t')],
          addr_type='i64')
test_heap(ListType(ListType(U8Type())), [[3,4,5],[],[6,7]], [0,3],
          [24,0,0,0, 3,0,0,0, 0,0,0,0, 0,0,0,0, 27,0,0,0, 2,0,0,0,
          3,4,5,  6,7])
test_heap(ListType(ListType(U8Type())), [[3,4,5],[],[6,7]], [0,3],
          [48,0,0,0,0,0,0,0, 3,0,0,0,0,0,0,0,
           0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
           51,0,0,0,0,0,0,0, 2,0,0,0,0,0,0,0,
           3,4,5, 6,7],
          addr_type='i64')
test_heap(ListType(ListType(U16Type())), [[5,6]], [0,1],
          [8,0,0,0, 2,0,0,0,
          5,0, 6,0])
test_heap(ListType(ListType(U16Type())), [[5,6]], [0,1],
          [16,0,0,0,0,0,0,0, 2,0,0,0,0,0,0,0,
          5,0, 6,0],
          addr_type='i64')
test_heap(ListType(ListType(U16Type())), None, [0,1],
          [9,0,0,0, 2,0,0,0,
          0, 5,0, 6,0])
test_heap(ListType(ListType(U16Type())), None, [0,1],
          [17,0,0,0,0,0,0,0, 2,0,0,0,0,0,0,0,
          0, 5,0, 6,0],
          addr_type='i64')
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
t = MapType(U8Type(), U16Type())
test_heap(t, [{'0':42, '1':83}, {'0':43, '1':84}], [0, 2],
          [42,0xff,83,0, 43,0xff,84,0])

def test_flatten(t, params, results, addr_type='i32'):
  opts = mk_opts(MemInst(bytearray(), addr_type))
  expect = CoreFuncType(params, results)

  if len(params) > definitions.MAX_FLAT_PARAMS:
    expect.params = [addr_type]

  if len(results) > definitions.MAX_FLAT_RESULTS:
    expect.results = [addr_type]
  got = flatten_functype(opts, t, 'lift')
  assert(got == expect)

  if len(results) > definitions.MAX_FLAT_RESULTS:
    expect.params += [addr_type]
    expect.results = []
  got = flatten_functype(opts, t, 'lower')
  assert(got == expect)

test_flatten(FuncType([U8Type(),F32Type(),F64Type()],[]), ['i32','f32','f64'], [])
test_flatten(FuncType([U8Type(),F32Type(),F64Type()],[F32Type()]), ['i32','f32','f64'], ['f32'])
test_flatten(FuncType([U8Type(),F32Type(),F64Type()],[U8Type()]), ['i32','f32','f64'], ['i32'])
test_flatten(FuncType([U8Type(),F32Type(),F64Type()],[TupleType([F32Type()])]), ['i32','f32','f64'], ['f32'])
test_flatten(FuncType([U8Type(),F32Type(),F64Type()],[TupleType([F32Type(),F32Type()])]), ['i32','f32','f64'], ['f32','f32'])
test_flatten(FuncType([U8Type(),F32Type(),F64Type()],[F32Type(),F32Type()]), ['i32','f32','f64'], ['f32','f32'])
test_flatten(FuncType([U8Type() for _ in range(17)],[]), ['i32' for _ in range(17)], [])
test_flatten(FuncType([U8Type() for _ in range(17)],[]), ['i32' for _ in range(17)], [], addr_type='i64')
test_flatten(FuncType([U8Type() for _ in range(17)],[TupleType([U8Type(),U8Type()])]), ['i32' for _ in range(17)], ['i32','i32'])
test_flatten(FuncType([U8Type() for _ in range(17)],[TupleType([U8Type(),U8Type()])]), ['i32' for _ in range(17)], ['i32','i32'], addr_type='i64')


def test_roundtrips():
  def test_roundtrip(t, v, addr_type='i32'):
    before = definitions.MAX_FLAT_RESULTS
    definitions.MAX_FLAT_RESULTS = 16

    store = Store()

    ft = FuncType([t],[t])
    def callee(x):
      return x

    callee_heap = Heap(1000)
    callee_opts = mk_opts(MemInst(callee_heap.memory, addr_type), 'utf8', callee_heap.realloc)
    callee_inst = ComponentInstance(store)

    got = None
    def on_start():
      return [v]
    def on_resolve(result):
      nonlocal got
      [got] = result
    lift_and_run(callee_opts, callee_inst, ft, callee, on_start, on_resolve)

    if got != v:
      fail("test_roundtrip({},{}) got {}".format(t, v, got))

    definitions.MAX_FLAT_RESULTS = before

  cases = [
    (S8Type(), -1),
    (TupleType([U16Type(),U16Type()]), mk_tup(3,4)),
    (ListType(StringType()), [mk_str("hello there")]),
    (ListType(ListType(StringType())), [[mk_str("one"),mk_str("two")],[mk_str("three")]]),
    (ListType(OptionType(TupleType([StringType(),U16Type()]))), [{'some':mk_tup(mk_str("answer"),42)}]),
    (VariantType([CaseType('x', TupleType([U32Type(),U32Type(),U32Type(),U32Type(),
                                           U32Type(),U32Type(),U32Type(),U32Type(),
                                           U32Type(),U32Type(),U32Type(),U32Type(),
                                           U32Type(),U32Type(),U32Type(),U32Type(),
                                           StringType()]))]),
                  {'x': mk_tup(1,2,3,4, 5,6,7,8, 9,10,11,12, 13,14,15,16, mk_str("wat"))}),
  ]
  for addr_type in ['i32', 'i64']:
    for t, v in cases:
      test_roundtrip(t, v, addr_type=addr_type)


def test_cross_component_realloc():
  store = Store()

  producer_heap = Heap(16)
  producer_opts = mk_opts(MemInst(producer_heap.memory, 'i32'))
  producer_inst = ComponentInstance(store)

  ft = FuncType([], [ListType(U8Type())])
  def core_producer(args):
    assert(len(args) == 0)
    [] = canon_context_set('i32', 0, 0xdead)
    [buf] = producer_heap.realloc([0, 0, 1, 3])
    producer_heap.memory[buf : buf+3] = b'\x0a\x0b\x0c'
    [retp] = producer_heap.realloc([0, 0, 4, 8])
    producer_heap.memory[retp] = buf
    producer_heap.memory[retp+4] = 3
    return [retp]
  producer = store.lift(core_producer, ft, producer_opts, producer_inst)

  consumer_heap = Heap(24)
  consumer_inst = ComponentInstance(store)
  consumer_thread = None
  num_realloc_calls = 0

  def core_consumer_realloc(args):
    nonlocal num_realloc_calls
    num_realloc_calls += 1
    thread = current_thread()
    assert(thread is not consumer_thread)
    assert(thread.task is not consumer_thread.task)
    assert(thread.task.inst is consumer_inst)
    assert(current_instance() is consumer_inst)
    assert(not consumer_inst.may_leave)
    assert(canon_context_get('i32', 0) == [0])
    assert(canon_context_get('i32', 1) == [0])
    [] = canon_context_set('i32', 0, 0xfeed)
    assert(canon_context_get('i32', 0) == [0xfeed])
    try:
      canon_thread_index()
      fail("thread.index must trap during realloc")
    except Trap:
      pass
    return consumer_heap.realloc(args)

  consumer_opts = mk_opts(MemInst(consumer_heap.memory, 'i32'), realloc = core_consumer_realloc)

  def core_consumer(args):
    nonlocal consumer_thread
    assert(len(args) == 0)
    consumer_thread = current_thread()
    [] = canon_context_set('i32', 0, 42)
    [] = canon_context_set('i32', 1, 43)
    [retp] = consumer_heap.realloc([0, 0, 4, 8])
    assert(num_realloc_calls == 0)
    [] = store.lower(producer, ft, consumer_opts, consumer_inst)([retp])
    assert(num_realloc_calls == 1)
    assert(canon_context_get('i32', 0) == [42])
    assert(canon_context_get('i32', 1) == [43])
    ptr = consumer_heap.memory[retp]
    length = consumer_heap.memory[retp+4]
    assert(length == 3)
    assert(consumer_heap.memory[ptr : ptr+3] == b'\x0a\x0b\x0c')
    return []

  lift_and_run(mk_opts(), consumer_inst, FuncType([], []), core_consumer, lambda: [], lambda _: ())
  assert(num_realloc_calls == 1)


def test_handles():
  before = definitions.MAX_FLAT_RESULTS
  definitions.MAX_FLAT_RESULTS = 16

  dtor_value = None
  def dtor(args):
    nonlocal dtor_value
    assert(len(args) == 1)
    dtor_value = args[0]
    return []

  store = Store()
  producer_inst = ComponentInstance(store)
  rt = ResourceType(producer_inst, dtor) # usable in imports and exports
  inst = ComponentInstance(store)
  rt2 = ResourceType(inst, dtor) # only usable in exports
  opts = mk_opts()

  host_ft = FuncType([
    BorrowType(rt),
    BorrowType(rt)
  ],[
    OwnType(rt)
  ])
  def host_func(on_start, on_return, wait_until):
    args = on_start()
    assert(len(args) == 2)
    assert(args[0] == 42)
    assert(args[1] == 44)
    on_return([45])
  host_func_inst = mk_host_func(store, host_func, host_ft)

  def core_wasm(args):
    nonlocal dtor_value

    assert(len(args) == 4)
    assert(len(inst.handles.array) == 4)
    assert(inst.handles.array[0] is None)
    assert(args[0] == 1)
    assert(args[1] == 2)
    assert(args[2] == 3)
    assert(args[3] == 13)
    h1 = args[0]
    h2 = args[1]
    h3 = args[2]
    assert((canon_resource_rep(rt, h1))[0] == 42)
    assert((canon_resource_rep(rt, h2))[0] == 43)
    assert((canon_resource_rep(rt, h3))[0] == 44)

    results = store.lower(host_func_inst, host_ft, opts, inst)([h1, h3])
    assert(len(results) == 1)
    assert(results[0] == 4)
    h4 = results[0]
    assert((canon_resource_rep(rt, h4))[0] == 45)

    dtor_value = None
    [] = canon_resource_drop(rt, h1)
    assert(dtor_value == 42)
    assert(len(inst.handles.array) == 5)
    assert(inst.handles.array[h1] is None)
    assert(len(inst.handles.free) == 1)

    h = (canon_resource_new(rt, 46))[0]
    assert(h == h1)
    assert(len(inst.handles.array) == 5)
    assert(inst.handles.array[h] is not None)
    assert(len(inst.handles.free) == 0)

    dtor_value = None
    [] = canon_resource_drop(rt, h3)
    assert(dtor_value is None)
    assert(len(inst.handles.array) == 5)
    assert(inst.handles.array[h3] is None)
    assert(len(inst.handles.free) == 1)

    return [h, h2, h4]

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

  lift_and_run(opts, inst, ft, core_wasm, on_start, on_resolve)

  assert(len(got) == 3)
  assert(got[0] == 46)
  assert(got[1] == 43)
  assert(got[2] == 45)
  assert(len(inst.handles.array) == 5)
  assert(all(inst.handles.array[i] is None for i in range(4)))
  assert(len(inst.handles.free) == 4)
  definitions.MAX_FLAT_RESULTS = before


def test_async_to_async():
  producer_heap = Heap(10)
  producer_opts = mk_opts(MemInst(producer_heap.memory, 'i32'))
  producer_opts.async_ = True

  store = Store()
  producer_inst = ComponentInstance(store)

  eager_ft = FuncType([], [U8Type()], async_=True)
  def core_eager_producer(args):
    assert(len(args) == 0)
    [] = canon_task_return([U8Type()], producer_opts, [43])
    return []
  eager_callee = store.lift(core_eager_producer, eager_ft, producer_opts, producer_inst)

  toggle_ft = FuncType([], [], async_=True)
  fut1_1 = RacyBool(False)
  fut1_2 = RacyBool(False)
  def core_toggle(args):
    thread = current_thread()
    assert(len(args) == 0)
    [] = canon_backpressure_inc()
    thread.wait_until(fut1_1.is_set)
    [] = canon_task_return([], producer_opts, [])
    thread.wait_until(fut1_2.is_set)
    [] = canon_backpressure_dec()
    return []
  toggle_callee = store.lift(core_toggle, toggle_ft, producer_opts, producer_inst)

  fut2, fut3, fut4 = RacyBool(False), RacyBool(False), RacyBool(False)
  blocking_ft = FuncType([U8Type()], [U8Type()], async_=True)
  def core_blocking_producer(args):
    thread = current_thread()
    [x] = args
    assert(x == 83)
    thread.wait_until(fut2.is_set)
    [] = canon_task_return([U8Type()], producer_opts, [44])
    thread.wait_until(fut3.is_set)
    fut4.set()
    return []
  blocking_callee = store.lift(core_blocking_producer, blocking_ft, producer_opts, producer_inst)

  consumer_heap = Heap(20)
  consumer_opts = mk_opts(MemInst(consumer_heap.memory, 'i32'))
  consumer_opts.async_ = True
  consumer_inst = ComponentInstance(store)

  def consumer(args):
    [b] = args
    [seti] = canon_waitable_set_new()
    [ptr] = consumer_heap.realloc([0, 0, 1, 1])
    [ret] = store.lower(eager_callee, eager_ft, consumer_opts, consumer_inst)([ptr])
    assert(ret == Subtask.State.RETURNED)
    u8 = consumer_heap.memory[ptr]
    assert(u8 == 43)
    [ret] = store.lower(toggle_callee, toggle_ft, consumer_opts, consumer_inst)([])
    state,subi1 = unpack_result(ret)
    assert(subi1 == 2)
    assert(state == Subtask.State.STARTED)
    [] = canon_waitable_join(subi1, seti)
    retp = ptr
    consumer_heap.memory[retp] = 13
    [ret] = store.lower(blocking_callee, blocking_ft, consumer_opts, consumer_inst)([83, retp])
    state,subi2 = unpack_result(ret)
    assert(subi2 == 3)
    assert(state == Subtask.State.STARTING)
    assert(consumer_heap.memory[retp] == 13)
    [] = canon_waitable_join(subi2, seti)
    fut1_1.set()

    [waitretp] = consumer_heap.realloc([0, 0, 8, 4])
    [event] = canon_waitable_set_wait(MemInst(consumer_heap.memory, 'i32'), seti, waitretp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_heap.memory[waitretp] == subi1)
    assert(consumer_heap.memory[waitretp+4] == Subtask.State.RETURNED)
    [] = canon_subtask_drop(subi1)
    fut1_2.set()

    [event] = canon_waitable_set_wait(MemInst(consumer_heap.memory, 'i32'), seti, waitretp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_heap.memory[waitretp] == subi2)
    assert(consumer_heap.memory[waitretp+4] == Subtask.State.STARTED)
    assert(consumer_heap.memory[retp] == 13)
    fut2.set()

    [event] = canon_waitable_set_wait(MemInst(consumer_heap.memory, 'i32'), seti, waitretp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_heap.memory[waitretp] == subi2)
    assert(consumer_heap.memory[waitretp+4] == Subtask.State.RETURNED)
    assert(consumer_heap.memory[retp] == 44)
    [] = canon_subtask_drop(subi2)
    fut3.set()
    current_thread().wait_until(fut4.is_set)

    [] = canon_task_return([U8Type()], consumer_opts, [42])
    return []

  ft = FuncType([BoolType()],[U8Type()], async_=True)

  def on_start():
    return [ True ]

  got = None
  def on_resolve(results):
    nonlocal got
    got = results

  lift_and_run(consumer_opts, consumer_inst, ft, consumer, on_start, on_resolve)
  assert(len(got) == 1)
  assert(got[0] == 42)


def test_async_callback():
  store = Store()
  producer_inst = ComponentInstance(store)
  producer_opts = mk_opts()
  producer_opts.async_ = True
  producer_ft = FuncType([], [], async_ = True)

  def core_producer_pre(fut, args):
    assert(len(args) == 0)
    current_thread().wait_until(fut.is_set)
    canon_task_return([], producer_opts, [])
    return []
  fut1 = RacyBool(False)
  core_producer1 = partial(core_producer_pre, fut1)
  producer1 = store.lift(core_producer1, producer_ft, producer_opts, producer_inst)
  fut2 = RacyBool(False)
  core_producer2 = partial(core_producer_pre, fut2)
  producer2 = store.lift(core_producer2, producer_ft, producer_opts, producer_inst)

  consumer_inst = ComponentInstance(store)
  consumer_ft = FuncType([],[U32Type()], async_ = True)
  consumer_inst = ComponentInstance(store)
  seti = 0
  def consumer(args):
    assert(len(args) == 0)

    [ret] = store.lower(producer1, producer_ft, opts, consumer_inst)([])
    state,subi1 = unpack_result(ret)
    assert(subi1 == 1)
    assert(state == Subtask.State.STARTED)

    [ret] = store.lower(producer2, producer_ft, opts, consumer_inst)([])
    state,subi2 = unpack_result(ret)
    assert(subi2 == 2)
    assert(state == Subtask.State.STARTED)

    nonlocal seti
    [seti] = canon_waitable_set_new()
    assert(seti == 3)
    [] = canon_waitable_join(subi1, seti)
    [] = canon_waitable_join(subi2, seti)

    fut1.set()
    [] = canon_context_set('i32', 0, 42)
    return [definitions.CallbackCode.WAIT|(seti << 4)]

  def callback(args):
    assert(len(args) == 3)
    [ctx] = canon_context_get('i32', 0)
    match ctx:
      case 42:
        assert(args[0] == EventCode.SUBTASK)
        assert(args[1] == 1)
        assert(args[2] == Subtask.State.RETURNED)
        subi = args[1]
        canon_subtask_drop(subi)
        [] = canon_context_set('i32', 0, 52)
        return [definitions.CallbackCode.YIELD]
      case 52:
        assert(args[0] == EventCode.NONE)
        assert(args[1] == 0)
        assert(args[2] == 0)
        fut2.set()
        [] = canon_context_set('i32', 0, 62)
        return [definitions.CallbackCode.WAIT | (seti << 4)]
      case 62:
        assert(args[0] == EventCode.SUBTASK)
        assert(args[1] == 2)
        assert(args[2] == Subtask.State.RETURNED)
        subi = args[1]
        canon_subtask_drop(subi)
        [] = canon_task_return([U32Type()], opts, [83])
        return [definitions.CallbackCode.EXIT]
      case _:
        assert(False)

  def on_start(): return []

  got = None
  def on_resolve(results):
    nonlocal got
    got = results

  opts = mk_opts()
  opts.async_ = True
  opts.callback = callback

  lift_and_run(opts, consumer_inst, consumer_ft, consumer, on_start, on_resolve)
  assert(got[0] == 83)


def test_callback_interleaving():
  store = Store()
  producer_inst = ComponentInstance(store)
  producer_ft = FuncType([U32Type(), FutureType(None),FutureType(None),FutureType(None)],[U32Type()], async_ = True)
  fut3s = [None,None]
  def core_producer(args):
    [i,fut1,fut2,fut3] = args
    fut3s[i] = fut3

    [] = canon_context_set('i32', 0, i)

    sync_opts = mk_opts()
    [ret] = canon_future_read(FutureType(None), sync_opts, fut1, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    [seti] = canon_waitable_set_new()

    async_opts = mk_opts(async_ = True)
    [ret] = canon_future_read(FutureType(None), async_opts, fut2, 0xdeadbeef)
    assert(ret == definitions.BLOCKED)

    [] = canon_waitable_join(fut2, seti)
    return [CallbackCode.WAIT|(seti << 4)]

  def core_producer_callback(args):
    [event,payload1,payload2] = args
    assert(event == EventCode.FUTURE_READ)
    assert(payload2 == CopyResult.COMPLETED)

    [i] = canon_context_get('i32', 0)
    [] = canon_task_return([U32Type()], mk_opts(), [42 + i])

    fut3 = fut3s[i]
    sync_opts = mk_opts()
    [ret] = canon_future_read(FutureType(None), sync_opts, fut3, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    return [CallbackCode.EXIT]
  producer_opts = mk_opts()
  producer_opts.async_ = True
  producer_opts.callback = core_producer_callback
  producer_callee = store.lift(core_producer, producer_ft, producer_opts, producer_inst)

  sync_callee_ft = FuncType([], [U32Type()], async_ = True)
  def core_sync_callee(args):
    assert(len(args) == 0)
    return [100]
  sync_callee_opts = mk_opts()
  sync_callee = store.lift(core_sync_callee, sync_callee_ft, sync_callee_opts, producer_inst)

  consumer_inst = ComponentInstance(store)
  consumer_ft = FuncType([], [], async_ = True)
  consumer_mem = bytearray(24)
  consumer_opts = mk_opts(MemInst(consumer_mem, 'i32'), async_ = True)
  def core_consumer(args):
    assert(len(args) == 0)

    [packed] = canon_future_new(FutureType(None))
    rfut11,wfut11 = unpack_new_ends(packed)
    [packed] = canon_future_new(FutureType(None))
    rfut12,wfut12 = unpack_new_ends(packed)
    [packed] = canon_future_new(FutureType(None))
    rfut13,wfut13 = unpack_new_ends(packed)
    [packed] = canon_future_new(FutureType(None))
    rfut21,wfut21 = unpack_new_ends(packed)
    [packed] = canon_future_new(FutureType(None))
    rfut22,wfut22 = unpack_new_ends(packed)
    [packed] = canon_future_new(FutureType(None))
    rfut23,wfut23 = unpack_new_ends(packed)

    producer_inst.backpressure = True
    [ret] = store.lower(producer_callee, producer_ft, consumer_opts, consumer_inst)([0, rfut11, rfut12, rfut13, 0xdeadbeef])
    state,todie = unpack_result(ret)
    assert(state == Subtask.State.STARTING)
    [ret] = canon_subtask_cancel(False, todie)
    assert(ret == Subtask.State.CANCELLED_BEFORE_STARTED)
    producer_inst.backpressure = False

    subi1ret = 12
    [ret] = store.lower(producer_callee, producer_ft, consumer_opts, consumer_inst)([0, rfut11, rfut12, rfut13, subi1ret])
    state,subi1 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)

    [ret] = store.lower(producer_callee, producer_ft, consumer_opts, consumer_inst)([1, rfut21, rfut22, rfut23, 0xdeadbeef])
    state,todie = unpack_result(ret)
    assert(state == Subtask.State.STARTING)

    [ret] = canon_subtask_cancel(False, todie)
    assert(ret == Subtask.State.CANCELLED_BEFORE_STARTED)

    subi2ret = 16
    [ret] = store.lower(producer_callee, producer_ft, consumer_opts, consumer_inst)([1, rfut21, rfut22, rfut23, subi2ret])
    state,subi2 = unpack_result(ret)
    assert(state == Subtask.State.STARTING)

    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(subi1, seti)
    [] = canon_waitable_join(subi2, seti)

    [ret] = canon_future_write(FutureType(None), consumer_opts, wfut11, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    retp = 0
    [event] = canon_waitable_set_wait(MemInst(consumer_mem, 'i32'), seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_mem[retp+0] == subi2)
    assert(consumer_mem[retp+4] == Subtask.State.STARTED)

    [ret] = canon_future_write(FutureType(None), consumer_opts, wfut12, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    for i in range(10):
      canon_thread_yield()
      retp = 0
      [ret] = canon_waitable_set_poll(MemInst(consumer_mem, 'i32'), seti, retp)
      assert(ret == EventCode.NONE)

    [ret] = canon_future_write(FutureType(None), consumer_opts, wfut21, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    retp = 0
    [event] = canon_waitable_set_wait(MemInst(consumer_mem, 'i32'), seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_mem[retp+0] == subi1)
    assert(consumer_mem[retp+4] == Subtask.State.RETURNED)
    assert(consumer_mem[subi1ret] == 42)
    [] = canon_subtask_drop(subi1)

    [ret] = canon_future_write(FutureType(None), consumer_opts, wfut22, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    for i in range(10):
      canon_thread_yield()
      retp = 0
      [ret] = canon_waitable_set_poll(MemInst(consumer_mem, 'i32'), seti, retp)
      assert(ret == EventCode.NONE)

    [ret] = canon_future_write(FutureType(None), consumer_opts, wfut13, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    retp = 0
    [event] = canon_waitable_set_wait(MemInst(consumer_mem, 'i32'), seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_mem[retp+0] == subi2)
    assert(consumer_mem[retp+4] == Subtask.State.RETURNED)
    assert(consumer_mem[subi2ret] == 43)
    [] = canon_subtask_drop(subi2)

    subi3ret = 20
    [ret] = store.lower(sync_callee, sync_callee_ft, consumer_opts, consumer_inst)([subi3ret])
    state,subi3 = unpack_result(ret)
    assert(state == Subtask.State.STARTING)
    [] = canon_waitable_join(subi3, seti)

    [ret] = canon_future_write(FutureType(None), consumer_opts, wfut23, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    retp = 0
    [event] = canon_waitable_set_wait(MemInst(consumer_mem, 'i32'), seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_mem[retp+0] == subi3)
    assert(consumer_mem[retp+4] == Subtask.State.RETURNED)
    assert(consumer_mem[subi3ret] == 100)

    return []

  lift_and_run(mk_opts(), consumer_inst, consumer_ft, core_consumer, lambda:[], lambda _:())


def test_sync_ignores_backpressure():
  store = Store()
  sync_opts = mk_opts(async_ = False)
  async_opts = mk_opts(async_ = True)

  callee_inst = ComponentInstance(store)

  async_ft = FuncType([U32Type(), FutureType(None)],[U32Type()], async_ = True)
  def core_callee1(args):
    [i,fut] = args
    [ret] = canon_future_read(FutureType(None), sync_opts, fut, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)
    return [42 + i]
  async_callee = store.lift(core_callee1, async_ft, sync_opts, callee_inst)

  sync_ft = FuncType([U32Type()], [U32Type()])
  def core_callee2(args):
    [i] = args
    return [84 + i]
  sync_callee = store.lift(core_callee2, sync_ft, sync_opts, callee_inst)

  caller_inst = ComponentInstance(store)
  caller_ft = FuncType([], [], async_ = True)
  caller_mem = bytearray(24)
  caller_opts = mk_opts(memory = MemInst(caller_mem, 'i32'), async_ = True)
  def core_caller(args):
    assert(len(args) == 0)

    [packed] = canon_future_new(FutureType(None))
    rfut,wfut = unpack_new_ends(packed)

    retp1 = 4
    [ret] = store.lower(async_callee, async_ft, caller_opts, caller_inst)([1, rfut, retp1])
    state,subi = unpack_result(ret)
    assert(state == Subtask.State.STARTED)

    retp2 = 8
    [ret] = store.lower(sync_callee, sync_ft, caller_opts, caller_inst)([2, retp2])
    assert(ret == Subtask.State.RETURNED)
    assert(caller_mem[retp2] == 86)

    [ret] = canon_future_write(FutureType(None), sync_opts, wfut, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)

    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(subi, seti)
    retp3 = 12
    [event] = canon_waitable_set_wait(MemInst(caller_mem, 'i32'), seti, retp3)
    assert(event == EventCode.SUBTASK)
    assert(caller_mem[retp3+0] == subi)
    assert(caller_mem[retp3+4] == Subtask.State.RETURNED)

    [] = canon_subtask_drop(subi)
    return []

  lift_and_run(mk_opts(), caller_inst, caller_ft, core_caller, lambda:[], lambda _:())

def test_async_to_sync():
  store = Store()
  producer_opts = CanonicalOptions()
  producer_inst = ComponentInstance(store)

  producer_ft = FuncType([],[], async_ = True)
  fut = RacyBool(False)
  producer1_done = False
  def producer1_core(args):
    nonlocal producer1_done
    assert(len(args) == 0)
    current_thread().wait_until(fut.is_set)
    producer1_done = True
    return []

  producer2_done = False
  def producer2_core(args):
    nonlocal producer2_done
    assert(len(args) == 0)
    assert(producer1_done == True)
    producer2_done = True
    return []

  producer1 = store.lift(producer1_core, producer_ft, producer_opts, producer_inst)
  producer2 = store.lift(producer2_core, producer_ft, producer_opts, producer_inst)

  consumer_heap = Heap(20)
  consumer_opts = mk_opts(MemInst(consumer_heap.memory, 'i32'))
  consumer_opts.async_ = True
  consumer_inst = ComponentInstance(store)
  consumer_ft = FuncType([],[U8Type()], async_ = True)
  def consumer(args):
    assert(len(args) == 0)

    [ret] = store.lower(producer1, producer_ft, consumer_opts, consumer_inst)([])
    state,subi1 = unpack_result(ret)
    assert(subi1 == 1)
    assert(state == Subtask.State.STARTED)

    [ret] = store.lower(producer2, producer_ft, consumer_opts, consumer_inst)([])
    state,subi2 = unpack_result(ret)
    assert(subi2 == 2)
    assert(state == Subtask.State.STARTING)

    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(subi1, seti)
    [] = canon_waitable_join(subi2, seti)

    fut.set()
    assert(producer1_done == False)
    assert(producer2_done == False)

    remain = [subi1, subi2]
    while remain:
      canon_thread_yield()
      retp = 8
      [event] = canon_waitable_set_poll(MemInst(consumer_heap.memory, 'i32'), seti, retp)
      if event == EventCode.NONE:
        continue
      assert(event == EventCode.SUBTASK)
      assert(consumer_heap.memory[retp+4] == Subtask.State.RETURNED)
      subi = consumer_heap.memory[retp]
      remain.remove(subi)
      canon_subtask_drop(subi)

    assert(producer1_done == True)
    assert(producer2_done == True)

    [] = canon_waitable_set_drop(seti)

    canon_task_return([U8Type()], consumer_opts, [83])
    return []

  def on_start(): return []

  got = None
  def on_resolve(results):
    nonlocal got
    got = results

  lift_and_run(consumer_opts, consumer_inst, consumer_ft, consumer, on_start, on_resolve)
  assert(got[0] == 83)


def test_async_backpressure():
  store = Store()
  producer_opts = CanonicalOptions()
  producer_opts.async_ = True
  producer_inst = ComponentInstance(store)

  producer_ft = FuncType([],[], async_ = True)
  fut = RacyBool(False)
  producer1_done = False
  def producer1_core(args):
    nonlocal producer1_done
    canon_backpressure_inc()
    current_thread().wait_until(fut.is_set)
    canon_backpressure_dec()
    canon_task_return([], producer_opts, [])
    producer1_done = True
    return []

  producer2_done = False
  def producer2_core(args):
    nonlocal producer2_done
    assert(producer1_done == True)
    canon_task_return([], producer_opts, [])
    producer2_done = True
    return []

  producer1 = store.lift(producer1_core, producer_ft, producer_opts, producer_inst)
  producer2 = store.lift(producer2_core, producer_ft, producer_opts, producer_inst)

  consumer_heap = Heap(20)
  consumer_opts = mk_opts(MemInst(consumer_heap.memory, 'i32'), async_ = True)
  consumer_inst = ComponentInstance(store)
  consumer_ft = FuncType([],[U8Type()], async_ = True)
  def consumer(args):
    assert(len(args) == 0)

    [ret] = store.lower(producer1, producer_ft, consumer_opts, consumer_inst)([])
    state,subi1 = unpack_result(ret)
    assert(subi1 == 1)
    assert(state == Subtask.State.STARTED)

    [ret] = store.lower(producer2, producer_ft, consumer_opts, consumer_inst)([])
    state,subi2 = unpack_result(ret)
    assert(subi2 == 2)
    assert(state == Subtask.State.STARTING)

    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(subi1, seti)
    [] = canon_waitable_join(subi2, seti)

    fut.set()
    assert(producer1_done == False)
    assert(producer2_done == False)

    remain = [subi1, subi2]
    while remain:
      retp = 8
      [event] = canon_waitable_set_wait(MemInst(consumer_heap.memory, 'i32'), seti, retp)
      assert(event == EventCode.SUBTASK)
      assert(consumer_heap.memory[retp+4] == Subtask.State.RETURNED)
      subi = consumer_heap.memory[retp]
      remain.remove(subi)
      canon_subtask_drop(subi)

    assert(producer1_done == True)
    assert(producer2_done == True)

    [] = canon_waitable_set_drop(seti)

    canon_task_return([U8Type()], consumer_opts, [84])
    return []

  def on_start(): return []

  got = None
  def on_resolve(results):
    nonlocal got
    got = results

  lift_and_run(consumer_opts, consumer_inst, consumer_ft, consumer, on_start, on_resolve)
  assert(got[0] == 84)


def test_sync_using_wait():
  store = Store()
  producer_opts = mk_opts()
  producer_opts.async_ = True
  producer_inst = ComponentInstance(store)
  ft = FuncType([], [], async_ = True)

  def core_producer_pre(fut, args):
    current_thread().wait_until(fut.is_set)
    [] = canon_task_return([], producer_opts, [])
    return []
  fut1 = RacyBool(False)
  core_producer1 = partial(core_producer_pre, fut1)
  producer1 = store.lift(core_producer1, ft, producer_opts, producer_inst)
  fut2 = RacyBool(False)
  core_producer2 = partial(core_producer_pre, fut2)
  producer2 = store.lift(core_producer2, ft, producer_opts, producer_inst)

  consumer_heap = Heap(20)
  consumer_opts = mk_opts(MemInst(consumer_heap.memory, 'i32'))
  consumer_opts.async_ = True
  consumer_inst = ComponentInstance(store)

  def core_func(args):
    [ret] = store.lower(producer1, ft, consumer_opts, consumer_inst)([])
    state,subi1 = unpack_result(ret)
    assert(subi1 == 1)
    assert(state == Subtask.State.STARTED)
    [ret] = store.lower(producer2, ft, consumer_opts, consumer_inst)([])
    state,subi2 = unpack_result(ret)
    assert(subi2 == 2)
    assert(state == Subtask.State.STARTED)

    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(subi1, seti)
    [] = canon_waitable_join(subi2, seti)

    fut1.set()

    [retp] = consumer_heap.realloc([0,0,8,4])
    [event] = canon_waitable_set_wait(MemInst(consumer_heap.memory, 'i32'), seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_heap.memory[retp] == subi1)
    assert(consumer_heap.memory[retp+4] == Subtask.State.RETURNED)

    fut2.set()

    [event] = canon_waitable_set_wait(MemInst(consumer_heap.memory, 'i32'), seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(consumer_heap.memory[retp] == subi2)
    assert(consumer_heap.memory[retp+4] == Subtask.State.RETURNED)

    canon_subtask_drop(subi1)
    canon_subtask_drop(subi2)
    canon_waitable_set_drop(seti)

    return []

  def on_start(): return []
  def on_resolve(results): pass
  lift_and_run(mk_opts(), consumer_inst, ft, core_func, on_start, on_resolve)


class HostReadableBuffer(ReadableBuffer):
  vs: list[any]
  progress: int

  def __init__(self, t, vs):
    self.t = t
    self.vs = vs
    self.progress = 0

  def remain(self):
    return len(self.vs) - self.progress

  def is_zero_length(self):
    return len(self.vs) == 0

  def read(self, n):
    assert(n <= self.remain())
    vs = self.vs[self.progress : self.progress + n]
    self.progress += n
    return vs

class HostWritableBuffer(WritableBuffer):
  length: int
  progress: int
  received: list[any]

  def __init__(self, t, length):
    self.t = t
    self.length = length
    self.progress = 0
    self.received = []

  def remain(self):
    return self.length - self.progress

  def is_zero_length(self):
    return self.length == 0

  def write(self, vs):
    assert(len(vs) <= self.remain())
    self.received += vs
    self.progress += len(vs)

class HostWriter:
  end: WritableStreamEnd
  queue: list[any]
  chunk: int
  drop_when_empty: bool
  buffer: Optional[HostReadableBuffer]

  def __init__(self, t, vs = (), chunk = Buffer.MAX_LENGTH, drop_when_empty = True):
    stream = Stream(t)
    self.end = stream.writable_end
    self.queue = list(vs)
    self.chunk = chunk
    self.drop_when_empty = drop_when_empty
    self.buffer = None
    self.start_copy()

  def write(self, vs):
    assert(not self.end.shared.dropped)
    self.queue += vs
    self.start_copy()

  def end_when_empty(self):
    self.drop_when_empty = True
    self.start_copy()

  def start_copy(self):
    if self.buffer is not None or self.end.shared.dropped:
      return
    if not self.queue:
      if self.drop_when_empty:
        self.end.shared.drop()
      return
    self.buffer = HostReadableBuffer(self.end.shared.t, self.queue[:self.chunk])
    self.end.shared.write(None, self.buffer, self.on_copy_done, self.on_partial_copy)

  def on_copy_done(self, result):
    self.finish_copy()

  def on_partial_copy(self):
    self.end.shared.reset_pending()
    self.finish_copy()

  def finish_copy(self):
    del self.queue[:self.buffer.progress]
    self.buffer = None
    self.start_copy()

class HostReader:
  end: ReadableStreamEnd
  received: list[any]
  remain: int
  dropped: bool
  buffer: Optional[HostWritableBuffer]
  on_data: Optional[Callable[[HostReader], None]]

  def __init__(self, end, remain = Buffer.MAX_LENGTH, on_data = None):
    self.end = end
    self.received = []
    self.remain = remain
    self.dropped = False
    self.buffer = None
    self.on_data = on_data
    self.start_copy()

  def set_remain(self, remain):
    self.remain = remain
    self.start_copy()

  def take(self):
    received = self.received
    self.received = []
    return received

  def start_copy(self):
    if self.buffer is not None or self.dropped or self.remain == 0:
      return
    self.buffer = HostWritableBuffer(self.end.shared.t, self.remain)
    self.end.shared.read(None, self.buffer, self.on_copy_done, self.on_partial_copy)

  def on_copy_done(self, result):
    if result == CopyResult.DROPPED:
      self.dropped = True
    self.drain()
    self.buffer = None
    self.start_copy()

  def on_partial_copy(self):
    self.drain()

  def drain(self):
    self.received += self.buffer.received
    self.remain -= len(self.buffer.received)
    self.buffer.received = []
    if self.on_data:
      self.on_data(self)

def test_eager_stream_completion():
  store = Store()
  inst = ComponentInstance(store)
  mem = bytearray(20)
  opts = mk_opts(memory=MemInst(mem, 'i32'), async_=True)
  sync_opts = mk_opts(memory=MemInst(mem, 'i32'), async_=False)

  ft = FuncType([StreamType(U8Type())], [StreamType(U8Type())])
  def host_func(on_start, on_resolve, wait_until):
    [incoming_readable_end] = on_start()
    assert(isinstance(incoming_readable_end, ReadableStreamEnd))
    host_writer = HostWriter(U8Type(), chunk=4, drop_when_empty=False)
    def add10(reader):
      vs = reader.take()
      if vs:
        host_writer.write([v + 10 for v in vs])
      if reader.dropped:
        host_writer.end_when_empty()
    HostReader(incoming_readable_end, on_data = add10)
    on_resolve([host_writer.end.shared.readable_end])
  host_func_inst = mk_host_func(store, host_func, ft)

  host_writer = HostWriter(U8Type(), [1,2,3,4,5,6,7,8], chunk=4)
  def on_start():
    return [host_writer.end.shared.readable_end]

  host_reader = None
  def on_resolve(results):
    [readable_end] = results
    assert(isinstance(readable_end, ReadableStreamEnd))
    nonlocal host_reader
    host_reader = HostReader(readable_end)

  def core_func(args):
    assert(len(args) == 1)
    rsi1 = args[0]
    assert(rsi1 == 1)
    [packed] = canon_stream_new(StreamType(U8Type()))
    rsi2,wsi2 = unpack_new_ends(packed)
    [] = canon_task_return([StreamType(U8Type())], opts, [rsi2])
    [ret] = canon_stream_read(StreamType(U8Type()), opts, rsi1, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    assert(mem[0:4] == b'\x01\x02\x03\x04')
    [packed] = canon_stream_new(StreamType(U8Type()))
    rsi3,wsi3 = unpack_new_ends(packed)
    retp = 12
    [ret] = store.lower(host_func_inst, ft, opts, inst)([rsi3, retp])
    assert(ret == Subtask.State.RETURNED)
    rsi4 = mem[retp]
    [ret] = canon_stream_write(StreamType(U8Type()), opts, wsi3, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(U8Type()), sync_opts, rsi4, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, wsi2, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(U8Type()), opts, rsi1, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.DROPPED)
    assert(mem[0:4] == b'\x05\x06\x07\x08')
    [ret] = canon_stream_write(StreamType(U8Type()), sync_opts, wsi3, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(U8Type()), sync_opts, rsi4, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_write(StreamType(U8Type()), sync_opts, wsi2, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_readable(StreamType(U8Type()), rsi1)
    [] = canon_stream_drop_readable(StreamType(U8Type()), rsi4)
    [] = canon_stream_drop_writable(StreamType(U8Type()), wsi2)
    [] = canon_stream_drop_writable(StreamType(U8Type()), wsi3)
    return []

  lift_and_run(opts, inst, ft, core_func, on_start, on_resolve)
  assert(host_reader.received == [11,12,13,14,15,16,17,18])


def test_async_stream_ops():
  store = Store()
  inst = ComponentInstance(store)
  mem = bytearray(24)
  opts = mk_opts(memory=MemInst(mem, 'i32'), async_=True)
  sync_opts = mk_opts(memory=MemInst(mem, 'i32'), async_=False)

  host_reader = None
  host_writer = None
  ft = FuncType([StreamType(U8Type())], [StreamType(U8Type())], async_ = True)
  def host_func(on_start, on_resolve, wait_until):
    nonlocal host_reader, host_writer
    [readable_end] = on_start()
    assert(isinstance(readable_end, ReadableStreamEnd))
    host_reader = HostReader(readable_end, remain = 0)
    host_writer = HostWriter(U8Type(), chunk=4, drop_when_empty=False)
    on_resolve([host_writer.end.shared.readable_end])
    while True:
      wait_until(lambda: host_reader.received or host_reader.dropped)
      vs = host_reader.take()
      if not vs:
        break
      host_writer.write([v + 10 for v in vs])
  host_func_inst = mk_host_func(store, host_func, ft)

  host_writer2 = HostWriter(U8Type(), chunk=4, drop_when_empty = False)
  def on_start():
    return [host_writer2.end.shared.readable_end]

  host_reader2 = None
  def on_resolve(results):
    [readable_end] = results
    nonlocal host_reader2
    host_reader2 = HostReader(readable_end, remain = 0)

  def core_func(args):
    [rsi1] = args
    assert(rsi1 == 1)
    [packed] = canon_stream_new(StreamType(U8Type()),)
    rsi2,wsi2 = unpack_new_ends(packed)
    [] = canon_task_return([StreamType(U8Type())], opts, [rsi2])
    [ret] = canon_stream_read(StreamType(U8Type()), opts, rsi1, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_writer2.write([1,2,3,4])
    retp = 16
    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(rsi1, seti)
    [event] = canon_waitable_set_wait(MemInst(mem, 'i32'), seti, retp) ##
    assert(event == EventCode.STREAM_READ)
    assert(mem[retp+0] == rsi1)
    result,n = unpack_result(mem[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)
    assert(mem[0:4] == b'\x01\x02\x03\x04')
    [packed] = canon_stream_new(StreamType(U8Type()))
    rsi3,wsi3 = unpack_new_ends(packed)
    [ret] = store.lower(host_func_inst, ft, opts, inst)([rsi3, retp])
    assert(ret == Subtask.State.RETURNED)
    rsi4 = mem[16]
    assert(rsi4 == 4)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, wsi3, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_reader.set_remain(100)
    [] = canon_waitable_join(wsi3, seti)
    [event] = canon_waitable_set_wait(MemInst(mem, 'i32'), seti, retp)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem[retp+0] == wsi3)
    result,n = unpack_result(mem[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(U8Type()), sync_opts, rsi4, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, wsi2, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_reader2.set_remain(100)
    [] = canon_waitable_join(wsi2, seti)
    [event] = canon_waitable_set_wait(MemInst(mem, 'i32'), seti, retp)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem[retp+0] == wsi2)
    result,n = unpack_result(mem[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)
    host_writer2.write([5,6,7,8])
    host_writer2.end_when_empty()
    [ret] = canon_stream_read(StreamType(U8Type()), opts, rsi1, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.DROPPED)
    assert(mem[0:4] == b'\x05\x06\x07\x08')
    [] = canon_stream_drop_readable(StreamType(U8Type()), rsi1)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, wsi3, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_writable(StreamType(U8Type()), wsi3)
    [ret] = canon_stream_read(StreamType(U8Type()), opts, rsi4, 0, 4)
    assert(ret == definitions.BLOCKED)
    [] = canon_waitable_join(rsi4, seti)
    [event] = canon_waitable_set_wait(MemInst(mem, 'i32'), seti, retp)
    assert(event == EventCode.STREAM_READ)
    assert(mem[retp+0] == rsi4)
    [] = canon_waitable_join(rsi4, 0)
    result,n = unpack_result(mem[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)
    host_writer.end_when_empty()
    [ret] = canon_stream_read(StreamType(U8Type()), sync_opts, rsi4, 0, 4)
    assert(ret == CopyResult.DROPPED)
    [] = canon_stream_drop_readable(StreamType(U8Type()), rsi4)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, wsi2, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_writable(StreamType(U8Type()), wsi2)
    [] = canon_waitable_set_drop(seti)
    return []

  lift_and_run(opts, inst, ft, core_func, on_start, on_resolve)
  assert(host_reader2.received == [11,12,13,14,15,16,17,18])


def test_stream_forward():
  host_writer = HostWriter(U8Type(), [1,2,3,4], chunk=4)
  def on_start():
    return [host_writer.end.shared.readable_end]

  return_value = None
  def on_resolve(results):
    nonlocal return_value
    [return_value] = results

  def core_func(args):
    assert(len(args) == 1)
    rsi1 = args[0]
    assert(rsi1 == 1)
    return [rsi1]

  opts = mk_opts()
  inst = ComponentInstance(Store())
  ft = FuncType([StreamType(U8Type())], [StreamType(U8Type())])
  lift_and_run(opts, inst, ft, core_func, on_start, on_resolve)
  assert(host_writer.end.shared.readable_end is return_value)


def test_forward_builtins():
  store = Store()
  mem = bytearray(32)
  opts = mk_opts(memory=MemInst(mem, 'i32'), async_=True)
  inst = ComponentInstance(store)
  st = StreamType(U8Type())
  st2 = StreamType(U32Type())
  ft = FutureType(U8Type())

  def core_func(args):
    def new_stream(t = st):
      [packed] = canon_stream_new(t)
      return unpack_new_ends(packed)
    def new_future():
      [packed] = canon_future_new(ft)
      return unpack_new_ends(packed)
    def expect_trap(f):
      try:
        f()
        assert(False)
      except Trap:
        pass

    ## the trap cases of 'forward_copy'

    # 'ri' isn't a readable end, isn't a readable *future* end, or has the
    # wrong element type
    rsi,wsi = new_stream()
    expect_trap(lambda: canon_stream_forward(st, wsi, rsi))
    rsi,wsi = new_stream()
    expect_trap(lambda: canon_future_forward(ft, rsi, wsi))
    rsi,wsi = new_stream()
    expect_trap(lambda: canon_stream_forward(st2, rsi, wsi))

    # ... and symmetrically for 'wi'
    rsi1,_ = new_stream()
    rsi2,_ = new_stream()
    expect_trap(lambda: canon_stream_forward(st, rsi1, rsi2))
    rsi,_ = new_stream()
    _,wsi2 = new_stream(st2)
    expect_trap(lambda: canon_stream_forward(st, rsi, wsi2))

    # an end is in the middle of a copy
    rsi,wsi = new_stream()
    [ret] = canon_stream_read(st, opts, rsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    expect_trap(lambda: canon_stream_forward(st, rsi, wsi))
    rsi,wsi = new_stream()
    [ret] = canon_stream_write(st, opts, wsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    expect_trap(lambda: canon_stream_forward(st, rsi, wsi))

    # an end is in a waitable set (using a set of its own, since the traps leave
    # these ends out of the handle table but still joined)
    [trap_seti] = canon_waitable_set_new()
    rsi,wsi = new_stream()
    [] = canon_waitable_join(rsi, trap_seti)
    expect_trap(lambda: canon_stream_forward(st, rsi, wsi))
    rsi,wsi = new_stream()
    [] = canon_waitable_join(wsi, trap_seti)
    expect_trap(lambda: canon_stream_forward(st, rsi, wsi))

    ## 'ri' and 'wi' are the two ends of the same stream: nothing is forwarded,
    ## but both handles are removed all the same
    rsi,wsi = new_stream()
    [] = canon_stream_forward(st, rsi, wsi)
    expect_trap(lambda: canon_stream_read(st, opts, rsi, 0, 4))

    ## forward_to: the sink is already dropped, so the source is dropped too and
    ## the source's writer is the one told about it
    rsi1,wsi1 = new_stream()
    rsi2,wsi2 = new_stream()
    [] = canon_stream_drop_readable(st, rsi2)
    [] = canon_stream_forward(st, rsi1, wsi2)
    [ret] = canon_stream_write(st, opts, wsi1, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 0 and result == CopyResult.DROPPED)
    [] = canon_stream_drop_writable(st, wsi1)

    ## forward_to: neither dropped nor mid-copy, so just the pointer swap; the
    ## sink's reader then reads what the source's writer writes
    rsi1,wsi1 = new_stream()
    rsi2,wsi2 = new_stream()
    [] = canon_stream_forward(st, rsi1, wsi2)
    mem[0:4] = b'\x01\x02\x03\x04'
    [ret] = canon_stream_write(st, opts, wsi1, 0, 4)
    assert(ret == definitions.BLOCKED)
    [ret] = canon_stream_read(st, opts, rsi2, 8, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    assert(mem[8:12] == b'\x01\x02\x03\x04')

    ## forward_to: the sink's reader is already blocked, so its buffer is
    ## re-issued against the source and the event it eventually gets is the
    ## source's copy
    rsi1,wsi1 = new_stream()
    rsi2,wsi2 = new_stream()
    [ret] = canon_stream_read(st, opts, rsi2, 8, 4)
    assert(ret == definitions.BLOCKED)
    [] = canon_stream_forward(st, rsi1, wsi2)
    mem[0:4] = b'\x05\x06\x07\x08'
    [ret] = canon_stream_write(st, opts, wsi1, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    assert(mem[8:12] == b'\x05\x06\x07\x08')
    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(rsi2, seti)
    [event] = canon_waitable_set_wait(MemInst(mem, 'i32'), seti, 16)
    assert(event == EventCode.STREAM_READ)
    assert(mem[16] == rsi2)
    result,n = unpack_result(mem[20])
    assert(n == 4 and result == CopyResult.COMPLETED)

    ## future.forward: the sink's reader is blocked but the source's writer
    ## isn't, so the read is simply left pending on the source
    rfi1,wfi1 = new_future()
    rfi2,wfi2 = new_future()
    [ret] = canon_future_read(ft, opts, rfi2, 8)
    assert(ret == definitions.BLOCKED)
    [] = canon_future_forward(ft, rfi1, wfi2)
    mem[0] = 42
    [ret] = canon_future_write(ft, opts, wfi1, 0)
    assert(ret == CopyResult.COMPLETED)
    assert(mem[8] == 42)

    ## future.forward: both sides are already blocked, so the rendezvous happens
    ## inside 'forward' itself
    rfi1,wfi1 = new_future()
    rfi2,wfi2 = new_future()
    mem[0] = 43
    [ret] = canon_future_write(ft, opts, wfi1, 0)
    assert(ret == definitions.BLOCKED)
    [ret] = canon_future_read(ft, opts, rfi2, 8)
    assert(ret == definitions.BLOCKED)
    [] = canon_future_forward(ft, rfi1, wfi2)
    assert(mem[8] == 43)

    ## future.forward: the sink is already dropped
    rfi1,wfi1 = new_future()
    rfi2,wfi2 = new_future()
    [] = canon_future_drop_readable(ft, rfi2)
    [] = canon_future_forward(ft, rfi1, wfi2)
    [ret] = canon_future_write(ft, opts, wfi1, 0)
    assert(ret == CopyResult.DROPPED)
    [] = canon_future_drop_writable(ft, wfi1)

    return []

  caller_ft = FuncType([], [], async_ = True)
  lift_and_run(mk_opts(), inst, caller_ft, core_func, lambda:[], lambda _:())


def test_receive_own_stream():
  store = Store()
  inst = ComponentInstance(store)
  mem = bytearray(20)
  opts = mk_opts(memory=MemInst(mem, 'i32'), async_=True)

  host_ft = FuncType([StreamType(U8Type())], [StreamType(U8Type())])
  def host_func(on_start, on_resolve, wait_until):
    args = on_start()
    assert(len(args) == 1)
    assert(isinstance(args[0], ReadableStreamEnd))
    on_resolve(args)
  host_func_inst = mk_host_func(store, host_func, host_ft)

  def core_func(args):
    assert(len(args) == 0)
    [packed] = canon_stream_new(StreamType(U8Type()))
    rsi,wsi = unpack_new_ends(packed)
    assert(rsi == 1)
    assert(wsi == 2)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, wsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    retp = 8
    [ret] = store.lower(host_func_inst, host_ft, opts, inst)([rsi, retp])
    assert(ret == Subtask.State.RETURNED)
    rsi2 = int.from_bytes(mem[retp : retp+4], 'little', signed=False)
    assert(rsi2 == 1)
    [ret] = canon_stream_cancel_write(StreamType(U8Type()), False, wsi)
    result,n = unpack_result(ret)
    assert(result == CopyResult.CANCELLED and n == 0)
    [] = canon_stream_drop_writable(StreamType(U8Type()), wsi)
    return []

  def on_start(): return []
  def on_resolve(results): assert(len(results) == 0)
  ft = FuncType([],[], async_ = True)
  lift_and_run(mk_opts(), inst, ft, core_func, on_start, on_resolve)


def test_host_partial_reads_writes():
  store = Store()
  mem = bytearray(20)
  opts = mk_opts(memory=MemInst(mem, 'i32'), async_=True)
  inst = ComponentInstance(store)

  host_writer = HostWriter(U8Type(), [1,2,3,4], chunk=2, drop_when_empty = False)
  source_ft = FuncType([], [StreamType(U8Type())])
  def host_source_func(on_start, on_resolve, wait_until):
    [] = on_start()
    on_resolve([host_writer.end.shared.readable_end])
  host_source_func_inst = mk_host_func(store, host_source_func, source_ft)

  host_reader = None
  sink_ft = FuncType([StreamType(U8Type())], [])
  def host_sink_func(on_start, on_resolve, wait_until):
    nonlocal host_reader
    [readable_end] = on_start()
    host_reader = HostReader(readable_end, remain=2)
    on_resolve([])
  host_sink_func_inst = mk_host_func(store, host_sink_func, sink_ft)

  def core_func(args):
    assert(len(args) == 0)
    retp = 4
    [ret] = store.lower(host_source_func_inst, source_ft, opts, inst)([retp])
    assert(ret == Subtask.State.RETURNED)
    rsi = mem[retp]
    assert(rsi == 1)
    [ret] = canon_stream_read(StreamType(U8Type()), opts, rsi, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    assert(mem[0:2] == b'\x01\x02')
    [ret] = canon_stream_read(StreamType(U8Type()), opts, rsi, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    assert(mem[0:2] == b'\x03\x04')
    [ret] = canon_stream_read(StreamType(U8Type()), opts, rsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_writer.write([5,6])

    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(rsi, seti)
    [event] = canon_waitable_set_wait(MemInst(mem, 'i32'), seti, retp)
    assert(event == EventCode.STREAM_READ)
    assert(mem[retp+0] == rsi)
    result,n = unpack_result(mem[retp+4])
    assert(n == 2 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_readable(StreamType(U8Type()), rsi)

    [packed] = canon_stream_new(StreamType(U8Type()))
    rsi,wsi = unpack_new_ends(packed)
    assert(rsi == 1)
    assert(wsi == 3)
    [ret] = store.lower(host_sink_func_inst, sink_ft, opts, inst)([rsi])
    assert(ret == Subtask.State.RETURNED)
    mem[0:6] = b'\x01\x02\x03\x04\x05\x06'
    [ret] = canon_stream_write(StreamType(U8Type()), opts, wsi, 0, 6)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_write(StreamType(U8Type()), opts, wsi, 2, 4)
    assert(ret == definitions.BLOCKED)
    host_reader.set_remain(4)
    [] = canon_waitable_join(wsi, seti)
    [event] = canon_waitable_set_wait(MemInst(mem, 'i32'), seti, retp)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem[retp+0] == wsi)
    result,n = unpack_result(mem[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)
    assert(host_reader.received == [1,2,3,4,5,6])
    [] = canon_stream_drop_writable(StreamType(U8Type()), wsi)
    [] = canon_waitable_set_drop(seti)
    host_reader.set_remain(100)
    assert(host_reader.dropped)
    return []

  opts2 = mk_opts()
  def on_start(): return []
  def on_resolve(results): assert(len(results) == 0)
  ft = FuncType([],[], async_ = True)
  lift_and_run(opts2, inst, ft, core_func, on_start, on_resolve)


def test_wasm_to_wasm_stream():
  store = Store()
  fut1, fut2, fut3, fut4 = RacyBool(False), RacyBool(False), RacyBool(False), RacyBool(False)

  inst1 = ComponentInstance(store)
  mem1 = bytearray(24)
  opts1 = mk_opts(memory=MemInst(mem1, 'i32'), async_=True)
  ft1 = FuncType([], [StreamType(U8Type())])
  def core_func1(args):
    thread = current_thread()
    assert(not args)
    [packed] = canon_stream_new(StreamType(U8Type()))
    rsi,wsi = unpack_new_ends(packed)
    [] = canon_task_return([StreamType(U8Type())], opts1, [rsi])

    thread.wait_until(fut1.is_set)

    mem1[0:4] = b'\x01\x02\x03\x04'
    [ret] = canon_stream_write(StreamType(U8Type()), opts1, wsi, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_write(StreamType(U8Type()), opts1, wsi, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 4 and result == CopyResult.COMPLETED)

    [ret] = canon_stream_write(StreamType(U8Type()), opts1, wsi, 0, 0)
    assert(ret == definitions.BLOCKED)
    [ret] = canon_stream_cancel_write(StreamType(U8Type()), True, wsi)
    result,n = unpack_result(ret)
    assert(n == 0 and result == CopyResult.CANCELLED)

    thread.wait_until(fut2.is_set)

    mem1[0:8] = b'\x05\x06\x07\x08\x09\x0a\x0b\x0c'
    [ret] = canon_stream_write(StreamType(U8Type()), opts1, wsi, 0, 8)
    assert(ret == definitions.BLOCKED)

    fut3.set()

    retp = 16
    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(wsi, seti)
    [event] = canon_waitable_set_wait(MemInst(mem1, 'i32'), seti, retp)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem1[retp+0] == wsi)
    result,n = unpack_result(mem1[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)

    [ret] = canon_stream_write(StreamType(U8Type()), opts1, wsi, 12345, 0)
    assert(ret == definitions.BLOCKED)

    fut4.set()

    [event] = canon_waitable_set_wait(MemInst(mem1, 'i32'), seti, retp)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem1[retp+0] == wsi)
    assert(mem1[retp+4] == 0)

    [ret] = canon_stream_write(StreamType(U8Type()), opts1, wsi, 12345, 0)
    assert(ret == 0)

    [errctxi] = canon_error_context_new(opts1, 0, 0)
    [] = canon_stream_drop_writable(StreamType(U8Type()), wsi)
    [] = canon_waitable_set_drop(seti)
    [] = canon_error_context_drop(errctxi)
    return []

  func1 = store.lift(core_func1, ft1, opts1, inst1)

  inst2 = ComponentInstance(store)
  heap2 = Heap(24)
  mem2 = heap2.memory
  opts2 = mk_opts(memory=MemInst(heap2.memory, 'i32'), realloc=heap2.realloc, async_=True)
  ft2 = FuncType([], [])
  def core_func2(args):
    thread = current_thread()
    assert(not args)
    [] = canon_task_return([], opts2, [])

    retp = 16
    [ret] = store.lower(func1, ft1, opts2, inst2)([retp])
    assert(ret == Subtask.State.RETURNED)
    rsi = mem2[retp]
    assert(rsi == 1)

    [ret] = canon_stream_read(StreamType(U8Type()), opts2, rsi, 0, 8)
    assert(ret == definitions.BLOCKED)

    fut1.set()

    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(rsi, seti)
    [event] = canon_waitable_set_wait(MemInst(mem2, 'i32'), seti, retp)
    assert(event == EventCode.STREAM_READ)
    assert(mem2[retp+0] == rsi)
    result,n = unpack_result(mem2[retp+4])
    assert(n == 8 and result == CopyResult.COMPLETED)
    assert(mem2[0:8] == b'\x01\x02\x03\x04\x01\x02\x03\x04')

    fut2.set()
    thread.wait_until(fut3.is_set)

    [ret] = canon_stream_read(StreamType(U8Type()), opts2, rsi, 12345, 0)
    assert(ret == 0)

    mem2[0:8] = bytes(8)
    [ret] = canon_stream_read(StreamType(U8Type()), opts2, rsi, 0, 2)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    assert(mem2[0:6] == b'\x05\x06\x00\x00\x00\x00')
    [ret] = canon_stream_read(StreamType(U8Type()), opts2, rsi, 2, 2)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    assert(mem2[0:6] == b'\x05\x06\x07\x08\x00\x00')

    thread.wait_until(fut4.is_set)

    [ret] = canon_stream_read(StreamType(U8Type()), opts2, rsi, 12345, 0)
    assert(ret == definitions.BLOCKED)

    [event] = canon_waitable_set_wait(MemInst(mem2, 'i32'), seti, retp)
    assert(event == EventCode.STREAM_READ)
    assert(mem2[retp+0] == rsi)
    p2 = int.from_bytes(mem2[retp+4 : retp+8], 'little', signed=False)
    assert(p2 == (CopyResult.DROPPED | 1))

    [] = canon_stream_drop_readable(StreamType(U8Type()), rsi)
    [] = canon_waitable_set_drop(seti)
    return []

  lift_and_run(opts2, inst2, ft2, core_func2, lambda:[], lambda _:())


def test_wasm_to_wasm_stream_empty():
  store = Store()
  fut1, fut2, fut3, fut4 = RacyBool(False), RacyBool(False), RacyBool(False), RacyBool(False)

  inst1 = ComponentInstance(store)
  mem1 = bytearray(24)
  opts1 = mk_opts(memory=MemInst(mem1, 'i32'), async_=True)
  ft1 = FuncType([], [StreamType(None)])
  def core_func1(args):
    thread = current_thread()
    assert(not args)
    [packed] = canon_stream_new(StreamType(None))
    rsi,wsi = unpack_new_ends(packed)
    [] = canon_task_return([StreamType(None)], opts1, [rsi])

    thread.wait_until(fut1.is_set)

    [ret] = canon_stream_write(StreamType(None), opts1, wsi, 10000, 2)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_write(StreamType(None), opts1, wsi, 10000, 2)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)

    thread.wait_until(fut2.is_set)

    [ret] = canon_stream_write(StreamType(None), opts1, wsi, 0, 8)
    assert(ret == definitions.BLOCKED)

    fut3.set()

    retp = 16
    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(wsi, seti)
    [event] = canon_waitable_set_wait(MemInst(mem1, 'i32'), seti, retp)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem1[retp+0] == wsi)
    result,n = unpack_result(mem1[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)

    fut4.set()

    [errctxi] = canon_error_context_new(opts1, 0, 0)
    [] = canon_stream_drop_writable(StreamType(None), wsi)
    [] = canon_error_context_drop(errctxi)
    return []

  func1 = store.lift(core_func1, ft1, opts1, inst1)

  inst2 = ComponentInstance(store)
  heap2 = Heap(10)
  mem2 = heap2.memory
  opts2 = mk_opts(memory=MemInst(heap2.memory, 'i32'), realloc=heap2.realloc, async_=True)
  ft2 = FuncType([], [])
  def core_func2(args):
    thread = current_thread()
    assert(not args)
    [] = canon_task_return([], opts2, [])

    retp = 0
    [ret] = store.lower(func1, ft1, opts2, inst2)([retp])
    assert(ret == Subtask.State.RETURNED)
    rsi = mem2[0]
    assert(rsi == 1)

    [ret] = canon_stream_read(StreamType(None), opts2, rsi, 0, 8)
    assert(ret == definitions.BLOCKED)

    fut1.set()

    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(rsi, seti)
    [event] = canon_waitable_set_wait(MemInst(mem2, 'i32'), seti, retp)
    assert(event == EventCode.STREAM_READ)
    assert(mem2[retp+0] == rsi)
    result,n = unpack_result(mem2[retp+4])
    assert(n == 4 and result == CopyResult.COMPLETED)

    fut2.set()
    thread.wait_until(fut3.is_set)

    [ret] = canon_stream_read(StreamType(None), opts2, rsi, 1000000, 2)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(None), opts2, rsi, 1000000, 2)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)

    thread.wait_until(fut4.is_set)

    [ret] = canon_stream_read(StreamType(None), opts2, rsi, 1000000, 2)
    result,n = unpack_result(ret)
    assert(n == 0 and result == CopyResult.DROPPED)
    [] = canon_stream_drop_readable(StreamType(None), rsi)
    return []

  lift_and_run(opts2, inst2, ft2, core_func2, lambda:[], lambda _:())


def test_cancel_copy():
  store = Store()
  inst = ComponentInstance(store)
  mem = bytearray(24)
  lower_opts = mk_opts(memory=MemInst(mem, 'i32'), async_=True)

  host_ft1 = FuncType([StreamType(U8Type())],[])
  host_reader = None
  def host_func1(on_start, on_resolve, wait_until):
    nonlocal host_reader
    [readable_end] = on_start()
    host_reader = HostReader(readable_end, remain = 0)
    on_resolve([])
  host_func1_inst = mk_host_func(store, host_func1, host_ft1)

  host_ft2 = FuncType([], [StreamType(U8Type())])
  host_writer = None
  def host_func2(on_start, on_resolve, wait_until):
    nonlocal host_writer
    [] = on_start()
    host_writer = HostWriter(U8Type(), chunk=2, drop_when_empty = False)
    on_resolve([host_writer.end.shared.readable_end])
  host_func2_inst = mk_host_func(store, host_func2, host_ft2)

  lift_opts = mk_opts()
  def core_func(args):
    assert(not args)

    [packed] = canon_stream_new(StreamType(U8Type()))
    rsi,wsi = unpack_new_ends(packed)
    [ret] = store.lower(host_func1_inst, host_ft1, lower_opts, inst)([rsi])
    assert(ret == Subtask.State.RETURNED)
    mem[0:4] = b'\x0a\x0b\x0c\x0d'
    [ret] = canon_stream_write(StreamType(U8Type()), lower_opts, wsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_reader.set_remain(2)
    assert(host_reader.take() == [0xa, 0xb])
    [ret] = canon_stream_cancel_write(StreamType(U8Type()), False, wsi)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_writable(StreamType(U8Type()), wsi)
    host_reader.set_remain(100)
    assert(host_reader.dropped)

    [packed] = canon_stream_new(StreamType(U8Type()))
    rsi,wsi = unpack_new_ends(packed)
    [ret] = store.lower(host_func1_inst, host_ft1, lower_opts, inst)([rsi])
    assert(ret == Subtask.State.RETURNED)
    mem[0:4] = b'\x01\x02\x03\x04'
    [ret] = canon_stream_write(StreamType(U8Type()), lower_opts, wsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_reader.set_remain(2)
    assert(host_reader.take() == [1, 2])
    [ret] = canon_stream_cancel_write(StreamType(U8Type()), True, wsi)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_writable(StreamType(U8Type()), wsi)
    host_reader.set_remain(100)
    assert(host_reader.dropped)

    retp = 16
    [ret] = store.lower(host_func2_inst, host_ft2, lower_opts, inst)([retp])
    assert(ret == Subtask.State.RETURNED)
    rsi = mem[retp]
    [ret] = canon_stream_read(StreamType(U8Type()), lower_opts, rsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    [ret] = canon_stream_cancel_read(StreamType(U8Type()), False, rsi)
    result,n = unpack_result(ret)
    assert(n == 0 and result == CopyResult.CANCELLED)
    [] = canon_stream_drop_readable(StreamType(U8Type()), rsi)

    [ret] = store.lower(host_func2_inst, host_ft2, lower_opts, inst)([retp])
    assert(ret == Subtask.State.RETURNED)
    rsi = mem[retp]
    [ret] = canon_stream_read(StreamType(U8Type()), lower_opts, rsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    [ret] = canon_stream_cancel_read(StreamType(U8Type()), True, rsi)
    result,n = unpack_result(ret)
    assert(n == 0 and result == CopyResult.CANCELLED)
    [] = canon_stream_drop_readable(StreamType(U8Type()), rsi)

    [ret] = store.lower(host_func2_inst, host_ft2, lower_opts, inst)([retp])
    assert(ret == Subtask.State.RETURNED)
    rsi = mem[retp]
    [ret] = canon_stream_read(StreamType(U8Type()), lower_opts, rsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_writer.write([7,8])
    [ret] = canon_stream_cancel_read(StreamType(U8Type()), True, rsi)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    assert(mem[0:2] == b'\x07\x08')
    [] = canon_stream_drop_readable(StreamType(U8Type()), rsi)

    return []

  caller_ft = FuncType([], [], async_ = True)
  lift_and_run(lift_opts, inst, caller_ft, core_func, lambda:[], lambda _:())


def test_futures():
  store = Store()
  inst = ComponentInstance(store)
  mem = bytearray(24)
  lower_opts = mk_opts(memory=MemInst(mem, 'i32'), async_=True)

  host_ft1 = FuncType([FutureType(U8Type())],[FutureType(U8Type())], async_ = True)
  def host_func(on_start, on_resolve, wait_until):
    [incoming_readable_end] = on_start()
    outgoing = Future(U8Type())
    on_resolve([outgoing.readable_end])
    buffer = HostWritableBuffer(U8Type(), 1)
    copied = RacyBool(False)
    incoming_readable_end.shared.read(None, buffer, lambda result: copied.set())
    wait_until(copied.is_set)
    assert(buffer.received == [42])
    outgoing.write(None, HostReadableBuffer(U8Type(), [43]), lambda result:())
  host_func_inst = mk_host_func(store, host_func, host_ft1)

  lift_opts = mk_opts()
  def core_func(args):
    thread = current_thread()
    assert(not args)
    [packed] = canon_future_new(FutureType(U8Type()))
    rfi,wfi = unpack_new_ends(packed)
    retp = 16
    [ret] = store.lower(host_func_inst, host_ft1, lower_opts, inst)([rfi, retp])
    assert(ret == Subtask.State.RETURNED)
    rfi = mem[retp]

    readp = 0
    [ret] = canon_future_read(FutureType(U8Type()), lower_opts, rfi, readp)
    assert(ret == definitions.BLOCKED)

    writep = 8
    mem[writep] = 42
    [ret] = canon_future_write(FutureType(U8Type()), lower_opts, wfi, writep)
    assert(ret == CopyResult.COMPLETED)

    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(rfi, seti)
    [event] = canon_waitable_set_wait(MemInst(mem, 'i32'), seti, retp)
    assert(event == EventCode.FUTURE_READ)
    assert(mem[retp+0] == rfi)
    assert(mem[retp+4] == CopyResult.COMPLETED)
    assert(mem[readp] == 43)

    [] = canon_future_drop_writable(FutureType(U8Type()), wfi)
    [] = canon_future_drop_readable(FutureType(U8Type()), rfi)
    [] = canon_waitable_set_drop(seti)

    [packed] = canon_future_new(FutureType(U8Type()))
    rfi,wfi = unpack_new_ends(packed)
    [ret] = store.lower(host_func_inst, host_ft1, lower_opts, inst)([rfi, retp])
    assert(ret == Subtask.State.RETURNED)
    rfi = mem[retp]

    readp = 0
    [ret] = canon_future_read(FutureType(U8Type()), lower_opts, rfi, readp)
    assert(ret == definitions.BLOCKED)

    writep = 8
    mem[writep] = 42
    [ret] = canon_future_write(FutureType(U8Type()), lower_opts, wfi, writep)
    assert(ret == CopyResult.COMPLETED)

    while not thread.task.inst.handles.get(rfi).has_pending_event():
      canon_thread_yield()

    [ret] = canon_future_cancel_read(FutureType(U8Type()), False, rfi)
    assert(ret == CopyResult.COMPLETED)
    assert(mem[readp] == 43)

    [] = canon_future_drop_writable(FutureType(U8Type()), wfi)
    [] = canon_future_drop_readable(FutureType(U8Type()), rfi)

    [packed] = canon_future_new(FutureType(U8Type()))
    rfi,wfi = unpack_new_ends(packed)
    trapped = False
    try:
      canon_future_drop_writable(FutureType(U8Type()), wfi)
    except Trap:
      trapped = True
    assert(trapped)

    return []

  caller_ft = FuncType([], [], async_ = True)
  lift_and_run(lift_opts, inst, caller_ft, core_func, lambda:[], lambda _:())


def test_future_drop_readable_with_pending_write():
  store = Store()
  inst = ComponentInstance(store)
  mem = bytearray(24)
  opts = mk_opts(memory=MemInst(mem, 'i32'), async_=True)
  future_t = FutureType(U8Type())

  def core_func(args):
    assert(len(args) == 0)
    [] = canon_task_return([], opts, [])
    [packed] = canon_future_new(future_t)
    rfi,wfi = unpack_new_ends(packed)

    mem[0] = 42
    [ret] = canon_future_write(future_t, opts, wfi, 0)
    assert(ret == definitions.BLOCKED)

    # The reader may drop its end before reading a value; the blocked write
    # is notified that the readable end was dropped.
    [] = canon_future_drop_readable(future_t, rfi)
    retp = 16
    [seti] = canon_waitable_set_new()
    [] = canon_waitable_join(wfi, seti)
    [event] = canon_waitable_set_wait(MemInst(mem, 'i32'), seti, retp)
    assert(event == EventCode.FUTURE_WRITE)
    assert(mem[retp+0] == wfi)
    assert(mem[retp+4] == CopyResult.DROPPED)
    [] = canon_waitable_join(wfi, 0)
    [] = canon_waitable_set_drop(seti)
    [] = canon_future_drop_writable(future_t, wfi)
    return []

  caller_ft = FuncType([], [], async_ = True)
  lift_and_run(opts, inst, caller_ft, core_func, lambda:[], lambda _:())


def test_cancel_subtask():
  store = Store()
  ft = FuncType([U8Type()], [U8Type()], async_ = True)

  callee_heap = Heap(10)
  callee_mem = MemInst(callee_heap.memory, 'i32')
  callee_inst = ComponentInstance(store)

  never_started_opts = mk_opts(callee_mem, async_ = True)
  def core_never_started(args):
    assert(False)
  callee_never_started = store.lift(core_never_started, ft, never_started_opts, callee_inst)

  # Waits in the event loop and, when cancelled, either resolves immediately or
  # goes back to the event loop once more (via `YIELD`) before resolving.
  wait_opts = mk_opts(callee_mem, async_ = True)
  def core_wait(args):
    [x] = args
    [] = canon_context_set('i32', 0, x)
    [si] = canon_waitable_set_new()
    return [CallbackCode.WAIT | (si << 4)]
  def core_wait_callback(args):
    [event,p1,p2] = args
    assert(p1 == 0 and p2 == 0)
    [x] = canon_context_get('i32', 0)
    if event == EventCode.TASK_CANCELLED:
      match x:
        case 1:
          [] = canon_task_return([U8Type()], wait_opts, [42])
        case 2:
          [] = canon_task_cancel()
        case 3 | 4:
          return [CallbackCode.YIELD]
        case _:
          assert(False)
    else:
      assert(event == EventCode.NONE)
      match x:
        case 3:
          [] = canon_task_return([U8Type()], wait_opts, [43])
        case 4:
          [] = canon_task_cancel()
        case _:
          assert(False)
    return [CallbackCode.EXIT]
  wait_opts.callback = core_wait_callback
  callee_wait = store.lift(core_wait, ft, wait_opts, callee_inst)

  # Yields to the event loop and then returns `x`, unless it is cancelled first.
  yield_opts = mk_opts(callee_mem, async_ = True)
  def core_yield(args):
    [x] = args
    [] = canon_context_set('i32', 0, x)
    return [CallbackCode.YIELD]
  def core_yield_callback(args):
    [event,p1,p2] = args
    assert(p1 == 0 and p2 == 0)
    [x] = canon_context_get('i32', 0)
    if event == EventCode.TASK_CANCELLED:
      [] = canon_task_cancel()
    else:
      assert(event == EventCode.NONE)
      [] = canon_task_return([U8Type()], yield_opts, [x])
    return [CallbackCode.EXIT]
  yield_opts.callback = core_yield_callback
  callee_yield = store.lift(core_yield, ft, yield_opts, callee_inst)

  # Holds the "exclusive" lock of `callee_inst` while suspended, thereby
  # preventing any other task of `callee_inst` from being cancelled.
  lock_hog_opts = mk_opts(callee_mem, async_ = True)
  def core_lock_hog(args):
    [x] = args
    canon_thread_yield()
    [] = canon_task_return([U8Type()], lock_hog_opts, [x])
    return [CallbackCode.EXIT]
  def core_lock_hog_callback(args):
    assert(False)
  lock_hog_opts.callback = core_lock_hog_callback
  callee_lock_hog = store.lift(core_lock_hog, ft, lock_hog_opts, callee_inst)

  # Blocks in a synchronous import call (during which it is not cancellable)
  # and only then returns to the event loop to receive the cancellation.
  host_fut1 = RacyBool(False)
  def host_func1(on_start, on_resolve, wait_until):
    args = on_start()
    assert(len(args) == 1 and args[0] == 42)
    wait_until(host_fut1.is_set)
    on_resolve([43])
  host_func1_inst = mk_host_func(store, host_func1, ft)
  sync_lower_opts = mk_opts(callee_mem, async_ = False)
  sync_import_opts = mk_opts(callee_mem, async_ = True)
  def core_sync_import(args):
    [x] = args
    [result] = store.lower(host_func1_inst, ft, sync_lower_opts, callee_inst)([42])
    assert(result == 43)
    try:
      [] = canon_task_cancel()
      assert(False)
    except Trap:
      pass
    [si] = canon_waitable_set_new()
    [] = canon_context_set('i32', 0, si)
    return [CallbackCode.WAIT | (si << 4)]
  def core_sync_import_callback(args):
    [event,p1,p2] = args
    assert(event == EventCode.TASK_CANCELLED and p1 == 0 and p2 == 0)
    [si] = canon_context_get('i32', 0)
    [event] = canon_waitable_set_poll(callee_mem, si, 0)
    assert(event == EventCode.NONE)
    [] = canon_task_cancel()
    return [CallbackCode.EXIT]
  sync_import_opts.callback = core_sync_import_callback
  callee_sync_import = store.lift(core_sync_import, ft, sync_import_opts, callee_inst)

  # Uses the stackful ABI and thus never becomes cancellable: the cancellation
  # request is silently ignored and the task returns normally.
  host_fut2 = RacyBool(False)
  def host_func2(on_start, on_resolve, wait_until):
    args = on_start()
    assert(len(args) == 1 and args[0] == 42)
    wait_until(host_fut2.is_set)
    wait_until(host_fut2.is_set)
    on_resolve([43])
  host_func2_inst = mk_host_func(store, host_func2, ft)
  ignores_cancel_opts = mk_opts(callee_mem, async_ = True)
  def core_ignores_cancel(args):
    [x] = args
    assert(x == 13)
    [ret] = store.lower(host_func2_inst, ft, ignores_cancel_opts, callee_inst)([42, 0])
    state,subi = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_subtask_cancel(False, subi)
    assert(ret == Subtask.State.RETURNED)
    [] = canon_subtask_drop(subi)
    [] = canon_task_return([U8Type()], ignores_cancel_opts, [44])
    return []
  callee_ignores_cancel = store.lift(core_ignores_cancel, ft, ignores_cancel_opts, callee_inst)

  caller_heap = Heap(20)
  caller_mem = MemInst(caller_heap.memory, 'i32')
  caller_opts = mk_opts(caller_mem, async_ = True)
  caller_inst = ComponentInstance(store)

  def core_caller(args):
    [x] = args
    assert(x == 1)

    [seti] = canon_waitable_set_new()
    retp = 8

    # A task blocked on backpressure is cancelled without ever running the
    # callee, both when cancelling synchronously and asynchronously.
    callee_inst.backpressure = True
    [ret] = store.lower(callee_never_started, ft, caller_opts, caller_inst)([13, 0])
    state,subi1 = unpack_result(ret)
    assert(state == Subtask.State.STARTING)
    [ret] = store.lower(callee_never_started, ft, caller_opts, caller_inst)([13, 0])
    state,subi2 = unpack_result(ret)
    assert(state == Subtask.State.STARTING)
    [ret] = canon_subtask_cancel(False, subi2)
    assert(ret == Subtask.State.CANCELLED_BEFORE_STARTED)
    [ret] = canon_subtask_cancel(True, subi1)
    assert(ret == Subtask.State.CANCELLED_BEFORE_STARTED)
    callee_inst.backpressure = False

    # A `callback` task waiting in the event loop is immediately resumed with a
    # TASK_CANCELLED and can then `task.return`, `task.cancel` or go back to the
    # event loop first.
    [ret] = store.lower(callee_wait, ft, caller_opts, caller_inst)([1, 0])
    state,subi1 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = store.lower(callee_wait, ft, caller_opts, caller_inst)([2, 0])
    state,subi2 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = store.lower(callee_wait, ft, caller_opts, caller_inst)([3, 0])
    state,subi3 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = store.lower(callee_wait, ft, caller_opts, caller_inst)([3, 0])
    state,subi3_2 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = store.lower(callee_wait, ft, caller_opts, caller_inst)([4, 0])
    state,subi4 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = store.lower(callee_wait, ft, caller_opts, caller_inst)([4, 0])
    state,subi4_2 = unpack_result(ret)
    assert(state == Subtask.State.STARTED)

    caller_heap.memory[0] = 13
    [ret] = canon_subtask_cancel(False, subi1)
    assert(ret == Subtask.State.RETURNED)
    assert(caller_heap.memory[0] == 42)
    [] = canon_subtask_drop(subi1)

    caller_heap.memory[0] = 13
    [ret] = canon_subtask_cancel(True, subi2)
    if ret == definitions.BLOCKED:
      canon_waitable_join(subi2, seti)
      [ret] = canon_waitable_set_wait(caller_mem, seti, retp)
      assert(ret == EventCode.SUBTASK)
      assert(caller_heap.memory[retp+0] == subi2)
      assert(caller_heap.memory[retp+4] == Subtask.State.CANCELLED_BEFORE_RETURNED)
    else:
      assert(ret == Subtask.State.CANCELLED_BEFORE_RETURNED)
    assert(caller_heap.memory[0] == 13)
    [] = canon_subtask_drop(subi2)

    caller_heap.memory[0] = 13
    [ret] = canon_subtask_cancel(True, subi3)
    if ret == definitions.BLOCKED:
      assert(caller_heap.memory[0] == 13)
      [] = canon_waitable_join(subi3, seti)
      [ret] = canon_waitable_set_wait(caller_mem, seti, retp)
      assert(ret == EventCode.SUBTASK)
      assert(caller_heap.memory[retp+0] == subi3)
      assert(caller_heap.memory[retp+4] == Subtask.State.RETURNED)
    else:
      assert(ret == Subtask.State.RETURNED)
    assert(caller_heap.memory[0] == 43)
    [] = canon_subtask_drop(subi3)

    caller_heap.memory[0] = 13
    [ret] = canon_subtask_cancel(False, subi3_2)
    assert(ret == Subtask.State.RETURNED)
    assert(caller_heap.memory[0] == 43)
    [] = canon_subtask_drop(subi3_2)

    caller_heap.memory[0] = 13
    [ret] = canon_subtask_cancel(True, subi4)
    assert(caller_heap.memory[0] == 13)
    if ret == definitions.BLOCKED:
      [] = canon_waitable_join(subi4, seti)
      [ret] = canon_waitable_set_wait(caller_mem, seti, retp)
      assert(ret == EventCode.SUBTASK)
      assert(caller_heap.memory[retp+0] == subi4)
      assert(caller_heap.memory[retp+4] == Subtask.State.CANCELLED_BEFORE_RETURNED)
    else:
      assert(ret == Subtask.State.CANCELLED_BEFORE_RETURNED)
    [] = canon_subtask_drop(subi4)

    caller_heap.memory[0] = 13
    [ret] = canon_subtask_cancel(False, subi4_2)
    assert(ret == Subtask.State.CANCELLED_BEFORE_RETURNED)
    assert(caller_heap.memory[0] == 13)
    [] = canon_subtask_drop(subi4_2)

    # Cancelling a subtask that has already returned simply reports the
    # already-resolved state.
    caller_heap.memory[0] = 13
    [ret] = store.lower(callee_yield, ft, caller_opts, caller_inst)([83, 0])
    state,subi = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    while caller_inst.handles.get(subi).state == Subtask.State.STARTED:
      canon_thread_yield()
    [ret] = canon_subtask_cancel(True, subi)
    assert(ret == Subtask.State.RETURNED)
    assert(caller_heap.memory[0] == 83)
    [] = canon_subtask_drop(subi)

    # A `callback` task that returned `YIELD` is also immediately cancellable.
    caller_heap.memory[0] = 13
    [ret] = store.lower(callee_yield, ft, caller_opts, caller_inst)([83, 0])
    state,subi = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_subtask_cancel(True, subi)
    if ret == definitions.BLOCKED:
      canon_waitable_join(subi, seti)
      [ret] = canon_waitable_set_wait(caller_mem, seti, retp)
      assert(ret == EventCode.SUBTASK)
      assert(caller_heap.memory[retp+0] == subi)
      assert(caller_heap.memory[retp+4] == Subtask.State.CANCELLED_BEFORE_RETURNED)
    else:
      assert(ret == Subtask.State.CANCELLED_BEFORE_RETURNED)
    assert(caller_heap.memory[0] == 13)
    [] = canon_subtask_drop(subi)

    # While another task holds the "exclusive" lock of `callee_inst`, the
    # cancellation request is remembered and only delivered once the lock is
    # released and the cancelled task is resumed: first for a task waiting in
    # the event loop, then for a task that returned `YIELD`.
    for (callee, cancelled_state, expected) in [(callee_wait, Subtask.State.RETURNED, 42),
                                                (callee_yield, Subtask.State.CANCELLED_BEFORE_RETURNED, 13)]:
      caller_heap.memory[0] = 13
      caller_heap.memory[4] = 13
      [ret] = store.lower(callee, ft, caller_opts, caller_inst)([1, 0])
      state,subi = unpack_result(ret)
      assert(state == Subtask.State.STARTED)
      [ret] = store.lower(callee_lock_hog, ft, caller_opts, caller_inst)([45, 4])
      state,subi_hog = unpack_result(ret)
      assert(state == Subtask.State.STARTED)
      [ret] = canon_subtask_cancel(True, subi)
      if ret == definitions.BLOCKED:
        assert(caller_heap.memory[0] == 13)
        [] = canon_waitable_join(subi, seti)
        [ret] = canon_waitable_set_wait(caller_mem, seti, retp)
        assert(ret == EventCode.SUBTASK)
        assert(caller_heap.memory[retp+0] == subi)
        assert(caller_heap.memory[retp+4] == cancelled_state)
      else:
        assert(ret == cancelled_state)
      assert(caller_heap.memory[0] == expected)
      assert(caller_heap.memory[4] == 45)
      [] = canon_subtask_drop(subi)
      [] = canon_waitable_join(subi_hog, seti)
      [ret] = canon_waitable_set_wait(caller_mem, seti, retp)
      assert(ret == EventCode.SUBTASK)
      assert(caller_heap.memory[retp+0] == subi_hog)
      assert(caller_heap.memory[retp+4] == Subtask.State.RETURNED)
      [] = canon_subtask_drop(subi_hog)

    # A `callback` task blocked in a synchronous import call is not cancellable
    # until it returns to the event loop. `task.cancel` traps until then and
    # TASK_CANCELLED is delivered at most once.
    caller_heap.memory[0] = 13
    [ret] = store.lower(callee_sync_import, ft, caller_opts, caller_inst)([0, 0])
    state,subi = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_subtask_cancel(True, subi)
    assert(ret == definitions.BLOCKED)
    assert(caller_heap.memory[0] == 13)
    host_fut1.set()
    [] = canon_waitable_join(subi, seti)
    [event] = canon_waitable_set_wait(caller_mem, seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(caller_heap.memory[retp+0] == subi)
    assert(caller_heap.memory[retp+4] == Subtask.State.CANCELLED_BEFORE_RETURNED)
    assert(caller_heap.memory[0] == 13)
    [] = canon_subtask_drop(subi)

    # A task using the stackful ABI never becomes cancellable, so the
    # cancellation request is silently ignored and the task returns normally.
    caller_heap.memory[0] = 13
    [ret] = store.lower(callee_ignores_cancel, ft, caller_opts, caller_inst)([13, 0])
    state,subi = unpack_result(ret)
    assert(state == Subtask.State.STARTED)
    [ret] = canon_subtask_cancel(True, subi)
    assert(ret == definitions.BLOCKED)
    assert(caller_heap.memory[0] == 13)
    host_fut2.set()
    [] = canon_waitable_join(subi, seti)
    [event] = canon_waitable_set_wait(caller_mem, seti, retp)
    assert(event == EventCode.SUBTASK)
    assert(caller_heap.memory[retp+0] == subi)
    assert(caller_heap.memory[retp+4] == Subtask.State.RETURNED)
    assert(caller_heap.memory[0] == 44)
    [] = canon_subtask_drop(subi)

    [] = canon_waitable_set_drop(seti)
    [] = canon_task_return([U8Type()], caller_opts, [42])
    return []

  def on_start():
    return [ 1 ]

  got = None
  def on_resolve(results):
    nonlocal got
    got = results

  lift_and_run(caller_opts, caller_inst, ft, core_caller, on_start, on_resolve)

  assert(len(got) == 1)
  assert(got[0] == 42)


def test_self_copy(elemt):
  store = Store()
  inst = ComponentInstance(store)
  mem = bytearray(40)
  sync_opts = mk_opts(memory=MemInst(mem, 'i32'), async_=False)
  async_opts = mk_opts(memory=MemInst(mem, 'i32'), async_=True)

  ft = FuncType([], [], async_ = True)
  def core_func(args):
    [seti] = canon_waitable_set_new()

    [packed] = canon_future_new(FutureType(elemt))
    rfi,wfi = unpack_new_ends(packed)

    [ret] = canon_future_write(FutureType(elemt), async_opts, wfi, 0)
    assert(ret == definitions.BLOCKED)

    [ret] = canon_future_read(FutureType(elemt), async_opts, rfi, 0)
    assert(ret == CopyResult.COMPLETED)
    [] = canon_future_drop_readable(FutureType(elemt), rfi)

    [] = canon_waitable_join(wfi, seti)
    [event] = canon_waitable_set_wait(MemInst(mem, 'i32'), seti, 0)
    assert(event == EventCode.FUTURE_WRITE)
    assert(mem[0] == wfi)
    assert(mem[4] == CopyResult.COMPLETED)
    [] = canon_future_drop_writable(FutureType(elemt), wfi)

    [packed] = canon_stream_new(StreamType(elemt))
    rsi,wsi = unpack_new_ends(packed)
    [ret] = canon_stream_write(StreamType(elemt), async_opts, wsi, 0, 3)
    assert(ret == definitions.BLOCKED)

    [ret] = canon_stream_read(StreamType(elemt), async_opts, rsi, 0, 1)
    result,n = unpack_result(ret)
    assert(n == 1 and result == CopyResult.COMPLETED)
    [ret] = canon_stream_read(StreamType(elemt), async_opts, rsi, 0, 4)
    result,n = unpack_result(ret)
    assert(n == 2 and result == CopyResult.COMPLETED)
    [] = canon_stream_drop_readable(StreamType(elemt), rsi)

    [] = canon_waitable_join(wsi, seti)
    [event] = canon_waitable_set_wait(MemInst(mem, 'i32'), seti, 0)
    assert(event == EventCode.STREAM_WRITE)
    assert(mem[0] == wsi)
    result,n = unpack_result(mem[4])
    assert(result == CopyResult.DROPPED)
    assert(n == 3)
    [] = canon_stream_drop_writable(StreamType(elemt), wsi)

    [] = canon_waitable_set_drop(seti)
    return []

  lift_and_run(sync_opts, inst, ft, core_func, lambda:[], lambda _:())


def test_async_flat_params():
  store = Store()
  heap = Heap(1000)
  opts = mk_opts(MemInst(heap.memory, 'i32'), 'utf8', heap.realloc, async_ = True)
  inst = ComponentInstance(store)

  ft1 = FuncType([F32Type(), F64Type(), U32Type(), S64Type()],[])
  def f1(on_start, on_resolve, wait_until):
    args = on_start()
    assert(len(args) == 4)
    assert(args[0] == 1.1)
    assert(args[1] == 2.2)
    assert(args[2] == 3)
    assert(args[3] == 4)
    on_resolve([])
  f1_inst = mk_host_func(store, f1, ft1)

  ft2 = FuncType([U32Type(),U8Type(),U8Type(),U8Type()],[])
  def f2(on_start, on_resolve, wait_until):
    args = on_start()
    assert(len(args) == 4)
    assert(args == [1,2,3,4])
    on_resolve([])
  f2_inst = mk_host_func(store, f2, ft2)

  ft3 = FuncType([U32Type(),U8Type(),U8Type(),U8Type(),U8Type()],[])
  def f3(on_start, on_resolve, wait_until):
    args = on_start()
    assert(len(args) == 5)
    assert(args == [1,2,3,4,5])
    on_resolve([])
  f3_inst = mk_host_func(store, f3, ft3)

  def core_func(args):
    [ret] = store.lower(f1_inst, ft1, opts, inst)([1.1, 2.2, 3, 4])
    assert(ret == Subtask.State.RETURNED)

    [ret] = store.lower(f2_inst, ft2, opts, inst)([1,2,3,4])
    assert(ret == Subtask.State.RETURNED)

    heap.memory[12:20] = b'\x01\x00\x00\x00\x02\x03\x04\x05'
    [ret] = store.lower(f3_inst, ft3, opts, inst)([12])
    assert(ret == Subtask.State.RETURNED)

    canon_task_return([], opts, [])
    return []

  lift_and_run(opts, inst, FuncType([], []), core_func, lambda:[], lambda _:())

def test_threads():
  store = Store()
  inst = ComponentInstance(store)
  mem = bytearray(8)
  opts = mk_opts(memory = MemInst(mem, 'i32'))

  ftbl = Table()
  ft = CoreFuncType(['i32'],[])

  def thread_func1(args):
    assert(args == [13])
    return []
  fi1 = ftbl.add(CoreFuncRef(ft, thread_func1))

  def thread_func2(args):
    [mainthreadi] = args
    canon_thread_yield_then_resume(mainthreadi)
    return []
  fi2 = ftbl.add(CoreFuncRef(ft, thread_func2))

  def thread_func3(args):
    [mainthreadi] = args
    [] = canon_thread_resume_later(mainthreadi)
    return []
  fi3 = ftbl.add(CoreFuncRef(ft, thread_func3))

  def thread_func4(args):
    [ptr] = args
    canon_thread_yield()
    mem[ptr] = mem[ptr] + 1
    canon_thread_yield()
    mem[ptr] = mem[ptr] + 1
    return []
  fi4 = ftbl.add(CoreFuncRef(ft, thread_func4))

  def core_func(args):
    assert(not args)

    [mainthreadi] = canon_thread_index()

    [threadi] = canon_thread_new_indirect(ft, ftbl, fi1, 13)
    canon_thread_yield_then_resume(threadi)

    [threadi] = canon_thread_new_indirect(ft, ftbl, fi2, mainthreadi)
    canon_thread_suspend_then_resume(threadi)

    [threadi] = canon_thread_new_indirect(ft, ftbl, fi3, mainthreadi)
    [] = canon_thread_resume_later(threadi)
    canon_thread_suspend()

    ptr = 4
    mem[ptr] = 0
    for i in range(5):
      [threadi] = canon_thread_new_indirect(ft, ftbl, fi4, ptr)
      [] = canon_thread_resume_later(threadi)
    while mem[ptr] != 10:
      canon_thread_yield()

    return [42]

  result = None
  def on_resolve(v):
    nonlocal result
    [result] = v

  caller_ft = FuncType([], [U8Type()], async_ = True)
  lift_and_run(opts, inst, caller_ft, core_func, lambda:[], on_resolve)
  assert(result == 42)

def test_sync_threads():
  store = Store()
  inst = ComponentInstance(store)

  mem = bytearray(8)
  opts = mk_opts(memory = MemInst(mem, 'i32'), async_ = True)
  ftbl = Table()
  ft = CoreFuncType(['i32'],[])

  ping_count1 = 0
  pong_count1 = 0
  threadi2 = None
  threadi3 = None
  threadi4_1 = None
  threadi4_2 = None
  ping_count5 = 0
  pong_count5 = 0
  threadi5_1 = None
  threadi5_2 = None

  def thread_func1_1(args):
    assert(args == [131])
    nonlocal ping_count1
    while ping_count1 < 3 or pong_count1 < 3:
      ping_count1 += 1
      canon_thread_yield()
    [] = canon_thread_resume_later(threadi2)
    return []
  fi1_1 = ftbl.add(CoreFuncRef(ft, thread_func1_1))

  def thread_func1_2(args):
    assert(args == [132])
    nonlocal pong_count1
    while ping_count1 < 3 or pong_count1 < 3:
      pong_count1 += 1
      canon_thread_yield()
    return []
  fi1_2 = ftbl.add(CoreFuncRef(ft, thread_func1_2))

  def thread_func2(args):
    assert(args == [14])
    [] = canon_thread_resume_later(threadi3)
    return []
  fi2 = ftbl.add(CoreFuncRef(ft, thread_func2))

  def thread_func3(args):
    assert(args == [15])
    [] = canon_thread_resume_later(threadi4_1)
    canon_thread_suspend()
    return []
  fi3 = ftbl.add(CoreFuncRef(ft, thread_func3))

  wsi = None
  def thread_func4_1(args):
    assert(args == [161])
    [] = canon_thread_resume_later(threadi3)
    [] = canon_thread_resume_later(threadi4_2)
    nonlocal wsi
    [wsi] = canon_waitable_set_new()
    [event] = canon_waitable_set_wait(opts.memory, wsi, 0)
    assert(event == EventCode.FUTURE_READ)
    [] = canon_thread_resume_later(threadi5_1)
    return []
  fi4_1 = ftbl.add(CoreFuncRef(ft, thread_func4_1))

  def thread_func4_2(args):
    assert(args == [162])
    [packed] = canon_future_new(FutureType(None))
    futr,futw = unpack_new_ends(packed)
    [ret] = canon_future_read(FutureType(None), opts, futr, 0xdeadbeef)
    assert(ret == definitions.BLOCKED)
    [] = canon_waitable_join(futr, wsi)
    [ret] = canon_future_write(FutureType(None), opts, futw, 0xdeadbeef)
    assert(ret == CopyResult.COMPLETED)
    return []
  fi4_2 = ftbl.add(CoreFuncRef(ft, thread_func4_2))

  def thread_func5_1(args):
    assert(args == [171])
    nonlocal ping_count5
    while ping_count5 < 3:
      assert(ping_count5 == pong_count5)
      canon_thread_yield_then_promote(threadi5_2)
      assert(ping_count5 == pong_count5)
      [] = canon_thread_resume_later(threadi5_2)
      canon_thread_yield_then_promote(threadi5_2)
      assert(ping_count5 == pong_count5 - 1)
      ping_count5 += 1
    [] = canon_task_return([U8Type()], opts, [42])
    [] = canon_thread_resume_later(threadi5_2)
    return []
  fi5_1 = ftbl.add(CoreFuncRef(ft, thread_func5_1))

  def thread_func5_2(args):
    assert(args == [172])
    nonlocal pong_count5
    while pong_count5 < 3:
      pong_count5 += 1
      canon_thread_suspend_then_promote(threadi5_1)
    return []
  fi5_2 = ftbl.add(CoreFuncRef(ft, thread_func5_2))

  def core_func(args):
    assert(not args)
    nonlocal threadi2, threadi3, threadi4_1, threadi4_2, threadi5_1, threadi5_2

    [threadi1_1] = canon_thread_new_indirect(ft, ftbl, fi1_1, 131)
    [threadi1_2] = canon_thread_new_indirect(ft, ftbl, fi1_2, 132)
    [threadi2] = canon_thread_new_indirect(ft, ftbl, fi2, 14)
    [threadi3] = canon_thread_new_indirect(ft, ftbl, fi3, 15)
    [threadi4_1] = canon_thread_new_indirect(ft, ftbl, fi4_1, 161)
    [threadi4_2] = canon_thread_new_indirect(ft, ftbl, fi4_2, 162)
    [threadi5_1] = canon_thread_new_indirect(ft, ftbl, fi5_1, 171)
    [threadi5_2] = canon_thread_new_indirect(ft, ftbl, fi5_2, 172)
    [] = canon_thread_resume_later(threadi1_1)
    [] = canon_thread_resume_later(threadi1_2)
    return []

  ready_bit = RacyBool(False)
  # once ready_bit is set, this thread may be resumed either by canon_lift's
  # completion loop (while core_func's task is still executing) or by a
  # top-level tick (after it resolves)
  def async_task_thread(args):
    assert(not args)
    current_thread().wait_until(ready_bit.is_set)
    return [43]
  async_ft = FuncType([], [U32Type()], async_ = True)
  other_result = None
  def on_async_resolve(v):
    nonlocal other_result
    [other_result] = v
  fi = store.lift(async_task_thread, async_ft, CanonicalOptions(), inst)
  _ = store.invoke(fi, lambda:[], on_async_resolve)
  assert(other_result is None)
  ready_bit.set()

  result = None
  def on_resolve(v):
    nonlocal result
    [result] = v

  caller_ft = FuncType([], [U8Type()])
  lift_and_run(opts, inst, caller_ft, core_func, lambda:[], on_resolve)
  assert(result == 42)
  assert(other_result == 43)

test_roundtrips()
test_cross_component_realloc()
test_handles()
test_async_to_async()
test_async_callback()
test_callback_interleaving()
test_sync_ignores_backpressure()
test_async_to_sync()
test_async_backpressure()
test_sync_using_wait()
test_eager_stream_completion()
test_async_stream_ops()
test_stream_forward()
test_forward_builtins()
test_receive_own_stream()
test_host_partial_reads_writes()
test_wasm_to_wasm_stream()
test_wasm_to_wasm_stream_empty()
test_cancel_copy()
test_futures()
test_future_drop_readable_with_pending_write()
test_cancel_subtask()
test_self_copy(None)
test_self_copy(U8Type())
test_self_copy(F64Type())
test_async_flat_params()
test_threads()
test_sync_threads()

print("All tests passed")
