import 'package:evdekimi_ai/core/text/markdown_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// The inputs here are real assistant replies, not invented ones.
///
/// Every block below is copied from what `tools/mock_server.js` actually
/// streams, because the failure this guards against was cosmetic and only
/// visible against real output: the conversation list printed
/// `**Villa Melati — Berawa**` and `| --- | --- |` verbatim.
void main() {
  group('inline markup', () {
    test('unwraps bold, italic and inline code', () {
      expect(
        MarkdownText.toPlain('Leasehold to 2051 · **\$298,000**'),
        equals(r'Leasehold to 2051 · $298,000'),
      );
      expect(
        MarkdownText.toPlain('Agree the extension terms *in the lease*.'),
        equals('Agree the extension terms in the lease.'),
      );
      expect(
        MarkdownText.toPlain('Call `refresh()` first.'),
        equals('Call refresh() first.'),
      );
    });

    test('bold is unwrapped before italic', () {
      // Running the single-asterisk rule first eats one asterisk from each side
      // and leaves *text* behind, which looks like a bug rather than markup.
      expect(MarkdownText.toPlain('**bold**'), equals('bold'));
      expect(MarkdownText.toPlain('a **b** c *d* e'), equals('a b c d e'));
    });

    test('keeps link and image labels, drops the targets', () {
      expect(
        MarkdownText.toPlain('See [the listing](https://evdekimi.shop/v/12).'),
        equals('See the listing.'),
      );
      expect(
        MarkdownText.toPlain('![Villa Melati](https://cdn.test/a.jpg) is new'),
        equals('Villa Melati is new'),
      );
    });

    test('leaves single underscores alone', () {
      // Deliberate: `_x_` cannot be told from an identifier without word
      // boundaries, and mangling `snake_case` mid-sentence is the worse error.
      expect(
        MarkdownText.toPlain('The flag is use_on_device_when_offline.'),
        equals('The flag is use_on_device_when_offline.'),
      );
    });
  });

  group('block constructs', () {
    test('drops a fenced code block and keeps the prose around it', () {
      const reply = '''
Here is a compact implementation:

```dart
Timer? _timer;
void debounce(VoidCallback action) => _timer = Timer(delay, action);
```

Call it from the text field's onChanged.''';

      expect(
        MarkdownText.toPlain(reply),
        equals(
          "Here is a compact implementation: Call it from the text field's "
          'onChanged.',
        ),
      );
    });

    test('survives an unterminated fence', () {
      // A cancelled stream leaves one behind; a greedy match would then eat the
      // rest of the message and return an empty preview.
      expect(
        MarkdownText.toPlain('Try this:\n```dart\nfinal x = 1;'),
        equals('Try this:'),
      );
    });

    test('reduces a table to its cells', () {
      const reply = '''
Here is roughly where the market sits right now.

| Area | 2BR villa | 3BR villa |
| --- | --- | --- |
| Canggu / Berawa | \$195k | \$310k |
| Ubud | \$150k | \$240k |''';

      expect(
        MarkdownText.toPlain(reply),
        equals(
          'Here is roughly where the market sits right now. '
          'Area · 2BR villa · 3BR villa '
          r'Canggu / Berawa · $195k · $310k '
          r'Ubud · $150k · $240k',
        ),
      );
    });

    test('strips headings, quotes, list markers and rules', () {
      const reply = '''
## What actually matters

1. Check the certificate class.
2. Confirm the zoning permits your use.

- Thursday afternoon is open
- Friday afternoon is open

---

> Our notary handles due diligence.''';

      expect(
        MarkdownText.toPlain(reply),
        equals(
          'What actually matters '
          'Check the certificate class. '
          'Confirm the zoning permits your use. '
          'Thursday afternoon is open '
          'Friday afternoon is open '
          'Our notary handles due diligence.',
        ),
      );
    });
  });

  group('edges', () {
    test('collapses all whitespace to single spaces', () {
      expect(
        MarkdownText.toPlain('one\n\n\ntwo\t\tthree   four'),
        equals('one two three four'),
      );
    });

    test('returns empty for input that is only markup', () {
      expect(MarkdownText.toPlain(''), isEmpty);
      expect(MarkdownText.toPlain('```\ncode\n```'), isEmpty);
      expect(MarkdownText.toPlain('---'), isEmpty);
    });

    test('leaves plain prose untouched', () {
      const plain = 'Viewings run Monday to Saturday, 09:00-17:00 WITA.';
      expect(MarkdownText.toPlain(plain), equals(plain));
    });
  });
}
