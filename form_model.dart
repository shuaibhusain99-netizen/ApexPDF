// annotation_commands.dart
//
// Feature 1 — Annotations (undo/redo).
//
// Every edit is a reversible command applied to an AnnotationStore. The stack
// supports undo/redo with bounded history; issuing a new command after undoing
// discards the redo branch (standard editor semantics).

import 'annotation_model.dart' show Annotation;
import 'annotation_store.dart' show AnnotationStore;

/// A reversible edit against an [AnnotationStore].
abstract interface class AnnotationCommand {
  void apply(AnnotationStore store);
  void revert(AnnotationStore store);

  /// Short human-readable label (for an "Undo X" menu).
  String get label;
}

final class AddAnnotationCommand implements AnnotationCommand {
  final Annotation annotation;
  AddAnnotationCommand(this.annotation);

  @override
  void apply(AnnotationStore store) => store.add(annotation);

  @override
  void revert(AnnotationStore store) => store.remove(annotation.id);

  @override
  String get label => 'Add ${annotation.kind.name}';
}

final class RemoveAnnotationCommand implements AnnotationCommand {
  final Annotation annotation;
  RemoveAnnotationCommand(this.annotation);

  @override
  void apply(AnnotationStore store) => store.remove(annotation.id);

  @override
  void revert(AnnotationStore store) => store.add(annotation);

  @override
  String get label => 'Delete ${annotation.kind.name}';
}

/// Replaces an annotation with [next], remembering [previous] for revert.
/// Both must share the same id.
final class UpdateAnnotationCommand implements AnnotationCommand {
  final Annotation previous;
  final Annotation next;

  UpdateAnnotationCommand({required this.previous, required this.next}) {
    if (previous.id != next.id) {
      throw ArgumentError('update requires matching ids '
          '(${previous.id} != ${next.id})');
    }
  }

  @override
  void apply(AnnotationStore store) => store.update(next);

  @override
  void revert(AnnotationStore store) => store.update(previous);

  @override
  String get label => 'Edit ${next.kind.name}';
}

/// Bounded undo/redo stack bound to a single [AnnotationStore].
final class CommandStack {
  final AnnotationStore store;
  final int maxDepth;

  final List<AnnotationCommand> _undo = <AnnotationCommand>[];
  final List<AnnotationCommand> _redo = <AnnotationCommand>[];

  CommandStack(this.store, {this.maxDepth = 200}) {
    if (maxDepth < 1) {
      throw ArgumentError.value(maxDepth, 'maxDepth', 'must be >= 1');
    }
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoDepth => _undo.length;
  int get redoDepth => _redo.length;

  /// Applies [command] and pushes it onto the undo stack, clearing any redo
  /// branch. Trims history to [maxDepth].
  void execute(AnnotationCommand command) {
    command.apply(store);
    _undo.add(command);
    if (_undo.length > maxDepth) _undo.removeAt(0);
    _redo.clear();
  }

  /// Reverts the most recent command; moves it to the redo stack. No-op if empty.
  void undo() {
    if (_undo.isEmpty) return;
    final c = _undo.removeLast();
    c.revert(store);
    _redo.add(c);
  }

  /// Re-applies the most recently undone command. No-op if empty.
  void redo() {
    if (_redo.isEmpty) return;
    final c = _redo.removeLast();
    c.apply(store);
    _undo.add(c);
  }

  void clearHistory() {
    _undo.clear();
    _redo.clear();
  }
}
