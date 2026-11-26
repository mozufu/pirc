package org.mozufu.pirc

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Strings Kotlin shows without the Flutter engine exist in English and Traditional Chinese. */
class StringsTest {
    private fun keys(folder: String): Map<String, String> {
        // Gradle runs unit tests in the module directory (apps/app/android/app).
        val file = File("src/main/res/$folder/strings.xml")
        assertTrue("${file.absolutePath} exists", file.isFile)
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val strings = document.getElementsByTagName("string")
        return (0 until strings.length).associate { i ->
            val node = strings.item(i)
            node.attributes.getNamedItem("name").nodeValue to node.textContent
        }
    }

    @Test fun bothLanguagesHaveTheSameKeys() {
        val english = keys("values")
        val chinese = keys("values-zh-rTW")
        assertTrue(english.isNotEmpty())
        assertEquals(english.keys, chinese.keys)
    }

    @Test fun placeholdersMatch() {
        val english = keys("values")
        val chinese = keys("values-zh-rTW")
        val placeholder = Regex("%\\d+\\$[sd]")
        for ((key, text) in english) {
            assertEquals(key, placeholder.findAll(text).map { it.value }.toSet(), placeholder.findAll(chinese.getValue(key)).map { it.value }.toSet())
        }
    }
}
