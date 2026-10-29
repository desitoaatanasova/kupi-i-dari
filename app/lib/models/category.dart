import 'package:flutter/material.dart';

@immutable
class Category {
  const Category({required this.id, required this.name, required this.icon});

  final int id;
  final String name;
  final IconData icon;
}
