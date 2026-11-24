import '../render_l10n.dart';
// Port of the flat-forest CoSE-Bilkent path from cose-base 1.0.3 and
// layout-base 1.0.2 (MIT; Copyright (c) 2019-present iVis@Bilkent).
//
// The source projects' MIT permission notice:
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// This implements the deterministic, non-incremental, flat-tree path used by
// Mermaid's pinned Cytoscape CoSE-Bilkent 4.1.0 integration. It intentionally
// returns model-space node centers; SVG/viewBox normalization happens later.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

const double _defaultEdgeLength = 50;
const double _defaultSpringStrength = 0.45;
const double _defaultRepulsionStrength = 4500;
const double _defaultGraphMargin = 15;
const double _worldCenterX = 1200;
const double _worldCenterY = 900;
const double _defaultRepulsionRange = 100;
const double _minRepulsionDistance = 5;
const int _maxIterations = 2500;
const int _convergencePeriod = 100;
const double _maxNodeDisplacement = 300;
const int _trigFractionBits = 256;
final BigInt _trigScale = BigInt.one << _trigFractionBits;

/// Returns raw CoSE-Bilkent centers in the same input order as [nodeSizes].
///
/// This ports the pinned default quality=proof flat-tree path: radial
/// initialization, CoSE springs, smart-grid repulsion, cooling and convergence
/// checks. The Cytoscape container size is not an input because the source
/// plugin uses it only for viewport fitting; Mermaid normalizes SVG bounds.
///
/// [edges] are undirected node-index pairs. This native port is bounded to one
/// connected tree, which is the topology emitted by Mermaid's mindmap renderer.
/// Non-tree and disconnected inputs are rejected rather than laid out with a
/// different algorithm.
List<Offset> layoutNativeMindmapCoseBilkent({
  required List<Size> nodeSizes,
  required List<({int source, int target})> edges,
}) {
  if (nodeSizes.isEmpty) {
    throw ArgumentError.value(nodeSizes, 'nodeSizes', tr("must not be empty"));
  }
  for (var i = 0; i < nodeSizes.length; i++) {
    final size = nodeSizes[i];
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      throw ArgumentError.value(
        size,
        'nodeSizes[$i]',
        tr("width and height must be finite and greater than zero"),
      );
    }
  }
  if (edges.length != nodeSizes.length - 1) {
    throw ArgumentError.value(
      edges.length,
      'edges',
      tr("a connected tree with {0} nodes must have {1} edges", [
        nodeSizes.length,
        nodeSizes.length - 1,
      ]),
    );
  }

  final nodes = List<_CoseNode>.generate(
    nodeSizes.length,
    (index) => _CoseNode(index, nodeSizes[index]),
  );
  final coseEdges = <_CoseEdge>[];
  for (var i = 0; i < edges.length; i++) {
    final edge = edges[i];
    if (edge.source < 0 ||
        edge.source >= nodes.length ||
        edge.target < 0 ||
        edge.target >= nodes.length) {
      throw ArgumentError.value(
        edge,
        'edges[$i]',
        tr("node index is out of range"),
      );
    }
    if (edge.source == edge.target ||
        nodes[edge.source].neighbors.contains(edge.target)) {
      throw ArgumentError.value(
        edge,
        'edges[$i]',
        tr("self edges and duplicate edges are not tree edges"),
      );
    }
    nodes[edge.source].neighbors.add(edge.target);
    nodes[edge.target].neighbors.add(edge.source);
    coseEdges.add(_CoseEdge(edge.source, edge.target));
  }

  final bfsOrder = _breadthFirstOrder(nodes);
  if (bfsOrder.length != nodes.length) {
    throw ArgumentError.value(
      edges,
      'edges',
      tr("the input graph must be connected"),
    );
  }

  _radiallyPosition(nodes, bfsOrder);
  _moveRadialTreeToSourceWorld(nodes);
  _runProofQualityForceLayout(nodes, coseEdges);
  _normalize(nodes, _defaultGraphMargin);

  return List<Offset>.unmodifiable(
    nodes.map((node) => Offset(node.centerX, node.centerY)),
  );
}

class _CoseNode {
  _CoseNode(this.index, this.size);

  final int index;
  final Size size;
  final List<int> neighbors = <int>[];
  // layout-base stores rectangles by their top-left and derives centers from
  // those values for every force pass. Preserve that arithmetic to keep the
  // long CoSE simulation aligned with the pinned source.
  double x = 0;
  double y = 0;
  double get centerX => x + size.width / 2;
  double get centerY => y + size.height / 2;
  double springX = 0;
  double springY = 0;
  double repulsionX = 0;
  double repulsionY = 0;
  double gravityX = 0;
  double gravityY = 0;
  double displacementX = 0;
  double displacementY = 0;
  List<int> surrounding = const <int>[];
  int gridStartX = 0;
  int gridFinishX = 0;
  int gridStartY = 0;
  int gridFinishY = 0;

  double get left => x;
  double get right => x + size.width;
  double get top => y;
  double get bottom => y + size.height;
}

class _CoseEdge {
  const _CoseEdge(this.source, this.target);

  final int source;
  final int target;
}

List<int> _breadthFirstOrder(List<_CoseNode> nodes) {
  final order = <int>[0];
  final visited = <int>{0};
  for (var i = 0; i < order.length; i++) {
    for (final neighbor in nodes[order[i]].neighbors) {
      if (visited.add(neighbor)) {
        order.add(neighbor);
      }
    }
  }
  return order;
}

/// Mirrors layout-base 1.0.2's leaf-removal center choice, including its
/// first-node choice when a tree has two centers.
int _findCenterOfTree(List<_CoseNode> nodes, List<int> treeOrder) {
  var remaining = List<int>.from(treeOrder);
  final removed = <int>{};
  final remainingDegrees = <int, int>{};
  final initialLeaves = <int>[];

  if (remaining.length <= 2) {
    return remaining.first;
  }

  for (final node in remaining) {
    final degree = nodes[node].neighbors.length;
    remainingDegrees[node] = degree;
    if (degree == 1) {
      initialLeaves.add(node);
    }
  }

  removed.addAll(initialLeaves);

  while (remaining.length > 2) {
    final nextLeaves = <int>[];
    for (var i = 0; i < remaining.length; i++) {
      final node = remaining[i];
      final index = remaining.indexOf(node);
      if (index >= 0) {
        remaining.removeAt(index);
      }

      for (final neighbor in nodes[node].neighbors) {
        if (!removed.contains(neighbor)) {
          final degree = remainingDegrees[neighbor]! - 1;
          remainingDegrees[neighbor] = degree;
          if (degree == 1) {
            nextLeaves.add(neighbor);
          }
        }
      }
    }

    removed.addAll(nextLeaves);
    if (remaining.length <= 2) {
      break;
    }
  }
  return remaining.first;
}

void _radiallyPosition(List<_CoseNode> nodes, List<int> treeOrder) {
  var radialSeparation = _defaultEdgeLength;
  for (final node in nodes) {
    final diagonal = math.sqrt(
      node.size.width * node.size.width + node.size.height * node.size.height,
    );
    radialSeparation = math.max(radialSeparation, diagonal).toDouble();
  }

  final center = _findCenterOfTree(nodes, treeOrder);
  _branchRadial(nodes, center, null, 0, 359, 0, radialSeparation);
}

void _branchRadial(
  List<_CoseNode> nodes,
  int nodeIndex,
  int? parent,
  double startAngle,
  double endAngle,
  double distance,
  double radialSeparation,
) {
  var halfInterval = (endAngle - startAngle + 1) / 2;
  if (halfInterval < 0) {
    halfInterval += 180;
  }
  final nodeAngle = (halfInterval + startAngle) % 360;
  final theta = nodeAngle * (math.pi * 2) / 360;
  final (cosTheta, sinTheta) = _sourceSinCos(theta);
  final node = nodes[nodeIndex];
  // CoSENode.setCenter() writes the top-left rectangle location, then all
  // later center reads add the half-size back.
  node.x = distance * cosTheta - node.size.width / 2;
  node.y = distance * sinTheta - node.size.height / 2;

  final neighborEdges = List<int>.from(node.neighbors);
  var childCount = neighborEdges.length;
  if (parent != null) {
    childCount--;
  }
  if (childCount <= 0) {
    return;
  }

  var startIndex = 0;
  if (parent != null) {
    final parentIndex = neighborEdges.indexOf(parent);
    if (parentIndex < 0) {
      throw StateError(tr("CoSE radial traversal lost its parent edge"));
    }
    startIndex = (parentIndex + 1) % neighborEdges.length;
  }

  final stepAngle = (endAngle - startAngle).abs() / childCount;
  var branchCount = 0;
  var i = startIndex;
  while (branchCount != childCount) {
    final neighbor = neighborEdges[i];
    if (neighbor != parent) {
      final childStart = (startAngle + branchCount * stepAngle) % 360;
      final childEnd = (childStart + stepAngle) % 360;
      _branchRadial(
        nodes,
        neighbor,
        nodeIndex,
        childStart,
        childEnd,
        distance + radialSeparation,
        radialSeparation,
      );
      branchCount++;
    }
    i = (i + 1) % neighborEdges.length;
  }
}

/// Mirrors CoSELayout.radialLayout() and positionNodesRadially() world
/// transforms before the force loop. Translating to the origin before forces
/// is mathematically equivalent but changes floating-point rounding in this
/// iterative simulation.
void _moveRadialTreeToSourceWorld(List<_CoseNode> nodes) {
  var minLeft = double.infinity;
  var minTop = double.infinity;
  var maxRight = -double.infinity;
  var maxBottom = -double.infinity;
  for (final node in nodes) {
    minLeft = math.min(minLeft, node.left);
    minTop = math.min(minTop, node.top);
    maxRight = math.max(maxRight, node.right);
    maxBottom = math.max(maxBottom, node.bottom);
  }

  // Keep the source's two separate Transform.inverseTransformPoint passes.
  // Collapsing these into one algebraic translation changes the last few bits
  // of some initial rectangles, which compounds over the long force loop.
  for (final node in nodes) {
    node.x = 0 + ((node.x - minLeft) * 1 / 1);
    node.y = 0 + ((node.y - minTop) * 1 / 1);
  }

  final pointX = 0 + ((maxRight - minLeft) * 1 / 1);
  final pointY = 0 + ((maxBottom - minTop) * 1 / 1);
  final worldOriginX = _worldCenterX - pointX / 2;
  final worldOriginY = _worldCenterY - pointY / 2;
  var graphLeft = double.infinity;
  var graphTop = double.infinity;
  for (final node in nodes) {
    graphLeft = math.min(graphLeft, node.left);
    graphTop = math.min(graphTop, node.top);
  }
  graphLeft -= _defaultGraphMargin;
  graphTop -= _defaultGraphMargin;
  for (final node in nodes) {
    // Layout.transform() obtains the graph origin from updateLeftTop(), then
    // inverseTransformPoint evaluates worldOrg + ((rect - deviceOrg) * 1 / 1).
    node.x = worldOriginX + ((node.x - graphLeft) * 1 / 1);
    node.y = worldOriginY + ((node.y - graphTop) * 1 / 1);
  }
}

void _normalize(List<_CoseNode> nodes, double margin) {
  var minLeft = double.infinity;
  var minTop = double.infinity;
  for (final node in nodes) {
    minLeft = math.min(minLeft, node.left);
    minTop = math.min(minTop, node.top);
  }

  final dx = margin - minLeft;
  final dy = margin - minTop;
  for (final node in nodes) {
    node.x += dx;
    node.y += dy;
  }
}

void _runProofQualityForceLayout(List<_CoseNode> nodes, List<_CoseEdge> edges) {
  final maxIterations = math.max(nodes.length * 5, _maxIterations).toInt();
  final initialCooling = nodes.length > 1000
      ? math
            .max(0.33, 1 - (nodes.length - 1000) / (5000 - 1000) * (1 - 0.33))
            .toDouble()
      : 1.0;
  var cooling = initialCooling;
  var oldTotalDisplacement = 0.0;
  var totalDisplacement = 0.0;
  var coolingCycle = 0;
  const coolingAdjuster = 1.0;
  const maxCoolingCycle = _maxIterations / _convergencePeriod;
  const finalTemperature = _convergencePeriod / _maxIterations;
  final displacementThreshold = 1.5 * nodes.length;
  List<List<List<int>>>? grid;
  var gridWidth = 0;
  var gridHeight = 0;

  for (var iteration = 1; iteration <= maxIterations; iteration++) {
    // CoSELayout.tick() exits before doing any work at maxIterations.
    if (iteration == maxIterations) {
      break;
    }

    if (iteration % _convergencePeriod == 0) {
      var oscillating = false;
      if (iteration > maxIterations / 3) {
        oscillating = (totalDisplacement - oldTotalDisplacement).abs() < 2;
      }
      final converged =
          totalDisplacement < displacementThreshold || oscillating;
      oldTotalDisplacement = totalDisplacement;
      if (converged) {
        break;
      }

      coolingCycle++;
      // The proof preset leaves coolingAdjuster at 1.
      cooling = math
          .max(
            initialCooling -
                math
                        .pow(
                          coolingCycle,
                          math.log(100 * (initialCooling - finalTemperature)) /
                              math.log(maxCoolingCycle),
                        )
                        .toDouble() /
                    100 *
                    coolingAdjuster,
            finalTemperature,
          )
          .toDouble();
    }

    totalDisplacement = 0;
    final refreshGrid = iteration % 10 == 1;
    if (refreshGrid) {
      final built = _buildGrid(nodes);
      grid = built.$1;
      gridWidth = built.$2;
      gridHeight = built.$3;
    }

    for (final edge in edges) {
      _applySpring(nodes, edge);
    }

    final processed = <int>{};
    for (var nodeIndex = 0; nodeIndex < nodes.length; nodeIndex++) {
      final node = nodes[nodeIndex];
      if (refreshGrid) {
        node.surrounding = _findSurrounding(
          nodes,
          node,
          nodeIndex,
          processed,
          grid!,
          gridWidth,
          gridHeight,
        );
      }
      for (final surroundingIndex in node.surrounding) {
        _applyRepulsion(nodes, nodeIndex, surroundingIndex);
      }
      processed.add(nodeIndex);
    }

    for (final node in nodes) {
      node.displacementX =
          cooling * (node.springX + node.repulsionX + node.gravityX);
      node.displacementY =
          cooling * (node.springY + node.repulsionY + node.gravityY);

      final maxMove = cooling * _maxNodeDisplacement;
      if (node.displacementX.abs() > maxMove) {
        node.displacementX = maxMove * _sign(node.displacementX);
      }
      if (node.displacementY.abs() > maxMove) {
        node.displacementY = maxMove * _sign(node.displacementY);
      }

      node.x += node.displacementX;
      node.y += node.displacementY;
      totalDisplacement += node.displacementX.abs() + node.displacementY.abs();

      node.springX = 0;
      node.springY = 0;
      node.repulsionX = 0;
      node.repulsionY = 0;
      node.gravityX = 0;
      node.gravityY = 0;
      node.displacementX = 0;
      node.displacementY = 0;
    }
  }
}

(List<List<List<int>>>, int, int) _buildGrid(List<_CoseNode> nodes) {
  const range = _defaultRepulsionRange;
  var left = double.infinity;
  var right = -double.infinity;
  var top = double.infinity;
  var bottom = -double.infinity;
  for (final node in nodes) {
    left = math.min(left, node.left);
    right = math.max(right, node.right);
    top = math.min(top, node.top);
    bottom = math.max(bottom, node.bottom);
  }
  left -= _defaultGraphMargin;
  right += _defaultGraphMargin;
  top -= _defaultGraphMargin;
  bottom += _defaultGraphMargin;

  final width = math.max(1, ((right - left) / range).ceil()).toInt();
  final height = math.max(1, ((bottom - top) / range).ceil()).toInt();
  final cells = List<List<List<int>>>.generate(
    width,
    (_) => List<List<int>>.generate(height, (_) => <int>[]),
  );

  for (final node in nodes) {
    node.gridStartX = ((node.left - left) / range).floor();
    node.gridFinishX = ((node.right - left) / range).floor();
    node.gridStartY = ((node.top - top) / range).floor();
    node.gridFinishY = ((node.bottom - top) / range).floor();
    for (var x = node.gridStartX; x <= node.gridFinishX; x++) {
      for (var y = node.gridStartY; y <= node.gridFinishY; y++) {
        // The source graph margin keeps node cell coordinates in range.
        if (x >= 0 && y >= 0 && x < width && y < height) {
          cells[x][y].add(node.index);
        }
      }
    }
  }

  return (cells, width, height);
}

List<int> _findSurrounding(
  List<_CoseNode> nodes,
  _CoseNode node,
  int nodeIndex,
  Set<int> processed,
  List<List<List<int>>> grid,
  int gridWidth,
  int gridHeight,
) {
  const range = _defaultRepulsionRange;
  final surrounding = <int>{};
  for (var x = node.gridStartX - 1; x < node.gridFinishX + 2; x++) {
    for (var y = node.gridStartY - 1; y < node.gridFinishY + 2; y++) {
      if (x < 0 || y < 0 || x >= gridWidth || y >= gridHeight) {
        continue;
      }
      for (final otherIndex in grid[x][y]) {
        if (otherIndex == nodeIndex || processed.contains(otherIndex)) {
          continue;
        }
        final other = nodes[otherIndex];
        final distanceX =
            (node.centerX - other.centerX).abs() -
            node.size.width / 2 -
            other.size.width / 2;
        final distanceY =
            (node.centerY - other.centerY).abs() -
            node.size.height / 2 -
            other.size.height / 2;
        if (distanceX <= range && distanceY <= range) {
          surrounding.add(otherIndex);
        }
      }
    }
  }
  return surrounding.toList(growable: false);
}

void _applySpring(List<_CoseNode> nodes, _CoseEdge edge) {
  final source = nodes[edge.source];
  final target = nodes[edge.target];
  if (_intersects(source, target)) {
    return;
  }

  // LEdge.updateLength() calls getIntersection(target, source), then
  // subtracts the two returned clip points in that order.
  final clips = _clipPair(target, source);
  var lengthX = clips.$1.dx - clips.$2.dx;
  var lengthY = clips.$1.dy - clips.$2.dy;
  if (lengthX.abs() < 1) {
    lengthX = _sign(lengthX);
  }
  if (lengthY.abs() < 1) {
    lengthY = _sign(lengthY);
  }
  final length = math.sqrt(lengthX * lengthX + lengthY * lengthY);
  if (length == 0) {
    return;
  }

  final spring = _defaultSpringStrength * (length - _defaultEdgeLength);
  final springX = spring * (lengthX / length);
  final springY = spring * (lengthY / length);
  source.springX += springX;
  source.springY += springY;
  target.springX -= springX;
  target.springY -= springY;
}

void _applyRepulsion(List<_CoseNode> nodes, int aIndex, int bIndex) {
  final a = nodes[aIndex];
  final b = nodes[bIndex];
  if (_intersects(a, b)) {
    final overlapX = math.min(a.right, b.right) - math.max(a.left, b.left);
    final overlapY = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
    var adjustedX = overlapX;
    var adjustedY = overlapY;

    if (a.left <= b.left && a.right >= b.right) {
      adjustedX += math.min(b.left - a.left, a.right - b.right);
    } else if (b.left <= a.left && b.right >= a.right) {
      adjustedX += math.min(a.left - b.left, b.right - a.right);
    }

    if (a.top <= b.top && a.bottom >= b.bottom) {
      adjustedY += math.min(b.top - a.top, a.bottom - b.bottom);
    } else if (b.top <= a.top && b.bottom >= a.bottom) {
      adjustedY += math.min(a.top - b.top, b.bottom - a.bottom);
    }

    var slope = ((b.centerY - a.centerY) / (b.centerX - a.centerX)).abs();
    if (a.centerY == b.centerY && a.centerX == b.centerX) {
      slope = 1;
    }
    var moveByY = slope * adjustedX;
    var moveByX = adjustedY / slope;
    if (adjustedX < moveByX) {
      moveByX = adjustedX;
    } else {
      moveByY = adjustedY;
    }

    final directionX = a.centerX < b.centerX ? -1.0 : 1.0;
    final directionY = a.centerY < b.centerY ? -1.0 : 1.0;
    final repulsionX = -directionX * (moveByX / 2 + _defaultEdgeLength / 2);
    final repulsionY = -directionY * (moveByY / 2 + _defaultEdgeLength / 2);
    const childrenConstant = 0.5;
    a.repulsionX -= childrenConstant * 2 * repulsionX;
    a.repulsionY -= childrenConstant * 2 * repulsionY;
    b.repulsionX += childrenConstant * 2 * repulsionX;
    b.repulsionY += childrenConstant * 2 * repulsionY;
    return;
  }

  final clips = _clipPair(a, b);
  var distanceX = clips.$2.dx - clips.$1.dx;
  var distanceY = clips.$2.dy - clips.$1.dy;
  if (distanceX.abs() < _minRepulsionDistance) {
    distanceX = _sign(distanceX) * _minRepulsionDistance;
  }
  if (distanceY.abs() < _minRepulsionDistance) {
    distanceY = _sign(distanceY) * _minRepulsionDistance;
  }
  final distanceSquared = distanceX * distanceX + distanceY * distanceY;
  final distance = math.sqrt(distanceSquared);
  if (distance == 0) {
    return;
  }
  final force = _defaultRepulsionStrength / distanceSquared;
  final forceX = force * distanceX / distance;
  final forceY = force * distanceY / distance;

  a.repulsionX -= forceX;
  a.repulsionY -= forceY;
  b.repulsionX += forceX;
  b.repulsionY += forceY;
}

bool _intersects(_CoseNode a, _CoseNode b) {
  return !(a.right < b.left ||
      a.bottom < b.top ||
      b.right < a.left ||
      b.bottom < a.top);
}

/// Returns rectangle boundary points on the line between node centers.
(Offset, Offset) _clipPair(_CoseNode a, _CoseNode b) {
  // Port of layout-base 1.0.2 IGeometry.getIntersection2. Keep its branch and
  // arithmetic order: the force simulation is sensitive to boundary rounding
  // over many iterations.
  final p1x = a.centerX;
  final p1y = a.centerY;
  final p2x = b.centerX;
  final p2y = b.centerY;
  if (_intersects(a, b)) {
    return (Offset(p1x, p1y), Offset(p2x, p2y));
  }

  final topLeftAx = a.left;
  final topLeftAy = a.top;
  final topRightAx = a.right;
  final bottomLeftAy = a.bottom;
  final halfWidthA = a.size.width / 2;
  final halfHeightA = a.size.height / 2;
  final topLeftBx = b.left;
  final topLeftBy = b.top;
  final topRightBx = b.right;
  final bottomLeftBy = b.bottom;
  final halfWidthB = b.size.width / 2;
  final halfHeightB = b.size.height / 2;

  if (p1x == p2x) {
    if (p1y > p2y) {
      return (Offset(p1x, topLeftAy), Offset(p2x, bottomLeftBy));
    }
    if (p1y < p2y) {
      return (Offset(p1x, bottomLeftAy), Offset(p2x, topLeftBy));
    }
  } else if (p1y == p2y) {
    if (p1x > p2x) {
      return (Offset(topLeftAx, p1y), Offset(topRightBx, p2y));
    }
    if (p1x < p2x) {
      return (Offset(topRightAx, p1y), Offset(topLeftBx, p2y));
    }
  } else {
    final slopeA = a.size.height / a.size.width;
    final slopeB = b.size.height / b.size.width;
    final slopePrime = (p2y - p1y) / (p2x - p1x);
    Offset? clipPointA;
    Offset? clipPointB;

    if (-slopeA == slopePrime) {
      clipPointA = p1x > p2x
          ? Offset(a.left, a.bottom)
          : Offset(topRightAx, topLeftAy);
    } else if (slopeA == slopePrime) {
      clipPointA = p1x > p2x
          ? Offset(topLeftAx, topLeftAy)
          : Offset(topRightAx, bottomLeftAy);
    }

    if (-slopeB == slopePrime) {
      clipPointB = p2x > p1x
          ? Offset(b.left, bottomLeftBy)
          : Offset(topRightBx, topLeftBy);
    } else if (slopeB == slopePrime) {
      clipPointB = p2x > p1x
          ? Offset(topLeftBx, topLeftBy)
          : Offset(topRightBx, b.bottom);
    }

    if (p1x > p2x) {
      if (p1y > p2y) {
        final cardinalA = _cardinalDirection(slopeA, slopePrime, 4);
        final cardinalB = _cardinalDirection(slopeB, slopePrime, 2);
        clipPointA ??= _clipOnCardinal(
          cardinalA,
          centerX: p1x,
          centerY: p1y,
          left: a.left,
          top: a.top,
          right: a.right,
          bottom: a.bottom,
          halfWidth: halfWidthA,
          halfHeight: halfHeightA,
          slope: slopePrime,
        );
        clipPointB ??= _clipOnCardinal(
          cardinalB,
          centerX: p2x,
          centerY: p2y,
          left: b.left,
          top: b.top,
          right: b.right,
          bottom: b.bottom,
          halfWidth: halfWidthB,
          halfHeight: halfHeightB,
          slope: slopePrime,
        );
      } else {
        final cardinalA = _cardinalDirection(-slopeA, slopePrime, 3);
        final cardinalB = _cardinalDirection(-slopeB, slopePrime, 1);
        clipPointA ??= _clipOnCardinal(
          cardinalA,
          centerX: p1x,
          centerY: p1y,
          left: a.left,
          top: a.top,
          right: a.right,
          bottom: a.bottom,
          halfWidth: halfWidthA,
          halfHeight: halfHeightA,
          slope: slopePrime,
        );
        clipPointB ??= _clipOnCardinal(
          cardinalB,
          centerX: p2x,
          centerY: p2y,
          left: b.left,
          top: b.top,
          right: b.right,
          bottom: b.bottom,
          halfWidth: halfWidthB,
          halfHeight: halfHeightB,
          slope: slopePrime,
        );
      }
    } else if (p1y > p2y) {
      final cardinalA = _cardinalDirection(-slopeA, slopePrime, 1);
      final cardinalB = _cardinalDirection(-slopeB, slopePrime, 3);
      clipPointA ??= _clipOnCardinal(
        cardinalA,
        centerX: p1x,
        centerY: p1y,
        left: a.left,
        top: a.top,
        right: a.right,
        bottom: a.bottom,
        halfWidth: halfWidthA,
        halfHeight: halfHeightA,
        slope: slopePrime,
      );
      clipPointB ??= _clipOnCardinal(
        cardinalB,
        centerX: p2x,
        centerY: p2y,
        left: b.left,
        top: b.top,
        right: b.right,
        bottom: b.bottom,
        halfWidth: halfWidthB,
        halfHeight: halfHeightB,
        slope: slopePrime,
      );
    } else {
      final cardinalA = _cardinalDirection(slopeA, slopePrime, 2);
      final cardinalB = _cardinalDirection(slopeB, slopePrime, 4);
      clipPointA ??= _clipOnCardinal(
        cardinalA,
        centerX: p1x,
        centerY: p1y,
        left: a.left,
        top: a.top,
        right: a.right,
        bottom: a.bottom,
        halfWidth: halfWidthA,
        halfHeight: halfHeightA,
        slope: slopePrime,
      );
      clipPointB ??= _clipOnCardinal(
        cardinalB,
        centerX: p2x,
        centerY: p2y,
        left: b.left,
        top: b.top,
        right: b.right,
        bottom: b.bottom,
        halfWidth: halfWidthB,
        halfHeight: halfHeightB,
        slope: slopePrime,
      );
    }

    return (clipPointA, clipPointB);
  }

  // Coincident centers are already caught by _intersects above.
  throw StateError(tr("Unable to clip non-overlapping CoSE rectangles"));
}

int _cardinalDirection(double slope, double slopePrime, int line) {
  if (slope > slopePrime) return line;
  return 1 + line % 4;
}

Offset _clipOnCardinal(
  int direction, {
  required double centerX,
  required double centerY,
  required double left,
  required double top,
  required double right,
  required double bottom,
  required double halfWidth,
  required double halfHeight,
  required double slope,
}) {
  switch (direction) {
    case 1:
      return Offset(centerX + (-halfHeight) / slope, top);
    case 2:
      return Offset(right, centerY + halfWidth * slope);
    case 3:
      return Offset(centerX + halfHeight / slope, bottom);
    case 4:
      return Offset(left, centerY + (-halfWidth) * slope);
    default:
      throw StateError(
        tr("Invalid CoSE clipping cardinal direction: {0}", [direction]),
      );
  }
}

double _sign(double value) {
  if (value > 0) return 1;
  if (value < 0) return -1;
  return 0;
}

/// Computes correctly rounded trigonometric values for the radial angles.
///
/// Chrome's Math.sin/cos returned the correctly rounded binary64 values in the
/// pinned source probe, while dart:math differed by one ULP for some of these
/// angles. The force simulation compounds those tiny seed differences across
/// hundreds of iterations, so use a small fixed-point Taylor kernel instead
/// of the host libm. Radial angles are finite and bounded to [0, 2π].
(double, double) _sourceSinCos(double radians) {
  final x = _doubleToFixed(radians);
  final xSquared = _fixedMultiply(x, x);
  var cosineTerm = _trigScale;
  var cosine = cosineTerm;
  var sineTerm = x;
  var sine = sineTerm;

  for (var n = 1; n <= 64; n++) {
    final cosineDenominator = BigInt.from((2 * n - 1) * (2 * n));
    cosineTerm = -_roundDivide(
      cosineTerm * xSquared,
      _trigScale * cosineDenominator,
    );
    cosine += cosineTerm;

    final sineDenominator = BigInt.from((2 * n) * (2 * n + 1));
    sineTerm = -_roundDivide(sineTerm * xSquared, _trigScale * sineDenominator);
    sine += sineTerm;

    if (cosineTerm == BigInt.zero && sineTerm == BigInt.zero) {
      break;
    }
  }

  return (_fixedToDouble(cosine), _fixedToDouble(sine));
}

BigInt _doubleToFixed(double value) {
  if (value == 0) return BigInt.zero;
  final bytes = ByteData(8)..setFloat64(0, value, Endian.big);
  final bits = bytes.getUint64(0, Endian.big);
  final negative = (bits >> 63) != 0;
  final exponentBits = ((bits >> 52) & 0x7ff).toInt();
  final fraction = bits & 0x000fffffffffffff;
  final significand = exponentBits == 0
      ? fraction
      : fraction | 0x0010000000000000;
  final exponent = exponentBits == 0 ? -1074 : exponentBits - 1023 - 52;
  final fixedShift = exponent + _trigFractionBits;
  final magnitude = fixedShift >= 0
      ? BigInt.from(significand) << fixedShift
      : _roundShiftRight(BigInt.from(significand), -fixedShift);
  return negative ? -magnitude : magnitude;
}

BigInt _fixedMultiply(BigInt left, BigInt right) =>
    _roundDivide(left * right, _trigScale);

BigInt _roundDivide(BigInt numerator, BigInt denominator) {
  final negative = numerator.isNegative;
  final magnitude = numerator.abs();
  final quotient = magnitude ~/ denominator;
  final remainder = magnitude.remainder(denominator);
  final twiceRemainder = remainder << 1;
  final increment =
      twiceRemainder > denominator ||
      (twiceRemainder == denominator && quotient.isOdd);
  final rounded = increment ? quotient + BigInt.one : quotient;
  return negative ? -rounded : rounded;
}

BigInt _roundShiftRight(BigInt value, int places) {
  if (places <= 0) return value << -places;
  return _roundDivide(value, BigInt.one << places);
}

double _fixedToDouble(BigInt value) {
  if (value == BigInt.zero) return 0;
  final negative = value.isNegative;
  final magnitude = value.abs();
  var exponent = magnitude.bitLength - 1 - _trigFractionBits;
  final shift = magnitude.bitLength - 53;
  var significand = shift >= 0
      ? _roundShiftRight(magnitude, shift)
      : magnitude << -shift;
  if (significand == (BigInt.one << 53)) {
    significand >>= 1;
    exponent++;
  }

  final exponentBits = exponent + 1023;
  final fraction = significand - (BigInt.one << 52);
  final signBit = negative ? 0x8000000000000000 : 0;
  final bits = signBit | (exponentBits << 52) | fraction.toInt();
  final bytes = ByteData(8)..setUint64(0, bits, Endian.big);
  return bytes.getFloat64(0, Endian.big);
}
