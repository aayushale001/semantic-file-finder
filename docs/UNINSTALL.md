# Uninstall Fosvera

This removes the app, local index, logs, settings, and saved Gemini API key.

## Remove the app

Quit Fosvera, then delete the app from `/Applications`:

```bash
rm -rf "/Applications/Fosvera.app"
```

If you installed it somewhere else, delete that copy instead.

## Delete the local index and logs

Fosvera stores its local app data here. The established directory name is kept so
existing tester indexes survive the rebrand:

```text
~/.semantic_file_finder/
```

To remove the index, metadata, and logs:

```bash
rm -rf ~/.semantic_file_finder
```

This cannot be undone. If you reinstall later, you will need to re-index your
folders.

## Remove app preferences

The watched-folder list and view settings are stored in macOS user defaults. The
existing defaults domain is intentionally retained for compatibility:
Remove them with:

```bash
defaults delete com.semanticfilefinder.app
```

If no preferences exist, macOS may print a domain-not-found message. That is
safe.

## Remove the Gemini API key from Keychain

The app stores the Gemini API key as a generic password in the macOS Keychain.
Remove it with:

```bash
security delete-generic-password \
  -s com.semanticfilefinder.app.gemini-api-key \
  -a gemini-api-key
```

If the key is not present, macOS may print an item-not-found message. That is
safe.

The app automatically migrates a readable key from early development builds and
removes that old item when you choose **Remove Key**. If an old item could not be
read without a Keychain prompt, you may also remove it manually:

```bash
security delete-generic-password \
  -s com.semanticfilefinder.gemini-api-key \
  -a gemini
```

## Remove development files

If you cloned the repository for development, you can also remove:

```bash
rm -rf /path/to/VectorBasedFileSearch/.venv
rm -f /path/to/VectorBasedFileSearch/.env
```

Do not run those commands against a repository you still want to develop in.
