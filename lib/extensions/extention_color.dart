import 'package:flutter/material.dart';

extension ColorExtensions on Color {
  /// A safe alternative to `withOpacity` using `withAlpha`
  Color withOpacitySafe(double opacity) {
    assert(opacity >= 0.0 && opacity <= 1.0,
        'Opacity must be between 0.0 and 1.0');
    return withValues(alpha: opacity);
  }
}
