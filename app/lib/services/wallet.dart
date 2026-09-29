import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DocKind {
  rc(/*t*/'Registration (RC)', Icons.badge_outlined),
  insurance(/*t*/'Insurance policy', Icons.verified_user_outlined),
  puc(/*t*/'PUC certificate', Icons.eco_outlined),
  licence(/*t*/'Driving licence', Icons.credit_card_outlined),
  other(/*t*/'Other document', Icons.description_outlined);

  const DocKind(this.label, this.icon);
  final String label;
  final IconData icon;

  static DocKind parse(String s) => values.firstWhere((k) => k.name == s, orElse: () => other);
}

/// Photos of a paper document, kept in the app's private folder. Never
/// uploaded: Connect doesn't want a copy of anyone's licence.
class WalletDoc {
  WalletDoc({required this.kind, required this.pages, required this.addedAt, this.note});
  final DocKind kind;
  final List<String> pages;
  final DateTime addedAt;
  final String? note;

  Map<String, dynamic> toJson() => {'kind': kind.name, 'pages': pages, 'addedAt': addedAt.toIso8601String(), 'note': note};

  factory WalletDoc.fromJson(Map<String, dynamic> j) => WalletDoc(
        kind: DocKind.parse(j['kind'] as String),
        pages: (j['pages'] as List).cast<String>(),
        addedAt: DateTime.parse(j['addedAt'] as String),
        note: j['note'] as String?,
      );
}

class Wallet {
  static const _key = 'wallet_v1';

  /// One entry per kind.
  static final docs = ValueNotifier<Map<DocKind, WalletDoc>>(const {});

  static Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      final list = (jsonDecode(raw) as List).map((e) => WalletDoc.fromJson(e as Map<String, dynamic>));
      docs.value = {for (final d in list) d.kind: d};
    } catch (e) {
      debugPrint('wallet load failed: $e');
    }
  }

  static Future<void> _save(Map<DocKind, WalletDoc> m) async {
    docs.value = Map.unmodifiable(m);
    await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(m.values.map((d) => d.toJson()).toList()));
  }

  /// Camera or gallery photo, copied out of the picker's cache.
  static Future<String?> capture({required bool camera}) async {
    if (kIsWeb) return null;
    final shot = await ImagePicker().pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 2000,
      imageQuality: 80,
    );
    if (shot == null) return null;
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/wallet');
    await dir.create(recursive: true);
    final dest = '${dir.path}/doc_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(shot.path).copy(dest);
    return dest;
  }

  static Future<void> put(WalletDoc d) async {
    final old = docs.value[d.kind];
    await _save({...docs.value, d.kind: d});
    for (final p in old?.pages ?? const <String>[]) {
      if (!d.pages.contains(p)) deletePage(p);
    }
  }

  static Future<void> remove(DocKind k) async {
    final old = docs.value[k];
    await _save({...docs.value}..remove(k));
    for (final p in old?.pages ?? const <String>[]) {
      deletePage(p);
    }
  }

  static void deletePage(String path) {
    if (kIsWeb) return;
    File(path).delete().then((_) {}, onError: (_) {});
  }
}
