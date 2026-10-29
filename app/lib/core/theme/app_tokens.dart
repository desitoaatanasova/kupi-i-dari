import 'package:flutter/material.dart';

abstract class AppTokens {
  static const double radiusLarge = 14;
  static const double radiusMedium = 10;
  static const double radiusPill = 999;

  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;

  static const double touchTarget = 48;

  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x0F101828), offset: Offset(0, 1), blurRadius: 2),
    BoxShadow(color: Color(0x140D47A1), offset: Offset(0, 4), blurRadius: 12),
  ];
}
