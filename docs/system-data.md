# What is System Data?

English · [繁體中文](system-data.zh-Hant.md) · [日本語](system-data.ja.md) · [한국어](system-data.ko.md)

**System Settings › General › Storage** splits your disk into categories, and System Data is often
one of the largest, with no list of what is in it. Apple says it "primarily includes files and data
used by the system, such as log files, caches, VM files", also "temporary files, fonts, app support
files, and plug-ins", and that "You can't manage the contents of this category."
([Apple](https://support.apple.com/guide/mac-help/change-storage-settings-on-mac-mchl3d437fbc/mac))

Settings does not say which files it put there, so no app can open that category item by item, and
Hoard does not pretend to. It works from the other end: it takes how much the disk uses, subtracts
everything it can measure, and names what is left. That is the **Unaccounted Space** card.

## Where to find it

1. Scan the whole disk: **File › Scan entire disk "Macintosh HD"** (your disk may have another name).
   Give Hoard Full Disk Access first (see [Install](../README.md#install)); without it many folders
   cannot be read.
2. Choose **Cleanup** in the sidebar. Unaccounted Space is the first card.

On the command line, `hoard hidden` prints the same lines (add `--json` for a program to read).
After scanning a single folder, the card can only say that the rest of the disk was not scanned.

## The lines, one by one

Every size is measured, estimated (shown as "about" or "at least") or unknown. An unknown size is
never shown as zero.

| Line | What it is | Can you free it? |
|---|---|---|
| **Total disk capacity**, **Available space**, **Used space** | The whole APFS container, which all volumes on the disk share, as the file system reports it. | — |
| **Scanned files** | Everything on the map. The caches, logs, temporary files and app support files that Settings counts as System Data are ordinary folders here, such as `~/Library/Caches`. | Partly. Cleanup lists the caches, build files, installers, logs and data of removed apps that it recognizes, and says which can be rebuilt or downloaded again. |
| **Virtual memory volume**, with **Swap files** and **Sleep image file** under it | `/System/Volumes/VM`: the swap files macOS writes when memory runs short and, on some Macs, the image kept for sleep. These are the "VM files" in Apple's description. | Not by deleting them: they belong to the running system. They shrink when less memory is needed, for example after quitting apps that use a lot of it, or after a restart. |
| **Other mounted volumes** | The other volumes in the same container, mainly the read-only system volume that holds macOS itself ([Apple](https://support.apple.com/guide/security/secd698747c9/web)) and Preboot. | No. They are part of macOS. |
| **Time Machine local snapshots** | How many local snapshots Time Machine keeps. macOS lists them but does not give their size, so this line shows a count. `tmutil listlocalsnapshots /` shows the same list. | Usually no need: Time Machine "automatically deletes snapshots as they age or as space is needed". To remove them sooner, set **Backup Frequency** to **Manually** in Time Machine settings, wait a few minutes, then turn automatic backups back on ([Apple](https://support.apple.com/102154)). |
| **Unreadable folders** | Folders Hoard could not read completely, usually because it was not allowed to. Their size is unknown. | Give Hoard Full Disk Access and scan again. |
| **Remaining unexplained space** | Used space minus every line above that has a size: volumes that are not mounted (Recovery among them), the file system's own records, space held only by snapshots (Time Machine's and other apps'), and folders Hoard could not read. | Check the lines above first. While folders are unreadable or snapshot sizes unknown, this number is an estimate. |
| **Purgeable space** | Space macOS can free by itself when something needs it: the difference between the space macOS offers for important files ([Apple](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey)) and plain free space. | macOS frees it when needed. |

## Why Hoard and Settings show different numbers

- **Used space.** macOS "counts the space used by snapshots as available storage"
  ([Apple](https://support.apple.com/102154)). Hoard's Used space comes from the file system, which
  counts that space as used. macOS gives no snapshot sizes, so space held only by snapshots is in no
  folder and ends up in Remaining unexplained space. So Hoard's Used space is often larger than what
  Settings shows.
- **Categories and folders.** Settings puts each file in one category (Applications, Documents,
  System Data, …). Hoard shows folders. A cache that Settings counts as System Data is a folder in
  your home folder on Hoard's map.
- **Shared storage.** Hard links and APFS clones are counted once, as the disk stores them.

## What Hoard does not do

Hoard never deletes system files, snapshots or swap files. It only reads: the snapshot count comes
from `tmutil listlocalsnapshots`. Cleanup and Move to Trash work only on items you could also delete
in the Finder, and only after you confirm.
