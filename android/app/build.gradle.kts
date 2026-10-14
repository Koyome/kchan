plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "me.koyome.kchan"
    compileSdk = 36
    // 各插件统一要求 NDK 28.2（向后兼容）
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "me.koyome.kchan"
        // Flutter 3.47.x 要求 minSdk >= 23（建议 24 以避免后续弃用）
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 仅打包主流手机 ABI，控制体积（fvp 会为每个 ABI 编译原生库）
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    buildTypes {
        release {
            // 试用版：使用 debug 签名，站长可直接安装试用
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // 依赖 AAR（jni / datastore 等）自带 x86 / x86_64 预编译库，
    // abiFilters 不会过滤它们，需显式排除以缩减体积（真机均为 ARM）。
    packaging {
        resources {
            // androidx.annotation 1.10.0 与 annotation-jvm 1.10.0 携带同名 LICENSE，
            // 合并 Java 资源时会冲突，排除重复项（许可信息不影响运行时）。
            excludes += listOf(
                "META-INF/androidx/annotation/annotation/LICENSE.txt",
                "META-INF/LICENSE.txt",
                "META-INF/NOTICE.txt",
                "META-INF/*.kotlin_module",
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
            )
        }
        jniLibs {
            excludes += listOf(
                "lib/x86/**",
                "lib/x86_64/**",
                "lib/arm64/**",
                "lib/mips/**",
            )
            // 关键兼容性设置：把 .so 释放到 /data/app 再加载。
            // AGP 8.x 默认 useLegacyPackaging=false（即 extractNativeLibs="false"），
            // 要求所有 .so 在 APK 内 STORED + 页对齐，并在加载时直接 mmap。
            // 部分国产 ROM（iQOO / OriginOS 等）与 Android 7~11 的组合对该路径
            // 兼容性不佳，会出现「安装后点图标闪退 / 打不开」。
            // 显式使用 legacy 打包（extractNativeLibs="true"）可最大化兼容性，
            // 代价仅是安装时多占用一点存储。
            useLegacyPackaging = true
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
