# Releasing QuickChat

QuickChat releases are manually started from `main`. The workflow tests the app, signs it with Developer ID, submits it to Apple for notarization, staples the ticket, and creates a **draft** GitHub release. Review the generated notes and publish the draft when ready. The ZIP supports Apple silicon and macOS 14 or later.

## One-time setup

Add these repository Actions secrets:

- `APPLE_CERTIFICATE`: base64-encoded Developer ID Application `.p12` file, including its private key.
- `APPLE_CERTIFICATE_PASSWORD`: the `.p12` export password.
- `APPLE_NOTARY_KEY`: the complete App Store Connect API private key (`.p8`), including its PEM boundaries.
- `APPLE_NOTARY_KEY_ID`: the API key ID.
- `APPLE_NOTARY_ISSUER_ID`: the API issuer ID.

The API key needs access to Apple notarization. Keep private keys out of Git and restrict repository administration. The runner imports the certificate into a temporary keychain. GitHub-hosted runners are ephemeral.

## Make a release

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, and merge the change to `main`. Use a new stable version in `X.Y.Z` form.
2. In GitHub Actions, run **Release** on `main`, entering the same version without `v`.
3. Review the draft release notes and signed ZIP. Publish the draft when ready.

The release tag is created at the tested commit only after notarization succeeds. Notes are generated from commits since the last tag by git-cliff, including commits that do not follow Conventional Commits. Edit the draft notes for clarity before publication. The checksum detects accidental corruption; Apple code signing and notarization authenticate the app.

If a run fails, inspect its log and Apple's notarization log before retrying. If a draft or tag already exists, inspect it before removing or replacing anything; the workflow refuses an existing tag. Do not rerun against a different commit under the same version.
