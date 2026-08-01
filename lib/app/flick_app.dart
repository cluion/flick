import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../api/backend_gateway.dart';
import 'rename_workspace.dart';

typedef BackendConnector = Future<BackendGateway> Function();
typedef AppVersionLoader = Future<String> Function();

Future<String> loadAppVersion() async {
  final info = await PackageInfo.fromPlatform();
  final buildNumber = info.buildNumber.trim();
  return buildNumber.isEmpty
      ? 'v${info.version}'
      : 'v${info.version} ($buildNumber)';
}

const background = Color(0xFF0B0D12);
const surface = Color(0xFF12151C);
const surfaceRaised = Color(0xFF191D26);
const border = Color(0xFF282D39);
const primary = Color(0xFF8C7CFF);
const primaryBright = Color(0xFFB9AEFF);
const mint = Color(0xFF52D6A3);
const muted = Color(0xFF9BA2B2);
const subtle = Color(0xFF6B7280);
const danger = Color(0xFFFF7184);
const warning = Color(0xFFF0BE62);

class FlickApp extends StatelessWidget {
  const FlickApp({
    super.key,
    this.connector = RpcBackend.connect,
    this.versionLoader = loadAppVersion,
  });

  final BackendConnector connector;
  final AppVersionLoader versionLoader;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flick',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: primary,
          onPrimary: Color(0xFF17112C),
          secondary: mint,
          surface: surface,
          error: danger,
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.8,
          ),
          titleLarge: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
          titleMedium: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
          bodyMedium: TextStyle(color: muted, height: 1.4),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0E1117),
          labelStyle: const TextStyle(color: muted),
          hintStyle: const TextStyle(color: subtle),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 13,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: primary),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: primaryBright,
            foregroundColor: const Color(0xFF17112C),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFD9D5F4),
            side: const BorderSide(color: Color(0xFF3A4050)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        dividerColor: border,
        useMaterial3: true,
      ),
      home: RenameWorkspace(connector: connector, versionLoader: versionLoader),
    );
  }
}
