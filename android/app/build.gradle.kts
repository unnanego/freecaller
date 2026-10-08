import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (android/key.properties + the keystore are gitignored).
//
// When they are absent the release build used to fall back to debug signing
// WITHOUT SAYING SO. The result looks like a release and is not one: it cannot
// update the installed app (different signature — and the people this app is
// for are updated remotely, by family, through Play), and the debug key is
// public, so it must never be what ships. Now a release task fails with
// instructions instead, unless the fallback is asked for by name:
//
//     ./gradlew assembleRelease -PallowDebugSignedRelease=true
//     ORG_GRADLE_PROJECT_allowDebugSignedRelease=true flutter build apk --release
//
// The check runs when the task graph is ready and looks only at release tasks
// of this module, so debug builds, IDE sync and configuring any other task are
// untouched on a machine with no keystore.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val allowDebugSignedRelease =
    (project.findProperty("allowDebugSignedRelease") as String?)?.toBoolean() ?: false

if (!keystorePropertiesFile.exists() && !allowDebugSignedRelease) {
    val appProjectPath = project.path
    gradle.taskGraph.whenReady {
        val releaseTask = allTasks.firstOrNull {
            it.project.path == appProjectPath && it.name.contains("Release")
        }
        if (releaseTask != null) {
            throw GradleException(
                """
                Refusing to run ${releaseTask.path}: no release signing key.

                ${keystorePropertiesFile.absolutePath} does not exist, so this build would be
                signed with the public debug key and could not update the installed app.

                Either create android/key.properties with
                    storeFile=<path to the upload keystore, relative to android/app>
                    storePassword=...
                    keyAlias=...
                    keyPassword=...
                or, for a throwaway local build only, opt in explicitly:
                    -PallowDebugSignedRelease=true
                    (with flutter build: ORG_GRADLE_PROJECT_allowDebugSignedRelease=true)
                """.trimIndent()
            )
        }
    }
}

android {
    namespace = "com.unnanego.freecaller"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.unnanego.freecaller"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 37
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Debug signing only on the explicit opt-in above; without it a
            // release task never gets this far (see the top of this file).
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // FreecallerMessagingService extends the Flutter FCM service; compile
    // against the Firebase Messaging API. The runtime artifact is provided by
    // the firebase_messaging plugin, so keep this compileOnly to avoid pinning
    // a conflicting version.
    compileOnly("com.google.firebase:firebase-messaging:24.1.0")
}
