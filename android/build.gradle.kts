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

// Часть подключаемых Android-плагинов (например, flutter_webrtc) собрана со
// старым compileSdk (31), из-за чего современные androidx-зависимости падают
// на этапе конфигурации Gradle. Подстраиваем compileSdk Android-подпроектов
// под уровень приложения.
fun setCompileSdk(project: Project) {
    val android = project.extensions.findByName("android") ?: return
    try {
        val setter = android.javaClass.methods.firstOrNull {
            it.parameterCount == 1 &&
                it.parameterTypes[0] == Int::class.javaPrimitiveType &&
                it.name.contains("CompileSdk", ignoreCase = true)
        }
        if (setter != null) {
            println("compileSdk override: ${project.name} -> 36")
            setter.invoke(android, 36)
        }
    } catch (e: Exception) {
        println("compileSdk override FAILED for ${project.name}: $e")
    }
}

subprojects {
    if (state.executed) {
        setCompileSdk(this)
    } else {
        afterEvaluate {
            setCompileSdk(this)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
