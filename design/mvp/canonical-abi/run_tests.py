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
  inst = ComponentInstance()
  return LiftLowerContext(opts, inst)

def mk_str(s):
  return (s, 'utf8', len(s.encode('utf-8')))

def mk_tup(*a):
  def mk_tup_rec(x):
    if isinstance(x, list):
      return { str(i):mk_tup_rec(v) for i,v in enumerate(x) }
    return x
  return { str(i):mk_tup_rec(v) for i,v in enumerate(a) }

def unpack_lower_result(ret):
  return (ret & ~(3 << 30), ret >> 30)

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
                 CaseType('x',U8Type(),'w'),
                 CaseType('y',U8Type()),
                 CaseType('z',U8Type(),'x')])
test(t, [0, 42], {'w':42})
test(t, [1, 42], {'x|w':42})
test(t, [2, 42], {'y':42})
test(t, [3, 42], {'z|x|w':42})
t2 = VariantType([CaseType('w',U8Type())])
test(t, [0, 42], {'w':42}, lower_t=t2, lower_v={'w':42})
test(t, [1, 42], {'x|w':42}, lower_t=t2, lower_v={'w':42})
test(t, [3, 42], {'z|x|w':42}, lower_t=t2, lower_v={'w':42})

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


async def test_roundtrips():
  async def test_roundtrip(t, v):
    before = definitions.MAX_FLAT_RESULTS
    definitions.MAX_FLAT_RESULTS = 16

    ft = FuncType([t],[t])
    async def callee(task, x):
      return x

    callee_heap = Heap(1000)
    callee_opts = mk_opts(callee_heap.memory, 'utf8', callee_heap.realloc)
    callee_inst = ComponentInstance()
    lifted_callee = partial(canon_lift, callee_opts, callee_inst, ft, callee)

    caller_heap = Heap(1000)
    caller_opts = mk_opts(caller_heap.memory, 'utf8', caller_heap.realloc)
    caller_inst = ComponentInstance()
    caller_task = Task(caller_opts, caller_inst, ft, None, None, None)

    flat_args = await caller_task.enter(lambda: [v])

    return_in_heap = len(flatten_types([t])) > definitions.MAX_FLAT_RESULTS
    if return_in_heap:
      flat_args += [ caller_heap.realloc(0, 0, alignment(t), elem_size(t)) ]

    flat_results = await canon_lower(caller_opts, ft, lifted_callee, caller_task, flat_args)

    if return_in_heap:
      flat_results = [ flat_args[-1] ]

    cx = LiftLowerContext(caller_opts, caller_inst, caller_task)
    [got] = lift_flat_values(cx, definitions.MAX_FLAT_PARAMS, CoreValueIter(flat_results), [t])
    caller_task.exit()

    if got != v:
      fail("test_roundtrip({},{}) got {}".format(t, v, got))

    definitions.MAX_FLAT_RESULTS = before

  await test_roundtrip(S8Type(), -1)
  await test_roundtrip(TupleType([U16Type(),U16Type()]), mk_tup(3,4))
  await test_roundtrip(ListType(StringType()), [mk_str("hello there")])
  await test_roundtrip(ListType(ListType(StringType())), [[mk_str("one"),mk_str("two")],[mk_str("three")]])
  await test_roundtrip(ListType(OptionType(TupleType([StringType(),U16Type()]))), [{'some':mk_tup(mk_str("answer"),42)}])
  await test_roundtrip(VariantType([CaseType('x', TupleType([U32Type(),U32Type(),U32Type(),U32Type(),
                                                             U32Type(),U32Type(),U32Type(),U32Type(),
                                                             U32Type(),U32Type(),U32Type(),U32Type(),
                                                             U32Type(),U32Type(),U32Type(),U32Type(),
                                                             StringType()]))]),
                       {'x': mk_tup(1,2,3,4, 5,6,7,8, 9,10,11,12, 13,14,15,16, mk_str("wat"))})


async def test_handles():
  before = definitions.MAX_FLAT_RESULTS
  definitions.MAX_FLAT_RESULTS = 16

  dtor_value = None
  async def dtor(task, args):
    nonlocal dtor_value
    assert(len(args) == 1)
    dtor_value = args[0]
    return []

  rt = ResourceType(ComponentInstance(), dtor) # usable in imports and exports
  inst = ComponentInstance()
  rt2 = ResourceType(inst, dtor) # only usable in exports
  opts = mk_opts()

  async def host_import(task, on_start, on_return, on_block):
    args = on_start()
    assert(len(args) == 2)
    assert(args[0] == 42)
    assert(args[1] == 44)
    on_return([45])

  async def core_wasm(task, args):
    nonlocal dtor_value

    assert(len(args) == 4)
    assert(len(inst.resources.table(rt).array) == 4)
    assert(inst.resources.table(rt).array[0] is None)
    assert(args[0] == 1)
    assert(args[1] == 2)
    assert(args[2] == 3)
    assert(args[3] == 13)
    assert((await canon_resource_rep(rt, task, 1))[0] == 42)
    assert((await canon_resource_rep(rt, task, 2))[0] == 43)
    assert((await canon_resource_rep(rt, task, 3))[0] == 44)

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
    results = await canon_lower(opts, host_ft, host_import, task, args)
    assert(len(results) == 1)
    assert(results[0] == 4)
    assert((await canon_resource_rep(rt, task, 4))[0] == 45)

    dtor_value = None
    await canon_resource_drop(rt, True, task, 1)
    assert(dtor_value == 42)
    assert(len(inst.resources.table(rt).array) == 5)
    assert(inst.resources.table(rt).array[1] is None)
    assert(len(inst.resources.table(rt).free) == 1)

    h = (await canon_resource_new(rt, task, 46))[0]
    assert(h == 1)
    assert(len(inst.resources.table(rt).array) == 5)
    assert(inst.resources.table(rt).array[1] is not None)
    assert(len(inst.resources.table(rt).free) == 0)

    dtor_value = None
    await canon_resource_drop(rt, True, task, 3)
    assert(dtor_value is None)
    assert(len(inst.resources.table(rt).array) == 5)
    assert(inst.resources.table(rt).array[3] is None)
    assert(len(inst.resources.table(rt).free) == 1)

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
  def on_return(results):
    nonlocal got
    got = results

  await canon_lift(opts, inst, ft, core_wasm, None, on_start, on_return, None)

  assert(len(got) == 3)
  assert(got[0] == 46)
  assert(got[1] == 43)
  assert(got[2] == 45)
  assert(len(inst.resources.table(rt).array) == 5)
  assert(all(inst.resources.table(rt).array[i] is None for i in range(4)))
  assert(len(inst.resources.table(rt).free) == 4)
  definitions.MAX_FLAT_RESULTS = before


async def test_async_to_async():
  producer_heap = Heap(10)
  producer_opts = mk_opts(producer_heap.memory)
  producer_opts.sync = False

  producer_inst = ComponentInstance()

  eager_ft = FuncType([], [U8Type()])
  async def core_eager_producer(task, args):
    assert(len(args) == 0)
    [] = await canon_task_return(task, CoreFuncType(['i32'],[]), [43])
    return []
  eager_callee = partial(canon_lift, producer_opts, producer_inst, eager_ft, core_eager_producer)

  toggle_ft = FuncType([], [])
  fut1 = asyncio.Future()
  async def core_toggle(task, args):
    assert(len(args) == 0)
    [] = await canon_task_backpressure(task, [1])
    await task.on_block(fut1)
    [] = await canon_task_backpressure(task, [0])
    [] = await canon_task_return(task, CoreFuncType([],[]), [])
    return []
  toggle_callee = partial(canon_lift, producer_opts, producer_inst, toggle_ft, core_toggle)

  fut2, fut3 = asyncio.Future(), asyncio.Future()
  blocking_ft = FuncType([U8Type()], [U8Type()])
  async def core_blocking_producer(task, args):
    [x] = args
    assert(x == 83)
    await task.on_block(fut2)
    [] = await canon_task_return(task, CoreFuncType(['i32'],[]), [44])
    await task.on_block(fut3)
    return []
  blocking_callee = partial(canon_lift, producer_opts, producer_inst, blocking_ft, core_blocking_producer)

  consumer_heap = Heap(10)
  consumer_opts = mk_opts(consumer_heap.memory)
  consumer_opts.sync = False

  async def consumer(task, args):
    [b] = args
    ptr = consumer_heap.realloc(0, 0, 1, 1)
    [ret] = await canon_lower(consumer_opts, eager_ft, eager_callee, task, [ptr])
    assert(ret == 0)
    u8 = consumer_heap.memory[ptr]
    assert(u8 == 43)
    [ret] = await canon_lower(consumer_opts, toggle_ft, toggle_callee, task, [])
    subi,state = unpack_lower_result(ret)
    assert(state == CallState.STARTED)
    retp = ptr
    consumer_heap.memory[retp] = 13
    [ret] = await canon_lower(consumer_opts, blocking_ft, blocking_callee, task, [83, retp])
    assert(ret == (2 | (CallState.STARTING << 30)))
    assert(consumer_heap.memory[retp] == 13)
    fut1.set_result(None)
    event, callidx, _ = await task.wait(sync = False)
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 1)
    [] = await canon_subtask_drop(task, callidx)
    event, callidx, _ = await task.wait(sync = True)
    assert(event == EventCode.CALL_STARTED)
    assert(callidx == 2)
    assert(consumer_heap.memory[retp] == 13)
    fut2.set_result(None)
    event, callidx, _ = await task.wait(sync = False)
    assert(event == EventCode.CALL_RETURNED)
    assert(callidx == 2)
    assert(consumer_heap.memory[retp] == 44)
    fut3.set_result(None)
    event, callidx, _ = await task.wait(sync = True)
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 2)
    [] = await canon_subtask_drop(task, callidx)

    dtor_fut = asyncio.Future()
    dtor_value = None
    async def dtor(task, args):
      nonlocal dtor_value
      assert(len(args) == 1)
      await task.on_block(dtor_fut)
      dtor_value = args[0]
      return []
    rt = ResourceType(producer_inst, dtor)

    [i] = await canon_resource_new(rt, task, 50)
    assert(i == 1)
    assert(dtor_value is None)
    [ret] = await canon_resource_drop(rt, False, task, 1)
    assert(ret == (2 | (CallState.STARTED << 30)))
    assert(dtor_value is None)
    dtor_fut.set_result(None)
    event, callidx, _ = await task.wait(sync = False)
    assert(event == CallState.DONE)
    assert(callidx == 2)
    [] = await canon_subtask_drop(task, callidx)

    [] = await canon_task_return(task, CoreFuncType(['i32'],[]), [42])
    return []

  ft = FuncType([BoolType()],[U8Type()])

  def on_start():
    return [ True ]

  got = None
  def on_return(results):
    nonlocal got
    got = results

  consumer_inst = ComponentInstance()
  await canon_lift(consumer_opts, consumer_inst, ft, consumer, None, on_start, on_return)
  assert(len(got) == 1)
  assert(got[0] == 42)


async def test_async_callback():
  producer_inst = ComponentInstance()
  producer_opts = mk_opts()
  producer_opts.sync = False
  producer_ft = FuncType([], [])

  async def core_producer_pre(fut, task, args):
    assert(len(args) == 0)
    await task.on_block(fut)
    await canon_task_return(task, CoreFuncType([],[]), [])
    return []
  fut1 = asyncio.Future()
  core_producer1 = partial(core_producer_pre, fut1)
  producer1 = partial(canon_lift, producer_opts, producer_inst, producer_ft, core_producer1)
  fut2 = asyncio.Future()
  core_producer2 = partial(core_producer_pre, fut2)
  producer2 = partial(canon_lift, producer_opts, producer_inst, producer_ft, core_producer2)

  consumer_ft = FuncType([],[U32Type()])
  async def consumer(task, args):
    assert(len(args) == 0)

    [ret] = await canon_lower(opts, producer_ft, producer1, task, [])
    assert(ret == (1 | (CallState.STARTED << 30)))

    [ret] = await canon_lower(opts, producer_ft, producer2, task, [])
    assert(ret == (2 | (CallState.STARTED << 30)))

    fut1.set_result(None)
    return [42]

  async def callback(task, args):
    assert(len(args) == 4)
    if args[0] == 42:
      assert(args[1] == EventCode.CALL_DONE)
      assert(args[2] == 1)
      assert(args[3] == 0)
      await canon_subtask_drop(task, 1)
      return [53]
    elif args[0] == 52:
      assert(args[1] == EventCode.YIELDED)
      assert(args[2] == 0)
      assert(args[3] == 0)
      fut2.set_result(None)
      return [62]
    else:
      assert(args[0] == 62)
      assert(args[1] == EventCode.CALL_DONE)
      assert(args[2] == 2)
      assert(args[3] == 0)
      await canon_subtask_drop(task, 2)
      [] = await canon_task_return(task, CoreFuncType(['i32'],[]), [83])
      return [0]

  consumer_inst = ComponentInstance()
  def on_start(): return []

  got = None
  def on_return(results):
    nonlocal got
    got = results

  opts = mk_opts()
  opts.sync = False
  opts.callback = callback

  await canon_lift(opts, consumer_inst, consumer_ft, consumer, None, on_start, on_return)
  assert(got[0] == 83)


async def test_async_to_sync():
  producer_opts = CanonicalOptions()
  producer_inst = ComponentInstance()

  producer_ft = FuncType([],[])
  fut = asyncio.Future()
  producer1_done = False
  async def producer1_core(task, args):
    nonlocal producer1_done
    assert(len(args) == 0)
    await task.on_block(fut)
    producer1_done = True
    return []

  producer2_done = False
  async def producer2_core(task, args):
    nonlocal producer2_done
    assert(len(args) == 0)
    assert(producer1_done == True)
    producer2_done = True
    return []

  producer1 = partial(canon_lift, producer_opts, producer_inst, producer_ft, producer1_core)
  producer2 = partial(canon_lift, producer_opts, producer_inst, producer_ft, producer2_core)

  consumer_opts = mk_opts()
  consumer_opts.sync = False

  consumer_ft = FuncType([],[U8Type()])
  async def consumer(task, args):
    assert(len(args) == 0)

    [ret] = await canon_lower(consumer_opts, producer_ft, producer1, task, [])
    assert(ret == (1 | (CallState.STARTED << 30)))

    [ret] = await canon_lower(consumer_opts, producer_ft, producer2, task, [])
    assert(ret == (2 | (CallState.STARTING << 30)))

    assert(await task.poll(sync = False) is None)

    fut.set_result(None)
    assert(producer1_done == False)
    event, callidx, _ = await task.wait(sync = False)
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 1)
    await canon_subtask_drop(task, callidx)
    assert(producer1_done == True)

    assert(producer2_done == False)
    await canon_task_yield(False, task)
    assert(producer2_done == True)
    event, callidx, _ = await task.poll(sync = False)
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 2)
    await canon_subtask_drop(task, callidx)
    assert(producer2_done == True)

    assert(await task.poll(sync = True) is None)

    await canon_task_return(task, CoreFuncType(['i32'],[]), [83])
    return []

  consumer_inst = ComponentInstance()
  def on_start(): return []

  got = None
  def on_return(results):
    nonlocal got
    got = results

  await canon_lift(consumer_opts, consumer_inst, consumer_ft, consumer, None, on_start, on_return)
  assert(got[0] == 83)


async def test_async_backpressure():
  producer_opts = CanonicalOptions()
  producer_opts.sync = False
  producer_inst = ComponentInstance()

  producer_ft = FuncType([],[])
  fut = asyncio.Future()
  producer1_done = False
  async def producer1_core(task, args):
    nonlocal producer1_done
    await canon_task_return(task, CoreFuncType([],[]), [])
    await canon_task_backpressure(task, [1])
    await task.on_block(fut)
    await canon_task_backpressure(task, [0])
    producer1_done = True
    return []

  producer2_done = False
  async def producer2_core(task, args):
    nonlocal producer2_done
    assert(producer1_done == True)
    await canon_task_return(task, CoreFuncType([],[]), [])
    producer2_done = True
    return []

  producer1 = partial(canon_lift, producer_opts, producer_inst, producer_ft, producer1_core)
  producer2 = partial(canon_lift, producer_opts, producer_inst, producer_ft, producer2_core)

  consumer_opts = CanonicalOptions()
  consumer_opts.sync = False

  consumer_ft = FuncType([],[U8Type()])
  async def consumer(task, args):
    assert(len(args) == 0)

    [ret] = await canon_lower(consumer_opts, producer_ft, producer1, task, [])
    assert(ret == (1 | (CallState.RETURNED << 30)))

    [ret] = await canon_lower(consumer_opts, producer_ft, producer2, task, [])
    assert(ret == (2 | (CallState.STARTING << 30)))

    assert(await task.poll(sync = False) is None)

    fut.set_result(None)
    assert(producer1_done == False)
    assert(producer2_done == False)
    event, callidx, _ = await task.wait(sync = False)
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 1)
    assert(producer1_done == True)
    assert(producer2_done == True)
    event, callidx, _ = await task.poll(sync = False)
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 2)
    assert(producer2_done == True)

    await canon_subtask_drop(task, 1)
    await canon_subtask_drop(task, 2)

    assert(await task.poll(sync = False) is None)

    await canon_task_return(task, CoreFuncType(['i32'],[]), [84])
    return []

  consumer_inst = ComponentInstance()
  def on_start(): return []

  got = None
  def on_return(results):
    nonlocal got
    got = results

  await canon_lift(consumer_opts, consumer_inst, consumer_ft, consumer, None, on_start, on_return)
  assert(got[0] == 84)


async def test_sync_using_wait():
  hostcall_opts = mk_opts()
  hostcall_opts.sync = False
  hostcall_inst = ComponentInstance()
  ft = FuncType([], [])

  async def core_hostcall_pre(fut, task, args):
    await task.on_block(fut)
    [] = await canon_task_return(task, CoreFuncType([],[]), [])
    return []
  fut1 = asyncio.Future()
  core_hostcall1 = partial(core_hostcall_pre, fut1)
  hostcall1 = partial(canon_lift, hostcall_opts, hostcall_inst, ft, core_hostcall1)
  fut2 = asyncio.Future()
  core_hostcall2 = partial(core_hostcall_pre, fut2)
  hostcall2 = partial(canon_lift, hostcall_opts, hostcall_inst, ft, core_hostcall2)

  lower_opts = mk_opts()
  lower_opts.sync = False

  async def core_func(task, args):
    [ret] = await canon_lower(lower_opts, ft, hostcall1, task, [])
    assert(ret == (1 | (CallState.STARTED << 30)))
    [ret] = await canon_lower(lower_opts, ft, hostcall2, task, [])
    assert(ret == (2 | (CallState.STARTED << 30)))

    fut1.set_result(None)
    event, callidx, _ = await task.wait(sync = False)
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 1)
    fut2.set_result(None)
    event, callidx, _ = await task.wait(sync = False)
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 2)

    await canon_subtask_drop(task, 1)
    await canon_subtask_drop(task, 2)

    return []

  inst = ComponentInstance()
  def on_start(): return []
  def on_return(results): pass
  await canon_lift(mk_opts(), inst, ft, core_func, None, on_start, on_return)


class HostSource(ReadableStream):
  remaining: list[int]
  destroy_if_empty: bool
  chunk: int
  waiting: Optional[asyncio.Future]
  eager_cancel: asyncio.Event

  def __init__(self, contents, chunk, destroy_if_empty = True):
    self.remaining = contents
    self.destroy_if_empty = destroy_if_empty
    self.chunk = chunk
    self.waiting = None
    self.eager_cancel = asyncio.Event()
    self.eager_cancel.set()

  def closed(self):
    return not self.remaining and self.destroy_if_empty
  def closed_with_error(self):
    assert(self.closed())
    return None

  def wake_waiting(self, cancelled = False):
    if self.waiting:
      self.waiting.set_result(cancelled)
      self.waiting = None

  def close(self, error = None):
    self.remaining = []
    self.destroy_if_empty = True
    self.wake_waiting()

  def destroy_once_empty(self):
    self.destroy_if_empty = True
    if self.closed():
      self.wake_waiting()

  async def read(self, dst, on_block):
    if not self.remaining:
      if self.closed():
        return
      self.waiting = asyncio.Future()
      cancelled = await on_block(self.waiting)
      if cancelled or self.closed():
        return
      assert(self.remaining)
    n = min(dst.remain(), len(self.remaining), self.chunk)
    dst.lower(self.remaining[:n])
    del self.remaining[:n]

  async def cancel_read(self, dst, on_block):
    await on_block(self.eager_cancel.wait())
    self.wake_waiting(True)

  def write(self, vs):
    assert(vs and not self.closed())
    self.remaining += vs
    self.wake_waiting()

  def maybe_writer_handle_index(self, inst):
    return None

class HostSink:
  stream: ReadableStream
  received: list[int]
  chunk: int
  write_remain: int
  write_event: asyncio.Event
  ready_to_consume: asyncio.Event

  def __init__(self, stream, chunk, remain = 2**64):
    self.stream = stream
    self.received = []
    self.chunk = chunk
    self.write_remain = remain
    self.write_event = asyncio.Event()
    if remain:
      self.write_event.set()
    self.ready_to_consume = asyncio.Event()
    async def read_all():
      while not self.stream.closed():
        async def on_block(f):
          return await f
        await self.write_event.wait()
        if self.stream.closed():
          break
        await self.stream.read(self, on_block)
      self.ready_to_consume.set()
    asyncio.create_task(read_all())

  def set_remain(self, n):
    self.write_remain = n
    if self.write_remain > 0:
      self.write_event.set()

  def remain(self):
    return self.write_remain

  def lower(self, vs):
    self.received += vs
    self.ready_to_consume.set()
    self.write_remain -= len(vs)
    if self.write_remain == 0:
      self.write_event.clear()

  async def consume(self, n):
    while n > len(self.received):
      self.ready_to_consume.clear()
      await self.ready_to_consume.wait()
      if self.stream.closed():
        return None
    ret = self.received[:n];
    del self.received[:n]
    return ret

async def test_eager_stream_completion():
  ft = FuncType([StreamType(U8Type())], [StreamType(U8Type())])
  inst = ComponentInstance()
  mem = bytearray(20)
  opts = mk_opts(memory=mem, sync=False)

  async def host_import(task, on_start, on_return, on_block):
    args = on_start()
    assert(len(args) == 1)
    assert(isinstance(args[0], ReadableStream))
    incoming = HostSink(args[0], chunk=4)
    outgoing = HostSource([], chunk=4, destroy_if_empty=False)
    on_return([outgoing])
    async def add10():
      while (vs := await incoming.consume(4)):
        for i in range(len(vs)):
          vs[i] += 10
        outgoing.write(vs)
      outgoing.close()
    asyncio.create_task(add10())

  src_stream = HostSource([1,2,3,4,5,6,7,8], chunk=4)
  def on_start():
    return [src_stream]

  dst_stream = None
  def on_return(results):
    assert(len(results) == 1)
    nonlocal dst_stream
    dst_stream = HostSink(results[0], chunk=4)

  async def core_func(task, args):
    assert(len(args) == 1)
    rsi1 = args[0]
    assert(rsi1 == 1)
    [wsi1] = await canon_stream_new(U8Type(), task)
    [] = await canon_task_return(task, CoreFuncType(['i32'],[]), [wsi1])
    [ret] = await canon_stream_read(U8Type(), opts, task, rsi1, 0, 4)
    assert(ret == 4)
    assert(mem[0:4] == b'\x01\x02\x03\x04')
    [wsi2] = await canon_stream_new(U8Type(), task)
    retp = 12
    [ret] = await canon_lower(opts, ft, host_import, task, [wsi2, retp])
    assert(ret == 0)
    rsi2 = mem[retp]
    [ret] = await canon_stream_write(U8Type(), opts, task, wsi2, 0, 4)
    assert(ret == 4)
    [ret] = await canon_stream_read(U8Type(), opts, task, rsi2, 0, 4)
    assert(ret == 4)
    [ret] = await canon_stream_write(U8Type(), opts, task, wsi1, 0, 4)
    assert(ret == 4)
    [ret] = await canon_stream_read(U8Type(), opts, task, rsi1, 0, 4)
    assert(ret == 4)
    [ret] = await canon_stream_read(U8Type(), opts, task, rsi1, 0, 4)
    assert(ret == definitions.CLOSED)
    assert(mem[0:4] == b'\x05\x06\x07\x08')
    [ret] = await canon_stream_write(U8Type(), opts, task, wsi2, 0, 4)
    assert(ret == 4)
    [ret] = await canon_stream_read(U8Type(), opts, task, rsi2, 0, 4)
    assert(ret == 4)
    [ret] = await canon_stream_write(U8Type(), opts, task, wsi1, 0, 4)
    assert(ret == 4)
    [] = await canon_stream_close_readable(U8Type(), task, rsi1)
    [] = await canon_stream_close_readable(U8Type(), task, rsi2)
    [] = await canon_stream_close_writable(U8Type(), task, wsi1, 0)
    [] = await canon_stream_close_writable(U8Type(), task, wsi2, 0)
    return []

  await canon_lift(opts, inst, ft, core_func, None, on_start, on_return)
  assert(dst_stream.received == [11,12,13,14,15,16,17,18])


async def test_async_stream_ops():
  ft = FuncType([StreamType(U8Type())], [StreamType(U8Type())])
  inst = ComponentInstance()
  mem = bytearray(20)
  opts = mk_opts(memory=mem, sync=False)
  sync_opts = mk_opts(memory=mem, sync=True)

  host_import_incoming = None
  host_import_outgoing = None
  async def host_import(task, on_start, on_return, on_block):
    nonlocal host_import_incoming, host_import_outgoing
    args = on_start()
    assert(len(args) == 1)
    assert(isinstance(args[0], ReadableStream))
    host_import_incoming = HostSink(args[0], chunk=4, remain = 0)
    host_import_outgoing = HostSource([], chunk=4, destroy_if_empty=False)
    on_return([host_import_outgoing])
    while not host_import_incoming.stream.closed():
      vs = await on_block(host_import_incoming.consume(4))
      for i in range(len(vs)):
        vs[i] += 10
      host_import_outgoing.write(vs)
    host_import_outgoing.destroy_once_empty()

  src_stream = HostSource([], chunk=4, destroy_if_empty = False)
  def on_start():
    return [src_stream]

  dst_stream = None
  def on_return(results):
    assert(len(results) == 1)
    nonlocal dst_stream
    dst_stream = HostSink(results[0], chunk=4, remain = 0)

  async def core_func(task, args):
    [rsi1] = args
    assert(rsi1 == 1)
    [wsi1] = await canon_stream_new(U8Type(), task)
    [] = await canon_task_return(task, CoreFuncType(['i32'],[]), [wsi1])
    [ret] = await canon_stream_read(U8Type(), opts, task, rsi1, 0, 4)
    assert(ret == definitions.BLOCKED)
    src_stream.write([1,2,3,4])
    event, p1, p2 = await task.wait(sync = False)
    assert(event == EventCode.STREAM_READ)
    assert(p1 == rsi1)
    assert(p2 == 4)
    assert(mem[0:4] == b'\x01\x02\x03\x04')
    [wsi2] = await canon_stream_new(U8Type(), task)
    retp = 16
    [ret] = await canon_lower(opts, ft, host_import, task, [wsi2, retp])
    subi,state = unpack_lower_result(ret)
    assert(state == CallState.RETURNED)
    rsi2 = mem[16]
    assert(rsi2 == 4)
    [ret] = await canon_stream_write(U8Type(), opts, task, wsi2, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_import_incoming.set_remain(100)
    event, p1, p2 = await task.wait(sync = False)
    assert(event == EventCode.STREAM_WRITE)
    assert(p1 == wsi2)
    assert(p2 == 4)
    [ret] = await canon_stream_read(U8Type(), sync_opts, task, rsi2, 0, 4)
    assert(ret == 4)
    [ret] = await canon_stream_write(U8Type(), opts, task, wsi1, 0, 4)
    assert(ret == definitions.BLOCKED)
    dst_stream.set_remain(100)
    event, p1, p2 = await task.wait(sync = False)
    assert(event == EventCode.STREAM_WRITE)
    assert(p1 == wsi1)
    assert(p2 == 4)
    src_stream.write([5,6,7,8])
    src_stream.destroy_once_empty()
    [ret] = await canon_stream_read(U8Type(), opts, task, rsi1, 0, 4)
    assert(ret == 4)
    [ret] = await canon_stream_read(U8Type(), sync_opts, task, rsi1, 0, 4)
    assert(ret == definitions.CLOSED)
    [] = await canon_stream_close_readable(U8Type(), task, rsi1)
    assert(mem[0:4] == b'\x05\x06\x07\x08')
    [ret] = await canon_stream_write(U8Type(), opts, task, wsi2, 0, 4)
    assert(ret == 4)
    [] = await canon_stream_close_writable(U8Type(), task, wsi2, 0)
    [ret] = await canon_stream_read(U8Type(), opts, task, rsi2, 0, 4)
    assert(ret == definitions.BLOCKED)
    event, p1, p2 = await task.wait(sync = False)
    assert(event == EventCode.CALL_DONE)
    assert(p1 == subi)
    assert(p2 == 0)
    event, p1, p2 = await task.wait(sync = False)
    assert(event == EventCode.STREAM_READ)
    assert(p1 == rsi2)
    assert(p2 == 4)
    [ret] = await canon_stream_read(U8Type(), opts, task, rsi2, 0, 4)
    assert(ret == definitions.CLOSED)
    [] = await canon_stream_close_readable(U8Type(), task, rsi2)
    [] = await canon_subtask_drop(task, subi)
    [ret] = await canon_stream_write(U8Type(), sync_opts, task, wsi1, 0, 4)
    assert(ret == 4)
    [] = await canon_stream_close_writable(U8Type(), task, wsi1, 0)
    return []

  await canon_lift(opts, inst, ft, core_func, None, on_start, on_return)
  assert(dst_stream.received == [11,12,13,14,15,16,17,18])


async def test_stream_forward():
  src_stream = HostSource([1,2,3,4], chunk=4)
  def on_start():
    return [src_stream]

  dst_stream = None
  def on_return(results):
    assert(len(results) == 1)
    nonlocal dst_stream
    dst_stream = results[0]

  async def core_func(task, args):
    assert(len(args) == 1)
    rsi1 = args[0]
    assert(rsi1 == 1)
    return [rsi1]

  opts = mk_opts()
  inst = ComponentInstance()
  ft = FuncType([StreamType(U8Type())], [StreamType(U8Type())])
  await canon_lift(opts, inst, ft, core_func, None, on_start, on_return)
  assert(src_stream is dst_stream)


async def test_receive_own_stream():
  inst = ComponentInstance()
  mem = bytearray(20)
  opts = mk_opts(memory=mem, sync=False)

  host_ft = FuncType([StreamType(U8Type())], [StreamType(U8Type())])
  async def host_import(task, on_start, on_return, on_block):
    args = on_start()
    assert(len(args) == 1)
    assert(isinstance(args[0], ReadableStream))
    on_return(args)

  async def core_func(task, args):
    assert(len(args) == 0)
    [wsi] = await canon_stream_new(U8Type(), task)
    assert(wsi == 1)
    retp = 4
    [ret] = await canon_lower(opts, host_ft, host_import, task, [wsi, retp])
    assert(ret == 0)
    result = int.from_bytes(mem[retp : retp+4], 'little', signed=False)
    assert(result == (wsi | 2**31))
    [] = await canon_stream_close_writable(U8Type(), task, wsi, 0)
    return []

  def on_start(): return []
  def on_return(results): assert(len(results) == 0)
  ft = FuncType([],[])
  await canon_lift(mk_opts(), inst, ft, core_func, None, on_start, on_return)


async def test_host_partial_reads_writes():
  mem = bytearray(20)
  opts = mk_opts(memory=mem, sync=False)

  src = HostSource([1,2,3,4], chunk=2, destroy_if_empty = False)
  source_ft = FuncType([], [StreamType(U8Type())])
  async def host_source(task, on_start, on_return, on_block):
    [] = on_start()
    on_return([src])

  dst = None
  sink_ft = FuncType([StreamType(U8Type())], [])
  async def host_sink(task, on_start, on_return, on_block):
    nonlocal dst
    [s] = on_start()
    dst = HostSink(s, chunk=1, remain=2)
    on_return([])

  async def core_func(task, args):
    assert(len(args) == 0)
    retp = 4
    [ret] = await canon_lower(opts, source_ft, host_source, task, [retp])
    assert(ret == 0)
    rsi = mem[retp]
    assert(rsi == 1)
    [ret] = await canon_stream_read(U8Type(), opts, task, rsi, 0, 4)
    assert(ret == 2)
    assert(mem[0:2] == b'\x01\x02')
    [ret] = await canon_stream_read(U8Type(), opts, task, rsi, 0, 4)
    assert(ret == 2)
    assert(mem[0:2] == b'\x03\x04')
    [ret] = await canon_stream_read(U8Type(), opts, task, rsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    src.write([5,6])
    event, p1, p2 = await task.wait(sync = False)
    assert(event == EventCode.STREAM_READ)
    assert(p1 == rsi)
    assert(p2 == 2)
    [] = await canon_stream_close_readable(U8Type(), task, rsi)

    [wsi] = await canon_stream_new(U8Type(), task)
    assert(wsi == 1)
    [ret] = await canon_lower(opts, sink_ft, host_sink, task, [wsi])
    assert(ret == 0)
    mem[0:6] = b'\x01\x02\x03\x04\x05\x06'
    [ret] = await canon_stream_write(U8Type(), opts, task, wsi, 0, 6)
    assert(ret == 2)
    [ret] = await canon_stream_write(U8Type(), opts, task, wsi, 2, 6)
    assert(ret == definitions.BLOCKED)
    dst.set_remain(4)
    event, p1, p2 = await task.wait(sync = False)
    assert(event == EventCode.STREAM_WRITE)
    assert(p1 == wsi)
    assert(p2 == 4)
    assert(dst.received == [1,2,3,4,5,6])
    [] = await canon_stream_close_writable(U8Type(), task, wsi, 0)
    dst.set_remain(100)
    assert(await dst.consume(100) is None)
    return []

  opts2 = mk_opts()
  inst = ComponentInstance()
  def on_start(): return []
  def on_return(results): assert(len(results) == 0)
  ft = FuncType([],[])
  await canon_lift(opts2, inst, ft, core_func, None, on_start, on_return)


async def test_wasm_to_wasm_stream():
  fut1, fut2, fut3, fut4 = asyncio.Future(), asyncio.Future(), asyncio.Future(), asyncio.Future()

  inst1 = ComponentInstance()
  mem1 = bytearray(10)
  opts1 = mk_opts(memory=mem1, sync=False)
  ft1 = FuncType([], [StreamType(U8Type())])
  async def core_func1(task, args):
    assert(not args)
    [wsi] = await canon_stream_new(U8Type(), task)
    [] = await canon_task_return(task, CoreFuncType(['i32'], []), [wsi])

    await task.on_block(fut1)

    mem1[0:4] = b'\x01\x02\x03\x04'
    [ret] = await canon_stream_write(U8Type(), opts1, task, wsi, 0, 2)
    assert(ret == 2)
    [ret] = await canon_stream_write(U8Type(), opts1, task, wsi, 2, 2)
    assert(ret == 2)

    await task.on_block(fut2)

    mem1[0:8] = b'\x05\x06\x07\x08\x09\x0a\x0b\x0c'
    [ret] = await canon_stream_write(U8Type(), opts1, task, wsi, 0, 8)
    assert(ret == definitions.BLOCKED)

    fut3.set_result(None)

    event, p1, p2 = await task.wait(sync = False)
    assert(event == EventCode.STREAM_WRITE)
    assert(p1 == wsi)
    assert(p2 == 4)

    fut4.set_result(None)

    [errori] = await canon_error_new(opts1, task, 0, 0)
    [] = await canon_stream_close_writable(U8Type(), task, wsi, errori)
    [] = await canon_error_drop(task, errori)
    return []

  func1 = partial(canon_lift, opts1, inst1, ft1, core_func1)

  inst2 = ComponentInstance()
  heap2 = Heap(10)
  mem2 = heap2.memory
  opts2 = mk_opts(memory=heap2.memory, realloc=heap2.realloc, sync=False)
  ft2 = FuncType([], [])
  async def core_func2(task, args):
    assert(not args)
    [] = await canon_task_return(task, CoreFuncType([], []), [])

    retp = 0
    [ret] = await canon_lower(opts2, ft1, func1, task, [retp])
    subi,state = unpack_lower_result(ret)
    assert(state== CallState.RETURNED)
    rsi = mem2[0]
    assert(rsi == 1)

    [ret] = await canon_stream_read(U8Type(), opts2, task, rsi, 0, 8)
    assert(ret == definitions.BLOCKED)

    fut1.set_result(None)

    event, p1, p2 = await task.wait(sync = False)
    assert(event == EventCode.STREAM_READ)
    assert(p1 == rsi)
    assert(p2 == 4)
    assert(mem2[0:8] == b'\x01\x02\x03\x04\x00\x00\x00\x00')

    fut2.set_result(None)
    await task.on_block(fut3)

    mem2[0:8] = bytes(8)
    [ret] = await canon_stream_read(U8Type(), opts2, task, rsi, 0, 2)
    assert(ret == 2)
    assert(mem2[0:6] == b'\x05\x06\x00\x00\x00\x00')
    [ret] = await canon_stream_read(U8Type(), opts2, task, rsi, 2, 2)
    assert(ret == 2)
    assert(mem2[0:6] == b'\x05\x06\x07\x08\x00\x00')

    await task.on_block(fut4)

    [ret] = await canon_stream_read(U8Type(), opts2, task, rsi, 0, 2)
    errori = 1
    assert(ret == (definitions.CLOSED | errori))
    [] = await canon_stream_close_readable(U8Type(), task, rsi)
    [] = await canon_error_debug_message(opts2, task, errori, 0)
    [] = await canon_error_drop(task, errori)

    event, callidx, _ = await task.wait(sync = False)
    assert(event == EventCode.CALL_DONE)
    assert(callidx == subi)
    [] = await canon_subtask_drop(task, subi)
    return []

  await canon_lift(opts2, inst2, ft2, core_func2, None, lambda:[], lambda _:())


async def test_borrow_stream():
  rt_inst = ComponentInstance()
  rt = ResourceType(rt_inst, None)

  inst1 = ComponentInstance()
  mem1 = bytearray(12)
  opts1 = mk_opts(memory=mem1)
  ft1 = FuncType([StreamType(BorrowType(rt))], [])
  async def core_func1(task, args):
    [rsi] = args

    stream_opts = mk_opts(memory=mem1, sync=False)
    [ret] = await canon_stream_read(BorrowType(rt), stream_opts, task, rsi, 4, 2)
    assert(ret == definitions.BLOCKED)

    event, p1, p2 = await task.wait(sync = False)
    assert(event == EventCode.STREAM_READ)
    assert(p1 == rsi)
    assert(p2 == 2)
    [ret] = await canon_stream_read(BorrowType(rt), stream_opts, task, rsi, 0, 2)
    assert(ret == definitions.CLOSED)

    [] = await canon_stream_close_readable(BorrowType(rt), task, rsi)

    h1 = mem1[4]
    h2 = mem1[8]
    assert(await canon_resource_rep(rt, task, h1) == [42])
    assert(await canon_resource_rep(rt, task, h2) == [43])
    [] = await canon_resource_drop(rt, True, task, h1)
    [] = await canon_resource_drop(rt, True, task, h2)

    return []

  func1 = partial(canon_lift, opts1, inst1, ft1, core_func1)

  inst2 = ComponentInstance()
  mem2 = bytearray(10)
  sync_opts2 = mk_opts(memory=mem2, sync=True)
  async_opts2 = mk_opts(memory=mem2, sync=False)
  ft2 = FuncType([], [])
  async def core_func2(task, args):
    assert(not args)

    [wsi] = await canon_stream_new(BorrowType(rt), task)
    [ret] = await canon_lower(async_opts2, ft1, func1, task, [wsi])
    subi,state = unpack_lower_result(ret)
    assert(state == CallState.STARTED)

    [h1] = await canon_resource_new(rt, task, 42)
    [h2] = await canon_resource_new(rt, task, 43)
    mem2[0] = h1
    mem2[4] = h2

    [ret] = await canon_stream_write(BorrowType(rt), async_opts2, task, wsi, 0, 2)
    assert(ret == 2)
    [] = await canon_stream_close_writable(BorrowType(rt), task, wsi, 0)

    event, p1, _ = await task.wait(sync = False)
    assert(event == EventCode.CALL_DONE)
    assert(p1 == subi)

    [] = await canon_subtask_drop(task, subi)
    return []

  await canon_lift(sync_opts2, inst2, ft2, core_func2, None, lambda:[], lambda _:())


async def test_cancel_copy():
  inst = ComponentInstance()
  mem = bytearray(10)
  lower_opts = mk_opts(memory=mem, sync=False)

  host_ft1 = FuncType([StreamType(U8Type())],[])
  host_sink = None
  async def host_func1(task, on_start, on_return, on_block):
    nonlocal host_sink
    [stream] = on_start()
    host_sink = HostSink(stream, 2, remain = 0)
    on_return([])

  host_ft2 = FuncType([], [StreamType(U8Type())])
  host_source = None
  async def host_func2(task, on_start, on_return, on_block):
    nonlocal host_source
    [] = on_start()
    host_source = HostSource([], chunk=2, destroy_if_empty = False)
    on_return([host_source])

  lift_opts = mk_opts()
  async def core_func(task, args):
    assert(not args)

    [wsi] = await canon_stream_new(U8Type(), task)
    [ret] = await canon_lower(lower_opts, host_ft1, host_func1, task, [wsi])
    assert(ret == 0)
    mem[0:4] = b'\x0a\x0b\x0c\x0d'
    [ret] = await canon_stream_write(U8Type(), lower_opts, task, wsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_sink.set_remain(2)
    got = await host_sink.consume(2)
    assert(got == [0xa, 0xb])
    [ret] = await canon_stream_cancel_write(True, task, wsi)
    assert(ret == 2)
    [] = await canon_stream_close_writable(U8Type(), task, wsi, 0)
    host_sink.set_remain(100)
    assert(await host_sink.consume(100) is None)

    [wsi] = await canon_stream_new(U8Type(), task)
    [ret] = await canon_lower(lower_opts, host_ft1, host_func1, task, [wsi])
    assert(ret == 0)
    mem[0:4] = b'\x01\x02\x03\x04'
    [ret] = await canon_stream_write(U8Type(), lower_opts, task, wsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_sink.set_remain(2)
    got = await host_sink.consume(2)
    assert(got == [1, 2])
    [ret] = await canon_stream_cancel_write(False, task, wsi)
    assert(ret == 2)
    [] = await canon_stream_close_writable(U8Type(), task, wsi, 0)
    host_sink.set_remain(100)
    assert(await host_sink.consume(100) is None)

    retp = 0
    [ret] = await canon_lower(lower_opts, host_ft2, host_func2, task, [retp])
    assert(ret == 0)
    rsi = mem[retp]
    [ret] = await canon_stream_read(U8Type(), lower_opts, task, rsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    [ret] = await canon_stream_cancel_read(True, task, rsi)
    assert(ret == 0)
    [] = await canon_stream_close_readable(U8Type(), task, rsi)

    retp = 0
    [ret] = await canon_lower(lower_opts, host_ft2, host_func2, task, [retp])
    assert(ret == 0)
    rsi = mem[retp]
    [ret] = await canon_stream_read(U8Type(), lower_opts, task, rsi, 0, 4)
    assert(ret == definitions.BLOCKED)
    host_source.eager_cancel.clear()
    [ret] = await canon_stream_cancel_read(False, task, rsi)
    assert(ret == definitions.BLOCKED)
    host_source.write([7,8])
    await asyncio.sleep(0)
    host_source.eager_cancel.set()
    event,p1,p2 = await task.wait(sync = False)
    assert(event == EventCode.STREAM_READ)
    assert(p1 == rsi)
    assert(p2 == 2)
    assert(mem[0:2] == b'\x07\x08')
    [] = await canon_stream_close_readable(U8Type(), task, rsi)

    return []

  await canon_lift(lift_opts, inst, FuncType([],[]), core_func, None, lambda:[], lambda _:())


class HostFutureSink:
  v: Optional[any] = None

  def remain(self):
    return 1 if self.v is None else 0

  def lower(self, v):
    assert(not self.v)
    assert(len(v) == 1)
    self.v = v[0]

class HostFutureSource(ReadableStream):
  v: Optional[asyncio.Future]
  def __init__(self):
    self.v = asyncio.Future()
  def closed(self):
    return self.v is None
  def closed_with_error(self):
    assert(self.closed())
    return None
  def close(self, error = None):
    assert(self.v is None)
  async def read(self, dst, on_block):
    assert(self.v is not None)
    v = await on_block(self.v)
    if v:
      dst.lower([v])
      self.v = None
  async def cancel_read(self, dst, on_block):
    if self.v and not self.v.done():
      self.v.set_result(None)
      self.v = asyncio.Future()
  def maybe_writer_handle_index(self, inst):
    return None

async def test_futures():
  inst = ComponentInstance()
  mem = bytearray(10)
  lower_opts = mk_opts(memory=mem, sync=False)

  host_ft1 = FuncType([FutureType(U8Type())],[FutureType(U8Type())])
  async def host_func(task, on_start, on_return, on_block):
    [future] = on_start()
    outgoing = HostFutureSource()
    on_return([outgoing])
    incoming = HostFutureSink()
    await future.read(incoming, on_block)
    assert(incoming.v == 42)
    outgoing.v.set_result(43)

  lift_opts = mk_opts()
  async def core_func(task, args):
    assert(not args)
    [wfi] = await canon_future_new(U8Type(), task)
    retp = 0
    [ret] = await canon_lower(lower_opts, host_ft1, host_func, task, [wfi, retp])
    subi,state = unpack_lower_result(ret)
    assert(state == CallState.RETURNED)
    rfi = mem[retp]

    readp = 0
    [ret] = await canon_future_read(U8Type(), lower_opts, task, rfi, readp)
    assert(ret == definitions.BLOCKED)

    writep = 8
    mem[writep] = 42
    [ret] = await canon_future_write(U8Type(), lower_opts, task, wfi, writep)
    assert(ret == 1)

    event,p1,p2 = await task.wait(sync = False)
    assert(event == EventCode.CALL_DONE)
    assert(p1 == subi)

    event,p1,p2 = await task.wait(sync = False)
    assert(event == EventCode.FUTURE_READ)
    assert(p1 == rfi)
    assert(p2 == 1)
    assert(mem[readp] == 43)

    [] = await canon_future_close_writable(U8Type(), task, wfi, 0)
    [] = await canon_future_close_readable(U8Type(), task, rfi)
    [] = await canon_subtask_drop(task, subi)

    [wfi] = await canon_future_new(U8Type(), task)
    retp = 0
    [ret] = await canon_lower(lower_opts, host_ft1, host_func, task, [wfi, retp])
    subi,state = unpack_lower_result(ret)
    assert(state == CallState.RETURNED)
    rfi = mem[retp]

    readp = 0
    [ret] = await canon_future_read(U8Type(), lower_opts, task, rfi, readp)
    assert(ret == definitions.BLOCKED)

    writep = 8
    mem[writep] = 42
    [ret] = await canon_future_write(U8Type(), lower_opts, task, wfi, writep)
    assert(ret == 1)

    event,p1,p2 = await task.wait(sync = False)
    assert(event == EventCode.CALL_DONE)
    assert(p1 == subi)

    await task.yield_(sync = False)
    [ret] = await canon_future_cancel_read(True, task, rfi)
    assert(ret == 1)
    assert(mem[readp] == 43)

    [] = await canon_future_close_writable(U8Type(), task, wfi, 0)
    [] = await canon_future_close_readable(U8Type(), task, rfi)
    [] = await canon_subtask_drop(task, subi)

    return []

  await canon_lift(lift_opts, inst, FuncType([],[]), core_func, None, lambda:[], lambda _:())


async def run_async_tests():
  await test_roundtrips()
  await test_handles()
  await test_async_to_async()
  await test_async_callback()
  await test_async_to_sync()
  await test_async_backpressure()
  await test_sync_using_wait()
  await test_eager_stream_completion()
  await test_stream_forward()
  await test_receive_own_stream()
  await test_host_partial_reads_writes()
  await test_async_stream_ops()
  await test_wasm_to_wasm_stream()
  await test_borrow_stream()
  await test_cancel_copy()
  await test_futures()

asyncio.run(run_async_tests())

print("All tests passed")
