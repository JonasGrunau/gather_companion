/// Who you are in the room: available, busy, away, and a line saying why.
///
/// Gather opens this as a popover above the avatar in its bar. On a phone it is a
/// sheet, for the ordinary reason — a popover anchored to a 48-point tile at the
/// bottom-left of a screen would either cover the thing it belongs to or point at
/// it from a distance, and the app already has one sheet (`type_code_dialog.dart`)
/// whose recipe this follows exactly.
///
/// ## Both halves are read back, and neither is an echo
///
/// Availability comes off the roster, and so does the status line. That second
/// one was an echo of whatever this phone last sent for a while, because
/// `SpaceUserStatus` was one of the models the reader discarded — so it survived
/// no restart and knew nothing about a status set from the Mac. It is tracked
/// now. The join runs from the status row's own `spaceUserId` rather than from
/// `SpaceUser.activeCustomStatusId`, because that field, and
/// `activeUserGeneratedStatusId` beside it, were never set on anybody: measured
/// across 98 rows, including people whose status was on screen at the time.
///
/// One consequence worth knowing: what comes back may be a status **Gather
/// wrote**, not one you typed. A connected calendar produces `CalendarInferred`
/// rows — "Lunch 🥗" — and this sheet will happily show you one and let you
/// replace it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gather_client/gather_client.dart';

import '../src/app_state.dart';
import '../theme/gather_theme.dart';

/// How long a status stands before Gather drops it by itself.
///
/// Gather's own picker offers a menu of these. One is enough here: the common
/// case by a distance is "for the rest of today", and a phone is not where
/// somebody sets up a status that expires next Tuesday.
const _clearAfter = Duration(hours: 8);

Future<void> showStatusSheet(BuildContext context, AppState state) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      // The sheet paints its own container, as `showTypeCode` does.
      backgroundColor: Colors.transparent,
      builder: (context) => _StatusSheet(state: state),
    );

class _StatusSheet extends StatefulWidget {
  const _StatusSheet({required this.state});

  final AppState state;

  @override
  State<_StatusSheet> createState() => _StatusSheetState();
}

class _StatusSheetState extends State<_StatusSheet> {
  late final _text = TextEditingController(text: widget.state.customStatus?.text ?? '');
  late String? _emoji = widget.state.customStatus?.emoji;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    final failed = await action();
    if (!mounted) return;
    if (failed != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failed)));
      return;
    }
    setState(() {});
  }

  Future<void> _pick(String availability) async {
    HapticFeedback.selectionClick();
    await _run(() => widget.state.setAvailability(availability));
  }

  Future<void> _submit() async {
    final text = _text.text.trim();
    await _run(() => text.isEmpty
        ? widget.state.clearCustomStatus()
        : widget.state.setCustomStatus(
            text: text,
            emoji: _emoji,
            clearAt: DateTime.now().toUtc().add(_clearAfter),
          ));
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final state = widget.state;
    final current = state.myAvailability;
    final me = state.mePerson;

    return Padding(
      // Lifts the sheet clear of the keyboard while the status line is being
      // typed, exactly as the pairing sheet does.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: BoxDecoration(
          color: t.popover,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: t.border)),
        ),
        padding: const EdgeInsets.fromLTRB(kGutter, 12, kGutter, 20),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: t.ring,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                me?.label ?? 'You',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 2),
              Text(
                availabilityLabel(current ?? 'Active'),
                style: TextStyle(fontSize: 13, color: t.mutedForeground),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  for (final availability in settableAvailabilities) ...[
                    Expanded(
                      child: _Choice(
                        availability: availability,
                        // `Focused` comes off a focus area rather than this
                        // picker, and it is not one of the three — so it lights
                        // none of them rather than pretending to be Active.
                        selected: current == availability,
                        onTap: () => _pick(availability),
                      ),
                    ),
                    if (availability != settableAvailabilities.last)
                      const SizedBox(width: 8),
                  ],
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _text,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                maxLength: 80,
                decoration: InputDecoration(
                  hintText: 'Update your status',
                  counterText: '',
                  prefixIcon: _EmojiButton(
                    emoji: _emoji,
                    onPick: (next) => setState(() => _emoji = next),
                  ),
                  suffixIcon: IconButton(
                    onPressed: _submit,
                    icon: Icon(Icons.arrow_forward_rounded, color: t.mutedForeground),
                    tooltip: 'Set',
                  ),
                ),
              ),
              // Only when there is one to take down — the same rule the control
              // bar follows for the conversation button.
              if (state.customStatus != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () async {
                      _text.clear();
                      setState(() => _emoji = null);
                      await _run(state.clearCustomStatus);
                    },
                    child: const Text('Clear it'),
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                'Your status clears itself after eight hours.',
                style: TextStyle(fontSize: 11.5, color: t.faint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the three, tinted in its own colour when it is the one you are on.
///
/// The fill-and-border pair is the link strip's recipe (0.12 fill, 0.3 border),
/// which is also what Gather draws around the selected state — so it is both the
/// app's own language and a faithful copy, which does not happen often.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.availability,
    required this.selected,
    required this.onTap,
  });

  final String availability;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final colour = availabilityColor(t, availability);

    return Semantics(
      button: true,
      selected: selected,
      label: availabilityLabel(availability),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(t.radius),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: selected ? colour.withValues(alpha: 0.12) : t.secondary,
              borderRadius: BorderRadius.circular(t.radius),
              border: Border.all(
                color: selected ? colour.withValues(alpha: 0.3) : t.border,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    availabilityLabel(availability),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: selected ? t.foreground : t.mutedForeground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The emoji that sits in front of the status line.
///
/// A short list rather than a keyboard: the system emoji picker is not something
/// a Flutter text field can summon on its own, and the six here cover what a
/// status line is usually about.
const _statusEmoji = ['🎧', '📅', '🍽️', '🚶', '🤒', '🌴'];

class _EmojiButton extends StatelessWidget {
  const _EmojiButton({required this.emoji, required this.onPick});

  final String? emoji;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return PopupMenuButton<String?>(
      tooltip: 'Pick an emoji',
      color: t.popover,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(t.radius),
        side: BorderSide(color: t.border),
      ),
      onSelected: onPick,
      itemBuilder: (context) => [
        for (final option in _statusEmoji)
          PopupMenuItem(
            value: option,
            child: Text(option, style: const TextStyle(fontSize: 19)),
          ),
        PopupMenuItem(
          value: null,
          child: Text('None', style: TextStyle(color: t.mutedForeground)),
        ),
      ],
      child: Center(
        widthFactor: 1,
        child: emoji == null
            ? Icon(Icons.mood_rounded, color: t.faint)
            : Text(emoji!, style: const TextStyle(fontSize: 19)),
      ),
    );
  }
}
