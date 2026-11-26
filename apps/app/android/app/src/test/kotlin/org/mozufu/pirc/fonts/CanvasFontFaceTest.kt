package org.mozufu.pirc.fonts

import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CanvasFontFaceTest {
    @Test fun extractsSelectedCollectionFaceAndRebuildsChecksumsWithoutChangingTables() {
        val source = ttcV1()
        val extracted = CanvasFontFace.extract(source, 1)
        val tables = readOutputTables(extracted)

        assertEquals(listOf("TEST", "head"), tables.keys.toList())
        assertArrayEquals("shared".toByteArray(), tableBytes(extracted, tables.getValue("TEST")))

        val originalHead = source.copyOfRange(168, 184)
        val extractedHead = tableBytes(extracted, tables.getValue("head"))
        assertEquals(originalHead.size, extractedHead.size)
        assertArrayEquals(originalHead.copyOfRange(0, 8), extractedHead.copyOfRange(0, 8))
        assertArrayEquals(originalHead.copyOfRange(12, 16), extractedHead.copyOfRange(12, 16))
        assertFalse(originalHead.copyOfRange(8, 12).contentEquals(extractedHead.copyOfRange(8, 12)))

        for ((tag, record) in tables) {
            assertEquals(0, record.offset % 4)
            val checksumBytes = tableBytes(extracted, record).also {
                if (tag == "head") it.fill(0, 8, 12)
            }
            assertEquals(checksum(checksumBytes), record.checksum)
        }
        assertEquals(CHECKSUM_MAGIC, checksum(extracted))
    }

    @Test fun extractsTtcV2AndDropsCollectionSignature() {
        val extracted = CanvasFontFace.extract(ttcV2(), 0)
        assertEquals(listOf("TEST", "head"), readOutputTables(extracted).keys.toList())
        assertEquals(CHECKSUM_MAGIC, checksum(extracted))
    }

    @Test fun standaloneFontIsPassedThroughAndRejectsNonzeroCollectionIndex() {
        val standalone = byteArrayOf(0, 1, 2, 3, 4, 5)
        assertArrayEquals(standalone, CanvasFontFace.extract(standalone, 0))
        expectFailure { CanvasFontFace.extract(standalone, 1) }
    }

    @Test fun readsOnlyTheSuppliedByteBufferSlice() {
        val font = ttcV1()
        val wrapped = ByteBuffer.allocate(font.size + 8)
        wrapped.putInt(0x01020304)
        wrapped.put(font)
        wrapped.putInt(0x05060708)
        wrapped.flip()
        wrapped.position(4)
        wrapped.limit(4 + font.size)

        val extracted = CanvasFontFace.extract(wrapped, 1)
        assertArrayEquals("shared".toByteArray(), tableBytes(extracted, readOutputTables(extracted).getValue("TEST")))
    }

    @Test fun rejectsMalformedTtcRangesVersionsAndIndices() {
        val valid = ttcV1()

        val badVersion = valid.copyOf().also { putUInt32(it, 4, 0x00030000L) }
        expectFailure { CanvasFontFace.extract(badVersion, 0) }
        expectFailure { CanvasFontFace.extract(valid, 2) }

        val badDirectoryOffset = valid.copyOf().also { putUInt32(it, 16, 0xffff_ffffL) }
        expectFailure { CanvasFontFace.extract(badDirectoryOffset, 1) }

        // Face 1's TEST record points outside the source buffer after this change.
        val badTableRange = valid.copyOf().also { putUInt32(it, 116, 0xffff_fffcL) }
        expectFailure { CanvasFontFace.extract(badTableRange, 1) }

        val badV2Signature = ttcV2().also { putUInt32(it, 24, 0xffff_fffcL) }
        expectFailure { CanvasFontFace.extract(badV2Signature, 0) }
    }

    private fun ttcV1(): ByteArray {
        val bytes = ByteArray(184)
        putTag(bytes, 0, "ttcf")
        putUInt32(bytes, 4, 0x00010000L)
        putUInt32(bytes, 8, 2)
        putUInt32(bytes, 12, 20)
        putUInt32(bytes, 16, 80)
        writeDirectory(bytes, 20, headOffset = 152)
        writeDirectory(bytes, 80, headOffset = 168)
        putTag(bytes, 140, "sign")
        "shared".toByteArray().copyInto(bytes, 144)
        writeHead(bytes, 152, seed = 0x21)
        writeHead(bytes, 168, seed = 0x41)
        return bytes
    }

    private fun ttcV2(): ByteArray {
        val bytes = ByteArray(96)
        putTag(bytes, 0, "ttcf")
        putUInt32(bytes, 4, 0x00020000L)
        putUInt32(bytes, 8, 1)
        putUInt32(bytes, 12, 28)
        putUInt32(bytes, 16, 0x44534947L)
        putUInt32(bytes, 20, 4)
        putUInt32(bytes, 24, 92)
        writeUInt32(bytes, 28, 0x00010000L)
        writeUInt16(bytes, 32, 2)
        writeUInt16(bytes, 34, 32)
        writeUInt16(bytes, 36, 1)
        writeUInt16(bytes, 38, 0)
        writeRecord(bytes, 40, "TEST", 72, 4)
        writeRecord(bytes, 56, "head", 76, 16)
        "data".toByteArray().copyInto(bytes, 72)
        writeHead(bytes, 76, seed = 0x61)
        putTag(bytes, 92, "sig!")
        return bytes
    }

    private fun writeDirectory(bytes: ByteArray, offset: Int, headOffset: Int) {
        writeUInt32(bytes, offset, 0x00010000L)
        writeUInt16(bytes, offset + 4, 3)
        writeUInt16(bytes, offset + 6, 32)
        writeUInt16(bytes, offset + 8, 1)
        writeUInt16(bytes, offset + 10, 16)
        writeRecord(bytes, offset + 12, "DSIG", 140, 4)
        writeRecord(bytes, offset + 28, "TEST", 144, 6)
        writeRecord(bytes, offset + 44, "head", headOffset, 16)
    }

    private fun writeHead(bytes: ByteArray, offset: Int, seed: Int) {
        for (index in 0 until 16) bytes[offset + index] = (seed + index).toByte()
    }

    private fun writeRecord(bytes: ByteArray, offset: Int, tag: String, dataOffset: Int, length: Int) {
        putTag(bytes, offset, tag)
        writeUInt32(bytes, offset + 4, 0)
        writeUInt32(bytes, offset + 8, dataOffset.toLong())
        writeUInt32(bytes, offset + 12, length.toLong())
    }

    private fun readOutputTables(bytes: ByteArray): LinkedHashMap<String, Table> {
        val count = readUInt16(bytes, 4)
        val tables = linkedMapOf<String, Table>()
        for (index in 0 until count) {
            val offset = 12 + index * 16
            val tag = String(bytes, offset, 4, Charsets.US_ASCII)
            tables[tag] = Table(
                offset = readUInt32(bytes, offset + 8).toInt(),
                length = readUInt32(bytes, offset + 12).toInt(),
                checksum = readUInt32(bytes, offset + 4),
            )
        }
        return tables
    }

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

    private fun putUInt32(bytes: ByteArray, offset: Int, value: Long) = writeUInt32(bytes, offset, value)

    private inline fun expectFailure(block: () -> Unit) {
        try {
            block()
        } catch (_: IllegalArgumentException) {
            return
        }
        throw AssertionError("Expected malformed font input to be rejected")
    }

    private data class Table(val offset: Int, val length: Int, val checksum: Long)

    private companion object {
        const val CHECKSUM_MAGIC = 0xB1B0AFBAL
    }
}
