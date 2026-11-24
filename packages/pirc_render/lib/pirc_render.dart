/// Native chat content rendering (tiers 1 and 2 in plans/client.md).
///
/// The engine moves here from `apps/android/lib/rendering` in M5 step 2.
library;

/// Support levels of rendered content (plans/client.md, Rendering).
enum RenderTier {
  /// Markdown, code, tables, images, math, forms: regressions are bugs.
  mainline,

  /// Mermaid, static HTML layout, SVG as image: kept, not expanded.
  maintain,

  /// Script runtime and DOM APIs: safety, crash and isolation fixes only.
  frozen,
}
