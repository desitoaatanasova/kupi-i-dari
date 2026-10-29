import 'package:flutter/material.dart';

@immutable
class Product {
  const Product({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.unitLabel,
  });

  final int id;
  final int categoryId;
  final String name;
  final String unitLabel;
}
