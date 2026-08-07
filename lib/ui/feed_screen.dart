import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:gather_events/gather_events.dart';

import '../src/app_state.dart';
import '../src/link_status.dart';
import '../theme/gather_theme.dart';

/// The main screen: who is following you, right now.
///
/// It used to be two things — that answer at the top, and a scrolling history of
/// everything that had happened underneath. The history is gone. It was worth
/// keeping while the bridge held a 500-event ring on a computer that was awake all
/// day; once the app started talking to Gather itself, the log could only record
/// what happened while the app was open, which is the one window in which you were
/// already looking at the screen. A list that is empty exactly when you need it and
/// full of things you already saw otherwise is not history, it is furniture.
///
/// What that history was *for* survives as push notifications, which arrive whether
/// the app is open or not. So the screen is now only the questions it can actually
/// answer live: who is following you, and whether the party is on.
class FeedScreen extends StatelessWidget {
  const FeedScreen({super.key, required this.state, required this.onUnpair});

  final AppState state;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(state: state, onUnpair: onUnpair),
            _LinkStrip(status: state.link),
            Expanded(
              child: RefreshIndicator(
                color: t.brand,
                backgroundColor: t.card,
                onRefresh: state.reconnect,
                child: CustomScrollView(
                  // The screen is shorter than the viewport now, so without this
                  // there is nothing to over-scroll and pull-to-refresh silently
                  // does nothing.
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(child: _AroundYou(state: state)),
                    SliverToBoxAdapter(child: _PartyCard(state: state)),
                    const SliverToBoxAdapter(child: SizedBox(height: 32)),
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
                case 'unpair':
                  onUnpair();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'unpair', child: Text('Forget this computer')),
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
///
/// Stateful for one reason: *when* to appear. A healthy launch walks
/// idle → connecting → live in well under a second, and a banner that inserts a
/// row and removes it again in that window shoves the whole feed down and back
/// — the jump reads as a glitch, not as information. So an unhealthy link has to
/// persist past [_grace] before it earns the space, and the row animates in
/// rather than appearing between two frames. Recovery is instant: nobody needs
/// easing on good news.
class _LinkStrip extends StatefulWidget {
  const _LinkStrip({required this.status});

  final LinkStatus status;

  @override
  State<_LinkStrip> createState() => _LinkStripState();
}

class _LinkStripState extends State<_LinkStrip> {
  static const _grace = Duration(milliseconds: 600);

  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_LinkStrip old) {
    super.didUpdateWidget(old);
    if (old.status.state != widget.status.state) _sync();
  }

  void _sync() {
    if (widget.status.isLive) {
      _timer?.cancel();
      _timer = null;
      if (_visible) setState(() => _visible = false);
      return;
    }
    if (_visible || _timer != null) return;
    _timer = Timer(_grace, () {
      if (!mounted) return;
      setState(() {
        _visible = true;
        _timer = null;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: _visible
          ? _LinkStripBody(status: widget.status)
          : const SizedBox(width: double.infinity),
    );
  }
}

class _LinkStripBody extends StatelessWidget {
  const _LinkStripBody({required this.status});

  final LinkStatus status;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // A dead credential is the one state here that asks the user to *do* something,
    // so it gets sentence and loses the spinner. Everything else is us working on it.
    final (text, tint) = status.needsPairing
        ? ('Gather signed this device out — pair again', t.danger)
        : switch (status.state) {
            LinkState.connecting => ('Connecting to Gather…', t.warn),
            LinkState.retrying => ('Reconnecting to Gather…', t.danger),
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
          if (!status.needsPairing)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: tint),
            )
          else
            Icon(Icons.link_off_rounded, size: 13, color: tint),
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

/// The answer to "is anyone following me", from the snapshot rather than from
/// history.
///
/// This used to be two cards — one for who was standing next to you, one for who
/// was following. Being near somebody says nothing about whether they want you,
/// so only the second question survived, and it now holds the slot on its own.
class _AroundYou extends StatelessWidget {
  const _AroundYou({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kGutter, 4, kGutter, 4),
      child: _FollowerCard(followers: state.followers),
    );
  }
}

/// The one control on the screen, and the only thing here that writes to Gather.
///
/// Everything else in this app watches. This teleports your avatar to a random
/// tile four times a second, which is silly on purpose — so it is allowed the one
/// piece of motion in an interface that otherwise deliberately sits still. The
/// gradient turns only while it is actually hopping: an animation that runs when
/// nothing is happening is decoration, and this one is a status light.
///
/// It reads [AppState.partyMode] rather than any local flag, so it goes dark by
/// itself when the bridge stops — on its own timer, or because it lost Gather.
class _PartyCard extends StatefulWidget {
  const _PartyCard({required this.state});

  final AppState state;

  @override
  State<_PartyCard> createState() => _PartyCardState();
}

class _PartyCardState extends State<_PartyCard> with SingleTickerProviderStateMixin {
  /// Slow enough to read as a drift rather than a strobe. This sits on a screen
  /// someone may leave open.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  );

  bool _reduceMotion = false;

  /// The palette opens and closes on Gather's own accent so the sweep meets
  /// itself: a gradient whose ends differ shows a seam every time it comes round.
  static const _palette = [
    Color(0xFF4257DA),
    Color(0xFF7B3FE4),
    Color(0xFFD33EF7),
    Color(0xFFE0A22F),
    Color(0xFF3FBF87),
    Color(0xFF2C86C4),
    Color(0xFF4257DA),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(_PartyCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Ties the controller to the bridge's answer, and stops it otherwise — a
  /// ticker left running behind a switched-off card costs a rebuild every frame
  /// for something nobody can see.
  void _sync() {
    final on = widget.state.partyMode && !_reduceMotion;
    if (on && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!on && _spin.isAnimating) {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (widget.state.partyPending) return;
    final on = !widget.state.partyMode;
    final error = await widget.state.setPartyMode(on);
    if (error == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final on = widget.state.partyMode;
    final party = widget.state.party;

    // While it is hopping, a reason means it is *not* hopping this moment — a
    // corner it has been backed into rather than a fault. Standing still is the
    // correct behaviour there, so it is reported plainly instead of as an error.
    final subtitle = switch ((on, party.detail)) {
      (true, final String why) => why,
      (true, _) => 'Hopping four times a second, nowhere near anyone',
      (false, final String why) => why,
      _ => 'Teleport around the map, never next to anyone',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(kGutter, 6, kGutter, 2),
      child: AnimatedBuilder(
        animation: _spin,
        builder: (context, child) {
          final phase = _spin.value;
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(t.radius),
              color: on ? null : t.card,
              border: on ? null : Border.all(color: t.border),
              gradient: on
                  ? LinearGradient(
                      colors: _palette,
                      transform: GradientRotation(phase * 2 * math.pi),
                    )
                  : null,
              boxShadow: on
                  ? [
                      BoxShadow(
                        color: _palette[1].withValues(alpha: 0.34),
                        blurRadius: 24,
                        spreadRadius: -6,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: child,
          );
        },
        // Built once and handed to the builder: only the decoration depends on
        // the animation, so the row underneath has no business rebuilding sixty
        // times a second.
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(t.radius),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(13, 13, 14, 13),
              child: Row(
                children: [
                  _PartyGlyph(spin: _spin, on: on),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Party mode',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                                color: on ? Colors.white : t.foreground,
                              ),
                            ),
                            if (on && party.hops > 0) ...[
                              const SizedBox(width: 8),
                              Text(
                                '${party.hops}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white.withValues(alpha: 0.75),
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: on ? Colors.white.withValues(alpha: 0.86) : t.faint,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _PartySwitch(on: on, pending: widget.state.partyPending),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The disco ball. Wobbles rather than spins — a full rotation on a round icon
/// is invisible, and a tilt back and forth reads as bouncing.
class _PartyGlyph extends StatelessWidget {
  const _PartyGlyph({required this.spin, required this.on});

  final Animation<double> spin;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AnimatedBuilder(
      animation: spin,
      builder: (context, child) {
        final wobble = on ? math.sin(spin.value * 2 * math.pi) : 0.0;
        return Transform.rotate(
          angle: wobble * 0.22,
          child: Transform.scale(scale: 1 + wobble.abs() * 0.08, child: child),
        );
      },
      child: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? Colors.white.withValues(alpha: 0.2) : t.secondary,
          shape: BoxShape.circle,
          border: on ? null : Border.all(color: t.border),
        ),
        child: Icon(
          Icons.celebration_rounded,
          size: 20,
          color: on ? Colors.white : t.mutedForeground,
        ),
      ),
    );
  }
}

/// A switch drawn by hand rather than a `Switch`, because Material's fills its
/// own track colour and would fight the gradient behind it.
class _PartySwitch extends StatelessWidget {
  const _PartySwitch({required this.on, required this.pending});

  final bool on;

  /// A tap that has not reached the computer yet. Shown as a dimmed knob so the
  /// button reads as "heard you" rather than as finished.
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: 44,
      height: 26,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: on ? Colors.white.withValues(alpha: 0.28) : t.secondary,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: on ? Colors.white.withValues(alpha: 0.4) : t.border,
        ),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Opacity(
          opacity: pending ? 0.55 : 1,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: on ? Colors.white : t.faint,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

/// Being followed is the one thing this app exists to tell you, so it gets the
/// only saturated surface on the screen — and, when nobody is, the quietest.
///
/// It is always on screen either way. An empty slot reads as the app being
/// broken; "nobody is following you" is an answer, and the difference between
/// the two is the whole reason anyone opens this.
class _FollowerCard extends StatelessWidget {
  const _FollowerCard({required this.followers});

  final List<PlayerRef> followers;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final empty = followers.isEmpty;
    final single = followers.length == 1;

    // Chips repeat the name for a lone silent follower, whose name the title
    // already carries. They earn their place when there is more than one, or
    // when somebody is talking — which the title cannot say.
    final showChips = followers.length > 1 || followers.any((f) => f.speaking);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 15),
      decoration: BoxDecoration(
        color: empty ? t.card : null,
        gradient: empty
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [t.brand, t.brand.withValues(alpha: 0.72)],
              ),
        borderRadius: BorderRadius.circular(t.radius),
        border: empty ? Border.all(color: t.border) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: empty ? t.secondary : Colors.white.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.directions_walk_rounded,
                  color: empty ? t.faint : Colors.white,
                  size: 21,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      switch (followers.length) {
                        0 => 'Nobody is following you',
                        1 => '${followers.first.label} is following you',
                        final n => '$n people are following you',
                      },
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: empty ? t.mutedForeground : Colors.white,
                      ),
                    ),
                    if (single) ...[
                      const SizedBox(height: 2),
                      Text(
                        _since(followers.first.followingMeSince),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (showChips) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final person in followers) _PersonChip(person: person, onBrand: true),
              ],
            ),
          ],
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
  const _PersonChip({required this.person, this.onBrand = false});

  final PlayerRef person;

  /// Drawn on the follower card's saturated gradient rather than a plain
  /// surface, so it borrows white translucency instead of the theme's greys.
  final bool onBrand;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 11, 4),
      decoration: BoxDecoration(
        color: onBrand ? Colors.white.withValues(alpha: 0.16) : t.secondary,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: onBrand ? Colors.white.withValues(alpha: 0.22) : t.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Avatar(id: person.id, label: person.label, size: 22),
          const SizedBox(width: 8),
          Text(
            person.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: onBrand ? Colors.white : t.foreground,
            ),
          ),
          // Talking, from Gather's own `speaking` field. This used to be a
          // mic-off icon driven by the desktop client's log, which could only
          // ever be turned *off* and so almost never showed. Voice activity is
          // both readable and the thing you actually want to know — somebody
          // following you *and* talking is this app's whole reason to exist.
          if (person.speaking) ...[
            const SizedBox(width: 6),
            Icon(
              Icons.graphic_eq_rounded,
              size: 13,
              color: onBrand ? Colors.white : t.brandSoft,
            ),
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
