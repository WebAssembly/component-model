#!/usr/bin/env python3
# Checks that the ```python code blocks in ../CanonicalABI.md mirror the part
# of definitions.py after the '# START' line and prints any differences as a
# diff, with every line labeled with its line number in each file.
#
# Concatenated in order, the code blocks must match definitions.py where:
#  * code lines must match exactly, including indentation (only trailing
#    whitespace is ignored);
#  * blank lines *within* a code block must match exactly;
#  * at the boundary between two code blocks, anything goes: definitions.py may
#    have any number of blank lines and '#' section comments (or nothing, if
#    the .md interrupts a definition with prose) and code blocks may start or
#    end with any number of blank lines;
#  * '#' comments starting in column 0 of definitions.py are section markers
#    that are not shown in CanonicalABI.md and so may only appear at code
#    block boundaries. (Indented comments are compared like code.)
#
# Exits with 0 if the files match, 1 if they differ and 2 on error.

import difflib
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# Top-level functions shown in CanonicalABI.md that have no counterpart in
# definitions.py because they depend on 🧵② shared-everything-threads features
# that definitions.py does not yet model.
MD_ONLY_FUNCTIONS = {
  'canon_thread_spawn_ref',
  'canon_thread_spawn_indirect',
  'canon_thread_available_parallelism',
}

CONTEXT = 3

@dataclass
class Line:
  num: int   # 1-based line number in the file
  text: str  # trailing whitespace removed
  block: int = 0  # CanonicalABI.md only: which code block contains this line
  gap: list = field(default_factory = list)  # non-code lines since the previous code line

def fail(msg):
  print(f'error: {msg}', file = sys.stderr)
  sys.exit(2)

def read_definitions(path):
  lines = path.read_text().splitlines()
  for i, text in enumerate(lines):
    if text.startswith('# START'):
      return [Line(num, line.rstrip()) for num, line in enumerate(lines[i+1:], start = i+2)]
  fail(f"{path}: no '# START' line")

OPEN_FENCE = re.compile(r'( *)(`{3,})([^`]*)$')
CLOSE_FENCE = re.compile(r' *(`{3,})\s*$')

def read_python_blocks(path):
  lines = path.read_text().splitlines()
  blocks = []
  i = 0
  while i < len(lines):
    m = OPEN_FENCE.match(lines[i])
    i += 1
    if not m:
      continue
    start, indent, fence, info = i, len(m[1]), m[2], m[3].split()
    body = []
    while True:
      if i == len(lines):
        fail(f'{path}:{start}: unterminated code block')
      close = CLOSE_FENCE.match(lines[i])
      if close and len(close[1]) >= len(fence):
        break
      text = lines[i]
      text = text[min(indent, len(text) - len(text.lstrip(' '))):]
      body.append(Line(i+1, text.rstrip()))
      i += 1
    i += 1
    if info and info[0] == 'python':
      blocks.append(body)
  return blocks

# Removes MD_ONLY_FUNCTIONS from 'blocks', splitting a block in two if a
# function is removed from its middle.
def remove_md_only_functions(blocks, path):
  found = set()
  pieces = []
  for block in blocks:
    piece = []
    skipping = False
    for line in block:
      if line.text and not line.text[0].isspace():
        m = re.match(r'(?:async\s+)?def\s+(\w+)', line.text)
        skipping = bool(m) and m[1] in MD_ONLY_FUNCTIONS
        if skipping:
          found.add(m[1])
          pieces.append(piece)
          piece = []
      if not skipping:
        piece.append(line)
    pieces.append(piece)
  for name in sorted(MD_ONLY_FUNCTIONS - found):
    fail(f"{path}: MD_ONLY_FUNCTIONS contains '{name}' but no code block defines it")
  return pieces

# Returns the code lines of 'lines', setting each one's 'gap' to the non-code
# lines between it and the preceding code line.
def code_lines(lines, is_code):
  code = []
  gap = []
  for line in lines:
    if is_code(line):
      line.gap = gap
      gap = []
      code.append(line)
    else:
      gap.append(line)
  return code

# Rows of the diff are (tag, def_line, md_line) where tag is ' ' for lines that
# match, '-' for lines only in definitions.py, '+' for lines only in
# CanonicalABI.md and '~' for a code block boundary (shown as context only).
def diff_rows(def_code, md_code):
  rows = []
  matcher = difflib.SequenceMatcher(None, [l.text for l in def_code],
                                          [l.text for l in md_code], autojunk = False)
  for op, i1, i2, j1, j2 in matcher.get_opcodes():
    if op != 'equal':
      rows += [('-', d, None) for d in def_code[i1:i2]]
      rows += [('+', None, m) for m in md_code[j1:j2]]
      continue
    for k, (d, m) in enumerate(zip(def_code[i1:i2], md_code[j1:j2])):
      if k > 0 and m.block == md_code[j1+k-1].block:
        rows += gap_rows(d.gap, m.gap)
      rows.append((' ', d, m))
  return add_block_boundaries(rows)

# Within a code block, the lines between two code lines are all blank and
# definitions.py must have exactly the same lines in between.
def gap_rows(def_gap, md_gap):
  rows = []
  matcher = difflib.SequenceMatcher(None, [l.text for l in def_gap],
                                          [l.text for l in md_gap], autojunk = False)
  for op, i1, i2, j1, j2 in matcher.get_opcodes():
    if op == 'equal':
      rows += [(' ', d, m) for d, m in zip(def_gap[i1:i2], md_gap[j1:j2])]
    else:
      rows += [('-', d, None) for d in def_gap[i1:i2]]
      rows += [('+', None, m) for m in md_gap[j1:j2]]
  return rows

def add_block_boundaries(rows):
  result = []
  block = None
  for row in rows:
    m = row[2]
    if m:
      if block is not None and m.block != block:
        result.append(('~', None, None))
      block = m.block
    result.append(row)
  return result

# Groups the changed rows, along with up to CONTEXT matching rows on either
# side, into a list of hunks (lists of rows).
def hunks(rows):
  shown = [False] * len(rows)
  for i, (tag, _, _) in enumerate(rows):
    if tag in '-+':
      shown[i] = True
      for step in (-1, 1):
        j, context = i + step, 0
        while 0 <= j < len(rows) and rows[j][0] not in '-+' and context < CONTEXT:
          shown[j] = True
          context += rows[j][0] == ' '
          j += step
  result = []
  for i, row in enumerate(rows):
    if shown[i]:
      if i == 0 or not shown[i-1]:
        result.append([])
      result[-1].append(row)
  return result

# The line in each file that a hunk header should point at: the first changed
# line in that file or, if there is none, the line just before the change.
def hunk_location(hunk, side, name):
  changed = [row[side] for row in hunk if row[0] in '-+' and row[side]]
  if changed:
    return f'{name}:{changed[0].num}'
  first_change = next(i for i, row in enumerate(hunk) if row[0] in '-+')
  before = [row[side] for row in hunk[:first_change] if row[side]]
  after = [row[side] for row in hunk[first_change:] if row[side]]
  return f'{name}:{(before[-1] if before else after[0]).num}' if before or after else name

def main():
  script_dir = Path(__file__).resolve().parent
  def_path = Path(os.path.relpath(script_dir / 'definitions.py'))
  md_path = Path(os.path.relpath(script_dir.parent / 'CanonicalABI.md'))

  def_lines = read_definitions(def_path)
  md_lines = []
  for block_index, block in enumerate(remove_md_only_functions(read_python_blocks(md_path), md_path)):
    for line in block:
      line.block = block_index
      md_lines.append(line)

  def_code = code_lines(def_lines, lambda l: l.text != '' and not l.text.startswith('#'))
  md_code = code_lines(md_lines, lambda l: l.text != '')
  diff = hunks(diff_rows(def_code, md_code))
  if not diff:
    print(f'{def_path} and {md_path} match')
    return

  width = len(str(max(line.num for hunk in diff for row in hunk for line in row[1:] if line)))
  print(f'--- {def_path}')
  print(f'+++ {md_path}')
  for hunk in diff:
    print(f'@@ {hunk_location(hunk, 1, def_path)} {hunk_location(hunk, 2, md_path)} @@')
    for tag, d, m in hunk:
      if tag == '~':
        print(f'{"":{2 * width + 3}} | ```')
        continue
      text = (d or m).text
      if tag != ' ' and text == '':
        text = '<blank line>'
      dnum = d.num if d else ''
      mnum = m.num if m else ''
      print(f'{tag} {dnum:>{width}} {mnum:>{width}} | {text}')
  print(f'\nFound {len(diff)} difference(s) between {def_path} and {md_path}.')
  sys.exit(1)

if __name__ == '__main__':
  main()
