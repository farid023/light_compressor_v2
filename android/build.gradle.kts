plugins {
    id("com.android.library")
}

group = "com.gurfdev.light_compressor_v2"
version = "1.0"

rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

configure<com.android.build.api.dsl.LibraryExtension> {

    namespace = "com.gurfdev.light_compressor_v2"
    compileSdk = 34

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    sourceSets {
        getByName("main") {
            java.directories.add("src/main/kotlin")
        }
        getByName("test") {
            java.directories.add("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    lint {
        disable.add("InvalidPackage")
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("com.google.code.gson:gson:2.10.1")
    testImplementation("junit:junit:4.13.2")
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
    }
}