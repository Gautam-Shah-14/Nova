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

// Older Flutter plugins (e.g. vosk_flutter_2) ship an android/build.gradle that
// AGP 8+/9 rejects: no `namespace`, and a stale `compileSdk` (33) that's older
// than what their transitive androidx deps require. Patch both by reflection so
// this root script needs no AGP on its classpath. Must run before
// evaluationDependsOn(":app") below, and cope with already-evaluated subprojects.
fun Project.patchAndroidPlugin() {
    val androidExt = extensions.findByName("android") ?: return
    try {
        val getNs = androidExt.javaClass.getMethod("getNamespace")
        val setNs = androidExt.javaClass.getMethod("setNamespace", String::class.java)
        if (getNs.invoke(androidExt) == null) {
            val manifest = file("src/main/AndroidManifest.xml")
            val pkg = if (manifest.exists()) {
                Regex("package=\"([^\"]+)\"").find(manifest.readText())?.groupValues?.get(1)
            } else null
            setNs.invoke(
                androidExt,
                pkg ?: "com.tokenburners.patched.${name.replace('-', '_')}",
            )
        }
    } catch (_: Exception) {
    }
    try {
        androidExt.javaClass
            .getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
            .invoke(androidExt, 36)
    } catch (_: Exception) {
    }
}

subprojects {
    if (name == "app") return@subprojects
    if (state.executed) patchAndroidPlugin() else afterEvaluate { patchAndroidPlugin() }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
