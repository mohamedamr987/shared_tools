import 'dart:io';

Future<void> run(List<String> args) async {
  final projectDir = Directory.current;

  final files = projectDir.listSync(recursive: true).whereType<File>().where(
      (file) =>
          file.path.endsWith('.dart') &&
          !file.path.contains(RegExp(
              r'(/|\\)(build|\.dart_tool|\.pub-cache|test_resources)(/|\\)')));

  for (final file in files) {
    final content = await file.readAsString();

    final hasWithOpacity = content.contains('.withOpacity(');
    final alreadyConverted = content.contains('.withOpacitySafe(');

    if (!hasWithOpacity || alreadyConverted) continue;

    String updated = content.replaceAllMapped(
      RegExp(r'\.withOpacity\((.*?)\)'),
      (match) => '.withOpacitySafe(${match[1]})',
    );

    final importRegex = RegExp(
      r'''import\s+['"]package:shared_tools/extensions/extention_color\.dart['"];''',
    );
    final hasImport = importRegex.hasMatch(updated);

    if (!hasImport) {
      final lines = updated.split('\n');
      final lastImportIndex =
          lines.lastIndexWhere((line) => line.startsWith('import '));
      const importLine =
          "import 'package:shared_tools/extensions/extention_color.dart';";

      if (lastImportIndex != -1) {
        lines.insert(lastImportIndex + 1, importLine);
      } else {
        lines.insert(0, importLine);
      }

      updated = lines.join('\n');
    }

    await file.writeAsString(updated);
    print('✔ Updated: ${file.path}');
  }

  print('🎉 All replacements complete.');
}
