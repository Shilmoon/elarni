// Disposable traffic identities for emulator acceptance; never packaged with Elarni.
plugins { id("com.android.application") }
android {
    namespace = "com.elarni.traffic"
    compileSdk = 37
    defaultConfig { applicationId = "com.elarni.traffic"; minSdk = 30; targetSdk = 36; versionCode = 1; versionName = "fixture" }
    flavorDimensions += "identity"
    productFlavors {
        create("a") { dimension = "identity"; applicationIdSuffix = ".a" }
        create("b") { dimension = "identity"; applicationIdSuffix = ".b" }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
