import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../audio_editor.dart';
import '../image_editor.dart';
import '../video_editor.dart';

import '../ffmpeg_service.dart';

class CompressView extends StatefulWidget {
  final XFile? initialFile;
  final MediaType? mediaType;
  final VoidCallback? onClose;

  const CompressView({super.key, this.initialFile, this.mediaType, this.onClose});

  @override
  State<CompressView> createState() => _CompressViewState();
}

class _CompressViewState extends State<CompressView> {
  XFile? _droppedFile;
  @override
  void initState() {
    super.initState();
    if (widget.initialFile != null) {
      _droppedFile = widget.initialFile;
    }
  }

  @override
  void didUpdateWidget(covariant CompressView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialFile != null && widget.initialFile != oldWidget.initialFile) {
      setState(() {
        _droppedFile = widget.initialFile;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.transparent,
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_droppedFile == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.upload_file, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'Drag and drop media here',
              style: TextStyle(fontSize: 20, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    // Use provided media type if available, otherwise fallback to extension check
    if (widget.mediaType == MediaType.video) {
      return VideoEditor(
        file: _droppedFile!,
        onClear: () {
          widget.onClose?.call();
        },
      );
    } else if (widget.mediaType == MediaType.audio) {
      return AudioEditor(
        file: _droppedFile!,
        onClear: () {
          widget.onClose?.call();
        },
      );
    } else if (widget.mediaType == MediaType.image) {
      return ImageEditor(
        file: _droppedFile!,
        onClear: () {
          widget.onClose?.call();
        },
      );
    }

    // Fallback to extension check if type is unknown or not provided
    final ext = p.extension(_droppedFile!.path).toLowerCase();
    if (['.mp4', '.webm', '.mkv', '.mov', '.avi', '.flv', '.wmv', '.m4v', '.ts', '.3gp'].contains(ext)) {
      return VideoEditor(
        file: _droppedFile!,
        onClear: () {
          widget.onClose?.call();
        },
      );
    } else if (['.mp3', '.aac', '.ogg', '.wav', '.flac', '.m4a', '.opus', '.aiff', '.wma'].contains(ext)) {
      return AudioEditor(
        file: _droppedFile!,
        onClear: () {
          widget.onClose?.call();
        },
      );
    } else {
      // Default to image editor for unknown types (it might handle it or fail gracefully)
      return ImageEditor(
        file: _droppedFile!,
        onClear: () {
          widget.onClose?.call();
        },
      );
    }
  }
}