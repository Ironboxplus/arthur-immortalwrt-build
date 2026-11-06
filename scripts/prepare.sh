#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(pwd)
mkdir -p artifacts
source_url=$(python3 -c 'import json; print(json.load(open("source.lock.json"))["repository"])')
source_sha=$(python3 -c 'import json; print(json.load(open("source.lock.json"))["commit"])')
git init source
git -C source remote add origin "$source_url"
git -C source fetch --depth=1 origin "$source_sha"
git -C source checkout --detach FETCH_HEAD
test "$(git -C source rev-parse HEAD)" = "$source_sha"
cp feeds.conf source/feeds.conf.default
cp config.seed source/.config
cp -a files source/
chmod +x source/files/etc/uci-defaults/99-arthur-nss
cd source
./scripts/feeds update -a 2>&1 | tee "$repo_dir/artifacts/feeds-update.log"
./scripts/feeds install -a 2>&1 | tee "$repo_dir/artifacts/feeds-install.log"
# Prefer the explicitly locked iStore and EasyTier feeds over any duplicate recipe.
./scripts/feeds install -a -f -p istore
./scripts/feeds install -a -f -p easytier
# Argon is a single-package repository with Makefile at its root. The feed
# scanner skips that root; expose the pinned checkout as a normal package.
ln -s ../feeds/argon package/luci-theme-argon
python3 - "$repo_dir" <<'PY'
import hashlib, json, pathlib, subprocess, sys, urllib.request
root = pathlib.Path(sys.argv[1])
lock = json.loads((root / 'source.lock.json').read_text())
provenance = {'source': lock, 'feeds': {}}
for item in json.loads((root / 'feeds.lock.json').read_text()):
    path = pathlib.Path('feeds') / item['name']
    actual = subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != item['sha']:
        raise SystemExit('Feed revision mismatch: ' + item['name'])
    provenance['feeds'][item['name']] = actual
# EasyTier's upstream recipe downloads a release ZIP during Build/Prepare.
# Populate its expected build directory from the SHA256-locked official asset.
version = lock['easytier_version']
url = f'https://github.com/EasyTier/EasyTier/releases/download/v{version}/easytier-linux-aarch64-v{version}.zip'
archive = pathlib.Path('dl') / f'easytier-linux-aarch64-v{version}.zip'
archive.parent.mkdir(exist_ok=True)
if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != lock['easytier_archive_sha256']:
    urllib.request.urlretrieve(url, archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != lock['easytier_archive_sha256']:
    raise SystemExit('EasyTier official archive SHA256 mismatch')
provenance['easytier_archive'] = lock['easytier_archive_sha256']
recipe = pathlib.Path('feeds/easytier/easytier/Makefile')
text = recipe.read_text()
old = 'wget https://github.com/EasyTier/EasyTier/releases/download/v$(PKG_VERSION)/$(PKG_NAME)-linux-$(APP_ARCH)-v$(PKG_VERSION).zip -O $(PKG_BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION).zip;'
new = 'cp "$(DL_DIR)/easytier-linux-aarch64-v$(PKG_VERSION).zip" "$(PKG_BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION).zip";'
if text.count(old) != 1:
    raise SystemExit('Locked EasyTier recipe download statement changed')
recipe.write_text(text.replace(old, new))
provenance['easytier_recipe_sha256'] = hashlib.sha256(recipe.read_bytes()).hexdigest()
(root / 'artifacts/provenance.json').write_text(json.dumps(provenance, indent=2))
PY
# feeds update/install may invoke Kconfig before feed metadata exists and discard
# package selections. Apply the requested seed AFTER all feeds are installed.
cp "$repo_dir/config.seed" .config
make defconfig 2>&1 | tee "$repo_dir/artifacts/defconfig.log"
cp .config "$repo_dir/artifacts/config.resolved"
cp feeds.conf.default "$repo_dir/artifacts/feeds.conf"
cp "$repo_dir/source.lock.json" "$repo_dir/feeds.lock.json" "$repo_dir/config.seed" "$repo_dir/artifacts/"
python3 "$repo_dir/scripts/verify.py" config "$repo_dir"
