// melody: strip Python remote debugger
// serious_python_android splits CPython's stdlib bundle during the Gradle build.
// Remove the optional debugger after that split so neither the native extension
// nor its zipimport marker is shipped in production APKs or bundles.
gradle.projectsEvaluated {
    rootProject.findProject(":serious_python_android")?.tasks
        ?.matching { it.name.startsWith("splitStdlib_") }
        ?.configureEach {
            doLast {
                val abi = name.removePrefix("splitStdlib_")
                project.file("src/main/jniLibs/$abi/lib_remote_debugging.so").delete()

                val stdlib = project.file("src/main/assets/stdlib.zip")
                if (!stdlib.isFile) return@doLast
                val filtered = project.file("src/main/assets/stdlib.filtered.zip")
                var found = false
                java.util.zip.ZipFile(stdlib).use { source ->
                    java.util.zip.ZipOutputStream(filtered.outputStream()).use { target ->
                        source.entries().asSequence().forEach { entry ->
                            if (entry.name == "_remote_debugging.soref") {
                                found = true
                            } else {
                                target.putNextEntry(java.util.zip.ZipEntry(entry))
                                source.getInputStream(entry).use { it.copyTo(target) }
                                target.closeEntry()
                            }
                        }
                    }
                }
                if (found) {
                    java.nio.file.Files.move(
                        filtered.toPath(),
                        stdlib.toPath(),
                        java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                    )
                } else {
                    filtered.delete()
                }
            }
        }
}
