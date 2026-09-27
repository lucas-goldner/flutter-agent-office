// The 2D side of screen sharing: the thumbnails under the caffeine meter (#shares / .share-thumb)
// and the full-screen viewer (.modal.viewer). Each shows a live <video> as an HtmlElementView.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../ui/modal.dart';
import '../ui/theme.dart';

/// Someone's screen: who, and the stream.
typedef Share = ({String who, web.MediaStream stream});

/// A muted, autoplaying <video> of [stream], letterboxed on near-black.
class VideoView extends StatelessWidget {
  const VideoView(this.stream, {super.key});

  final web.MediaStream stream;

  @override
  Widget build(BuildContext context) => HtmlElementView.fromTagName(
    key: ValueKey(stream.id),
    tagName: 'video',
    onElementCreated: (o) {
      final v = o as web.HTMLVideoElement
        ..muted = true
        ..autoplay = true
        ..playsInline = true
        ..srcObject = stream;
      v.style
        ..width = '100%'
        ..height = '100%'
        ..objectFit = 'contain'
        ..background = '#111'
        ..display = 'block'
        ..pointerEvents = 'none';
      v.play();
    },
  );
}

/// The thumbnails of other people's screens; a click opens the viewer.
class ShareThumbs extends StatelessWidget {
  const ShareThumbs({super.key, required this.shares, required this.onWatch});

  final ValueListenable<List<Share>> shares;
  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: shares,
    builder: (context, list, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final s in list) Padding(padding: const EdgeInsets.only(bottom: 8), child: _Thumb(s, onWatch))],
    ),
  );
}

class _Thumb extends StatelessWidget {
  const _Thumb(this.share, this.onWatch);

  final Share share;
  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Watch full screen',
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onWatch,
        child: Container(
          width: 220,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Swatch.ink, width: kBorder),
            boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 4))],
          ),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The video can't take clicks (it's a platform view); the layer over it does.
                VideoView(share.stream),
                const ColoredBox(color: Colors.transparent),
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Swatch.paper,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Swatch.ink, width: 2),
                    ),
                    child: Text('🖥️ ${share.who}', style: heavy(12)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The full-screen viewer: whoever's screen [share] is, as big as the window allows.
ModalHandle openViewer(Share share) => ModalStack.instance.show(
  (modal) => ModalWindow(
    modal: modal,
    width: 1400,
    background: const Color(0xFF111111),
    bodyPadding: EdgeInsets.zero,
    scrollBody: false,
    title: Text("🖥️ ${share.who}'s screen"),
    body: LayoutBuilder(
      builder: (context, box) {
        final maxH = MediaQuery.sizeOf(context).height - 120;
        final h = (box.maxWidth * 9 / 16).clamp(120.0, maxH);
        return SizedBox(width: box.maxWidth, height: h, child: VideoView(share.stream));
      },
    ),
  ),
);
