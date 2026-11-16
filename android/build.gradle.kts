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

// Release lint (lintVital) crashes on the webview_flutter_android plugin
// library with a lint-tooling bug (NoSuchMethodError in JavaDocParser,
// Kotlin FIR) while analyzing AndroidWebkitLibrary.g.kt — this is not our
// code. Disable the lintVital tasks in every module, including plugin
// libraries, so assembleRelease does not run them. The app module's own
// lint setting would not stop a plugin library's lintVital task, so this
// has to live here in the root build script.
subprojects {
    tasks.matching { it.name.startsWith("lintVital") }.configureEach {
        enabled = false
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
