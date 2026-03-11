# Linux CI Releases

Build release artifacts on Linux and hand them off to App Store Connect with an external uploader.

## Overview

`xtool`'s build, archive, and `.ipa` export flow works cross-platform. The current limitation is the final upload
step: `xtool upload` uses Apple's macOS-only upload tooling.

For Linux CI, the intended split is:

- Use `xtool` to build, sign, archive, and export the app.
- Use an external App Store Connect client, such as
  [App Store Connect CLI (`asc`)](https://github.com/rudrankriyam/App-Store-Connect-CLI), to upload the resulting
  `.ipa` to TestFlight or App Store Connect.

This keeps `xtool` focused on packaging and signing while still supporting an end-to-end Linux release pipeline.

## Prerequisites

- A Linux runner with `xtool` configured and authenticated.
- A signing setup that can successfully produce a distributable app bundle.
- App Store Connect API credentials for your external uploader.

For `asc`, that usually means one of:

- Running `asc auth login` ahead of time.
- Providing `ASC_KEY_ID`, `ASC_ISSUER_ID`, and a private key via environment variables.

## Build an Archive

Create an archive with `xtool`:

```bash
xtool archive --configuration release
```

This writes an `.xcarchive` into `./xtool/` by default.

If you need an explicit destination or product:

```bash
xtool archive --configuration release --destination ios --product MyApp
```

## Export an IPA

Convert the archive into an `.ipa`:

```bash
xtool export xtool/MyApp.xcarchive
```

You can also export directly from an `.app` bundle if needed:

```bash
xtool export xtool/MyApp.app --output xtool/MyApp.ipa
```

## Upload with `asc`

Once you have an `.ipa`, upload it with `asc`:

```bash
asc builds upload --app <APP_ID> --ipa xtool/MyApp.ipa
```

For a TestFlight-oriented end-to-end flow, the `asc` release commands are typically more convenient:

```bash
asc publish testflight --app <APP_ID> --ipa xtool/MyApp.ipa --group <GROUP_ID> --wait
```

Refer to `asc --help` and the `asc publish testflight --help` output for the exact flags you want in CI.

## Suggested CI Shape

A practical Linux CI release job usually looks like:

```bash
xtool archive --configuration release
xtool export xtool/MyApp.xcarchive --output xtool/MyApp.ipa
asc builds upload --app "$ASC_APP_ID" --ipa xtool/MyApp.ipa
```

Or, if you want distribution to happen in the same step:

```bash
xtool archive --configuration release
xtool export xtool/MyApp.xcarchive --output xtool/MyApp.ipa
asc publish testflight --app "$ASC_APP_ID" --ipa xtool/MyApp.ipa --group "$ASC_GROUP_ID" --wait
```

## Scope

This workflow is the current Linux target for release automation:

- `xtool archive` and `xtool export` should remain cross-platform.
- App Store Connect upload and TestFlight distribution can be delegated to external tools.
- `xtool upload` is still useful on macOS, but it is not required for Linux CI parity.
