import 'package:flutter/material.dart';

class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    this.hintText = 'Търсене...',
    this.onChanged,
    this.onClear,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: Icon(Icons.search, color: Theme.of(context).hintColor),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return Semantics(
              label: 'Изчисти търсенето',
              button: true,
              child: IconButton(
                tooltip: 'Изчисти търсенето',
                icon: const Icon(Icons.close, size: 20),
                onPressed: onClear ?? () => controller.clear(),
              ),
            );
          },
        ),
      ),
    );
  }
}
