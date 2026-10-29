import 'package:flutter/material.dart';

enum ShiftStatus {
  draft('draft', 'Чернова', Color(0xFF4E342E), Color(0xFFF3ECE7)),
  upcoming('upcoming', 'Предстояща', Color(0xFF0D47A1), Color(0xFFE3F0FD)),
  available(
    'available',
    'Отворена за записване',
    Color(0xFF256428),
    Color(0xFFE7F5EC),
  ),
  almostFull(
    'almost_full',
    'Почти пълна',
    Color(0xFF8A5A00),
    Color(0xFFFFF6E0),
  ),
  full('full', 'Пълна', Color(0xFFC62828), Color(0xFFFDEBEA)),
  inProcess('in_process', 'В процес', Color(0xFF4A148C), Color(0xFFF3E8FB)),
  completed('completed', 'Завършена', Color(0xFF00695C), Color(0xFFE2F3F1)),
  archived('archived', 'Архивирана', Color(0xFF455A64), Color(0xFFEEF1F3));

  final String key;
  final String label;
  final Color textColor;
  final Color backgroundColor;

  const ShiftStatus(this.key, this.label, this.textColor, this.backgroundColor);

  static ShiftStatus? fromKey(String key) {
    for (final status in values) {
      if (status.key == key) return status;
    }
    return null;
  }
}
