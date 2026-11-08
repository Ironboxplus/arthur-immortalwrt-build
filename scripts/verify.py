"""Fail on missing required features; record image sizes without flashing."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import tarfile


def main():
    mode, root = sys.argv[1], Path(sys.argv[2])
    artifacts = root / 'artifacts'
    required = json.loads((root / 'required-packages.json').read_text())
    cfg = (root / 'source/.config').read_text()
    enabled = set(re.findall(r'^CONFIG_(.+)=y$', cfg, re.M))
    missing = [name for name in required if 'PACKAGE_' + name not in enabled]
    must_symbols = ['TARGET_qualcommax', 'TARGET_qualcommax_ipq60xx',
                    'TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01',
                    'NSS_FIRMWARE_VERSION_12_5', 'ATH11K_MEM_PROFILE_512M',
                    'ATH11K_NSS_SUPPORT', 'USE_APK']
    missing_symbols = [name for name in must_symbols if name not in enabled]
    forbidden = [name for name in enabled if name.startswith('PACKAGE_') and
                 re.search(r'(mwan3|multidial|ruijie|schoolrecon)', name, re.I)]
    if 'TESTING_KERNEL' in enabled:
        forbidden.append('TESTING_KERNEL')
    devices = [x for x in enabled if '_DEVICE_' in x and x.startswith('TARGET_')]
    report = dict(missing_packages=missing, missing_symbols=missing_symbols,
                  forbidden=forbidden, selected_devices=devices,
                  required_packages=required)
    (artifacts / 'config-audit.json').write_text(json.dumps(report, indent=2))
    if missing or missing_symbols or forbidden or len(devices) != 1:
        raise SystemExit(json.dumps(report, indent=2))
    if mode == 'config':
        print('CONFIG_AUDIT_PASS', len(required), 'required packages')
        return
    target = root / 'source/bin/targets/qualcommax/ipq60xx'
    manifests = list(target.glob('*jdcloud_re-ss-01*.manifest'))
    if len(manifests) != 1:
        raise SystemExit('Expected one RE-SS-01 manifest')
    installed = {line.split(' - ')[0] for line in manifests[0].read_text().splitlines()}
    missing = sorted(set(required) - installed)
    forbidden = sorted(x for x in installed if re.search(r'(mwan3|multidial|ruijie|schoolrecon)', x, re.I))
    if missing or forbidden:
        raise SystemExit(f'Manifest mismatch: missing={missing}, forbidden={forbidden}')
    # Local ath11k fixes must reach the module that ships, not only the tree.
    modules = list((root / 'source/build_dir').glob('target-*/linux-*/mac80211-*/backports-*/drivers/net/wireless/ath/ath11k/ath11k.ko'))
    if len(modules) != 1:
        raise SystemExit(f'Expected one built ath11k.ko, found {len(modules)}')
    if b'delete unacknowledged, deleting in firmware anyway' not in modules[0].read_bytes():
        raise SystemExit('ath11k.ko lacks the band-migration peer delete fix')
    images = list(target.glob('*jdcloud_re-ss-01*sysupgrade.bin'))
    factories = list(target.glob('*jdcloud_re-ss-01*factory.bin'))
    if len(images) != 1 or len(factories) != 1:
        raise SystemExit('Missing or ambiguous Arthur factory/sysupgrade pair')
    with tarfile.open(images[0]) as archive:
        kernels = [m for m in archive.getmembers() if m.name.endswith('/kernel')]
        roots = [m for m in archive.getmembers() if m.name.endswith('/root')]
        if len(kernels) != 1 or len(roots) != 1:
            raise SystemExit('Cannot inspect kernel/root sizes')
        sizes = dict(kernel_bytes=kernels[0].size, rootfs_bytes=roots[0].size,
                     oem_kernel_limit=6*1024**2, oem_rootfs_limit=60*1024**2)
    sizes['fits_oem_partition_sizes'] = sizes['kernel_bytes'] <= sizes['oem_kernel_limit'] and sizes['rootfs_bytes'] <= sizes['oem_rootfs_limit']
    sizes['device_boot_tested'] = False
    sizes['flash_authorized_by_build'] = False
    (artifacts / 'oem-size-report.json').write_text(json.dumps(sizes, indent=2))
    fw = artifacts / 'firmware'
    fw.mkdir(exist_ok=True)
    for path in target.iterdir():
        if path.is_file() and ('jdcloud_re-ss-01' in path.name or path.name in ['profiles.json', 'config.buildinfo', 'feeds.buildinfo', 'version.buildinfo', 'sha256sums']):
            shutil.copy2(path, fw / path.name)
    (fw / 'SHA256SUMS.local').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in sorted(fw.iterdir()) if p.is_file() and p.name != 'SHA256SUMS.local'))
    print('MANIFEST_AUDIT_PASS', len(required), 'required packages')
    print(json.dumps(sizes, indent=2))


if __name__ == '__main__':
    main()
