import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';

abstract interface class ProfileMediaPicker {
  Future<String?> chooseAvatar();
}

class DeviceProfileMediaPicker implements ProfileMediaPicker {
  @override
  Future<String?> chooseAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
      withData: false,
    );
    if (result == null || result.files.isEmpty) return null;
    ui.Codec? codec;
    ui.Image? image;
    try {
      final picked = result.files.single;
      if (picked.size > 5 * 1024 * 1024) {
        throw const FormatException('请选择 5 MB 以内的图片');
      }
      final file = picked.path == null ? null : File(picked.path!);
      if (file != null && await file.length() > 5 * 1024 * 1024) {
        throw const FormatException('请选择 5 MB 以内的图片');
      }
      final bytes = file == null ? picked.bytes : await file.readAsBytes();
      if (bytes == null) {
        throw const FormatException('无法读取图片，请选择 PNG、JPEG 或 WebP');
      }
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 512,
        allowUpscaling: false,
      );
      image = (await codec.getNextFrame()).image;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null || png.lengthInBytes > 2 * 1024 * 1024) {
        throw const FormatException('无法读取图片，请选择 PNG、JPEG 或 WebP');
      }
      return base64Encode(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('无法读取图片，请选择 PNG、JPEG 或 WebP');
    } finally {
      image?.dispose();
      codec?.dispose();
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          await FilePicker.platform.clearTemporaryFiles();
        } catch (_) {
          /* OS cache */
        }
      }
    }
  }
}
