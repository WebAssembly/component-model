import definitions
from definitions import *

asyncio.run(definitions.current_task.acquire())

def unlock_on_block():
  definitions.current_task.release()

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
  return CallContext(opts, ComponentInstance())

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
#test(Record([]), [], {})
test(Record([Field('x',U8()), Field('y',U16()), Field('z',U32())]), [1,2,3], {'x':1,'y':2,'z':3})
test(Tuple([Tuple([U8(),U8()]),U8()]), [1,2,3], {'0':{'0':1,'1':2},'1':3})
# Empty flags types are not permitted yet.
#t = Flags([])
#test(t, [], {})
t = Flags(['a','b'])
test(t, [0], {'a':False,'b':False})
test(t, [2], {'a':False,'b':True})
test(t, [3], {'a':True,'b':True})
test(t, [4], {'a':False,'b':False})
test(Flags([str(i) for i in range(33)]), [0xffffffff,0x1], { str(i):True for i in range(33) })
t = Variant([Case('x',U8()),Case('y',F32()),Case('z',None)])
test(t, [0,42], {'x': 42})
test(t, [0,256], {'x': 0})
test(t, [1,0x4048f5c3], {'y': 3.140000104904175})
test(t, [2,0xffffffff], {'z': None})
t = Option(F32())
test(t, [0,3.14], {'none':None})
test(t, [1,3.14], {'some':3.14})
t = Result(U8(),U32())
test(t, [0, 42], {'ok':42})
test(t, [1, 1000], {'error':1000})
t = Variant([Case('w',U8()), Case('x',U8(),'w'), Case('y',U8()), Case('z',U8(),'x')])
test(t, [0, 42], {'w':42})
test(t, [1, 42], {'x|w':42})
test(t, [2, 42], {'y':42})
test(t, [3, 42], {'z|x|w':42})
t2 = Variant([Case('w',U8())])
test(t, [0, 42], {'w':42}, lower_t=t2, lower_v={'w':42})
test(t, [1, 42], {'x|w':42}, lower_t=t2, lower_v={'w':42})
test(t, [3, 42], {'z|x|w':42}, lower_t=t2, lower_v={'w':42})

def test_pairs(t, pairs):
  for arg,expect in pairs:
    test(t, [arg], expect)

test_pairs(Bool(), [(0,False),(1,True),(2,True),(4294967295,True)])
test_pairs(U8(), [(127,127),(128,128),(255,255),(256,0),
                  (4294967295,255),(4294967168,128),(4294967167,127)])
test_pairs(S8(), [(127,127),(128,-128),(255,-1),(256,0),
                  (4294967295,-1),(4294967168,-128),(4294967167,127)])
test_pairs(U16(), [(32767,32767),(32768,32768),(65535,65535),(65536,0),
                   ((1<<32)-1,65535),((1<<32)-32768,32768),((1<<32)-32769,32767)])
test_pairs(S16(), [(32767,32767),(32768,-32768),(65535,-1),(65536,0),
                   ((1<<32)-1,-1),((1<<32)-32768,-32768),((1<<32)-32769,32767)])
test_pairs(U32(), [((1<<31)-1,(1<<31)-1),(1<<31,1<<31),(((1<<32)-1),(1<<32)-1)])
test_pairs(S32(), [((1<<31)-1,(1<<31)-1),(1<<31,-(1<<31)),((1<<32)-1,-1)])
test_pairs(U64(), [((1<<63)-1,(1<<63)-1), (1<<63,1<<63), ((1<<64)-1,(1<<64)-1)])
test_pairs(S64(), [((1<<63)-1,(1<<63)-1), (1<<63,-(1<<63)), ((1<<64)-1,-1)])
test_pairs(F32(), [(3.14,3.14)])
test_pairs(F64(), [(3.14,3.14)])
test_pairs(Char(), [(0,'\x00'), (65,'A'), (0xD7FF,'\uD7FF'), (0xD800,None), (0xDFFF,None)])
test_pairs(Char(), [(0xE000,'\uE000'), (0x10FFFF,'\U0010FFFF'), (0x110000,None), (0xFFFFFFFF,None)])
test_pairs(Enum(['a','b']), [(0,{'a':None}), (1,{'b':None}), (2,None)])

def test_nan32(inbits, outbits):
  origf = decode_i32_as_float(inbits)
  f = lift_flat(mk_cx(), CoreValueIter([origf]), F32())
  if DETERMINISTIC_PROFILE:
    assert(encode_float_as_i32(f) == outbits)
  else:
    assert(not math.isnan(origf) or math.isnan(f))
  cx = mk_cx(int.to_bytes(inbits, 4, 'little'))
  f = load(cx, 0, F32())
  if DETERMINISTIC_PROFILE:
    assert(encode_float_as_i32(f) == outbits)
  else:
    assert(not math.isnan(origf) or math.isnan(f))

def test_nan64(inbits, outbits):
  origf = decode_i64_as_float(inbits)
  f = lift_flat(mk_cx(), CoreValueIter([origf]), F64())
  if DETERMINISTIC_PROFILE:
    assert(encode_float_as_i64(f) == outbits)
  else:
    assert(not math.isnan(origf) or math.isnan(f))
  cx = mk_cx(int.to_bytes(inbits, 8, 'little'))
  f = load(cx, 0, F64())
  if DETERMINISTIC_PROFILE:
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
  test(String(), [0, tagged_code_units], v, cx, dst_encoding)

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
#test_heap(List(Record([])), [{},{},{}], [0,3], [])
test_heap(List(Bool()), [True,False,True], [0,3], [1,0,1])
test_heap(List(Bool()), [True,False,True], [0,3], [1,0,2])
test_heap(List(Bool()), [True,False,True], [3,3], [0xff,0xff,0xff, 1,0,1])
test_heap(List(U8()), [1,2,3], [0,3], [1,2,3])
test_heap(List(U16()), [1,2,3], [0,3], [1,0, 2,0, 3,0 ])
test_heap(List(U16()), None, [1,3], [0, 1,0, 2,0, 3,0 ])
test_heap(List(U32()), [1,2,3], [0,3], [1,0,0,0, 2,0,0,0, 3,0,0,0])
test_heap(List(U64()), [1,2], [0,2], [1,0,0,0,0,0,0,0, 2,0,0,0,0,0,0,0])
test_heap(List(S8()), [-1,-2,-3], [0,3], [0xff,0xfe,0xfd])
test_heap(List(S16()), [-1,-2,-3], [0,3], [0xff,0xff, 0xfe,0xff, 0xfd,0xff])
test_heap(List(S32()), [-1,-2,-3], [0,3], [0xff,0xff,0xff,0xff, 0xfe,0xff,0xff,0xff, 0xfd,0xff,0xff,0xff])
test_heap(List(S64()), [-1,-2], [0,2], [0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff, 0xfe,0xff,0xff,0xff,0xff,0xff,0xff,0xff])
test_heap(List(Char()), ['A','B','c'], [0,3], [65,00,00,00, 66,00,00,00, 99,00,00,00])
test_heap(List(String()), [mk_str("hi"),mk_str("wat")], [0,2],
          [16,0,0,0, 2,0,0,0, 21,0,0,0, 3,0,0,0,
           ord('h'), ord('i'),   0xf,0xf,0xf,   ord('w'), ord('a'), ord('t')])
test_heap(List(List(U8())), [[3,4,5],[],[6,7]], [0,3],
          [24,0,0,0, 3,0,0,0, 0,0,0,0, 0,0,0,0, 27,0,0,0, 2,0,0,0,
          3,4,5,  6,7])
test_heap(List(List(U16())), [[5,6]], [0,1],
          [8,0,0,0, 2,0,0,0,
          5,0, 6,0])
test_heap(List(List(U16())), None, [0,1],
          [9,0,0,0, 2,0,0,0,
          0, 5,0, 6,0])
test_heap(List(Tuple([U8(),U8(),U16(),U32()])), [mk_tup(6,7,8,9),mk_tup(4,5,6,7)], [0,2],
          [6, 7, 8,0, 9,0,0,0,   4, 5, 6,0, 7,0,0,0])
test_heap(List(Tuple([U8(),U16(),U8(),U32()])), [mk_tup(6,7,8,9),mk_tup(4,5,6,7)], [0,2],
          [6,0xff, 7,0, 8,0xff,0xff,0xff, 9,0,0,0,   4,0xff, 5,0, 6,0xff,0xff,0xff, 7,0,0,0])
test_heap(List(Tuple([U16(),U8()])), [mk_tup(6,7),mk_tup(8,9)], [0,2],
          [6,0, 7, 0x0ff, 8,0, 9, 0xff])
test_heap(List(Tuple([Tuple([U16(),U8()]),U8()])), [mk_tup([4,5],6),mk_tup([7,8],9)], [0,2],
          [4,0, 5,0xff, 6,0xff,  7,0, 8,0xff, 9,0xff])
# Empty flags types are not permitted yet.
#t = List(Flags([]))
#test_heap(t, [{},{},{}], [0,3],
#          [])
#t = List(Tuple([Flags([]), U8()]))
#test_heap(t, [mk_tup({}, 42), mk_tup({}, 43), mk_tup({}, 44)], [0,3],
#          [42,43,44])
t = List(Flags(['a','b']))
test_heap(t, [{'a':False,'b':False},{'a':False,'b':True},{'a':True,'b':True}], [0,3],
          [0,2,3])
test_heap(t, [{'a':False,'b':False},{'a':False,'b':True},{'a':False,'b':False}], [0,3],
          [0,2,4])
t = List(Flags([str(i) for i in range(9)]))
v = [{ str(i):b for i in range(9) } for b in [True,False]]
test_heap(t, v, [0,2],
          [0xff,0x1, 0,0])
test_heap(t, v, [0,2],
          [0xff,0x3, 0,0])
t = List(Flags([str(i) for i in range(17)]))
v = [{ str(i):b for i in range(17) } for b in [True,False]]
test_heap(t, v, [0,2],
          [0xff,0xff,0x1,0, 0,0,0,0])
test_heap(t, v, [0,2],
          [0xff,0xff,0x3,0, 0,0,0,0])
t = List(Flags([str(i) for i in range(33)]))
v = [{ str(i):b for i in range(33) } for b in [True,False]]
test_heap(t, v, [0,2],
          [0xff,0xff,0xff,0xff,0x1,0,0,0, 0,0,0,0,0,0,0,0])
test_heap(t, v, [0,2],
          [0xff,0xff,0xff,0xff,0x3,0,0,0, 0,0,0,0,0,0,0,0])

def test_flatten(t, params, results):
  expect = CoreFuncType(params, results)

  if len(params) > definitions.MAX_FLAT_PARAMS:
    expect.params = ['i32']

  if len(results) > definitions.MAX_FLAT_RESULTS:
    expect.results = ['i32']
  got = flatten_functype(CanonicalOptions(), t, 'lift', Needs())
  assert(got == expect)

  if len(results) > definitions.MAX_FLAT_RESULTS:
    expect.params += ['i32']
    expect.results = []
  got = flatten_functype(CanonicalOptions(), t, 'lower', Needs())
  assert(got == expect)

test_flatten(FuncType([U8(),F32(),F64()],[]), ['i32','f32','f64'], [])
test_flatten(FuncType([U8(),F32(),F64()],[F32()]), ['i32','f32','f64'], ['f32'])
test_flatten(FuncType([U8(),F32(),F64()],[U8()]), ['i32','f32','f64'], ['i32'])
test_flatten(FuncType([U8(),F32(),F64()],[Tuple([F32()])]), ['i32','f32','f64'], ['f32'])
test_flatten(FuncType([U8(),F32(),F64()],[Tuple([F32(),F32()])]), ['i32','f32','f64'], ['f32','f32'])
test_flatten(FuncType([U8(),F32(),F64()],[F32(),F32()]), ['i32','f32','f64'], ['f32','f32'])
test_flatten(FuncType([U8() for _ in range(17)],[]), ['i32' for _ in range(17)], [])
test_flatten(FuncType([U8() for _ in range(17)],[Tuple([U8(),U8()])]), ['i32' for _ in range(17)], ['i32','i32'])

def test_roundtrip(t, v):
  before = definitions.MAX_FLAT_RESULTS
  definitions.MAX_FLAT_RESULTS = 16

  ft = FuncType([t],[t])
  async def callee(task, x):
    return x

  callee_heap = Heap(1000)
  callee_opts = mk_opts(callee_heap.memory, 'utf8', callee_heap.realloc)
  callee_inst = ComponentInstance()
  lifted_callee = partial(canon_lift, callee_opts, callee_inst, callee, ft)

  caller_heap = Heap(1000)
  caller_opts = mk_opts(caller_heap.memory, 'utf8', caller_heap.realloc)
  caller_inst = ComponentInstance()
  caller_task = Task(caller_opts, caller_inst, None, lambda:())

  return_in_heap = len(flatten_types([t], 'lift', Needs())) > definitions.MAX_FLAT_RESULTS

  asyncio.run(caller_task.enter())

  flat_args = lower_flat_values(caller_task, definitions.MAX_FLAT_PARAMS, [v], [t])
  if return_in_heap:
    flat_args += [ caller_heap.realloc(0, 0, alignment(t), elem_size(t)) ]
  flat_results = asyncio.run(canon_lower(caller_opts, lifted_callee, ft, caller_task, flat_args))
  if return_in_heap:
    flat_results = [ flat_args[-1] ]
  [got] = lift_flat_values(caller_task, definitions.MAX_FLAT_PARAMS, CoreValueIter(flat_results), [t])
  caller_task.exit()

  if got != v:
    fail("test_roundtrip({},{}) got {}".format(t, v, got))

  definitions.MAX_FLAT_RESULTS = before

test_roundtrip(S8(), -1)
test_roundtrip(Tuple([U16(),U16()]), mk_tup(3,4))
test_roundtrip(List(String()), [mk_str("hello there")])
test_roundtrip(List(List(String())), [[mk_str("one"),mk_str("two")],[mk_str("three")]])
test_roundtrip(List(Option(Tuple([String(),U16()]))), [{'some':mk_tup(mk_str("answer"),42)}])
test_roundtrip(Variant([Case('x', Tuple([U32(),U32(),U32(),U32(), U32(),U32(),U32(),U32(),
                                         U32(),U32(),U32(),U32(), U32(),U32(),U32(),U32(), String()]))]),
               {'x': mk_tup(1,2,3,4, 5,6,7,8, 9,10,11,12, 13,14,15,16, mk_str("wat"))})

def test_handles():
  before = definitions.MAX_FLAT_RESULTS
  definitions.MAX_FLAT_RESULTS = 16

  dtor_value = None
  async def dtor(task, args):
    nonlocal dtor_value
    assert(len(args) == 1)
    dtor_value = args[0]

  rt = ResourceType(ComponentInstance(), dtor) # usable in imports and exports
  inst = ComponentInstance()
  rt2 = ResourceType(inst, dtor) # only usable in exports
  opts = mk_opts()

  async def host_import(entered, on_block, on_start, on_return):
    args = on_start()
    assert(len(args) == 2)
    assert(args[0] == 42)
    assert(args[1] == 44)
    on_return([45])

  async def core_wasm(task, args):
    nonlocal dtor_value

    assert(len(args) == 4)
    assert(len(inst.handles.table(rt).array) == 4)
    assert(inst.handles.table(rt).array[0] is None)
    assert(args[0] == 1)
    assert(args[1] == 2)
    assert(args[2] == 3)
    assert(args[3] == 13)
    assert((await canon_resource_rep(rt, task, 1))[0] == 42)
    assert((await canon_resource_rep(rt, task, 2))[0] == 43)
    assert((await canon_resource_rep(rt, task, 3))[0] == 44)

    host_ft = FuncType([
      Borrow(rt),
      Borrow(rt)
    ],[
      Own(rt)
    ])
    args = [
      1,
      3
    ]
    results = await canon_lower(opts, host_import, host_ft, task, args)
    assert(len(results) == 1)
    assert(results[0] == 4)
    assert((await canon_resource_rep(rt, task, 4))[0] == 45)

    dtor_value = None
    await canon_resource_drop(rt, True, task, 1)
    assert(dtor_value == 42)
    assert(len(inst.handles.table(rt).array) == 5)
    assert(inst.handles.table(rt).array[1] is None)
    assert(len(inst.handles.table(rt).free) == 1)

    h = (await canon_resource_new(rt, task, 46))[0]
    assert(h == 1)
    assert(len(inst.handles.table(rt).array) == 5)
    assert(inst.handles.table(rt).array[1] is not None)
    assert(len(inst.handles.table(rt).free) == 0)

    dtor_value = None
    await canon_resource_drop(rt, True, task, 3)
    assert(dtor_value is None)
    assert(len(inst.handles.table(rt).array) == 5)
    assert(inst.handles.table(rt).array[3] is None)
    assert(len(inst.handles.table(rt).free) == 1)

    return [1, 2, 4]

  ft = FuncType([
    Own(rt),
    Own(rt),
    Borrow(rt),
    Borrow(rt2)
  ],[
    Own(rt),
    Own(rt),
    Own(rt)
  ])

  def on_start():
    return [ 42, 43, 44, 13 ]

  got = None
  def on_return(results):
    nonlocal got
    got = results

  asyncio.run(canon_lift(opts, inst, core_wasm, ft, None, lambda:(), on_start, on_return))

  assert(len(got) == 3)
  assert(got[0] == 46)
  assert(got[1] == 43)
  assert(got[2] == 45)
  assert(len(inst.handles.table(rt).array) == 5)
  assert(all(inst.handles.table(rt).array[i] is None for i in range(4)))
  assert(len(inst.handles.table(rt).free) == 4)
  definitions.MAX_FLAT_RESULTS = before

test_handles()

async def test_async_to_async():
  producer_heap = Heap(10)
  producer_opts = mk_opts(producer_heap.memory)
  producer_opts.sync = False

  producer_inst = ComponentInstance()

  eager_ft = FuncType([], [U8()])
  async def core_eager_producer(task, args):
    assert(len(args) == 0)
    [] = await canon_task_start(task, CoreFuncType([],[]), [])
    [] = await canon_task_return(task, CoreFuncType(['i32'],[]), [43])
    return []
  eager_callee = partial(canon_lift, producer_opts, producer_inst, core_eager_producer, eager_ft)

  fut1, fut2, fut3 = asyncio.Future(), asyncio.Future(), asyncio.Future()
  blocking_ft = FuncType([U8()], [U8()])
  async def core_blocking_producer(task, args):
    assert(len(args) == 0)
    await task.suspend(fut1)
    [x] = await canon_task_start(task, CoreFuncType([],['i32']), [])
    assert(x == 83)
    await task.suspend(fut2)
    [] = await canon_task_return(task, CoreFuncType(['i32'],[]), [44])
    await task.suspend(fut3)
    return []
  blocking_callee = partial(canon_lift, producer_opts, producer_inst, core_blocking_producer, blocking_ft) 

  consumer_heap = Heap(10)
  consumer_opts = mk_opts(consumer_heap.memory)
  consumer_opts.sync = False

  async def consumer(task, args):
    assert(len(args) == 0)

    [b] = await canon_task_start(task, CoreFuncType([],['i32']), [])

    ptr = consumer_heap.realloc(0, 0, 1, 1)
    [ret] = await canon_lower(consumer_opts, eager_callee, eager_ft, task, [0, ptr])
    assert(ret == 0)
    u8 = consumer_heap.memory[ptr]
    assert(u8 == 43)

    retp = ptr
    consumer_heap.memory[retp] = 13
    [ret] = await canon_lower(consumer_opts, blocking_callee, blocking_ft, task, [83, retp])
    assert(consumer_heap.memory[retp] == 13)
    assert(task.num_async_subtasks == 1)
    assert(ret == 1)
    fut1.set_result(None)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_STARTED)
    assert(callidx == 1)
    assert(consumer_heap.memory[retp] == 13)
    fut2.set_result(None)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_RETURNED)
    assert(callidx == 1)
    assert(consumer_heap.memory[retp] == 44)
    fut3.set_result(None)
    assert(task.num_async_subtasks == 1)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 1)
    assert(task.num_async_subtasks == 0)

    dtor_fut = asyncio.Future()
    dtor_value = None
    async def dtor(task, args):
      nonlocal dtor_value
      assert(len(args) == 1)
      await task.suspend(dtor_fut)
      dtor_value = args[0]
    rt = ResourceType(producer_inst, dtor)

    [i] = await canon_resource_new(rt, task, 50)
    assert(i == 1)
    assert(dtor_value is None)
    [ret] = await canon_resource_drop(rt, False, task, 1)
    assert(ret == (1 | (AsyncCallState.STARTED << 30)))
    assert(task.num_async_subtasks == 1)
    assert(dtor_value is None)
    dtor_fut.set_result(None)
    event, callidx = await task.wait()
    assert(event == AsyncCallState.DONE)
    assert(callidx == 1)
    assert(task.num_async_subtasks == 0)

    [] = await canon_task_return(task, CoreFuncType(['i32'],[]), [42])
    return []

  ft = FuncType([Bool()],[U8()])

  def on_start():
    return [ True ]

  got = None
  def on_return(results):
    nonlocal got
    got = results

  consumer_inst = ComponentInstance()
  await canon_lift(consumer_opts, consumer_inst, consumer, ft, None, unlock_on_block, on_start, on_return)
  await current_task.acquire()
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
    await canon_task_start(task, CoreFuncType([],[]), [])
    await task.suspend(fut)
    await canon_task_return(task, CoreFuncType([],[]), [])
    return []
  fut1 = asyncio.Future()
  core_producer1 = partial(core_producer_pre, fut1)
  producer1 = partial(canon_lift, producer_opts, producer_inst, core_producer1, producer_ft)
  fut2 = asyncio.Future()
  core_producer2 = partial(core_producer_pre, fut2)
  producer2 = partial(canon_lift, producer_opts, producer_inst, core_producer2, producer_ft)

  consumer_ft = FuncType([],[U32()])
  async def consumer(task, args):
    assert(len(args) == 0)
    [] = await canon_task_start(task, CoreFuncType([],[]), [])

    [ret] = await canon_lower(opts, producer1, producer_ft, task, [0, 0])
    assert(ret == (1 | (AsyncCallState.STARTED << 30)))

    [ret] = await canon_lower(opts, producer2, producer_ft, task, [0, 0])
    assert(ret == (2 | (AsyncCallState.STARTED << 30)))

    fut1.set_result(None)
    return [42]

  async def callback(task, args):
    assert(len(args) == 3)
    if args[0] == 42:
      assert(args[1] == EventCode.CALL_DONE)
      assert(args[2] == 1)
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

  await canon_lift(opts, consumer_inst, consumer, consumer_ft, None, unlock_on_block, on_start, on_return)
  await current_task.acquire()
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
    await task.suspend(fut)
    producer1_done = True
    return []

  producer2_done = False
  async def producer2_core(task, args):
    nonlocal producer2_done
    assert(len(args) == 0)
    assert(producer1_done == True)
    producer2_done = True
    return []

  producer1 = partial(canon_lift, producer_opts, producer_inst, producer1_core, producer_ft)
  producer2 = partial(canon_lift, producer_opts, producer_inst, producer2_core, producer_ft)

  consumer_opts = mk_opts()
  consumer_opts.sync = False

  consumer_ft = FuncType([],[U8()])
  async def consumer(task, args):
    assert(len(args) == 0)

    [ret] = await canon_lower(consumer_opts, producer1, producer_ft, task, [0, 0])
    assert(ret == (1 | (AsyncCallState.STARTED << 30)))

    [ret] = await canon_lower(consumer_opts, producer2, producer_ft, task, [0, 0])
    assert(ret == (2 | (AsyncCallState.STARTING << 30)))

    assert(task.poll() is None)

    fut.set_result(None)
    assert(producer1_done == False)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 1)
    assert(producer1_done == True)

    assert(producer2_done == False)
    await canon_task_yield(task)
    assert(producer2_done == True)
    event, callidx = task.poll()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 2)
    assert(producer2_done == True)

    assert(task.poll() is None)

    await canon_task_start(task, CoreFuncType([],[]), [])
    await canon_task_return(task, CoreFuncType(['i32'],[]), [83])
    return []

  consumer_inst = ComponentInstance()
  def on_start(): return []

  got = None
  def on_return(results):
    nonlocal got
    got = results

  await canon_lift(consumer_opts, consumer_inst, consumer, consumer_ft, None, unlock_on_block, on_start, on_return)
  await current_task.acquire()
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
    await canon_task_start(task, CoreFuncType([],[]), [])
    await canon_task_return(task, CoreFuncType([],[]), [])
    await canon_task_backpressure(task, [1])
    await task.suspend(fut)
    await canon_task_backpressure(task, [0])
    producer1_done = True
    return []

  producer2_done = False
  async def producer2_core(task, args):
    nonlocal producer2_done
    assert(producer1_done == True)
    await canon_task_start(task, CoreFuncType([],[]), [])
    await canon_task_return(task, CoreFuncType([],[]), [])
    producer2_done = True
    return []

  producer1 = partial(canon_lift, producer_opts, producer_inst, producer1_core, producer_ft)
  producer2 = partial(canon_lift, producer_opts, producer_inst, producer2_core, producer_ft)

  consumer_opts = CanonicalOptions()
  consumer_opts.sync = False

  consumer_ft = FuncType([],[U8()])
  async def consumer(task, args):
    assert(len(args) == 0)

    [ret] = await canon_lower(consumer_opts, producer1, producer_ft, task, [0, 0])
    assert(ret == (1 | (AsyncCallState.RETURNED << 30)))

    [ret] = await canon_lower(consumer_opts, producer2, producer_ft, task, [0, 0])
    assert(ret == (2 | (AsyncCallState.STARTING << 30)))

    assert(task.poll() is None)

    fut.set_result(None)
    assert(producer1_done == False)
    assert(producer2_done == False)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 1)
    assert(producer1_done == True)
    assert(producer2_done == True)
    event, callidx = task.poll()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 2)
    assert(producer2_done == True)

    assert(task.poll() is None)

    await canon_task_start(task, CoreFuncType([],[]), [])
    await canon_task_return(task, CoreFuncType(['i32'],[]), [84])
    return []

  consumer_inst = ComponentInstance()
  def on_start(): return []

  got = None
  def on_return(results):
    nonlocal got
    got = results

  await canon_lift(consumer_opts, consumer_inst, consumer, consumer_ft, None, unlock_on_block, on_start, on_return)
  await current_task.acquire()
  assert(got[0] == 84)

asyncio.run(test_async_backpressure())

async def test_sync_using_wait():
  hostcall_opts = mk_opts()
  hostcall_opts.sync = False
  hostcall_inst = ComponentInstance()
  ft = FuncType([], [])

  async def core_hostcall_pre(fut, task, args):
    [] = await canon_task_start(task, CoreFuncType([],[]), [])
    await task.suspend(fut)
    [] = await canon_task_return(task, CoreFuncType([],[]), [])
    return []
  fut1 = asyncio.Future()
  core_hostcall1 = partial(core_hostcall_pre, fut1)
  hostcall1 = partial(canon_lift, hostcall_opts, hostcall_inst, core_hostcall1, ft)
  fut2 = asyncio.Future()
  core_hostcall2 = partial(core_hostcall_pre, fut2)
  hostcall2 = partial(canon_lift, hostcall_opts, hostcall_inst, core_hostcall2, ft)

  lower_opts = mk_opts()
  lower_opts.sync = False

  async def core_func(task, args):
    [ret] = await canon_lower(lower_opts, hostcall1, ft, task, [0,0])
    assert(ret == (1 | (AsyncCallState.STARTED << 30)))
    [ret] = await canon_lower(lower_opts, hostcall2, ft, task, [0,0])
    assert(ret == (2 | (AsyncCallState.STARTED << 30)))

    fut1.set_result(None)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 1)
    fut2.set_result(None)
    event, callidx = await task.wait()
    assert(event == EventCode.CALL_DONE)
    assert(callidx == 2)
    return []

  inst = ComponentInstance()
  def on_start(): return []
  def on_return(results): pass
  await canon_lift(mk_opts(), inst, core_func, ft, None, unlock_on_block, on_start, on_return)
  await current_task.acquire()

asyncio.run(test_sync_using_wait())

print("All tests passed")
