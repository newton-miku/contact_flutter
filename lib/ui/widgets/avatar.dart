import 'package:flutter/material.dart';

class Avatar extends StatelessWidget {
  final String initials;
  final bool isSelected;
  final double size;

  const Avatar({
    super.key,
    required this.initials,
    this.isSelected = false,
    this.size = 52,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isSelected ? colorScheme.primary : colorScheme.primaryContainer,
        border: isSelected
            ? Border.all(color: colorScheme.primary.withValues(alpha: 0.4), width: 2)
            : null,
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.bold,
          color: isSelected ? colorScheme.onPrimary : colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
