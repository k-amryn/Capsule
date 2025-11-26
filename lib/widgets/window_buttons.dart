import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _WindowButton(
          icon: Icons.remove,
          onPressed: () {
            windowManager.minimize();
          },
        ),
        _WindowButton(
          icon: Icons.check_box_outline_blank, // Simple square for maximize/restore
          iconSize: 13,
          onPressed: () async {
            if (await windowManager.isMaximized()) {
              windowManager.unmaximize();
            } else {
              windowManager.maximize();
            }
          },
        ),
        _WindowButton(
          icon: Icons.close,
          isClose: true,
          onPressed: () {
            windowManager.close();
          },
        ),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final bool isClose;
  final double? iconSize;

  const _WindowButton({
    required this.icon,
    required this.onPressed,
    this.isClose = false,
    this.iconSize,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    Color backgroundColor = Colors.transparent;
    Color iconColor = Colors.white;

    if (_isHovering) {
      if (widget.isClose) {
        backgroundColor = Colors.red;
        iconColor = Colors.white;
      } else {
        backgroundColor = Colors.white.withValues(alpha: 0.1);
      }
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 46,
          height: 32, // Standard Windows title bar height is usually around 30-32
          color: backgroundColor,
          child: Icon(
            widget.icon,
            size: widget.iconSize ?? 16,
            color: iconColor,
          ),
        ),
      ),
    );
  }
}