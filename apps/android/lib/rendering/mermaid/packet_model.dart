import '../render_l10n.dart';

/// One authored field in a Mermaid `packet` or `packet-beta` diagram.
///
/// `startBit`, `endBit`, and `bits` are the effective values stored by
/// Mermaid's PacketDB. The declared values retain whether the source used an
/// explicit range, one explicit bit, or a `+count` field.
class NativeMermaidPacketField {
  const NativeMermaidPacketField({
    required this.startBit,
    required this.endBit,
    required this.bits,
    required this.label,
    required this.syntax,
    this.declaredStart,
    this.declaredEnd,
    this.declaredBits,
  });

  final int startBit;
  final int endBit;
  final int bits;
  final String label;
  final NativeMermaidPacketFieldSyntax syntax;
  final int? declaredStart;
  final int? declaredEnd;
  final int? declaredBits;
}

enum NativeMermaidPacketFieldSyntax { explicitBit, explicitRange, count }

/// A row-local segment from Mermaid's PacketDB. A single authored field may
/// produce several segments when it crosses a `bitsPerRow` boundary.
class NativeMermaidPacketSegment {
  const NativeMermaidPacketSegment({
    required this.startBit,
    required this.endBit,
    required this.bits,
    required this.label,
    required this.fieldIndex,
  });

  final int startBit;
  final int endBit;

  /// Preserves the value returned by Mermaid PacketDB, including its
  /// row-splitting bit-count behavior.
  final int bits;
  final String label;
  final int fieldIndex;
}

class NativeMermaidPacketRow {
  NativeMermaidPacketRow(Iterable<NativeMermaidPacketSegment> fields)
    : fields = List.unmodifiable(fields);

  final List<NativeMermaidPacketSegment> fields;
}

/// Geometry defaults from Mermaid 11.17.2's packet config.
class NativeMermaidPacketConfig {
  const NativeMermaidPacketConfig({
    this.rowHeight = 32,
    this.bitWidth = 32,
    this.bitsPerRow = 32,
    this.showBits = true,
    this.paddingX = 5,
    this.paddingY = 5,
    this.useMaxWidth = true,
    this.labelFontSize = 12,
    this.bitFontSize = 10,
    this.titleFontSize = 14,
  });

  final double rowHeight;
  final double bitWidth;
  final int bitsPerRow;
  final bool showBits;
  final double paddingX;

  /// Configured base padding. Mermaid PacketDB adds ten pixels when
  /// [showBits] is enabled.
  final double paddingY;
  final bool useMaxWidth;
  final double labelFontSize;
  final double bitFontSize;
  final double titleFontSize;

  /// Padding returned by Mermaid PacketDB and used for rendering.
  double get effectivePaddingY => paddingY + (showBits ? 10 : 0);
}

class NativeMermaidPacketDiagram {
  NativeMermaidPacketDiagram({
    required Iterable<NativeMermaidPacketField> fields,
    required Iterable<NativeMermaidPacketRow> rows,
    this.title = '',
    this.accessibleTitle = '',
    this.accessibleDescription = '',
    this.config = const NativeMermaidPacketConfig(),
  }) : fields = List.unmodifiable(fields),
       rows = List.unmodifiable(rows);

  final List<NativeMermaidPacketField> fields;
  final List<NativeMermaidPacketRow> rows;
  final String title;
  final String accessibleTitle;
  final String accessibleDescription;
  final NativeMermaidPacketConfig config;

  String get semanticsLabel {
    final parts = <String>[tr("Packet diagram")];
    if (accessibleTitle.isNotEmpty) parts.add(accessibleTitle);
    if (accessibleDescription.isNotEmpty) parts.add(accessibleDescription);
    if (title.isNotEmpty) parts.add(title);
    for (final field in fields) {
      parts.add(
        tr("Bits {0}–{1}: {2}", [field.startBit, field.endBit, field.label]),
      );
    }
    return parts.join('. ');
  }
}
