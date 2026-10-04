#!/usr/bin/env python3
"""Patch gem5 v25 to support --cond-bp-type for conditional branch predictor sweeps.

gem5 v25 refactored BranchPredictor into a composite SimObject.
--bp-type only finds BranchPredictor subclasses (just GshareBP).
Real predictors (LocalBP, TournamentBP, BiModeBP, TAGE, LTAGE, ...)
are ConditionalPredictor subclasses, set via cpu.branchPred.conditionalBranchPred.

This patch adds --cond-bp-type to Options.py and applies it wherever
--indirect-bp-type is applied (both initial CPU and switch-CPU paths).

Usage:
    python3 kernel/patch_gem5_cond_bp.py                  # default ~/gem5
    python3 kernel/patch_gem5_cond_bp.py --gem5 /opt/gem5  # custom path
    python3 kernel/patch_gem5_cond_bp.py --dry-run         # show what would change
    python3 kernel/patch_gem5_cond_bp.py --revert          # restore .bak files

After patching, verify:
    ~/gem5/build/X86/gem5.opt configs/deprecated/example/se.py --help | grep cond
"""

import argparse
import glob
import os
import re
import shutil
import sys


def backup(path):
    bak = path + ".bak"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
        print("  backed up -> %s" % bak)


def patch_options(opts_path, dry_run):
    text = open(opts_path).read()
    if "cond-bp-type" in text or "cond_bp_type" in text:
        print("  %s: already patched" % opts_path)
        return

    marker = "type of indirect branch predictor to run with"
    if marker not in text:
        print("  WARNING: marker not found in %s, skipping" % opts_path)
        return

    pos = text.index(marker)
    start = text.rindex("parser.add_argument", 0, pos)
    depth = 0
    end = start
    for i in range(start, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    eol = text.index("\n", end)

    new_block = '\n'.join([
        '',
        '    parser.add_argument(',
        '        "--cond-bp-type",',
        '        default=None,',
        '        help="type of conditional branch predictor to run with"',
        '             " (e.g. LocalBP, TournamentBP, BiModeBP, TAGE, LTAGE)",',
        '    )',
    ])

    if dry_run:
        lineno = text[:eol].count("\n") + 1
        print("  %s: would add --cond-bp-type after line %d" % (opts_path, lineno))
    else:
        backup(opts_path)
        new_text = text[:eol] + new_block + text[eol:]
        open(opts_path, "w").write(new_text)
        print("  %s: patched (added --cond-bp-type)" % opts_path)


def patch_bp_application(path, dry_run):
    text = open(path).read()
    if "cond_bp_type" in text:
        print("  %s: already patched" % path)
        return
    if "indirect_bp_type" not in text or "indirectBranchPred" not in text:
        return

    lines = text.split("\n")
    result = []
    i = 0
    patched = 0

    while i < len(lines):
        result.append(lines[i])

        m = re.match(r"^(\s+)if\s+(\w+)\.indirect_bp_type\s*:", lines[i])
        if not m:
            m = re.match(r"^(\s+)if\s+getattr\(\s*(\w+)\s*,\s*['\"]indirect_bp_type", lines[i])
        if not m:
            i += 1
            continue

        indent = m.group(1)
        var = m.group(2)
        body_indent = indent + "    "

        target = "system.cpu[i]"
        scan_end = min(i + 12, len(lines))
        for j in range(i + 1, scan_end):
            if "switch_cpus" in lines[j] and "branchPred" in lines[j]:
                target = "switch_cpus[i]"
                break
            if "switch_cpus[i]" in lines[j]:
                target = "switch_cpus[i]"
                break

        i += 1
        while i < len(lines):
            line = lines[i]
            if not line.strip():
                result.append(line)
                i += 1
                continue
            line_indent = len(line) - len(line.lstrip())
            if line_indent > len(indent):
                result.append(line)
                i += 1
                continue
            break

        cond_block = [
            "%sif getattr(%s, 'cond_bp_type', None):" % (indent, var),
            "%simport m5.objects" % body_indent,
            "%s_cbp = getattr(m5.objects, %s.cond_bp_type, None)" % (body_indent, var),
            "%sif _cbp is None:" % body_indent,
            '%s    fatal("Unknown --cond-bp-type: %%s" %% %s.cond_bp_type)' % (body_indent, var),
            "%s%s.branchPred.conditionalBranchPred = _cbp()" % (body_indent, target),
        ]
        result.extend(cond_block)
        patched += 1

    if patched == 0:
        print("  %s: WARNING: found indirect_bp_type but no patchable if-blocks" % path)
        return

    if dry_run:
        print("  %s: would insert %d cond_bp_type block(s)" % (path, patched))
    else:
        backup(path)
        open(path, "w").write("\n".join(result))
        print("  %s: patched (%d block(s))" % (path, patched))


def revert(gem5_dir):
    count = 0
    for bak in glob.glob(os.path.join(gem5_dir, "configs", "**", "*.bak"), recursive=True):
        orig = bak[:-4]
        shutil.copy2(bak, orig)
        os.remove(bak)
        print("  restored %s" % orig)
        count += 1
    if count == 0:
        print("  no .bak files found")
    else:
        print("Reverted %d file(s)" % count)


def list_available_types():
    print("\nAvailable ConditionalPredictor types (gem5 v25.1):")
    types = [
        "LocalBP", "TournamentBP", "BiModeBP",
        "TAGE", "LTAGE",
        "TAGE_SC_L", "TAGE_SC_L_64KB", "TAGE_SC_L_8KB",
        "MultiperspectivePerceptron", "MultiperspectivePerceptron8KB",
        "MultiperspectivePerceptron64KB",
        "MultiperspectivePerceptronTAGE", "MultiperspectivePerceptronTAGE8KB",
        "MultiperspectivePerceptronTAGE64KB",
    ]
    for t in types:
        print("  " + t)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gem5", default=os.path.expanduser("~/gem5"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--revert", action="store_true")
    args = ap.parse_args()

    if args.revert:
        revert(args.gem5)
        return

    configs = os.path.join(args.gem5, "configs")
    if not os.path.isdir(configs):
        sys.exit("gem5 configs directory not found: %s" % configs)

    print("Patching gem5 at %s" % args.gem5)

    opts = os.path.join(configs, "common", "Options.py")
    if os.path.exists(opts):
        patch_options(opts, args.dry_run)
    else:
        print("  WARNING: %s not found" % opts)

    for root, dirs, files in os.walk(configs):
        for f in files:
            if not f.endswith(".py"):
                continue
            path = os.path.join(root, f)
            try:
                text = open(path).read(8192)
            except Exception:
                continue
            if "indirect_bp_type" in text and "indirectBranchPred" in text:
                patch_bp_application(path, args.dry_run)

    list_available_types()
    print("\nVerify:")
    print("  %s/build/X86/gem5.opt \\" % args.gem5)
    print("    %s/deprecated/example/se.py --help | grep -i cond" % configs)


if __name__ == "__main__":
    main()
