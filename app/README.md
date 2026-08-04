# Gather Companion

The iOS half of the project: a live event log for your Gather V2 session — who
is next to you, who is following you. It pairs with `gather-v2-bridge` running
on your Mac and shows what that bridge sees.

Not affiliated with Gather.

```sh
flutter run -d "iPhone 17 Pro"   # simulator
flutter test                     # widget + golden tests
flutter analyze
```

The full story — protocol, pairing, limits — is in the [root README](../README.md).

## Icon

`tool/make_icons.mjs` draws the app icon and writes every size in
`ios/Runner/Assets.xcassets/AppIcon.appiconset`. It is generated rather than
committed as an opaque blob, so the design can be reviewed and re-rendered:

```sh
node tool/make_icons.mjs --preview   # also writes tool/icon-preview.png
```
