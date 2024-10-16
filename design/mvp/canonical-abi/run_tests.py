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
      print('oom: have {} need {}'.format(len(self.memory), self.last_alloc))
      trap()
    self.memory[ret : ret + original_size] = self.memory[original_ptr : original_ptr + original_size]
    return ret

def mk_opts(memory = bytearray(), encoding = 'utf8', realloc = None, post_return = None):
  opts = CanonicalOptions()
  opts.memory = memory
  opts.string_encoding = encoding
  opts.realloc = realloc
  opts.post_return = post_return
  opts.sync = True
  opts.callback = None
  return opts

def mk_cx(memory = bytearray(), encoding = 'utf8', realloc = None, post_return = None):
  opts = mk_opts(memory, encoding, realloc, post_return)
  inst = ComponentInstance()
  return CallContext(opts, inst, None)

def mk_str(s):
  return (s, 'utf8', len(s.encode('utf-8')))

def mk_tup(*a):
  def mk_tup_rec(x):
    if isinstance(x, list):
      return { str(i):mk_tup_rec(v) for i,v in enumerate(x) }
    return x
  return { str(i):mk_tup_rec(v) for i,v in enumerate(a) }

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

def test_roundtrip(t, v):
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

  flat_args = asyncio.run(caller_task.enter(lambda: [v]))

  return_in_heap = len(flatten_types([t])) > definitions.MAX_FLAT_RESULTS
  if return_in_heap:
    flat_args += [ caller_heap.realloc(0, 0, alignment(t), elem_size(t)) ]

  flat_results = asyncio.run(canon_lower(caller_opts, ft, lifted_callee, caller_task, flat_args))

  if return_in_heap:
    flat_results = [ flat_args[-1] ]

  [got] = lift_flat_values(caller_task, definitions.MAX_FLAT_PARAMS, CoreValueIter(flat_results), [t])
  caller_task.exit()

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

  asyncio.run(canon_lift(opts, inst, ft, core_wasm, None, on_start, on_return, None))

  assert(len(got) == 3)
  assert(got[0] == 46)
  assert(got[1] == 43)
  assert(got[2] == 45)
  assert(len(inst.resources.table(rt).array) == 5)
  assert(all(inst.resources.table(rt).array[i] is None for i in range(4)))
  assert(len(inst.resources.table(rt).free) == 4)
  definitions.MAX_FLAT_RESULTS = before

test_handles()

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
    assert(ret == (1 | (CallState.STARTED << 30)))
    retp = ptr
    consumer_heap.memory[retp] = 13
    [ret] = await canon_lower(consumer_opts, blocking_ft, blocking_callee, task, [83, retp])
    assert(ret == (2 | (CallState.STARTING << 30)))
    assert(consumer_heap.memory[retp] == 13)
    fut1.set_result(None)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 1)
    [] = await canon_subtask_drop(task, callidx)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_STARTED)
    assert(callidx == 2)
    assert(consumer_heap.memory[retp] == 13)
    fut2.set_result(None)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_RETURNED)
    assert(callidx == 2)
    assert(consumer_heap.memory[retp] == 44)
    fut3.set_result(None)
    event, callidx = await task.wait()
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
    event, callidx = await task.wait()
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

asyncio.run(test_async_to_async())

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
    assert(len(args) == 3)
    if args[0] == 42:
      assert(args[1] == EventCode.CALL_DONE)
      assert(args[2] == 1)
      await canon_subtask_drop(task, 1)
      return [53]
    elif args[0] == 52:
      assert(args[1] == EventCode.YIELDED)
      assert(args[2] == 0)
      fut2.set_result(None)
      return [62]
    else:
      assert(args[0] == 62)
      assert(args[1] == EventCode.CALL_DONE)
      assert(args[2] == 2)
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

asyncio.run(test_async_callback())

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

    assert(await task.poll() is None)

    fut.set_result(None)
    assert(producer1_done == False)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 1)
    await canon_subtask_drop(task, callidx)
    assert(producer1_done == True)

    assert(producer2_done == False)
    await canon_task_yield(task)
    assert(producer2_done == True)
    event, callidx = await task.poll()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 2)
    await canon_subtask_drop(task, callidx)
    assert(producer2_done == True)

    assert(await task.poll() is None)

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

asyncio.run(test_async_to_sync())

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

    assert(await task.poll() is None)

    fut.set_result(None)
    assert(producer1_done == False)
    assert(producer2_done == False)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 1)
    assert(producer1_done == True)
    assert(producer2_done == True)
    event, callidx = await task.poll()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 2)
    assert(producer2_done == True)

    await canon_subtask_drop(task, 1)
    await canon_subtask_drop(task, 2)

    assert(await task.poll() is None)

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

if definitions.DETERMINISTIC_PROFILE:
  asyncio.run(test_async_backpressure())

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
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 1)
    fut2.set_result(None)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 2)

    await canon_subtask_drop(task, 1)
    await canon_subtask_drop(task, 2)

    return []

  inst = ComponentInstance()
  def on_start(): return []
  def on_return(results): pass
  await canon_lift(mk_opts(), inst, ft, core_func, None, on_start, on_return)

asyncio.run(test_sync_using_wait())

print("All tests passed")
