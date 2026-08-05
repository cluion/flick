import 'dart:io';

import 'package:flutter/services.dart';

typedef FilePathAction = Future<void> Function(String path);

class FileRevealCommand {
  const FileRevealCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

FileRevealCommand buildFileRevealCommand({
  required String operatingSystem,
  required String path,
}) {
  return switch (operatingSystem) {
    'macos' => FileRevealCommand('open', ['-R', path]),
    'windows' => FileRevealCommand('explorer.exe', ['/select,', path]),
    'linux' => FileRevealCommand('xdg-open', [File(path).parent.path]),
    _ => throw UnsupportedError('不支援的桌面平台：$operatingSystem'),
  };
}

Future<void> revealFileInManager(String path) async {
  final command = buildFileRevealCommand(
    operatingSystem: Platform.operatingSystem,
    path: path,
  );
  final result = await Process.run(
    command.executable,
    command.arguments,
    runInShell: false,
  );
  if (result.exitCode == 0) return;
  final detail = result.stderr.toString().trim();
  throw FileSystemException(
    detail.isEmpty ? '無法在檔案管理器中顯示檔案' : '無法在檔案管理器中顯示檔案：$detail',
    path,
  );
}

Future<void> copyFilePath(String path) {
  return Clipboard.setData(ClipboardData(text: path));
}
