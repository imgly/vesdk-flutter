import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    final segmentsEnabled = configuration?.export?.video?.segments == true;
    final release = segmentsEnabled && Platform.isAndroid
        ? () => _channel.invokeMethod(
            'release', <String, dynamic>{"identifier": result["identifier"]})
        : () => null;
    return result == null
        ? null
        : VideoEditorResult._fromJson(Map<String, dynamic>.from(result),
            release: release);
  }
}

/// A [VideoSegment] is part of a video composition and can be loaded into
/// the VideoEditor SDK editor.
class VideoSegment {
  /// Creates a new [VideoSegment].
  ///
  /// The [videoUri] source should either be a full path, an URI
  /// or if it is an asset the relative path as specified in
  /// your `pubspec.yaml` file.
  /// Remote resources are not optimized and therefore should be downloaded
  /// in advance and then passed to the editor as local resources.
  /// The [startTime] represents the start time of the video segment within the
  /// composition (in seconds) and the [endTime] the end time of the segment.
  VideoSegment(this.videoUri, {this.startTime, this.endTime});

  /// A URI for the video segment.
  final String videoUri;

  /// The start time in seconds.
  final double? startTime;

  /// The end time in seconds.
  final double? endTime;

  /// Converts the [VideoSegment] for JSON parsing.
  Map<String, dynamic> toJson() =>
      {"videoUri": videoUri, "startTime": startTime, "endTime": endTime};

  /// Creates a [VideoSegment] from the [json] map.
  factory VideoSegment.fromJson(Map<String, dynamic> json) =>
      VideoSegment(json["videoUri"],
          startTime: json["startTime"], endTime: json["endTime"]);
}

/// A [Video] can be loaded into the VideoEditor SDK editor.
class Video {
  /// Creates a new [Video] from the given source.
  /// The [video] source should either be a full path, an URI
  /// or if it is an asset the relative path as specified in
  /// your `pubspec.yaml` file.
  /// Remote resources are not optimized and therefore should be downloaded
  /// in advance and then passed to the editor as local resources.
  Video(String video)
      : _video = video,
        _videos = null,
        _segments = null,
        _size = null;

  /// Creates a new video composition with multiple videos.
  /// The [videos] each should either be a full path, an URI
  /// or if it is an asset the relative path as specified in
  /// your `pubspec.yaml` file.
  /// Remote resources are not optimized and therefore should be downloaded
  /// in advance and then passed to the editor as local resources.
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
        _segments = null,
        _video = null;

  /// Creates a new video composition with multiple [VideoSegment]s.
  /// The [size] overrides the natural dimensions of the video(s) passed to the
  /// editor. All videos will be fitted to the [size] aspect by adding
  /// black bars on the left and right side or top and bottom.
  /// If [segments] is set to `null`, a valid [size] must be given
  /// which will initialize the editor with an empty composition.
  ///
  /// ### Licensing:
  /// In order to use this feature, you need to unlock the video composition
  /// feature for your license first.
  Video.fromSegments({List<VideoSegment>? segments, Size? size})
      : _segments = segments,
        _videos = null,
        _size = size,
        _video = null;

  /// The segments of the video composition.
  final List<VideoSegment>? _segments;

  /// The video source.
  /// The source should either be a full path, an URI
  /// or if it is an asset the relative path as specified in
  /// your `pubspec.yaml` file.
  /// Remote resources are not optimized and therefore should be downloaded
  /// in advance and then passed to the editor as local resources.
  final String? _video;

  /// The sources for the video composition.
  /// The sources should each either be a full path, an URI
  /// or if it is an asset the relative path as specified in
  /// your `pubspec.yaml` file.
  /// Remote resources are not optimized and therefore should be downloaded
  /// in advance and then passed to the editor as local resources.
  final List<String>? _videos;

  /// The [Size] of the composition.
  final Size? _size;

  /// Converts the instance for JSON parsing.
  Map<String, dynamic> _toJson() {
    final size = _size;
    final map = Map<String, dynamic>.from({});
    if (_video != null) {
      map.addAll({"video": _video});
    } else if (_videos != null) {
      map.addAll({
        "videos": _videos,
        "size":
            size == null ? null : {"width": size.width, "height": size.height}
      });
    } else if (_segments != null) {
      map.addAll({
        "segments": _segments?.map((e) => e.toJson()).toList(),
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
  VideoEditorResult._(this.video, this.hasChanges, this.serialization,
      {this.segments, this.videoSize, required this.release});

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

  /// The used input video segments that compose the edited [video].
  /// Returned if `export.video.segments` of the [Configuration] is
  /// set to `true`.
  final List<VideoSegment>? segments;

  /// The size of the **untransformed** video.
  final Size? videoSize;

  /// Releases the result. Needed if `export.video.segments` of the
  /// [Configuration] is set to `true`.
  final VoidCallback release;

  /// Creates a [VideoEditorResult] from the [json] map.
  factory VideoEditorResult._fromJson(Map<String, dynamic> json,
      {required VoidCallback release}) {
    final serializedSegments = json["segments"] as List<dynamic>?;
    final deserializedSegments = serializedSegments
        ?.map((e) => VideoSegment.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final serializedSize = Map<String, dynamic>.from(json["videoSize"]);
    final deserializedSize =
        Size(serializedSize?["width"], serializedSize?["height"]);

    return VideoEditorResult._(
        json["video"], json["hasChanges"], json["serialization"],
        segments: deserializedSegments,
        videoSize: deserializedSize,
        release: release);
  }

  /// Converts the [VideoEditorResult] for JSON parsing.
  Map<String, dynamic> toJson() => {
        "video": video,
        "hasChanges": hasChanges,
        "serialization": serialization,
        "segments": segments?.map((e) => e.toJson()),
        "videoSize": {"width": videoSize?.width, "height": videoSize?.height}
      };
}
