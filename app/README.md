<div align="center">

<img src="../docs/icon.png" width="88" alt="Gather Companion icon">

# 📱 Gather Companion

**The phone half of the project.**

</div>

A live event log for your Gather V2 session — who is next to you, who is
following you. It pairs with `gather-app-bridge` running on your computer and
shows what that bridge sees.

*Not affiliated with Gather.*

```sh
flutter run -d <device>
flutter test                     # widget + golden tests
flutter analyze
```

Everything in `lib/` is platform-neutral Flutter over an HTTP/WebSocket contract.
Only the iOS runner is scaffolded so far; `flutter create --platforms=android,windows,linux .`
adds the others.

> [!TIP]
> The full story — protocol, fidelity levels, pairing, limits — is in the
> [root README](../README.md).

## 🎨 Icon

`tool/make_icons.mjs` draws the app icon and writes every size the iOS asset
catalogue asks for into `ios/Runner/Assets.xcassets/AppIcon.appiconset`, the
launch mark on alpha next to it, and the squircled `docs/icon.png` the READMEs
show. It is generated rather than committed as an opaque blob, so the design can
be reviewed and re-rendered — and a new platform means adding its output sizes
here rather than redrawing anything:

```sh
node tool/make_icons.mjs --preview   # also writes tool/icon-preview.png
```
