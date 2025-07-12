import 'dart:io';

Future<void> run(List<String> args) async {
  final projectDir = Directory.current;
  final files = projectDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'));

  for (final file in files) {
    final content = file.readAsStringSync();

    final hasWithOpacity = content.contains('.withOpacitySafe(');
    final hasImport = content
        .contains("import 'package:kaptain/core/extensions/color.dart';");

    if (!hasWithOpacity) continue;

    String updated = content.replaceAllMapped(
      RegExp(r'\.withOpacity\((.*?)\)'),
      (match) => '.withOpacitySafe(${match[1]})',
    );

    if (!hasImport) {
      final importInsertionIndex =
          updated.indexOf(RegExp(r'^import .+;', multiLine: true));
      const header = "import 'package:kaptain/core/extensions/color.dart';\n";
      if (importInsertionIndex == -1) {
        updated = '$header\n$updated';
      } else {
        final lines = updated.split('\n');
        final lastImportLine =
            lines.lastIndexWhere((line) => line.startsWith('import '));
        lines.insert(lastImportLine + 1, header.trim());
        updated = lines.join('\n');
      }
    }

    file.writeAsStringSync(updated);
    print('Updated: ${file.path}');
  }

  print('✔ All replacements complete.');
}
