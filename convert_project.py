#!/usr/bin/env python3
"""
Convert Xcode 16 project (objectVersion 77, PBXFileSystemSynchronizedRootGroup)
to Xcode 15 format (objectVersion 56, explicit PBXFileReference + PBXGroup).
"""

import os
import re
import hashlib
import sys

PROJECT_ROOT = "/Users/samhv/workspace/FineTune"
PBXPROJ = os.path.join(PROJECT_ROOT, "FineTune.xcodeproj", "project.pbxproj")

# ---------------------------------------------------------------------------
# Plist quoting: values with non-alphanumeric chars (except . and _) need quotes
# ---------------------------------------------------------------------------
_SAFE_PLIST_RE = re.compile(r'^[A-Za-z0-9._]+$')

def plist_quote(value: str) -> str:
    """Quote a plist value if it contains special characters."""
    if _SAFE_PLIST_RE.match(value):
        return value
    return f'"{value}"'


# ---------------------------------------------------------------------------
# ID generation: deterministic 24-char hex IDs based on path
# ---------------------------------------------------------------------------
def make_id(seed: str) -> str:
    """Generate a deterministic 24-char uppercase hex ID from a seed string."""
    h = hashlib.md5(seed.encode()).hexdigest()[:24].upper()
    return h

# Track generated IDs to avoid collisions
_used_ids: set[str] = set()

def unique_id(seed: str) -> str:
    """Generate a unique 24-char hex ID, appending a counter if needed."""
    base = make_id(seed)
    candidate = base
    i = 0
    while candidate in _used_ids:
        i += 1
        candidate = make_id(seed + f"__{i}")
    _used_ids.add(candidate)
    return candidate


# ---------------------------------------------------------------------------
# Collect existing IDs from the project file so we don't collide
# ---------------------------------------------------------------------------
def collect_existing_ids(content: str):
    """Find all 24-char hex IDs already in the pbxproj and reserve them."""
    for m in re.finditer(r'\b([0-9A-F]{24})\b', content):
        _used_ids.add(m.group(1))
    for m in re.finditer(r'\b([0-9A-Fa-f]{24})\b', content):
        _used_ids.add(m.group(1).upper())


# ---------------------------------------------------------------------------
# File type mapping for PBXFileReference
# ---------------------------------------------------------------------------
FILE_TYPE_MAP = {
    '.swift': 'sourcecode.swift',
    '.h': 'sourcecode.c.h',
    '.m': 'sourcecode.c.objc',
    '.mm': 'sourcecode.cpp.objcpp',
    '.c': 'sourcecode.c.c',
    '.cpp': 'sourcecode.cpp.cpp',
    '.xib': 'file.xib',
    '.storyboard': 'file.storyboard',
    '.plist': 'text.plist.xml',
    '.entitlements': 'text.plist.entitlements',
    '.xcassets': 'folder.assetcatalog',
    '.xcstrings': 'text.json.xcstrings',
    '.json': 'text.json',
    '.png': 'image.png',
    '.jpg': 'image.jpeg',
    '.jpeg': 'image.jpeg',
    '.pdf': 'image.pdf',
    '.strings': 'text.plist.strings',
    '.stringsdict': 'text.plist.stringsdict',
    '.metal': 'sourcecode.metal',
    '.md': 'net.daringfireball.markdown',
    '.txt': 'text',
    '.rtf': 'text.rtf',
}

def file_type_for(path: str) -> str:
    """Return the lastKnownFileType for a file extension."""
    _, ext = os.path.splitext(path)
    return FILE_TYPE_MAP.get(ext.lower(), 'file')


# ---------------------------------------------------------------------------
# Resource extensions (go to Resources build phase, NOT Sources)
# ---------------------------------------------------------------------------
RESOURCE_EXTENSIONS = {
    '.xcassets', '.xcstrings', '.json', '.plist', '.entitlements',
    '.png', '.jpg', '.jpeg', '.pdf', '.strings', '.stringsdict',
    '.storyboard', '.xib', '.metal',
}

SOURCE_EXTENSIONS = {'.swift', '.m', '.mm', '.c', '.cpp'}

def is_source(path: str) -> bool:
    _, ext = os.path.splitext(path)
    return ext.lower() in SOURCE_EXTENSIONS

def is_resource(path: str) -> bool:
    _, ext = os.path.splitext(path)
    return ext.lower() in RESOURCE_EXTENSIONS


# ---------------------------------------------------------------------------
# Scan filesystem and build group tree
# ---------------------------------------------------------------------------
class FileNode:
    """Represents a file in the project."""
    def __init__(self, name: str, abs_path: str, rel_path: str, file_ref_id: str, build_file_id: str):
        self.name = name
        self.abs_path = abs_path
        self.rel_path = rel_path  # relative to target root
        self.file_ref_id = file_ref_id
        self.build_file_id = build_file_id


class GroupNode:
    """Represents a PBXGroup in the project."""
    def __init__(self, name: str, group_id: str, path: str = None):
        self.name = name
        self.group_id = group_id
        self.path = path  # filesystem path component (just the dir name)
        self.children_groups: list['GroupNode'] = []
        self.children_files: list[FileNode] = []


def scan_target_dir(target_name: str, target_dir: str) -> tuple[GroupNode, list[FileNode], list[FileNode]]:
    """
    Scan a target directory recursively.
    Returns (root_group, source_files, resource_files).
    """
    source_files = []
    resource_files = []

    def scan_dir(dir_path: str, parent_rel: str) -> GroupNode:
        dir_name = os.path.basename(dir_path)
        group_id = unique_id(f"group_{target_name}_{parent_rel}")
        group = GroupNode(dir_name, group_id, path=dir_name)

        entries = sorted(os.listdir(dir_path))

        for entry in entries:
            full_path = os.path.join(dir_path, entry)
            rel_path = os.path.join(parent_rel, entry) if parent_rel else entry

            if os.path.isdir(full_path):
                # xcassets are treated as a single file reference (folder type)
                if entry.endswith('.xcassets'):
                    fref_id = unique_id(f"fileref_{target_name}_{rel_path}")
                    bf_id = unique_id(f"buildfile_{target_name}_{rel_path}")
                    node = FileNode(entry, full_path, rel_path, fref_id, bf_id)
                    group.children_files.append(node)
                    resource_files.append(node)
                else:
                    child_group = scan_dir(full_path, rel_path)
                    if child_group.children_files or child_group.children_groups:
                        group.children_groups.append(child_group)
            else:
                _, ext = os.path.splitext(entry)
                ext_lower = ext.lower()

                # Skip .DS_Store and hidden files
                if entry.startswith('.'):
                    continue

                # For Info.plist and entitlements in the main target:
                # they are referenced but typically NOT added to build phases
                # (Xcode references them via build settings like INFOPLIST_FILE)
                skip_build_phase = False
                if entry == 'Info.plist' or entry.endswith('.entitlements'):
                    skip_build_phase = True

                fref_id = unique_id(f"fileref_{target_name}_{rel_path}")
                bf_id = unique_id(f"buildfile_{target_name}_{rel_path}")
                node = FileNode(entry, full_path, rel_path, fref_id, bf_id)
                group.children_files.append(node)

                if not skip_build_phase:
                    if is_source(entry):
                        source_files.append(node)
                    elif is_resource(entry):
                        resource_files.append(node)

        return group

    root = scan_dir(target_dir, "")
    return root, source_files, resource_files


# ---------------------------------------------------------------------------
# Generate PBXFileReference lines (with proper quoting)
# ---------------------------------------------------------------------------
def generate_file_references(group: GroupNode) -> list[str]:
    """Generate PBXFileReference lines for all files in a group tree."""
    refs = []

    for f in group.children_files:
        ftype = file_type_for(f.name)
        quoted_path = plist_quote(f.name)
        refs.append(
            f'\t\t{f.file_ref_id} /* {f.name} */ = '
            f'{{isa = PBXFileReference; lastKnownFileType = {ftype}; '
            f'path = {quoted_path}; sourceTree = "<group>"; }};'
        )

    for child in group.children_groups:
        refs.extend(generate_file_references(child))

    return refs


# ---------------------------------------------------------------------------
# Generate PBXGroup entries (with proper quoting)
# ---------------------------------------------------------------------------
def generate_group_entries(group: GroupNode) -> list[str]:
    """Generate PBXGroup section entries for a group tree."""
    entries = []

    # Build children list
    children_lines = []
    for cg in sorted(group.children_groups, key=lambda g: g.name):
        children_lines.append(f'\t\t\t\t{cg.group_id} /* {cg.name} */,')
    for cf in sorted(group.children_files, key=lambda f: f.name):
        children_lines.append(f'\t\t\t\t{cf.file_ref_id} /* {cf.name} */,')

    children_str = '\n'.join(children_lines)
    quoted_path = plist_quote(group.path) if group.path else group.name

    entry = (
        f'\t\t{group.group_id} /* {group.name} */ = {{\n'
        f'\t\t\tisa = PBXGroup;\n'
        f'\t\t\tchildren = (\n'
        f'{children_str}\n'
        f'\t\t\t);\n'
        f'\t\t\tpath = {quoted_path};\n'
        f'\t\t\tsourceTree = "<group>";\n'
        f'\t\t}};'
    )
    entries.append(entry)

    for child in group.children_groups:
        entries.extend(generate_group_entries(child))

    return entries


# ---------------------------------------------------------------------------
# Generate PBXBuildFile lines
# ---------------------------------------------------------------------------
def generate_build_file_lines(files: list[FileNode], phase_name: str) -> list[str]:
    """Generate PBXBuildFile lines for source or resource files."""
    lines = []
    for f in files:
        lines.append(
            f'\t\t{f.build_file_id} /* {f.name} in {phase_name} */ = '
            f'{{isa = PBXBuildFile; fileRef = {f.file_ref_id} /* {f.name} */; }};'
        )
    return lines


# ---------------------------------------------------------------------------
# Fix existing unquoted paths in the original file content
# ---------------------------------------------------------------------------
def fix_existing_unquoted_paths(content: str) -> str:
    """Quote any existing path = values that contain special characters."""
    def quote_path_match(m):
        key = m.group(1)  # 'path' or 'name'
        value = m.group(2).strip()
        if _SAFE_PLIST_RE.match(value):
            return m.group(0)
        return f'{key} = "{value}";'

    # Fix: path = something+special; -> path = "something+special";
    content = re.sub(
        r'(path|name) = ([^";\n]+);',
        quote_path_match,
        content
    )
    return content


# ---------------------------------------------------------------------------
# Main conversion
# ---------------------------------------------------------------------------
def convert():
    with open(PBXPROJ, 'r') as fh:
        content = fh.read()

    # Collect existing IDs
    collect_existing_ids(content)

    # Scan all three target directories
    targets_info = {}

    for target_name, target_dir in [
        ("FineTune", os.path.join(PROJECT_ROOT, "FineTune")),
        ("FineTuneTests", os.path.join(PROJECT_ROOT, "FineTuneTests")),
        ("FineTuneUITests", os.path.join(PROJECT_ROOT, "FineTuneUITests")),
    ]:
        if os.path.isdir(target_dir) and os.listdir(target_dir):
            root_group, sources, resources = scan_target_dir(target_name, target_dir)
            targets_info[target_name] = {
                'root_group': root_group,
                'sources': sources,
                'resources': resources,
            }
        else:
            # Empty target dir (like FineTuneUITests) -- create empty group
            gid = unique_id(f"group_{target_name}_root")
            root_group = GroupNode(target_name, gid, path=target_name)
            targets_info[target_name] = {
                'root_group': root_group,
                'sources': [],
                'resources': [],
            }

    # --- 1. Change objectVersion from 77 to 56 ---
    content = content.replace('objectVersion = 77;', 'objectVersion = 56;')

    # --- 2. Remove preferredProjectObjectVersion = 77 ---
    content = re.sub(r'\s*preferredProjectObjectVersion = \d+;\n', '\n', content)

    # --- 3. Remove PBXFileSystemSynchronizedRootGroup section entirely ---
    content = re.sub(
        r'/\* Begin PBXFileSystemSynchronizedRootGroup section \*/\n.*?/\* End PBXFileSystemSynchronizedRootGroup section \*/\n',
        '',
        content,
        flags=re.DOTALL
    )

    # --- 4. Remove fileSystemSynchronizedGroups from all targets ---
    content = re.sub(
        r'\s*fileSystemSynchronizedGroups = \(\n\s*[0-9A-Fa-f]+ /\*.*?\*/,\n\s*\);\n',
        '\n',
        content,
    )

    # --- 5. Add new PBXFileReference entries ---
    new_file_refs = []
    for tname in ["FineTune", "FineTuneTests", "FineTuneUITests"]:
        info = targets_info[tname]
        new_file_refs.extend(generate_file_references(info['root_group']))

    # Insert before /* End PBXFileReference section */
    file_ref_insertion = '\n'.join(new_file_refs)
    content = content.replace(
        '/* End PBXFileReference section */',
        file_ref_insertion + '\n/* End PBXFileReference section */'
    )

    # --- 6. Add new PBXGroup entries and update root group + existing groups ---
    new_group_entries = []
    for tname in ["FineTune", "FineTuneTests", "FineTuneUITests"]:
        info = targets_info[tname]
        new_group_entries.extend(generate_group_entries(info['root_group']))

    group_insertion = '\n'.join(new_group_entries)
    content = content.replace(
        '/* End PBXGroup section */',
        group_insertion + '\n/* End PBXGroup section */'
    )

    # --- 7. Replace old PBXFileSystemSynchronizedRootGroup IDs in the main group ---
    old_to_new = {
        '79A607B12F05C9E00008D52A': targets_info['FineTune']['root_group'].group_id,
        '79A607BF2F05C9E10008D52A': targets_info['FineTuneTests']['root_group'].group_id,
        '79A607C92F05C9E10008D52A': targets_info['FineTuneUITests']['root_group'].group_id,
    }
    for old_id, new_id in old_to_new.items():
        content = content.replace(old_id, new_id)

    # --- 8. Add PBXBuildFile entries for sources and resources ---
    new_build_files = []
    for tname in ["FineTune", "FineTuneTests", "FineTuneUITests"]:
        info = targets_info[tname]
        new_build_files.extend(generate_build_file_lines(info['sources'], 'Sources'))
        new_build_files.extend(generate_build_file_lines(info['resources'], 'Resources'))

    build_file_insertion = '\n'.join(new_build_files)
    content = content.replace(
        '/* End PBXBuildFile section */',
        build_file_insertion + '\n/* End PBXBuildFile section */'
    )

    # --- 9. Populate PBXSourcesBuildPhase for each target ---
    source_phase_map = {
        'FineTune': '79A607AB2F05C9E00008D52A',
        'FineTuneTests': '79A607B82F05C9E10008D52A',
        'FineTuneUITests': '79A607C22F05C9E10008D52A',
    }

    for tname, phase_id in source_phase_map.items():
        info = targets_info[tname]
        source_lines = []
        for f in info['sources']:
            source_lines.append(f'\t\t\t\t{f.build_file_id} /* {f.name} in Sources */,')

        files_str = '\n'.join(source_lines)

        old_pattern = (
            f'{phase_id} /* Sources */ = {{\n'
            f'\t\t\tisa = PBXSourcesBuildPhase;\n'
            f'\t\t\tbuildActionMask = 2147483647;\n'
            f'\t\t\tfiles = (\n'
            f'\t\t\t);\n'
            f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
            f'\t\t}};'
        )
        new_pattern = (
            f'{phase_id} /* Sources */ = {{\n'
            f'\t\t\tisa = PBXSourcesBuildPhase;\n'
            f'\t\t\tbuildActionMask = 2147483647;\n'
            f'\t\t\tfiles = (\n'
            f'{files_str}\n'
            f'\t\t\t);\n'
            f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
            f'\t\t}};'
        )
        content = content.replace(old_pattern, new_pattern)

    # --- 10. Populate PBXResourcesBuildPhase for each target ---
    resource_phase_map = {
        'FineTune': '79A607AD2F05C9E00008D52A',
        'FineTuneTests': '79A607BA2F05C9E10008D52A',
        'FineTuneUITests': '79A607C42F05C9E10008D52A',
    }

    for tname, phase_id in resource_phase_map.items():
        info = targets_info[tname]
        resource_lines = []
        for f in info['resources']:
            resource_lines.append(f'\t\t\t\t{f.build_file_id} /* {f.name} in Resources */,')

        if tname == 'FineTune':
            # FineTune already has fineTuneIcon.icon in Resources -- keep it
            old_res = (
                f'{phase_id} /* Resources */ = {{\n'
                f'\t\t\tisa = PBXResourcesBuildPhase;\n'
                f'\t\t\tbuildActionMask = 2147483647;\n'
                f'\t\t\tfiles = (\n'
                f'\t\t\t\t7988AE522F1CC55900E6D086 /* fineTuneIcon.icon in Resources */,\n'
                f'\t\t\t);\n'
                f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
                f'\t\t}};'
            )
            all_res_lines = ['\t\t\t\t7988AE522F1CC55900E6D086 /* fineTuneIcon.icon in Resources */,']
            all_res_lines.extend(resource_lines)
            files_str = '\n'.join(all_res_lines)
            new_res = (
                f'{phase_id} /* Resources */ = {{\n'
                f'\t\t\tisa = PBXResourcesBuildPhase;\n'
                f'\t\t\tbuildActionMask = 2147483647;\n'
                f'\t\t\tfiles = (\n'
                f'{files_str}\n'
                f'\t\t\t);\n'
                f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
                f'\t\t}};'
            )
            content = content.replace(old_res, new_res)
        else:
            if resource_lines:
                files_str = '\n'.join(resource_lines)
                old_res = (
                    f'{phase_id} /* Resources */ = {{\n'
                    f'\t\t\tisa = PBXResourcesBuildPhase;\n'
                    f'\t\t\tbuildActionMask = 2147483647;\n'
                    f'\t\t\tfiles = (\n'
                    f'\t\t\t);\n'
                    f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
                    f'\t\t}};'
                )
                new_res = (
                    f'{phase_id} /* Resources */ = {{\n'
                    f'\t\t\tisa = PBXResourcesBuildPhase;\n'
                    f'\t\t\tbuildActionMask = 2147483647;\n'
                    f'\t\t\tfiles = (\n'
                    f'{files_str}\n'
                    f'\t\t\t);\n'
                    f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
                    f'\t\t}};'
                )
                content = content.replace(old_res, new_res)

    # --- 11. Remove Swift 6 build settings ---
    content = re.sub(r'\s*SWIFT_APPROACHABLE_CONCURRENCY = YES;\n', '\n', content)
    content = re.sub(r'\s*SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;\n', '\n', content)
    content = re.sub(r'\s*SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES;\n', '\n', content)

    # --- 12. Downgrade LastSwiftUpdateCheck and LastUpgradeCheck ---
    content = content.replace('LastSwiftUpdateCheck = 2610', 'LastSwiftUpdateCheck = 1540')
    content = content.replace('LastUpgradeCheck = 2610', 'LastUpgradeCheck = 1540')

    # --- 13. Downgrade CreatedOnToolsVersion ---
    content = content.replace('CreatedOnToolsVersion = 26.1.1', 'CreatedOnToolsVersion = 15.4')

    # --- 14. Fix all unquoted plist values with special characters ---
    # This catches both our generated content AND existing content that needs quoting
    content = fix_existing_unquoted_paths(content)

    # Write the result
    with open(PBXPROJ, 'w') as fh:
        fh.write(content)

    # Print summary
    for tname in ["FineTune", "FineTuneTests", "FineTuneUITests"]:
        info = targets_info[tname]
        print(f"{tname}:")
        print(f"  Sources: {len(info['sources'])} files")
        print(f"  Resources: {len(info['resources'])} files")
        print(f"  Group ID: {info['root_group'].group_id}")

    print("\nConversion complete!")
    print(f"  objectVersion: 77 -> 56")
    print(f"  Removed PBXFileSystemSynchronizedRootGroup section")
    print(f"  Removed fileSystemSynchronizedGroups from targets")
    print(f"  Removed Swift 6 build settings")
    print(f"  Added explicit PBXFileReference + PBXGroup entries")
    print(f"  Populated Sources and Resources build phases")
    print(f"  Fixed unquoted plist values")


if __name__ == '__main__':
    convert()
