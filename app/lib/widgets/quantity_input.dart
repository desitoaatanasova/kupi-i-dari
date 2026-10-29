import 'package:flutter/material.dart';

class QuantityInput extends StatelessWidget {
  const QuantityInput({
    super.key,
    this.controller,
    this.labelText,
    this.hintText,
    this.invalidValueMessage = 'Въведете цяло число.',
    this.tooLargeMessage = 'Твърде голямо число.',
    this.onChanged,
    this.enabled = true,
  });

  final TextEditingController? controller;
  final String? labelText;
  final String? hintText;
  final String invalidValueMessage;
  final String tooLargeMessage;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  static const int maxValue = 2147483647;

  static String? Function(String?) validator({
    String invalidValueMessage = 'Въведете цяло число.',
    String tooLargeMessage = 'Твърде голямо число.',
  }) {
    return (String? value) {
      if (value == null || value.isEmpty) return null;
      if (!RegExp(r'^\d+$').hasMatch(value)) return invalidValueMessage;
      if (int.parse(value) > maxValue) return tooLargeMessage;
      return null;
    };
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      keyboardType: const TextInputType.numberWithOptions(decimal: false),
      decoration: InputDecoration(labelText: labelText, hintText: hintText),
      validator: validator(
        invalidValueMessage: invalidValueMessage,
        tooLargeMessage: tooLargeMessage,
      ),
    );
  }
}
