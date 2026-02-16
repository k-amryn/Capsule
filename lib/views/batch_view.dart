import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../audio_editor.dart';
import '../ffmpeg_service.dart';
import '../image_editor.dart';
import '../models/compression_settings.dart';
import '../video_editor.dart';

class BatchView extends StatefulWidget {
  final List<XFile> files;
  final MediaType mediaType;
  final VoidCallback onClose;

  const BatchView({
    super.key,
    required this.files,
    required this.mediaType,
    required this.onClose,
  });

  @override
  State<BatchView> createState() => _BatchViewState();
}

class _BatchViewState extends State<BatchView> {
  final ScrollController _scrollController = ScrollController();
  int _selectedIndex = 0;
  CompressionSettings? _settings;
  bool _isSaving = false;
  double _batchProgress = 0.0;
  late FfmpegService _ffmpegService;
  String? _av1Encoder;
  String? _h265Encoder;
  String? _h264Encoder;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _ffmpegService = FfmpegServiceFactory.create();
    _ffmpegService.init().then((_) => _initializeEncoders());
    _initializeSettings();
  }

  Future<void> _initializeEncoders() async {
    _av1Encoder = await _ffmpegService.getBestEncoder([
      'libsvtav1',
      'av1_videotoolbox',
      'libaom-av1',
    ]);
    _h265Encoder = await _ffmpegService.getBestEncoder([
      'hevc_videotoolbox',
      'hevc_mediacodec',
      'hevc_nvenc',
      'hevc_amf',
      'hevc_qsv',
      'hevc_vaapi',
      'libx265',
    ]);
    _h264Encoder = await _ffmpegService.getBestEncoder([
      'h264_videotoolbox',
      'h264_mediacodec',
      'h264_nvenc',
      'h264_amf',
      'h264_qsv',
      'h264_vaapi',
      'libx264',
    ]);
  }

  void _initializeSettings() {
    switch (widget.mediaType) {
      case MediaType.video:
        _settings = VideoSettings();
        break;
      case MediaType.image:
        _settings = ImageSettings();
        break;
      case MediaType.audio:
        _settings = AudioSettings();
        break;
      case MediaType.unknown:
        // Should not happen in batch view as we filter before
        _settings = ImageSettings();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      body: Stack(
        children: [
          // Editor Area
          Positioned.fill(child: _buildEditor()),

          // Floating Thumbnails
          Positioned(
            top: 20,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                height: 80,
                constraints: const BoxConstraints(maxWidth: 800),
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      final newOffset =
                          _scrollController.offset + event.scrollDelta.dy;
                      if (newOffset >=
                              _scrollController.position.minScrollExtent &&
                          newOffset <=
                              _scrollController.position.maxScrollExtent) {
                        _scrollController.jumpTo(newOffset);
                      }
                    }
                  },
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(
                      dragDevices: {
                        PointerDeviceKind.touch,
                        PointerDeviceKind.mouse,
                      },
                    ),
                    child: ListView.builder(
                      controller: _scrollController,
                      scrollDirection: Axis.horizontal,
                      itemCount: widget.files.length,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shrinkWrap: true,
                      itemBuilder: (context, index) {
                        final file = widget.files[index];
                        final isSelected = index == _selectedIndex;
                        return Tooltip(
                          message: p.basename(file.path),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedIndex = index;
                                });
                              },
                              child: Container(
                                width: 60,
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                decoration: BoxDecoration(
                                  border: isSelected
                                      ? Border.all(
                                          color: Theme.of(context).primaryColor,
                                          width: 2,
                                        )
                                      : Border.all(
                                          color: Colors.white24,
                                          width: 1,
                                        ),
                                  borderRadius: BorderRadius.circular(8),
                                  color: Colors.black54,
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: _buildThumbnail(file),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnail(XFile file) {
    if (widget.mediaType == MediaType.image) {
      return Image.file(
        File(file.path),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            const Icon(Icons.broken_image, size: 20),
      );
    } else if (widget.mediaType == MediaType.video) {
      return const Center(
        child: Icon(Icons.videocam, color: Colors.white54, size: 24),
      );
    } else {
      return const Center(
        child: Icon(Icons.audiotrack, color: Colors.white54, size: 24),
      );
    }
  }

  Widget _buildEditor() {
    final file = widget.files[_selectedIndex];
    final progressLabel = _isSaving
        ? '${(_batchProgress * 100).round()}% (${(_batchProgress * widget.files.length).floor() + 1}/${widget.files.length})'
        : null;

    switch (widget.mediaType) {
      case MediaType.video:
        return VideoEditor(
          key: ValueKey(file.path), // Force rebuild on file change
          file: file,
          onClear: widget.onClose,
          settings: _settings as VideoSettings?,
          onSettingsChanged: (newSettings) {
            setState(() {
              _settings = newSettings;
            });
          },
          onSaveBatch: _saveBatch,
          batchProgress: _isSaving ? _batchProgress : null,
          progressLabel: progressLabel,
        );
      case MediaType.image:
        return ImageEditor(
          key: ValueKey(file.path),
          file: file,
          onClear: widget.onClose,
          settings: _settings as ImageSettings?,
          onSettingsChanged: (newSettings) {
            setState(() {
              _settings = newSettings;
            });
          },
          onSaveBatch: _saveBatch,
          batchProgress: _isSaving ? _batchProgress : null,
          progressLabel: progressLabel,
        );
      case MediaType.audio:
        return AudioEditor(
          key: ValueKey(file.path),
          file: file,
          onClear: widget.onClose,
          settings: _settings as AudioSettings?,
          onSettingsChanged: (newSettings) {
            setState(() {
              _settings = newSettings;
            });
          },
          onSaveBatch: _saveBatch,
          batchProgress: _isSaving ? _batchProgress : null,
          progressLabel: progressLabel,
        );
      case MediaType.unknown:
        return const Center(child: Text('Unknown media type'));
    }
  }

  Future<void> _saveBatch() async {
    if (_settings == null) return;

    setState(() {
      _isSaving = true;
      _batchProgress = 0.0;
    });

    try {
      String? outputDirPath;

      if (Platform.isAndroid || Platform.isIOS) {
        final tempDir = await getTemporaryDirectory();
        outputDirPath = tempDir.path;
      } else {
        final String? directoryPath = await getDirectoryPath();
        if (directoryPath == null) {
          setState(() {
            _isSaving = false;
          });
          return;
        }

        final folderName =
            'Batch_Compressed_${DateTime.now().millisecondsSinceEpoch}';
        final newDir = Directory(p.join(directoryPath, folderName));
        await newDir.create();
        outputDirPath = newDir.path;
      }

      int completed = 0;
      for (final file in widget.files) {
        await _processFile(file, outputDirPath, (fileProgress) {
          if (mounted) {
            setState(() {
              // Calculate total progress: (completed files + current file progress) / total files
              _batchProgress = (completed + fileProgress) / widget.files.length;
            });
          }
        });
        completed++;
      }

      // Ensure we hit 100% at the end
      if (mounted) {
        setState(() {
          _batchProgress = 1.0;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Batch processing complete! Saved to $outputDirPath'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error during batch processing: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _processFile(
    XFile file,
    String outputDir,
    Function(double) onProgress,
  ) async {
    final fileName = p.basenameWithoutExtension(file.path);
    String extension = '';
    String command = '';

    if (widget.mediaType == MediaType.video) {
      final s = _settings as VideoSettings;
      extension = s.outputFormat == 'vp9' ? 'webm' : 'mp4';

      String codec;
      String speed = '';

      if (s.outputFormat == 'av1') {
        codec = _av1Encoder ?? 'libaom-av1';
        speed = _ffmpegService.getPresetFlag(codec, '6');
      } else if (s.outputFormat == 'vp9') {
        codec = 'libvpx-vp9';
        speed = '-cpu-used 6';
      } else if (s.outputFormat == 'h265') {
        codec = _h265Encoder ?? 'libx265';
        speed = _ffmpegService.getPresetFlag(codec, 'fast');
      } else {
        // h264
        codec = _h264Encoder ?? 'libx264';
        speed = _ffmpegService.getPresetFlag(codec, 'fast');
      }

      final scaleFilter =
          'scale=trunc(iw*${s.resolution}/2)*2:trunc(ih*${s.resolution}/2)*2';
      final outputPath = p.join(outputDir, '$fileName.$extension');

      // Get duration for progress calculation
      Duration duration = Duration.zero;
      try {
        final info = await _ffmpegService.getMediaInfo(file.path);
        duration = info.duration;
      } catch (e) {
        debugPrint('Error getting duration for progress: $e');
      }

      try {
        await _ffmpegService
            .execute(
              '-y -i "${file.path}" -vf $scaleFilter -c:v $codec -b:v ${s.bitrate.round()}k $speed -pix_fmt yuv420p -threads 0 -row-mt 1 "$outputPath"',
              onProgress: onProgress,
              totalDuration: duration,
            )
            .then((t) => t.done);
      } catch (e) {
        // Check for hardware encoder failure and fallback
        bool isHardware = codec != 'libx264' &&
            codec != 'libx265' &&
            codec != 'libaom-av1' &&
            codec != 'libsvtav1' &&
            codec != 'libvpx-vp9';

        if (isHardware) {
          debugPrint(
              'Batch processing failed with $codec, falling back to software');

          // Update state for future files
          if (s.outputFormat == 'h265') {
            _h265Encoder = 'libx265';
            codec = 'libx265';
          } else if (s.outputFormat == 'h264') {
            _h264Encoder = 'libx264';
            codec = 'libx264';
          } else if (s.outputFormat == 'av1') {
            _av1Encoder = 'libaom-av1';
            codec = 'libaom-av1';
          }

          // Update speed preset for software
          if (s.outputFormat == 'av1') {
            speed = _ffmpegService.getPresetFlag(codec, '6');
          } else {
            speed = _ffmpegService.getPresetFlag(codec, 'fast');
          }

          // Retry with software encoder
          await _ffmpegService
              .execute(
                '-y -i "${file.path}" -vf $scaleFilter -c:v $codec -b:v ${s.bitrate.round()}k $speed -pix_fmt yuv420p -threads 0 -row-mt 1 "$outputPath"',
                onProgress: onProgress,
                totalDuration: duration,
              )
              .then((t) => t.done);
        } else {
          rethrow;
        }
      }
    } else if (widget.mediaType == MediaType.image) {
      final s = _settings as ImageSettings;
      extension = s.outputFormat;
      final outputPath = p.join(outputDir, '$fileName.$extension');

      String scaleFilter = '';
      if (s.resolution < 1.0) {
        scaleFilter =
            '-vf scale=trunc(iw*${s.resolution}/2)*2:trunc(ih*${s.resolution}/2)*2';
      }

      if (s.outputFormat == 'png') {
        command =
            '-y -i "${file.path}" $scaleFilter -frames:v 1 -update 1 "$outputPath"';
      } else if (s.outputFormat == 'webp') {
        command =
            '-y -i "${file.path}" $scaleFilter -c:v libwebp -q:v ${s.quality.round()} -pix_fmt yuva420p -frames:v 1 -update 1 "$outputPath"';
      } else if (s.outputFormat == 'avif') {
        // AVIF - Use two-step approach for transparency and resolution compatibility
        String inputPath = file.path;
        String? tempScaledPath;

        if (s.resolution < 1.0) {
          // Step 1: Scale to intermediate PNG (preserves transparency)
          final tempDir = await getTemporaryDirectory();
          tempScaledPath =
              '${tempDir.path}/temp_scaled_${p.basename(file.path)}.png';
          final scaleCommand =
              '-y -i "$inputPath" $scaleFilter -c:v png -pix_fmt rgba "$tempScaledPath"';
          await _ffmpegService.execute(scaleCommand).then((t) => t.done);
          inputPath = tempScaledPath;
        }

        final hasAlpha = await _ffmpegService.hasAlphaChannel(inputPath);
        int crf = (63 - (s.quality * 0.63)).round().clamp(0, 63);

        String filter;
        String mapping;
        if (hasAlpha) {
          // Use two-stream approach for transparency
          // Note: inputPath is already scaled if resolution < 1.0
          filter = '-filter_complex "[0:v]split[vcolor][valpha];[valpha]alphaextract[valphaout]"';
          mapping =
              '-map [vcolor] -c:v:0 libaom-av1 -crf:v:0 $crf -pix_fmt:v:0 yuv420p -map [valphaout] -c:v:1 libaom-av1 -crf:v:1 $crf -pix_fmt:v:1 gray -aom-params:v:1 matrix-coefficients=1';
          command =
              '-y -i "$inputPath" $filter $mapping -still-picture 1 -cpu-used 6 -strict experimental -frames:v:0 1 -frames:v:1 1 "$outputPath"';
        } else {
          // Single stream for non-transparent images
          // If inputPath was scaled, scaleFilter is already applied to it
          final currentFilter = tempScaledPath != null ? '' : scaleFilter;
          mapping = '-c:v libaom-av1 -crf $crf -pix_fmt yuv420p';
          command =
              '-y -i "$inputPath" $currentFilter $mapping -still-picture 1 -cpu-used 6 -strict experimental -frames:v 1 "$outputPath"';
        }

        // Execute AVIF conversion
        await _ffmpegService.execute(command).then((t) => t.done);

        // Clean up temp scaled PNG
        if (tempScaledPath != null) {
          try {
            await File(tempScaledPath).delete();
          } catch (_) {}
        }

        command = ''; // Skip default execution
      } else {
        // JPEG
        int qValue = (31 - ((s.quality - 1) * (29 / 99))).round().clamp(2, 31);
        command =
            '-y -i "${file.path}" $scaleFilter -q:v $qValue -pix_fmt yuvj420p -frames:v 1 -update 1 "$outputPath"';
      }

      if (command.isNotEmpty) {
        final task = await _ffmpegService.execute(command);
        // Image compression is usually fast, but we can simulate progress or just mark done
        // FFmpeg doesn't give great progress for single image
        onProgress(0.5);
        await task.done;
        onProgress(1.0);
      }
    } else if (widget.mediaType == MediaType.audio) {
      final s = _settings as AudioSettings;
      extension = s.outputFormat == 'mp3'
          ? 'mp3'
          : (s.outputFormat == 'opus' ? 'opus' : 'ogg');
      final outputPath = p.join(outputDir, '$fileName.$extension');

      String codec;
      if (s.outputFormat == 'mp3') {
        codec = 'libmp3lame';
      } else if (s.outputFormat == 'opus') {
        codec = 'libopus';
      } else {
        codec = 'libvorbis';
      }

      // Get duration for progress calculation
      Duration duration = Duration.zero;
      try {
        final info = await _ffmpegService.getMediaInfo(file.path);
        duration = info.duration;
      } catch (e) {
        debugPrint('Error getting duration for progress: $e');
      }

      await _ffmpegService
          .execute(
            '-y -i "${file.path}" -c:a $codec -b:a ${s.bitrate.round()}k "$outputPath"',
            onProgress: onProgress,
            totalDuration: duration,
          )
          .then((t) => t.done);
    }
  }
}
