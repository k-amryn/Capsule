import 'dart:ffi';
import 'dart:typed_data';
import 'camera_linux_bindings_generated.dart';
import 'package:ffi/ffi.dart';

class CameraLinux {
  late CameraLinuxBindings _bindings;

  CameraLinux() {
    final dylib = DynamicLibrary.open('libcamera_linux.so');
    _bindings = CameraLinuxBindings(dylib);
  }

  void initializeCamera() {
    _bindings.startVideoCaptureInThread();
  }

  void stopCamera() {
    _bindings.stopVideoCapture();
  }

  /// Returns the latest camera frame as raw JPEG bytes, or null if no frame
  /// is available yet.
  Uint8List? captureFrame() {
    final lengthPtr = calloc<Int>();
    try {
      final framePointer = _bindings.getLatestFrameBytes(lengthPtr);
      final length = lengthPtr.value;
      if (framePointer == nullptr || length <= 0) {
        return null;
      }
      return Uint8List.fromList(framePointer.asTypedList(length));
    } finally {
      calloc.free(lengthPtr);
    }
  }
}
