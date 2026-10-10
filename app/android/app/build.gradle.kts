plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.connectcar.connect"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // RoadGuard: on-device road scan (ncnn + Vulkan). Prebuilt ncnn lives in android/third_party,
    // fetched by tool/get_ncnn.sh.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    // Model files must stay uncompressed so ncnn can read them straight from the APK.
    androidResources { noCompress += listOf("bin", "param") }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time on older Android versions.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "app.connectcar.connect"
        // A lab build (tool/sound_lab.dart) sets CONNECT_ID_SUFFIX=.lab so it installs beside
        // the real app instead of over it; the real app's account lives only on the phone.
        System.getenv("CONNECT_ID_SUFFIX")?.takeIf { it.isNotBlank() }?.let { applicationIdSuffix = it }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                abiFilters += listOf("arm64-v8a", "x86_64")
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                    "-DNCNN_ROOT=" + file("../third_party/ncnn-20260526-android-vulkan").absolutePath.replace("\\", "/"),
                )
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

// The ML Kit image-labelling plugin drags in the legacy firebase-iid, whose
// classes firebase-messaging already contains.
configurations.all {
    exclude(group = "com.google.firebase", module = "firebase-iid")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // RoadGuard road scan
    val camerax = "1.4.2"
    implementation("androidx.camera:camera-core:$camerax")
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")
    implementation("androidx.lifecycle:lifecycle-service:2.8.7")
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.android.gms:play-services-tasks:18.4.1")
}
