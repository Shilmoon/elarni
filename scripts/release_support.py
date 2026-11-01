"""Small shared helpers for local release archives; never publishes artifacts."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess

ROOT = Path(__file__).resolve().parent.parent
PUBLIC_ROOT_FILES = {
    '.gitignore', '.metadata', 'Cargo.toml', 'Cargo.lock', 'pubspec.yaml', 'pubspec.lock',
    'go.work', 'go.work.sum', 'rust-toolchain.toml', 'mise.toml', 'ffigen.yaml', 'l10n.yaml', '.gitattributes',
    'package.json', 'package-lock.json', 'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES',
    'README.md', 'CONTRIBUTING.md', 'SECURITY.md', 'CHANGELOG.md', 'AGENTS.md', 'CLAUDE.md',
}
PUBLIC_DIRECTORIES = {'.github', 'Vendor', 'android', 'docs', 'ios', 'bin', 'include', 'lib', 'linux', 'macos', 'windows',
                      'native', 'scripts', 'test', 'third_party', 'assets'}
EXCLUDED_PARTS = {'.git', '.build', '.toolchains', '.dart_tool', 'build', 'target',
                  'Evidence', 'artifacts', 'ephemeral', '__pycache__', 'node_modules', '.gradle', '.kotlin'}


def version(root=ROOT):
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+\+\d+)\s*$',
                      (root / 'pubspec.yaml').read_text(), re.M)
    if not match:
        raise ValueError('Unsupported app version in pubspec.yaml')
    return match[1]


def windows_product_version(path):
    """The ProductVersion string in a PE file's version resource; the Windows runner sets it to the pubspec version."""
    data = path.read_bytes()
    key = 'ProductVersion\0'.encode('utf-16-le')
    start = data.find(key)
    if start < 6:
        return None
    # A version String entry: wLength, wValueLength (in characters), wType, key, padding to 4 bytes, value.
    length = struct.unpack_from('<H', data, start - 4)[0]
    value = start + len(key)
    value += -value % 4
    return data[value:value + 2 * length].decode('utf-16-le', 'replace').rstrip('\0')


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def validate_tree(root):
    root = root.resolve(strict=True)
    for path in root.rglob('*'):
        if path.is_symlink() and not path.resolve(strict=True).is_relative_to(root):
            raise ValueError('External bundle symlink: ' + str(path.relative_to(root)))
        if not path.is_file() and not path.is_dir():
            raise ValueError('Unsupported bundle entry: ' + str(path.relative_to(root)))


def require_files(root, names):
    validate_tree(root)
    for name in names:
        if not (root / name).is_file() or (root / name).stat().st_size == 0:
            raise ValueError('Missing or empty bundle component: ' + name)


def prepare_output(output):
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Output directory must be empty; previous releases are never overwritten')


def source_paths(root=ROOT):
    def permitted(relative):
        return (not relative.is_absolute() and '..' not in relative.parts
                and not any(part in EXCLUDED_PARTS for part in relative.parts)
                and (relative.parts[0] != 'android' or relative.name not in {'local.properties', 'GeneratedPluginRegistrant.java'}
                     and relative.suffix not in {'.jks', '.keystore', '.apk', '.aab'})
                and (relative.parts[0] != 'ios' or 'xcuserdata' not in relative.parts
                     and relative.suffix not in {'.mobileprovision', '.p12', '.ipa'})
                and (relative.as_posix() in PUBLIC_ROOT_FILES
                     or len(relative.parts) > 1 and relative.parts[0] in PUBLIC_DIRECTORIES))

    entries = subprocess.check_output(
        ['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'])
    result = []
    for text in sorted(set(os.fsdecode(value) for value in entries.split(b'\0') if value)):
        relative = Path(text)
        if not permitted(relative):
            continue
        path = root / relative
        if path.is_symlink():
            target = path.resolve(strict=True)
            if not target.is_relative_to(root) or not permitted(target.relative_to(root)):
                raise ValueError('Source symlink leaves public source: ' + text)
        if path.is_file():
            result.append(relative)
    if not result:
        raise ValueError('No public project source discovered')
    return result


def write_manifest(output, artifacts, platform, distribution, root=ROOT):
    files = source_paths(root)
    source = {path.as_posix(): ({'symlink': os.readlink(root / path)} if (root / path).is_symlink()
                              else digest(root / path)) for path in files}
    inventory = json.dumps(source, sort_keys=True, indent=2) + '\n'
    (output / 'project-source-manifest.json').write_text(inventory)
    toolchains = {}
    flutter = root / '.toolchains/flutter/bin' / ('flutter.bat' if os.name == 'nt' else 'flutter')
    for name, command in [('go', ['go', 'version']), ('rust', ['rustc', '--version'])]:
        try:
            toolchains[name] = subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()
        except (OSError, subprocess.CalledProcessError):
            toolchains[name] = None
    try:
        info = json.loads(subprocess.check_output([str(flutter) if flutter.exists() else 'flutter',
                                                  '--version', '--machine'], text=True))
        toolchains['flutter'] = {key: info.get(key) for key in
                                ('frameworkVersion', 'frameworkRevision', 'engineRevision', 'dartSdkVersion')}
    except (OSError, ValueError, subprocess.CalledProcessError):
        toolchains['flutter'] = None
    receipt = {
        'schemaVersion': 1, 'version': version(root), 'platform': platform,
        'distribution': distribution, 'createdAt': datetime.now(timezone.utc).isoformat(),
        'sourceAtPackaging': {
            'revision': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
            'fileCount': len(source), 'manifest': 'project-source-manifest.json',
            'sha256': hashlib.sha256(inventory.encode()).hexdigest(),
        },
        'packagingToolchains': toolchains,
        'artifacts': [{'file': path.name, 'bytes': path.stat().st_size, 'sha256': digest(path)} for path in artifacts],
        'acceptance': 'Separate installed-release and upgrade acceptance is required.',
    }
    (output / 'release-manifest.json').write_text(json.dumps(receipt, indent=2) + '\n')
    (output / 'SHA256SUMS').write_text(''.join(f"{item['sha256']}  {item['file']}\n" for item in receipt['artifacts']))
    return receipt
