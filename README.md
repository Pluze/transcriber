# Transcriber

A standalone, local macOS app for high-fidelity lecture transcription. Drop any
media file from which FFmpeg can extract an audio stream, choose a model and
receive TXT, SRT, full JSON, logs, and run metadata beside the source file.

## User experience

- No Homebrew or Python is required after installation.
- FFmpeg and whisper.cpp are bundled inside `Transcriber.app`.
- Models are installed, verified, located, and removed from the Models tab.
- Existing models from Lecture Transcriber are detected and imported without
  modifying or deleting the old copy.
- Temporary 16 kHz mono PCM is deleted after every run.

The default `Maximum Fidelity` model prioritizes recognition quality. CPU/GPU
use and multi-file concurrency are selected automatically from the model, queue,
available memory, power mode, and thermal state. Beam/context settings remain
fixed so scheduling does not silently change transcript quality.

Install two or more models to enable **Bench Installed Models**, which runs the
whole queue through every installed model with the same runtime policy.

## Build

Requirements: Apple Silicon Mac, macOS 13.3+, Xcode command-line tools, `curl`,
`make`, and `pkg-config`-free FFmpeg prerequisites included with macOS.

```sh
./scripts/build-ffmpeg.sh
./scripts/build-whisper.sh
./build.sh
./package.sh
```

`package.sh` creates `dist/Transcriber-<version>-macOS-arm64.zip`; its top level
contains only `Transcriber.app`. CI verifies clean source builds without storing
build artifacts; tagged builds publish the app ZIP as a GitHub Release asset.
GitHub automatically provides source archives.

To distribute without Gatekeeper warnings, set `SIGNING_IDENTITY` to a Developer
ID Application certificate and `NOTARY_PROFILE` to a configured notarytool
keychain profile.

## Runtime storage

Models live in `~/Library/Application Support/Transcriber/models`. Outputs are
created beside their source files in a new `<name>.transcript` directory.

## Third-party components

This project bundles whisper.cpp and an LGPL-only FFmpeg build. Notices are in
`ThirdParty/licenses` and are copied into the app bundle. Each tagged GitHub
Release also includes the exact FFmpeg source archive used to build its binary;
the reproducible configure options are recorded in `scripts/build-ffmpeg.sh`.
