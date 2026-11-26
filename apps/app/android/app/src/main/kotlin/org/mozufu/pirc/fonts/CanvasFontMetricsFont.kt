package org.mozufu.pirc.fonts

import java.nio.ByteBuffer

/**
 * Builds an opt-in, metrics-only face for supported OpenType CFF and CFF2 fonts.
 *
 * The result keeps the original glyph IDs, cmap, layout tables, and horizontal metrics, but has
 * no outlines. It is suitable only for shaping and measuring horizontal advance width. Drawing,
 * glyph bounds, actualBoundingBox metrics, and outline-dependent metrics must use the original
 * font. Callers should use the original bytes whenever [deriveAdvanceFont] returns null.
 */
object CanvasFontMetricsFont {
    private const val OTTO_TAG = 0x4f54544fL // 'OTTO'
    private const val TRUETYPE_VERSION = 0x00010000L
    private const val CFF_MAXP_VERSION = 0x00005000L
    private const val MAX_FONT_BYTES = 48 * 1024 * 1024
    private const val MAX_TABLES = 4095
    private const val SFNT_HEADER_BYTES = 12
    private const val TABLE_RECORD_BYTES = 16
    private const val HEAD_LENGTH = 54
    private const val HEAD_CHECKSUM_ADJUSTMENT_OFFSET = 8
    private const val HEAD_INDEX_TO_LOC_FORMAT_OFFSET = 50
    private const val HHEA_NUMBER_OF_HMETRICS_OFFSET = 34
    private const val HHEA_MIN_LENGTH = 36
    private const val MAXP_V05_LENGTH = 6
    private const val MAXP_V10_LENGTH = 32
    private const val FVAR_HEADER_LENGTH = 16
    private const val HVAR_HEADER_LENGTH = 20
    private const val CHECKSUM_MAGIC = 0xB1B0AFBAL
    private const val UINT32_MAX = 0xffff_ffffL

    private val unsupportedStaticCffVariationTables = setOf(
        "avar",
        "cvar",
        "fvar",
        "gvar",
        "HVAR",
        "MVAR",
        "VVAR",
    )

    /**
     * Converts a standalone OTTO+CFF font or supported OTTO+CFF2 variable font to a no-outline
     * TrueType-flavored SFNT for horizontal advance shaping.
     *
     * Returns null for a valid but unsupported font, including TrueType and CFF2 faces without
     * supported `fvar`/`HVAR` data. CFF2 conversion rejects `gvar` and `cvar`; existing `avar`,
     * `fvar`, `HVAR`, and every other non-outline table remain byte-identical. Throws for malformed
     * SFNT or metric tables. The outline table is removed and replaced by empty `glyf` and `loca`
     * tables; all other tables are retained except a stale `DSIG` signature.
     */
    fun deriveAdvanceFont(font: ByteArray): ByteArray? {
        require(font.size in SFNT_HEADER_BYTES..MAX_FONT_BYTES) {
            "Font input must be between $SFNT_HEADER_BYTES and $MAX_FONT_BYTES bytes"
        }
        val source = ByteBuffer.wrap(font).asReadOnlyBuffer()
        val sfnt = parseSfnt(source)
        if (sfnt.version != OTTO_TAG) return null

        val byTag = sfnt.tables.associateBy { it.tag }
        val cff1 = byTag["CFF "]
        val cff2 = byTag["CFF2"]
        if ((cff1 == null) == (cff2 == null)) return null
        if ("glyf" in byTag || "loca" in byTag) return null

        val outlineTable = if (cff2 != null) {
            if ("gvar" in byTag || "cvar" in byTag) return null
            val fvar = byTag["fvar"] ?: return null
            val hvar = byTag["HVAR"] ?: return null
            val axisCount = readFvarAxisCount(source, fvar) ?: return null
            if ("avar" in byTag && !hasSupportedAvar(source, byTag.getValue("avar"), axisCount)) return null
            if (!hasSupportedHvar(source, hvar, axisCount)) return null
            cff2
        } else {
            if (sfnt.tables.any { it.tag in unsupportedStaticCffVariationTables }) return null
            cff1!!
        }
        val head = byTag["head"] ?: malformed("CFF font is missing 'head'")
        val hhea = byTag["hhea"] ?: malformed("CFF font is missing 'hhea'")
        val hmtx = byTag["hmtx"] ?: malformed("CFF font is missing 'hmtx'")
        val maxp = byTag["maxp"] ?: malformed("CFF font is missing 'maxp'")
        if ("cmap" !in byTag) malformed("CFF font is missing 'cmap'")

        require(head.length >= HEAD_LENGTH) { "CFF font has a truncated 'head' table" }
        require(hhea.length >= HHEA_MIN_LENGTH) { "CFF font has a truncated 'hhea' table" }
        require(maxp.length >= MAXP_V05_LENGTH) { "CFF font has a truncated 'maxp' table" }
        require(readUInt32(source, maxp.offset) == CFF_MAXP_VERSION) {
            "CFF/CFF2 font must use maxp version 0.5"
        }
        require(outlineTable.length > 0) { "CFF font has an empty '${outlineTable.tag}' table" }

        val glyphCount = readUInt16(source, maxp.offset + 4)
        require(glyphCount > 0) { "CFF font has no glyphs" }
        val horizontalMetricCount = readUInt16(source, hhea.offset + HHEA_NUMBER_OF_HMETRICS_OFFSET)
        require(horizontalMetricCount in 1..glyphCount) {
            "CFF font has an invalid numberOfHMetrics value"
        }
        val minimumHmtxLength = horizontalMetricCount.toLong() * 4L +
            (glyphCount - horizontalMetricCount).toLong() * 2L
        require(hmtx.length.toLong() >= minimumHmtxLength) {
            "CFF font has a truncated 'hmtx' table"
        }

        val outputTables = ArrayList<OutputTable>(sfnt.tables.size + 1)
        var replacementHead: ByteArray? = null
        var replacementMaxp: ByteArray? = null
        for (table in sfnt.tables) {
            when (table.tag) {
                outlineTable.tag -> Unit
                "DSIG" -> Unit
                "head" -> {
                    replacementHead = copyTable(source, table).also {
                        writeUInt32(it, HEAD_CHECKSUM_ADJUSTMENT_OFFSET, 0L)
                        writeUInt16(it, HEAD_INDEX_TO_LOC_FORMAT_OFFSET, 0)
                    }
                    outputTables.add(OutputTable(table.tag, replacementHead.size, bytes = replacementHead))
                }
                "maxp" -> {
                    replacementMaxp = makeTrueTypeMaxp(glyphCount)
                    outputTables.add(OutputTable(table.tag, replacementMaxp.size, bytes = replacementMaxp))
                }
                else -> outputTables.add(OutputTable(table.tag, table.length, sourceOffset = table.offset))
            }
        }
        check(replacementHead != null && replacementMaxp != null)
        outputTables.add(OutputTable("glyf", 0, bytes = ByteArray(0)))
        outputTables.add(OutputTable("loca", (glyphCount + 1) * 2, bytes = ByteArray((glyphCount + 1) * 2)))
        return writeSfnt(TRUETYPE_VERSION, outputTables, source)
    }

    private fun parseSfnt(source: ByteBuffer): ParsedSfnt {
        val version = readUInt32(source, 0)
        val tableCount = readUInt16(source, 4)
        require(tableCount in 1..MAX_TABLES) { "Invalid SFNT table count: $tableCount" }
        val directoryEnd = SFNT_HEADER_BYTES.toLong() + tableCount.toLong() * TABLE_RECORD_BYTES
        require(directoryEnd <= source.limit().toLong()) { "Truncated SFNT table directory" }

        val tables = ArrayList<SfntTable>(tableCount)
        var previousTag: String? = null
        for (index in 0 until tableCount) {
            val recordOffset = SFNT_HEADER_BYTES + index * TABLE_RECORD_BYTES
            val tag = readTag(source, recordOffset)
            val previous = previousTag
            require(previous == null || previous < tag) { "SFNT table tags must be unique and sorted" }
            previousTag = tag

            val offset = readUInt32(source, recordOffset + 8)
            val length = readUInt32(source, recordOffset + 12)
            require(offset % 4L == 0L) { "Unaligned SFNT table offset for '$tag'" }
            require(offset >= directoryEnd) { "SFNT table '$tag' overlaps its directory" }
            val end = checkedEnd(offset, length, source.limit().toLong(), "SFNT table '$tag'")
            tables.add(SfntTable(tag, offset.toInt(), length.toInt(), end))
        }

        for (leftIndex in tables.indices) {
            val left = tables[leftIndex]
            if (left.length == 0) continue
            for (rightIndex in leftIndex + 1 until tables.size) {
                val right = tables[rightIndex]
                if (right.length == 0) continue
                val sameRange = left.offset == right.offset && left.endExclusive == right.endExclusive
                require(sameRange || left.endExclusive <= right.offset || right.endExclusive <= left.offset) {
                    "SFNT table ranges partially overlap"
                }
            }
        }

        return ParsedSfnt(version, tables)
    }

    private fun makeTrueTypeMaxp(glyphCount: Int): ByteArray = ByteArray(MAXP_V10_LENGTH).also { bytes ->
        writeUInt32(bytes, 0, TRUETYPE_VERSION)
        writeUInt16(bytes, 4, glyphCount)
        // The synthesized glyphs have no points, contours, components, or instructions.
        writeUInt16(bytes, 14, 1) // maxZones: no twilight-zone instructions are used.
    }

    private fun readFvarAxisCount(source: ByteBuffer, fvar: SfntTable): Int? {
        require(fvar.length >= FVAR_HEADER_LENGTH) { "CFF2 font has a truncated 'fvar' table" }
        if (readUInt16(source, fvar.offset) != 1 || readUInt16(source, fvar.offset + 2) != 0) {
            return null
        }

        val axesOffset = readUInt16(source, fvar.offset + 4)
        require(readUInt16(source, fvar.offset + 6) == 2) { "Invalid 'fvar' reserved field" }
        val axisCount = readUInt16(source, fvar.offset + 8)
        if (axisCount == 0) return null
        val axisSize = readUInt16(source, fvar.offset + 10)
        val instanceCount = readUInt16(source, fvar.offset + 12)
        val instanceSize = readUInt16(source, fvar.offset + 14)
        require(axisSize == 20) { "Invalid version 1.0 'fvar' axis record size" }
        require(axesOffset >= FVAR_HEADER_LENGTH) { "Invalid 'fvar' axes array offset" }
        val axesEnd = checkedEnd(
            axesOffset.toLong(),
            axisCount.toLong() * axisSize,
            fvar.length.toLong(),
            "'fvar' axes array",
        )
        val minimumInstanceSize = axisCount * 4 + 4
        val extendedInstanceSize = minimumInstanceSize + 2
        if (instanceSize != minimumInstanceSize && instanceSize != extendedInstanceSize) return null
        checkedEnd(
            axesEnd,
            instanceCount.toLong() * instanceSize,
            fvar.length.toLong(),
            "'fvar' instances array",
        )
        return axisCount
    }

    private fun hasSupportedAvar(source: ByteBuffer, avar: SfntTable, axisCount: Int): Boolean {
        require(avar.length >= 8) { "CFF2 font has a truncated 'avar' table" }
        if (readUInt16(source, avar.offset) != 1 || readUInt16(source, avar.offset + 2) != 0) return false
        require(readUInt16(source, avar.offset + 4) == 0) { "Invalid 'avar' reserved field" }
        if (readUInt16(source, avar.offset + 6) != axisCount) return false
        var mapOffset = 8L
        for (axis in 0 until axisCount) {
            checkedEnd(mapOffset, 2L, avar.length.toLong(), "'avar' segment map")
            val mapCount = readUInt16(source, avar.offset + mapOffset.toInt())
            mapOffset += 2L + mapCount.toLong() * 4L
            checkedEnd(mapOffset, 0L, avar.length.toLong(), "'avar' segment map")
        }
        return true
    }

    private fun hasSupportedHvar(source: ByteBuffer, hvar: SfntTable, axisCount: Int): Boolean {
        require(hvar.length >= HVAR_HEADER_LENGTH) { "CFF2 font has a truncated 'HVAR' table" }
        if (readUInt16(source, hvar.offset) != 1 || readUInt16(source, hvar.offset + 2) != 0) return false

        val storeOffset = readUInt32(source, hvar.offset + 4)
        require(storeOffset >= HVAR_HEADER_LENGTH.toLong()) { "Invalid 'HVAR' item variation store offset" }
        checkedEnd(storeOffset, 8L, hvar.length.toLong(), "'HVAR' item variation store header")
        val storeStart = hvar.offset + storeOffset.toInt()
        if (readUInt16(source, storeStart) != 1) return false
        val regionListOffset = readUInt32(source, storeStart + 2)
        val dataCount = readUInt16(source, storeStart + 6)
        val storeHeaderLength = 8L + dataCount.toLong() * 4L
        checkedEnd(storeOffset, storeHeaderLength, hvar.length.toLong(), "'HVAR' item variation store offsets")
        require(regionListOffset >= storeHeaderLength) { "Invalid 'HVAR' variation region list offset" }
        val regionListOffsetInTable = checkedAdd(storeOffset, regionListOffset, "'HVAR' variation region list")
        checkedEnd(regionListOffsetInTable, 4L, hvar.length.toLong(), "'HVAR' variation region list header")
        val regionListStart = hvar.offset + regionListOffsetInTable.toInt()
        val regionAxisCount = readUInt16(source, regionListStart)
        val regionCount = readUInt16(source, regionListStart + 2)
        if (regionAxisCount != axisCount) return false
        val regionListLength = 4L + regionAxisCount.toLong() * regionCount.toLong() * 6L
        checkedEnd(regionListOffsetInTable, regionListLength, hvar.length.toLong(), "'HVAR' variation region list")

        for (index in 0 until dataCount) {
            val dataOffset = readUInt32(source, storeStart + 8 + index * 4)
            require(dataOffset >= storeHeaderLength) { "Invalid 'HVAR' item variation data offset" }
            val dataStartInTable = checkedAdd(storeOffset, dataOffset, "'HVAR' item variation data")
            checkedEnd(dataStartInTable, 6L, hvar.length.toLong(), "'HVAR' item variation data header")
            val dataStart = hvar.offset + dataStartInTable.toInt()
            val itemCount = readUInt16(source, dataStart)
            val shortDeltaCount = readUInt16(source, dataStart + 2)
            val itemRegionCount = readUInt16(source, dataStart + 4)
            require(shortDeltaCount <= itemRegionCount) { "Invalid 'HVAR' short delta count" }
            val dataHeaderLength = 6L + itemRegionCount.toLong() * 2L
            val deltaBytesPerItem = shortDeltaCount.toLong() * 2L + itemRegionCount - shortDeltaCount
            val dataLength = dataHeaderLength + itemCount.toLong() * deltaBytesPerItem
            checkedEnd(dataStartInTable, dataLength, hvar.length.toLong(), "'HVAR' item variation data")
            for (regionIndex in 0 until itemRegionCount) {
                val region = readUInt16(source, dataStart + 6 + regionIndex * 2)
                require(region < regionCount) { "Invalid 'HVAR' region index" }
            }
        }

        for (mappingFieldOffset in listOf(8, 12, 16)) {
            val mappingOffset = readUInt32(source, hvar.offset + mappingFieldOffset)
            if (mappingOffset == 0L) continue
            require(mappingOffset >= HVAR_HEADER_LENGTH.toLong()) { "Invalid 'HVAR' delta-set index mapping offset" }
            checkedEnd(mappingOffset, 4L, hvar.length.toLong(), "'HVAR' delta-set index mapping")
            val mappingStart = hvar.offset + mappingOffset.toInt()
            val format = source.get(mappingStart).toInt() and 0xff
            if (format != 0) return false
            val entryFormat = source.get(mappingStart + 1).toInt() and 0xff
            val mapCount = readUInt16(source, mappingStart + 2)
            val entrySize = ((entryFormat ushr 4) and 0x03) + 1
            val mappingLength = 4L + mapCount.toLong() * entrySize
            checkedEnd(mappingOffset, mappingLength, hvar.length.toLong(), "'HVAR' delta-set index mapping")
        }
        return true
    }

    private fun writeSfnt(
        version: Long,
        unsortedTables: List<OutputTable>,
        source: ByteBuffer,
    ): ByteArray {
        val tables = unsortedTables.sortedBy { it.tag }
        require(tables.size in 1..MAX_TABLES) { "Metrics-only SFNT has too many tables" }
        require(tables.map { it.tag }.distinct().size == tables.size) { "Metrics-only SFNT has duplicate tables" }
        val tableCount = tables.size
        val directoryEnd = SFNT_HEADER_BYTES.toLong() + tableCount.toLong() * TABLE_RECORD_BYTES
        var cursor = align4(directoryEnd)
        val placements = ArrayList<Placement>(tableCount)
        for (table in tables) {
            cursor = align4(cursor)
            val offset = cursor
            cursor = checkedAdd(cursor, table.length.toLong(), "metrics-only SFNT size")
            cursor = align4(cursor)
            require(cursor <= MAX_FONT_BYTES.toLong() && offset <= UINT32_MAX) {
                "Metrics-only SFNT exceeds $MAX_FONT_BYTES bytes"
            }
            placements.add(Placement(table, offset.toInt()))
        }
        require(cursor <= MAX_FONT_BYTES.toLong() && cursor <= Int.MAX_VALUE.toLong()) {
            "Metrics-only SFNT exceeds $MAX_FONT_BYTES bytes"
        }

        val output = ByteArray(cursor.toInt())
        writeUInt32(output, 0, version)
        writeUInt16(output, 4, tableCount)
        val searchPower = Integer.highestOneBit(tableCount)
        val searchRange = searchPower * TABLE_RECORD_BYTES
        val entrySelector = Integer.numberOfTrailingZeros(searchPower)
        val rangeShift = tableCount * TABLE_RECORD_BYTES - searchRange
        require(searchRange <= 0xffff && rangeShift <= 0xffff) { "SFNT search fields overflow" }
        writeUInt16(output, 6, searchRange)
        writeUInt16(output, 8, entrySelector)
        writeUInt16(output, 10, rangeShift)

        var outputHeadOffset = -1
        for ((index, placement) in placements.withIndex()) {
            val table = placement.table
            val bytes = table.bytes
            if (bytes != null) {
                System.arraycopy(bytes, 0, output, placement.offset, bytes.size)
            } else {
                val sourceOffset = table.sourceOffset ?: error("Missing source for '${table.tag}'")
                val duplicate = source.duplicate()
                duplicate.position(sourceOffset)
                duplicate.limit(sourceOffset + table.length)
                duplicate.get(output, placement.offset, table.length)
            }
            if (table.tag == "head") outputHeadOffset = placement.offset
            val checksum = checksum(output, placement.offset, table.length)
            val recordOffset = SFNT_HEADER_BYTES + index * TABLE_RECORD_BYTES
            writeTag(output, recordOffset, table.tag)
            writeUInt32(output, recordOffset + 4, checksum)
            writeUInt32(output, recordOffset + 8, placement.offset.toLong())
            writeUInt32(output, recordOffset + 12, table.length.toLong())
        }
        check(outputHeadOffset >= 0)
        val adjustment = (CHECKSUM_MAGIC - checksum(output, 0, output.size)) and UINT32_MAX
        writeUInt32(output, outputHeadOffset + HEAD_CHECKSUM_ADJUSTMENT_OFFSET, adjustment)
        check(checksum(output, 0, output.size) == CHECKSUM_MAGIC) {
            "Could not calculate metrics-only SFNT checksum"
        }
        return output
    }

    private fun copyTable(source: ByteBuffer, table: SfntTable): ByteArray {
        val result = ByteArray(table.length)
        val duplicate = source.duplicate()
        duplicate.position(table.offset)
        duplicate.limit(table.offset + table.length)
        duplicate.get(result)
        return result
    }

    private fun readTag(source: ByteBuffer, offset: Int): String {
        val chars = CharArray(4) { index ->
            val value = source.get(offset + index).toInt() and 0xff
            require(value in 0x20..0x7e) { "Invalid non-printable SFNT table tag" }
            value.toChar()
        }
        return String(chars)
    }

    private fun writeTag(target: ByteArray, offset: Int, tag: String) {
        val encoded = tag.toByteArray(Charsets.US_ASCII)
        require(encoded.size == 4)
        System.arraycopy(encoded, 0, target, offset, 4)
    }

    private fun readUInt16(source: ByteBuffer, offset: Int): Int {
        requireRange(source, offset.toLong(), 2L, "uint16")
        return ((source.get(offset).toInt() and 0xff) shl 8) or
            (source.get(offset + 1).toInt() and 0xff)
    }

    private fun readUInt32(source: ByteBuffer, offset: Int): Long {
        requireRange(source, offset.toLong(), 4L, "uint32")
        return ((source.get(offset).toLong() and 0xffL) shl 24) or
            ((source.get(offset + 1).toLong() and 0xffL) shl 16) or
            ((source.get(offset + 2).toLong() and 0xffL) shl 8) or
            (source.get(offset + 3).toLong() and 0xffL)
    }

    private fun writeUInt16(target: ByteArray, offset: Int, value: Int) {
        require(value in 0..0xffff)
        target[offset] = (value ushr 8).toByte()
        target[offset + 1] = value.toByte()
    }

    private fun writeUInt32(target: ByteArray, offset: Int, value: Long) {
        require(value in 0L..UINT32_MAX) { "Value does not fit uint32" }
        target[offset] = (value ushr 24).toByte()
        target[offset + 1] = (value ushr 16).toByte()
        target[offset + 2] = (value ushr 8).toByte()
        target[offset + 3] = value.toByte()
    }

    private fun checksum(bytes: ByteArray, offset: Int, length: Int): Long {
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

    private fun checkedEnd(start: Long, length: Long, limit: Long, description: String): Long {
        require(start >= 0L && length >= 0L && start <= Long.MAX_VALUE - length) {
            "$description range overflows"
        }
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

    private fun requireRange(source: ByteBuffer, offset: Long, length: Long, description: String) {
        checkedEnd(offset, length, source.limit().toLong(), description)
    }

    private fun malformed(message: String): Nothing = throw IllegalArgumentException(message)

    private data class ParsedSfnt(val version: Long, val tables: List<SfntTable>)
    private data class SfntTable(val tag: String, val offset: Int, val length: Int, val endExclusive: Long)
    private data class OutputTable(
        val tag: String,
        val length: Int,
        val sourceOffset: Int? = null,
        val bytes: ByteArray? = null,
    )
    private data class Placement(val table: OutputTable, val offset: Int)
}
