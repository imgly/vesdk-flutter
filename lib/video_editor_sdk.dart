import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:imgly_sdk/imgly_sdk.dart';

/// The plugin class for the video_editor_sdk plugin.
class VESDK {
  /// The `MethodChannel`.
  static const MethodChannel _channel = MethodChannel('video_editor_sdk');

  /// Unlocks the SDK with a license file from the assets.
  /// The [path] input should be a relative path to the license
  /// file(s) as specified in your `pubspec.yaml` file.
  /// If you want to unlock the SDK for both iOS and Android, you need
  /// to include one license for each platform with the same name, but where
  /// the iOS license has `.ios` as its file extension and the
  /// Android license has `.android` as its file extension.
  static void unlockWithLicense(String path) async {
    await _channel.invokeMethod('unlock', <String, dynamic>{'license': path});
  }

  /// Opens a new video editor.
  ///
  /// Modally opens the editor with the given [video].
  /// The editor can be customized with the [configuration]
  /// The [serialization] restores a previous state of the editor
  /// by re-applying all modifications to the video.
  /// Once finished, the editor either returns a [VideoEditorResult]
  /// or `null` if the editor was dismissed without exporting the video.
  static Future<VideoEditorResult?> openEditor(Video video,
      {Configuration? configuration,
      Map<String, dynamic>? serialization}) async {
    final result = await _channel.invokeMethod('openEditor', <String, dynamic>{
      'video': video._toJson(),
      'configuration': configuration?.toJson(),
      'serialization': serialization == null
          ? null
          : Platform.isIOS
              ? serialization
              : jsonEncode(serialization)
    });
    return result == null
        ? null
        : VideoEditorResult._fromJson(Map<String, dynamic>.from(result));
  }
}

/// A [Video] can be loaded into the VideoEditor SDK editor.
class Video {
  /// Creates a new [Video] from the given source.
  /// The [video] source should either be a full path, an URI
  /// or if it is an asset the relative path as specified in
  /// your `pubspec.yaml` file.
  Video(String video)
      : _video = video,
        _videos = null,
        _size = null;

  /// Creates a new video composition with multiple videos.
  /// The [size] overrides the natural dimensions of the video(s) passed to the
  /// editor. All videos will be fitted to the [size] aspect by adding
  /// black bars on the left and right side or top and bottom.
  /// If [videos] is set to `null`, a valid [size] must be given
  /// which will initialize the editor with an empty composition.
  ///
  /// ### Licensing:
  /// In order to use this feature, you need to unlock it for your
  /// license first.
  Video.composition({List<String>? videos, Size? size})
      : _videos = videos,
        _size = size,
        _video = null;

  /// The video source.
  final String? _video;

  /// The sources for the video composition.
  final List<String>? _videos;

  /// The [Size] of the composition.
  final Size? _size;

  /// Converts the instance for JSON parsing.
  Map<String, dynamic> _toJson() {
    final size = _size;
    final map = Map<String, dynamic>.from({});
    if (_video != null) {
      map.addAll({"video": _video});
    } else {
      map.addAll({
        "videos": _videos,
        "size":
            size == null ? null : {"width": size.width, "height": size.height}
      });
    }
    return map..removeWhere((key, value) => value == null);
  }
}

/// Returned if an editor has completed exporting.
class VideoEditorResult {
  /// Creates a new [VideoEditorResult].
  VideoEditorResult._(this.video, this.hasChanges, this.serialization);

  /// The source of the edited video.
  final String video;

  /// Indicating whether the video has been
  /// changed at all.
  final bool hasChanges;

  /// The serialization contains the applied changes. This is only
  /// returned in case `Configuration.export.serialization.enabled` is
  /// set to `true`.
  /// The serialization can either be the path of the serialization file as
  /// a [String] in case that `Configuration.export.serialization.exportType`
  /// is set to [SerializationExportType.fileUrl]
  /// or an object if `Configuration.export.serialization.exportType`
  /// is set to [SerializationExportType.object].
  final dynamic serialization;

  /// Creates a [VideoEditorResult] from the [json] map.
  factory VideoEditorResult._fromJson(Map<String, dynamic> json) =>
      VideoEditorResult._(
          json["video"], json["hasChanges"], json["serialization"]);

  /// Converts the [VideoEditorResult] for JSON parsing.
  Map<String, dynamic> toJson() => {
        "video": video,
        "hasChanges": hasChanges,
        "serialization": serialization
      };
}
