// page_commands.dart
//
// Feature 5 — Page operations (reversible commands + undo/redo).

import 'page_model.dart';

abstract interface class PageCommand {
  void apply(PageListDocument doc);
  void revert(PageListDocument doc);
  String get label;
}

/// Moves the page at [from] to index [to].
final class MovePageCommand implements PageCommand {
  final int from;
  final int to;
  MovePageCommand(this.from, this.to);

  @override
  void apply(PageListDocument doc) {
    if (to < 0 || to >= doc.pageCount) {
      throw RangeError.range(to, 0, doc.pageCount - 1, 'to');
    }
    final e = doc.removeAt(from);
    doc.insert(to, e);
  }

  @override
  void revert(PageListDocument doc) {
    final e = doc.removeAt(to);
    doc.insert(from, e);
  }

  @override
  String get label => 'Move page ${from + 1} → ${to + 1}';
}

/// Rotates the page at [index] by [quarters] quarter-turns (clockwise).
final class RotatePageCommand implements PageCommand {
  final int index;
  final int quarters;
  RotatePageCommand(this.index, this.quarters);

  @override
  void apply(PageListDocument doc) =>
      doc.setEntry(index, doc.entryAt(index).rotated(quarters));

  @override
  void revert(PageListDocument doc) =>
      doc.setEntry(index, doc.entryAt(index).rotated(-quarters));

  @override
  String get label => 'Rotate page ${index + 1}';
}

/// Deletes the page at [index].
final class DeletePageCommand implements PageCommand {
  final int index;
  PageEntry? _removed;
  DeletePageCommand(this.index);

  @override
  void apply(PageListDocument doc) => _removed = doc.removeAt(index);

  @override
  void revert(PageListDocument doc) {
    final e = _removed;
    if (e == null) throw StateError('nothing to restore');
    doc.insert(index, e);
  }

  @override
  String get label => 'Delete page ${index + 1}';
}

/// Inserts [entry] at [index].
final class InsertPageCommand implements PageCommand {
  final int index;
  final PageEntry entry;
  InsertPageCommand(this.index, this.entry);

  @override
  void apply(PageListDocument doc) => doc.insert(index, entry);

  @override
  void revert(PageListDocument doc) => doc.removeAt(index);

  @override
  String get label => 'Insert page at ${index + 1}';
}

/// Duplicates the page at [index], placing the copy immediately after it.
final class DuplicatePageCommand implements PageCommand {
  final int index;
  DuplicatePageCommand(this.index);

  @override
  void apply(PageListDocument doc) => doc.insert(index + 1, doc.entryAt(index));

  @override
  void revert(PageListDocument doc) => doc.removeAt(index + 1);

  @override
  String get label => 'Duplicate page ${index + 1}';
}

/// Appends pages (e.g. merging another document) to the end.
final class AppendPagesCommand implements PageCommand {
  final List<PageEntry> entries;
  AppendPagesCommand(this.entries);

  @override
  void apply(PageListDocument doc) {
    for (final e in entries) {
      doc.insert(doc.pageCount, e);
    }
  }

  @override
  void revert(PageListDocument doc) {
    for (var k = 0; k < entries.length; k++) {
      doc.removeAt(doc.pageCount - 1);
    }
  }

  @override
  String get label => 'Append ${entries.length} page(s)';
}

/// Bounded undo/redo stack over a single [PageListDocument].
final class PageCommandStack {
  final PageListDocument doc;
  final int maxDepth;
  final List<PageCommand> _undo = <PageCommand>[];
  final List<PageCommand> _redo = <PageCommand>[];

  PageCommandStack(this.doc, {this.maxDepth = 200}) {
    if (maxDepth < 1) throw ArgumentError('maxDepth must be >= 1');
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoDepth => _undo.length;

  void execute(PageCommand c) {
    c.apply(doc);
    _undo.add(c);
    if (_undo.length > maxDepth) _undo.removeAt(0);
    _redo.clear();
  }

  void undo() {
    if (_undo.isEmpty) return;
    final c = _undo.removeLast();
    c.revert(doc);
    _redo.add(c);
  }

  void redo() {
    if (_redo.isEmpty) return;
    final c = _redo.removeLast();
    c.apply(doc);
    _undo.add(c);
  }
}
