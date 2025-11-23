import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class MediaInfo {
  final Duration duration;
  final int bitrate; // kbps

  MediaInfo({required this.duration, required this.bitrate});
}

class FfmpegTask {
  final Future<void> done;
  final VoidCallback cancel;

  FfmpegTask(this.done, this.cancel);
}

abstract class FfmpegService {
  Future<FfmpegTask> execute(String command, {void Function(double progress)? onProgress, Duration? totalDuration});
  Future<MediaInfo> getMediaInfo(String path);
  Future<bool> hasEncoder(String encoderName);
  Future<void> init();
}

class FfmpegServiceFactory {
  static FfmpegService create() {
    if (Platform.isAndroid || Platform.isIOS) {
      return MobileFfmpegService();
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

    return MediaInfo(duration: duration, bitrate: bitrate);
  }

  @override
  Future<bool> hasEncoder(String encoderName) async {
    // FFmpegKit min-gpl has standard encoders.
    // We can't easily check at runtime without parsing "ffmpeg -encoders".
    // But for now, let's assume standard ones are present.
    // If checking for hardware acceleration (videotoolbox/mediacodec),
    // min-gpl might not have them enabled or exposed easily via this check.
    // For Android, 'h264_mediacodec' might be available.
    return false;
  }
}

class DesktopFfmpegService implements FfmpegService {
  String? _binaryPath;

  @override
  Future<void> init() async {
    if (_binaryPath != null) return;

    // Check for system ffmpeg first
    final systemPaths = [
      '/opt/homebrew/bin/ffmpeg', // Apple Silicon Homebrew
      '/usr/local/bin/ffmpeg',    // Intel Homebrew
      '/usr/bin/ffmpeg',          // System (rarely has codecs)
    ];

    for (final path in systemPaths) {
      if (await File(path).exists()) {
        _binaryPath = path;
        debugPrint('Using system FFmpeg at $_binaryPath');
        return;
      }
    }

    // Fallback to bundled ffmpeg
    final appDir = await getApplicationSupportDirectory();
    final binDir = Directory(p.join(appDir.path, 'bin'));
    if (!await binDir.exists()) {
      await binDir.create(recursive: true);
    }

    String binaryName = 'ffmpeg';
    if (Platform.isWindows) {
      binaryName = 'ffmpeg.exe';
    }

    final binaryFile = File(p.join(binDir.path, binaryName));

    // Always copy for now to ensure we have the latest asset
    // In production, might want to check version or existence
    final byteData = await rootBundle.load('assets/bin/$binaryName');
    final buffer = byteData.buffer;
    await binaryFile.writeAsBytes(
      buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes),
    );

    if (Platform.isMacOS || Platform.isLinux) {
      await Process.run('chmod', ['+x', binaryFile.path]);
    }

    _binaryPath = binaryFile.path;
    debugPrint('Using bundled FFmpeg at $_binaryPath');
  }

  @override
  Future<FfmpegTask> execute(String command, {void Function(double progress)? onProgress, Duration? totalDuration}) async {
    if (_binaryPath == null) {
      await init();
    }

    final args = _parseArgs(command);
    
    debugPrint('Executing: $_binaryPath ${args.join(' ')}');

    final process = await Process.start(_binaryPath!, args);
    bool isCancelled = false;

    // Listen to stderr for progress (FFmpeg writes stats to stderr)
    process.stderr.transform(utf8.decoder).listen((data) {
      // debugPrint('FFmpeg stderr: $data'); // Too verbose for rapid updates
      if (onProgress != null && totalDuration != null) {
        _parseProgress(data, totalDuration, onProgress);
      }
    });

    // Also listen to stdout just in case
    process.stdout.transform(utf8.decoder).listen((data) {
      debugPrint('FFmpeg stdout: $data');
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

    return MediaInfo(duration: duration, bitrate: bitrate);
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