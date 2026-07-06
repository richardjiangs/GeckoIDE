# GeskoIDE

GeskoIDE is an offline code editor with the Gecko Dark theme. This repository includes the original macOS `.command` app, a corrected Android APK build, and the GitHub Pages download site.

## Downloads

- macOS: `GeskoIDE.command`
- Android: `GeskoIDE.apk`

## Open GeskoIDE.command on Mac

Open Terminal and run:

```sh
cd ~/Downloads
chmod +x "GeskoIDE.command"
xattr -d com.apple.quarantine "GeskoIDE.command"
./"GeskoIDE.command"
```

## Install GeskoIDE.apk on Android

Download `GeskoIDE.apk` on your Android device, open it, and allow installation from your browser or file manager when Android asks.

The Android edition is a native offline editor with Gecko Dark styling, open/save through Android document picker, syntax coloring, templates, and quick fixes. This APK restores the smaller stable Android startup UI while keeping the same 24 language definitions and skeleton templates as the `.command` app: Python, JavaScript, TypeScript, HTML, CSS, JSON, Markdown, C, C++, C#, Java, Go, Rust, Ruby, PHP, Shell, Swift, Kotlin, Lua, SQL, YAML, AppleScript, Perl, and Plain Text.

Run works offline in the APK for Python through bundled Pyodide/CPython WebAssembly, Go through bundled Yaegi WebAssembly, JavaScript and basic TypeScript through the bundled WebView runner, SQL through Android SQLite, Shell through Android `/system/bin/sh`, and HTML/CSS/Markdown/JSON through in-app preview or validation. Other compiled languages are edited and checked honestly; the APK does not fake a run when a compiler/runtime is not bundled. See `THIRD_PARTY_NOTICES.md` for bundled runtime notices.

The macOS `.command` edition contains the full Python/Tkinter desktop IDE, a hover right-edge scrollbar, the same Outline navigator, and can run its built-in self-test with:

```sh
python3 GeskoIDE.command --selftest
```

## Build the APK

The APK can be rebuilt on a Mac with Android Studio installed:

```sh
./android/build-tools/build_apk.sh
```

The script uses Android Studio's bundled JDK, the local Android SDK, and the checked-in GeskoIDE signing key, then writes `GeskoIDE.apk` at the repository root.

## Support

Bitcoin address:

```text
1G3owA2kPUuYS45XGyj8p8M3kgdHQzePBs
```

The donation QR code is included as `bitcoin-qr.jpg`.
