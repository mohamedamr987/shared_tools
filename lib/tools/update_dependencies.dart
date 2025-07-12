import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

Future<void> run(List<String> args) async {
  final dryRun = args.contains('--dry-run');
  final pubspecFile = File('pubspec.yaml');
  if (!pubspecFile.existsSync()) {
    print('❌ pubspec.yaml not found.');
    return;
  }

  final lines = await pubspecFile.readAsLines();
  final updatedLines = [...lines];

  final sectionIndexes = {
    'dependencies': _sectionIndexes(lines, 'dependencies'),
    'dev_dependencies': _sectionIndexes(lines, 'dev_dependencies'),
    'dependency_overrides': _sectionIndexes(lines, 'dependency_overrides'),
  };

  final allDeclaredPackages = {
    ...sectionIndexes['dependencies']!,
    ...sectionIndexes['dev_dependencies']!,
    ...sectionIndexes['dependency_overrides']!,
  };

  final originalVersions = <String, String?>{};
  for (var entry in allDeclaredPackages.entries) {
    final match = RegExp(r'^\s{2}${entry.key}:\s*\^?([^\s]+)')
        .firstMatch(lines[entry.value]);
    originalVersions[entry.key] = match?.group(1);
  }

  final updated = <String, String>{};

  // Step 1: Update all declared packages to latest
  for (final pkg in allDeclaredPackages.keys) {
    if (_isFlutterPackage(pkg)) continue;

    final latest = await _fetchLatestPubVersion(pkg);
    if (latest != null) {
      final index = allDeclaredPackages[pkg]!;
      updatedLines[index] = '  $pkg: ^$latest';
      updated[pkg] = latest;
    }
  }

  // Step 2: Find used but undeclared packages
  final projectName = _getProjectName(lines);
  final usedPackages = await _findUsedPackages(
    './',
    exclude: {
      projectName,
      ...allDeclaredPackages.keys.toSet(),
    },
  );

  for (final pkg in usedPackages) {
    if (_isFlutterPackage(pkg)) continue;
    final latest = await _fetchLatestPubVersion(pkg);
    if (latest != null) {
      final depSectionIndex =
          updatedLines.indexWhere((line) => line.trim() == 'dependencies:');
      if (depSectionIndex != -1) {
        final alreadyExists = updatedLines
            .skip(depSectionIndex + 1)
            .takeWhile((line) =>
                line.startsWith('  ') ||
                line.trim().isEmpty ||
                line.trim().startsWith('#'))
            .any((line) => line.trim().startsWith('$pkg:'));

        if (!alreadyExists) {
          int insertAt = depSectionIndex + 1;
          while (insertAt < updatedLines.length &&
              (updatedLines[insertAt].startsWith('  ') ||
                  updatedLines[insertAt].trim().isEmpty ||
                  updatedLines[insertAt].trim().startsWith('#'))) {
            insertAt++;
          }
          updatedLines.insert(insertAt, '  $pkg: ^$latest');
          updated[pkg] = latest;
          print('➕ Added $pkg: ^$latest');
        }
      }
    } else {
      print('⚠️  Could not fetch version for $pkg');
    }
  }

  // Step 3: Suggest unused packages for removal
  final actuallyUsed = await _findUsedPackages(
    './',
    exclude: {projectName},
  );

  final unused = sectionIndexes['dependencies']!.keys.where((pkg) {
    final isUsed = actuallyUsed.contains(pkg);
    final isFlutter = _isFlutterPackage(pkg);
    if (!isUsed && !isFlutter) {
      print('🧹 $pkg appears unused (not imported anywhere)');
      return true;
    }
    return false;
  }).toList();

  if (unused.isNotEmpty) {
    print('\n🧹 Unused packages detected (consider removing):');
    for (final pkg in unused) {
      print('  • $pkg');
    }

    for (final pkg in unused) {
      final index = sectionIndexes['dependencies']![pkg];
      if (index != null) {
        updatedLines[index] = ''; // Mark for cleanup
        print('❌ Removed unused dependency: $pkg');
      }
    }
  }

  // Step 4: Output changelog
  if (updated.isNotEmpty) {
    print('\n📝 Changelog (updated or added):');
    updated.forEach((pkg, latest) {
      final old = originalVersions[pkg];
      if (old == null) {
        print('  • $pkg → ^$latest (new)');
      } else if (old != latest) {
        print('  • $pkg: ^$old → ^$latest');
      }
    });
  }

  // Step 5: Sort and deduplicate
  _sortAndDeduplicateDependencies(updatedLines);

  if (dryRun) {
    print('\n🧪 Dry run: no changes written.');
    return;
  }

  await pubspecFile.writeAsString(updatedLines.join('\n'));
  print('\n✅ pubspec.yaml updated.');

  print('\n🚀 Running `flutter pub get`...');
  final flutterCmd = Platform.isWindows ? 'flutter.bat' : 'flutter';
  final get = await Process.run(flutterCmd, ['pub', 'get'], runInShell: true);
  stdout.write(get.stdout);
  stderr.write(get.stderr);
}

// ===== Helpers =====

String _getProjectName(List<String> lines) {
  final match =
      RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(lines.join('\n'));
  return match?.group(1) ?? '';
}

bool _isFlutterPackage(String pkg) {
  const flutterBuiltIns = {
    'flutter',
    'flutter_test',
    'flutter_localizations',
    'cupertino_icons',
    'flutter_lints'
  };
  return flutterBuiltIns.contains(pkg);
}

Future<String?> _fetchLatestPubVersion(String package) async {
  try {
    final response =
        await http.get(Uri.parse('https://pub.dev/api/packages/$package'));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['latest']['version'] as String?;
    }
  } catch (_) {}
  return null;
}

Future<Set<String>> _findUsedPackages(String dir,
    {required Set<String> exclude}) async {
  final used = <String>{};
  final identifierUsage = <String, int>{};

  await for (var entity in Directory(dir).list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      final content = await entity.readAsString();

      // Look for imports
      final importMatches =
          RegExp(r'''import\s+['"]package:([^/]+)''').allMatches(content);
      for (final match in importMatches) {
        final pkg = match.group(1)!;
        if (!exclude.contains(pkg)) {
          used.add(pkg);
        }
      }

      // Identifier usage fallback
      for (final pkg in exclude) {
        if (_isFlutterPackage(pkg)) continue;
        if (RegExp(r'\b$pkg\b').hasMatch(content)) {
          identifierUsage[pkg] = (identifierUsage[pkg] ?? 0) + 1;
        }
      }
    }
  }

  used.addAll(
      identifierUsage.entries.where((e) => e.value > 0).map((e) => e.key));

  return used;
}

Map<String, int> _sectionIndexes(List<String> lines, String section) {
  final index = lines.indexWhere((line) => line.trim() == '$section:');
  if (index == -1) return {};
  final result = <String, int>{};

  for (int i = index + 1; i < lines.length; i++) {
    final match = RegExp(r'^\s{2}([a-zA-Z0-9_]+):').firstMatch(lines[i]);
    if (match != null) {
      result[match.group(1)!] = i;
    } else if (lines[i].trim().isEmpty || !lines[i].startsWith(' ')) {
      break;
    }
  }

  return result;
}

void _sortAndDeduplicateDependencies(List<String> lines) {
  final sections = ['dependencies', 'dev_dependencies'];
  for (final section in sections) {
    final index = lines.indexWhere((line) => line.trim() == '$section:');
    if (index == -1) continue;

    final start = index + 1;
    int end = start;
    while (end < lines.length &&
        (lines[end].startsWith('  ') ||
            lines[end].trim().isEmpty ||
            lines[end].trim().startsWith('#'))) {
      end++;
    }

    final seen = <String>{};
    final entries = <String>[];

    for (var i = start; i < end; i++) {
      final line = lines[i];
      final match = RegExp(r'^\s{2}([a-zA-Z0-9_]+):').firstMatch(line);
      if (match != null) {
        final pkg = match.group(1)!;
        if (seen.add(pkg)) {
          entries.add(line);
        }
      } else {
        entries.add(line); // Keep comments or blank lines
      }
    }

    entries.sort((a, b) {
      final pkgA =
          RegExp(r'^\s{2}([a-zA-Z0-9_]+):').firstMatch(a)?.group(1) ?? '';
      final pkgB =
          RegExp(r'^\s{2}([a-zA-Z0-9_]+):').firstMatch(b)?.group(1) ?? '';
      return pkgA.compareTo(pkgB);
    });

    lines.replaceRange(start, end, entries);
  }
}
