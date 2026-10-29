import 'package:flutter/material.dart';

@immutable
class Location {
  const Location({
    required this.id,
    required this.name,
    required this.address,
    this.isActive = true,
  });

  final int id;
  final String name;
  final String address;
  final bool isActive;
}
