import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'ffmpeg_service.dart';
import 'models/compression_settings.dart';
import 'widgets/before_after.dart';
import 'widgets/media_controls.dart';

class VideoEditor extends StatefulWidget {
  final XFile file;
  final VoidCallback onClear;
  final VideoSettings? settings;
  final ValueChanged<VideoSettings>? onSettingsChanged;
  final VoidCallback? onSaveBatch;
  final String? progressLabel;
  final double? batchProgress;

  const VideoEditor({
    super.key,
    required this.file,
    required this.onClear,
    this.settings,
    this.onSettingsChanged,
    this.onSaveBatch,
    this.progressLabel,
    this.batchProgress,
  });

  @override
  State<VideoEditor> createState() => _VideoEditorState();
}

class _VideoEditorState extends State<VideoEditor> {
  // Single composite player for synchronized before/after preview
  // The composite video has original on left half, compressed on right half
  late final Player _compositePlayer;
  late final VideoController _compositeController;
  
  // Transform controller for pan/zoom - persists across preview regenerations
  final TransformationController _transformController = TransformationController();

  bool _isCompressing = false;
  bool _isPreviewing = false;
  bool _isCompositeReady = false;
  double _bitrate = 5000; // kbps
  double _maxBitrate = 10000; // kbps
  String _outputFormat = 'av1'; // av1 or vp9
  final ValueNotifier<double> _scrubPosition = ValueNotifier(0.0); // 0.0 to 1.0
  Duration _videoDuration = Duration.zero;
  double _progress = 0.0;
  bool _hasAv1Hardware = false;
  String? _originalSize;
  double _resolution = 1.0; // 1.0, 0.5, 0.25
  double? _aspectRatio;
  int _originalWidth = 0;
  int _originalHeight = 0;
  
  late FfmpegService _ffmpegService;
  
  // Optimization
  Timer? _debounceTimer;
  FfmpegTask? _currentPreviewTask;

  @override
  void initState() {
    super.initState();
    _ffmpegService = FfmpegServiceFactory.create();
    _ffmpegService.init();

    // Initialize single composite player
    _compositePlayer = Player();
    _compositeController = VideoController(_compositePlayer);

    // Mute audio as requested
    _compositePlayer.setVolume(0);

    _initializeVideo();
    
    if (widget.settings != null) {
      _outputFormat = widget.settings!.outputFormat;
      _bitrate = widget.settings!.bitrate;
      _resolution = widget.settings!.resolution;
    }
  }

  @override
  void didUpdateWidget(covariant VideoEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _initializeVideo();
    }
    if (widget.settings != null && widget.settings != oldWidget.settings) {
      setState(() {
        _outputFormat = widget.settings!.outputFormat;
        _bitrate = widget.settings!.bitrate;
        _resolution = widget.settings!.resolution;
      });
      _debouncePreview();
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _currentPreviewTask?.cancel();
    
    _compositePlayer.dispose();
    _transformController.dispose();
    _scrubPosition.dispose();
    
    super.dispose();
  }

  Future<void> _initializeVideo() async {
    try {
      debugPrint('Initializing video: ${widget.file.path}');
      final file = File(widget.file.path);
      if (!await file.exists()) {
        throw Exception('File does not exist');
      }

      // 1. Get file size and media info
      int size = 0;
      try {
        size = await file.length();
      } catch (e) {
        debugPrint('Error getting file size: $e');
      }

      // Check for hardware acceleration
      try {
        _hasAv1Hardware = await _ffmpegService.hasEncoder('av1_videotoolbox');
      } catch (e) {
        debugPrint('Error checking encoders: $e');
      }

      // Get media info to set max bitrate and aspect ratio
      try {
        final info = await _ffmpegService.getMediaInfo(widget.file.path);
        if (info.bitrate > 0) {
          setState(() {
            _maxBitrate = info.bitrate.toDouble();
            _bitrate = (_maxBitrate * 0.5).clamp(10.0, 5000.0);
          });
        }
        if (info.width > 0 && info.height > 0) {
          setState(() {
            _aspectRatio = info.width / info.height;
            _videoDuration = info.duration;
            _originalWidth = info.width;
            _originalHeight = info.height;
          });
        }
      } catch (e) {
        debugPrint('Error getting media info: $e');
      }

      setState(() {
        _originalSize = _formatBytes(size);
      });
      
      // 2. Generate initial preview
      _generatePreview();
    } catch (e) {
      debugPrint('Error initializing video: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading video: $e')),
        );
      }
    }
  }

  void _onScrubChanged(double value) {
    _scrubPosition.value = value;
    // Clear composite preview while scrubbing
    if (_isCompositeReady) {
      setState(() {
        _isCompositeReady = false;
      });
    }
    _debouncePreview();
  }

  void _onBitrateChanged(double value) {
    setState(() {
      _bitrate = value;
    });
    _debouncePreview();
  }

  void _debouncePreview() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _generatePreview();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.of(context).size.width < 600;

    return Stack(
      children: [
        // Layer 1: Composite Video Viewer (synchronized before/after)
        Positioned.fill(
          child: Container(
            color: Colors.transparent,
            child: _isPreviewing && !_isCompositeReady
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Generating preview...', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  )
                : _aspectRatio != null
                    ? BeforeAfterComposite(
                        controller: _compositeController,
                        aspectRatio: _aspectRatio!,
                        isReady: _isCompositeReady,
                        transformController: _transformController,
                      )
                    : const Center(
                        child: Text('Loading video...', style: TextStyle(color: Colors.white)),
                      ),
          ),
        ),

        // Layer 2: Floating Controls
        Positioned(
          left: isNarrow ? 20 : null,
          right: 20,
          bottom: 20,
          child: ValueListenableBuilder<double>(
            valueListenable: _scrubPosition,
            builder: (context, scrubPos, _) {
              return MediaControls(
                width: isNarrow ? double.infinity : 350,
                scrubPosition: scrubPos,
                duration: _videoDuration,
                outputFormat: _outputFormat,
                bitrate: _bitrate,
                maxBitrate: _maxBitrate,
                isCompressing: _isCompressing || widget.batchProgress != null,
                isPreviewing: _isPreviewing,
                progress: widget.batchProgress ?? _progress,
                progressLabel: widget.progressLabel,
                originalSize: _originalSize,
                estimatedSize: _estimateSize(),
                hasAv1Hardware: _hasAv1Hardware,
                resolution: _resolution,
                onScrubChanged: _onScrubChanged,
                onScrubEnd: (value) {
                  _debounceTimer?.cancel();
                  _generatePreview();
                },
                onFormatChanged: (newValue) {
                  if (newValue != null) {
                    setState(() {
                      _outputFormat = newValue;
                    });
                    if (widget.onSettingsChanged != null) {
                      widget.onSettingsChanged!(VideoSettings(
                        outputFormat: _outputFormat,
                        bitrate: _bitrate,
                        resolution: _resolution,
                      ));
                    }
                    _generatePreview();
                  }
                },
                onResolutionChanged: (newValue) {
                  if (newValue != null) {
                    setState(() {
                      _resolution = newValue;
                    });
                    if (widget.onSettingsChanged != null) {
                      widget.onSettingsChanged!(VideoSettings(
                        outputFormat: _outputFormat,
                        bitrate: _bitrate,
                        resolution: _resolution,
                      ));
                    }
                    _generatePreview();
                  }
                },
                originalResolution: Size(
                  _originalWidth.toDouble(),
                  _originalHeight.toDouble(),
                ),
                onBitrateChanged: _onBitrateChanged,
                onBitrateEnd: (value) {
                  _debounceTimer?.cancel();
                  if (widget.onSettingsChanged != null) {
                    widget.onSettingsChanged!(VideoSettings(
                      outputFormat: _outputFormat,
                      bitrate: _bitrate,
                      resolution: _resolution,
                    ));
                  }
                  _generatePreview();
                },
                onClear: widget.onClear,
                onSave: widget.onSaveBatch ?? _saveVideo,
                formatItems: [
                  DropdownMenuItem(
                    value: 'av1',
                    child: Text('AV1 (MP4)${_hasAv1Hardware ? " [HW]" : ""}'),
                  ),
                  const DropdownMenuItem(value: 'vp9', child: Text('VP9 (WebM)')),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _generatePreview() async {
    // Cancel previous task if running
    _currentPreviewTask?.cancel();
    
    setState(() {
      _isPreviewing = true;
      _isCompositeReady = false;
    });

    try {
      final tempDir = await getTemporaryDirectory();
      
      // Use unique filenames to avoid lock issues
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final originalClipPath = p.join(tempDir.path, 'preview_original_$timestamp.mp4');
      final compressedClipPath = p.join(tempDir.path, 'preview_compressed_$timestamp.mp4');
      final compositePath = p.join(tempDir.path, 'preview_composite_$timestamp.mp4');
      final tempVp9Path = p.join(tempDir.path, 'temp_vp9_$timestamp.webm');
      
      // Calculate start time
      final startTime = _videoDuration.inMilliseconds * _scrubPosition.value / 1000.0;
      final startTimeStr = startTime.toStringAsFixed(3);

      // Determine codec and settings
      String codec;
      String speed = '';
      
      if (_outputFormat == 'av1') {
        if (_hasAv1Hardware) {
          codec = 'av1_videotoolbox';
        } else {
          codec = 'libaom-av1';
          speed = '-cpu-used 8'; // Fastest for preview
        }
      } else {
        codec = 'libvpx-vp9';
        speed = '-cpu-used 5';
      }
      
      debugPrint('Generating preview with codec: $codec');
      
      final scaleFilter = 'scale=trunc(iw*$_resolution/2)*2:trunc(ih*$_resolution/2)*2';

      // Step 1 & 2: Generate original and compressed clips in PARALLEL
      final originalFuture = _ffmpegService.execute(
        '-y -ss $startTimeStr -t 2 -i "${widget.file.path}" -c:v libx264 -preset ultrafast -crf 18 -an "$originalClipPath"'
      ).then((task) => task.done);

      Future<void> compressedFuture;
      
      if (_outputFormat == 'vp9') {
        // For VP9: First compress to VP9 (to generate artifacts), then transcode to H.264
        compressedFuture = _ffmpegService.execute(
          '-y -ss $startTimeStr -t 2 -i "${widget.file.path}" -vf $scaleFilter -c:v $codec -b:v ${_bitrate.round()}k $speed -threads 0 -row-mt 1 -an "$tempVp9Path"'
        ).then((task) {
          _currentPreviewTask = task;
          return task.done;
        }).then((_) => _ffmpegService.execute(
          '-y -i "$tempVp9Path" -c:v libx264 -preset ultrafast -crf 18 -threads 0 -an "$compressedClipPath"'
        )).then((task) {
          _currentPreviewTask = task;
          return task.done;
        });
      } else {
        // AV1 (or others) - direct compression to MP4
        compressedFuture = _ffmpegService.execute(
          '-y -ss $startTimeStr -t 2 -i "${widget.file.path}" -vf $scaleFilter -c:v $codec -b:v ${_bitrate.round()}k $speed -threads 0 -row-mt 1 -an "$compressedClipPath"'
        ).then((task) {
          _currentPreviewTask = task;
          return task.done;
        });
      }

      // Wait for both clips to be generated
      try {
        await Future.wait([originalFuture, compressedFuture]);
      } catch (e) {
        debugPrint('Preview generation failed with $codec: $e');
        // Fallback to H.264 if VP9/AV1 fails
        if (_outputFormat == 'vp9' || _outputFormat == 'av1') {
          debugPrint('Falling back to H.264 for preview');
          final fallbackTask = await _ffmpegService.execute(
            '-y -ss $startTimeStr -t 2 -i "${widget.file.path}" -vf $scaleFilter -c:v libx264 -preset ultrafast -b:v ${_bitrate.round()}k -an "$compressedClipPath"'
          );
          _currentPreviewTask = fallbackTask;
          await fallbackTask.done;
        } else {
          rethrow;
        }
      }

      // Step 3: Create composite video using FFmpeg hstack filter
      // This combines original (left) and compressed (right) into a single video
      // Using -crf 18 for high quality to preserve visible compression artifacts
      final compositeTask = await _ffmpegService.execute(
        '-y -i "$originalClipPath" -i "$compressedClipPath" '
        '-filter_complex "[0:v]setpts=PTS-STARTPTS[a];[1:v]setpts=PTS-STARTPTS[b];[a][b]hstack=inputs=2[v]" '
        '-map "[v]" -c:v libx264 -preset ultrafast -crf 18 -an "$compositePath"'
      );
      _currentPreviewTask = compositeTask;
      await compositeTask.done;

      // Step 4: Open composite video in player
      await _compositePlayer.open(Media(compositePath));
      await _compositePlayer.setPlaylistMode(PlaylistMode.loop);
      await _compositePlayer.play();

      if (mounted) {
        setState(() {
          _isPreviewing = false;
          _isCompositeReady = true;
        });
      }

    } catch (e) {
      if (e.toString().contains('cancelled')) {
        debugPrint('Preview generation cancelled');
      } else {
        debugPrint('Error generating preview: $e');
      }
      if (mounted) {
        setState(() {
          _isPreviewing = false;
          _isCompositeReady = false;
        });
      }
    }
  }

  Future<void> _saveVideo() async {
    setState(() {
      _isCompressing = true;
      _progress = 0.0;
    });

    try {
      String? outputPath;
      
      if (Platform.isAndroid || Platform.isIOS) {
        final tempDir = await getTemporaryDirectory();
        outputPath = '${tempDir.path}/compressed_${DateTime.now().millisecondsSinceEpoch}.${_outputFormat == 'vp9' ? 'webm' : 'mp4'}';
      } else {
        final FileSaveLocation? result = await getSaveLocation(
          suggestedName: 'compressed.${_outputFormat == 'vp9' ? 'webm' : 'mp4'}',
          acceptedTypeGroups: [
            XTypeGroup(
              label: 'Videos',
              extensions: [_outputFormat == 'vp9' ? 'webm' : 'mp4'],
            ),
          ],
        );
        outputPath = result?.path;
      }

      if (outputPath == null) {
        setState(() {
          _isCompressing = false;
        });
        return;
      }

      String codec;
      String speed = '';
      
      if (_outputFormat == 'av1') {
        if (_hasAv1Hardware) {
          codec = 'av1_videotoolbox';
        } else {
          codec = 'libaom-av1';
          speed = '-cpu-used 6'; // Faster encoding (4-6 is good balance, 8 is fastest)
        }
      } else {
        codec = 'libvpx-vp9';
        speed = '-cpu-used 6'; // Faster encoding
      }

      debugPrint('Saving video with codec: $codec');

      // Add -row-mt 1 for better multi-threading performance
      // Add scaling
      final scaleFilter = 'scale=trunc(iw*$_resolution/2)*2:trunc(ih*$_resolution/2)*2';
      
      final task = await _ffmpegService.execute(
        '-y -i "${widget.file.path}" -vf $scaleFilter -c:v $codec -b:v ${_bitrate.round()}k $speed -threads 0 -row-mt 1 "$outputPath"',
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _progress = progress;
            });
          }
        },
        totalDuration: _videoDuration,
      );
      await task.done;

      if (Platform.isAndroid || Platform.isIOS) {
        await Gal.putVideo(outputPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video saved to Gallery')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video saved successfully')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving video: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCompressing = false;
          _progress = 0.0;
        });
      }
    }
  }

  String _estimateSize() {
    // (Video Bitrate + Audio Bitrate) * Duration / 8
    // Assume 128kbps audio
    final totalBitrate = _bitrate + 128;
    final durationSeconds = _videoDuration.inSeconds;
    final sizeBytes = (totalBitrate * 1000 * durationSeconds) / 8;
    
    if (sizeBytes <= 0) return "~0 MB";
    
    if (sizeBytes < 1024 * 1024) {
      final sizeKB = sizeBytes / 1024;
      return '~${sizeKB.toStringAsFixed(0)} KB';
    }
    
    final sizeMB = sizeBytes / (1024 * 1024);
    return '~${sizeMB.toStringAsFixed(1)} MB';
  }

  String _formatBytes(int bytes, [int decimals = 2]) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
    var i = (bytes.toString().length - 1) ~/ 3;
    i = 0;
    double v = bytes.toDouble();
    while (v >= 1024 && i < suffixes.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(decimals)} ${suffixes[i]}';
  }
}