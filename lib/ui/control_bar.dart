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
/// ## What red means, and the one control that is dimmed
///
/// Red used to be the mute state: a crossed-out microphone painted in
/// [GatherTokens.danger]. It is not any more, because the glyph had already said
/// it. `mic_off` *is* a microphone with a line through it — the shape carries the
/// state — and painting it red as well spent the bar's one alarming colour on the
/// most ordinary thing a person does in a meeting. Off is now the same grey every
/// other resting icon is, and [GatherTokens.brand] marks the two controls that are
/// actually broadcasting.
///
/// Red is spent instead on the desk, where it says something no glyph can: you are
/// not where the office has you filed. The D-pad's rule — pressed is a step of
/// opacity, never a different paint — is about a control being *pushed*, and still
/// holds for the press itself.
///
/// The desk is also the one control here that is ever greyed out, against the
/// standing rule that a button which can do nothing is absent rather than dimmed.
/// The rule is right for the others: the conversation button appears when there is
/// a conversation to leave and is gone when there is not, and its absence costs the
/// reader nothing. Being at your own desk is different. It is the answer to "where
/// am I", it is the state a person opens the bar to check, and a button that has
/// vanished cannot tell anybody they have arrived. So the desk is absent only when
/// Gather has given you no desk at all, and dim when you are already sitting at it.
library;

import 'package:flutter/material.dart';
// For [RenderProxyBox] — `material.dart` does not re-export the render tree, and
// [_NoWidthOpinion] needs one box that measures itself differently.
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../src/app_state.dart';
import '../theme/gather_theme.dart';
import 'call_screen.dart';
import 'person_avatar.dart';
import 'status_sheet.dart';

/// The eight, in Gather's own order.
///
/// The codepoints matter and are not decorative: two of these carry a variation
/// selector (`❤️` is `U+2764 U+FE0F`, `👍️` is `U+1F44D U+FE0F`) and Gather echoes
/// the string back to every other client exactly as sent. Dropping the selector
/// produces a different character, which renders as a dingbat heart on somebody
/// else's screen rather than the red one they expected.
const _emotes = ['👋', '❤️', '🎉', '👍️', '🤣', '👏', '💯', '🔥'];

/// The controls' row. The nav row below is taller — it carries labels under its
/// icons — but both are rows of the same island, which is what keeps them one
/// system.
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

  /// The way back to your own desk, in the three states it has.
  ///
  /// Gather's own toolbar button, transcribed — the shape of it is not ours:
  ///
  /// ```js
  /// onClick: hasDesk ? () => moveSpaceUserToDesk() : () => startGuidedClaimDeskFlow(),
  /// disabled: currentUserAtDesk
  /// ```
  ///
  /// The desktop offers to *claim* a desk when you have none. This cannot: claiming
  /// one is a guided flow over a map you cannot edit from a phone. So the branch
  /// this app keeps is the other one, and no desk means no button — dimming it
  /// would tell somebody who has never had a desk that they are sitting at it.
  Widget _deskButton(BuildContext context, AppState state) {
    if (state.myDesk == null) return const SizedBox.shrink();
    final atDesk = state.atMyDesk;

    return _BarButton(
      icon: Icons.meeting_room_rounded,
      label: atDesk ? 'You are at your desk' : 'Back to my desk',
      tint: atDesk ? null : context.tokens.danger,
      onTap: atDesk ? null : () => _run(state.goToMyDesk),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final state = widget.state;
    final call = state.call;

    return Column(
      mainAxisSize: MainAxisSize.min,
      // The dock stretches this to the island's width; this passes that width on
      // to both rows, so the tray's eight reactions and the controls above the
      // navigation all divide the same span instead of each finding their own.
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
            // Spread across the dock's width rather than bunched at the left, so
            // the row reads as the island's contents and not as a strip taped to
            // one end of it.
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _SelfButton(state: state, onTap: () => showStatusSheet(context, state)),
              const _Rule(),
              _BarButton(
                icon: call.micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                label: call.micOn ? 'Mute' : 'Unmute',
                // Brand while it is live, and the bar's ordinary resting grey once
                // it is not. See the header: the crossed-out glyph is the state.
                tint: call.micOn ? t.brand : t.mutedForeground,
                onTap: () => _run(() => state.setMicOn(!call.micOn)),
              ),
              _BarButton(
                icon: call.cameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                label: call.cameraOn ? 'Turn the camera off' : 'Turn the camera on',
                tint: call.cameraOn ? t.brand : t.mutedForeground,
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
              // The way to the faces — including your own. The camera being on
              // is enough: turning it on and having nowhere to see the picture
              // reads as the camera not working, which is exactly how this was
              // first reported. A route rather than a panel, because an
              // `RTCVideoRenderer` that is off-screen still decodes, so the
              // surface should not exist while nobody is looking at it.
              if (call.hasCompany || call.cameraOn)
                _BarButton(
                  icon: Icons.groups_rounded,
                  label: call.hasCompany
                      ? 'See the conversation'
                      : 'See your camera',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CallScreen(state: state),
                    ),
                  ),
                ),
              const _Rule(),
              _BarButton(
                icon: Icons.add_reaction_outlined,
                label: 'React',
                on: _tray,
                onTap: _toggleTray,
              ),
              // Its own listener. Walking is deliberately not a `notifyListeners`
              // — movement must not wake the whole tree — and this is the one
              // control in the bar whose answer changes as you walk. Without it the
              // button stays red under the thumb that pressed it until something
              // unrelated happens to rebuild the bar.
              ListenableBuilder(
                listenable: state.positions,
                builder: (context, _) => _deskButton(context, state),
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

/// You: your own profile picture, with the dot that says how available you are —
/// the same dot the map draws over your head.
///
/// Gather shows your live camera here instead. This does not, and the reason is
/// not laziness: the preview would have to reach past [Call] for a `MediaStream`
/// and drag the WebRTC plugin into the widget layer. The picture you set is the
/// better thing to show anyway, because it is there before the camera is on and
/// stays there after it goes off.
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
            borderRadius: BorderRadius.circular(t.radius + 4),
            child: SizedBox(
              width: 48,
              height: 44,
              child: Center(
                child: PersonAvatar(
                  id: id,
                  label: label,
                  photoUrl: state.photoUrlFor(id),
                  size: 34,
                  availability: state.myAvailability ?? 'Active',
                  // Ringed in the dock's own fill, so the dot reads as sitting on
                  // the picture rather than cut into it.
                  dotRing: t.card,
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

  /// Null for a control that is present but cannot be pressed — see the header for
  /// why exactly one of these is allowed to exist.
  final VoidCallback? onTap;

  /// Whether this is a control that is currently *in* a state, as opposed to one
  /// that merely does something when pressed.
  final bool on;

  /// Overrides the colour entirely, for the controls that are painted by what they
  /// are reporting rather than by whether they are pressed.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Concentric with the island, like the nav plates below: the dock's corner
    // minus the inset to here. See `_NavItem` in home_shell.dart.
    final radius = BorderRadius.circular(t.radius + 4);
    // Dimmed rather than recoloured, so a control that has gone quiet is plainly
    // the same control. `tint` is ignored here on purpose: red means "go back", and
    // a faded red would read as a warning being whispered rather than withdrawn.
    final colour = onTap == null
        ? t.mutedForeground.withValues(alpha: 0.38)
        : tint ?? (on ? t.brand : t.mutedForeground);

    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            // A null callback is what makes the plate inert: no splash, no
            // highlight, no tap.
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
                tween: ColorTween(end: colour),
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
///
/// ## Why the eight divide the width instead of setting it
///
/// The whole dock is sized by an [IntrinsicWidth] over its rows, so anything with
/// an opinion about its own width can move the island. Eight 40-point reactions
/// have a very firm one — 328 points, eight past the [kRailMinWidth] floor the two
/// permanent rows settle on — and the island grew by those eight points every time
/// the tray opened and shrank back every time a reaction was picked. Nothing was
/// wrong with the tray; the dock was being asked a question by a row that is only
/// up for a second.
///
/// So the tray answers zero when asked how wide it wants to be ([_NoWidthOpinion])
/// and divides whatever it is handed between the eight ([Expanded]). The closed
/// tray already worked this way by accident: a childless `SizedBox(width:
/// double.infinity)` reports an intrinsic width of zero, which is exactly the
/// "fill it, don't set it" this needed all along.
class _Tray extends StatelessWidget {
  const _Tray({required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return _NoWidthOpinion(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            for (final emote in _emotes)
              Expanded(
                child: Semantics(
                  button: true,
                  label: 'Send $emote',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => onPick(emote),
                      borderRadius: BorderRadius.circular(t.radius + 4),
                      child: SizedBox(
                        height: 40,
                        child: Center(
                          child: Text(emote, style: const TextStyle(fontSize: 21)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A child that takes the width it is given and asks for none of its own.
///
/// [RenderProxyBox] passes layout, painting and hit-testing straight through and
/// forwards every intrinsic measurement to the child; this overrides the two
/// horizontal ones to zero and leaves the vertical pair alone, because the dock
/// genuinely does need the tray's height to animate to. See [_Tray].
class _NoWidthOpinion extends SingleChildRenderObjectWidget {
  const _NoWidthOpinion({required Widget super.child});

  @override
  RenderProxyBox createRenderObject(BuildContext context) => _RenderNoWidthOpinion();
}

class _RenderNoWidthOpinion extends RenderProxyBox {
  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;
}
