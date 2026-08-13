import 'package:flutter/material.dart';

/// Design tokens for the companion app.
///
/// The accent is Gather's own: `--theme-color-accent: #4257DA`, read out of the
/// v2 web app's stylesheet (`app.v2.gather.town/main.*.css`) rather than picked
/// by eye, along with the tint ramp around it. Gather sets its interface in
/// Inter, so the app asks for Inter first and falls back to the system face.
///
/// The structure of this file is deliberately the same shape as Superset's
/// `superset_theme.dart` — a `ThemeExtension` of flat colour tokens plus a
/// `context.tokens` accessor — so the two companion apps stay legible to the same
/// pair of eyes. Only the palette differs.
@immutable
class GatherTokens extends ThemeExtension<GatherTokens> {
  const GatherTokens({
    required this.background,
    required this.foreground,
    required this.card,
    required this.popover,
    required this.primary,
    required this.primaryForeground,
    required this.secondary,
    required this.muted,
    required this.mutedForeground,
    required this.faint,
    required this.border,
    required this.ring,
    required this.brand,
    required this.brandSoft,
    required this.brandTint,
    required this.ok,
    required this.warn,
    required this.danger,
    required this.radius,
  });

  final Color background;
  final Color foreground;
  final Color card;
  final Color popover;

  /// Interactive surfaces. Unlike Superset — whose primary is near-white — the
  /// primary action colour here *is* the brand, because Gather's own UI leads
  /// with it.
  final Color primary;
  final Color primaryForeground;
  final Color secondary;
  final Color muted;
  final Color mutedForeground;

  /// Tertiary text tier: timestamps, hints, chevrons. Still readable, unlike
  /// [border] or [ring].
  final Color faint;
  final Color border;
  final Color ring;

  /// `--theme-color-accent` — Gather blue.
  final Color brand;

  /// A lighter step of the same ramp (`#6886F2`), for text on dark fills where
  /// the full accent would be too dense to read.
  final Color brandSoft;

  /// The faintest tint (`#C2CEFB`), for wash backgrounds behind brand content.
  final Color brandTint;

  final Color ok;
  final Color warn;
  final Color danger;

  final double radius;

  /// Dark is the default: the app is glanced at, often in a dim room, and the
  /// feed reads better as light text on a settled ground.
  static const dark = GatherTokens(
    background: Color(0xFF0E1016),
    foreground: Color(0xFFECEEF5),
    card: Color(0xFF171A23),
    popover: Color(0xFF1B1F2A),
    primary: Color(0xFF4257DA),
    primaryForeground: Color(0xFFFFFFFF),
    secondary: Color(0xFF20242F),
    muted: Color(0xFF20242F),
    mutedForeground: Color(0xFF9BA3B7),
    faint: Color(0xFF6E768B),
    border: Color(0xFF262B38),
    ring: Color(0xFF394052),
    brand: Color(0xFF4257DA),
    brandSoft: Color(0xFF6886F2),
    brandTint: Color(0xFFC2CEFB),
    ok: Color(0xFF3FBF87),
    warn: Color(0xFFE0A22F),
    danger: Color(0xFFE2585F),
    radius: 12,
  );

  @override
  GatherTokens copyWith({
    Color? background,
    Color? foreground,
    Color? card,
    Color? popover,
    Color? primary,
    Color? primaryForeground,
    Color? secondary,
    Color? muted,
    Color? mutedForeground,
    Color? faint,
    Color? border,
    Color? ring,
    Color? brand,
    Color? brandSoft,
    Color? brandTint,
    Color? ok,
    Color? warn,
    Color? danger,
    double? radius,
  }) {
    return GatherTokens(
      background: background ?? this.background,
      foreground: foreground ?? this.foreground,
      card: card ?? this.card,
      popover: popover ?? this.popover,
      primary: primary ?? this.primary,
      primaryForeground: primaryForeground ?? this.primaryForeground,
      secondary: secondary ?? this.secondary,
      muted: muted ?? this.muted,
      mutedForeground: mutedForeground ?? this.mutedForeground,
      faint: faint ?? this.faint,
      border: border ?? this.border,
      ring: ring ?? this.ring,
      brand: brand ?? this.brand,
      brandSoft: brandSoft ?? this.brandSoft,
      brandTint: brandTint ?? this.brandTint,
      ok: ok ?? this.ok,
      warn: warn ?? this.warn,
      danger: danger ?? this.danger,
      radius: radius ?? this.radius,
    );
  }

  @override
  GatherTokens lerp(ThemeExtension<GatherTokens>? other, double t) {
    if (other is! GatherTokens) return this;
    return GatherTokens(
      background: Color.lerp(background, other.background, t)!,
      foreground: Color.lerp(foreground, other.foreground, t)!,
      card: Color.lerp(card, other.card, t)!,
      popover: Color.lerp(popover, other.popover, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      primaryForeground: Color.lerp(primaryForeground, other.primaryForeground, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      mutedForeground: Color.lerp(mutedForeground, other.mutedForeground, t)!,
      faint: Color.lerp(faint, other.faint, t)!,
      border: Color.lerp(border, other.border, t)!,
      ring: Color.lerp(ring, other.ring, t)!,
      brand: Color.lerp(brand, other.brand, t)!,
      brandSoft: Color.lerp(brandSoft, other.brandSoft, t)!,
      brandTint: Color.lerp(brandTint, other.brandTint, t)!,
      ok: Color.lerp(ok, other.ok, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      radius: radius + (other.radius - radius) * t,
    );
  }
}

/// Convenience accessor: `context.tokens.brand`.
extension GatherThemeContext on BuildContext {
  GatherTokens get tokens => Theme.of(this).extension<GatherTokens>() ?? GatherTokens.dark;
}

/// Screens use a 16px gutter; text that sits outside a card indents to 20px so it
/// lines up with carded content rather than with the screen edge.
const double kGutter = 16;
const double kTextGutter = 20;

/// The floating nav rail's own geometry, and the room it asks every tab to leave
/// at the bottom.
///
/// Here rather than in `ui/home_shell.dart` because the tabs need [kRailInset]
/// too — the shell adds it to their `MediaQuery` padding, and a screen placing
/// something over the rail by hand has to be able to ask how tall it is. Reading
/// it from the shell would mean each tab importing the thing that builds it.
const double kRailHeight = 56;
const double kRailGap = 8;
const double kRailInset = kRailHeight + kRailGap + 8;

const kMonoFallback = <String>[
  'SF Mono',
  'ui-monospace',
  'Menlo',
  'Monaco',
  'Courier New',
];

/// Gather sets its own interface in Inter; asking for it by name picks it up on
/// devices that have it and falls through to the platform face otherwise.
const kSans = 'Inter';
const kSansFallback = <String>['Inter', 'SF Pro Text', '-apple-system', 'Helvetica Neue'];

ThemeData buildGatherTheme() {
  const t = GatherTokens.dark;

  final base = ThemeData.dark(useMaterial3: true);
  final textTheme = base.textTheme
      .apply(
        bodyColor: t.foreground,
        displayColor: t.foreground,
        fontFamily: kSans,
        fontFamilyFallback: kSansFallback,
      )
      // Tighter tracking on headings: Inter at display sizes is loose by default
      // and reads as unset type rather than as a title.
      .copyWith(
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
          color: t.foreground,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: t.foreground,
        ),
      );

  return base.copyWith(
    scaffoldBackgroundColor: t.background,
    canvasColor: t.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: t.brand,
      brightness: Brightness.dark,
    ).copyWith(
      surface: t.background,
      onSurface: t.foreground,
      primary: t.brand,
      onPrimary: t.primaryForeground,
      secondary: t.secondary,
      error: t.danger,
      outline: t.border,
    ),
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: t.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
    ),
    dividerTheme: DividerThemeData(color: t.border, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.brand,
        foregroundColor: t.primaryForeground,
        minimumSize: const Size.fromHeight(50),
        textStyle: const TextStyle(
          fontFamily: kSans,
          fontFamilyFallback: kSansFallback,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radius)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.secondary,
      hintStyle: TextStyle(color: t.faint),
      labelStyle: TextStyle(color: t.mutedForeground),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(t.radius),
        borderSide: BorderSide(color: t.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(t.radius),
        borderSide: BorderSide(color: t.brand, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(t.radius),
        borderSide: BorderSide(color: t.danger),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.popover,
      contentTextStyle: TextStyle(color: t.foreground),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radius)),
    ),
    extensions: const [t],
  );
}

/// The dot beside a name, in the colour the state deserves.
///
/// Lives here rather than on the painter that used to own it, because three
/// things now draw it — the map's name plates, the control bar's avatar, and the
/// status sheet's picker — and a person's own dot disagreeing with the one over
/// their head would be the worst possible place for these to drift apart.
///
/// `Offline` deliberately falls through to [GatherTokens.ok] rather than to grey:
/// nothing offline is ever drawn, so reaching the fallback means the field was
/// absent, not that the person is away.
Color availabilityColor(GatherTokens t, String? availability) => switch (availability) {
      'Busy' => t.danger,
      'Focused' || 'FocusedCoworking' => t.warn,
      'Away' => t.faint,
      _ => t.ok,
    };

/// What the picker calls each one. Gather's own wording, which is worth keeping:
/// somebody who has seen the desktop client should not have to learn a second
/// vocabulary for the same three states.
String availabilityLabel(String availability) => switch (availability) {
      'Busy' => 'Busy',
      'Away' => 'Away',
      'Focused' || 'FocusedCoworking' => 'Focused',
      _ => 'Active',
    };

/// A stable colour per person, so the same face keeps the same dot across
/// sessions without the bridge having to send one.
///
/// Picked from the accent ramp and its neighbours rather than from the whole
/// wheel: a feed of arbitrary hues looks like a chart, not like a room.
Color avatarColor(String id) {
  const palette = [
    Color(0xFF4257DA),
    Color(0xFF6886F2),
    Color(0xFF5F4DC5),
    Color(0xFF00786F),
    Color(0xFF3FBF87),
    Color(0xFFE0A22F),
    Color(0xFFD33EF7),
    Color(0xFF2C86C4),
  ];
  var hash = 0;
  for (final unit in id.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return palette[hash % palette.length];
}
