import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models/compression_settings.dart';
import 'ffmpeg_service.dart';
import 'widgets/before_after.dart';

class ImageEditor extends StatefulWidget {
  final XFile file;
  final VoidCallback onClear;
  final ImageSettings? settings;
  final ValueChanged<ImageSettings>? onSettingsChanged;
  final VoidCallback? onSaveBatch;
  final String? progressLabel;
  final double? batchProgress;

  const ImageEditor({
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
  State<ImageEditor> createState() => _ImageEditorState();
}

class _ImageEditorState extends State<ImageEditor> {
  File? _compressedFile;
  File? _previewFile;
  bool _isCompressing = false;
  double _quality = 80;
  String? _originalSize;
  String? _compressedSize;
  String _outputFormat = 'jpg';
  double _resolution = 1.0; // 1.0, 0.5, 0.25
  Size? _originalResolution;
  late FfmpegService _ffmpegService;
  FfmpegTask? _currentTask;
  int _jobId = 0;
  int _previewJobId = 0;
  int _previewKey = 0;

  @override
  void dispose() {
    _currentTask?.cancel();
    super.dispose();
  }
  
  @override
  void initState() {
    super.initState();
    _ffmpegService = FfmpegServiceFactory.create();
    _ffmpegService.init();
    _updateOriginalSize();
    _generatePreview();
    if (widget.settings != null) {
      _outputFormat = widget.settings!.outputFormat;
      _quality = widget.settings!.quality;
      _resolution = widget.settings!.resolution;
    }
    _compressImage();
  }

  @override
  void didUpdateWidget(covariant ImageEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _updateOriginalSize();
      _generatePreview();
      _compressImage();
    }
    if (widget.settings != null && widget.settings != oldWidget.settings) {
      setState(() {
        _outputFormat = widget.settings!.outputFormat;
        _quality = widget.settings!.quality;
        _resolution = widget.settings!.resolution;
      });
      _compressImage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.of(context).size.width < 600;

    return Stack(
      children: [
        // Layer 1: Image Viewer
        Positioned.fill(
          child: Container(
            color: Colors.transparent,
            child: BeforeAfter(
              original: Image.file(
                _previewFile ?? File(widget.file.path),
                fit: BoxFit.contain,
                alignment: Alignment.center,
              ),
              compressed: _compressedFile != null
                  ? Image.file(
                      _compressedFile!,
                      key: ValueKey(_previewKey),
                      fit: BoxFit.contain,
                      alignment: Alignment.center,
                    )
                  : null,
            ),
          ),
        ),

        // Layer 2: Floating Controls
        Positioned(
          left: isNarrow ? 20 : null,
          right: 20,
          bottom: 20,
          child: Card(
            color: Colors.black.withValues(alpha: 0.9),
            elevation: 8,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Container(
              width: isNarrow ? double.infinity : 300,
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // File Size Info
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Original', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          Text(_originalSize ?? '-', style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const Icon(Icons.arrow_forward, size: 16, color: Colors.grey),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text('Compressed', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          if (_isCompressing && widget.batchProgress == null)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Text(_compressedSize ?? '-', style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ],
                  ),
                  const Divider(height: 16),

                  // Format Selection
                  SizedBox(
                    height: 40,
                    child: Row(
                      children: [
                        const Text('Format: '),
                        const Spacer(),
                        DropdownButton<String>(
                          value: _outputFormat,
                          isDense: true,
                          underline: Container(),
                          items: const [
                            DropdownMenuItem(value: 'jpg', child: Text('JPEG')),
                            DropdownMenuItem(value: 'png', child: Text('PNG')),
                            DropdownMenuItem(value: 'webp', child: Text('WEBP')),
                            DropdownMenuItem(value: 'avif', child: Text('AVIF')),
                          ],
                          onChanged: (String? newValue) {
                            if (newValue != null) {
                              setState(() {
                                _outputFormat = newValue;
                              });
                              if (widget.onSettingsChanged != null) {
                                widget.onSettingsChanged!(ImageSettings(
                                  outputFormat: _outputFormat,
                                  quality: _quality,
                                  resolution: _resolution,
                                ));
                              }
                              _compressImage();
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Resolution Selection
                  if (_originalResolution != null) ...[
                    SizedBox(
                      height: 40,
                      child: Row(
                        children: [
                          const Text('Resolution: '),
                          const Spacer(),
                          DropdownButton<double>(
                            value: _resolution,
                            isDense: true,
                            underline: Container(),
                            selectedItemBuilder: (BuildContext context) {
                              return [1.0, 0.5, 0.25].map<Widget>((double value) {
                                return Center(
                                  child: Text(
                                    value == 1.0 ? '100%' : (value == 0.5 ? '50%' : '25%'),
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                );
                              }).toList();
                            },
                            items: [
                              DropdownMenuItem(
                                value: 1.0,
                                child: _buildResolutionItem('100%', _originalResolution!),
                              ),
                              DropdownMenuItem(
                                value: 0.5,
                                child: _buildResolutionItem('50%', Size(_originalResolution!.width * 0.5, _originalResolution!.height * 0.5)),
                              ),
                              DropdownMenuItem(
                                value: 0.25,
                                child: _buildResolutionItem('25%', Size(_originalResolution!.width * 0.25, _originalResolution!.height * 0.25)),
                              ),
                            ],
                            onChanged: (double? newValue) {
                              if (newValue != null) {
                                setState(() {
                                  _resolution = newValue;
                                });
                                if (widget.onSettingsChanged != null) {
                                  widget.onSettingsChanged!(ImageSettings(
                                    outputFormat: _outputFormat,
                                    quality: _quality,
                                    resolution: _resolution,
                                  ));
                                }
                                _compressImage();
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Quality Slider
                  if (_outputFormat != 'png') ...[
                    SizedBox(
                      height: 40,
                      child: Row(
                        children: [
                          const Text('Quality: '),
                          Expanded(
                            child: Slider(
                              value: _quality,
                              min: 1,
                              max: 100,
                              divisions: 100,
                              label: _quality.round().toString(),
                              onChanged: (double value) {
                                setState(() {
                                  _quality = value;
                                });
                              },
                              onChangeEnd: (double value) {
                                if (widget.onSettingsChanged != null) {
                                  widget.onSettingsChanged!(ImageSettings(
                                    outputFormat: _outputFormat,
                                    quality: _quality,
                                    resolution: _resolution,
                                  ));
                                }
                                _compressImage();
                              },
                            ),
                          ),
                          Text('${_quality.round()}%'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Actions
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: widget.onClear,
                          child: const Text('Clear'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _compressedFile != null && widget.batchProgress == null ? (widget.onSaveBatch ?? _saveImage) : null,
                          icon: widget.batchProgress != null
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.save),
                          label: Text(widget.batchProgress != null ? 'Saving...' : 'Save'),
                        ),
                      ),
                    ],
                  ),
                  if (widget.batchProgress != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Column(
                        children: [
                          LinearProgressIndicator(value: widget.batchProgress),
                          const SizedBox(height: 4),
                          Text(widget.progressLabel ?? '${(widget.batchProgress! * 100).round()}%'),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _generatePreview() async {
    _previewJobId++;
    final myJobId = _previewJobId;

    final ext = p.extension(widget.file.path).toLowerCase();
    if (ext == '.avif' || ext == '.heic') {
      // Convert AVIF/HEIC to PNG for preview
      try {
        final tempDir = await getTemporaryDirectory();
        final previewPath = '${tempDir.path}/preview.png';
        final previewFile = File(previewPath);

        try {
          if (await previewFile.exists()) {
            await previewFile.delete();
          }
        } catch (e) {
          // Ignore race conditions
        }

        // Convert to PNG
        // Use rgba to ensure transparency is preserved if source has it
        final task = await _ffmpegService.execute('-y -i "${widget.file.path}" -pix_fmt rgba -frames:v 1 -update 1 "$previewPath"');
        await task.done;

        if (myJobId != _previewJobId) return;

        if (await previewFile.exists()) {
          // Clear cache
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();

          if (mounted) {
            setState(() {
              _previewFile = previewFile;
            });
          }
        }
      } catch (e) {
        debugPrint('Error generating preview: $e');
      }
    } else {
      // For supported formats, just use the file directly
      if (mounted) {
        setState(() {
          _previewFile = null;
        });
      }
    }
  }

  Future<void> _updateOriginalSize() async {
    final size = await widget.file.length();
    
    // Get image dimensions
    Size? resolution;
    try {
      final decodedImage = await decodeImageFromList(await File(widget.file.path).readAsBytes());
      resolution = Size(decodedImage.width.toDouble(), decodedImage.height.toDouble());
    } catch (e) {
      debugPrint('Error getting image dimensions: $e');
    }

    setState(() {
      _originalSize = _formatBytes(size);
      _originalResolution = resolution;
    });
  }

  Future<void> _compressImage() async {
    _jobId++;
    final myJobId = _jobId;

    _currentTask?.cancel();
    _currentTask = null;

    setState(() {
      _isCompressing = true;
      // Keep old compressed file visible while new one loads
    });

    try {
      final tempDir = await getTemporaryDirectory();
      // Use selected format extension
      final outputPath = '${tempDir.path}/compressed.$_outputFormat';

      // Ensure directory exists
      final outputDir = Directory(p.dirname(outputPath));
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }

      // Delete previous temp file if exists
      final outputFile = File(outputPath);
      try {
        if (await outputFile.exists()) {
          await outputFile.delete();
        }
      } catch (e) {
        // Ignore race conditions where file is deleted by another process
      }

      debugPrint('Starting compression for ${widget.file.path}');

      // Construct FFmpeg command
      // -y: overwrite output files
      // -i: input file

      int qValue = (31 - ((_quality - 1) * (29 / 99))).round();
      qValue = qValue.clamp(2, 31);

      String command;
      String scaleFilter = '';
      if (_resolution < 1.0) {
        // Scale width and height, ensuring even dimensions
        scaleFilter = '-vf scale=trunc(iw*$_resolution/2)*2:trunc(ih*$_resolution/2)*2';
      }

      if (_outputFormat == 'png') {
        // PNG (lossless, compression level 0-9, default is usually 6 or 7)
        command = '-y -i "${widget.file.path}" $scaleFilter -frames:v 1 -update 1 "$outputPath"';
      } else if (_outputFormat == 'webp') {
        // WEBP (0-100 quality)
        // Use yuva420p for transparency support
        command = '-y -i "${widget.file.path}" $scaleFilter -q:v ${_quality.round()} -pix_fmt yuva420p -frames:v 1 -update 1 "$outputPath"';
      } else if (_outputFormat == 'avif') {
        // AVIF
        int crf = (63 - ((_quality - 1) * (63 / 99))).round();
        crf = crf.clamp(0, 63);
        
        // Check if yuva420p is supported by the encoder
        bool supportsYuva420p = await _ffmpegService.hasPixelFormat('libaom-av1', 'yuva420p');
        
        if (supportsYuva420p) {
          // Use native transparency support
          command = '-y -i "${widget.file.path}" $scaleFilter -c:v libaom-av1 -crf $crf -cpu-used 6 -pix_fmt yuva420p -frames:v 1 -update 1 "$outputPath"';
        } else {
          // Use dual-stream encoding for transparency support
          String filterComplex;
          if (scaleFilter.isNotEmpty) {
            // Extract scale parameters from "-vf scale=..."
            final scaleParams = scaleFilter.replaceAll('-vf ', '');
            filterComplex = '[0:v]$scaleParams[scaled];[scaled]format=rgba[in];[in]split=2[color_in][alpha_in];[color_in]format=yuv420p[color];[alpha_in]alphaextract,format=gray,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709[alpha]';
          } else {
            filterComplex = '[0:v]format=rgba[in];[in]split=2[color_in][alpha_in];[color_in]format=yuv420p[color];[alpha_in]alphaextract,format=gray,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709[alpha]';
          }
          
          command = '-y -i "${widget.file.path}" -filter_complex "$filterComplex" -map "[color]" -map "[alpha]" -c:v libaom-av1 -crf $crf -cpu-used 6 -frames:v 1 -update 1 "$outputPath"';
        }
      } else {
        // JPEG
        command = '-y -i "${widget.file.path}" $scaleFilter -q:v $qValue -pix_fmt yuvj420p -frames:v 1 -update 1 "$outputPath"';
      }

      final task = await _ffmpegService.execute(command);
      _currentTask = task;
      await task.done;
      _currentTask = null;

      if (myJobId != _jobId) {
        debugPrint('Compression finished but job is stale (new job started)');
        return;
      }

      debugPrint('Compression finished');

      if (await outputFile.exists()) {
        final size = await outputFile.length();

        if (size > 0) {
          // Force image cache eviction to ensure UI updates
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();

          if (mounted) {
            setState(() {
              _compressedFile = outputFile;
              _compressedSize = _formatBytes(size);
              _previewKey++;
            });
          }
        } else {
          debugPrint('Compression failed: Output file is empty');
        }
      } else {
        debugPrint('Compression failed: Output file not created');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Compression failed: Output file not created')),
          );
        }
      }
    } catch (e, stackTrace) {
      if (e.toString().contains('cancelled')) {
        debugPrint('Compression cancelled');
        return;
      }
      debugPrint('Error compressing: $e');
      debugPrint('Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error compressing: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCompressing = false;
        });
      }
    }
  }

  Future<void> _saveImage() async {
    if (_compressedFile == null) return;

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        // Request permissions
        if (Platform.isAndroid) {
          // Gal handles permissions, but good to be explicit if needed
        }
        
        await Gal.putImage(_compressedFile!.path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Saved to Gallery')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error saving to gallery: $e')),
          );
        }
      }
    } else {
      final FileSaveLocation? result = await getSaveLocation(
        suggestedName: 'compressed.$_outputFormat',
        acceptedTypeGroups: [
          XTypeGroup(
            label: 'Images',
            extensions: [_outputFormat],
          ),
        ],
      );
      final String? fileName = result?.path;

      if (fileName == null) {
        // Operation was canceled by the user.
        return;
      }

      try {
        await _compressedFile!.copy(fileName);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved to $fileName')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error saving file: $e')),
          );
        }
      }
    }
  }

  String _formatBytes(int bytes, [int decimals = 2]) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
    var i = (bytes.toString().length - 1) ~/ 3; // Simplified log10
    // Or just loop
    i = 0;
    double v = bytes.toDouble();
    while (v >= 1024 && i < suffixes.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(decimals)} ${suffixes[i]}';
  }

  Widget _buildResolutionItem(String percentage, Size size) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(percentage, style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(
          '${size.width.round()} x ${size.height.round()}',
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ],
    );
  }
}