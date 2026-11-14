# ScanSnap Manager OCR compatibility

> a hack for stubborn users of ScanSnap Manager OCR, who refuse to try anything better.

## What breaks

ScanSnap Manager 7.2.70.1001 is an Intel application that runs under Rosetta on Apple Silicon. On macOS 27.2 (26B123), its searchable-PDF OCR can fail and offer to save anyway. The saved PDF has no text layer.

The OCR client worker uses the deprecated Carbon process APIs to find and check its launcher. In the observed failure, its launcher process serial number (PSN) is `0:0`, even though its actual parent, OCRControllerProcess, is alive. The worker's parent check fails with `procNotFound` (`-600`), and the worker quits.

Ricoh lists this Manager version and the iX500 as unsupported on macOS 26 and 27. This repair targets the specific failure above, not every possible OCR problem.

## What the patch does

The patch replaces the OCR client executable with a small launcher and preserves the vendor worker in `Contents/Helpers/OCRClientProcessReal.app`. The launcher starts that worker with one interposing library, `Contents/Helpers/ScanSnapParentCompat.dylib`.

The library changes only a successful `GetProcessInformation` result for the worker itself when its launcher PSN is `0:0`: it substitutes the PSN for the worker's actual parent, if available. The worker's subsequent parent check is unchanged, so a genuinely dead parent still causes the worker to exit.

The Manager and helper retain their vendor entitlements. The preserved worker also receives the entitlement needed to honor `DYLD_INSERT_LIBRARIES` under the hardened runtime. The modified app and helpers are ad-hoc signed instead of vendor-signed.

## Requirements and limits

The app patch accepts only a stock, PFU-signed ScanSnap Manager 7.2.70, build 1001, with the expected OCR helper and no symlinks inside that helper. It checks the Manager and helper signatures and the helper executable's SHA-256. Other versions and already patched apps are rejected. App paths containing `:` are unsupported.

Run the commands below from this repository on macOS. The patch compiles the launcher and library with `xcrun clang`, so Apple's command-line developer tools are needed. Keep a copy of the original installer before rebuilding it; `app install` makes its own backup of the installed app.

Ad-hoc signing replaces the vendor signature and macOS may ask again for existing file or automation permissions. The patch does not change SIP, privacy settings, or scanner profiles. Installed-app repair leaves the patched bundle owned by the invoking user; the installer path preserves the vendor payload's `root:admin` ownership.

## Repair an installed app

Quit ScanSnap Manager first. Install and restore both refuse to run while any ScanSnap Manager is running. You need write access to the app and its parent directory.

```sh
./scansnap-ocr app install "/Applications/ScanSnap/ScanSnap Manager.app"
```

This patches a sibling copy and replaces the installed app without overwriting the original: it keeps the untouched vendor app at `APP.vendor-backup/Original.app`, where `APP` is the app path supplied to the command. For the command above, the backup is `/Applications/ScanSnap/ScanSnap Manager.app.vendor-backup/Original.app`. An existing backup is never overwritten.

For a disposable, unpacked copy instead, use:

```sh
./scansnap-ocr app stage "/path/to/disposable/ScanSnap Manager.app"
```

Never use `stage` on an installed app. It modifies the copy in place without making a backup, and a failure can leave that copy partially modified.

## Build an installer for a clean install

The vanilla installer is not included. Obtain `MacManagerV72L70WW.dmg` from [PFU](https://origin.pfultd.com/downloads/IMAGE/driver/ss/inst/ix1500/m-software/MacManagerV72L70WW.dmg) or its [Internet Archive listing](https://web.archive.org/web/*/https://origin.pfultd.com/downloads/IMAGE/driver/ss/inst/ix1500/m-software/MacManagerV72L70WW.dmg). Only process installers from a trusted source.

Build a separate image with:

```sh
sudo ./scansnap-ocr package MacManagerV72L70WW.dmg MacManagerV72L70WW-patched.dmg
```

The input is unchanged, and the output must not already exist. A supported flat `.pkg` can also be used as input with a `.pkg` output. The image must contain the PFU-signed flat `ScanSnap Manager.pkg` at its root. Root is required to preserve payload ownership; several gigabytes of free space are needed in both the temporary directory and beside the output.

Alternatively, replace an image in place:

```sh
sudo ./scansnap-ocr package --in-place MacManagerV72L70WW.dmg
```

This first retains the original as `MacManagerV72L70WW.dmg.original` without overwriting an existing backup. In-place replacement requires a filesystem that supports hard links. Thus neither installed-app repair nor installer replacement overwrites its original without retaining a copy; disposable `stage` is the exception described above.

The rebuilt installer is **unsigned and unnotarized** and was **never test-installed**. macOS may require explicit approval to open it. For a clean install, open the rebuilt image and run its `ScanSnap Manager.pkg`. The vendor's installer checks and scripts remain in place, including the refusal to install over an existing 7.2.70 WW Manager. Use installed-app repair in that case.

## After patching

Run a scan with searchable PDF enabled and check that text can be selected or searched in the result. One real scan after patching produced text on both pages. In a separate isolated engine test, the two compressed image streams in the resulting PDF were byte-identical to the input. These observations do not establish that every scan or other OCR failure will work.

## Undo

For installed-app repair, quit ScanSnap Manager and restore the saved vendor app:

```sh
./scansnap-ocr app restore "/Applications/ScanSnap/ScanSnap Manager.app"
```

Restore puts the vendor app back, retains the vendor backup, and saves the displaced patched app under `APP.pre-restore.*/Replaced.app`. For the command above, this is `/Applications/ScanSnap/ScanSnap Manager.app.pre-restore.XXXXXXXX/Replaced.app`. Restore requires the backup made by `app install`; it is not available for a patched app installed from a rebuilt installer.

For the installer path, keep the original installer or the `.original` backup. To return to the vendor app, use the vendor's uninstall and installation procedures with the original installer; the same-version installation refusal still applies.
