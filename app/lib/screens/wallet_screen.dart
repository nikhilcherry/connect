import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';
import '../services/wallet.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

/// Photos of the car's papers, kept only on this phone.
class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Documents'))),
      body: SafeArea(
        child: ValueListenableBuilder<Map<DocKind, WalletDoc>>(
          valueListenable: Wallet.docs,
          builder: (context, docs, _) => ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 32), children: revealAll([
            ScreenTitle(tr('Your car\'s papers'), eyebrow: tr('On this phone only')),
            const SizedBox(height: 8),
            Text(tr('Keep photos of your RC, insurance, PUC and licence handy for the petrol pump, the service centre or a checkpoint.'),
                style: DLText.body.copyWith(color: DL.muted)),
            const SizedBox(height: 16),
            const _Disclaimer(),
            const SizedBox(height: 24),
            if (kIsWeb)
              EmptyState(
                icon: Icons.phone_android_outlined,
                title: tr('Available in the Android app'),
                body: tr('Documents are stored in the app\'s private folder, which the web preview doesn\'t have.'),
              )
            else
              Column(children: [
                for (final k in DocKind.values) ...[_DocCard(kind: k, doc: docs[k]), const SizedBox(height: 12)],
              ]),
            const SizedBox(height: 8),
            FootNote(tr('Photos stay in Connect\'s private folder on this phone. They aren\'t uploaded or backed up, so uninstalling the app deletes them.')),
          ])),
        ),
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Tone.info.bg, borderRadius: BorderRadius.circular(DL.rCard)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.info_outline, color: DL.violetDeep, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              tr('These photos are a convenience, not legal copies. For an officer, show your documents in DigiLocker or mParivahan, which are valid under the Motor Vehicles Act.'),
              style: DLText.body.copyWith(color: DL.violetDeep, height: 1.45),
            ),
            const SizedBox(height: 6),
            TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(44, 36), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              onPressed: () => launchUrl(Uri.parse('https://www.digilocker.gov.in/'), mode: LaunchMode.externalApplication),
              child: Text(tr('Open DigiLocker')),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _DocCard extends StatelessWidget {
  const _DocCard({required this.kind, required this.doc});
  final DocKind kind;
  final WalletDoc? doc;

  Future<void> _add(BuildContext context, {required bool camera}) async {
    try {
      final path = await Wallet.capture(camera: camera);
      if (path == null) return;
      await Wallet.put(WalletDoc(kind: kind, pages: [...?doc?.pages, path], addedAt: DateTime.now(), note: doc?.note));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _addSheet(BuildContext context) => showModalBottomSheet(
        context: context,
        showDragHandle: true,
        builder: (c) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(tr('Take a photo')),
              onTap: () {
                Navigator.pop(c);
                _add(context, camera: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(tr('Choose from gallery')),
              onTap: () {
                Navigator.pop(c);
                _add(context, camera: false);
              },
            ),
            const SizedBox(height: 8),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final d = doc;
    return SectionCard(
      onTap: d == null ? () => _addSheet(context) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconBadge(kind.icon, tone: d == null ? null : Tone.success, size: 40),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr(kind.label), style: DLText.strong),
              const SizedBox(height: 2),
              Text(
                d == null
                    ? tr('Tap to add a photo')
                    : tr('{n} pages · added {date}', {'n': d.pages.length, 'date': DateFormat.yMMMd().format(d.addedAt)}),
                style: DLText.small,
              ),
            ]),
          ),
          if (d == null)
            const Icon(Icons.add, color: DL.violet)
          else
            PopupMenuButton<String>(
              tooltip: tr('More'),
              onSelected: (v) async {
                if (v == 'add') _addSheet(context);
                if (v == 'remove') {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: Text(tr('Delete these photos?')),
                      content: Text(tr('They\'re removed from this phone. This can\'t be undone.')),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
                        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Delete'))),
                      ],
                    ),
                  );
                  if (ok == true) await Wallet.remove(kind);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'add', child: Text(tr('Add another page'))),
                PopupMenuItem(value: 'remove', child: Text(tr('Delete'), style: const TextStyle(color: DL.error))),
              ],
            ),
        ]),
        if (d != null && d.pages.isNotEmpty) ...[
          const SizedBox(height: 14),
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: d.pages.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => Pressable(
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(PageRouteBuilder(
                    opaque: false,
                    barrierColor: DL.ink,
                    transitionDuration: DL.medium,
                    reverseTransitionDuration: DL.medium,
                    pageBuilder: (_, a, _) => FadeTransition(opacity: a, child: _PageViewer(pages: d.pages, initial: i, title: tr(kind.label))),
                  )),
                  child: Hero(
                    tag: d.pages[i],
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(DL.rButton),
                      child: Image.file(File(d.pages[i]), width: 72, height: 92, fit: BoxFit.cover, cacheWidth: 216,
                          errorBuilder: (_, _, _) => Container(width: 72, color: DL.skeleton)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

/// Full-screen pages on ink, pinch to zoom, swipe between pages.
class _PageViewer extends StatefulWidget {
  const _PageViewer({required this.pages, required this.initial, required this.title});
  final List<String> pages;
  final int initial;
  final String title;

  @override
  State<_PageViewer> createState() => _PageViewerState();
}

class _PageViewerState extends State<_PageViewer> {
  late final _pc = PageController(initialPage: widget.initial);
  late int _page = widget.initial;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DL.ink,
      appBar: AppBar(
        backgroundColor: DL.ink,
        foregroundColor: DL.onDark,
        iconTheme: const IconThemeData(color: DL.onDark),
        titleTextStyle: DLText.section.copyWith(color: DL.onDark),
        title: Text(widget.pages.length > 1 ? '${widget.title} · ${_page + 1}/${widget.pages.length}' : widget.title),
      ),
      body: PageView.builder(
        controller: _pc,
        itemCount: widget.pages.length,
        onPageChanged: (i) => setState(() => _page = i),
        itemBuilder: (_, i) => InteractiveViewer(
          maxScale: 5,
          child: Center(child: Hero(tag: widget.pages[i], child: Image.file(File(widget.pages[i])))),
        ),
      ),
    );
  }
}
