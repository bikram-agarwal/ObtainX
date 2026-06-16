import java.io.FileInputStream
import java.util.Properties
import com.android.build.gradle.internal.api.ApkVariantOutputImpl

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.reader(Charsets.UTF_8).use { reader ->
        localProperties.load(reader)
    }
}

var flutterVersionCode = localProperties.getProperty("flutter.versionCode") ?: "1"
var flutterVersionName = localProperties.getProperty("flutter.versionName") ?: "1.0"

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val keystorePropertiesExists = keystorePropertiesFile.exists()
if (keystorePropertiesExists) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "dev.imranr.obtainium"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_21.toString()
    }

    defaultConfig {
        applicationId = "dev.bikram.obtainx"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutterVersionCode.toInt()
        versionName = flutterVersionName
    }

    flavorDimensions += "default"

    productFlavors {
        create("normal") {
            dimension = "default"
            applicationIdSuffix = ""
        }
        create("fdroid") {
            dimension = "default"
            // Intentionally NO applicationIdSuffix: the F-Droid build shares the
            // GitHub build's applicationId (dev.bikram.obtainx) and signing key so
            // updates cross between channels seamlessly. This relies on F-Droid
            // publishing OUR signed APK via the reproducible-build path (Builds.binary
            // in the fdroiddata recipe) — do NOT re-add a suffix. The flavor still
            // exists only to run lib/main_fdroid.dart, which disables self-updating
            // (F-Droid policy: the store updates the app, it must not update itself).
            applicationIdSuffix = ""
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            val releaseSigningConfig = signingConfigs.getByName("release")
            signingConfig = if (keystorePropertiesExists && releaseSigningConfig.storeFile != null) {
                releaseSigningConfig
            } else {
                if (gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }) {
                    logger.error(
                        """
                            WARNING: You are trying to create a release build, but a key.properties file was not found.
                                     You will need to sign the APKs separately.

                            To sign a release build automatically, a keystore properties file is required.

                            The following is an example configuration.
                            Create a file named [project]/android/key.properties that contains a reference to your keystore.
                            Don't include the angle brackets (< >). They indicate that the text serves as a placeholder for your values.

                            storePassword=<keystore password>
                            keyPassword=<key password>
                            keyAlias=<key alias>
                            storeFile=<keystore file location>

                            For more info, see:
                            * https://docs.flutter.dev/deployment/android#sign-the-app
                        """.trimIndent()
                    )
                }
                null
            }
        }
        getByName("debug") {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }
}

// Every APK — both the split-per-abi GitHub builds and the universal F-Droid
// build — gets versionCode = base * 10. This keeps all codes uniform and in the established 5-digit
// range (e.g. base 3800 -> 38000), which matters for two reasons:
//   * Existing GitHub users are NEVER downgraded — codes only ever go up
//     (37903 -> 38000). Dropping to the 4-digit base (3800) would brick their
//     updates, so we must keep the *10 multiplier.
//   * The universal F-Droid APK shares ONE versionCode with the GitHub builds,
//     so installs are interchangeable across channels in either direction.
// We deliberately do NOT use distinct per-abi codes (38001/2/3): unique codes
// per APK are only required by Google Play, and ObtainX is not on Play (it's a
// sideloading manager Play would reject). The fdroiddata recipe reproduces this
// versionCode for auto-update via `VercodeOperation: %c * 10 `.
android.applicationVariants.configureEach {
    val variant = this
    variant.outputs.forEach { output ->
        (output as ApkVariantOutputImpl).versionCodeOverride = variant.versionCode * 10
    }
}


dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
