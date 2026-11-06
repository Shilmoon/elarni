plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "com.elarni"
    compileSdk = 37
    ndkVersion = "28.2.13676358"
    defaultConfig {
        applicationId = "com.elarni"
        minSdk = 30
        targetSdk = 36
        versionCode = 13
        versionName = "0.5.0"
        // scripts/check-android passes x86_64 for emulators on x86_64 hosts; releases ship arm64-v8a.
        ndk { abiFilters += (findProperty("elarni.abi") as String?) ?: "arm64-v8a" }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Connection recording ships only in builds made with ELARNI_RECORDING=1, which also
        // gives scripts/build-android-native's core its recorder.
        buildConfigField("boolean", "ELARNI_RECORDING", (System.getenv("ELARNI_RECORDING") == "1").toString())
    }
    buildTypes {
        debug { applicationIdSuffix = ".debug"; versionNameSuffix = "-dev" }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets["main"].jniLibs.srcDir("../../.build/android-native/jniLibs")
    sourceSets["main"].assets.directories.add(layout.buildDirectory.dir("generated/notices").get().asFile.absolutePath)
    // Desktop `flutter pub get` may generate this file because android/ exists.
    // This independent Kotlin host does not include the Flutter engine.
    sourceSets["main"].java.directories.apply {
        clear()
        add("src/main/java/com/elarni")
    }
}
val prepareNotices = tasks.register<Sync>("prepareNotices") {
    from(rootProject.file("../LICENSE"), rootProject.file("../NOTICE"), rootProject.file("../THIRD_PARTY_NOTICES"))
    from(rootProject.file("OPEN_SOURCE_NOTICES"))
    into(layout.buildDirectory.dir("generated/notices"))
}
tasks.named("preBuild") { dependsOn(prepareNotices) }
kotlin { jvmToolchain(17) }
dependencies {
    implementation(files("../../.build/android-native/elarni-libxray.aar"))
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    testImplementation("junit:junit:4.13.2")
    // android.jar only stubs org.json; JVM tests need the real implementation.
    testImplementation("org.json:json:20260814")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.09.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4-accessibility")
    androidTestImplementation("androidx.test:core:1.7.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
