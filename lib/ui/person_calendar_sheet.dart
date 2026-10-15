/// A read-only peek at one person's shared calendar.
///
/// Reached by tapping a colleague — from the map's person card or the Warp Dial —
/// this sheet answers "are they free, and when?". It is the same question the Plans
/// tab answers for yourself, pointed at somebody else: their events come from a Google
/// calendar they shared with *this* account, matched by name (Gather carries no email
/// to key on), so a person with nothing shared shows the honest "no shared calendar"
/// rather than a blank the user might read as "free".
///
/// Themed entirely through [context.tokens], so the retro Gameboy palette restyles it
/// with no per-mode code — the same contract the person card and Dial tiles keep.
library;

import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/google_calendar.dart';
import '../theme/gather_theme.dart';

/// Opens the calendar sheet for the person named [label]. A thin wrapper over
/// `showModalBottomSheet` so both call sites open it identically.
Future<void> showPersonCalendar(
  BuildContext context,
  AppState state,
  String label, {
  String? email,
}) {
  final t = context.tokens;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: t.card,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) =>
        _PersonCalendarSheet(state: state, label: label, email: email),
  );
}

class _PersonCalendarSheet extends StatelessWidget {
  const _PersonCalendarSheet({
    required this.state,
    required this.label,
    this.email,
  });

  final AppState state;
  final String label;

  /// The colleague's wire calendar email, when the Dial had one — the strong key the
  /// sheet reads by, falling back to the label the map's person card can offer.
  final String? email;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final firstName = label.split(' ').first;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "$firstName's plans",
                style: TextStyle(color: t.foreground, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: FutureBuilder<List<GoogleEvent>?>(
                  future: state.calendarForLabel(label, email: email),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 28),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    final events = snapshot.data;
                    if (events == null) {
                      return _Hint(
                        icon: Icons.event_busy_outlined,
                        text: '$firstName has not shared a calendar with you.',
                      );
                    }
                    final upcoming = [
                      for (final e in events) if (!e.isPast) e,
                    ]..sort((a, b) => a.startsAt.compareTo(b.startsAt));
                    if (upcoming.isEmpty) {
                      return _Hint(
                        icon: Icons.event_available_outlined,
                        text: 'Nothing on $firstName’s calendar for the next week.',
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: upcoming.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) => _PersonEventRow(event: upcoming[i]),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PersonEventRow extends StatelessWidget {
  const _PersonEventRow({required this.event});

  final GoogleEvent event;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hasPlace = event.location != null && event.location!.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: BorderRadius.circular(t.radius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  style: TextStyle(color: t.foreground, fontSize: 15, fontWeight: FontWeight.w600),
                ),
                if (hasPlace) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.place_outlined, size: 13, color: t.mutedForeground),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          event.location!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.mutedForeground, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            event.allDay ? 'All day' : '${_dayLabel(event.startsAt)} ${_hm(event.startsAt)}',
            style: TextStyle(
              color: t.faint,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Column(
        children: [
          Icon(icon, size: 30, color: t.faint),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: t.mutedForeground, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// "Today" / "Tomorrow" / a weekday, to put a loose day beside the time without the
/// sheet needing the Plans tab's full day-headed grouping.
String _dayLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  if (diff > 1 && diff < 7) return names[d.weekday - 1];
  return '${d.day}/${d.month}';
}
