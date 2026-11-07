import javax.inject.Inject
import org.gradle.process.ExecOperations

abstract class BuildRustJniTask @Inject constructor(private val execOperations: ExecOperations) : DefaultTask() {
    @get:InputFiles abstract val rustInputs: ConfigurableFileCollection
    @get:Internal abstract val repositoryDirectory: DirectoryProperty
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty
    @TaskAction fun build() {
        execOperations.exec {
            workingDir(repositoryDirectory.get().asFile)
            commandLine("python3", repositoryDirectory.file("android-native/build_android.py").get().asFile, "--out", outputDirectory.get().asFile)
        }
    }
}

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.padlink.controller"
    compileSdk = 37
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "com.padlink.controller"
        minSdk = 28
        targetSdk = 37
        versionCode = providers.environmentVariable("PADLINK_ANDROID_VERSION_CODE")
            .map { value -> value.toInt().also { require(it in 1..2100000000) { "Invalid Android version code" } } }
            .orElse(1).get()
        versionName = providers.environmentVariable("PADLINK_ANDROID_VERSION_NAME").orElse("0.1.0").get()
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64") }

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }

        release {
            // Enable R8 once a device test matrix exists.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }

    packaging {
        jniLibs { useLegacyPackaging = false }
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    lint {
        // Adaptive-icon XML must stay under -v26 even though minSdk is 28.
        disable += "ObsoleteSdkInt"
    }
}

val buildRustJni = tasks.register<BuildRustJniTask>("buildRustJni") {
    val repositoryRoot = rootProject.projectDir.parentFile
    val destination = layout.buildDirectory.dir("generated/rustJni")
    repositoryDirectory.set(repositoryRoot)
    rustInputs.from(fileTree(repositoryRoot.resolve("protocol/src")), fileTree(repositoryRoot.resolve("android-native/src")))
    rustInputs.from(repositoryRoot.resolve("Cargo.toml"), repositoryRoot.resolve("Cargo.lock"), repositoryRoot.resolve("protocol/Cargo.toml"), repositoryRoot.resolve("android-native/Cargo.toml"), repositoryRoot.resolve("android-native/build_android.py"))
    outputDirectory.set(destination)
}
androidComponents.onVariants { variant ->
    variant.sources.jniLibs?.addGeneratedSourceDirectory(buildRustJni, BuildRustJniTask::outputDirectory)
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.customview)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.core)

    testImplementation(libs.junit)

    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)

    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
