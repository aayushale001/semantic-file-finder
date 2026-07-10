# Gemini API Key Setup

Fosvera is bring-your-own-key. The open-source project does not ship
with a shared Gemini API key.

## Get a key

1. Open [Google AI Studio](https://aistudio.google.com/apikey).
2. Sign in with the Google account/project you want to use.
3. Create or copy a Gemini API key.
4. Keep the key private. Do not paste it into GitHub issues, screenshots, logs,
   or commits.

Google may offer a free tier, but quota, rate limits, billing, and model access
belong to your Google project.

## Save the key in the macOS app

1. Open Fosvera.
2. Open Settings with the gear button.
3. Paste your Gemini API key.
4. Click **Save & Test**.

The app validates the key with a lightweight Gemini metadata call and stores it
in the macOS Keychain. It is not written to a plaintext config file by the app.
If Gemini is offline or rate-limited during this check, the app keeps the key and
shows it as temporarily unverified instead of deleting it.

## CLI / development setup

For terminal-only development, copy the example environment file:

```bash
cp .env.example .env
```

Then edit `.env`:

```bash
GEMINI_API_KEY=your_api_key_here
```

`.env` is intentionally ignored by Git. Never commit a real API key.

The macOS app ignores `.env` by default and uses the Keychain key saved through
Settings. `.env` is for CLI/dev-helper commands.

During local app development only, you can temporarily allow environment/`.env`
keys by launching the app with:

```bash
SFF_ALLOW_APP_ENV_API_KEY=1 swift run --package-path macos-app
```

Do not use that override for release builds.

## Rotate or remove the key

If you think the key leaked, revoke or rotate it from Google AI Studio.

To remove the local Keychain copy from Terminal (the service identifier is kept
stable for compatibility with existing tester builds):

```bash
security delete-generic-password \
  -s com.semanticfilefinder.app.gemini-api-key \
  -a gemini-api-key
```

You can also remove the key from the app's Settings screen.

If you used early development builds before the first release, you can also
remove the old development Keychain item:

```bash
security delete-generic-password \
  -s com.semanticfilefinder.gemini-api-key \
  -a gemini
```
