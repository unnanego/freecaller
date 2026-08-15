import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

/// A photo the user chose for their profile, already scaled down for upload.
class PickedPhoto {
  const PickedPhoto({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;
}

/// Picking a profile photo, from the library or the camera.
///
/// Two implementations, for one Android-specific reason. MainActivity is
/// `singleInstance` — that is what makes answering a call work — and such an
/// activity is the only member its task can hold, so a plugin that starts the
/// system picker for a result never hears the answer: image_picker returned
/// null on Android however long the user spent choosing. Android therefore goes
/// through `PhotoPickerActivity`, an activity of ours with an ordinary launch
/// mode that can receive the result and hands back a path over this channel.
/// Everywhere else image_picker is exactly right.
class ProfilePhotoPicker {
  const ProfilePhotoPicker();

  static const _channel = MethodChannel('freecaller/photo_picker');

  /// The longest edge and JPEG quality the picked image is reduced to. The
  /// server caps an avatar at 2 MB and only ever serves its 100/300 px thumbs,
  /// so anything larger is paid for on every roster read and shown to nobody.
  static const _maxEdge = 1024.0;
  static const _quality = 85;

  /// Returns null when the user backed out of the picker.
  ///
  /// Throws [PhotoPickerDenied] if the camera was asked for and the OS says no,
  /// so the caller can say something more useful than "failed".
  Future<PickedPhoto?> pick({required bool camera}) async {
    if (Platform.isAndroid) return _pickAndroid(camera: camera);

    final picked = await ImagePicker().pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: _maxEdge,
      maxHeight: _maxEdge,
      imageQuality: _quality,
    );
    if (picked == null) return null;
    return PickedPhoto(bytes: await picked.readAsBytes(), filename: picked.name);
  }

  Future<PickedPhoto?> _pickAndroid({required bool camera}) async {
    // The app declares the camera permission (video calls), and Android then
    // refuses ACTION_IMAGE_CAPTURE outright unless it has actually been
    // granted — asking here turns a silent refusal into a normal prompt.
    if (camera && !await Permission.camera.request().isGranted) {
      throw const PhotoPickerDenied();
    }
    final path = await _channel.invokeMethod<String>('pick', {'camera': camera});
    if (path == null) return null; // cancelled
    final file = File(path);
    final bytes = await file.readAsBytes();
    // The scaled copy lives in the cache dir and is of no use once uploaded.
    unawaited(file.delete().catchError((Object _) => file));
    return PickedPhoto(bytes: bytes, filename: path.split('/').last);
  }
}

/// The camera was refused, so there is nothing to pick.
class PhotoPickerDenied implements Exception {
  const PhotoPickerDenied();
}
