import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

class FrameEncoder {
  Future<Uint8List> encodeToJpeg(CameraImage frame) async {
    switch (frame.format.group) {
      case ImageFormatGroup.jpeg:
        return _jpegToJpeg(frame);

      case ImageFormatGroup.yuv420:
        return _yuv420ToJpeg(frame);

      case ImageFormatGroup.bgra8888:
        return _bgra8888ToJpeg(frame);

      case ImageFormatGroup.nv21:
        return _nv21ToJpeg(frame);

      case ImageFormatGroup.unknown:
        throw UnsupportedError(
          'Unknown camera image format: ${frame.format.raw}',
        );
    }
  }

  // Already encoded as JPEG
  Uint8List _jpegToJpeg(CameraImage frame) {
    if (frame.planes.isEmpty) {
      throw StateError('JPEG frame has no image data.');
    }

    return frame.planes.first.bytes;
  }

  // Supports both 3-plane YUV420 and 2-plane bi-planar YUV420
  Uint8List _yuv420ToJpeg(CameraImage frame) {
    if (frame.planes.length < 2) {
      throw StateError('Invalid YUV420 frame: expected at least 2 planes.');
    }

    final width = frame.width;
    final height = frame.height;

    final output = img.Image(width: width, height: height);

    final yPlane = frame.planes[0];

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yIndex = y * yPlane.bytesPerRow + x * (yPlane.bytesPerPixel ?? 1);

        final yValue = yPlane.bytes[yIndex];

        int uValue;
        int vValue;

        if (frame.planes.length >= 3) {
          final uPlane = frame.planes[1];
          final vPlane = frame.planes[2];

          final uvX = x ~/ 2;
          final uvY = y ~/ 2;

          final uIndex =
              uvY * uPlane.bytesPerRow + uvX * (uPlane.bytesPerPixel ?? 1);

          final vIndex =
              uvY * vPlane.bytesPerRow + uvX * (vPlane.bytesPerPixel ?? 1);

          uValue = uPlane.bytes[uIndex];
          vValue = vPlane.bytes[vIndex];
        } else {
          // Bi-planar YUV420 / NV12-style UV plane
          final uvPlane = frame.planes[1];

          final uvX = x ~/ 2;
          final uvY = y ~/ 2;
          final pixelStride = uvPlane.bytesPerPixel ?? 2;

          final uvIndex = uvY * uvPlane.bytesPerRow + uvX * pixelStride;

          uValue = uvPlane.bytes[uvIndex];
          vValue = uvPlane.bytes[uvIndex + 1];
        }

        _setYuvPixel(output, x, y, yValue, uValue, vValue);
      }
    }

    return Uint8List.fromList(img.encodeJpg(output, quality: 80));
  }

  // iOS-style BGRA8888
  Uint8List _bgra8888ToJpeg(CameraImage frame) {
    if (frame.planes.isEmpty) {
      throw StateError('BGRA8888 frame has no image data.');
    }

    final width = frame.width;
    final height = frame.height;

    final plane = frame.planes.first;

    final output = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      final rowStart = y * plane.bytesPerRow;

      for (int x = 0; x < width; x++) {
        final index = rowStart + (x * 4);

        final b = plane.bytes[index];
        final g = plane.bytes[index + 1];
        final r = plane.bytes[index + 2];
        final a = plane.bytes[index + 3];

        output.setPixelRgba(x, y, r, g, b, a);
      }
    }

    return Uint8List.fromList(img.encodeJpg(output, quality: 80));
  }

  // Android NV21: Y plane followed by interleaved VU
  Uint8List _nv21ToJpeg(CameraImage frame) {
    if (frame.planes.isEmpty) {
      throw StateError('NV21 frame has no image data.');
    }

    final width = frame.width;
    final height = frame.height;

    final output = img.Image(width: width, height: height);

    final bytes = frame.planes.first.bytes;
    final ySize = width * height;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yIndex = y * width + x;

        final uvIndex = ySize + (y ~/ 2) * width + (x ~/ 2) * 2;

        final yValue = bytes[yIndex];
        final vValue = bytes[uvIndex];
        final uValue = bytes[uvIndex + 1];

        _setYuvPixel(output, x, y, yValue, uValue, vValue);
      }
    }

    return Uint8List.fromList(img.encodeJpg(output, quality: 80));
  }

  void _setYuvPixel(
    img.Image image,
    int x,
    int y,
    int yValue,
    int uValue,
    int vValue,
  ) {
    final u = uValue - 128;
    final v = vValue - 128;

    int r = (yValue + 1.402 * v).round();
    int g = (yValue - 0.344136 * u - 0.714136 * v).round();
    int b = (yValue + 1.772 * u).round();

    r = r.clamp(0, 255);
    g = g.clamp(0, 255);
    b = b.clamp(0, 255);

    image.setPixelRgb(x, y, r, g, b);
  }
}
