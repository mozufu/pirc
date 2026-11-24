import 'render_l10n.dart';
import 'dart:async';
import 'code_tabs.dart';
import 'code_lines.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'render_theme.dart';
import 'markdown_selection.dart';

final _highlight = Highlight()..registerLanguages(_nativeWebCommonLanguages());

const _webDiffMetaMatch =
    r'(?:^@@ +-\d+,\d+ +\+\d+,\d+ +@@|^@@ +-\d+ +\+\d+,\d+ +@@|^@@ +-\d+,\d+ +\+\d+ +@@|^@@ +-\d+ +\+\d+ +@@|^\*\*\* +\d+,\d+ +\*\*\*\*$|^--- +\d+,\d+ +----$)';

Map<String, Mode> _nativeWebCommonLanguages() {
  final languages = <String, Mode>{
    for (final entry in builtinAllLanguages.entries)
      if (_webCommonLanguages.contains(entry.key)) entry.key: entry.value,
  };

  final typescript = languages['typescript'];
  if (typescript?.contains case final List<Mode> contains) {
    languages['typescript'] = typescript!.copyWith(
      Mode(
        contains: [
          ...contains,
          Mode(
            scope: 'attr',
            match: r'[A-Za-z_$][0-9A-Za-z_$]*(?=\s*\?:)',
            relevance: 0,
          ),
        ],
      ),
    );
  }

  final diff = languages['diff'];
  if (diff?.contains case final List<Mode> contains) {
    var replacedMeta = false;
    final patchedContains = <Mode>[];
    for (final mode in contains) {
      // The pinned Dart grammar still stores this pre-compilation field.
      // ignore: deprecated_member_use
      if (!replacedMeta && mode.className == 'meta' && mode.match is String) {
        patchedContains.add(mode.copyWith(Mode(match: _webDiffMetaMatch)));
        replacedMeta = true;
      } else {
        patchedContains.add(mode);
      }
    }
    languages['diff'] = diff!.copyWith(Mode(contains: patchedContains));
  }

  final perl = languages['perl'];
  final variable = perl?.refs?['~contains~0'];
  if (perl != null && variable is Mode) {
    final refs = Map<String, dynamic>.from(perl.refs ?? const {});
    refs['~contains~0'] = variable.copyWith(
      Mode(
        scope: 'variable',
        contains: [
          Mode(scope: 'attr', match: r'\s+:\s*\w+(\s*\(.*?\))?', relevance: 0),
        ],
      ),
    );
    languages['perl'] = perl.copyWith(Mode(refs: refs));
  }

  return languages;
}

/// Fenced blocks use highlight.js 11's common grammar set, matching the web.
/// The standalone API below retains the web helper's 200,000-character cap.
const _maxStandaloneHighlightLength = 200000;

const _webCommonLanguages = <String>{
  'xml',
  'bash',
  'c',
  'cpp',
  'csharp',
  'css',
  'markdown',
  'diff',
  'ruby',
  'go',
  'graphql',
  'ini',
  'java',
  'javascript',
  'json',
  'kotlin',
  'less',
  'lua',
  'makefile',
  'perl',
  'objectivec',
  'php',
  'php-template',
  'plaintext',
  'python',
  'python-repl',
  'r',
  'rust',
  'scss',
  'shell',
  'sql',
  'swift',
  'yaml',
  'typescript',
  'vbnet',
  'wasm',
};

const _webCommonLanguageAliases = <String, String>{
  'html': 'xml',
  'xhtml': 'xml',
  'rss': 'xml',
  'atom': 'xml',
  'xjb': 'xml',
  'xsd': 'xml',
  'xsl': 'xml',
  'plist': 'xml',
  'wsf': 'xml',
  'svg': 'xml',
  'sh': 'bash',
  'zsh': 'bash',
  'h': 'c',
  'cc': 'cpp',
  'c++': 'cpp',
  'h++': 'cpp',
  'hpp': 'cpp',
  'hh': 'cpp',
  'hxx': 'cpp',
  'cxx': 'cpp',
  'cs': 'csharp',
  'c#': 'csharp',
  'md': 'markdown',
  'mkdown': 'markdown',
  'mkd': 'markdown',
  'patch': 'diff',
  'rb': 'ruby',
  'gemspec': 'ruby',
  'podspec': 'ruby',
  'thor': 'ruby',
  'irb': 'ruby',
  'golang': 'go',
  'gql': 'graphql',
  'toml': 'ini',
  'jsp': 'java',
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'jsonc': 'json',
  'json5': 'json',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'ktm': 'kotlin',
  'ktx': 'kotlin',
  'pluto': 'lua',
  'mk': 'makefile',
  'mak': 'makefile',
  'make': 'makefile',
  'pl': 'perl',
  'pm': 'perl',
  'mm': 'objectivec',
  'objc': 'objectivec',
  'obj-c': 'objectivec',
  'obj-c++': 'objectivec',
  'objective-c++': 'objectivec',
  'text': 'plaintext',
  'txt': 'plaintext',
  'py': 'python',
  'gyp': 'python',
  'ipython': 'python',
  'pycon': 'python-repl',
  'rs': 'rust',
  'console': 'shell',
  'shellsession': 'shell',
  'yml': 'yaml',
  'ts': 'typescript',
  'tsx': 'typescript',
  'mts': 'typescript',
  'cts': 'typescript',
  'vb': 'vbnet',
};

/// Uses the web's highlight.js scope palette, not a separate native theme.
///
/// highlight.js 11's common languages define the web's supported languages.
/// `re_highlight` bundles additional languages, so we only allow a requested
/// language when its grammar resolves to one of the web's 36 grammars.
TextSpan highlightCode(
  String code,
  String language,
  RenderColors colors, {
  TextStyle? baseStyle,
}) => _highlightCode(
  code,
  language,
  colors,
  baseStyle: baseStyle,
  maxLength: _maxStandaloneHighlightLength,
);

/// Native Markdown fences follow the web renderer, which highlights without the
/// standalone helper's size limit.
TextSpan highlightCodeBlock(
  String code,
  String language,
  RenderColors colors, {
  TextStyle? baseStyle,
}) => _highlightCode(code, language, colors, baseStyle: baseStyle);

TextSpan _highlightCode(
  String code,
  String language,
  RenderColors colors, {
  TextStyle? baseStyle,
  int? maxLength,
}) {
  final base =
      baseStyle ??
      TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        height: 1.6,
        letterSpacing: 0,
        color: colors['code.text'],
      );
  TextSpan plain() => TextSpan(
    style: base,
    children: [TextSpan(text: code)],
  );
  if (maxLength != null && code.length > maxLength) return plain();

  final requestedLanguage = language.trim().toLowerCase();
  final canonicalLanguage = _webCommonLanguages.contains(requestedLanguage)
      ? requestedLanguage
      : _webCommonLanguageAliases[requestedLanguage];
  if (canonicalLanguage == null) return plain();
  if (_highlight.getLanguage(canonicalLanguage) == null) return plain();

  try {
    final renderer = _WebScopeRenderer(base, colors);
    _highlight
        .highlight(
          code: code,
          language: canonicalLanguage,
          ignoreIllegals: true,
        )
        .render(renderer);
    return renderer.span;
  } catch (_) {
    // highlight.js also falls back to escaped plain text for failed grammars.
    return plain();
  }
}

/// Resolves highlight.js scope styles like markdown.css does. Parent scopes
/// contribute inherited font styles; a recognized child scope may replace its
/// parent's color, matching the browser cascade for nested spans.
class _WebScopeRenderer implements HighlightRenderer {
  _WebScopeRenderer(this.base, this.colors);

  final TextStyle base;
  final RenderColors colors;
  final List<String> _scopes = [];
  final List<InlineSpan> _children = [];

  TextSpan get span => TextSpan(style: base, children: _children);

  @override
  void openNode(DataNode node) {
    if (node.scope != null) _scopes.add(node.scope!);
  }

  @override
  void closeNode(DataNode node) {
    if (node.scope != null && _scopes.isNotEmpty) _scopes.removeLast();
  }

  @override
  void addText(String text) {
    if (text.isEmpty) return;
    String? colorGroup;
    var italic = false;
    var bold = false;
    for (final scope in _scopes) {
      final group = _scopeGroup(scope);
      if (group != null) colorGroup = group;
      final classes = scope.replaceAll('.', ' ').split(RegExp(r'\s+'));
      if (classes.contains('comment') ||
          classes.contains('quote') ||
          classes.contains('emphasis')) {
        italic = true;
      }
      if (classes.contains('strong')) bold = true;
    }
    _children.add(
      TextSpan(
        text: text,
        style: TextStyle(
          color: colorGroup == null ? null : colors['web.hl-$colorGroup'],
          fontStyle: italic ? FontStyle.italic : null,
          fontWeight: bold ? FontWeight.w700 : null,
        ),
      ),
    );
  }
}

/// Raw highlight.js scopes become CSS classes in the web renderer: for example
/// `title.function` becomes `hljs-title function_`. Unknown dotted suffixes
/// still inherit the primary selector, just as they do in markdown.css.
String? _scopeGroup(String scope) {
  final pieces = scope.split('.');
  final root = pieces.first;
  final modifiers = pieces.skip(1).toSet();
  switch (root) {
    case 'comment':
    case 'quote':
      return 'comment';
    case 'keyword':
    case 'selector-tag':
    case 'literal':
    case 'doctag':
      return 'keyword';
    case 'string':
    case 'regexp':
    case 'addition':
      return 'string';
    case 'number':
    case 'symbol':
    case 'bullet':
      return 'number';
    case 'variable':
      return modifiers.contains('constant') ? 'number' : 'attr';
    case 'title':
      return modifiers.contains('class') ? 'type' : 'title';
    case 'section':
      return 'title';
    case 'type':
    case 'built_in':
      return 'type';
    case 'attr':
    case 'attribute':
    case 'property':
    case 'template-variable':
    case 'params':
      return 'attr';
    case 'name':
    case 'tag':
    case 'selector-id':
    case 'selector-class':
      return 'tag';
    case 'deletion':
      return 'del';
    case 'meta':
      return 'meta';
    default:
      return null;
  }
}

class NativeCodeBlock extends StatefulWidget {
  const NativeCodeBlock({
    super.key,
    required this.source,
    required this.language,
    this.headerLineHeight = 1.65,
  });
  final String source, language;
  final double headerLineHeight;
  @override
  State<NativeCodeBlock> createState() => _NativeCodeBlockState();
}

class _NativeCodeBlockState extends State<NativeCodeBlock> {
  bool copied = false;
  int sourceGeneration = 0;
  final copyTimers = <Timer>{};
  String? lastSource, lastLanguage;
  RenderColors? lastColors;
  TextSpan? span;
  @override
  void didUpdateWidget(NativeCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.language != widget.language) {
      sourceGeneration++;
      copied = false;
      for (final timer in copyTimers) {
        timer.cancel();
      }
      copyTimers.clear();
    }
  }

  @override
  void dispose() {
    for (final timer in copyTimers) {
      timer.cancel();
    }
    super.dispose();
  }

  Future<void> copySource() async {
    final generation = sourceGeneration;
    await Clipboard.setData(ClipboardData(text: widget.source));
    if (!mounted || generation != sourceGeneration) return;
    setState(() => copied = true);
    late final Timer timer;
    timer = Timer(const Duration(milliseconds: 1400), () {
      copyTimers.remove(timer);
      if (mounted && generation == sourceGeneration) {
        setState(() => copied = false);
      }
    });
    copyTimers.add(timer);
  }

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final colors = Theme.of(context).extension<RenderColors>()!;
    if (lastSource != widget.source ||
        lastLanguage != widget.language ||
        lastColors != colors) {
      lastSource = widget.source;
      lastLanguage = widget.language;
      lastColors = colors;
      span = highlightCodeBlock(widget.source, widget.language, colors);
    }
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final displaySpan = nativeCodeTabStops(
      span!,
      textScaler: textScaler,
      textDirection: textDirection,
      locale: locale,
    );
    final visibleLines = nativeCodeVisibleLines(
      displaySpan,
      textScaler: textScaler,
      textDirection: textDirection,
      locale: locale,
    );
    return NativeSelection(
      child: NativeSelectionGroup(
        separator: '\n',
        child: Container(
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: colors['code.bg'],
            borderRadius: BorderRadius.circular(12),
          ),
          // The web uses an inset shadow: paint the edge without consuming
          // layout space, so header/pre padding starts at the same coordinate.
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors['line.hairline']),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: colors['line.hairline']),
                  ),
                ),
                child: NativeSelectionGroup(
                  separator: '\n',
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.language.isEmpty ? 'text' : widget.language,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: widget.headerLineHeight,
                            fontWeight: FontWeight.w400,
                            letterSpacing: 0,
                            color: colors['code.head'],
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: copySource,
                        style:
                            TextButton.styleFrom(
                              foregroundColor: colors['text.muted'],
                              minimumSize: const Size(0, 36),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 4,
                              ),
                              textStyle: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: widget.headerLineHeight,
                                fontWeight: FontWeight.w400,
                                letterSpacing: 0,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                              splashFactory: NoSplash.splashFactory,
                            ).copyWith(
                              foregroundColor: WidgetStateProperty.resolveWith(
                                (states) =>
                                    colors[states.contains(WidgetState.hovered)
                                        ? 'text.primary'
                                        : 'text.muted'],
                              ),
                              backgroundColor: WidgetStateProperty.resolveWith(
                                (states) => states.contains(WidgetState.hovered)
                                    ? colors['web.bg-hover']
                                    : Colors.transparent,
                              ),
                              overlayColor: WidgetStateProperty.resolveWith(
                                (states) =>
                                    states.contains(WidgetState.hovered) ||
                                        states.contains(WidgetState.pressed)
                                    ? Colors.transparent
                                    : null,
                              ),
                            ),
                        child: Text(copied ? tr("Copied") : tr("Copy")),
                      ),
                    ],
                  ),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: widget.source.isEmpty
                    ? const SizedBox.shrink()
                    : Text.rich(
                        displaySpan,
                        maxLines: visibleLines,
                        overflow: TextOverflow.visible,
                        softWrap: false,
                        // Invisible tab advances must not enlarge line metrics.
                        strutStyle: widget.source.contains('\t')
                            ? StrutStyle.fromTextStyle(
                                span!.style!,
                                forceStrutHeight: true,
                              )
                            : null,
                        textWidthBasis: TextWidthBasis.longestLine,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
