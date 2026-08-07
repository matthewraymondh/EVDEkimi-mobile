import 'dart:async';
import 'dart:io';

import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';
import 'package:evdekimi_ai/features/chat/domain/repositories/chat_repository.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Where an image came from.
enum ImageSourceKind { camera, gallery }

/// Camera/gallery capture plus on-device OCR.
///
/// Two decisions worth calling out:
///
/// * **Files are copied into app storage before use.** `image_picker` returns
///   paths in an OS cache directory that can be reclaimed at any time. Since an
///   attachment may sit in the outbox for hours waiting for connectivity, the
///   bytes are copied somewhere this app controls, or an offline send would find
///   the file gone.
/// * **OCR runs at attach time, not at send time.** Recognising text immediately
///   means an image contributes to the prompt (and to offline semantic search)
///   even when the chosen model has no vision support, or when the upload never
///   succeeds. It is the difference between "here is a picture you cannot see"
///   and "here is what the picture says".
class AttachmentService {
  AttachmentService({
    required AppLogger logger,
    ImagePicker? picker,
    TextRecognizer? textRecognizer,
  }) : _logger = logger.scoped('input.attachments'),
       _picker = picker ?? ImagePicker(),
       _textRecognizer = textRecognizer;

  /// Downscale target. Large enough for OCR and for a vision model, small enough
  /// that an upload over mobile data is quick.
  static const int _maxDimension = 1600;
  static const int _imageQuality = 82;

  /// Ignore OCR output shorter than this: a couple of stray characters from a
  /// photo of a landscape is noise, not content.
  static const int _minUsefulTextLength = 4;

  final AppLogger _logger;
  final ImagePicker _picker;

  TextRecognizer? _textRecognizer;

  /// Created lazily: constructing a recogniser loads a native model, which is
  /// wasted work for a user who never attaches an image.
  /// Latin script is the default and covers English and Indonesian, the two
  /// languages this app is used in.
  TextRecognizer get _recognizer => _textRecognizer ??= TextRecognizer();

  /// Picks an image, copies it into app storage, and runs OCR on it.
  ///
  /// Returns `null` when the user cancels — a cancellation is not an error.
  Future<PendingAttachment?> pickImage(ImageSourceKind source) async {
    try {
      final picked = await _picker.pickImage(
        source: source == ImageSourceKind.camera
            ? ImageSource.camera
            : ImageSource.gallery,
        maxWidth: _maxDimension.toDouble(),
        maxHeight: _maxDimension.toDouble(),
        imageQuality: _imageQuality,
      );
      if (picked == null) return null;

      final stored = await _copyIntoAppStorage(picked);
      final extractedText = await recogniseText(stored.path);

      _logger.i(
        'Image attached',
        fields: {
          'source': source.name,
          'bytes': stored.lengthSync(),
          'ocrChars': extractedText?.length ?? 0,
        },
      );

      return PendingAttachment(
        localPath: stored.path,
        kind: AttachmentKind.image,
        mimeType: _mimeTypeFor(stored.path),
        sizeBytes: stored.lengthSync(),
        extractedText: extractedText,
      );
    } on PlatformException catch (error) {
      // image_picker surfaces a denied permission as a platform error with one
      // of these codes; anything else is a genuine failure and is rethrown.
      const deniedCodes = {
        'camera_access_denied',
        'photo_access_denied',
        'invalid_source',
      };
      if (!deniedCodes.contains(error.code)) rethrow;
      throw PermissionDeniedException(
        source == ImageSourceKind.camera ? 'Camera' : 'Photo library',
        // The plugin cannot tell us whether the user chose "don't ask again", so
        // we assume a re-prompt will not help and point at system settings. A
        // pointless extra prompt is worse UX than one redundant instruction.
        isPermanentlyDenied: true,
      );
    } catch (error, stackTrace) {
      _logger.w('Image selection failed', error: error, stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Runs on-device OCR and returns the recognised text, or `null` if there is
  /// nothing useful.
  ///
  /// ML Kit's text recognition runs entirely locally, so this works offline and
  /// no image leaves the device to be read.
  Future<String?> recogniseText(String imagePath) async {
    try {
      final input = InputImage.fromFilePath(imagePath);
      final result = await _recognizer.processImage(input);

      // `result.text` preserves ML Kit's block order, which reads more naturally
      // than re-joining lines ourselves.
      final text = result.text.trim();
      if (text.length < _minUsefulTextLength) return null;
      return text;
    } catch (error, stackTrace) {
      // OCR is an enhancement. A failure must not stop the image being attached.
      _logger.w('OCR failed', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// Copies a picked file into a directory this app owns.
  Future<File> _copyIntoAppStorage(XFile picked) async {
    final directory = Directory(
      '${(await getApplicationSupportDirectory()).path}/attachments',
    );
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }

    final extension = picked.path.contains('.')
        ? picked.path.split('.').last
        : 'jpg';
    final target = File(
      '${directory.path}/${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    await target.writeAsBytes(await picked.readAsBytes(), flush: true);
    return target;
  }

  static String _mimeTypeFor(String path) {
    final extension = path.split('.').last.toLowerCase();
    return switch (extension) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'heic' || 'heif' => 'image/heic',
      'gif' => 'image/gif',
      _ => 'image/jpeg',
    };
  }

  Future<void> dispose() async {
    await _textRecognizer?.close();
    _textRecognizer = null;
  }
}
