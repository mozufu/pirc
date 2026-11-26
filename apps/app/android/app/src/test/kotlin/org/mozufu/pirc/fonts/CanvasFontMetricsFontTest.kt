package org.mozufu.pirc.fonts

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CanvasFontMetricsFontTest {
    @Test fun convertsStaticCffAndPreservesHorizontalMetricsAndShapingTables() {
        val source = staticCffFont()
        val original = readTables(source)
        val derived = CanvasFontMetricsFont.deriveAdvanceFont(source)
        requireNotNull(derived)
        val result = readTables(derived)

        assertEquals(TRUETYPE_VERSION, readUInt32(derived, 0))
        assertFalse("CFF " in result)
        assertEquals(0, result.getValue("glyf").length)
        assertArrayEquals(ByteArray((GLYPH_COUNT + 1) * 2), tableBytes(derived, result.getValue("loca")))
        assertEquals(
            listOf("GDEF", "GPOS", "GSUB", "OS/2", "cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post"),
            result.keys.toList(),
        )

        for (tag in listOf("GDEF", "GPOS", "GSUB", "OS/2", "cmap", "hhea", "hmtx", "name", "post")) {
            assertArrayEquals("table $tag", tableBytes(source, original.getValue(tag)), tableBytes(derived, result.getValue(tag)))
        }

        val originalHead = tableBytes(source, original.getValue("head"))
        val derivedHead = tableBytes(derived, result.getValue("head"))
        assertArrayEquals(originalHead.copyOfRange(0, 8), derivedHead.copyOfRange(0, 8))
        assertArrayEquals(originalHead.copyOfRange(12, 50), derivedHead.copyOfRange(12, 50))
        assertArrayEquals(originalHead.copyOfRange(52, originalHead.size), derivedHead.copyOfRange(52, derivedHead.size))
        assertEquals(0, readUInt16(derivedHead, 50))
        assertFalse(originalHead.copyOfRange(8, 12).contentEquals(derivedHead.copyOfRange(8, 12)))

        val maxp = tableBytes(derived, result.getValue("maxp"))
        assertEquals(32, maxp.size)
        assertEquals(0x00010000L, readUInt32(maxp, 0))
        assertEquals(GLYPH_COUNT, readUInt16(maxp, 4))
        assertEquals(1, readUInt16(maxp, 14))
        for (offset in listOf(6, 8, 10, 12, 16, 18, 20, 22, 24, 26, 28, 30)) {
            assertEquals("maxp field at $offset", 0, readUInt16(maxp, offset))
        }

        for ((tag, table) in result) {
            assertEquals(0, table.offset % 4)
            val bytes = tableBytes(derived, table)
            if (tag == "head") bytes.fill(0, 8, 12)
            assertEquals("checksum for $tag", checksum(bytes), table.checksum)
        }
        assertEquals(CHECKSUM_MAGIC, checksum(derived))
        assertTrue(derived.size < source.size)
    }

    @Test fun doesNotStripTrueTypeOrVariableCff1Outlines() {
        val trueType = makeSfnt(
            TRUETYPE_VERSION,
            mapOf("glyf" to byteArrayOf(), "loca" to ByteArray((GLYPH_COUNT + 1) * 2)) + commonTables(cff = false),
        )
        assertNull(CanvasFontMetricsFont.deriveAdvanceFont(trueType))

        for (variationTag in listOf("avar", "cvar", "fvar", "gvar", "HVAR", "VVAR", "MVAR")) {
            val variable = makeSfnt(OTTO_VERSION, commonTables(cff = true) + (variationTag to byteArrayOf(1, 2, 3, 4)))
            assertNull("variation table $variationTag", CanvasFontMetricsFont.deriveAdvanceFont(variable))
        }

        val cff2 = makeSfnt(
            OTTO_VERSION,
            commonTables(cff = false) + ("CFF2" to byteArrayOf(1, 2, 3, 4)),
        )
        assertNull(CanvasFontMetricsFont.deriveAdvanceFont(cff2))
    }

    @Test fun rejectsMalformedCffMetricsBeforeRebuilding() {
        val invalidMaxp = staticCffFont().also {
            val maxpRecord = findRecord(it, "maxp")
            writeUInt32(it, maxpRecord.offset, 0x00010000L)
        }
        expectFailure { CanvasFontMetricsFont.deriveAdvanceFont(invalidMaxp) }

        val truncatedHmtx = staticCffFont().also {
            val hmtxRecord = findRecord(it, "hmtx")
            writeUInt32(it, hmtxRecord.recordOffset + 12, 1)
        }
        expectFailure { CanvasFontMetricsFont.deriveAdvanceFont(truncatedHmtx) }
    }

    @Test fun convertsCff2AndPreservesVariationAdvanceTables() {
        val source = variableCff2Font()
        val original = readTables(source)
        val derived = CanvasFontMetricsFont.deriveAdvanceFont(source)
        requireNotNull(derived)
        val result = readTables(derived)

        assertEquals(TRUETYPE_VERSION, readUInt32(derived, 0))
        assertFalse("CFF2" in result)
        assertFalse("DSIG" in result)
        assertEquals(0, result.getValue("glyf").length)
        assertArrayEquals(ByteArray((GLYPH_COUNT + 1) * 2), tableBytes(derived, result.getValue("loca")))
        assertEquals(
            listOf("GDEF", "GPOS", "GSUB", "HVAR", "OS/2", "avar", "cmap", "fvar", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post"),
            result.keys.toList(),
        )

        for (tag in listOf("GDEF", "GPOS", "GSUB", "HVAR", "OS/2", "avar", "cmap", "fvar", "hhea", "hmtx", "name", "post")) {
            assertArrayEquals("table $tag", tableBytes(source, original.getValue(tag)), tableBytes(derived, result.getValue(tag)))
        }
        assertEquals(CHECKSUM_MAGIC, checksum(derived))
        assertTrue(derived.size < source.size)
    }

    @Test fun rejectsCff2WithoutSupportedHorizontalVariationData() {
        val base = commonTables(cff = false) + ("CFF2" to ByteArray(16))
        assertNull(CanvasFontMetricsFont.deriveAdvanceFont(makeSfnt(OTTO_VERSION, base)))
        assertNull(
            CanvasFontMetricsFont.deriveAdvanceFont(
                makeSfnt(OTTO_VERSION, base + ("fvar" to makeFvar())),
            ),
        )
        assertNull(
            CanvasFontMetricsFont.deriveAdvanceFont(
                makeSfnt(OTTO_VERSION, base + ("HVAR" to makeHvar())),
            ),
        )

        for (unsupportedTag in listOf("gvar", "cvar")) {
            val tables = base + ("fvar" to makeFvar()) + ("HVAR" to makeHvar()) +
                (unsupportedTag to byteArrayOf(1, 2, 3, 4))
            assertNull(
                unsupportedTag,
                CanvasFontMetricsFont.deriveAdvanceFont(makeSfnt(OTTO_VERSION, tables)),
            )
        }
    }

    private fun staticCffFont(): ByteArray = makeSfnt(OTTO_VERSION, commonTables(cff = true))

    private fun variableCff2Font(): ByteArray = makeSfnt(
        OTTO_VERSION,
        commonTables(cff = false) + mapOf(
            "CFF2" to ByteArray(4 * 1024 * 1024) { (it * 17).toByte() },
            "DSIG" to byteArrayOf(0, 0, 0, 0),
            "HVAR" to makeHvar(),
            "avar" to makeAvar(),
            "fvar" to makeFvar(),
        ),
    )

    private fun commonTables(cff: Boolean): Map<String, ByteArray> = buildMap {
        if (cff) put("CFF ", ByteArray(4 * 1024 * 1024) { (it * 31).toByte() })
        put("GDEF", byteArrayOf(1, 0, 0, 0))
        put("GPOS", byteArrayOf(1, 0, 0, 0))
        put("GSUB", byteArrayOf(1, 0, 0, 0))
        put("OS/2", byteArrayOf(0, 4, 0, 0))
        put("cmap", byteArrayOf(0, 0, 0, 0))
        put("head", makeHead())
        put("hhea", makeHhea())
        put("hmtx", makeHmtx())
        put("maxp", makeCffMaxp())
        put("name", byteArrayOf(0, 0, 0, 0, 0, 0))
        put("post", byteArrayOf(0, 3, 0, 0))
    }

    private fun makeHead(): ByteArray = ByteArray(54).also {
        writeUInt32(it, 0, 0x00010000L)
        writeUInt32(it, 8, 0x12345678L)
        writeUInt16(it, 18, 1000)
        writeUInt16(it, 50, 1)
    }

    private fun makeHhea(): ByteArray = ByteArray(36).also {
        writeUInt32(it, 0, 0x00010000L)
        writeUInt16(it, 34, GLYPH_COUNT)
    }

    private fun makeHmtx(): ByteArray = ByteArray(GLYPH_COUNT * 4).also {
        val metrics = listOf(500 to 3, 600 to 19, 700 to 0, 800 to 24)
        for ((index, metric) in metrics.withIndex()) {
            writeUInt16(it, index * 4, metric.first)
            writeUInt16(it, index * 4 + 2, metric.second)
        }
    }

    private fun makeCffMaxp(): ByteArray = ByteArray(6).also {
        writeUInt32(it, 0, 0x00005000L)
        writeUInt16(it, 4, GLYPH_COUNT)
    }

    private fun makeFvar(): ByteArray = ByteArray(84).also {
        writeUInt16(it, 0, 1)
        writeUInt16(it, 2, 0)
        writeUInt16(it, 4, 16)
        writeUInt16(it, 6, 2)
        writeUInt16(it, 8, 1)
        writeUInt16(it, 10, 20)
        writeUInt16(it, 12, 6)
        writeUInt16(it, 14, 8)
        putTag(it, 16, "wght")
        writeUInt32(it, 20, 100L shl 16)
        writeUInt32(it, 24, 400L shl 16)
        writeUInt32(it, 28, 900L shl 16)
        writeUInt16(it, 32, 0)
        writeUInt16(it, 34, 256)
    }

    private fun makeAvar(): ByteArray = ByteArray(30).also {
        writeUInt16(it, 0, 1)
        writeUInt16(it, 2, 0)
        writeUInt16(it, 4, 0)
        writeUInt16(it, 6, 1)
        writeUInt16(it, 8, 5)
        val coordinates = listOf(-16384, -8192, 0, 8192, 16384)
        for ((index, coordinate) in coordinates.withIndex()) {
            writeUInt16(it, 10 + index * 4, coordinate)
            writeUInt16(it, 12 + index * 4, coordinate)
        }
    }

    private fun makeHvar(): ByteArray = ByteArray(52).also {
        writeUInt16(it, 0, 1)
        writeUInt16(it, 2, 0)
        writeUInt32(it, 4, 20)
        writeUInt32(it, 8, 0)
        writeUInt32(it, 12, 0)
        writeUInt32(it, 16, 0)
        writeUInt16(it, 20, 1)
        writeUInt32(it, 22, 12)
        writeUInt16(it, 26, 1)
        writeUInt32(it, 28, 22)
        writeUInt16(it, 32, 1)
        writeUInt16(it, 34, 1)
        writeUInt16(it, 36, -16384)
        writeUInt16(it, 38, 16384)
        writeUInt16(it, 40, 16384)
        writeUInt16(it, 42, 1)
        writeUInt16(it, 44, 1)
        writeUInt16(it, 46, 1)
        writeUInt16(it, 48, 0)
        writeUInt16(it, 50, 25)
    }

    private fun makeSfnt(version: Long, inputTables: Map<String, ByteArray>): ByteArray {
        val tables = inputTables.toSortedMap()
        val directoryEnd = 12 + tables.size * 16
        var cursor = align4(directoryEnd)
        val offsets = linkedMapOf<String, Int>()
        for ((tag, bytes) in tables) {
            cursor = align4(cursor)
            offsets[tag] = cursor
            cursor += bytes.size
            cursor = align4(cursor)
        }
        return ByteArray(cursor).also { output ->
            writeUInt32(output, 0, version)
            writeUInt16(output, 4, tables.size)
            val power = Integer.highestOneBit(tables.size)
            writeUInt16(output, 6, power * 16)
            writeUInt16(output, 8, Integer.numberOfTrailingZeros(power))
            writeUInt16(output, 10, tables.size * 16 - power * 16)
            for ((index, entry) in tables.entries.withIndex()) {
                val (tag, bytes) = entry
                val record = 12 + index * 16
                putTag(output, record, tag)
                writeUInt32(output, record + 8, offsets.getValue(tag).toLong())
                writeUInt32(output, record + 12, bytes.size.toLong())
                bytes.copyInto(output, offsets.getValue(tag))
            }
        }
    }

    private fun readTables(bytes: ByteArray): LinkedHashMap<String, Table> {
        val count = readUInt16(bytes, 4)
        val result = linkedMapOf<String, Table>()
        for (index in 0 until count) {
            val record = 12 + index * 16
            val tag = String(bytes, record, 4, Charsets.US_ASCII)
            result[tag] = Table(
                recordOffset = record,
                offset = readUInt32(bytes, record + 8).toInt(),
                length = readUInt32(bytes, record + 12).toInt(),
                checksum = readUInt32(bytes, record + 4),
            )
        }
        return result
    }

    private fun findRecord(bytes: ByteArray, tag: String): Table =
        readTables(bytes).getValue(tag)

    private fun tableBytes(bytes: ByteArray, table: Table): ByteArray =
        bytes.copyOfRange(table.offset, table.offset + table.length)

    private fun checksum(bytes: ByteArray): Long {
        var sum = 0L
        for (start in bytes.indices step 4) {
            var word = 0L
            for (index in 0 until 4) {
                if (start + index < bytes.size) {
                    word = word or ((bytes[start + index].toLong() and 0xffL) shl (24 - 8 * index))
                }
            }
            sum = (sum + word) and 0xffff_ffffL
        }
        return sum
    }

    private fun putTag(bytes: ByteArray, offset: Int, tag: String) {
        tag.toByteArray(Charsets.US_ASCII).copyInto(bytes, offset)
    }

    private fun writeUInt16(bytes: ByteArray, offset: Int, value: Int) {
        bytes[offset] = (value ushr 8).toByte()
        bytes[offset + 1] = value.toByte()
    }

    private fun writeUInt32(bytes: ByteArray, offset: Int, value: Long) {
        bytes[offset] = (value ushr 24).toByte()
        bytes[offset + 1] = (value ushr 16).toByte()
        bytes[offset + 2] = (value ushr 8).toByte()
        bytes[offset + 3] = value.toByte()
    }

    private fun readUInt16(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xff) shl 8) or (bytes[offset + 1].toInt() and 0xff)

    private fun readUInt32(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xffL) shl 24) or
            ((bytes[offset + 1].toLong() and 0xffL) shl 16) or
            ((bytes[offset + 2].toLong() and 0xffL) shl 8) or
            (bytes[offset + 3].toLong() and 0xffL)

    private fun align4(value: Int): Int = (value + 3) and -4

    private inline fun expectFailure(block: () -> Unit) {
        try {
            block()
        } catch (_: IllegalArgumentException) {
            return
        }
        throw AssertionError("Expected invalid CFF metrics font to be rejected")
    }

    private data class Table(
        val recordOffset: Int,
        val offset: Int,
        val length: Int,
        val checksum: Long,
    )

    private companion object {
        const val OTTO_VERSION = 0x4f54544fL
        const val TRUETYPE_VERSION = 0x00010000L
        const val GLYPH_COUNT = 4
        const val CHECKSUM_MAGIC = 0xB1B0AFBAL
    }
}
