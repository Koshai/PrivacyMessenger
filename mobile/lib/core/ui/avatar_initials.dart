import 'package:flutter/material.dart';

/// Circle avatar with a single letter from [email] or [label].
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({
    super.key,
    this.email,
    this.label,
    this.radius,
  });

  final String? email;
  final String? label;
  final double? radius;

  static String initialFor({String? email, String? label}) {
    final source = (label ?? email ?? '').trim();
    if (source.isEmpty) return '?';
    final at = source.indexOf('@');
    final local = at > 0 ? source.substring(0, at) : source;
    return local[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final letter = initialFor(email: email, label: label);
    return CircleAvatar(
      radius: radius,
      child: Text(letter),
    );
  }
}
