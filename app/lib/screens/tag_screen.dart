import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../config.dart';
import '../l10n.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'onboarding_complete.dart';

/// The owner's tag: the QR to print or stick on the windshield.
class TagScreen extends StatefulWidget {
  const TagScreen({super.key, this.firstTime = false});
  final bool firstTime;

  @override
  State<TagScreen> createState() => _TagScreenState();
}

class _TagScreenState extends State<TagScreen> {
  final _sticker = GlobalKey();
  bool _rendering = false;

  bool get firstTime => widget.firstTime;

  /// The sticker as a PNG, for WhatsApp or a print shop.
  Future<void> _shareImage(String car) async {
    setState(() => _rendering = true);
    try {
      final boundary = _sticker.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 4);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(png, mimeType: 'image/png', name: 'connect-tag.png')],
          fileNameOverrides: ['connect-tag.png'],
          text: tr('My Connect tag for the {car}. Print it about 8 cm wide.', {'car': car}),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _rendering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final tag = s.tag;
    final v = s.vehicle;
    if (tag == null || v == null) {
      return const Scaffold(
        body: Center(child: SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5))),
      );
    }

    return Scaffold(
      appBar: firstTime ? null : AppBar(title: Text(tr('Your tag'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: revealAll([
            if (firstTime) ...[
              const SizedBox(height: 20),
              Label(tr('Step 3 of 3')),
              const SizedBox(height: 8),
              Text(tr('Your tag is ready'), style: DLText.display),
              const SizedBox(height: 10),
              Text(tr('Stick it on the inside of your windshield, facing out.'), style: DLText.body.copyWith(color: DL.muted)),
              const SizedBox(height: 24),
            ],
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: RepaintBoundary(
                  key: _sticker,
                  child: TagSticker(code: tag.code, active: tag.active),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (!tag.active)
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Tone.neutral.bg,
                  borderRadius: BorderRadius.circular(DL.rCard),
                  border: Border.all(color: DL.lineStrong),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.pause_circle_outline, color: DL.muted),
                    const SizedBox(width: 10),
                    Expanded(child: Text(tr('Paused. People who scan it see "Tag not found".'), style: DLText.body.copyWith(height: 1.45))),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
                    icon: _rendering
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.image_outlined),
                    label: Text(tr('Sticker image')),
                    onPressed: _rendering ? null : () => _shareImage('${v.make} ${v.model}'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
                    icon: const Icon(Icons.print_outlined),
                    label: Text(tr('How to print')),
                    onPressed: () => showModalBottomSheet(context: context, showDragHandle: true, builder: (_) => const _PrintHelp()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    icon: const Icon(Icons.link),
                    label: Text(tr('Share link')),
                    onPressed: () => SharePlus.instance.share(
                      ShareParams(
                        text: tr('Need to reach me about my {car}? Use my Connect tag: {url}', {
                          'car': '${v.make} ${v.model}',
                          'url': Config.tagUrl(tag.code),
                        }),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    icon: const Icon(Icons.volunteer_activism_outlined),
                    label: Text(tr('Protect a friend\'s car')),
                    onPressed: () => SharePlus.instance.share(
                      ShareParams(
                        text: tr(
                          'I put a Connect tag on my car: if it\'s blocking someone or the lights are on, they can message me without seeing my number. It\'s free: {url}',
                          {'url': Config.appUrl},
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            Label(tr('What people see when they scan')),
            const SizedBox(height: 12),
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (icon, text) in [
                    (Icons.directions_car_outlined, [if (v.colour != null) tr(v.colour!), v.make, v.model].join(' ')),
                    (Icons.list_alt_outlined, tr('A list of quick messages')),
                    (Icons.pin_outlined, tr('A box for the last 4 characters of your plate')),
                    (Icons.visibility_off_outlined, tr('Never your name, number or plate')),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Icon(icon, size: 20, color: DL.muted),
                          const SizedBox(width: 12),
                          Expanded(child: Text(text, style: DLText.body.copyWith(height: 1.4))),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (firstTime) ...[
              const SizedBox(height: 32),
              FilledButton(
                onPressed: () => Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const OnboardingCompleteScreen()), (r) => false),
                child: Text(tr('Done')),
              ),
            ] else if (!s.isOwner) ...[
              const SizedBox(height: 20),
              Text(tr('Only the car\'s owner can pause or replace this tag.'), style: DLText.small),
            ] else ...[
              const SizedBox(height: 32),
              Label(tr('Manage')),
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    SwitchListTile(
                      title: Text(tr('Tag active')),
                      subtitle: Text(tr('Pause it if you sell the car or remove the sticker')),
                      value: tag.active,
                      onChanged: (on) => s.setTagActive(on),
                    ),
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.autorenew_outlined),
                      title: Text(tr('Replace tag')),
                      subtitle: Text(tr('Get a new code if your sticker was damaged or misused. The old one stops working.')),
                      onTap: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: Text(tr('Replace this tag?')),
                            content: Text(tr('Your current sticker will stop working. You\'ll need to print the new one.')),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Cancel'))),
                              FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Replace'))),
                            ],
                          ),
                        );
                        if (ok == true) await s.replaceTag();
                      },
                    ),
                  ],
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// The printable sticker design, reused on Home as a preview.
class TagSticker extends StatelessWidget {
  const TagSticker({super.key, required this.code, this.active = true, this.compact = false});
  final String code;
  final bool active;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final pretty = '${code.substring(0, 4)} ${code.substring(4)}';
    // The sticker is the one ink-filled card: it has to read from outside the windshield.
    return Opacity(
      opacity: active ? 1 : 0.45,
      child: Container(
        padding: EdgeInsets.all(compact ? 12 : 24),
        decoration: BoxDecoration(color: DL.ink, borderRadius: BorderRadius.circular(compact ? DL.rButton : DL.rSheet)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!compact) ...[
              Label(tr('Scan to reach the owner'), color: DL.onDarkMuted),
              const SizedBox(height: 8),
              Text(tr('Blocking? Lights on? Being towed?'), style: DLText.section.copyWith(color: DL.onDark)),
              const SizedBox(height: 18),
            ],
            // The QR flies between the Home card and this screen.
            Hero(
              tag: 'tag-qr-$code',
              child: Container(
                padding: EdgeInsets.all(compact ? 6 : 12),
                decoration: BoxDecoration(color: DL.card, borderRadius: BorderRadius.circular(compact ? DL.rChip : DL.rCard)),
                child: QrImageView(
                  data: Config.tagUrl(code),
                  size: compact ? 92 : 210,
                  padding: EdgeInsets.zero,
                  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: DL.ink),
                  dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: DL.ink),
                ),
              ),
            ),
            SizedBox(height: compact ? 8 : 16),
            Text(
              pretty,
              style: (compact ? DLText.strong : DLText.numeral.copyWith(fontSize: 24)).copyWith(
                color: DL.onDark,
                fontFamily: 'SpaceGrotesk',
                fontWeight: FontWeight.w700,
                letterSpacing: compact ? 1.5 : 3,
              ),
            ),
            if (!compact) ...[
              const SizedBox(height: 8),
              Text(tr('Connect · your number stays private'), style: DLText.small.copyWith(color: DL.onDarkMuted)),
            ],
          ],
        ),
      ),
    );
  }
}

class _PrintHelp extends StatelessWidget {
  const _PrintHelp();
  @override
  Widget build(BuildContext context) {
    final steps = [
      tr('Tap "Sticker image" and send it to a print shop, or take a screenshot.'),
      tr('Print it about 8 cm wide at any print shop. Glossy sticker paper lasts longest.'),
      tr('Stick it inside the windshield, lower corner on the driver\'s side, facing out.'),
      tr('Scan it with another phone to check it works.'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('Printing your tag'), style: DLText.title),
          const SizedBox(height: 16),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${i + 1}',
                      style: DLText.strong.copyWith(fontFamily: 'SpaceGrotesk', color: DL.violet),
                    ),
                  ),
                  Expanded(child: Text(steps[i], style: DLText.body.copyWith(height: 1.5))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
