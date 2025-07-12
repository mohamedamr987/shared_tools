import 'dart:io';

import 'package:http/http.dart' as http;

Future<void> run(List<String> args) async {
  final agpVersion = await fetchLatestStableVersion(
    'https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/maven-metadata.xml',
  );
  final kotlinVersion = await fetchLatestStableVersion(
    'https://plugins.gradle.org/m2/org/jetbrains/kotlin/kotlin-gradle-plugin/maven-metadata.xml',
  );
  final googleServicesVersion = await fetchLatestStableVersion(
    'https://dl.google.com/dl/android/maven2/com/google/gms/google-services/maven-metadata.xml',
  );
  final crashlyticsVersion = await fetchLatestStableVersion(
    'https://dl.google.com/dl/android/maven2/com/google/firebase/firebase-crashlytics-gradle/maven-metadata.xml',
  );

  print(
      'AGP: $agpVersion, Kotlin: $kotlinVersion, GoogleServices: $googleServicesVersion, Crashlytics: $crashlyticsVersion');

  if ([agpVersion, kotlinVersion, googleServicesVersion, crashlyticsVersion]
      .contains(null)) {
    print('❌ Failed to fetch some versions.');
    return;
  }

  await updateGradleWrapper();
  await updateBuildGradle(agpVersion!, kotlinVersion!);
  await updateSettingsGradle(
    agpVersion: agpVersion,
    kotlinVersion: kotlinVersion,
    googleServicesVersion: googleServicesVersion!,
    crashlyticsVersion: crashlyticsVersion!,
  );

  print('\n✅ Android files updated successfully.');
}

Future<String?> fetchLatestStableVersion(String url) async {
  try {
    final response = await http.get(Uri.parse(url));
    final matches =
        RegExp(r'<version>([\d.]+)</version>').allMatches(response.body);
    final versions = matches
        .map((m) => m.group(1)!)
        .where((v) => !v.contains(RegExp(r'[a-zA-Z]')))
        .toList();
    return versions.isNotEmpty ? versions.last : null;
  } catch (_) {
    return null;
  }
}

Future<void> updateGradleWrapper() async {
  final file = File('android/gradle/wrapper/gradle-wrapper.properties');
  if (!file.existsSync()) return;
  final content = await file.readAsString();
  final latestGradle = await fetchLatestStableGradleVersion();
  if (latestGradle == null) {
    print('❌ Failed to fetch latest Gradle version.');
    return;
  }

  final updated = content.replaceAllMapped(
    RegExp(r'distributionUrl=.*'),
    (_) =>
        'distributionUrl=https\\://services.gradle.org/distributions/gradle-$latestGradle-all.zip',
  );

  await file.writeAsString(updated);
  print('🛠 Updated gradle-wrapper.properties');
}

Future<String?> fetchLatestStableGradleVersion() async {
  try {
    final response = await http
        .get(Uri.parse('https://services.gradle.org/versions/current'));
    if (response.statusCode != 200) return null;

    final json = response.body;
    final match = RegExp(r'"version"\s*:\s*"([^"]+)"').firstMatch(json);
    return match?.group(1);
  } catch (_) {
    return null;
  }
}

Future<void> updateBuildGradle(String agpVersion, String kotlinVersion) async {
  final file = File('android/build.gradle');
  if (!file.existsSync()) return;
  final lines = await file.readAsLines();
  final updated = lines.map((line) {
    if (line.contains('com.android.tools.build:gradle')) {
      return '        classpath "com.android.tools.build:gradle:$agpVersion"';
    }
    if (line.contains('kotlin-gradle-plugin')) {
      return '        classpath "org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion"';
    }
    return line;
  }).toList();
  await file.writeAsString(updated.join('\n'));
  print('🛠 Updated build.gradle');
}

Future<void> updateSettingsGradle({
  required String agpVersion,
  required String kotlinVersion,
  required String googleServicesVersion,
  required String crashlyticsVersion,
}) async {
  final file = File('android/settings.gradle');
  if (!file.existsSync()) return;

  final lines = await file.readAsLines();

  int start = -1, end = -1, depth = 0;
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].trim().startsWith('plugins {')) {
      start = i;
      for (int j = i; j < lines.length; j++) {
        if (lines[j].contains('{')) depth++;
        if (lines[j].contains('}')) depth--;
        if (depth == 0) {
          end = j;
          break;
        }
      }
      break;
    }
  }

  if (start == -1 || end == -1) {
    print('❌ Could not locate plugin block in settings.gradle');
    return;
  }

  final newPlugins = [
    'plugins {',
    '    id "dev.flutter.flutter-plugin-loader" version "1.0.0"',
    '    id "com.android.application" version "$agpVersion" apply false',
    '    // START: FlutterFire Configuration',
    '    id "com.google.gms.google-services" version "$googleServicesVersion" apply false',
    '    id "com.google.firebase.crashlytics" version "$crashlyticsVersion" apply false',
    '    // END: FlutterFire Configuration',
    '    id "org.jetbrains.kotlin.android" version "$kotlinVersion" apply false',
    '}'
  ];

  final updatedLines = [
    ...lines.sublist(0, start),
    ...newPlugins,
    ...lines.sublist(end + 1),
  ];

  await file.writeAsString(updatedLines.join('\n'));
  print('🛠 Rewrote plugins block in settings.gradle');
}
