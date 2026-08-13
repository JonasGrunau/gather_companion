/// A face, with a coloured initial behind it.
///
/// The first widget in this app that is genuinely wanted twice — the control bar
/// draws you, the activity tab draws whoever waved — which is why it is here
/// rather than private to one of them. `lib/ui/AGENTS.md` says there is no shared
/// widget library because nothing had needed to be shared; this is the exception
/// that earns one, and it should stay a very small one.
///
/// ## Where the picture comes from
///
/// `SpaceUser.profilePictureId` is a `UserFile` id and nothing more. The URL is a
/// REST lookup away, and the answer is a CloudFront signature that expires — all
/// of which is `ProfilePhotos`' problem, not this widget's. Here it is a nullable
/// string: present means draw it, absent means draw the initial.
///
/// ## Why the initial is not a fallback
///
/// It is the ground the picture is laid on, drawn first and always. Roughly half
/// a space has no profile picture — 45 of 98 on the one this was measured against
/// — so the coloured initial is the common case rather than the error case, and a
/// photo that is still loading, has expired, or 404s lands on a finished avatar
/// instead of a grey hole. Nothing ever flashes.
library;

import 'package:flutter/material.dart';

import '../theme/gather_theme.dart';

class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.id,
    required this.label,
    this.photoUrl,
    this.size = 30,
    this.availability,
    this.dotRing,
  });

  /// Their `SpaceUser` id, which is what picks the colour — so the same person
  /// keeps the same one between sessions without anybody storing it.
  final String id;
  final String label;

  /// A loadable URL, from `AppState.photoUrlFor`. Null draws the initial alone.
  final String? photoUrl;

  final double size;

  /// Draws the availability dot in the corner when given. Same value and same
  /// colour as the name plate over their head on the map.
  final String? availability;

  /// What the dot is ringed in — the colour of whatever it sits on, so it reads
  /// as resting on the avatar rather than being cut out of it.
  final Color? dotRing;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final initial = label.trim().isEmpty ? '?' : label.trim()[0].toUpperCase();
    final url = photoUrl;

    Widget face = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: avatarColor(id), shape: BoxShape.circle),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.44,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );

    if (url != null) {
      face = Stack(
        children: [
          face,
          ClipOval(
            child: Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              // Fades in over the initial rather than replacing it, so a face
              // arriving does not read as the avatar being redrawn.
              frameBuilder: (context, child, frame, wasSynchronous) => AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                child: child,
              ),
              // A signature that has expired, a picture that has been deleted, no
              // network. The initial is already underneath and is a perfectly
              // good answer, so none of them is worth a broken-image glyph.
              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
            ),
          ),
        ],
      );
    }

    if (availability == null) return face;

    // Proportional to the avatar so this works at 22 points in a chip and at 34
    // in the control bar without a second set of numbers.
    final dot = (size * 0.34).clamp(9.0, 14.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        // The dot hangs off the corner, so it has to paint outside the circle.
        clipBehavior: Clip.none,
        children: [
          face,
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: availabilityColor(t, availability),
                shape: BoxShape.circle,
                border: Border.all(color: dotRing ?? t.card, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
