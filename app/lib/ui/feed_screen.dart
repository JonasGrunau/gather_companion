import 'package:flutter/material.dart';
import 'package:gather_events/gather_events.dart';

import '../src/app_state.dart';
import '../src/bridge_client.dart';
import '../src/relevance.dart';
import '../theme/gather_theme.dart';

/// The main screen: who is around you now, and what has happened.
///
/// The split is deliberate. The top of the screen answers a question you have
/// *right now* — is anyone next to me, is anyone following me — from the bridge's
/// snapshot, which is authoritative and does not depend on having been running.
/// The list underneath is history, and only carries what is worth reading; the
/// background tier is a tap away rather than mixed in.
class FeedScreen extends StatelessWidget {
  const FeedScreen({super.key, required this.state, required this.onUnpair});

  final AppState state;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final feed = state.feed;

    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(state: state, onUnpair: onUnpair),
            if (!state.link.isLive) _LinkStrip(status: state.link),
            Expanded(
              child: RefreshIndicator(
                color: t.brand,
                backgroundColor: t.card,
                onRefresh: () async => state.reconnect(),
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    _AroundYou(state: state),
                    if (feed.isEmpty)
                      _EmptyFeed(connected: state.link.isLive)
                    else ...[
                      const _SectionLabel('Activity'),
                      for (final entry in feed)
                        _EventRow(
                          event: entry.event,
                          look: entry.look,
                          state: state,
                        ),
                    ],
                    _BackgroundToggle(state: state),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.state, required this.onUnpair});

  final AppState state;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final subtitle = state.bridgeName ?? state.settings.host;

    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 10, kGutter - 6, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Flexible because the name is long enough to crowd the
                    // header buttons on a 320pt phone.
                    Flexible(
                      child: Text(
                        'Gather Companion',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _LiveDot(live: state.link.isLive),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: t.faint),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: state.reconnect,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.refresh_rounded, color: t.mutedForeground, size: 21),
            tooltip: 'Reconnect',
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_horiz_rounded, color: t.mutedForeground),
            color: t.popover,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(t.radius),
              side: BorderSide(color: t.border),
            ),
            onSelected: (value) {
              switch (value) {
                case 'everything':
                  state.setShowEverything(!state.showEverything);
                case 'clear':
                  state.clearLog();
                case 'unpair':
                  onUnpair();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'everything',
                child: Text(
                  state.showEverything ? 'Show only what matters' : 'Show everything',
                ),
              ),
              const PopupMenuItem(value: 'clear', child: Text('Clear activity')),
              const PopupMenuItem(value: 'unpair', child: Text('Forget this Mac')),
            ],
          ),
        ],
      ),
    );
  }
}

class _LiveDot extends StatelessWidget {
  const _LiveDot({required this.live});

  final bool live;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: live ? t.ok : t.faint,
        shape: BoxShape.circle,
        boxShadow: live
            ? [BoxShadow(color: t.ok.withValues(alpha: 0.5), blurRadius: 6, spreadRadius: 1)]
            : null,
      ),
    );
  }
}

/// Only present when the link is unhealthy — no permanent "connected" chrome
/// taking up a row.
class _LinkStrip extends StatelessWidget {
  const _LinkStrip({required this.status});

  final LinkStatus status;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final (text, tint) = switch (status.state) {
      LinkState.connecting => ('Connecting to the bridge…', t.warn),
      LinkState.retrying => ('Reconnecting…', t.danger),
      _ => ('Not connected', t.faint),
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(kGutter, 0, kGutter, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(t.radius - 2),
        border: Border.all(color: tint.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: tint),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, color: tint),
            ),
          ),
        ],
      ),
    );
  }
}

/// The answer to "who is around me", from the snapshot rather than from history.
class _AroundYou extends StatelessWidget {
  const _AroundYou({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final followers = state.followers;
    final nearby = state.nearby;

    return Padding(
      padding: const EdgeInsets.fromLTRB(kGutter, 4, kGutter, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (followers.isNotEmpty) ...[
            _FollowerCard(followers: followers),
            const SizedBox(height: 10),
          ],
          Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
            decoration: BoxDecoration(
              color: t.card,
              borderRadius: BorderRadius.circular(t.radius),
              border: Border.all(color: t.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.person_pin_circle_rounded,
                      size: 16,
                      color: nearby.isEmpty ? t.faint : t.brandSoft,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      nearby.isEmpty ? 'Nobody next to you' : 'Next to you',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                        color: nearby.isEmpty ? t.faint : t.mutedForeground,
                      ),
                    ),
                    const Spacer(),
                    if (nearby.isNotEmpty)
                      Text(
                        '${nearby.length}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: t.mutedForeground,
                        ),
                      ),
                  ],
                ),
                if (nearby.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [for (final person in nearby) _PersonChip(person: person)],
                  ),
                ],
                if (!state.hasRichData) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Log-only mode: no names, and being followed can only be '
                    'guessed. Run gather-app-bridge doctor on your Mac to turn the '
                    'rest on.',
                    style: TextStyle(fontSize: 11.5, height: 1.45, color: t.faint),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Being followed is the one thing this app exists to tell you, so it gets the
/// only saturated surface on the screen.
class _FollowerCard extends StatelessWidget {
  const _FollowerCard({required this.followers});

  final List<PlayerRef> followers;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final single = followers.length == 1;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 15),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [t.brand, t.brand.withValues(alpha: 0.72)],
        ),
        borderRadius: BorderRadius.circular(t.radius),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.directions_walk_rounded, color: Colors.white, size: 21),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  single
                      ? '${followers.first.label} is following you'
                      : '${followers.length} people are following you',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  single
                      ? _since(followers.first.followingMeSince)
                      : followers.map((f) => f.label).join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _since(DateTime? at) {
    if (at == null) return 'right now';
    final delta = DateTime.now().difference(at);
    if (delta.inSeconds < 60) return 'just started';
    if (delta.inMinutes < 60) return 'for ${delta.inMinutes} min';
    return 'for ${delta.inHours}h';
  }
}

class _PersonChip extends StatelessWidget {
  const _PersonChip({required this.person});

  final PlayerRef person;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 11, 4),
      decoration: BoxDecoration(
        color: t.secondary,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Avatar(id: person.id, label: person.label, size: 22),
          const SizedBox(width: 8),
          Text(
            person.label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: t.foreground),
          ),
          if (person.screensharing) ...[
            const SizedBox(width: 6),
            Icon(Icons.screen_share_rounded, size: 13, color: t.brandSoft),
          ] else if (person.micOn == false) ...[
            const SizedBox(width: 6),
            Icon(Icons.mic_off_rounded, size: 13, color: t.faint),
          ],
        ],
      ),
    );
  }
}

/// A person, as a coloured initial. Stable per id, so the same face keeps the same
/// colour without the bridge having to send one.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.id, required this.label, this.size = 30});

  final String id;
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colour = avatarColor(id);
    final initial = label.trim().isEmpty ? '?' : label.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.44,
          fontWeight: FontWeight.w700,
          color: Colors.white,
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
      padding: const EdgeInsets.fromLTRB(kTextGutter, 20, kTextGutter, 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: t.faint,
        ),
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.look, required this.state});

  final GatherEvent event;
  final EventLook look;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final alert = look.isAlert;
    final ambient = look.relevance == Relevance.ambient;

    return Container(
      margin: const EdgeInsets.fromLTRB(kGutter, 0, kGutter, 6),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
      decoration: BoxDecoration(
        color: alert ? t.brand.withValues(alpha: 0.13) : t.card,
        borderRadius: BorderRadius.circular(t.radius - 2),
        border: Border.all(
          color: alert ? t.brand.withValues(alpha: 0.45) : t.border,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (look.subject != null)
            _Avatar(id: look.subject!, label: state.nameFor(look.subject!))
          else
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.secondary,
                shape: BoxShape.circle,
                border: Border.all(color: t.border),
              ),
              child: Icon(look.icon, size: 15, color: t.mutedForeground),
            ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (look.subject != null) ...[
                      Icon(
                        look.icon,
                        size: 13,
                        color: alert ? t.brandSoft : t.faint,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        look.title,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.25,
                          fontWeight: alert ? FontWeight.w700 : FontWeight.w500,
                          color: ambient ? t.mutedForeground : t.foreground,
                        ),
                      ),
                    ),
                  ],
                ),
                if (look.detail != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    look.detail!,
                    style: TextStyle(fontSize: 12, height: 1.35, color: t.faint),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _clock(event.at),
            style: TextStyle(
              fontSize: 11,
              color: t.faint,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _BackgroundToggle extends StatelessWidget {
  const _BackgroundToggle({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hidden = state.hiddenCount;
    if (!state.showEverything && hidden == 0) return const SizedBox(height: 8);

    return Padding(
      padding: const EdgeInsets.fromLTRB(kGutter, 14, kGutter, 4),
      child: TextButton.icon(
        onPressed: () => state.setShowEverything(!state.showEverything),
        icon: Icon(
          state.showEverything ? Icons.filter_list_off_rounded : Icons.filter_list_rounded,
          size: 17,
          color: t.mutedForeground,
        ),
        label: Text(
          state.showEverything
              ? 'Hide background activity'
              : 'Show $hidden background ${hidden == 1 ? 'event' : 'events'}',
          style: TextStyle(fontSize: 13, color: t.mutedForeground),
        ),
      ),
    );
  }
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 44, kTextGutter, 20),
      child: Column(
        children: [
          Icon(Icons.check_circle_outline_rounded, size: 28, color: t.faint),
          const SizedBox(height: 14),
          Text(
            // Not "Not connected": the strip above already says that, and saying
            // it twice on one screen reads as a stutter rather than as emphasis.
            connected ? 'All quiet' : 'No activity yet',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: t.mutedForeground),
          ),
          const SizedBox(height: 6),
          Text(
            connected
                ? 'Nothing worth interrupting you for. Anyone walking up to you, or '
                    'following you, shows up here.'
                : 'Waiting for the bridge on your Mac.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.5, color: t.faint),
          ),
        ],
      ),
    );
  }
}

String _clock(DateTime at) {
  final local = at.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
