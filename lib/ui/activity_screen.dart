/// The activity tab: Gather's own feed of what happened to you — waves,
/// mentions, meeting notes — kept server-side and the same list the desktop
/// client shows.
///
/// It used to carry more. Party mode sat here as a gradient card, and moved to
/// the settings tab, where the app keeps its switches. The follower card sat
/// here too, and became the accent-tinted counter next to the head count in the
/// office's app bar — live presence belongs on the live screen, and a history
/// does not want a card above it that is stale a minute later. The link strip
/// went last: the settings tab already owns up to a dead connection, and the
/// strip's main appearance in practice was pull-to-refresh dropping the socket
/// on purpose and then announcing the reconnect it had caused. What is left is
/// the record.
///
/// The phone's *local* history is still gone and is not coming back. It could
/// only ever record its own waking hours, so it was empty exactly when it
/// mattered. That was never an argument against a history — only against one
/// this app kept for itself. The list below is Gather's, and it was there while
/// the phone was asleep.
///
/// ## What a row can and cannot do
///
/// Read state is not uniform, and the screen does not pretend otherwise. Meeting
/// memos and onboarding nudges have an `ActivityEventSubscription` row behind
/// them, so tapping one marks it read in Gather and the desktop badge clears
/// too. A wave does not — its read state is a chat read cursor on a DM channel,
/// a different mechanism this app does not implement. So waves arrive already
/// reported read and are not tappable. Showing an unread dot we could not clear
/// would be worse than showing none.
///
/// ## Arriving finished
///
/// Bones stand in until the feed has answered, and then the two cross-fade in
/// the same pixels rather than cutting — see [_Skeleton] for the bones and
/// [_ActivityScreenState] for the swap.
///
/// The faces are *not* waited for. Holding the rows back until every avatar had
/// decoded was tried and is the wrong trade: a list of names with coloured
/// initials is a list you can read, and no list at all is not. So they are
/// warmed in the background instead, and land on rows that are already up.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gather_client/gather_client.dart';

import '../src/app_state.dart';
import '../theme/gather_theme.dart';
import 'person_avatar.dart';

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key, required this.state});

  final AppState state;

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

/// Dissolves the bones into the list, and warms the faces behind it.
///
/// Only one thing is waited for, and it is the feed answering —
/// [AppState.activityFetched]. The faces are deliberately not: see the library
/// comment. What happens to them instead is [_warmFaces].
class _ActivityScreenState extends State<ActivityScreen> with SingleTickerProviderStateMixin {
  /// The cross-dissolve. Long enough to read as one thing becoming another
  /// rather than a cut, short enough that nobody is waiting on it.
  late final AnimationController _reveal =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 320));

  /// One curve, and its own reverse for the bones, so the two opacities always
  /// sum to one: the pixels they share never dim in the middle of the swap.
  late final CurvedAnimation _rows = CurvedAnimation(parent: _reveal, curve: Curves.easeInOut);
  late final Animation<double> _bones = ReverseAnimation(_rows);

  /// Faces already handed to the image cache, so a rebuild does not hand them
  /// over again.
  final _warmed = <String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _warmFaces();
    // Answered before the first frame — a warm tab, or a test. There were never
    // any bones, so there is nothing to fade.
    if (_ready) _reveal.value = 1;
  }

  @override
  void didUpdateWidget(covariant ActivityScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Every rebuild of this screen is a change in `AppState` — a fetch landing,
    // a live wave, or one more picture URL having resolved.
    _warmFaces();
    if (_ready) _reveal.forward();
  }

  @override
  void dispose() {
    _rows.dispose();
    _reveal.dispose();
    super.dispose();
  }

  /// Whether there is something honest to show: the rows, or the sentence
  /// saying why there are none.
  bool get _ready =>
      widget.state.activityFetched ||
      widget.state.activityError != null ||
      widget.state.activity.isNotEmpty;

  /// Fetches and decodes the feed's faces off to one side.
  ///
  /// Nothing waits on this. The rows are already up wearing their coloured
  /// initials, and each picture lands on the one it belongs to when it is
  /// ready. What it buys is that the face is decoded *before* you have scrolled
  /// to it, and that it is only ever fetched once: `precacheImage` fills the
  /// same cache `Image.network` reads from, keyed on the URL, so the same
  /// colleague on four rows is one download and a scroll back up is none.
  ///
  /// Asking [AppState.photosFor] is also what starts the URL lookups, and those
  /// answers arrive as further rebuilds — which is why this runs on each of
  /// them and skips what it has already asked for.
  void _warmFaces() {
    final urls = widget.state.photosFor(
      widget.state.activity.map((item) => item.actorSpaceUserId).whereType<String>(),
    );
    for (final url in urls) {
      if (!_warmed.add(url)) continue;
      unawaited(
        precacheImage(
          NetworkImage(url),
          context,
          // An expired signature or a deleted picture is a coloured initial,
          // which the avatar draws underneath regardless. Nothing to report.
          onError: (_, _) {},
        ),
      );
    }
  }

  /// The bottom inset is read here rather than inside the `Scaffold`: the shell
  /// puts the nav rail's height into the bottom padding, and `Scaffold` is
  /// entitled to take that off its body. This context sits above it and sees
  /// the real number.
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final state = widget.state;
    final items = state.activity;
    final ready = _ready;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        title: const Text('Activity'),
        titleTextStyle: Theme.of(context).textTheme.titleLarge,
        actions: [
          // Withheld until the list it acts on is on screen — an action over a
          // skeleton is offering to do something to nothing.
          if (ready && items.any((item) => item.canMarkRead && !item.isRead))
            IconButton(
              // The double check is the reading apps' idiom for "all of it";
              // the words it replaces are kept for the tooltip and VoiceOver.
              tooltip: 'Mark all read',
              onPressed: () => state.markActivityRead(items),
              icon: Icon(Icons.done_all_rounded, color: t.brand),
            ),
        ],
      ),
      // Not wrapped in a `SafeArea`: the list runs under the rail, and the
      // trailing sliver below is what lets the last row be scrolled clear of it.
      body: Stack(
        children: [
          RefreshIndicator(
            color: t.brand,
            backgroundColor: t.card,
            // Only the list. The pull used to also drop and reopen the socket,
            // on the theory that a pull means "all of it" — in practice the
            // socket looks after itself, and the reconnect's only visible
            // effect was the link strip popping in over the history it was
            // refreshing.
            onRefresh: state.refreshActivity,
            child: CustomScrollView(
              // Without this there is nothing to over-scroll on a short screen
              // and pull-to-refresh silently does nothing — which is also what
              // keeps the pull working while the bones are up and the list
              // below them is still empty.
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // Nothing has been checked yet, so nothing is claimed yet: not
                // even an empty state is in the tree until [_ready].
                if (ready)
                  SliverFadeTransition(
                    opacity: _rows,
                    sliver: items.isNotEmpty
                        ? _History(state: state, items: items)
                        : SliverToBoxAdapter(child: _NoHistory(state: state)),
                  ),
                SliverToBoxAdapter(child: SizedBox(height: bottomInset + 32)),
              ],
            ),
          ),
          // Over the list rather than in it, for two reasons: the bones and the
          // rows have to cross-fade in the same pixels, and the breath has to
          // carry on undisturbed through the swap — moving the skeleton
          // somewhere else in the tree would restart it, which is a flash at
          // exactly the wrong moment.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedBuilder(
              animation: _reveal,
              builder: (context, child) => _reveal.isCompleted
                  ? const SizedBox.shrink()
                  : IgnorePointer(child: FadeTransition(opacity: _bones, child: child)),
              child: Semantics(
                // Once the rows are in the tree, they are what there is to read.
                label: ready ? null : 'Reading your activity…',
                child: const ExcludeSemantics(child: _Skeleton()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Why the list below is empty, which is two different things.
///
/// "Could not read" is not the same as "nothing happened", and a person who
/// cannot tell them apart has no way to know whether to pull again. The third
/// kind of empty — "still reading" — is the skeleton's, drawn rather than said.
class _NoHistory extends StatelessWidget {
  const _NoHistory({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
      child: Center(
        child: Text(
          state.activityError != null
              ? "Couldn't read your activity from Gather.\nPull to try again."
              : 'Nothing yet.\nWaves and meeting notes show up here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: t.mutedForeground, height: 1.5),
        ),
      ),
    );
  }
}

/// The shape of the list before the list: a day-header bone and a screenful of
/// row bones, breathing while the first read is in flight.
///
/// Each bone copies its row's real measurements — the 36pt glyph, the title
/// line, the time column — so the fetch landing swaps texture for text without
/// anything moving. The stagger of widths is a fixed pattern rather than
/// random: real titles are ragged, but a skeleton that reshuffled on every
/// build would shimmer in the wrong sense of the word.
///
/// One fade over the whole column, not one per row, and slow: this is the
/// screen breathing, not an alarm blinking. The sentence the bones replaced is
/// VoiceOver's, and is put on them from outside — the screen takes it away
/// again the moment the real rows enter the tree.
class _Skeleton extends StatefulWidget {
  const _Skeleton();

  @override
  State<_Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<_Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _breath =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Reading your activity…',
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: _breath.drive(Tween(begin: 0.45, end: 1.0).chain(CurveTween(curve: Curves.easeInOut))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(kTextGutter, 8, kTextGutter, 8),
                child: _Bone(width: 56, height: 12),
              ),
              for (var i = 0; i < 8; i++) _SkeletonRow(index: i),
            ],
          ),
        ),
      ),
    );
  }
}

/// One placeholder row, cut to [_ActivityTile]'s measurements.
class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow({required this.index});

  final int index;

  static const _widths = [0.62, 0.48, 0.71, 0.42, 0.58, 0.52, 0.66, 0.45];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kTextGutter, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Bone.circle(36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The title bar sits where the title's 20pt line would put it.
                const SizedBox(height: 3),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: _widths[index % _widths.length],
                  child: const _Bone(height: 14),
                ),
                // Every third row gets the second line real rows sometimes have.
                if (index % 3 == 0) ...[
                  const SizedBox(height: 8),
                  const FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: 0.85,
                    child: _Bone(height: 12),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          // The clock time — "12:30" is 34pt wide in its tabular figures.
          const _Bone(width: 34, height: 12),
        ],
      ),
    );
  }
}

/// A rounded rectangle (or circle) of surface colour where content will be.
class _Bone extends StatelessWidget {
  const _Bone({this.width, required this.height}) : circle = false;

  const _Bone.circle(double size)
      : width = size,
        height = size,
        circle = true;

  final double? width;
  final double height;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: t.secondary,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(6),
      ),
    );
  }
}

/// Gather's feed, split into days.
///
/// A sliver rather than its own `ListView`, so anything above it — today just
/// the link strip — scrolls as one piece with it instead of sitting pinned over
/// a second scrollable.
class _History extends StatelessWidget {
  const _History({required this.state, required this.items});

  final AppState state;
  final List<ActivityItem> items;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final rows = _withDayHeaders(items);

    return SliverList.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) => switch (rows[index]) {
        _DayHeader(:final label) => Padding(
          padding: const EdgeInsets.fromLTRB(kTextGutter, 8, kTextGutter, 8),
          child: Text(
            label,
            style: TextStyle(color: t.mutedForeground, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.6),
          ),
        ),
        _Row(:final item) => _ActivityTile(state: state, item: item),
      },
    );
  }
}

sealed class _Line {
  const _Line();
}

class _DayHeader extends _Line {
  const _DayHeader(this.label);
  final String label;
}

class _Row extends _Line {
  const _Row(this.item);
  final ActivityItem item;
}

/// Splits the list into days. The feed spans months, and a wall of times with no
/// dates is unreadable past the first screen.
List<_Line> _withDayHeaders(List<ActivityItem> items) {
  final out = <_Line>[];
  String? current;
  for (final item in items) {
    final label = _dayLabel(item.at);
    if (label != current) {
      out.add(_DayHeader(label));
      current = label;
    }
    out.add(_Row(item));
  }
  return out;
}

String _dayLabel(DateTime? at) {
  if (at == null) return 'EARLIER';
  final local = at.toLocal();
  final now = DateTime.now();
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final delta = today.difference(day).inDays;
  if (delta == 0) return 'TODAY';
  if (delta == 1) return 'YESTERDAY';
  if (delta < 7) return _weekdays[local.weekday - 1].toUpperCase();
  return '${local.day} ${_months[local.month - 1]} ${local.year}'.toUpperCase();
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.state, required this.item});

  final AppState state;
  final ActivityItem item;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final unread = !item.isRead;
    final actor = item.actorSpaceUserId;
    final name = actor == null ? null : state.nameFor(actor);

    return InkWell(
      // Only the subscription-backed kinds can be flipped; the rest are not
      // pretending to be buttons.
      onTap: item.canMarkRead && unread ? () => state.markActivityRead([item]) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: kTextGutter, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Glyph(item: item, name: name, id: actor, photoUrl: actor == null ? null : state.photoUrlFor(actor)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title(item, name),
                    style: TextStyle(color: t.foreground, fontSize: 15, height: 1.35, fontWeight: unread ? FontWeight.w600 : FontWeight.w400),
                  ),
                  if (_detail(item) case final detail?) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.mutedForeground, fontSize: 13, height: 1.35),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _time(item.at),
                  // Tabular figures so the times form a column down the list
                  // instead of a ragged edge.
                  style: TextStyle(color: t.faint, fontSize: 12, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                if (unread) ...[
                  const SizedBox(height: 6),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: t.brand, shape: BoxShape.circle),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// An initial for a person, an icon for everything else.
/// What a row in the history leads with.
///
/// Two different things wear the same 36-point circle. Something a *person* did
/// gets that person — their profile picture, or their initial on a colour picked
/// from their id when they have not set one. Something the system did (meeting
/// notes, onboarding) gets an icon, because there is nobody to show.
class _Glyph extends StatelessWidget {
  const _Glyph({required this.item, required this.name, this.id, this.photoUrl});

  final ActivityItem item;
  final String? name;

  /// The actor's `SpaceUser` id, which picks their colour.
  final String? id;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    final icon = switch (item) {
      MeetingArtifactActivity() => Icons.description_outlined,
      OnboardingActivity() => Icons.school_outlined,
      UnknownActivity() => Icons.bolt_outlined,
      _ => null,
    };

    if (icon == null && id != null) {
      return PersonAvatar(id: id!, label: name ?? '?', photoUrl: photoUrl, size: 36);
    }

    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: icon == null ? t.brandTint : t.secondary, shape: BoxShape.circle),
      child: icon != null
          ? Icon(icon, size: 18, color: t.mutedForeground)
          : Text(
              _initial(name),
              style: TextStyle(color: t.brand, fontWeight: FontWeight.w700, fontSize: 15),
            ),
    );
  }
}

String _initial(String? name) {
  final trimmed = name?.trim() ?? '';
  return trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
}

String _title(ActivityItem item, String? name) {
  final who = name ?? 'Someone';
  return switch (item) {
    WaveActivity() => '$who waved at you',
    MentionActivity() => '$who mentioned you',
    ReactionActivity() => '$who reacted to your message',
    ReplyActivity() => '$who replied in your thread',
    MeetingArtifactActivity(:final meetingTitle, :final hasVideoRecording, :final hasMeetingMemo) => switch ((hasMeetingMemo, hasVideoRecording)) {
      (true, true) => 'Notes and recording ready${_from(meetingTitle)}',
      (false, true) => 'Recording ready${_from(meetingTitle)}',
      _ => 'Notes ready${_from(meetingTitle)}',
    },
    OnboardingActivity(:final kind) => switch (kind) {
      activityOnboardingChat => 'Try chatting in Gather',
      activityOnboardingDesk => 'Claim a desk in Gather',
      _ => 'Getting started in Gather',
    },
    // Deliberately says what it is rather than inventing a sentence for it: a kind
    // nobody has decoded yet is more useful named than paraphrased.
    UnknownActivity(:final kind) => kind,
  };
}

String _from(String? title) => title == null ? '' : ' from $title';

String? _detail(ActivityItem item) => switch (item) {
  MentionActivity(:final message) => message,
  ReactionActivity(:final message) => message,
  ReplyActivity(:final message) => message,
  MeetingArtifactActivity(:final participantCount) => participantCount == null ? null : '$participantCount people',
  _ => null,
};

/// Clock time within the day; the day itself is the header above.
String _time(DateTime? at) {
  if (at == null) return '';
  final local = at.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}
