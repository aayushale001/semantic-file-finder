# Security

## Supported versions

Until the first public release, security fixes target the `main` branch.

After `v0.1.0`, the latest minor release will receive fixes unless the project
states otherwise in the release notes.

## API keys and secrets

Fosvera is a bring-your-own-key app. Never share your Gemini API
key in GitHub issues, screenshots, logs, crash reports, or pull requests.

The macOS app stores the key in Keychain under the established technical service
identifier below. It remains stable so existing tester keys survive the Fosvera
rebrand:

- service: `com.semanticfilefinder.app.gemini-api-key`
- account: `gemini-api-key`

The CLI development path can use `.env`, but `.env` is ignored by Git and must
never be committed.

## Reporting vulnerabilities

If GitHub private vulnerability reporting is enabled for this repository, please
use that. Otherwise, contact the maintainer privately before opening a public
issue for vulnerabilities involving secrets, local file disclosure, signing,
notarization, or code execution.

When reporting, include:

- The app version or commit SHA.
- macOS version.
- Clear reproduction steps.
- The security impact.
- Logs with secrets and private file paths removed.
