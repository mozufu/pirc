/// Native chat content rendering (tiers 1 and 2 in plans/client.md):
/// Markdown, code blocks, math, tables, images, static HTML with forms, and
/// Mermaid diagrams. Fetched documents and the script runtime (tier 3) are
/// not part of this library.
///
/// A host connects the renderer through [RenderHost], [RenderL10n] and a
/// [RenderColors] theme extension.
library;

export 'src/code_block.dart' show NativeCodeBlock;
export 'src/licenses.dart' show registerNativeRendererLicenses;
export 'src/mermaid/native_mermaid.dart' show NativeMermaid;
export 'src/native_html.dart' show NativeHtmlDocument;
export 'src/native_markdown.dart' show NativeMarkdown;
export 'src/native_raster_images.dart' show NativeRasterImages;
export 'src/remote_content_gate.dart'
    show NativeRemoteContentPolicy, NativeRemoteContentGate;
export 'src/render_host.dart';
export 'src/render_l10n.dart'
    show
        CatalogRenderLocalizations,
        RenderL10n,
        RenderLocalizations,
        substituteRenderParameters;
export 'src/render_theme.dart';

/// Support levels of rendered content (plans/client.md, Rendering).
enum RenderTier {
  /// Markdown, code, tables, images, math, forms: regressions are bugs.
  mainline,

  /// Mermaid, static HTML layout, SVG as image: kept, not expanded.
  maintain,

  /// Script runtime and DOM APIs: safety, crash and isolation fixes only.
  frozen,
}
