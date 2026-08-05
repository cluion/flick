import 'package:flick/platform/file_actions.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds a Finder reveal command without a shell', () {
    const path = '/Users/example/My File.txt';

    final command = buildFileRevealCommand(
      operatingSystem: 'macos',
      path: path,
    );

    expect(command.executable, 'open');
    expect(command.arguments, ['-R', path]);
  });

  test('builds an Explorer selection command with the path as an argument', () {
    const path = r'C:\Users\Example\My File, 1.txt';

    final command = buildFileRevealCommand(
      operatingSystem: 'windows',
      path: path,
    );

    expect(command.executable, 'explorer.exe');
    expect(command.arguments, ['/select,', path]);
  });

  test('opens the containing directory on Linux', () {
    final command = buildFileRevealCommand(
      operatingSystem: 'linux',
      path: '/tmp/media/My File.txt',
    );

    expect(command.executable, 'xdg-open');
    expect(command.arguments, ['/tmp/media']);
  });

  test('rejects unsupported platforms', () {
    expect(
      () => buildFileRevealCommand(
        operatingSystem: 'android',
        path: '/tmp/example.txt',
      ),
      throwsUnsupportedError,
    );
  });
}
