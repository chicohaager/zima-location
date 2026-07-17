# Announcement draft (EN) — forum / Reddit r/ZimaOS, r/selfhosted

**Title:** zima-location — finally point /DATA/Media (and all your apps) at a different disk, once, reboot-safe

---

One thing that bugs a lot of ZimaOS/CasaOS users: there is **no global setting**
for *where* apps store their data. Every store app hard-codes `/DATA/AppData/...`
and `/DATA/Media` onto the system disk. Your only option is editing each app's
volumes by hand — and every new install resets to `/DATA/...` again.

So I built a small tool: **zima-location**.

Every app points at the same anchors (`/DATA/Media`, `/DATA/AppData`), so you
redirect the anchor **once** and every present *and future* app follows. It
bind-mounts an anchor onto a subdirectory of a disk you choose.

The tricky part is doing it **safely across reboots**: ZimaOS mounts data disks
under letter paths (`/media/sdb`) that can **shift** after a reboot (plug in a USB
stick and your SATA letters move). A naive bind to `/media/sdb/...` is a time bomb.

zima-location never hardcodes a letter — a tiny `oneshot` systemd service resolves
the disk **by UUID** at every boot (`findmnt -S UUID=...`) and binds wherever it
actually is. I tested this on real hardware: after a reboot the target disk moved
from `/dev/sdd` to `/dev/sdb`, and `/DATA/Media` stayed correctly bound. 🎯

- ext4/btrfs/xfs only (exFAT/NTFS are rejected — container uid can't chown them)
- migrates existing files, keeps a backup, one-command rollback
- optional tiny web UI (python3)
- MIT OR Apache-2.0

**Repo + install:** https://github.com/chicohaager/zima-location

```
curl -fsSL https://raw.githubusercontent.com/chicohaager/zima-location/main/install.sh | sudo bash
sudo /DATA/AppData/zima-location/zima-location.sh list-disks
sudo /DATA/AppData/zima-location/zima-location.sh set /DATA/Media <UUID> Media
```

Not affiliated with IceWhale. Feedback / issues welcome. Test `rollback` first. 🙂
