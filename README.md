# ScanSnap Manager OCR - macOS Tahoe compatibility shim

> a hack for stubborn users of ScanSnap Manager OCR, who refuse to try anything better. (Until Rosetta is deprecated)

## Why?
No _good_ reason. Just try ScanSnap Home, it probably won't kill you?

If ScanSnap Home doesn't still have secret support for your hardware, consider something like the paths here which also may have better OCR: <https://notes.max.engineer/replacing-scansnap-manager-on-macos/>

## Bug: Carbon is old and so is ScanSnap Manager
ScanSnap Manager 7.2.70.1001 is an Intel application that runs under Rosetta on Apple Silicon.
On macOS 27.2 (26B123), its searchable-PDF OCR hangs and fails.

The OCR client worker uses the deprecated Carbon (2000 CE) process APIs to find and check its launcher. In the observed failure, its launcher process serial number (PSN) is `0:0`, even though its actual parent, OCRControllerProcess, is alive. The worker's parent check fails with `procNotFound` (`-600`), and the worker quits.

## Patch/Wrapper and Installer

The patch replaces the OCR client executable with a small launcher and preserves the vendor worker in `Contents/Helpers/OCRClientProcessReal.app`. The launcher starts that worker with one interposing library, `Contents/Helpers/ScanSnapParentCompat.dylib`.

The library changes only a successful `GetProcessInformation` result for the worker itself when its launcher PSN is `0:0`: it substitutes the PSN for the worker's actual parent, if available. The worker's subsequent parent check is unchanged, so a genuinely dead parent still causes the worker to exit.

The Manager and helper retain their vendor entitlements. The preserved worker also receives the entitlement needed to honor `DYLD_INSERT_LIBRARIES` under the hardened runtime. The modified app and helpers are ad-hoc signed instead of vendor-signed.

## Requirements and limits

The app patch accepts only a stock, PFU-signed ScanSnap Manager 7.2.70, build 1001, with the expected OCR helper and no symlinks inside that helper. It checks the Manager and helper signatures and the helper executable's SHA-256. Other versions and already patched apps are rejected. App paths containing `:` are unsupported.

Run the commands below from this repository on macOS. The patch compiles the launcher and library with `xcrun clang`, so Apple's command-line developer tools are needed. Keep a copy of the original installer before rebuilding it; `app install` makes its own backup of the installed app.

Ad-hoc signing replaces the vendor signature and macOS may ask again for existing file or automation permissions. The patch does not change SIP, privacy settings, or scanner profiles. Installed-app repair leaves the patched bundle owned by the invoking user; the installer path preserves the vendor payload's `root:admin` ownership.

## Patch an existing install

Quit ScanSnap Manager first. Install and restore both refuse to run while any ScanSnap Manager is running. You need write access to the app and its parent directory.

```sh
./scansnap-ocr app install "/Applications/ScanSnap/ScanSnap Manager.app"
```

This patches a sibling copy and replaces the installed app without overwriting the original: it keeps the untouched vendor app at `APP.vendor-backup/Original.app`, where `APP` is the app path supplied to the command. For the command above, the backup is `/Applications/ScanSnap/ScanSnap Manager.app.vendor-backup/Original.app`. An existing backup is never overwritten.

For a disposable, unpacked copy (kinda-destructive) instead, use:

```sh
./scansnap-ocr app stage "/path/to/disposable/ScanSnap Manager.app"
```

Never use `stage` on an installed app. It modifies the copy in place without making a backup, and a failure can leave that copy partially modified.

## Build a patched installer .dmg

The vanilla installer is not included. Obtain `MacManagerV72L70WW.dmg` from [PFU](https://origin.pfultd.com/downloads/IMAGE/driver/ss/inst/ix1500/m-software/MacManagerV72L70WW.dmg) or its [Internet Archive listing](https://web.archive.org/web/*/https://origin.pfultd.com/downloads/IMAGE/driver/ss/inst/ix1500/m-software/MacManagerV72L70WW.dmg).

Build a separate image with:

```sh
sudo ./scansnap-ocr package MacManagerV72L70WW.dmg MacManagerV72L70WW-patched.dmg
```

A supported flat `.pkg` can also be used as input with a `.pkg` output. The image must contain the PFU-signed flat `ScanSnap Manager.pkg` at its root. Root is required to preserve payload ownership; several gigabytes of free space are needed for working space and final output.

Alternatively, replace an image in place:

```sh
sudo ./scansnap-ocr package --in-place MacManagerV72L70WW.dmg
```

This first retains the original as `MacManagerV72L70WW.dmg.original` without overwriting an existing backup. In-place replacement requires a filesystem that supports hard links. Thus neither installed-app repair nor installer replacement overwrites its original without retaining a copy; disposable `stage` is the exception described above.

The rebuilt installer is **unsigned and unnotarized** and untested. You may need to give Gatekeeper approval in macOS Settings. For a clean install, open the rebuilt image and run its `ScanSnap Manager.pkg`.

The stock installer won't overwrite a same-version install, so use installed-app repair if you already have it installed.

## Reverting to stock

For in-place bundle patch, quit ScanSnap Manager and restore the saved vendor app:

```sh
./scansnap-ocr app restore "/Applications/ScanSnap/ScanSnap Manager.app"
```

Restore puts the vendor app back, retains the vendor backup, and saves the displaced patched app under `APP.pre-restore.*/Replaced.app`. For the command above, this is `/Applications/ScanSnap/ScanSnap Manager.app.pre-restore.XXXXXXXX/Replaced.app`. Restore requires the backup made by `app install`; it is not available for a patched app installed from a rebuilt installer.

For the patched-installer path, keep the original installer or the `.original` backup.
To return to the stock app, normal uninstall and then installation with the stock installer.

## License
This was coded by LLM and is thus uncopyrightable.
deepseek v4.1 flash and gpt6.1 terra
