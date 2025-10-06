import re
import sys
from pathlib import Path

def extract_code_from_definitions(file_path):
    with open(file_path, 'r') as f:
        content = f.read()

    start_pos = content.find("# START")
    if start_pos == -1:
        print("Error: Could not find '# START' comment in definitions.py")
        sys.exit(1)

    code_after_start = content[start_pos:].split('\n', 1)[1].strip()
    return code_after_start.split('\n')

def extract_code_blocks_from_md(file_path):
    with open(file_path, 'r') as f:
        content = f.read()

    code_blocks_text = re.findall(r'```python\n(.*?)```', content, re.DOTALL)
    return [block.split('\n') for block in code_blocks_text]

def normalize_line(line):
    return line.strip()

def is_comment_or_empty(line):
    normalized = normalize_line(line)
    return normalized == '' or normalized.startswith('#')

def is_canon_thread_function(line):
    normalized = normalize_line(line)
    return (normalized.startswith('def canon_thread_spawn') or
            normalized.startswith('def canon_thread_available_parallelism'))

def filter_canon_thread_functions(code_blocks):
    filtered_blocks = []

    for block in code_blocks:
        filtered_block = []
        i = 0

        while i < len(block):
            if is_canon_thread_function(block[i]):
                i += 1
                while i < len(block) and (not block[i].strip() or block[i].startswith(' ') or block[i].startswith('\t')):
                    i += 1
            else:
                filtered_block.append(block[i])
                i += 1

        if filtered_block:
            filtered_blocks.append(filtered_block)

    return filtered_blocks

def find_spurious_newlines_in_definitions(def_lines, md_lines):
    empty_lines = []
    for i, line in enumerate(def_lines):
        if is_comment_or_empty(line):
            empty_lines.append(i)

    spurious_lines = []
    for i in empty_lines:
        prev_line = def_lines[i-1] if i > 0 else ""
        next_line = def_lines[i+1] if i+1 < len(def_lines) else ""

        if not is_comment_or_empty(prev_line) and not is_comment_or_empty(next_line):
            prev_normalized = normalize_line(prev_line)
            next_normalized = normalize_line(next_line)

            prev_indices = [j for j, line in enumerate(md_lines) if normalize_line(line) == prev_normalized]
            next_indices = [j for j, line in enumerate(md_lines) if normalize_line(line) == next_normalized]

            for prev_idx in prev_indices:
                for next_idx in next_indices:
                    if next_idx == prev_idx + 1:
                        spurious_lines.append(i)
                        break
                if i in spurious_lines:
                    break

    return spurious_lines

def find_spurious_newlines_in_md(def_lines, md_blocks):
    spurious_lines = []

    for block_idx, block in enumerate(md_blocks):
        for line_idx, line in enumerate(block):
            if is_comment_or_empty(line):
                prev_line = block[line_idx-1] if line_idx > 0 else ""
                next_line = block[line_idx+1] if line_idx+1 < len(block) else ""

                if not is_comment_or_empty(prev_line) and not is_comment_or_empty(next_line):
                    prev_normalized = normalize_line(prev_line)
                    next_normalized = normalize_line(next_line)

                    prev_in_def = False
                    next_in_def = False
                    adjacent_in_def = False

                    for i in range(len(def_lines) - 1):
                        if normalize_line(def_lines[i]) == prev_normalized and normalize_line(def_lines[i+1]) == next_normalized:
                            adjacent_in_def = True
                            break

                    if adjacent_in_def:
                        spurious_lines.append((block_idx, line_idx))

    return spurious_lines

def check_content_differences(def_lines, md_lines):
    def_content = [(i, normalize_line(line)) for i, line in enumerate(def_lines) if not is_comment_or_empty(line)]
    md_content = [(i, normalize_line(line)) for i, line in enumerate(md_lines) if not is_comment_or_empty(line)]

    differences = []
    i, j = 0, 0

    while i < len(def_content) and j < len(md_content):
        def_idx, def_line = def_content[i]
        md_idx, md_line = md_content[j]

        if def_line != md_line:
            found_match = False
            for k in range(i+1, min(i+10, len(def_content))):
                if def_content[k][1] == md_line:
                    for l in range(i, k):
                        differences.append((def_content[l][0], def_content[l][1], md_idx, md_line))
                    i = k
                    found_match = True
                    break

            if not found_match:
                for k in range(j+1, min(j+10, len(md_content))):
                    if md_content[k][1] == def_line:
                        for l in range(j, k):
                            differences.append((def_idx, def_line, md_content[l][0], md_content[l][1]))
                        j = k
                        found_match = True
                        break

            if not found_match:
                differences.append((def_idx, def_line, md_idx, md_line))
                i += 1
                j += 1
        else:
            i += 1
            j += 1

    while i < len(def_content):
        def_idx, def_line = def_content[i]
        differences.append((def_idx, def_line, None, None))
        i += 1

    while j < len(md_content):
        md_idx, md_line = md_content[j]
        differences.append((None, None, md_idx, md_line))
        j += 1

    return differences

def main():
    script_dir = Path(__file__).parent.absolute()
    definitions_path = script_dir / 'definitions.py'
    canonical_abi_path = script_dir.parent / 'CanonicalABI.md'

    try:
        def_lines = extract_code_from_definitions(definitions_path)
        md_blocks = extract_code_blocks_from_md(canonical_abi_path)
        filtered_blocks = filter_canon_thread_functions(md_blocks)
        md_lines = []
        for block in filtered_blocks:
            md_lines.extend(block)

        spurious_in_def = find_spurious_newlines_in_definitions(def_lines, md_lines)
        spurious_in_md = find_spurious_newlines_in_md(def_lines, filtered_blocks)
        content_differences = check_content_differences(def_lines, md_lines)

        has_errors = False
        if spurious_in_def:
            has_errors = True
            print(f"\nFound {len(spurious_in_def)} spurious newline(s) in definitions.py:")
            for i in spurious_in_def:
                print(f"  Line {i+1}")
                start = max(0, i - 2)
                end = min(len(def_lines), i + 3)
                print("\n  Context:")
                for j in range(start, end):
                    prefix = ">" if j == i else " "
                    print(f"  {prefix} {j+1}: '{def_lines[j]}'")

        if spurious_in_md:
            has_errors = True
            print(f"\nFound {len(spurious_in_md)} spurious newline(s) in CanonicalABI.md code blocks:")
            for block_idx, line_idx in spurious_in_md:
                block = filtered_blocks[block_idx]
                print(f"  Block {block_idx+1}, Line {line_idx+1}")
                start = max(0, line_idx - 2)
                end = min(len(block), line_idx + 3)
                print("\n  Context:")
                for j in range(start, end):
                    prefix = ">" if j == line_idx else " "
                    print(f"  {prefix} Line {j+1}: '{block[j]}'")

        if content_differences:
            has_errors = True
            print(f"\nFound {len(content_differences)} content difference(s) between the files:")
            for def_idx, def_line, md_idx, md_line in content_differences:
                if def_idx is not None and md_idx is not None:
                    print(f"\n  Difference at definitions.py line {def_idx+1} and CanonicalABI.md line {md_idx+1}:")
                    print(f"    definitions.py: '{def_line}'")
                    print(f"    CanonicalABI.md: '{md_line}'")
                elif def_idx is not None:
                    print(f"\n  Extra line in definitions.py at line {def_idx+1}:")
                    print(f"    '{def_line}'")
                else:
                    print(f"\n  Extra line in CanonicalABI.md at line {md_idx+1}:")
                    print(f"    '{md_line}'")

        if has_errors:
            print("\nError: Differences found between definitions.py and CanonicalABI.md.")
            sys.exit(1)
    except Exception as e:
        print(f"\nError: {str(e)}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()
