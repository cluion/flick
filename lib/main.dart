import 'package:bridra_flutter/bridra_flutter.dart';
import 'package:flutter/material.dart';

import 'app/flick_app.dart';

Future<void> main([List<String> arguments = const []]) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (DesktopSingleInstance.isSupported) {
    final instance = await DesktopSingleInstance.acquire(
      applicationId: 'com.cluion.flick',
      arguments: arguments,
    );
    if (!instance.isPrimary) return;
    instance.activations.listen((activation) {
      debugPrint('Flick activation: ${activation.arguments}');
    });
  }
  runApp(const FlickApp());
}
