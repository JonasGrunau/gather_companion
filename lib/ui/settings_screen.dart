/// Everything the app can tell you about itself, and the two switches it owns.
///
/// This was a `PopupMenuButton` with two items hidden behind an overflow icon on
/// the feed. That was the right size for it when there was one screen and no
/// room, but a menu is a bad place for anything you might want to *read* — it
/// closes when you look away, and it can only hold verbs. The state that
/// actually matters here is nouns: whether Gather is connected, which space you
/// are in, which computer is paired, whether that computer can still wake the
/// app for a notification. None of that fitted in a menu, so none of it was
/// shown anywhere.
///
/// Nothing on this screen is a preference. The two real preferences the app has
/// — `Notifier.notifyOnFollow` and `Notifier.notifyOnGather` — are deliberately
/// absent, because they are plain fields with no persistence behind them: a
/// switch wired to one would forget itself on the next launch, which is worse
/// than not offering it. Persisting them is the change that earns them a row.
library;

import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/link_status.dart';
import '../theme/gather_theme.dart';
import 'media_check_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state, required this.onUnpair});

  final AppState state;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final link = state.link;
    final space = state.spaceName;

    // Four states, four sentences. `needsPairing` is kept apart from `retrying`
    // for the same reason the link strip keeps them apart: one asks you to wait
    // and the other asks you to act.
    final (status, detail, tint) = link.needsPairing
        ? ('Signed out', 'Gather signed this device out. Pair again to reconnect.', t.danger)
        : switch (link.state) {
            LinkState.live => ('Connected', space == null ? 'Talking to Gather.' : 'In $space.', t.ok),
            LinkState.connecting => ('Connecting', 'Opening a connection to Gather.', t.warn),
            LinkState.retrying => ('Reconnecting', link.detail ?? 'The connection dropped. Trying again.', t.danger),
            LinkState.idle => ('Not connected', 'Nothing is listening to Gather right now.', t.faint),
          };

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        title: const Text('Settings'),
        titleTextStyle: Theme.of(context).textTheme.titleLarge,
      ),
      // `top: false` because the AppBar has already taken the notch; the bottom
      // inset is the nav rail, which the shell put there.
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const _SectionLabel('Gather'),
            _Card(children: [
              _Row(
                icon: link.isLive ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                tint: tint,
                title: status,
                subtitle: detail,
              ),
              _Row(
                icon: Icons.refresh_rounded,
                title: 'Reconnect',
                subtitle: 'Drop the connection and open it again.',
                onTap: state.reconnect,
              ),
            ]),
            const _SectionLabel('This phone'),
            _Card(children: [
              _Row(
                icon: Icons.mic_rounded,
                title: 'Mic & camera',
                subtitle: 'Check that they work before you need them.',
                goes: true,
                // Pushed, never a tab: the check opens the hardware in
                // `initState` and holds it until it is disposed, so it has to be
                // a screen you leave rather than one that sits behind another.
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const MediaCheckScreen()),
                ),
              ),
            ]),
            const _SectionLabel('Paired computer'),
            _Card(children: [
              _Row(
                icon: Icons.computer_rounded,
                title: state.bridgeName ?? 'Paired',
                // The bridge stopped relaying presence when the phone started
                // talking to Gather itself. Saying what it is still *for* is more
                // use than a hostname on its own.
                // Untinted on purpose: `tint` colours the whole row, and an
                // orange computer name reads as the computer being wrong rather
                // than as it being unreachable. The sentence carries it.
                subtitle: state.canBeWoken
                    ? 'Can wake this app when something happens.'
                    : 'Unreachable — pushed notifications may not arrive.',
              ),
              _Row(
                icon: Icons.link_off_rounded,
                title: 'Forget this computer',
                subtitle: 'Sign out of Gather and start again from the QR code.',
                tint: t.danger,
                onTap: onUnpair,
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      // Text outside a card indents to `kTextGutter` so it lines up with the
      // carded content rather than with the screen edge.
      padding: const EdgeInsets.fromLTRB(kTextGutter, 20, kTextGutter, 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.faint),
      ),
    );
  }
}

/// The same surface the media check draws its preview on: card fill, hairline
/// border, `t.radius`, clipped so the rows' ink stays inside the corners.
class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: kGutter),
      decoration: BoxDecoration(
        color: t.card,
        border: Border.all(color: t.border),
        borderRadius: BorderRadius.circular(t.radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(color: t.border, height: 1, thickness: 1),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// One line of the list, in three kinds: a fact, an action, and a way out of
/// here.
///
/// The chevron marks only the third. It was on every tappable row first, which
/// put one next to "Reconnect" and one next to "Forget this computer" — neither
/// of which goes anywhere, and a chevron is a promise of somewhere to go. The
/// verbs carry those two on their own.
class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.tint,
    this.goes = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? tint;

  /// Whether the tap opens another screen, rather than doing something here.
  final bool goes;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final colour = tint ?? t.mutedForeground;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          child: Row(
            children: [
              Icon(icon, size: 20, color: colour),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: tint ?? t.foreground,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 12.5, height: 1.35, color: t.faint),
                    ),
                  ],
                ),
              ),
              if (goes) ...[
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, size: 20, color: t.faint),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
