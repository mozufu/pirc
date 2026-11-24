import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_layout_visibility.dart';

void main() {
  Set<String> hidden(String source) {
    final document = html.parse(source);
    for (final e in document.querySelectorAll('[id]')) {
      e.attributes['data-pirc-script-id'] = e.id;
    }
    return nativeDocumentNoBoxIds(
      document: document,
      knownIds: const ['omitted-script'],
      stylesByElement: {
        for (final e in document.querySelectorAll('[data-display]'))
          e: {'display': e.attributes['data-display']!},
      },
    );
  }

  test('a closed details keeps only its first summary subtree visible', () {
    expect(
      hidden(
        '<details id="details"><summary id="first"><span id="label">Title</span></summary><p id="body">Body</p><summary id="second">Other</summary></details>',
      ),
      {'omitted-script', 'body', 'second'},
    );
  });
  test(
    'opening details allows body boxes but preserves explicit hidden state',
    () {
      expect(
        hidden(
          '<details open id="details"><summary id="first">Title</summary><p id="body">Body</p><p hidden id="hidden">Hidden</p><div data-display="none"><b id="css-hidden">CSS hidden</b></div></details>',
        ),
        {'omitted-script', 'hidden', 'css-hidden'},
      );
    },
  );
  test('a closed outer details hides an open nested body and its summary', () {
    expect(
      hidden(
        '<details id="outer"><summary id="outer-title">Title</summary><details open id="inner"><summary id="inner-title">Nested</summary><p id="inner-body">Body</p></details></details>',
      ),
      {'omitted-script', 'inner', 'inner-title', 'inner-body'},
    );
  });
  test('details without a summary has no visible authored body boxes', () {
    expect(
      hidden(
        '<details id="details"><p id="body">Body</p></details><div data-display="contents" id="contents"><span id="content-child">Visible child</span></div>',
      ),
      {'omitted-script', 'body', 'contents'},
    );
  });
}
