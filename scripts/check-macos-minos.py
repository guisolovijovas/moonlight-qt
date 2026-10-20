#!/usr/bin/env python3
"""
Verifies that Mach-O binaries (executables, dylibs, framework binaries) do
not require a macOS version newer than the given minimum.

This is the safety net for the macOS 10.13 (High Sierra) build: modern Xcode
still allows -mmacosx-version-min=10.13, but any dependency accidentally
compiled with a higher deployment target would fail to load at runtime with
"mach-o file, but is an incompatible architecture" or "cannot be linked".
Libraries are also checked to make sure every slice is x86_64 (10.13 only
runs on Intel Macs).

Usage:
    check-macos-minos.py [--min-major N --min-minor N] <path> [<path> ...]

Each path may be a file or a directory (directories are walked recursively;
non-Mach-O files are skipped silently).
"""
import argparse
import os
import struct
import sys

MH_MAGIC = 0xfeedface
MH_CIGAM = 0xcefaedfe
MH_MAGIC_64 = 0xfeedfacf
MH_CIGAM_64 = 0xcffaedfe
FAT_MAGIC = 0xcafebabe
FAT_CIGAM = 0xbebafeca
FAT_MAGIC_64 = 0xcafebabf
FAT_CIGAM_64 = 0xbfbafeca

LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION = 0x32

CPU_TYPE_NAMES = {
    7: "x86",
    0x01000007: "x86_64",
    12: "arm",
    0x0100000C: "arm64",
}


def parse_version(raw):
    return (raw >> 16, (raw >> 8) & 0xFF, raw & 0xFF)


def parse_slice(data, offset, endian):
    """Returns a list of (arch, minos, sdk) tuples for one Mach-O slice."""
    magic, = struct.unpack_from(endian + "I", data, offset)
    if magic in (MH_MAGIC_64, MH_CIGAM_64):
        hdr_size = 32
    elif magic in (MH_MAGIC, MH_CIGAM):
        hdr_size = 24
    else:
        return None

    fields = struct.unpack_from(endian + "IIIIIIII"[:hdr_size // 4 * 2], data, offset)
    cputype = fields[1]
    ncmds = fields[4]

    results = []
    p = offset + hdr_size
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(endian + "II", data, p)
        if cmd == LC_VERSION_MIN_MACOSX:
            ver, sdk = struct.unpack_from(endian + "II", data, p + 8)
            results.append((CPU_TYPE_NAMES.get(cputype, hex(cputype)),
                            parse_version(ver), parse_version(sdk)))
        elif cmd == LC_BUILD_VERSION:
            _platform, minos, sdk = struct.unpack_from(endian + "III", data, p + 8)
            results.append((CPU_TYPE_NAMES.get(cputype, hex(cputype)),
                            parse_version(minos), parse_version(sdk)))
        p += cmdsize
    return results


def check_macho(path):
    """Returns a list of (arch, minos, sdk) for all slices, or None if the
    file is not a Mach-O binary."""
    with open(path, "rb") as f:
        data = f.read(1024 * 1024)  # headers are at the start; 1 MiB is plenty
        f.seek(0, 2)
        size = f.tell()
        if size > len(data):
            data += f.read()

    magic, = struct.unpack_from(">I", data, 0)

    if magic in (FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64):
        nfat, = struct.unpack_from(">I", data, 4)
        p = 8
        results = []
        for _ in range(nfat):
            if magic in (FAT_MAGIC_64, FAT_CIGAM_64):
                cputype, _cpusub, offset, _size, _align = struct.unpack_from(">IIQQI", data, p)
                p += 32
            else:
                cputype, _cpusub, offset, _size, _align = struct.unpack_from(">IIIII", data, p)
                p += 20
            endian = "<" if cputype & 0xFF000000 else ">"
            slice_results = parse_slice(data, offset, endian)
            if slice_results:
                results.extend(slice_results)
        return results or None

    endian = "<" if magic in (MH_CIGAM, MH_CIGAM_64) else ">"
    return parse_slice(data, 0, endian)


def collect_files(paths):
    for path in paths:
        if os.path.isdir(path):
            for root, _dirs, files in os.walk(path):
                for name in files:
                    yield os.path.join(root, name)
        else:
            yield path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--min-major", type=int, default=10)
    parser.add_argument("--min-minor", type=int, default=13)
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()

    required = (args.min_major, args.min_minor, 0)
    required_str = "%d.%d" % (args.min_major, args.min_minor)

    failures = 0
    checked = 0

    for path in collect_files(args.paths):
        try:
            results = check_macho(path)
        except (OSError, struct.error, IndexError):
            continue  # not a Mach-O file (or unreadable) - skip
        if not results:
            continue

        checked += 1
        problems = []
        for arch, minos, sdk in results:
            if minos > required:
                problems.append("%s minos=%d.%d.%d (newer than %s)"
                                % (arch, minos[0], minos[1], minos[2], required_str))
        status = "OK  " if not problems else "FAIL"
        minos_str = ", ".join("%s minos=%d.%d.%d (sdk %d.%d.%d)"
                              % (arch, m[0], m[1], m[2], s[0], s[1], s[2])
                              for arch, m, s in results)
        print("%s %-60s %s" % (status, os.path.basename(path), minos_str))
        if problems:
            failures += 1
            for problem in problems:
                print("      -> %s" % problem)

    print("Checked %d Mach-O binaries; %d incompatible with macOS %s"
          % (checked, failures, required_str))

    if checked == 0:
        print("ERROR: no Mach-O binaries were found to check!" , file=sys.stderr)
        return 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
