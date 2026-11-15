import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'model.dart';
import 'tokens.dart';

/// Editing state of one receipt: the document, the selected block and an
/// undo/redo history of immutable snapshots. UI-independent.
class ReceiptEditor extends ChangeNotifier {
  ReceiptEditor(Receipt initial) : _doc = initial;

  /// Edits with the same key closer together than this merge into one undo
  /// step (typing, dragging a slider).
  static const coalesceWindow = Duration(milliseconds: 1200);
  static const maxHistory = 200;

  Receipt _doc;
  Receipt get doc => _doc;

  String? _selectedId;
  String? get selectedId => _selectedId;
  ReceiptBlock? get selected => _doc.blocks.where((b) => b.id == _selectedId).firstOrNull;

  final _undo = <Receipt>[];
  final _redo = <Receipt>[];
  String? _lastKey;
  DateTime _lastEdit = DateTime.fromMillisecondsSinceEpoch(0);

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Replace the document as one undoable step.
  void apply(Receipt next, {String? coalesce}) {
    final now = DateTime.now();
    final merge = coalesce != null && coalesce == _lastKey && now.difference(_lastEdit) < coalesceWindow;
    if (!merge) {
      _undo.add(_doc);
      if (_undo.length > maxHistory) _undo.removeAt(0);
    }
    _redo.clear();
    _doc = next;
    _lastKey = coalesce;
    _lastEdit = now;
    notifyListeners();
  }

  /// Open another document (template, saved, imported). Undoable.
  void load(Receipt r) {
    apply(r);
    _selectedId = null;
    notifyListeners();
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(_doc);
    _doc = _undo.removeLast();
    _lastKey = null;
    notifyListeners();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(_doc);
    _doc = _redo.removeLast();
    _lastKey = null;
    notifyListeners();
  }

  void select(String? id) {
    if (id == _selectedId) return;
    _selectedId = id;
    _lastKey = null;
    notifyListeners();
  }

  void rename(String name) => apply(_doc.copyWith(name: name), coalesce: 'name');

  /// Set the next running number. Not merged with other edits.
  void setCounter(int n) => apply(_doc.copyWith(counter: n), coalesce: 'counter');

  /// After printing: advance `{n}` without creating an undo step.
  void advanceCounter(int by) {
    _doc = _doc.copyWith(counter: _doc.counter + by);
    notifyListeners();
  }

  /// Replace the block with the same id. [field] distinguishes properties
  /// for undo coalescing (typing in a text field is one step).
  void update(ReceiptBlock b, [String field = 'props']) {
    final i = _index(b.id);
    if (i < 0) return;
    apply(_doc.copyWith(blocks: [..._doc.blocks]..[i] = b), coalesce: '${b.id}:$field');
  }

  /// Insert after the selected block (or at the end) and select it.
  void add(ReceiptBlock b) {
    final sel = _selectedId == null ? -1 : _index(_selectedId!);
    final at = sel < 0 ? _doc.blocks.length : sel + 1;
    apply(_doc.copyWith(blocks: [..._doc.blocks]..insert(at, b)));
    _selectedId = b.id;
    notifyListeners();
  }

  void duplicate(String id) {
    final i = _index(id);
    if (i < 0) return;
    final copy = _doc.blocks[i].duplicate();
    apply(_doc.copyWith(blocks: [..._doc.blocks]..insert(i + 1, copy)));
    _selectedId = copy.id;
    notifyListeners();
  }

  void remove(String id) {
    final i = _index(id);
    if (i < 0) return;
    apply(_doc.copyWith(blocks: [..._doc.blocks]..removeAt(i)));
    if (_selectedId == id) _selectedId = null;
    notifyListeners();
  }

  /// [ReorderableListView.onReorder] semantics: [newIndex] counts the
  /// moved item still in place.
  void move(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    if (oldIndex == newIndex) return;
    final blocks = [..._doc.blocks];
    blocks.insert(newIndex, blocks.removeAt(oldIndex));
    apply(_doc.copyWith(blocks: blocks));
  }

  int _index(String id) => _doc.blocks.indexWhere((b) => b.id == id);
}

/// Whether any block uses the running number `{n}`.
bool receiptUsesCounter(Receipt r) => r.blocks.any((b) => switch (b) {
      TextBlock() => usesCounter(b.text),
      ColumnsBlock() => b.cells.any((c) => usesCounter(c.text)),
      QrBlock() => usesCounter(b.data),
      BarcodeBlock() => usesCounter(b.data),
      _ => false,
    });

// ----------------------------------------------------------------- library ---

/// Saved receipts are stored as one JSON array of receipt objects.
List<Receipt> decodeLibrary(String? json) {
  if (json == null || json.isEmpty) return [];
  try {
    final list = jsonDecode(json);
    if (list is! List) return [];
    return [
      for (final j in list)
        if (j is Map) Receipt.fromJson(j.cast<String, Object?>()),
    ];
  } on FormatException catch (e) {
    debugPrint('saved receipts unreadable: $e');
    return [];
  }
}

String encodeLibrary(List<Receipt> lib) => jsonEncode([for (final r in lib) r.toJson()]);

/// Insert or replace (by name), sorted by name.
List<Receipt> upsertReceipt(List<Receipt> lib, Receipt r) =>
    [...lib.where((x) => x.name != r.name), r]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
