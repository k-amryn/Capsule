import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Original BeforeAfter widget for two separate widgets (images, etc.)
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
            // Layer 1: Visuals (Non-interactive)
            IgnorePointer(
              child: Stack(
                children: [
                  // Original (Left side)
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

                  // Compressed (Right side)
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
                ],
              ),
            ),

            // Layer 2: Gesture Handler (Invisible)
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _controller,
                minScale: 0.1,
                maxScale: 5.0,
                boundaryMargin: const EdgeInsets.all(double.infinity),
                child: Opacity(
                  opacity: 0.0,
                  child: widget.original,
                ),
              ),
            ),

            // Layer 3: Slider Handle
            Positioned(
              left: constraints.maxWidth * _splitPosition - 25,
              top: 0,
              bottom: 0,
              width: 50,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
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
            ),
          ],
        );
      },
    );
  }
}

/// Composite BeforeAfter widget for a single side-by-side video.
/// The composite video has original on the left half and compressed on the right half.
/// This guarantees perfect frame-level synchronization since it's a single video stream.
class BeforeAfterComposite extends StatefulWidget {
  /// The video controller for the composite video (2x width: original|compressed)
  final VideoController controller;
  
  /// The aspect ratio of the ORIGINAL video (not the composite).
  /// The composite will be 2x this width.
  final double aspectRatio;
  
  /// Whether the composite video is ready to display
  final bool isReady;
  
  /// Optional external transformation controller to preserve pan/zoom state
  /// across widget rebuilds. If not provided, an internal controller is used.
  final TransformationController? transformController;

  const BeforeAfterComposite({
    super.key,
    required this.controller,
    required this.aspectRatio,
    this.isReady = true,
    this.transformController,
  });

  @override
  State<BeforeAfterComposite> createState() => _BeforeAfterCompositeState();
}

class _BeforeAfterCompositeState extends State<BeforeAfterComposite> {
  final ValueNotifier<double> _splitPosition = ValueNotifier(0.5);
  TransformationController? _internalTransformController;
  
  /// Returns the active transformation controller (external or internal)
  TransformationController get _transformController {
    if (widget.transformController != null) {
      return widget.transformController!;
    }
    _internalTransformController ??= TransformationController();
    return _internalTransformController!;
  }
  
  // Zoom constraints
  static const double _minScale = 0.5; // Allow zooming out to see more context
  static const double _maxScale = 5.0;
  static const double _scrollZoomFactor = 0.1;
  
  // Minimum pixels of content that must remain visible on screen
  static const double _minVisiblePixels = 100.0;
  
  // Store viewport size for boundary clamping
  Size _viewportSize = Size.zero;
  
  // Track current pan offset and scale directly
  Offset _panOffset = Offset.zero;
  double _scale = 1.0;
  
  // For pinch-to-zoom gesture tracking
  double _baseScale = 1.0;
  Offset _basePanOffset = Offset.zero;
  Offset _startFocalPoint = Offset.zero;

  @override
  void initState() {
    super.initState();
    // Initialize from external controller if provided
    if (widget.transformController != null) {
      _syncFromController();
    }
  }
  
  void _syncFromController() {
    final matrix = _transformController.value;
    _scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    _panOffset = Offset(translation.x, translation.y);
  }
  
  void _syncToController() {
    final matrix = Matrix4.identity()
      ..translate(_panOffset.dx, _panOffset.dy)
      ..scale(_scale);
    _transformController.value = matrix;
  }

  @override
  void dispose() {
    // Only dispose the internal controller, not the external one
    _internalTransformController?.dispose();
    _splitPosition.dispose();
    super.dispose();
  }

  /// Handle mouse scroll wheel for zoom
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // Determine zoom direction
      double scaleFactor;
      if (event.scrollDelta.dy < 0) {
        // Scroll up = zoom in
        scaleFactor = 1 + _scrollZoomFactor;
      } else {
        // Scroll down = zoom out
        scaleFactor = 1 - _scrollZoomFactor;
      }
      
      final newScale = (_scale * scaleFactor).clamp(_minScale, _maxScale);
      
      if (newScale != _scale) {
        // Get the pointer position relative to the widget
        final RenderBox? box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          final localPosition = box.globalToLocal(event.position);
          _zoomToPoint(localPosition, newScale);
        }
      }
    }
  }

  /// Zoom towards a specific point
  void _zoomToPoint(Offset focalPoint, double newScale) {
    // Calculate the focal point in content coordinates before scaling
    final focalPointInContent = (focalPoint - _panOffset) / _scale;
    
    // Apply new scale
    _scale = newScale;
    
    // Adjust pan so focal point stays in the same position on screen
    _panOffset = focalPoint - focalPointInContent * _scale;
    
    // Clamp to boundaries
    _clampPanOffset();
    
    _syncToController();
    // No setState needed, AnimatedBuilder listens to controller
  }

  /// Reset zoom to fit
  void _resetZoom() {
    _scale = 1.0;
    _panOffset = Offset.zero;
    _syncToController();
    // No setState needed
  }
  
  /// Clamp pan offset to keep at least minVisiblePixels of content on screen
  void _clampPanOffset() {
    // Calculate the scaled content size
    final scaledWidth = _viewportSize.width * _scale;
    final scaledHeight = _viewportSize.height * _scale;
    
    // Use fixed minimum visible area
    final minVisibleX = _minVisiblePixels.clamp(0.0, scaledWidth);
    final minVisibleY = _minVisiblePixels.clamp(0.0, scaledHeight);
    
    // Calculate pan bounds
    // Content can be panned so that at least minVisible pixels remain on screen
    // - When panning left (negative offset): right edge of content stays at least minVisible from left of viewport
    // - When panning right (positive offset): left edge of content stays at least minVisible from right of viewport
    
    final minPanX = _viewportSize.width - scaledWidth + minVisibleX - _viewportSize.width;
    final maxPanX = _viewportSize.width - minVisibleX;
    
    final minPanY = _viewportSize.height - scaledHeight + minVisibleY - _viewportSize.height;
    final maxPanY = _viewportSize.height - minVisibleY;
    
    _panOffset = Offset(
      _panOffset.dx.clamp(minPanX, maxPanX),
      _panOffset.dy.clamp(minPanY, maxPanY),
    );
  }
  
  // --- Gesture Handlers ---
  
  void _onScaleStart(ScaleStartDetails details) {
    _baseScale = _scale;
    _basePanOffset = _panOffset;
    _startFocalPoint = details.localFocalPoint;
  }
  
  void _onScaleUpdate(ScaleUpdateDetails details) {
    // Calculate total movement from the start of the gesture
    final focalDelta = details.localFocalPoint - _startFocalPoint;
    
    // Handle scaling (pinch zoom)
    if (details.scale != 1.0) {
      final newScale = (_baseScale * details.scale).clamp(_minScale, _maxScale);
      
      // Calculate the focal point in content coordinates at base scale
      final focalPointInContent = (_startFocalPoint - _basePanOffset) / _baseScale;
      
      _scale = newScale;
      // Adjust pan so focal point stays in the same position, plus any drag movement
      _panOffset = details.localFocalPoint - focalPointInContent * _scale;
    } else {
      // Handle panning only - use total delta from start, not incremental delta
      _panOffset = _basePanOffset + focalDelta;
    }
    
    // Clamp to boundaries
    _clampPanOffset();
    
    _syncToController();
    // No setState needed
  }
  
  void _onScaleEnd(ScaleEndDetails details) {
    // Final clamp
    _clampPanOffset();
    _syncToController();
    // No setState needed
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Store viewport size for boundary calculations
        _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        
        // Build the video halves ONCE for this layout
        // This prevents rebuilding the Video widget during pan/zoom/split
        final leftHalf = _buildCompositeHalf(constraints, Alignment.centerLeft);
        final rightHalf = _buildCompositeHalf(constraints, Alignment.centerRight);
        
        return Listener(
          onPointerSignal: _onPointerSignal,
          child: Stack(
            children: [
              // Layer 1: Composite Video Display
              if (widget.isReady)
                Positioned.fill(
                  child: ClipRect(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _splitPosition,
                      builder: (context, split, _) {
                        return AnimatedBuilder(
                          animation: _transformController,
                          builder: (context, _) {
                            return Stack(
                              children: [
                                // Left side (Original - left half of composite)
                                ClipRect(
                                  clipper: _LeftClipper(split),
                                  child: Transform(
                                    transform: _transformController.value,
                                    child: leftHalf,
                                  ),
                                ),
                                // Right side (Compressed - right half of composite)
                                ClipRect(
                                  clipper: _RightClipper(split),
                                  child: Transform(
                                    transform: _transformController.value,
                                    child: rightHalf,
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),

              // Layer 2: Gesture Handler (for pan/zoom gestures)
              if (widget.isReady)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTap: _resetZoom,
                    onScaleStart: _onScaleStart,
                    onScaleUpdate: _onScaleUpdate,
                    onScaleEnd: _onScaleEnd,
                    child: Container(color: Colors.transparent),
                  ),
                ),

              // Layer 3: Slider Handle
              ValueListenableBuilder<double>(
                valueListenable: _splitPosition,
                builder: (context, split, _) {
                  return Positioned(
                    left: constraints.maxWidth * split - 25,
                    top: 0,
                    bottom: 0,
                    width: 50,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeLeftRight,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragUpdate: (details) {
                          // Update value notifier directly, no setState
                          // Use _splitPosition.value to ensure we add delta to the latest value
                          double newSplit = _splitPosition.value + details.delta.dx / constraints.maxWidth;
                          _splitPosition.value = newSplit.clamp(0.0, 1.0);
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
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Builds a view showing either the left or right half of the composite video.
  ///
  /// The composite video is 2x the width of the display area:
  /// - Left half contains the original video
  /// - Right half contains the compressed video
  ///
  /// By using FittedBox with different alignments, we can show either half
  /// filling the entire display width.
  Widget _buildCompositeHalf(BoxConstraints constraints, Alignment alignment) {
    // The composite video has 2x the aspect ratio of the original
    // (because it's two videos side by side)
    final compositeAspectRatio = widget.aspectRatio * 2;
    
    return Center(
      child: AspectRatio(
        aspectRatio: widget.aspectRatio, // Display at original aspect ratio
        child: ClipRect(
          child: OverflowBox(
            maxWidth: double.infinity,
            alignment: alignment,
            child: AspectRatio(
              aspectRatio: compositeAspectRatio,
              child: Video(
                controller: widget.controller,
                fit: BoxFit.cover,
                controls: NoVideoControls,
              ),
            ),
          ),
        ),
      ),
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