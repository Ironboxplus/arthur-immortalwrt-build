#!/usr/bin/env bash
# Rebuild the patched mac80211/ath11k source tree the way OpenWrt's
# package/kernel/mac80211 Build/Patch does for the NSS variant, without a full
# firmware build. Used to write local patches and to prove they apply cleanly.
#
# usage: scripts/mac80211-tree.sh <workdir> [--with-local]
#
# <workdir>/tree is a git repo: commit "upstream" = backports + all OpenWrt/NSS
# patches; with --with-local, patches/mac80211/nss/ath11k/*.patch from this repo
# are applied last (same place prepare.sh copies them) as commit "local".
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
work=${1:?usage: $0 <workdir> [--with-local]}
with_local=${2:-}
mkdir -p "$work/dl"
work=$(cd "$work" && pwd)

lock_field() { sed -n "s/.*\"$1\": *\"\\([^\"]*\\)\".*/\\1/p" "$repo_dir/source.lock.json"; }
sha=$(lock_field commit)
url=$(lock_field repository)

src=$work/openwrt
if [ "$(git -C "$src" rev-parse HEAD 2>/dev/null || true)" != "$sha" ]; then
	rm -rf "$src"
	git init -q "$src"
	git -C "$src" remote add origin "$url"
	git -C "$src" config core.sparseCheckout true
	echo package/kernel/mac80211/ > "$src/.git/info/sparse-checkout"
	git -C "$src" fetch -q --depth=1 --filter=blob:none origin "$sha"
	git -C "$src" checkout -q --detach FETCH_HEAD
fi
pkg=$src/package/kernel/mac80211

ver=$(sed -n 's/^PKG_SOURCE_VERSION:=//p' "$pkg/Makefile")
hash=$(sed -n 's/^PKG_HASH:=//p' "$pkg/Makefile")
nss_dirs=$(sed -n 's/^NSS_PATCH:=//p' "$pkg/Makefile")
tarball=$work/dl/backports-$ver.tar.zst
if [ ! -f "$tarball" ] || ! echo "$hash  $tarball" | sha256sum -c --status; then
	curl -fL --retry 3 -o "$tarball" "https://github.com/openwrt/backports/releases/download/backports-v$ver/backports-$ver.tar.zst"
fi
echo "$hash  $tarball" | sha256sum -c --status || { echo "backports-$ver hash mismatch" >&2; exit 1; }

tree=$work/tree
rm -rf "$tree" "$work/backports-$ver"
tar -C "$work" -I zstd -xf "$tarball"
mv "$work/backports-$ver" "$tree"

apply_dir() {
	local dir=$1 p
	[ -d "$dir" ] || return 0
	while IFS= read -r p; do
		patch -p1 -E -s -f --no-backup-if-mismatch -d "$tree" < "$p" ||
			{ echo "FAILED: ${p#"$pkg/"}" >&2; return 1; }
	done < <(find "$dir" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)
}

# Same order as Build/Patch in package/kernel/mac80211/Makefile.
for d in build subsys ath ath5k ath9k ath10k ath11k ath12k rt2x00 mt7601u mwl brcm rtl; do
	apply_dir "$pkg/patches/$d"
done
for d in $nss_dirs; do
	apply_dir "$pkg/patches/nss/$d"
done

git -C "$tree" init -q
git -C "$tree" config core.autocrlf false
git -C "$tree" add -A
git -C "$tree" -c user.name=tree -c user.email=tree@localhost commit -q -m upstream
echo "upstream tree: $tree (backports-$ver, openwrt $sha)"

if [ "$with_local" = --with-local ]; then
	apply_dir "$repo_dir/patches/mac80211/nss/ath11k"
	git -C "$tree" add -A
	git -C "$tree" -c user.name=tree -c user.email=tree@localhost commit -q -m local
	git -C "$tree" show --stat --format='local patches applied (%s):' HEAD
fi
