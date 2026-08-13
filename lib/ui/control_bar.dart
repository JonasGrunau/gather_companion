/// The things you can do about yourself, gathered into one island over the floor.
///
/// Gather's own client puts these across the bottom of the office — who you are,
/// whether you are available, your microphone, your camera, and a row of
/// reactions — and that is the right place for them, because they are all
/// answers to "what am I doing in this room" rather than places to go. The rail
/// underneath is navigation; this is participation, and keeping the two as
/// separate islands is what stops a person hunting for the mute button among the
/// tabs.
///
/// ## What is here, and what is deliberately not
///
/// Gather's bar also carries a screen-share button and a door marked *leave*.
/// Neither survives the trip to a phone. There is nothing on a phone worth
/// sharing a window of, and leaving is worse than useless here: the socket this
/// app holds **is** the presence everything else in it reports, so a door out of
/// the space would switch the product off. What replaces the door is
/// `leaveCluster` — stepping out of the conversation you are in without walking
/// away from it — which is a real thing on the wire and the one people actually
/// want on a phone.
///
/// The two chevrons beside Gather's microphone and camera open device pickers.
/// A phone has one microphone and two cameras, and the second is a button rather
/// than a menu, so those are gone too.
///
/// ## Off is red, and pressed is not
///
/// A muted microphone is drawn crossed out in [GatherTokens.danger], which is
/// what the media check already does and what Gather does. That is a *state*, and
/// states are allowed a colour. The D-pad's rule — pressed is a step of opacity,
/// never a different paint — is about a control being *pushed*, and still holds
/// for the press itself.
///
/// Nothing here is ever greyed out. A control that cannot do anything is not
/// dimmed, it is absent: the conversation button appears when there is a
/// conversation and is gone when there is not, so the bar never contains a
/// button that does nothing when pressed.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/app_state.dart';
import '../theme/gather_theme.dart';
import 'status_sheet.dart';

/// The eight, in Gather's own order.
///
/// The codepoints matter and are not decorative: two of these carry a variation
/// selector (`❤️` is `U+2764 U+FE0F`, `👍️` is `U+1F44D U+FE0F`) and Gather echoes
/// the string back to every other client exactly as sent. Dropping the selector
/// produces a different character, which renders as a dingbat heart on somebody
/// else's screen rather than the red one they expected.
const _emotes = ['👋', '❤️', '🎉', '👍️', '🤣', '👏', '💯', '🔥'];

/// Matches the rail below it, so two islands read as one system.
const double _barHeight = 56;

/// How much taller the dock is while the office is carrying these.
///
/// The shell already hands every tab the rail's height as bottom padding, which
/// is why the D-pad and the legend needed no changes to clear it. This is the
/// same trick one layer in: the map tab gets this row on top, so its overlays
/// lift above the whole dock without knowing it has more than one row.
///
/// The row plus the hairline under it, and no gap — the two rows are attached.
/// The reaction tray is not counted: it is up for about a second, and reserving
/// permanent floor for it would cost the office a strip all day.
const double kControlBarInset = _barHeight + 1;

class ControlBar extends StatefulWidget {
  const ControlBar({super.key, required this.state});

  final AppState state;

  @override
  State<ControlBar> createState() => _ControlBarState();
}

class _ControlBarState extends State<ControlBar> {
  bool _tray = false;

  /// Puts a failure in front of the person, in the app's one existing way.
  ///
  /// Every action here returns null or a sentence — the contract `setPartyMode`
  /// set — so success is silent and only a refusal ever interrupts.
  Future<void> _run(Future<String?> Function() action) async {
    final failed = await action();
    if (!mounted || failed == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failed)));
  }

  void _toggleTray() {
    HapticFeedback.selectionClick();
    setState(() => _tray = !_tray);
  }

  Future<void> _send(String emote) async {
    HapticFeedback.selectionClick();
    setState(() => _tray = false);
    await _run(() => widget.state.sendEmote(emote));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final state = widget.state;
    final call = state.call;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // A row of the same island rather than a thing floating over it: the tray
        // pushes the dock upwards when it opens and lets it back down when a
        // reaction is picked, so nothing ever overlaps anything.
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: _tray ? _Tray(onPick: _send) : const SizedBox(width: double.infinity),
        ),
        SizedBox(
          height: _barHeight,
          child: Row(
            // Spread across the dock's width rather than bunched at the left: the
            // nav row underneath is the same width and does the same, so the two
            // rows' plates line up as a grid instead of drifting apart.
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _SelfButton(state: state, onTap: () => showStatusSheet(context, state)),
              const _Rule(),
              _BarButton(
                icon: call.micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                label: call.micOn ? 'Mute' : 'Unmute',
                tint: call.micOn ? t.brand : t.danger,
                onTap: () => _run(() => state.setMicOn(!call.micOn)),
              ),
              _BarButton(
                icon: call.cameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                label: call.cameraOn ? 'Turn the camera off' : 'Turn the camera on',
                tint: call.cameraOn ? t.brand : t.danger,
                onTap: () => _run(() => state.setCameraOn(!call.cameraOn)),
              ),
              // Only once there is a camera running to flip. Absent rather than
              // dimmed, like everything else here.
              if (call.cameraOn)
                _BarButton(
                  icon: Icons.cameraswitch_rounded,
                  label: 'Switch camera',
                  onTap: state.switchCamera,
                ),
              const _Rule(),
              _BarButton(
                icon: Icons.add_reaction_outlined,
                label: 'React',
                on: _tray,
                onTap: _toggleTray,
              ),
              _BarButton(
                icon: Icons.back_hand_outlined,
                label: state.handRaised ? 'Lower your hand' : 'Raise your hand',
                on: state.handRaised,
                onTap: () => _run(() => state.setHandRaised(!state.handRaised)),
              ),
              if (state.inHuddle) ...[
                const _Rule(),
                _BarButton(
                  icon: Icons.logout_rounded,
                  label: 'Leave the conversation',
                  onTap: () => _run(state.leaveHuddle),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// You: a coloured disc with your initial and the dot that says how available you
/// are, which is the same dot the map draws over your head.
///
/// Gather shows your camera here. This does not, and the reason is not laziness:
/// the preview would have to reach past [Call] for a `MediaStream` and drag the
/// WebRTC plugin into the widget layer, and the tile is 40 points across — at
/// which size a face is a smudge and the thing worth showing is whether you are
/// marked busy.
class _SelfButton extends StatelessWidget {
  const _SelfButton({required this.state, required this.onTap});

  final AppState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final me = state.mePerson;
    final label = me?.label ?? 'You';
    final id = me?.id ?? 'me';

    return Semantics(
      button: true,
      label: 'You — ${availabilityLabel(state.myAvailability ?? 'Active')}. '
          'Set your status',
      child: Tooltip(
        message: 'Your status',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(t.radius - 2),
            child: SizedBox(
              width: 48,
              height: 44,
              child: Center(
                child: SizedBox(
                  width: 34,
                  height: 34,
                  // The dot hangs off the disc's corner, so it needs to be able to
                  // paint outside it.
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: avatarColor(id),
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          label.trim().isEmpty ? '?' : label.trim()[0].toUpperCase(),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      Positioned(
                        right: -1,
                        bottom: -1,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: availabilityColor(t, state.myAvailability),
                            shape: BoxShape.circle,
                            // Ringed in the bar's own fill, so the dot reads as
                            // sitting on top of the disc rather than cut into it.
                            border: Border.all(color: t.card, width: 2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One control: a glyph on a plate that fills in while it is on.
///
/// The same plate as the rail's destinations, one radius step inside the island
/// that holds it, so the two bars are visibly the same furniture.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.on = false,
    this.tint,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Whether this is a control that is currently *in* a state, as opposed to one
  /// that merely does something when pressed.
  final bool on;

  /// Overrides the colour entirely, for the two controls that are red when off
  /// rather than grey.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final radius = BorderRadius.circular(t.radius - 2);

    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: 46,
              height: 44,
              decoration: BoxDecoration(
                color: on ? t.secondary : Colors.transparent,
                borderRadius: radius,
              ),
              child: TweenAnimationBuilder<Color?>(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                tween: ColorTween(end: tint ?? (on ? t.brand : t.mutedForeground)),
                builder: (context, colour, _) => Icon(icon, size: 22, color: colour),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The hairline between groups. Three of them would be clutter; two is what turns
/// six glyphs into "me", "my hardware" and "the room".
class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 24,
        margin: const EdgeInsets.symmetric(horizontal: 5),
        color: context.tokens.border,
      );
}

/// The eight reactions, as the dock's top row.
///
/// Undecorated: the dock paints the island, and a second bordered box inside it
/// would read as a dialog sitting on a bar rather than as the bar having grown a
/// row.
class _Tray extends StatelessWidget {
  const _Tray({required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final emote in _emotes)
            Semantics(
              button: true,
              label: 'Send $emote',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => onPick(emote),
                  borderRadius: BorderRadius.circular(t.radius - 2),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: Text(emote, style: const TextStyle(fontSize: 21)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
