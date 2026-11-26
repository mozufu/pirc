package org.mozufu.pirc.fonts

import java.nio.ByteBuffer

/**
 * Extracts one font from a TTC/OTC container as an ordinary SFNT without changing its tables.
 * Only the non-metric `head.checkSumAdjustment` field and the SFNT directory/checksums are rebuilt;
 * DSIG data is omitted because the new standalone file is no longer the signed collection.
 */
object CanvasFontFace {
    private const val TTC_TAG = 0x74746366L // 'ttcf'
    private const val TTC_VERSION_1 = 0x00010000L
    private const val TTC_VERSION_2 = 0x00020000L
    private const val DSIG_TAG = 0x44534947L // 'DSIG'
    private const val CHECKSUM_MAGIC = 0xB1B0AFBAL
    private const val UINT32_MAX = 0xffff_ffffL

    private const val MAX_FONT_BYTES = 48 * 1024 * 1024
    private const val MAX_TTC_FONTS = 256
    private const val MAX_TABLES = 4095
    private const val MAX_TABLE_TAG = 4
    private const val SFNT_HEADER_BYTES = 12
    private const val TABLE_RECORD_BYTES = 16
    private const val HEAD_CHECKSUM_ADJUSTMENT_OFFSET = 8
    private const val HEAD_CHECKSUM_ADJUSTMENT_LENGTH = 4

    /** ByteArray overload for callers and tests that already own the complete font buffer. */
    fun extract(bytes: ByteArray, ttcIndex: Int): ByteArray = extract(ByteBuffer.wrap(bytes), ttcIndex)

    /**
     * Returns a standalone SFNT unchanged, or extracts [ttcIndex] from a TTC/OTC container.
     * The read-only duplicate lets Android's mapped font buffer be read directly; a TTC copy is
     * allocated only for the selected face's tables. An index other than zero is invalid for a
     * standalone font.
     */
    fun extract(buffer: ByteBuffer, ttcIndex: Int): ByteArray {
        require(ttcIndex >= 0) { "Font TTC index cannot be negative" }
        val input = buffer.slice().asReadOnlyBuffer()
        require(input.remaining() <= MAX_FONT_BYTES) { "Font input exceeds $MAX_FONT_BYTES bytes" }
        if (input.limit() < 4 || readUInt32(input, 0) != TTC_TAG) {
            require(ttcIndex == 0) { "A standalone font only has TTC index 0" }
            return copyBuffer(input)
        }
        return extractCollectionFace(input, ttcIndex)
    }

    private fun extractCollectionFace(bytes: ByteBuffer, ttcIndex: Int): ByteArray {
        require(bytes.limit() >= SFNT_HEADER_BYTES) { "Truncated TTC header" }
        val version = readUInt32(bytes, 4)
        require(version == TTC_VERSION_1 || version == TTC_VERSION_2) {
            "Unsupported TTC version 0x${version.toString(16)}"
        }

        val fontCountValue = readUInt32(bytes, 8)
        require(fontCountValue in 1L..MAX_TTC_FONTS.toLong()) {
            "Invalid TTC font count: $fontCountValue"
        }
        val fontCount = fontCountValue.toInt()
        require(ttcIndex < fontCount) { "TTC index $ttcIndex is outside font count $fontCount" }

        val offsetsEnd = SFNT_HEADER_BYTES.toLong() + fontCount.toLong() * 4L
        val headerSize = offsetsEnd + if (version == TTC_VERSION_2) 12L else 0L
        require(headerSize <= bytes.limit().toLong()) { "Truncated TTC offset array or header" }

        val collectionDsig = if (version == TTC_VERSION_2) {
            val fieldsOffset = offsetsEnd.toInt()
            val tag = readUInt32(bytes, fieldsOffset)
            val length = readUInt32(bytes, fieldsOffset + 4)
            val offset = readUInt32(bytes, fieldsOffset + 8)
            if (tag == 0L) {
                require(length == 0L && offset == 0L) { "Malformed empty TTC DSIG fields" }
                null
            } else {
                require(tag == DSIG_TAG) { "Invalid TTC DSIG tag" }
                require(length > 0L) { "Empty TTC DSIG data" }
                require(offset % 4L == 0L) { "Unaligned TTC DSIG offset" }
                val end = checkedEnd(offset, length, bytes.limit().toLong(), "TTC DSIG")
                require(end == bytes.limit().toLong()) { "TTC DSIG must end at the end of the file" }
                Range(offset, end)
            }
        } else {
            null
        }

        val directories = ArrayList<FontDirectory>(fontCount)
        for (fontIndex in 0 until fontCount) {
            val offset = readUInt32(bytes, SFNT_HEADER_BYTES + fontIndex * 4)
            require(offset % 4L == 0L) { "Unaligned TTC font directory offset" }
            require(offset >= headerSize) { "TTC font directory overlaps the TTC header" }
            val minimumEnd = checkedEnd(offset, SFNT_HEADER_BYTES.toLong(), bytes.limit().toLong(), "TTC font directory")
            val directoryOffset = offset.toInt()
            val tableCount = readUInt16(bytes, directoryOffset + 4)
            require(tableCount in 1..MAX_TABLES) { "Invalid TTC table count: $tableCount" }
            val directoryLength = SFNT_HEADER_BYTES.toLong() + tableCount.toLong() * TABLE_RECORD_BYTES
            val directoryEnd = checkedEnd(offset, directoryLength, bytes.limit().toLong(), "TTC table directory")
            require(directoryEnd >= minimumEnd)
            val directory = FontDirectory(directoryOffset, tableCount, directoryEnd)
            if (collectionDsig != null) {
                require(!directory.range.overlaps(collectionDsig)) { "TTC font directory overlaps DSIG data" }
            }
            directories.add(directory)
        }

        for (leftIndex in directories.indices) {
            for (rightIndex in leftIndex + 1 until directories.size) {
                require(!directories[leftIndex].range.overlaps(directories[rightIndex].range)) {
                    "TTC font directories overlap"
                }
            }
        }

        val selectedDirectory = directories[ttcIndex]
        val sfntVersion = readUInt32(bytes, selectedDirectory.offset)
        val tables = readSelectedTables(
            bytes = bytes,
            directory = selectedDirectory,
            ttcHeader = Range(0L, headerSize),
            allDirectories = directories,
            collectionDsig = collectionDsig,
        )
        return writeStandaloneFont(bytes, sfntVersion, tables)
    }

    private fun readSelectedTables(
        bytes: ByteBuffer,
        directory: FontDirectory,
        ttcHeader: Range,
        allDirectories: List<FontDirectory>,
        collectionDsig: Range?,
    ): List<FontTable> {
        val tables = ArrayList<FontTable>(directory.tableCount)
        var previousTag: String? = null
        val recordsStart = directory.offset + SFNT_HEADER_BYTES

        for (index in 0 until directory.tableCount) {
            val recordOffset = recordsStart + index * TABLE_RECORD_BYTES
            val tag = readTag(bytes, recordOffset)
            val previous = previousTag
            require(previous == null || previous < tag) {
                "TTC table tags must be unique and sorted"
            }
            previousTag = tag

            val sourceOffset = readUInt32(bytes, recordOffset + 8)
            val length = readUInt32(bytes, recordOffset + 12)
            require(sourceOffset % 4L == 0L) { "Unaligned TTC table offset for '$tag'" }
            require(sourceOffset >= ttcHeader.endExclusive) { "TTC table '$tag' overlaps the TTC header" }
            val end = checkedEnd(sourceOffset, length, bytes.limit().toLong(), "TTC table '$tag'")
            val range = Range(sourceOffset, end)

            for (fontDirectory in allDirectories) {
                require(!range.overlaps(fontDirectory.range)) {
                    "TTC table '$tag' overlaps a font directory"
                }
            }
            if (collectionDsig != null && range.overlaps(collectionDsig)) {
                val isCollectionDsigTable = tag == "DSIG" && range == collectionDsig
                require(isCollectionDsigTable) { "TTC table '$tag' overlaps collection DSIG data" }
            }

            tables.add(FontTable(tag, sourceOffset.toInt(), length.toInt()))
        }

        for (leftIndex in tables.indices) {
            val left = tables[leftIndex]
            val leftRange = Range(left.sourceOffset.toLong(), left.sourceOffset.toLong() + left.length)
            if (left.length == 0) continue
            for (rightIndex in leftIndex + 1 until tables.size) {
                val right = tables[rightIndex]
                if (right.length == 0) continue
                val rightRange = Range(right.sourceOffset.toLong(), right.sourceOffset.toLong() + right.length)
                val sharesExactData = leftRange == rightRange
                require(sharesExactData || !leftRange.overlaps(rightRange)) {
                    "TTC table ranges partially overlap"
                }
            }
        }
        return tables
    }

    private fun writeStandaloneFont(
        source: ByteBuffer,
        sfntVersion: Long,
        sourceTables: List<FontTable>,
    ): ByteArray {
        val tables = sourceTables.filterNot { it.tag == "DSIG" }
        require(tables.isNotEmpty()) { "Selected TTC face has no usable tables" }
        val head = tables.singleOrNull { it.tag == "head" }
            ?: error("Selected TTC face must contain exactly one 'head' table")
        require(head.length >= HEAD_CHECKSUM_ADJUSTMENT_OFFSET + HEAD_CHECKSUM_ADJUSTMENT_LENGTH) {
            "Selected TTC face has a truncated 'head' table"
        }
        require(tables.size <= MAX_TABLES) { "Standalone face has too many tables" }

        val directoryEnd = SFNT_HEADER_BYTES.toLong() + tables.size.toLong() * TABLE_RECORD_BYTES
        var outputCursor = align4(directoryEnd)
        val placements = ArrayList<TablePlacement>(tables.size)
        for (table in tables) {
            outputCursor = align4(outputCursor)
            val offset = outputCursor
            outputCursor = checkedAdd(outputCursor, table.length.toLong(), "standalone font size")
            outputCursor = align4(outputCursor)
            require(outputCursor <= MAX_FONT_BYTES.toLong()) {
                "Extracted TTC face exceeds $MAX_FONT_BYTES bytes"
            }
            require(offset <= UINT32_MAX && table.length.toLong() <= UINT32_MAX) {
                "Extracted TTC face table does not fit SFNT offsets"
            }
            placements.add(TablePlacement(table, offset.toInt()))
        }
        require(outputCursor <= MAX_FONT_BYTES.toLong() && outputCursor <= Int.MAX_VALUE.toLong()) {
            "Extracted TTC face exceeds supported output size"
        }

        val output = ByteArray(outputCursor.toInt())
        writeUInt32(output, 0, sfntVersion)
        writeUInt16(output, 4, tables.size)
        val searchPower = Integer.highestOneBit(tables.size)
        val entrySelector = Integer.numberOfTrailingZeros(searchPower)
        val searchRange = searchPower * TABLE_RECORD_BYTES
        val rangeShift = tables.size * TABLE_RECORD_BYTES - searchRange
        require(searchRange <= 0xffff && rangeShift <= 0xffff) { "SFNT search fields overflow" }
        writeUInt16(output, 6, searchRange)
        writeUInt16(output, 8, entrySelector)
        writeUInt16(output, 10, rangeShift)

        var outputHeadOffset = -1
        for ((index, placement) in placements.withIndex()) {
            val table = placement.table
            val outputOffset = placement.outputOffset
            copyRange(source, table.sourceOffset, output, outputOffset, table.length)
            if (table.tag == "head") {
                outputHeadOffset = outputOffset
                writeUInt32(output, outputHeadOffset + HEAD_CHECKSUM_ADJUSTMENT_OFFSET, 0L)
            }
            val tableChecksum = checksum(output, outputOffset, table.length)
            val recordOffset = SFNT_HEADER_BYTES + index * TABLE_RECORD_BYTES
            writeTag(output, recordOffset, table.tag)
            writeUInt32(output, recordOffset + 4, tableChecksum)
            writeUInt32(output, recordOffset + 8, outputOffset.toLong())
            writeUInt32(output, recordOffset + 12, table.length.toLong())
        }
        check(outputHeadOffset >= 0)

        val wholeFontChecksum = checksum(output, 0, output.size)
        val adjustment = (CHECKSUM_MAGIC - wholeFontChecksum) and UINT32_MAX
        writeUInt32(output, outputHeadOffset + HEAD_CHECKSUM_ADJUSTMENT_OFFSET, adjustment)
        check(checksum(output, 0, output.size) == CHECKSUM_MAGIC) {
            "Could not recalculate standalone font checksum"
        }
        return output
    }

    private fun readTag(bytes: ByteBuffer, offset: Int): String {
        requireRange(bytes, offset.toLong(), MAX_TABLE_TAG.toLong(), "table tag")
        val tag = CharArray(MAX_TABLE_TAG) { index ->
            val value = bytes.get(offset + index).toInt() and 0xff
            require(value in 0x20..0x7e) { "Invalid non-printable SFNT table tag" }
            value.toChar()
        }
        return String(tag)
    }

    private fun writeTag(bytes: ByteArray, offset: Int, tag: String) {
        require(tag.length == MAX_TABLE_TAG)
        val encoded = tag.toByteArray(Charsets.US_ASCII)
        require(encoded.size == MAX_TABLE_TAG)
        System.arraycopy(encoded, 0, bytes, offset, MAX_TABLE_TAG)
    }

    private fun readUInt16(bytes: ByteBuffer, offset: Int): Int {
        requireRange(bytes, offset.toLong(), 2L, "uint16")
        return ((bytes.get(offset).toInt() and 0xff) shl 8) or
            (bytes.get(offset + 1).toInt() and 0xff)
    }

    private fun readUInt32(bytes: ByteBuffer, offset: Int): Long {
        requireRange(bytes, offset.toLong(), 4L, "uint32")
        return ((bytes.get(offset).toLong() and 0xffL) shl 24) or
            ((bytes.get(offset + 1).toLong() and 0xffL) shl 16) or
            ((bytes.get(offset + 2).toLong() and 0xffL) shl 8) or
            (bytes.get(offset + 3).toLong() and 0xffL)
    }

    private fun writeUInt16(bytes: ByteArray, offset: Int, value: Int) {
        require(value in 0..0xffff)
        requireRange(bytes, offset.toLong(), 2L, "uint16 destination")
        bytes[offset] = (value ushr 8).toByte()
        bytes[offset + 1] = value.toByte()
    }

    private fun writeUInt32(bytes: ByteArray, offset: Int, value: Long) {
        require(value in 0L..UINT32_MAX) { "Value does not fit uint32" }
        requireRange(bytes, offset.toLong(), 4L, "uint32 destination")
        bytes[offset] = (value ushr 24).toByte()
        bytes[offset + 1] = (value ushr 16).toByte()
        bytes[offset + 2] = (value ushr 8).toByte()
        bytes[offset + 3] = value.toByte()
    }

    private fun checksum(bytes: ByteArray, offset: Int, length: Int): Long {
        requireRange(bytes, offset.toLong(), length.toLong(), "checksum range")
        var sum = 0L
        var relative = 0
        while (relative < length) {
            var word = 0L
            for (byteIndex in 0 until 4) {
                val sourceIndex = relative + byteIndex
                if (sourceIndex < length) {
                    word = word or ((bytes[offset + sourceIndex].toLong() and 0xffL) shl (24 - byteIndex * 8))
                }
            }
            sum = (sum + word) and UINT32_MAX
            relative += 4
        }
        return sum
    }

    private fun copyBuffer(source: ByteBuffer): ByteArray {
        val copy = ByteArray(source.remaining())
        source.get(copy)
        return copy
    }

    private fun copyRange(source: ByteBuffer, sourceOffset: Int, target: ByteArray, targetOffset: Int, length: Int) {
        val copy = source.duplicate()
        copy.position(sourceOffset)
        copy.limit(sourceOffset + length)
        copy.get(target, targetOffset, length)
    }

    private fun checkedEnd(start: Long, length: Long, limit: Long, description: String): Long {
        require(start >= 0L && length >= 0L) { "Negative $description range" }
        require(start <= Long.MAX_VALUE - length) { "$description range overflows" }
        val end = start + length
        require(end <= limit) { "$description range is outside the input" }
        return end
    }

    private fun checkedAdd(left: Long, right: Long, description: String): Long {
        require(left >= 0L && right >= 0L && left <= Long.MAX_VALUE - right) {
            "$description overflows"
        }
        return left + right
    }

    private fun align4(value: Long): Long {
        require(value >= 0L && value <= Long.MAX_VALUE - 3L) { "Alignment overflows" }
        return (value + 3L) and -4L
    }

    private fun requireRange(bytes: ByteBuffer, offset: Long, length: Long, description: String) {
        checkedEnd(offset, length, bytes.limit().toLong(), description)
    }

    private fun requireRange(bytes: ByteArray, offset: Long, length: Long, description: String) {
        checkedEnd(offset, length, bytes.size.toLong(), description)
    }

    private data class Range(val start: Long, val endExclusive: Long) {
        fun overlaps(other: Range): Boolean = start < other.endExclusive && other.start < endExclusive
    }

    private data class FontDirectory(
        val offset: Int,
        val tableCount: Int,
        val endExclusive: Long,
    ) {
        val range: Range get() = Range(offset.toLong(), endExclusive)
    }

    private data class FontTable(val tag: String, val sourceOffset: Int, val length: Int)

    private data class TablePlacement(val table: FontTable, val outputOffset: Int)
}
