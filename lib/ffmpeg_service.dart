import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

enum MediaType { video, audio, image, unknown }

class MediaInfo {
  final Duration duration;
  final int bitrate; // kbps

  final int width;
  final int height;

  MediaInfo({required this.duration, required this.bitrate, this.width = 0, this.height = 0});
}

class ProbeResult {
  final MediaType type;
  final bool isSupported;

  ProbeResult({required this.type, required this.isSupported});
}

class FfmpegTask {
  final Future<void> done;
  final VoidCallback cancel;

  FfmpegTask(this.done, this.cancel);
}

abstract class FfmpegService {
  Future<FfmpegTask> execute(String command, {void Function(double progress)? onProgress, Duration? totalDuration});
  Future<MediaInfo> getMediaInfo(String path);
  Future<ProbeResult> probeFile(String path);
  Future<bool> hasEncoder(String encoderName);
  Future<bool> hasPixelFormat(String encoderName, String pixelFormat);
  Future<bool> isUsingSystemFfmpeg();
  Future<bool> isAvailable();
  Future<void> init();
}

class FfmpegServiceFactory {
  static FfmpegService create() {
    if (Platform.isAndroid || Platform.isIOS) {
      return MobileFfmpegService();
    } else if (Platform.isMacOS) {
      return MacosHybridFfmpegService();
    } else {
      return DesktopFfmpegService();
    }
  }
}

class MobileFfmpegService implements FfmpegService {
  @override
  Future<void> init() async {
    // No initialization needed for mobile
  }

  @override
  Future<bool> isUsingSystemFfmpeg() async {
    return false;
  }

  @override
  Future<bool> isAvailable() async {
    return true;
  }

  @override
  Future<FfmpegTask> execute(String command, {void Function(double progress)? onProgress, Duration? totalDuration}) async {
    // FFmpegKit expects command without "ffmpeg" prefix if using execute()
    // But we are passing full command string often.
    // Actually, execute() takes a string of arguments.
    // Our command string usually starts with flags like "-y -i ...".
    // If the command string passed here starts with "ffmpeg", we should strip it?
    // The Desktop implementation uses Process.start(binary, args).
    // The args are parsed from the command string.
    // Let's parse args here too to be safe and consistent.
    
    // However, FFmpegKit.execute(String command) takes a single string.
    // If we pass "-y -i input.mp4 output.mp4", it works.
    
    final completer = Completer<void>();

    final session = await FFmpegKit.executeAsync(
      command,
      (session) async {
        // Complete callback
        completer.complete();
      },
      (log) {
        // Log callback
        debugPrint(log.getMessage());
      },
      (statistics) {
        // Statistics callback
        if (onProgress != null && totalDuration != null) {
          final time = statistics.getTime();
          if (time > 0) {
            final progress = time / totalDuration.inMilliseconds;
            onProgress(progress.clamp(0.0, 1.0));
          }
        }
      },
    );

    final doneFuture = completer.future.then((_) async {
      final returnCode = await session.getReturnCode();
      if (ReturnCode.isCancel(returnCode)) {
        throw Exception('FFmpeg cancelled');
      }
      if (!ReturnCode.isSuccess(returnCode)) {
        final failStackTrace = await session.getFailStackTrace();
        throw Exception('FFmpeg failed with return code $returnCode. $failStackTrace');
      }
    });

    return FfmpegTask(
      doneFuture,
      () {
        FFmpegKit.cancel(session.getSessionId());
      },
    );
  }

  @override
  Future<MediaInfo> getMediaInfo(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final info = session.getMediaInformation();
    
    if (info == null) {
      throw Exception('Failed to get media info');
    }

    final durationStr = info.getDuration();
    final bitrateStr = info.getBitrate();

    Duration duration = Duration.zero;
    if (durationStr != null) {
      final seconds = double.tryParse(durationStr);
      if (seconds != null) {
        duration = Duration(milliseconds: (seconds * 1000).round());
      }
    }

    int bitrate = 0;
    if (bitrateStr != null) {
      bitrate = int.tryParse(bitrateStr) ?? 0;
      // FFprobe returns bitrate in bps, we want kbps?
      // Desktop implementation parses "21640 kb/s".
      // FFprobeKit usually returns bps.
      // Let's convert to kbps to match desktop implementation expectation.
      bitrate = (bitrate / 1000).round();
    }

    // Parse Width and Height
    // Stream #0:0(und): Video: h264 (High) (avc1 / 0x31637661), yuv420p, 1920x1080 [SAR 1:1 DAR 16:9], 21640 kb/s, 29.97 fps, 29.97 tbr, 30k tbn, 59.94 tbc (default)
    // We need to find the video stream line.
    // FFprobeKit info object has getStreams().
    final streams = info.getStreams();
    int width = 0;
    int height = 0;
    for (final stream in streams) {
      if (stream.getType() == 'video') {
        width = stream.getWidth() ?? 0;
        height = stream.getHeight() ?? 0;
        break; // Use first video stream
      }
    }

    return MediaInfo(duration: duration, bitrate: bitrate, width: width, height: height);
  }

  @override
  Future<ProbeResult> probeFile(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final info = session.getMediaInformation();
    
    if (info == null) {
      return ProbeResult(type: MediaType.unknown, isSupported: false);
    }

    final streams = info.getStreams();
    bool hasVideo = false;
    bool hasAudio = false;

    for (final stream in streams) {
      if (stream.getType() == 'video') {
        // Check if it's an attached picture (cover art)
        // FFprobeKit Stream object might have disposition
        // But here we are using FFprobeKit which returns objects.
        // Let's check if we can detect attached pic.
        // The Stream object has getAllProperties().
        final props = stream.getAllProperties();
        bool isAttachedPic = false;
        if (props != null && props['disposition'] != null) {
           final disposition = props['disposition'];
           if (disposition is Map) {
             if (disposition['attached_pic'] == 1) {
               isAttachedPic = true;
             }
           }
        }
        
        if (!isAttachedPic) {
          hasVideo = true;
        }
      } else if (stream.getType() == 'audio') {
        hasAudio = true;
      }
    }

    if (hasVideo) {
      // Check if it's an image (single frame video stream usually, or specific codec)
      // But FFprobe usually distinguishes images if format is image2
      // For simplicity, if it has video stream, treat as video unless duration is very short/0?
      // Actually, images are often detected as video streams with 1 frame.
      // Let's check format name.
      final format = info.getFormat();
      if (format != null && (format.contains('image') || format.contains('png') || format.contains('jpeg') || format.contains('webp'))) {
         return ProbeResult(type: MediaType.image, isSupported: true);
      }
      return ProbeResult(type: MediaType.video, isSupported: true);
    } else if (hasAudio) {
      return ProbeResult(type: MediaType.audio, isSupported: true);
    }

    return ProbeResult(type: MediaType.unknown, isSupported: false);
  }

  @override
  Future<bool> hasEncoder(String encoderName) async {
    final completer = Completer<bool>();
    await FFmpegKit.executeAsync('-encoders', (session) async {
      final output = await session.getAllLogsAsString();
      completer.complete(output?.contains(encoderName) ?? false);
    });
    return completer.future;
  }

  @override
  Future<bool> hasPixelFormat(String encoderName, String pixelFormat) async {
    // Assume standard formats are supported on mobile
    if (pixelFormat == 'yuva420p') return true;
    return false;
  }
}

class DesktopFfmpegService implements FfmpegService {
  String? _binaryPath;
  bool _isSystemFfmpeg = false;

  @override
  Future<bool> isUsingSystemFfmpeg() async {
    if (_binaryPath == null) {
      await init();
    }
    return _isSystemFfmpeg;
  }

  @override
  Future<bool> isAvailable() async {
    if (_binaryPath == null) {
      await init();
    }
    return _binaryPath != null;
  }

  @override
  Future<void> init() async {
    if (_binaryPath != null) return;

    // Check if system ffmpeg is available
    try {
      final result = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        ['ffmpeg'],
      );
      
      if (result.exitCode == 0) {
        final systemPath = result.stdout.toString().trim().split('\n').first;
        if (systemPath.isNotEmpty) {
          _binaryPath = systemPath;
          _isSystemFfmpeg = true;
          debugPrint('Using system FFmpeg at $_binaryPath');
          return;
        }
      }
    } catch (e) {
      debugPrint('Error checking for system ffmpeg: $e');
    }

    debugPrint('System FFmpeg not found');
  }

  @override
  Future<FfmpegTask> execute(String command, {void Function(double progress)? onProgress, Duration? totalDuration}) async {
    if (_binaryPath == null) {
      await init();
    }
    
    if (_binaryPath == null) {
      throw Exception('FFmpeg not available');
    }

    final args = _parseArgs(command);
    
    // Add -nostdin to prevent hanging if ffmpeg waits for input
    if (!args.contains('-nostdin')) {
      args.insert(0, '-nostdin');
    }
    
    debugPrint('Executing: $_binaryPath ${args.join(' ')}');

    final process = await Process.start(_binaryPath!, args);
    bool isCancelled = false;

    // Listen to stderr for progress (FFmpeg writes stats to stderr)
    process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((data) {
      // debugPrint('FFmpeg stderr: $data'); // Too verbose for rapid updates
      if (onProgress != null && totalDuration != null) {
        _parseProgress(data, totalDuration, onProgress);
      }
    }, onError: (e) {
      debugPrint('FFmpeg stderr error: $e');
    });

    // Also listen to stdout just in case
    process.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen((data) {
      debugPrint('FFmpeg stdout: $data');
    }, onError: (e) {
      debugPrint('FFmpeg stdout error: $e');
    });

    final doneFuture = process.exitCode.then((exitCode) {
      if (isCancelled) {
        throw Exception('FFmpeg cancelled');
      }
      if (exitCode != 0) {
        throw Exception('FFmpeg failed with exit code $exitCode');
      }
    });

    return FfmpegTask(
      doneFuture,
      () {
        isCancelled = true;
        process.kill();
      },
    );
  }

  @override
  Future<MediaInfo> getMediaInfo(String path) async {
    if (_binaryPath == null) {
      await init();
    }

    // Run ffmpeg -i input
    final result = await Process.run(_binaryPath!, ['-i', path]);
    
    // Parse stderr (ffmpeg outputs info to stderr)
    final output = result.stderr.toString();
    
    // Parse Duration
    // Duration: 00:00:05.00
    final durationRegex = RegExp(r'Duration: (\d+):(\d+):(\d+\.\d+)');
    final durationMatch = durationRegex.firstMatch(output);
    Duration duration = Duration.zero;
    if (durationMatch != null) {
      final hours = int.parse(durationMatch.group(1)!);
      final minutes = int.parse(durationMatch.group(2)!);
      final seconds = double.parse(durationMatch.group(3)!);
      duration = Duration(
        hours: hours,
        minutes: minutes,
        milliseconds: (seconds * 1000).round(),
      );
    }

    // Parse Bitrate
    // bitrate: 21640 kb/s
    final bitrateRegex = RegExp(r'bitrate: (\d+) kb/s');
    final bitrateMatch = bitrateRegex.firstMatch(output);
    int bitrate = 0;
    if (bitrateMatch != null) {
      bitrate = int.parse(bitrateMatch.group(1)!);
    }

    // Parse Width and Height
    // Stream #0:0(und): Video: h264 (High) (avc1 / 0x31637661), yuv420p, 1920x1080 [SAR 1:1 DAR 16:9], ...
    // Regex for resolution: , (\d+)x(\d+)
    final resolutionRegex = RegExp(r', (\d+)x(\d+)');
    final resolutionMatch = resolutionRegex.firstMatch(output);
    int width = 0;
    int height = 0;
    if (resolutionMatch != null) {
      width = int.parse(resolutionMatch.group(1)!);
      height = int.parse(resolutionMatch.group(2)!);
    }

    return MediaInfo(duration: duration, bitrate: bitrate, width: width, height: height);
  }

  @override
  Future<ProbeResult> probeFile(String path) async {
    if (_binaryPath == null) {
      await init();
    }

    // Run ffmpeg -i path
    // We rely on ffmpeg output to detect streams
    // Add -nostdin to prevent hanging if ffmpeg waits for input
    final result = await Process.run(_binaryPath!, ['-nostdin', '-i', path]);
    final output = result.stderr.toString();
    
    debugPrint('Probe output for $path:\n$output');

    // Parse output line by line to detect streams and ignore attached pics
    final lines = output.split('\n');
    bool hasVideo = false;
    bool hasAudio = false;
    
    for (final line in lines) {
      if (line.contains('Video:')) {
        // Check if it's an attached picture (cover art)
        // Stream #0:1: Video: mjpeg, ... (attached pic)
        if (!line.contains('(attached pic)') && !line.contains('attached_pic')) {
          hasVideo = true;
        }
      }
      if (line.contains('Audio:')) {
        hasAudio = true;
      }
    }
    
    // Check for image formats
    // Input #0, png_pipe, from ...
    // Input #0, image2, from ...
    // Input #0, mjpeg, from ...
    bool isImage = output.contains('image2') || output.contains('png_pipe') || output.contains('jpeg_pipe') || output.contains('bmp_pipe') || output.contains('tiff_pipe') || output.contains('webp_pipe');
    
    if (isImage) {
       return ProbeResult(type: MediaType.image, isSupported: true);
    }

    if (hasVideo) {
      return ProbeResult(type: MediaType.video, isSupported: true);
    } else if (hasAudio) {
      return ProbeResult(type: MediaType.audio, isSupported: true);
    }

    // If ffmpeg recognized the format but no streams?
    // "Input #0, ..."
    if (output.contains('Input #0')) {
       // Recognized but maybe no streams or unknown
       return ProbeResult(type: MediaType.unknown, isSupported: true);
    }

    return ProbeResult(type: MediaType.unknown, isSupported: false);
  }

  @override
  Future<bool> hasEncoder(String encoderName) async {
    if (_binaryPath == null) {
      await init();
    }

    // Run ffmpeg -encoders
    final result = await Process.run(_binaryPath!, ['-encoders']);
    final output = result.stdout.toString();
    
    debugPrint('Available encoders check for $encoderName');
    
    return output.contains(encoderName);
  }

  @override
  Future<bool> hasPixelFormat(String encoderName, String pixelFormat) async {
    if (_binaryPath == null) {
      await init();
    }

    // Run ffmpeg -h encoder=name
    final result = await Process.run(_binaryPath!, ['-h', 'encoder=$encoderName']);
    final output = result.stdout.toString();
    
    // Look for "Supported pixel formats: ... pixelFormat ..."
    // Regex to find the line
    final regex = RegExp(r'Supported pixel formats:.*');
    final match = regex.firstMatch(output);
    if (match != null) {
      final supported = match.group(0)!;
      return supported.contains(pixelFormat);
    }
    return false;
  }

  void _parseProgress(String data, Duration totalDuration, void Function(double) onProgress) {
    // Look for time=HH:MM:SS.mm
    final regex = RegExp(r'time=(\d+):(\d+):(\d+\.\d+)');
    final match = regex.firstMatch(data);
    if (match != null) {
      try {
        final hours = int.parse(match.group(1)!);
        final minutes = int.parse(match.group(2)!);
        final seconds = double.parse(match.group(3)!);
        
        final currentDuration = Duration(
          hours: hours,
          minutes: minutes,
          milliseconds: (seconds * 1000).round(),
        );

        final progress = currentDuration.inMilliseconds / totalDuration.inMilliseconds;
        onProgress(progress.clamp(0.0, 1.0));
      } catch (e) {
        // Ignore parsing errors
      }
    }
  }

  List<String> _parseArgs(String command) {
    // Simple regex to split by space but respect quotes
    final RegExp regex = RegExp(r'[^\s"]+|"([^"]*)"');
    return regex.allMatches(command).map((m) {
      if (m.group(1) != null) {
        return m.group(1)!;
      }
      return m.group(0)!;
    }).toList();
  }
}

class MacosHybridFfmpegService implements FfmpegService {
  final _desktopService = DesktopFfmpegService();
  final _mobileService = MobileFfmpegService();
  FfmpegService? _activeService;

  @override
  Future<void> init() async {
    await _desktopService.init();
    if (await _desktopService.isAvailable()) {
      _activeService = _desktopService;
    } else {
      _activeService = _mobileService;
      await _mobileService.init();
    }
  }

  Future<FfmpegService> _getService() async {
    if (_activeService == null) {
      await init();
    }
    return _activeService!;
  }

  @override
  Future<FfmpegTask> execute(String command, {void Function(double progress)? onProgress, Duration? totalDuration}) async {
    final service = await _getService();
    return service.execute(command, onProgress: onProgress, totalDuration: totalDuration);
  }

  @override
  Future<MediaInfo> getMediaInfo(String path) async {
    final service = await _getService();
    return service.getMediaInfo(path);
  }

  @override
  Future<ProbeResult> probeFile(String path) async {
    final service = await _getService();
    return service.probeFile(path);
  }

  @override
  Future<bool> hasEncoder(String encoderName) async {
    final service = await _getService();
    return service.hasEncoder(encoderName);
  }

  @override
  Future<bool> hasPixelFormat(String encoderName, String pixelFormat) async {
    final service = await _getService();
    return service.hasPixelFormat(encoderName, pixelFormat);
  }

  @override
  Future<bool> isUsingSystemFfmpeg() async {
    final service = await _getService();
    return service.isUsingSystemFfmpeg();
  }

  @override
  Future<bool> isAvailable() async {
    final service = await _getService();
    return service.isAvailable();
  }
}