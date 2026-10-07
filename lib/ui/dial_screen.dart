/// Warp Dial: the office as a phone app.
///
/// The map answers "where is everyone"; this answers "who do I want, and where are
/// the conversations". It is the screen for a thumb on a train — a contact list
/// (here first, gone last), the conversations happening right now, and a rail of
/// the people you have heard from lately — where a tap warps you next to them and
/// opens the call, with none of the panning the office asks for.
///
/// ## Why it reads the directory, not the map
///
/// [AppState.directory] and [AppState.meetings] are built off the whole roster, so
/// this screen shows people the office tab never draws: the offline, and anyone the
/// roster has not placed. That is the point of a directory — you call someone
/// *because* they are not already in front of you.
///
/// ## What it listens to
///
/// `main.dart` wraps the whole shell in a `ListenableBuilder` on [AppState], which
/// catches the presence folds that fire `notifyListeners` — a name, a follow. But
/// the roster carries more than the fold reports: somebody can go Offline, a
/// conversation can form or break up, an availability dot can turn, none of which is
/// part of the fold and so none of which wakes the shell. Those are exactly what this
/// tab sorts and groups on, so it also rides [AppState.directoryChanges], which ticks
/// on just that projection. It deliberately does **not** ride [AppState.positions]
/// the way the map does: a contact list has no reason to repaint four times a second
/// because a stranger took a step.
library;

import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/directory.dart';
import '../theme/gather_theme.dart';
import 'call_screen.dart';
import 'person_avatar.dart';

class DialScreen extends StatefulWidget {
  const DialScreen({super.key, required this.state});

  final AppState state;

  @override
  State<DialScreen> createState() => _DialScreenState();
}

class _DialScreenState extends State<DialScreen> {
  /// The person or meeting a warp is in flight for, keyed by contact id or
  /// cluster id, so its tile can show a spinner while the hop and the mic settle.
  /// One at a time — a second tap mid-warp is ignored rather than queued.
  String? _warping;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    // The shell's own [ListenableBuilder] misses availability and cluster changes;
    // this is the signal that carries them. See the library comment.
    state.directoryChanges.addListener(_onDirectoryChanged);
  }

  @override
  void dispose() {
    state.directoryChanges.removeListener(_onDirectoryChanged);
    super.dispose();
  }

  void _onDirectoryChanged() {
    if (mounted) setState(() {});
  }

  /// Warps, then opens the faces on success. The sentence a refusal returns is
  /// shown here rather than swallowed; the async refusals Gather pushes later
  /// arrive on [AppState.notices], which the office surfaces.
  Future<void> _run(String key, Future<String?> Function() action) async {
    if (_warping != null) return;
    setState(() => _warping = key);
    final failed = await action();
    if (!mounted) return;
    setState(() => _warping = null);
    if (failed != null) {
      _say(failed);
      return;
    }
    await openCallScreen(context, state);
  }

  /// Waves at a contact without warping or opening the call — the one directory
  /// action that touches somebody without going to them. There is no feed echo for
  /// our own wave, so the confirmation here is the only sign it went.
  Future<void> _waveAt(Contact contact) async {
    final result = await state.sendWave(contact.id);
    if (!mounted) return;
    if (result.error != null) {
      _say(result.error!);
    } else if (result.sent) {
      // Only a frame that went gets a confirmation; a cooldown no-op says nothing.
      _say('👋 Waved at ${_firstName(contact.label)}');
    }
  }

  void _say(String message) {
    final t = context.tokens;
    // Float the bar just above the nav rail: the rail floats over content, so a
    // bar docked at the true bottom would sit behind it. The margin is measured
    // from the Scaffold, which re-adds the home-indicator safe area under the
    // floating bar itself — so the rail inset alone (plus a gutter) lands the bar
    // snug above the dock. Using the tab's own `paddingOf`, which already carries
    // that inset *and* the safe area, double-counts the safe area and floats it a
    // home-indicator too high.
    final bottom = kRailInset + kGutter;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: t.card,
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(kGutter, 0, kGutter, bottom),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    final contacts = state.directory;
    final meetings = state.meetings;
    final recents = _recentContacts(contacts);

    final present = contacts.where((c) => c.isPresent).toList(growable: false);
    final offline = contacts.where((c) => !c.isPresent).toList(growable: false);

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        title: Text(state.spaceName ?? 'Dial'),
        titleTextStyle: Theme.of(context).textTheme.titleLarge,
      ),
      body: SafeArea(
        top: false,
        // A live call reserves a strip above the directory rather than floating
        // over it — the list must stay fully readable while you place the next call.
        child: Column(children: [
          CallBannerHeader(state: state),
          Expanded(
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
            if (recents.isNotEmpty)
              SliverToBoxAdapter(child: _RecentsRail(state: state, contacts: recents, onTap: _warpToPerson)),

            if (meetings.isNotEmpty) ...[
              const SliverToBoxAdapter(child: _SectionHeader('Happening now')),
              SliverList.builder(
                itemCount: meetings.length,
                itemBuilder: (context, i) => _MeetingCard(
                  state: state,
                  meeting: meetings[i],
                  busy: _warping == meetings[i].clusterId,
                  onTap: () => _run(meetings[i].clusterId, () => state.warpToMeeting(meetings[i])),
                ),
              ),
            ],

            SliverToBoxAdapter(child: _SectionHeader(present.isEmpty ? 'Nobody here' : 'In the office')),
            if (present.isEmpty)
              const SliverToBoxAdapter(child: _Empty("Nobody's in the office right now."))
            else
              SliverList.builder(
                itemCount: present.length,
                itemBuilder: (context, i) {
                  final c = present[i];
                  final canWarp = state.canWarpTo(c);
                  return _ContactTile(
                    state: state,
                    contact: c,
                    busy: _warping == c.id,
                    canWarp: canWarp,
                    onTap: canWarp ? () => _warpToPerson(c) : null,
                    onWave: () => _waveAt(c),
                  );
                },
              ),

            if (offline.isNotEmpty) ...[
              const SliverToBoxAdapter(child: _SectionHeader('Away')),
              SliverList.builder(
                itemCount: offline.length,
                itemBuilder: (context, i) =>
                    _ContactTile(state: state, contact: offline[i], busy: false, canWarp: false, onTap: null),
              ),
            ],

                SliverToBoxAdapter(child: SizedBox(height: bottomInset + 32)),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  void _warpToPerson(Contact contact) => _run(contact.id, () => state.warpToPerson(contact));

  /// The people behind the most recent activity, newest first and deduplicated —
  /// a "recent calls" rail. Capped, because this is a glance and not the history
  /// (which is the Activity tab's job).
  List<Contact> _recentContacts(List<Contact> contacts) {
    final byId = {for (final c in contacts) c.id: c};
    final seen = <String>{};
    final out = <Contact>[];
    for (final item in state.activity) {
      final id = item.actorSpaceUserId;
      if (id == null || !seen.add(id)) continue;
      final contact = byId[id];
      if (contact != null) out.add(contact);
      if (out.length >= 8) break;
    }
    return out;
  }
}

/// A horizontal rail of recent people — the phone app's "recents" strip.
class _RecentsRail extends StatelessWidget {
  const _RecentsRail({required this.state, required this.contacts, required this.onTap});

  final AppState state;
  final List<Contact> contacts;
  final ValueChanged<Contact> onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Recent'),
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: kTextGutter),
            itemCount: contacts.length,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (context, i) {
              final c = contacts[i];
              return GestureDetector(
                onTap: state.canWarpTo(c) ? () => onTap(c) : null,
                child: Opacity(
                  opacity: c.isPresent ? 1 : 0.45,
                  child: SizedBox(
                    width: 60,
                    child: Column(
                      children: [
                        PersonAvatar(
                          id: c.id,
                          label: c.label,
                          photoUrl: state.photoUrlFor(c.id),
                          size: 52,
                          availability: c.availability,
                          dotRing: t.background,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _firstName(c.label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.mutedForeground, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One conversation to join: the faces in it, and the room or the people it is.
class _MeetingCard extends StatelessWidget {
  const _MeetingCard({required this.state, required this.meeting, required this.busy, required this.onTap});

  final AppState state;
  final Meeting meeting;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final title = meeting.roomName ?? _conversationLabel(meeting.members);
    final subtitle = '${meeting.members.length + (meeting.includesMe ? 1 : 0)} people'
        '${meeting.includesMe ? ' · you' : ''}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 4, kTextGutter, 8),
      child: Material(
        color: t.card,
        borderRadius: BorderRadius.circular(t.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(t.radius),
          onTap: meeting.includesMe || busy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                _FacePile(state: state, members: meeting.members, ring: t.card),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.foreground, fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(subtitle, style: TextStyle(color: t.mutedForeground, fontSize: 13)),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (meeting.includesMe)
                  Text('In this', style: TextStyle(color: t.faint, fontSize: 13))
                else
                  _JoinButton(busy: busy, label: 'Join'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Up to three overlapping avatars, the way a group chat draws its members.
class _FacePile extends StatelessWidget {
  const _FacePile({required this.state, required this.members, required this.ring});

  final AppState state;
  final List<Contact> members;
  final Color ring;

  @override
  Widget build(BuildContext context) {
    const size = 36.0;
    const step = 22.0;
    final shown = members.take(3).toList();
    return SizedBox(
      width: step * (shown.length - 1) + size,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * step,
              child: Container(
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ring, width: 2)),
                child: PersonAvatar(
                  id: shown[i].id,
                  label: shown[i].label,
                  photoUrl: state.photoUrlFor(shown[i].id),
                  size: size,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One person in the directory. Tappable to warp while they are here; dimmed and
/// inert while they are not.
class _ContactTile extends StatelessWidget {
  const _ContactTile({
    required this.state,
    required this.contact,
    required this.busy,
    required this.canWarp,
    required this.onTap,
    this.onWave,
  });

  final AppState state;
  final Contact contact;
  final bool busy;

  /// Whether this contact can be warped to — present, placed, and on our floor.
  /// Drives the pill: a present person on another floor is listed but not called.
  final bool canWarp;
  final VoidCallback? onTap;

  /// Waves at this contact. Null for an offline row — a wave at somebody who is not
  /// here would land nowhere. A present person on another floor can still be waved
  /// at even when [canWarp] is false, so this is independent of the warp pill.
  final VoidCallback? onWave;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final present = contact.isPresent;
    final status = contact.status?.text;

    return Opacity(
      opacity: present ? 1 : 0.5,
      child: InkWell(
        onTap: canWarp && !busy ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: kTextGutter, vertical: 10),
          child: Row(
            children: [
              PersonAvatar(
                id: contact.id,
                label: contact.label,
                photoUrl: state.photoUrlFor(contact.id),
                size: 44,
                availability: present ? contact.availability : null,
                dotRing: t.background,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contact.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.foreground, fontSize: 16, fontWeight: FontWeight.w500),
                    ),
                    if (status != null && status.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.mutedForeground, fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (onWave != null && present) ...[
                _WaveButton(onTap: busy ? null : onWave, label: contact.label),
                const SizedBox(width: 8),
              ],
              if (canWarp) _JoinButton(busy: busy, label: 'Warp', icon: Icons.call_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

/// A quiet round wave button, sized to sit beside the Warp pill without competing
/// with it — a wave is the lighter of the two touches a row offers.
class _WaveButton extends StatelessWidget {
  const _WaveButton({required this.onTap, required this.label});

  final VoidCallback? onTap;

  /// Who the wave is aimed at, so an icon-only button still names its action and
  /// target to a screen reader: "Wave at Ada" rather than an unlabelled button.
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final waveAt = 'Wave at ${_firstName(label)}';
    return Semantics(
      button: true,
      label: waveAt,
      child: Tooltip(
        message: waveAt,
        child: Material(
          color: t.card,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(Icons.waving_hand_rounded, size: 18, color: t.mutedForeground),
            ),
          ),
        ),
      ),
    );
  }
}

/// The call-to-action on a row: a filled pill that spins while its warp settles.
class _JoinButton extends StatelessWidget {
  const _JoinButton({required this.busy, required this.label, this.icon});

  final bool busy;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      height: 34,
      constraints: const BoxConstraints(minWidth: 68),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: t.brand.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(17)),
      child: busy
          ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: t.brand))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[Icon(icon, size: 15, color: t.brand), const SizedBox(width: 5)],
                Text(label, style: TextStyle(color: t.brand, fontSize: 14, fontWeight: FontWeight.w600)),
              ],
            ),
    );
  }
}

/// A quiet uppercase label above a section, matching the activity tab's day
/// headers so the two tabs read as one app.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 16, kTextGutter, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(color: t.mutedForeground, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0.6),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 8, kTextGutter, 24),
      child: Text(message, style: TextStyle(color: t.mutedForeground, height: 1.5)),
    );
  }
}

String _firstName(String label) {
  final trimmed = label.trim();
  final space = trimmed.indexOf(' ');
  return space == -1 ? trimmed : trimmed.substring(0, space);
}

/// "Alice & Bob", "Alice, Bob & 2 more" — a conversation named by its people when
/// it is not named by its room.
String _conversationLabel(List<Contact> members) {
  final names = members.map((m) => _firstName(m.label)).toList();
  if (names.length == 1) return names.first;
  if (names.length == 2) return '${names[0]} & ${names[1]}';
  return '${names[0]}, ${names[1]} & ${names.length - 2} more';
}
