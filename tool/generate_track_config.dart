import 'dart:convert';
import 'dart:io';

const _requiredKeys = [
  'FIREBASE_API_KEY',
  'FIREBASE_AUTH_DOMAIN',
  'FIREBASE_DATABASE_URL',
  'FIREBASE_PROJECT_ID',
  'FIREBASE_MESSAGING_SENDER_ID',
  'FIREBASE_APP_ID',
];

// Optional: only needed if using Firebase Storage. If using Cloudinary, can be empty.
const _optionalKeys = ['FIREBASE_STORAGE_BUCKET'];

void main(List<String> args) {
  final scriptUri = Platform.script;
  final scriptPath = scriptUri.toFilePath();
  final toolDir = File(scriptPath).parent;
  final root = toolDir.parent.path;
  final envFile = File('$root/.env');
  final outputFile = File('$root/web/track-config.js');

  if (!envFile.existsSync()) {
    stderr.writeln('Missing .env at $root/.env');
    exitCode = 1;
    return;
  }

  final env = _readEnv(envFile.readAsLinesSync());
  final missing = _requiredKeys
      .where((key) => env[key] == null || env[key]!.isEmpty)
      .toList();

  // storageBucket is optional if using Cloudinary
  final storageBucket = env['FIREBASE_STORAGE_BUCKET'] ?? '';
  final googleMapsApiKey =
      env['GOOGLE_MAPS_API_KEY'] ?? env['GOOGLE_PLACES_API_KEY'];
  if (googleMapsApiKey == null || googleMapsApiKey.isEmpty) {
    missing.add('GOOGLE_MAPS_API_KEY or GOOGLE_PLACES_API_KEY');
  }
  if (missing.isNotEmpty) {
    stderr.writeln('Missing required keys in .env: ${missing.join(', ')}');
    exitCode = 1;
    return;
  }

  final config = {
    'firebaseConfig': {
      'apiKey': env['FIREBASE_API_KEY'],
      'authDomain': env['FIREBASE_AUTH_DOMAIN'],
      'databaseURL': env['FIREBASE_DATABASE_URL'],
      'projectId': env['FIREBASE_PROJECT_ID'],
      'storageBucket': storageBucket,
      'messagingSenderId': env['FIREBASE_MESSAGING_SENDER_ID'],
      'appId': env['FIREBASE_APP_ID'],
    },
    'googleMapsApiKey': googleMapsApiKey,
  };

  final js = 'window.__TRACK_CONFIG__ = ${jsonEncode(config)};\n';
  outputFile.writeAsStringSync(js);
  stdout.writeln('Wrote ${outputFile.path}');
}

Map<String, String> _readEnv(List<String> lines) {
  final values = <String, String>{};

  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }

    final index = line.indexOf('=');
    if (index <= 0) {
      continue;
    }

    final key = line.substring(0, index).trim();
    var value = line.substring(index + 1).trim();

    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }

    values[key] = value;
  }

  return values;
}
