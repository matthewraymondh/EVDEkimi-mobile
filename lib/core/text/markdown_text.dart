/// Markdown reduced to the sentence underneath it.
///
/// Assistant replies are markdown, but a conversation row is one unstyled line
/// with no renderer behind it. Without this the home screen printed
/// `**Villa Melati — Berawa**` and a price table's `| --- | --- |` verbatim,
/// which is what markup leaking into a plain-text surface looks like.
///
/// Deliberately **not** a parser. It handles the constructs an assistant
/// actually emits, ordered so they cannot interfere with each other, and leaves
/// everything else alone. A preview that misses an exotic edge case is fine; one
/// that mangles an ordinary sentence is not, so every rule here is narrow.
abstract final class MarkdownText {
  /// Strips markup from [source], collapsing it to a single line.
  static String toPlain(String source) {
    // Fenced blocks go first and go entirely. Their contents are code, so no
    // later rule should ever see them — `Timer? _timer` must not have its
    // underscores read as emphasis, and a preview of a code block is noise
    // anyway. The prose introducing it is the useful part.
    var text = source.replaceAll('\r\n', '\n').replaceAll(_fencedBlock, ' ');

    text = text.split('\n').map(_stripLinePrefix).nonNulls.join(' ');

    // Images before links: the two syntaxes differ only by a leading `!`, so
    // the link rule would otherwise strip the label and strand the `!`.
    text = text
        .replaceAllMapped(_image, _firstGroup)
        .replaceAllMapped(_link, _firstGroup)
        // Bold before italic, or `**text**` loses one asterisk from each side
        // and comes out as `*text*`.
        .replaceAllMapped(_boldStars, _firstGroup)
        .replaceAllMapped(_boldUnderscores, _firstGroup)
        .replaceAllMapped(_italicStars, _firstGroup)
        .replaceAllMapped(_strikethrough, _firstGroup)
        .replaceAllMapped(_inlineCode, _firstGroup);

    return text.replaceAll(_whitespace, ' ').trim();
  }

  /// Handles the line-level constructs, or drops the line entirely.
  ///
  /// Returns `null` for lines that carry no words — blanks, rules, and the
  /// `| --- | --- |` separator every markdown table has.
  static String? _stripLinePrefix(String rawLine) {
    final line = rawLine.trim();
    if (line.isEmpty) return null;
    if (_tableDivider.hasMatch(line)) return null;
    if (_horizontalRule.hasMatch(line)) return null;

    if (_tableRow.hasMatch(line)) {
      // Keep the cells, lose the scaffolding: a preview of the price table
      // should read "Canggu · $195k · $310k", not "| Canggu | $195k |".
      return line
          .split('|')
          .map((cell) => cell.trim())
          .where((cell) => cell.isNotEmpty)
          .join(' · ');
    }

    return line
        .replaceFirst(_heading, '')
        .replaceFirst(_blockquote, '')
        .replaceFirst(_listMarker, '');
  }

  static String _firstGroup(Match match) => match.group(1) ?? '';

  /// Tolerates an unterminated fence, which a cancelled stream leaves behind.
  static final RegExp _fencedBlock = RegExp(r'```[\s\S]*?(?:```|$)');

  static final RegExp _tableDivider = RegExp(r'^\|[\s:|-]*\|$');
  static final RegExp _tableRow = RegExp(r'^\|.*\|$');
  static final RegExp _horizontalRule = RegExp(r'^(?:-{3,}|\*{3,}|_{3,})$');
  static final RegExp _heading = RegExp(r'^#{1,6}\s+');
  static final RegExp _blockquote = RegExp(r'^>\s?');
  static final RegExp _listMarker = RegExp(r'^(?:[-*+]\s+|\d+[.)]\s+)');

  static final RegExp _image = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
  static final RegExp _link = RegExp(r'\[([^\]]*)\]\([^)]*\)');
  static final RegExp _boldStars = RegExp(r'\*\*(.+?)\*\*');
  static final RegExp _boldUnderscores = RegExp(r'__(.+?)__');
  static final RegExp _italicStars = RegExp(r'\*([^*\n]+)\*');
  static final RegExp _strikethrough = RegExp(r'~~(.+?)~~');
  static final RegExp _inlineCode = RegExp('`([^`]+)`');

  // Single-underscore italics are *not* handled, on purpose. `_x_` is
  // indistinguishable from an identifier without tracking word boundaries, and
  // getting it wrong turns `snake_case_name` into `snake case name` inside a
  // sentence. Assistants emit asterisk emphasis overwhelmingly more often, so
  // the trade is heavily one-sided.

  static final RegExp _whitespace = RegExp(r'\s+');
}
