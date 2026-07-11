// Generated from the Firebase project's platform config files
// (google-services.json / GoogleService-Info.plist) for freecaller-fef3e.
// Regenerate with `flutterfire configure` if the project's apps change.
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Web is a stage-2 target; not configured yet.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for $defaultTargetPlatform.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAkj8GtwU11JiedCgXF_STk_t-hdyPzhOE',
    appId: '1:806105122900:android:015ef79e9f9f02b33705c1',
    messagingSenderId: '806105122900',
    projectId: 'freecaller-fef3e',
    storageBucket: 'freecaller-fef3e.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyCO5CorAG9IBpYRQIbU3Fb5zGsiJAfQGf8',
    appId: '1:806105122900:ios:b9fa3698ba1bd77a3705c1',
    messagingSenderId: '806105122900',
    projectId: 'freecaller-fef3e',
    storageBucket: 'freecaller-fef3e.firebasestorage.app',
    iosBundleId: 'com.unnanego.freecaller',
  );
}
