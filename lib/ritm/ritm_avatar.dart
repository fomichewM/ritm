// «Ритм» — фото профиля (аватар): выбор из галереи/камеры, квадрат 512×512,
// хранится только локально в ApplicationDocuments/avatar.png (ТЗ v2 §2.1).

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

class RitmAvatar {
  RitmAvatar._();

  /// Путь к фото или null (нет фото). Слушают шапка главной и «Профиль».
  static final ValueNotifier<String?> path = ValueNotifier<String?>(null);
  static bool _loaded = false;

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/avatar.png');
  }

  /// Прочитать сохранённое фото (один раз за запуск).
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      path.value = await f.exists() ? f.path : null;
    } catch (_) {
      path.value = null;
    }
  }

  /// Выбрать фото. true — сохранено.
  static Future<bool> pick({bool camera = false}) async {
    try {
      final x = await ImagePicker().pickImage(
        source: camera ? ImageSource.camera : ImageSource.gallery,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 90,
      );
      if (x == null) return false;
      final png = await squareCrop(await x.readAsBytes(), 512);
      if (png == null) return false;
      final f = await _file();
      await f.writeAsBytes(png, flush: true);
      await FileImage(f).evict();
      path.value = null; // сбросить кэш картинки у слушателей
      path.value = f.path;
      return true;
    } catch (e) {
      debugPrint('[ritm] avatar pick failed: $e');
      return false;
    }
  }

  static Future<void> remove() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        await FileImage(f).evict();
        await f.delete();
      }
    } catch (_) {}
    path.value = null;
  }

  /// Центральный квадрат изображения, уменьшенный до [side]×[side], в PNG.
  static Future<Uint8List?> squareCrop(Uint8List bytes, int side) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final s = img.width < img.height ? img.width : img.height;
    final src = ui.Rect.fromLTWH(
      (img.width - s) / 2,
      (img.height - s) / 2,
      s.toDouble(),
      s.toDouble(),
    );
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawImageRect(
      img,
      src,
      ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final out = await rec.endRecording().toImage(side, side);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    out.dispose();
    return data?.buffer.asUint8List();
  }
}
