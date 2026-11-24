import 'render_l10n.dart';
import 'dart:convert';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:html/parser.dart' as html;

/// Decodes response bytes for the native HTML viewer and extracts document
/// metadata. Scripts are detected but never run.
///
/// For text/html this follows the WHATWG sniffing order supported here: BOM,
/// supported transport charset, a meta declaration in the first 1024 bytes,
/// then Windows-1252. The HTML Standard leaves the fallback implementation
/// defined (typically locale-dependent); Windows-1252 is this module's fixed
/// fallback.
///
/// Other MIME types use BOM, supported transport charset, then UTF-8. This
/// module does not inspect XML declarations or JSON content. Unknown labels
/// are ignored so HTML can continue to its meta scan. Recognized encodings
/// without a decoder here throw UnsupportedError instead of being mistranslated.
class NativeHtmlDocumentContent {
  NativeHtmlDocumentContent._({
    required this.text,
    required this.encoding,
    required this.isHtml,
    required this.title,
    required this.bodyInnerHtml,
    required this.bodyAttributes,
    required this.baseHref,
    required this.baseTarget,
    required this.stylesheetRefs,
    required this.inlineStyles,
    required this.hasScripts,
  });

  factory NativeHtmlDocumentContent.fromBytes(
    Uint8List bytes, {
    required String mimeType,
    String? charset,
  }) {
    final isHtml = _mediaType(mimeType) == 'text/html';
    final bomEncoding = _sniffBom(bytes);
    final headerEncoding = bomEncoding == null
        ? _encodingForLabel(charset)
        : null;

    late final String selectedEncoding;
    if (bomEncoding != null) {
      selectedEncoding = bomEncoding;
    } else if (headerEncoding != null) {
      selectedEncoding = _requireImplemented(headerEncoding);
    } else if (isHtml) {
      final metaEncoding = _sniffHtmlMetaEncoding(bytes);
      if (metaEncoding != null) {
        selectedEncoding = _requireImplemented(metaEncoding);
      } else {
        selectedEncoding = 'windows-1252';
      }
    } else {
      selectedEncoding = 'utf-8';
    }

    final text = _decode(bytes, selectedEncoding);
    if (!isHtml) {
      return NativeHtmlDocumentContent._(
        text: text,
        encoding: selectedEncoding,
        isHtml: false,
        title: null,
        bodyInnerHtml: '',
        bodyAttributes: const <String, String>{},
        baseHref: null,
        baseTarget: null,
        stylesheetRefs: const <String>[],
        inlineStyles: const <String>[],
        hasScripts: false,
      );
    }

    final document = html.parse(text);
    final body = document.body;
    final titleText = document.querySelector('head title')?.text;
    final stylesheetRefs = document
        .querySelectorAll('link[rel][href]')
        .where((element) {
          final relTokens = (element.attributes['rel'] ?? '')
              .toLowerCase()
              .split(RegExp(r'\s+'));
          return relTokens.contains('stylesheet');
        })
        .map((element) => element.attributes['href']!)
        .toList(growable: false);
    final inlineStyles = document
        .querySelectorAll('style')
        .map((element) => element.text)
        .toList(growable: false);

    return NativeHtmlDocumentContent._(
      text: text,
      encoding: selectedEncoding,
      isHtml: true,
      title: titleText,
      bodyInnerHtml: body?.innerHtml ?? '',
      bodyAttributes: Map<String, String>.unmodifiable(
        body?.attributes ?? const <String, String>{},
      ),
      baseHref: document.querySelector('base[href]')?.attributes['href'],
      baseTarget: document.querySelector('base[target]')?.attributes['target'],
      stylesheetRefs: List<String>.unmodifiable(stylesheetRefs),
      inlineStyles: List<String>.unmodifiable(inlineStyles),
      hasScripts: document.querySelector('script') != null,
    );
  }

  /// The complete decoded response text.
  final String text;

  /// The canonical encoding used by this module.
  ///
  /// Implemented values are utf-8, windows-1252, utf-16le, and utf-16be.
  final String encoding;

  final bool isHtml;

  /// Text from the first title element in the document head, if present.
  final String? title;

  /// Serialized contents of the parsed body, excluding the body element.
  final String bodyInnerHtml;

  /// Parsed body attributes, such as class, id, and data-*.
  final Map<String, String> bodyAttributes;

  /// The first base element with an href attribute, if present.
  final String? baseHref;

  /// The first base element with a target attribute, if present.
  final String? baseTarget;

  /// href values from link elements whose rel token list contains stylesheet.
  final List<String> stylesheetRefs;

  /// Text contents of style elements, in document order.
  final List<String> inlineStyles;

  /// Whether the document contains at least one script element.
  final bool hasScripts;
}

String _mediaType(String mimeType) =>
    mimeType.split(';').first.trim().toLowerCase();

const _asciiWhitespace = <int>{0x09, 0x0A, 0x0C, 0x0D, 0x20};

String _trimAsciiWhitespace(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && _asciiWhitespace.contains(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _asciiWhitespace.contains(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(start, end);
}

class _EncodingLabel {
  const _EncodingLabel(this.name, this.implemented);

  final String name;
  final bool implemented;
}

_EncodingLabel? _encodingForLabel(String? rawLabel) {
  if (rawLabel == null) return null;
  final label = _trimAsciiWhitespace(rawLabel).toLowerCase();
  if (label.isEmpty) return null;

  if (const {
    'unicode-1-1-utf-8',
    'unicode11utf8',
    'unicode20utf8',
    'utf-8',
    'utf8',
    'x-unicode20utf8',
  }.contains(label)) {
    return const _EncodingLabel('utf-8', true);
  }

  if (const {
    'ansi_x3.4-1968',
    'ascii',
    'cp1252',
    'cp819',
    'csisolatin1',
    'ibm819',
    'iso-8859-1',
    'iso-ir-100',
    'iso8859-1',
    'iso88591',
    'iso_8859-1',
    'iso_8859-1:1987',
    'l1',
    'latin1',
    'us-ascii',
    'windows-1252',
    'x-cp1252',
  }.contains(label)) {
    return const _EncodingLabel('windows-1252', true);
  }

  if (const {
    'csunicode',
    'iso-10646-ucs-2',
    'ucs-2',
    'unicode',
    'unicodefeff',
    'utf-16',
    'utf-16le',
  }.contains(label)) {
    return const _EncodingLabel('utf-16le', true);
  }

  if (const {'unicodefffe', 'utf-16be'}.contains(label)) {
    return const _EncodingLabel('utf-16be', true);
  }

  if (_knownButUnsupportedLabels.contains(label)) {
    return _EncodingLabel(label, false);
  }
  return null;
}

String _requireImplemented(_EncodingLabel label) {
  if (!label.implemented) {
    throw UnsupportedError(
      tr("The recognized character encoding {0} is not implemented.", [
        label.name,
      ]),
    );
  }
  return label.name;
}

// Valid WHATWG labels whose decoders are intentionally not included.
const _knownButUnsupportedLabels = <String>{
  '866',
  'arabic',
  'asmo-708',
  'big5',
  'big5-hkscs',
  'chinese',
  'cn-big5',
  'cp866',
  'cp1250',
  'cp1251',
  'cp1253',
  'cp1254',
  'cp1255',
  'cp1256',
  'cp1257',
  'cp1258',
  'csbig5',
  'cseuckr',
  'cseucpkdfmtjapanese',
  'csibm866',
  'csiso2022jp',
  'csiso2022kr',
  'csiso58gb231280',
  'csiso88596e',
  'csiso88596i',
  'csiso88598e',
  'csiso88598i',
  'csisolatin2',
  'csisolatin3',
  'csisolatin4',
  'csisolatin5',
  'csisolatin6',
  'csisolatin9',
  'csisolatinhebrew',
  'csisolatinarabic',
  'csisolatincyrillic',
  'csisolatingreek',
  'csksc56011987',
  'csmacintosh',
  'cskoi8r',
  'csshiftjis',
  'cyrillic',
  'dos-874',
  'ecma-114',
  'ecma-118',
  'elot_928',
  'euc-jp',
  'euc-kr',
  'gb18030',
  'gb2312',
  'gb_2312',
  'gb_2312-80',
  'gbk',
  'greek',
  'greek8',
  'hebrew',
  'ibm866',
  'iso-2022-cn',
  'iso-2022-cn-ext',
  'iso-2022-jp',
  'iso-2022-kr',
  'iso-8859-2',
  'iso-8859-3',
  'iso-8859-4',
  'iso-8859-5',
  'iso-8859-6',
  'iso-8859-6-e',
  'iso-8859-6-i',
  'iso-8859-7',
  'iso-8859-8',
  'iso-8859-8-e',
  'iso-8859-8-i',
  'iso-8859-9',
  'iso-8859-10',
  'iso-8859-11',
  'iso-8859-13',
  'iso-8859-14',
  'iso-8859-15',
  'iso-8859-16',
  'iso-ir-101',
  'iso-ir-109',
  'iso-ir-110',
  'iso-ir-127',
  'iso-ir-126',
  'iso-ir-138',
  'iso-ir-144',
  'iso-ir-148',
  'iso-ir-149',
  'iso-ir-157',
  'iso-ir-58',
  'iso8859-2',
  'iso8859-3',
  'iso8859-4',
  'iso8859-5',
  'iso8859-6',
  'iso8859-7',
  'iso8859-8',
  'iso8859-9',
  'iso8859-10',
  'iso8859-11',
  'iso8859-13',
  'iso8859-14',
  'iso8859-15',
  'iso8859-16',
  'iso88592',
  'iso88593',
  'iso88594',
  'iso88595',
  'iso88596',
  'iso88597',
  'iso88598',
  'iso88599',
  'iso885910',
  'iso885911',
  'iso885913',
  'iso885914',
  'iso885915',
  'iso885916',
  'iso_8859-2',
  'iso_8859-2:1987',
  'iso_8859-3',
  'iso_8859-3:1988',
  'iso_8859-4',
  'iso_8859-4:1988',
  'iso_8859-5',
  'iso_8859-5:1988',
  'iso_8859-6',
  'iso_8859-6:1987',
  'iso_8859-7',
  'iso_8859-7:1987',
  'iso_8859-8',
  'iso_8859-8:1988',
  'iso_8859-9',
  'iso_8859-9:1989',
  'iso_8859-11',
  'iso_8859-13',
  'iso_8859-14',
  'iso_8859-15',
  'iso_8859-16',
  'koi',
  'koi8',
  'koi8-r',
  'koi8-ru',
  'koi8-u',
  'koi8_r',
  'ks_c_5601-1987',
  'ks_c_5601-1989',
  'ksc5601',
  'ksc_5601',
  'l2',
  'l3',
  'l4',
  'l5',
  'l6',
  'l9',
  'latin2',
  'latin3',
  'latin4',
  'latin5',
  'latin6',
  'logical',
  'mac',
  'macintosh',
  'ms932',
  'ms_kanji',
  'replacement',
  'shift-jis',
  'shift_jis',
  'sjis',
  'sun_eu_greek',
  'tis-620',
  'visual',
  'windows-1250',
  'windows-1251',
  'windows-1253',
  'windows-1254',
  'windows-1255',
  'windows-1256',
  'windows-1257',
  'windows-1258',
  'windows-31j',
  'windows-874',
  'windows-949',
  'x-cp1250',
  'x-cp1251',
  'x-cp1253',
  'x-cp1254',
  'x-cp1255',
  'x-cp1256',
  'x-cp1257',
  'x-cp1258',
  'x-euc-jp',
  'x-gbk',
  'x-mac-cyrillic',
  'x-mac-roman',
  'x-mac-ukrainian',
  'x-sjis',
  'x-user-defined',
  'x-x-big5',
};

String? _sniffBom(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return 'utf-8';
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return 'utf-16le';
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return 'utf-16be';
  }
  return null;
}

_EncodingLabel? _sniffHtmlMetaEncoding(Uint8List bytes) {
  final prefix = String.fromCharCodes(bytes.take(min(bytes.length, 1024)));
  final document = html.parse(prefix);

  for (final meta in document.querySelectorAll('meta')) {
    var gotPragma = false;
    var needPragma = false;
    var charsetWasSet = false;
    _EncodingLabel? charset;

    // Attribute order matters when charset and http-equiv/content coexist.
    for (final attribute in meta.attributes.entries) {
      switch (attribute.key) {
        case 'http-equiv':
          gotPragma =
              _trimAsciiWhitespace(attribute.value).toLowerCase() ==
              'content-type';
          break;
        case 'content':
          if (!charsetWasSet) {
            final contentLabel = _charsetFromContent(attribute.value);
            final contentEncoding = _encodingForLabel(contentLabel);
            if (contentEncoding != null) {
              charset = contentEncoding;
              charsetWasSet = true;
              needPragma = true;
            }
          }
          break;
        case 'charset':
          charset = _encodingForLabel(attribute.value);
          charsetWasSet = true;
          needPragma = false;
          break;
      }
    }

    if (!charsetWasSet || (needPragma && !gotPragma) || charset == null) {
      continue;
    }
    if (charset.name == 'utf-16le' || charset.name == 'utf-16be') {
      return const _EncodingLabel('utf-8', true);
    }
    if (charset.name == 'x-user-defined') {
      return const _EncodingLabel('windows-1252', true);
    }
    return charset;
  }
  return null;
}

String? _charsetFromContent(String content) {
  final match = RegExp(
    r'''(?:^|;)\s*charset\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s;]+))''',
    caseSensitive: false,
  ).firstMatch(content);
  return match?.group(1) ?? match?.group(2) ?? match?.group(3);
}

String _decode(Uint8List bytes, String encoding) {
  final start = switch (encoding) {
    'utf-8' when _sniffBom(bytes) == 'utf-8' => 3,
    'utf-16le' when _sniffBom(bytes) == 'utf-16le' => 2,
    'utf-16be' when _sniffBom(bytes) == 'utf-16be' => 2,
    _ => 0,
  };
  final remaining = Uint8List.sublistView(bytes, start);

  switch (encoding) {
    case 'utf-8':
      return utf8.decode(remaining, allowMalformed: true);
    case 'windows-1252':
      return String.fromCharCodes(
        remaining.map((byte) {
          if (byte < 0x80 || byte > 0x9F) return byte;
          return _windows1252C1[byte - 0x80];
        }),
      );
    case 'utf-16le':
      return _decodeUtf16(remaining, littleEndian: true);
    case 'utf-16be':
      return _decodeUtf16(remaining, littleEndian: false);
    default:
      throw UnsupportedError(
        tr("The character encoding {0} is not implemented.", [encoding]),
      );
  }
}

const _windows1252C1 = <int>[
  0x20AC,
  0x0081,
  0x201A,
  0x0192,
  0x201E,
  0x2026,
  0x2020,
  0x2021,
  0x02C6,
  0x2030,
  0x0160,
  0x2039,
  0x0152,
  0x008D,
  0x017D,
  0x008F,
  0x0090,
  0x2018,
  0x2019,
  0x201C,
  0x201D,
  0x2022,
  0x2013,
  0x2014,
  0x02DC,
  0x2122,
  0x0161,
  0x203A,
  0x0153,
  0x009D,
  0x017E,
  0x0178,
];

String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
  final output = StringBuffer();
  var index = 0;

  while (index + 1 < bytes.length) {
    final first = littleEndian
        ? bytes[index] | (bytes[index + 1] << 8)
        : (bytes[index] << 8) | bytes[index + 1];
    index += 2;

    if (first >= 0xD800 && first <= 0xDBFF) {
      if (index + 1 < bytes.length) {
        final second = littleEndian
            ? bytes[index] | (bytes[index + 1] << 8)
            : (bytes[index] << 8) | bytes[index + 1];
        if (second >= 0xDC00 && second <= 0xDFFF) {
          index += 2;
          output.writeCharCode(
            0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00),
          );
          continue;
        }
      }
      output.writeCharCode(0xFFFD);
      continue;
    }

    if (first >= 0xDC00 && first <= 0xDFFF) {
      output.writeCharCode(0xFFFD);
    } else {
      output.writeCharCode(first);
    }
  }

  if (index < bytes.length) output.writeCharCode(0xFFFD);
  return output.toString();
}
