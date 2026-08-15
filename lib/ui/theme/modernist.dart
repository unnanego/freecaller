import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// The "Modernist" design system: flat and architectural — near-mono red on
/// off-white, Archivo throughout, zero corner radius, strong 2px rules.
/// Single source of truth for tokens; see design_handoff_caller_app/.
abstract final class Mod {
  // ── Colors ──────────────────────────────────────────────────────────────
  static const bg = Color(0xFFF3F2F2);
  static const surface = Color(0xFFEAE9E9);
  static const text = Color(0xFF201E1D);
  static const accent = Color(0xFFEC3013);
  static const accent600 = Color(0xFFDD2B0F);
  static const accent700 = Color(0xFFAE1800);
  // ── Call direction ──────────────────────────────────────────────────────
  // The only hues in an otherwise near-mono palette, and deliberately so: a
  // recents list is scanned rather than read, and direction is the thing being
  // scanned for. Both are darkened well past their usual web values to hold
  // contrast against the off-white background.
  static const callIncoming = Color(0xFF1B7F3B);
  static const callOutgoing = Color(0xFF1A5FC4);

  /// Unanswered, in either direction — the brand accent rather than a fourth
  /// hue, since "you did not connect" is exactly what it already means here.
  static const callUnanswered = accent;

  static const neutral500 = Color(0xFF9B9797);
  static const neutral600 = Color(0xFF7D7979);
  static const neutral700 = Color(0xFF605D5D);
  static const neutral900 = Color(0xFF2D2B2B);

  /// Major rules (2px) and the light row separators (~18%).
  static Color get divider => const Color(0xFF201E1D).withValues(alpha: 0.40);
  static Color get rowDivider => const Color(0xFF201E1D).withValues(alpha: 0.18);

  // ── Spacing ─────────────────────────────────────────────────────────────
  static const s1 = 4.0;
  static const s2 = 8.0;
  static const s3 = 12.0;
  static const s4 = 16.0;
  static const s6 = 24.0;
  static const s8 = 32.0;

  // ── Type (Archivo) ──────────────────────────────────────────────────────
  // Headings are weight 800 with tight tracking; kickers/captions are upper-
  // case with open tracking. Letter-spacing is expressed as a fraction of the
  // size (the CSS "em") and converted to logical pixels here.
  static TextStyle _archivo(
    double size,
    FontWeight weight, {
    Color? color,
    double emSpacing = 0,
    double height = 1.2,
  }) =>
      GoogleFonts.archivo(
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: emSpacing * size,
        color: color ?? text,
      );

  static TextStyle h1({Color? color}) =>
      _archivo(42, FontWeight.w800, color: color, emSpacing: -0.015, height: 1.05);
  static TextStyle h2({Color? color}) =>
      _archivo(32, FontWeight.w800, color: color, emSpacing: -0.015, height: 1.08);
  static TextStyle name({Color? color}) =>
      _archivo(17, FontWeight.w800, color: color);
  static TextStyle tileInitials(double size, {Color? color}) =>
      _archivo(size, FontWeight.w800, color: color);

  /// Small uppercase accent label above a title.
  static TextStyle kicker({Color? color}) => _archivo(11, FontWeight.w800,
      color: color ?? accent, emSpacing: 0.13, height: 1.2);

  /// 10–11px uppercase caption under a control button.
  static TextStyle caption({Color? color}) => _archivo(10, FontWeight.w800,
      color: color ?? text, emSpacing: 0.06, height: 1.2);

  static TextStyle body({Color? color}) =>
      _archivo(14, FontWeight.w400, color: color ?? neutral700, height: 1.5);
  static TextStyle meta({Color? color}) =>
      _archivo(12, FontWeight.w400, color: color ?? neutral600, height: 1.4);
  static TextStyle time({Color? color}) =>
      _archivo(11, FontWeight.w400, color: color ?? neutral600);

  /// Uppercase button label (primary/segmented).
  static TextStyle button({Color? color}) => _archivo(15, FontWeight.w800,
      color: color ?? bg, emSpacing: 0.02, height: 1.2);

  static ThemeData theme() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.light(
        primary: accent,
        onPrimary: bg,
        surface: bg,
        onSurface: text,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );
    return base.copyWith(
      textTheme: GoogleFonts.archivoTextTheme(base.textTheme).apply(
        bodyColor: text,
        displayColor: text,
      ),
    );
  }
}

/// Two-letter initials from a display name (falls back to "?").
String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    return parts.first.characters.take(2).toString().toUpperCase();
  }
  return (parts.first.characters.first + parts[1].characters.first).toUpperCase();
}

/// The square, bordered initials/avatar tile used across the app.
///
/// Shows [imageUrl] when the person has a picture and falls back to their
/// initials otherwise — including while the picture loads and if it fails, so a
/// slow or unreachable server never leaves a hole in a list.
class InitialsTile extends StatelessWidget {
  const InitialsTile({
    super.key,
    required this.name,
    this.size = 46,
    this.imageUrl = '',
  });

  final String name;
  final double size;
  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    final initials = Text(
      initialsOf(name),
      style: Mod.tileInitials(size * 0.33),
    );
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(border: Border.all(color: Mod.divider, width: 2)),
      child: imageUrl.isEmpty
          ? initials
          : Image.network(
              imageUrl,
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              loadingBuilder: (_, child, progress) =>
                  progress == null ? child : initials,
              errorBuilder: (_, _, _) => initials,
            ),
    );
  }
}
