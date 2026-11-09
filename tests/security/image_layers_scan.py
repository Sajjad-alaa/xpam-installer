#!/usr/bin/env python3
"""Scan EVERY layer of a saved image for readable XPAM source, including files later deleted in an upper layer
(a deleted file stays in the lower layer's tar and can be recovered with `docker save`).

    docker save <image> | python3 -I image_layers_scan.py [<apps-path-in-image>]

Reports, per layer that holds application files: .py files, .pyc files, compiled .so modules, test files and the
SDK demos. Exit status 1 if any layer holds XPAM-only source (xpack/*.py, accounts/jit/*.py) or a .pyc of it.
"""
import json
import sys
import tarfile

APPS = (sys.argv[1] if len(sys.argv) > 1 else 'opt/jumpserver/apps').strip('/') + '/'
# files that exist only in XPAM (not in the public upstream JumpServer image): readable copies mean leaked source
XPAM_ONLY = ('xpack/', 'accounts/jit/')


def is_test(rel):
    name = rel.rsplit('/', 1)[-1]
    return '/tests/' in '/' + rel or name == 'tests.py' or (name.startswith('test_') and name.endswith('.py'))


def scan_layer(fileobj):
    stats = {'py': 0, 'pyc': 0, 'so': 0, 'tests': 0, 'demos': 0, 'xpam_py': [], 'xpam_pyc': []}
    with tarfile.open(fileobj=fileobj, mode='r|*') as layer:
        for m in layer:
            name = m.name.lstrip('./')
            if not name.startswith(APPS) or not m.isfile():
                continue
            rel = name[len(APPS):]
            if rel.rsplit('/', 1)[-1].startswith('.wh.'):
                continue  # a whiteout: the marker of a file deleted in this layer, no content
            if rel.endswith('.py'):
                stats['py'] += 1
                if rel.startswith(XPAM_ONLY) and not rel.endswith('__init__.py') and '/migrations/' not in rel:
                    stats['xpam_py'].append(rel)
            elif rel.endswith('.pyc'):
                stats['pyc'] += 1
                src = rel.replace('/__pycache__', '').rsplit('.cpython', 1)[0]
                if src.startswith(XPAM_ONLY) and not src.endswith('__init__') and '/migrations/' not in src:
                    stats['xpam_pyc'].append(rel)
            elif rel.endswith('.so'):
                stats['so'] += 1
            if is_test(rel):
                stats['tests'] += 1
            if rel.startswith('accounts/demos/'):
                stats['demos'] += 1
    return stats


def main():
    outer = tarfile.open(fileobj=sys.stdin.buffer, mode='r|')
    leaks = 0
    n = 0
    for member in outer:
        if not member.isfile() or not (member.name.startswith('blobs/') or member.name.endswith('layer.tar')):
            continue
        f = outer.extractfile(member)
        try:
            stats = scan_layer(f)
        except tarfile.TarError:
            continue  # a config or manifest blob, not a layer
        n += 1
        if not (stats['py'] or stats['pyc'] or stats['so']):
            continue
        bad = stats['xpam_py'] or stats['xpam_pyc']
        leaks += bool(bad)
        print(('LEAK ' if bad else 'ok   ') + member.name[-19:] + ' ' + json.dumps(
            {k: (len(v) if isinstance(v, list) else v) for k, v in stats.items()}))
        for rel in (stats['xpam_py'] + stats['xpam_pyc'])[:5]:
            print('       e.g. ' + rel)
    print(f'layers scanned: {n}; layers with readable XPAM-only source: {leaks}')
    sys.exit(1 if leaks else 0)


main()
