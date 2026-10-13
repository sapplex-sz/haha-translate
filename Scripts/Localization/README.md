# App localization catalogs

`en.json` is the complete source catalog. The keys are stable Simplified Chinese UI strings; each other language JSON contains the same keys with fully translated values. Simplified Chinese is generated directly from the keys. `delta-*.en.json` preserve the batches used for translation and are not loaded by the app.

Run `python3 Scripts/localize.py --write` to validate every language, then generate `Resources/<locale>.lproj/{Localizable,InfoPlist,ServicesMenu}.strings`. Run without `--write` to check both the source catalog and generated resources. Adding a Swift `L("literal")` key without an English translation or any declared locale translation fails validation. Missing, empty, extra, or incompatible printf arguments also fail. Positional placeholders such as `%2$@` are supported when a translation needs a different argument order.

The `--bootstrap` option is only for early English/Chinese development. It does not certify all declared languages and must not be used as the final release check.

`AppLocalization.shared.language` persists the interface preference separately from translation source/target choices. `system` follows supported preferred languages; an unsupported preference list falls back to English. App-controlled views and menus update live. System permission prompts and Services labels come from the bundle's localized resources and may require the app or the system's service cache to reload.

Do not localize model prompt templates, file names, hashes, URLs, support addresses, or third-party license texts. The original license documents retain their authoritative wording. Locale coverage checks do not certify native-speaker review or translation output quality.
