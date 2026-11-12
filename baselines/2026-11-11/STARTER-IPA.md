# TrapTube Starter IPA Baseline

**Status:** Pinned starter baseline  
**Pinned on:** 2026-11-11  
**Purpose:** Use this build as the starting point for all subsequent TrapTube improvements unless a newer baseline is explicitly approved.

## Exact build identity

- Repository: `vulturefilezexclusive-svg/YTPlus-Reference-Analysis`
- Source branch at build time: `feature/traptube-ytplus-native-rebrand`
- Source commit: `869242416c52a18afebecc04852737e7e6c4a98b`
- Baseline pin branch: `starter/traptube-ipa-2026-11-11`
- GitHub Actions workflow run: [43066854840](https://github.com/vulturefilezexclusive-svg/YTPlus-Reference-Analysis/actions/runs/43066854840)
- Workflow result: `completed / success`
- Workflow artifact ID: `13876980602`
- Workflow artifact name: `traptube-ytplus-branding-theme-trial-v1`
- Artifact ZIP: `TrapTube-Trial-Build.zip`
- Artifact ZIP SHA-256: `dd9269fbb270d38e50e01a4fd39f29d2acb833dfb8ec244d7f20019d0b5e5d19`
- IPA filename: `TrapTube-YTPlus-Branding-Theme-Trial.ipa`
- IPA SHA-256: `45638cfa7ce434e3206d0ca52d86c2d96019c875783472def7e6fcb66dfc2c37`
- IPA archive validation: `unzip -t` passed; no compressed-data errors were reported.

## Baseline handling rules

1. Treat source commit `869242416c52a18afebecc04852737e7e6c4a98b` as the known-good source starting point.
2. Start future improvement work from this pinned commit/branch, not from older trial branches or unrelated builds.
3. Preserve existing host integration, branding, launch-screen work, and StemKit changes unless a change is intentional and verified.
4. For every new trial, record its source commit, Actions run, IPA SHA-256, and archive-validation result.
5. Compare each new trial against this baseline and report regressions separately from newly implemented features.
6. Do not describe a successful CI build as proof of on-device runtime behavior. The pinned IPA passed CI and archive-integrity checks; device installation and runtime behavior remain separate validation steps.

## Important artifact note

The IPA is preserved in the GitHub Actions artifact associated with run 43066854840. Actions artifacts are subject to the repository's artifact-retention policy and may expire. The hashes and source provenance recorded here remain the reference identity even if the downloadable workflow artifact later expires. A permanent GitHub Release asset or binary stored in a durable release location has not been created by this manifest.

## Build artifact access

- [Successful build and downloadable artifact](https://github.com/vulturefilezexclusive-svg/YTPlus-Reference-Analysis/actions/runs/43066854840)
- [Pinned source commit](https://github.com/vulturefilezexclusive-svg/YTPlus-Reference-Analysis/commit/869242416c52a18afebecc04852737e7e6c4a98b)
