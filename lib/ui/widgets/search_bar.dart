import 'package:flutter/material.dart';

class ContactSearchBar extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const ContactSearchBar({
    super.key,
    required this.controller,
    required this.onChanged,
  });

  @override
  State<ContactSearchBar> createState() => _ContactSearchBarState();
}

class _ContactSearchBarState extends State<ContactSearchBar> {
  bool _showClear = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: widget.controller,
        onChanged: (v) {
          setState(() => _showClear = v.isNotEmpty);
          widget.onChanged(v);
        },
        decoration: InputDecoration(
          hintText: '搜索姓名、电话或部门',
          hintStyle: TextStyle(color: colorScheme.outline),
          prefixIcon: Icon(Icons.search, color: colorScheme.outline, size: 22),
          suffixIcon: _showClear
              ? IconButton(
            icon: Icon(Icons.close, color: colorScheme.outline, size: 20),
            onPressed: () {
              widget.controller.clear();
              setState(() => _showClear = false);
              widget.onChanged('');
            },
          )
              : null,
          filled: true,
          fillColor: colorScheme.surfaceVariant.withOpacity(0.6),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
        style: const TextStyle(fontSize: 15),
      ),
    );
  }
}
