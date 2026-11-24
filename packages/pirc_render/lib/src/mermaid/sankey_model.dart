/// Immutable input graph for Mermaid 11.17.2's Sankey diagram.
class NativeSankeyNode {
  const NativeSankeyNode({required this.id, required this.index});

  final String id;
  final int index;
}

class NativeSankeyFlow {
  const NativeSankeyFlow({
    required this.sourceId,
    required this.targetId,
    required this.value,
    required this.index,
  });

  final String sourceId;
  final String targetId;
  final double value;
  final int index;
}

class NativeSankeyDiagram {
  NativeSankeyDiagram({
    required Iterable<NativeSankeyNode> nodes,
    required Iterable<NativeSankeyFlow> flows,
  }) : nodes = List.unmodifiable(nodes),
       flows = List.unmodifiable(flows);

  final List<NativeSankeyNode> nodes;
  final List<NativeSankeyFlow> flows;
}
