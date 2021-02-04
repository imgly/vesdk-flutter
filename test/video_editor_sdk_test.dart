import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const MethodChannel channel = MethodChannel('video_editor_sdk');

  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {});

  tearDown(() {
    channel.setMockMethodCallHandler(null);
  });
}
