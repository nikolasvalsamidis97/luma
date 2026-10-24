"""Verify a self-contained Windows folder before zipping; no Windows runtime required."""
import json, pathlib, struct, sys
root = pathlib.Path(sys.argv[1])
required = ['Luma.exe','Luma.dll','Luma.Core.dll','Luma.runtimeconfig.json','coreclr.dll','hostfxr.dll','hostpolicy.dll',
            'PresentationFramework.dll','LibVLCSharp.dll','LibVLCSharp.WPF.dll','START-HERE.txt','THIRD_PARTY_NOTICES.txt',
            'licenses/LGPL-2.1.txt','licenses/DOTNET-LICENSE.txt','licenses/DOTNET-THIRD-PARTY-NOTICES.txt',
            'libvlc/win-x64/libvlc.dll','libvlc/win-x64/libvlccore.dll']
for name in required:
    assert (root/name).is_file() and (root/name).stat().st_size > 0, f'Missing {name}'
config=json.loads((root/'Luma.runtimeconfig.json').read_text())['runtimeOptions']
assert {x['name'] for x in config['includedFrameworks']} >= {'Microsoft.NETCore.App','Microsoft.WindowsDesktop.App'}
assert 'framework' not in config and 'frameworks' not in config, 'Framework-dependent build'
for name in ['Luma.exe','coreclr.dll','libvlc/win-x64/libvlc.dll','libvlc/win-x64/libvlccore.dll']:
    raw=(root/name).read_bytes(); pe=struct.unpack_from('<I',raw,0x3c)[0]
    assert raw[:2]==b'MZ' and raw[pe:pe+4]==b'PE\0\0' and struct.unpack_from('<H',raw,pe+4)[0]==0x8664, f'Not Windows x64: {name}'
plugins=list((root/'libvlc/win-x64/plugins').rglob('*.dll'))
assert len(plugins)>100, 'VLC plugins missing'
for glob in ['*avcodec*','*freetype*','*adaptive*','*direct3d11*']:
    assert list((root/'libvlc/win-x64/plugins').rglob(glob)), f'Missing VLC component {glob}'
assert not (root/'libvlc/win-x86').exists() and not (root/'libvlc/win-arm64').exists()
assert not list(root.rglob('*.dat')) and not list(root.rglob('.env*')), 'Unexpected private data in package'
assert not any(p.is_symlink() for p in root.rglob('*')), 'Package must not depend on external symlinks'
print(f'PASS: self-contained Windows x64 package; {len(plugins)} VLC plugins, runtime, licenses, and no external symlinks.')
