/// The Plans tab: meetings somebody scheduled ahead of time.
///
/// This is the one screen whose contents Gather knows nothing about. Everything
/// else in the app is a view onto Gather's live state — who is here, what is being
/// said, where people stand. A plan is the opposite: a title and a time the user
/// typed, kept on this phone (see [PlannedMeeting]), because Gather has no calendar
/// of its own to put it in. What it borrows from the rest of the app is the one
/// thing a plan can share with the live office — a *place*. A meeting pinned to a
/// Gather room carries a "Walk here" that hands straight to the same routing the
/// map's "Go here" uses ([AppState.walkToMeeting]).
///
/// Modelled on the Activity tab: a day-headed list under a plain app bar, read
/// above the `Scaffold` so the last row clears the floating rail. Unlike Activity,
/// this list is *writable* — the `+` opens a sheet, and each row edits.
library;

import 'package:flutter/material.dart';
import 'package:gather_client/gather_client.dart';

import '../src/app_state.dart';
import '../src/calendar.dart';
import '../theme/gather_theme.dart';

class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Read above the `Scaffold`: the shell folds the rail's height into the bottom
    // padding, which a `Scaffold` body is entitled to take off again. The trailing
    // gap below is what lifts the last card, and the FAB, clear of the dock.
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        title: const Text('Plans'),
        titleTextStyle: Theme.of(context).textTheme.titleLarge,
      ),
      floatingActionButton: Padding(
        // Lifts the FAB above the floating rail it would otherwise sit under.
        padding: EdgeInsets.only(bottom: bottomInset),
        child: FloatingActionButton(
          backgroundColor: t.brand,
          foregroundColor: t.primaryForeground,
          onPressed: () => _openEditor(context, state, null),
          child: const Icon(Icons.add_rounded),
        ),
      ),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final meetings = state.plannedMeetings;
          final now = DateTime.now();
          final upcoming = [for (final m in meetings) if (!m.endsAt.isBefore(now)) m];
          // Past descending: the most recent is the one worth seeing first.
          final past = [for (final m in meetings) if (m.endsAt.isBefore(now)) m]
              .reversed
              .toList();

          if (meetings.isEmpty) {
            return _Empty(bottomInset: bottomInset);
          }

          return ListView(
            padding: EdgeInsets.only(top: 8, bottom: bottomInset + 96),
            children: [
              ..._withDayHeaders(context, state, upcoming),
              if (past.isNotEmpty) ...[
                const _SectionHeader('EARLIER'),
                for (final m in past) _MeetingCard(state: state, meeting: m, past: true),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Upcoming meetings, split by day the way the Activity feed is — a wall of times
/// with no dates stops being readable past the first screen.
List<Widget> _withDayHeaders(BuildContext context, AppState state, List<PlannedMeeting> meetings) {
  final out = <Widget>[];
  String? current;
  for (final m in meetings) {
    final label = _dayLabel(m.startsAt);
    if (label != current) {
      out.add(_SectionHeader(label));
      current = label;
    }
    out.add(_MeetingCard(state: state, meeting: m, past: false));
  }
  return out;
}

class _Empty extends StatelessWidget {
  const _Empty({required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.fromLTRB(32, 48, 32, 24 + bottomInset),
      child: Center(
        child: Text(
          'No plans yet.\nTap + to schedule a meeting and get a reminder before it starts.',
          textAlign: TextAlign.center,
          style: TextStyle(color: t.mutedForeground, height: 1.5),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 16, kTextGutter, 8),
      child: Text(
        label,
        style: TextStyle(
          color: t.mutedForeground,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// One planned meeting. Tapping the body edits it; the two actions below walk you
/// to its room and delete it. A past meeting is dimmed and keeps only its delete —
/// there is nowhere to be walked to for something that already happened.
class _MeetingCard extends StatelessWidget {
  const _MeetingCard({required this.state, required this.meeting, required this.past});

  final AppState state;
  final PlannedMeeting meeting;
  final bool past;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hasRoom = meeting.roomName != null && meeting.roomName!.isNotEmpty;

    return Opacity(
      opacity: past ? 0.55 : 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kTextGutter, 4, kTextGutter, 4),
        child: Material(
          color: t.card,
          borderRadius: BorderRadius.circular(t.radius),
          child: InkWell(
            borderRadius: BorderRadius.circular(t.radius),
            onTap: () => _openEditor(context, state, meeting),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          meeting.title,
                          style: TextStyle(color: t.foreground, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _timeRange(meeting),
                        style: TextStyle(
                          color: t.faint,
                          fontSize: 13,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  if (hasRoom) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.place_outlined, size: 15, color: t.mutedForeground),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            meeting.roomName!,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.mutedForeground, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (!past && hasRoom)
                        _Action(
                          icon: Icons.directions_walk_rounded,
                          label: 'Walk here',
                          onTap: () => _walk(context),
                        ),
                      const Spacer(),
                      _Action(
                        icon: Icons.delete_outline_rounded,
                        label: 'Delete',
                        tint: t.danger,
                        onTap: () => _delete(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _walk(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await state.walkToMeeting(meeting);
    messenger.showSnackBar(SnackBar(
      content: Text(error ?? 'On your way to ${meeting.roomName}.'),
    ));
  }

  Future<void> _delete(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await state.deleteMeeting(meeting.id);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }
}

/// One of a card's inline actions: an icon with a word, flat, in the accent or a
/// given tint. Small enough that two sit on one line under the title.
class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap, this.tint});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final colour = tint ?? t.brand;
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: colour,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

/// Opens the create/edit sheet. [existing] null means a new meeting.
Future<void> _openEditor(BuildContext context, AppState state, PlannedMeeting? existing) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.tokens.popover,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => _MeetingEditor(state: state, existing: existing),
  );
}

/// The create/edit sheet. A title, a day and time, a length, an optional Gather
/// room to pin it to, and how long before to be reminded. Lifts above the keyboard
/// while the title is being typed.
class _MeetingEditor extends StatefulWidget {
  const _MeetingEditor({required this.state, required this.existing});

  final AppState state;
  final PlannedMeeting? existing;

  @override
  State<_MeetingEditor> createState() => _MeetingEditorState();
}

class _MeetingEditorState extends State<_MeetingEditor> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?.title ?? '');
  late DateTime _start = widget.existing?.startsAt ?? _defaultStart();
  late int _durationMinutes = widget.existing == null
      ? 30
      : widget.existing!.endsAt.difference(widget.existing!.startsAt).inMinutes.clamp(5, 480);
  late String? _roomStableId = widget.existing?.roomStableId;
  late int _remindMinutes = widget.existing?.remindMinutesBefore ?? 5;
  bool _saving = false;

  /// The next round half-hour: the overwhelmingly common thing to want, so it is
  /// what the pickers open on.
  static DateTime _defaultStart() {
    final now = DateTime.now();
    final rounded = DateTime(now.year, now.month, now.day, now.hour).add(
      Duration(minutes: now.minute < 30 ? 30 : 60),
    );
    return rounded;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // The sheet rides above the keyboard rather than being covered by it.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final rooms = widget.state.plannableRooms;
    final editing = widget.existing != null;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + keyboard),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text(
              editing ? 'Edit meeting' : 'New meeting',
              style: TextStyle(color: t.foreground, fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              autofocus: !editing,
              textCapitalization: TextCapitalization.sentences,
              style: TextStyle(color: t.foreground),
              decoration: InputDecoration(
                hintText: 'What is it?',
                hintStyle: TextStyle(color: t.faint),
                filled: true,
                fillColor: t.secondary,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(t.radius),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _Field(
              label: 'When',
              child: _PickerButton(
                text: '${_dayLabelFull(_start)}, ${_time(_start)}',
                onTap: _pickWhen,
              ),
            ),
            const SizedBox(height: 12),
            _Field(
              label: 'Length',
              child: _DurationPicker(
                minutes: _durationMinutes,
                onChanged: (m) => setState(() => _durationMinutes = m),
              ),
            ),
            const SizedBox(height: 12),
            _Field(
              label: 'Where',
              child: _RoomPicker(
                rooms: rooms,
                selectedStableId: _roomStableId,
                onChanged: (id) => setState(() => _roomStableId = id),
              ),
            ),
            const SizedBox(height: 12),
            _Field(
              label: 'Remind me',
              child: _ReminderPicker(
                minutes: _remindMinutes,
                onChanged: (m) => setState(() => _remindMinutes = m),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: t.brand,
                  foregroundColor: t.primaryForeground,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _saving ? null : _save,
                child: Text(editing ? 'Save changes' : 'Add meeting'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickWhen() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_start),
    );
    if (time == null || !mounted) return;
    setState(() {
      _start = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (title.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Give the meeting a name.')));
      return;
    }
    setState(() => _saving = true);

    // Resolve the chosen room off the live map so its label and floor travel with
    // the plan — the map may be gone by the time the meeting is walked to.
    final room = _resolveRoom(_roomStableId);
    final existing = widget.existing;
    final meeting = PlannedMeeting(
      id: existing?.id ?? _newId(),
      title: title,
      startsAt: _start,
      endsAt: _start.add(Duration(minutes: _durationMinutes)),
      roomStableId: room?.stableId,
      roomName: room?.name,
      floorId: room == null ? null : widget.state.map?.floorId,
      remindMinutesBefore: _remindMinutes,
      deviceEventId: existing?.deviceEventId,
    );

    final error = existing == null
        ? await widget.state.addMeeting(meeting)
        : await widget.state.updateMeeting(meeting);
    if (!mounted) return;
    if (error != null) {
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    navigator.pop();
  }

  SpaceRoom? _resolveRoom(String? stableId) {
    if (stableId == null) return null;
    for (final room in widget.state.plannableRooms) {
      if (room.stableId == stableId) return room;
    }
    return null;
  }
}

String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

/// A labelled row in the editor: a caption over its control.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(color: t.mutedForeground, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

/// A flat field-shaped button that opens a picker — used for the date/time row.
class _PickerButton extends StatelessWidget {
  const _PickerButton({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: t.secondary,
      borderRadius: BorderRadius.circular(t.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(t.radius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.schedule_rounded, size: 18, color: t.mutedForeground),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: TextStyle(color: t.foreground, fontSize: 15))),
            ],
          ),
        ),
      ),
    );
  }
}

class _DurationPicker extends StatelessWidget {
  const _DurationPicker({required this.minutes, required this.onChanged});

  final int minutes;
  final ValueChanged<int> onChanged;

  static const _options = [15, 30, 45, 60, 90, 120];

  @override
  Widget build(BuildContext context) {
    // A duration not on the shortlist (an edited meeting of an odd length) still
    // shows, added to the choices so the menu can render it.
    final options = {..._options, minutes}.toList()..sort();
    return _Dropdown<int>(
      value: minutes,
      items: [for (final m in options) (m, _durationLabel(m))],
      onChanged: onChanged,
    );
  }
}

class _ReminderPicker extends StatelessWidget {
  const _ReminderPicker({required this.minutes, required this.onChanged});

  final int minutes;
  final ValueChanged<int> onChanged;

  static const _options = [0, 5, 10, 15, 30, 60];

  @override
  Widget build(BuildContext context) {
    final options = {..._options, minutes}.toList()..sort();
    return _Dropdown<int>(
      value: minutes,
      items: [for (final m in options) (m, m == 0 ? 'At start time' : '${_durationLabel(m)} before')],
      onChanged: onChanged,
    );
  }
}

/// The room picker. Empty when the office has not loaded — a plan can still be made
/// without a place, and pinned later once there is a floor plan to pin it to.
class _RoomPicker extends StatelessWidget {
  const _RoomPicker({required this.rooms, required this.selectedStableId, required this.onChanged});

  final List<SpaceRoom> rooms;
  final String? selectedStableId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (rooms.isEmpty) {
      return Text(
        selectedStableId == null
            ? 'No place — connect to the office to pin a room.'
            : 'Room saved; connect to the office to change it.',
        style: TextStyle(color: t.faint, fontSize: 13),
      );
    }
    return _Dropdown<String?>(
      value: rooms.any((r) => r.stableId == selectedStableId) ? selectedStableId : null,
      items: [
        (null, 'No place'),
        for (final room in rooms)
          if (room.stableId != null) (room.stableId, room.name ?? 'Room'),
      ],
      onChanged: onChanged,
    );
  }
}

/// A field-shaped dropdown sharing the pickers' look, generic over its value.
class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({required this.value, required this.items, required this.onChanged});

  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: t.secondary, borderRadius: BorderRadius.circular(t.radius)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: t.popover,
          iconEnabledColor: t.mutedForeground,
          style: TextStyle(color: t.foreground, fontSize: 15),
          items: [
            for (final (v, label) in items)
              DropdownMenuItem<T>(value: v, child: Text(label)),
          ],
          onChanged: (v) {
            if (v != null || null is T) onChanged(v as T);
          },
        ),
      ),
    );
  }
}

// ---- formatting ------------------------------------------------------------

String _timeRange(PlannedMeeting m) => '${_time(m.startsAt)}–${_time(m.endsAt)}';

String _time(DateTime at) {
  final h = at.hour.toString().padLeft(2, '0');
  final m = at.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

String _durationLabel(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (m == 0) return h == 1 ? '1 hour' : '$h hours';
  return '${h}h ${m}m';
}

/// Short day label for the list headers — TODAY / TOMORROW / weekday / date.
String _dayLabel(DateTime at) {
  final day = DateTime(at.year, at.month, at.day);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final delta = day.difference(today).inDays;
  if (delta == 0) return 'TODAY';
  if (delta == 1) return 'TOMORROW';
  if (delta > 1 && delta < 7) return _weekdays[at.weekday - 1].toUpperCase();
  return '${at.day} ${_months[at.month - 1]} ${at.year}'.toUpperCase();
}

/// Longer day label for the editor's When button — "Today", "Tomorrow", or a date.
String _dayLabelFull(DateTime at) {
  final day = DateTime(at.year, at.month, at.day);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final delta = day.difference(today).inDays;
  if (delta == 0) return 'Today';
  if (delta == 1) return 'Tomorrow';
  return '${_weekdays[at.weekday - 1]} ${at.day} ${_months[at.month - 1]}';
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
