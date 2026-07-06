allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Some plugins (e.g. file_picker) still compile against SDK 34, but a
// transitive dependency now requires 36. Force every Android library
// subproject up to 36 so AAR-metadata checks pass.
subprojects {
    // `evaluationDependsOn(":app")` above can force some subprojects to be
    // evaluated before this block is applied to them, so guard against
    // registering an afterEvaluate hook on an already-evaluated project.
    val forceCompileSdk36: Project.() -> Unit = {
        extensions.findByName("android")?.let { ext ->
            val android = ext as com.android.build.gradle.BaseExtension
            if (android.compileSdkVersion?.substringAfter("-")?.toIntOrNull()
                    ?.let { it < 36 } != false) {
                android.compileSdkVersion(36)
            }
        }
    }
    if (state.executed) {
        forceCompileSdk36()
    } else {
        afterEvaluate { forceCompileSdk36() }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
