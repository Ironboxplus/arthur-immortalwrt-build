# Arthur ImmortalWrt build

GitHub Actions build for JDCloud RE-SS-01 (Arthur), 512 MiB RAM / 64 GB eMMC.

Source: `laipeng668/immortalwrt`, `openwrt-25.12`, fixed commit in `source.lock.json`.
Linux 6.12, NSS 12.5, 512M ath11k memory profile, iStore, EasyTier and the historical
general-purpose router toolset. No campus authentication, multi-dial, mwan3,
accounts, mesh identity, passwords, calibration data or device backups are included.

Run **Build Arthur** manually. The workflow checks all explicitly required packages
after `defconfig` and again against the resulting manifest. Source, feeds and
GitHub Actions are pinned. Artifacts include firmware, matching package archive,
resolved config, provenance, SHA256 and an OEM partition-size report.

Building does not flash anything. A successful build is not a device boot test.
The size report compares the image against the original 6 MiB HLOS and 60 MiB
rootfs partitions; exceeding these sizes requires a separately reviewed layout.

`files/etc/uci-defaults/99-arthur-nss` disables generic flow offload and packet
steering, and selects the upstream 512M NSS pbuf profile. It does not overclock,
invent WAN speeds or enable SQM shaping without a measured line rate.
