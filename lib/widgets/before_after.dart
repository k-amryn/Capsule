import 'package:flutter/material.dart';

class BeforeAfter extends StatefulWidget {
  final Widget original;
  final Widget? compressed;

  const BeforeAfter({
    super.key,
    required this.original,
    this.compressed,
  });

  @override
  State<BeforeAfter> createState() => _BeforeAfterState();
}

class _BeforeAfterState extends State<BeforeAfter> {
  double _splitPosition = 0.5;
  final TransformationController _controller = TransformationController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            // Layer 1: Original (Left side)
            Positioned.fill(
              child: ClipRect(
                clipper: _LeftClipper(_splitPosition),
                child: InteractiveViewer(
                  transformationController: _controller,
                  minScale: 0.1,
                  maxScale: 5.0,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  child: widget.original,
                ),
              ),
            ),

            // Layer 2: Compressed (Right side)
            if (widget.compressed != null)
              Positioned.fill(
                child: ClipRect(
                  clipper: _RightClipper(_splitPosition),
                  child: InteractiveViewer(
                    transformationController: _controller,
                    minScale: 0.1,
                    maxScale: 5.0,
                    boundaryMargin: const EdgeInsets.all(double.infinity),
                    child: widget.compressed!,
                  ),
                ),
              ),

            // Layer 3: Slider Handle
            Positioned(
              left: constraints.maxWidth * _splitPosition - 25,
              top: 0,
              bottom: 0,
              width: 50,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _splitPosition += details.delta.dx / constraints.maxWidth;
                    _splitPosition = _splitPosition.clamp(0.0, 1.0);
                  });
                },
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Vertical Line
                    CustomPaint(
                      size: const Size(4, double.infinity),
                      painter: _SliderLinePainter(),
                    ),
                    // Handle Icon
                    Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 4,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.compare_arrows, size: 28, color: Colors.black),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LeftClipper extends CustomClipper<Rect> {
  final double split;

  _LeftClipper(this.split);

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(0, 0, size.width * split, size.height);
  }

  @override
  bool shouldReclip(covariant _LeftClipper oldClipper) {
    return oldClipper.split != split;
  }
}

class _RightClipper extends CustomClipper<Rect> {
  final double split;

  _RightClipper(this.split);

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(size.width * split, 0, size.width * (1 - split), size.height);
  }

  @override
  bool shouldReclip(covariant _RightClipper oldClipper) {
    return oldClipper.split != split;
  }
}

class _SliderLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 4.0
      ..blendMode = BlendMode.difference;

    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}