# AGENTS.md

Fork of [karansinghgit/speaktype](https://github.com/karansinghgit/speaktype). `main` here = upstream + this fork's patches; build from `main`.

## Build, Sign & Install

Xcode automatic signing is configured for the upstream maintainer's team (`PCV4UMSRZX`) and will fail locally. Build with overrides:

```bash
xcodebuild -project speaktype.xcodeproj -scheme speaktype -configuration Release \
  -derivedDataPath /tmp/speaktype-build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= AD_HOC_CODE_SIGNING_ALLOWED=YES build
```

Install = `ditto` the built .app over `/Applications/speaktype.app`, then **always re-sign**:

```bash
codesign --force --sign "SpeakType Local Dev" /Applications/speaktype.app
```

The re-sign step is load-bearing twice over:

1. The raw build is ad-hoc signed **with hardened runtime**, and ad-hoc + library validation makes dyld refuse the embedded `WhisperKit.framework` — the app crashes at launch (`Library not loaded`). The plain `codesign --force --sign` strips the runtime flag.
2. "SpeakType Local Dev" is a self-signed identity in the login keychain. A *stable* identity keeps TCC grants valid across rebuilds. Do not ship ad-hoc (`-`) signed installs: every rebuild changes the CDHash and silently invalidates Accessibility.

`make install` does NOT do the re-sign step — don't use it as-is.

## TCC / Permission Gotchas

- If the signature identity ever changes, the Accessibility toggle in System Settings still **shows enabled** but `AXIsProcessTrusted` returns false → the app falls back to clipboard-only output instead of pasting. Fix: `tccutil reset Accessibility com.2048labs.speaktype`, relaunch, re-grant.
- Models live in `~/Documents/huggingface/` (non-sandboxed documents dir). `~/Documents` is TCC-protected — terminal/agent processes typically cannot read it, and files copied out of it carry a `com.apple.macl` xattr that keeps blocking access until stripped (`xattr -rc`).

## Compute Units (deliberate divergence from upstream)

`WhisperService` routes the audio encoder and text decoder to `.cpuAndGPU`, not WhisperKit's default Neural Engine. Measured on this hardware (large-v3_turbo, 16s clip, whisperkit-cli): ANE 3m08s vs GPU 56s end-to-end, identical output — ANE's CoreML specialization pass dominates load time. Don't "fix" this back to `ModelComputeOptions()` defaults.

## Fork / Upstream Relationship

- Keep the GitHub fork link: open upstream PRs ([#77](https://github.com/karansinghgit/speaktype/pull/77), [#78](https://github.com/karansinghgit/speaktype/pull/78)) close permanently if the repo leaves the fork network.
- Patches intended for upstream get their own branch off `main` so they can be PR'd independently.

## Debugging

- `MiniRecorderView` writes a timestamped flow log to `/tmp/speaktype_debug.log` (hotkey → record → transcribe) — check it before instrumenting anything.
- Unified logging subsystem is `com.2048labs.speaktype` (`make logs` streams it).
