<div align="center">
  <img src=".github/assets/icon.png" width="120" height="120" alt="SwiftIPA icon" />

  # SwiftIPA

  An IPA signer that runs on your iPhone (iOS 16+).

</div>

I wanted a signer that feels quick and doesn't get in the way, so I built one. You add your own certificate and provisioning profile, pick an IPA and sign it right on your phone. The signing itself is done by [zsign](https://github.com/zhlynn/zsign), which is compiled into the app.

There's no account and no tracking. The app only goes online when you ask it to: downloading an IPA, loading a source, checking for updates, or installing (more on that below).

## Features

- Change the bundle ID, name, version, build, minimum iOS version, icon and entitlements, or take the bundle ID straight from your certificate's provisioning profile
- The imported IPA stays untouched. Signing always starts from it, so signing again with other settings doesn't stack changes, and you can export the original any time
- Re-signing the same app with the same certificate and settings is almost instant, because the result gets cached
- Fast Packaging (on by default) skips compressing the signed IPA, so signing big apps takes a fraction of the time
- Sign several apps in one go
- Save your favorite settings as presets
- Inject `.dylib` or `.deb` tweaks, right from the sign screen. Every tweak inside a `.deb` is picked up (gzip and xz packages), and tweaks that hook with CydiaSubstrate are pointed at ElleKit automatically once you've imported ElleKit's `.deb`
- Remove extensions, the Watch app or the embedded profile, force file sharing, and a few more tweaks like that
- Add AltStore or ESign sources and pull apps from them
- See when a certificate is about to expire, with a reminder a few days before
- Adding a certificate checks the .p12 password and that the .p12 belongs to the provisioning profile
- If signing fails, Show Log has zsign's full output to copy or share
- Sort the library by name, size, or when an app was added or signed
- Look inside an IPA before signing it (architectures, encryption, linked libraries, extensions)
- Six color themes, English and German
- Report bugs from Settings → Bugs & Issues, which opens a prefilled issue on GitHub

## Installing apps

Tap Install on a signed app and a small bar at the bottom shows what's happening: preparing, waiting for you to confirm the iOS prompt, sending the app, installing. It works on Wi-Fi and on mobile data, and you don't need to install a profile or trust anything first.

How it works: iOS installs apps like this through `itms-services://`, but it only accepts the install manifest from a real HTTPS website. So the app runs a tiny server on your phone that hands out the IPA, and only the manifest (bundle ID, version and a link back to your phone) goes through [api.palera.in](https://api.palera.in), a small public service made for this. Your IPA never leaves your phone.

If you'd rather use something else to install, Export IPA gives you the signed file for AltStore, Sideloadly or TrollStore.

## Download

Every push to `main` builds a new unsigned IPA, see [Releases](https://github.com/xsxs18-dev/SwiftIPA/releases). Sign it once with whatever signer you use now, after that SwiftIPA can re-sign itself.

You can also add it as a source in AltStore, ESign or SwiftIPA itself:

```
https://raw.githubusercontent.com/xsxs18-dev/SwiftIPA/main/altstore-source.json
```

## Screenshots

<p align="center">
  <img src=".github/assets/screenshots/install.png" width="200" alt="Installing an app with the status bar" />
  <img src=".github/assets/screenshots/inspector.png" width="200" alt="IPA inspector" />
  <img src=".github/assets/screenshots/settings.png" width="200" alt="Settings with themes" />
  <img src=".github/assets/screenshots/settings-more.png" width="200" alt="More settings" />
</p>

## Building it yourself

You need a Mac with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and your own signing certificate.

```bash
brew install xcodegen
git clone https://github.com/xsxs18-dev/SwiftIPA.git
cd SwiftIPA
./Scripts/fetch-dependencies.sh
xcodegen generate
open SwiftIPA.xcodeproj
```

The fetch script downloads zsign and the OpenSSL headers into `Vendor/`, which isn't checked in. Both are pinned to fixed versions in the script. The app talks to zsign through one small Objective-C++ file (`ZSignKit/ZSignBridge.mm`), everything else is Swift and SwiftUI.

### With xtool (Linux or macOS)

With [xtool](https://xtool.sh) and its Darwin SDK set up:

```bash
./Scripts/xtool-build.sh            # unsigned IPA in xtool/SwiftIPA.ipa
./Scripts/xtool-build.sh install    # build, sign and install on the connected iPhone
```

This uses `Package.swift` and `xtool.yml`. Release builds still come from `project.yml` on GitHub Actions. The xtool build has no German strings yet, because the String Catalog can't be compiled outside Xcode.

## Known issues

- `.deb` tweaks work with gzip and xz compression. For `zstd` or `bzip2` ones, extract the `.dylib` and import that instead.
- Installing needs api.palera.in to be reachable. If it's down, use Export IPA for now.
- Revoked certificates are only detected through the profile and expiry date, the app doesn't ask Apple directly.
- No special iPad layout yet.

Found a bug or have an idea? Open an issue, I read all of them.

## License

MIT, see [LICENSE](LICENSE).
