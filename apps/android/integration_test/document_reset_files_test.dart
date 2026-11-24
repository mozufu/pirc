import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_mobile/theme.dart';

const resetFilesHtml = '''<!doctype html><html><body>
<form id="form" action="/send" method="post" enctype="multipart/form-data">
<label for="query">Query</label><input id="query" name="query" value="Initial">
<label for="upload">Attachment</label><input id="upload" name="upload" type="file">
<button id="update" type="button">Update page</button>
<button id="cancel" type="button">Cancel next reset</button>
<button id="reset-button" type="reset">Reset</button>
<button id="programmatic" type="button">Script reset</button>
<button id="clear" type="button">Clear file</button>
<button id="send">Send</button>
</form>
<p id="revision">Revision 0</p><p id="selection">No selection event</p><p id="resetResult">No reset</p>
<script>
window.revision = 0; window.cancelReset = false;
const form = document.querySelector('#form'), field = document.querySelector('#query'), upload = document.querySelector('#upload');
upload.addEventListener('change', () => {
 document.querySelector('#selection').textContent = 'Selected: ' + upload.files[0].name + ' / ' + upload.files[0].size;
});
document.querySelector('#update').onclick = () => { document.querySelector('#revision').textContent = 'Revision ' + (++window.revision); };
document.querySelector('#cancel').onclick = () => { window.cancelReset = true; document.querySelector('#resetResult').textContent = 'Will cancel'; };
form.addEventListener('reset', event => {
 document.querySelector('#resetResult').textContent = (window.cancelReset ? 'Canceled: ' : 'Reset from: ') + field.value;
 if (window.cancelReset) { event.preventDefault(); window.cancelReset = false; }
});
document.querySelector('#programmatic').onclick = () => { form.reset(); };
document.querySelector('#clear').onclick = () => { upload.value = ''; };
</script></body></html>''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android reset defaults and native files survive dynamic document updates',
    (t) async {
      final scripts = NativeDocumentScripts(Gateway());
      final theme = await PircTheme.load();
      final identity = Object(), viewport = NativeHtmlViewportController();
      final submissions = <NativeHtmlFormSubmission>[];
      var picks = 0;
      Future<void> until(bool Function() condition, String label) async {
        for (var i = 0; i < 150 && !condition(); i++) {
          await t.pump(const Duration(milliseconds: 50));
        }
        expect(condition(), true, reason: '$label: ${scripts.diagnostics}');
        expect(t.takeException(), isNull, reason: label);
      }

      Finder button(String label) => find.byWidgetPredicate(
        (w) => w is NativeHtmlButtonWidget && w.button.label == label,
      );
      Future<void> tap(String label) async {
        await t.ensureVisible(button(label));
        await t.tap(button(label));
        await t.pump(const Duration(milliseconds: 100));
      }

      NativeHtmlFileInputWidget fileWidget() =>
          t.widget<NativeHtmlFileInputWidget>(
            find.byType(NativeHtmlFileInputWidget),
          );
      int fileCount() =>
          fileWidget().state.filesFor(fileWidget().control.key).length;
      String value() =>
          t.widget<TextField>(find.byType(TextField)).controller!.text;
      Future<void> pick() async {
        await t.ensureVisible(find.byType(NativeHtmlFileInputWidget));
        await t.tap(find.byType(NativeHtmlFileInputWidget));
        await until(() => fileCount() == 1, 'file picked');
        await until(
          () => find
              .text('Selected: report.txt / 3', findRichText: true)
              .evaluate()
              .isNotEmpty,
          'file change',
        );
      }

      try {
        await scripts.start(
          source: resetFilesHtml,
          url: 'https://example.test/reset',
        );
        expect(scripts.ready, true, reason: scripts.diagnostics.toString());
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: SingleChildScrollView(
                child: ListenableBuilder(
                  listenable: scripts,
                  builder: (context, _) => NativeHtmlDocument(
                    nodes: [NativeHtmlRaw(scripts.content!.bodyInnerHtml)],
                    style: const TextStyle(fontSize: 16),
                    styles: MarkdownStyleSheet(),
                    builders: const {},
                    markdownStyles: false,
                    viewport: viewport,
                    scriptDocument: identity,
                    scriptSnapshot: scripts.content,
                    onScriptEvent: scripts.dispatch,
                    onFormSubmit: submissions.add,
                    filePicker: (_) async {
                      picks++;
                      return [
                        NativeHtmlFile(
                          name: 'report.txt',
                          mimeType: 'text/plain',
                          bytes: [65, 66, 67],
                        ),
                      ];
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        await t.enterText(find.byType(TextField), 'Edited');
        await t.pumpAndSettle();
        await pick();
        await tap('Update page');
        await until(
          () =>
              find.text('Revision 1', findRichText: true).evaluate().isNotEmpty,
          'DOM replaced',
        );
        expect(fileCount(), 1);
        expect(value(), 'Edited');
        await tap('Send');
        await until(() => submissions.length == 1, 'file submit');
        final entry = submissions.single.entries.firstWhere(
          (e) => e.name == 'upload',
        );
        expect(entry.file!.bytes, [65, 66, 67]);
        await tap('Cancel next reset');
        await t.pumpAndSettle();
        await tap('Reset');
        await until(
          () => find
              .text('Canceled: Edited', findRichText: true)
              .evaluate()
              .isNotEmpty,
          'reset canceled',
        );
        expect(value(), 'Edited');
        expect(fileCount(), 1);
        await tap('Reset');
        await until(
          () => value() == 'Initial' && fileCount() == 0,
          'native reset defaults',
        );
        await t.enterText(find.byType(TextField), 'Second');
        await t.pumpAndSettle();
        await pick();
        await tap('Script reset');
        await until(
          () => value() == 'Initial' && fileCount() == 0,
          'script reset defaults',
        );
        await pick();
        await tap('Clear file');
        await until(() => fileCount() == 0, 'script clears file');
        expect(picks, 3);
      } finally {
        await t.pumpWidget(const SizedBox());
        scripts.dispose();
      }
    },
  );
}
