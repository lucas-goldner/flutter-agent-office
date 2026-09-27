// A <video> as a scene texture: each new video frame is copied straight into a GPU texture with
// texSubImage2D on flutter_scene's own WebGL2 context (the old THREE.VideoTexture). No readback,
// no canvas in between.
//
// flutter_scene 0.23 has no public way in: ExternalTexture needs platform texture ids, which the
// web doesn't have, and Texture.fromImage can't cross from the framework's GL context. But its
// WebGL backend's GpuContext exposes `gl` and its Texture `glTexture`, so this reaches into that
// backend (package:flutter_scene/src/gpu/web) and does the upload itself, on the same reserved
// texture unit the backend uses for its own uploads so no pass's bindings are disturbed.
// ignore_for_file: implementation_imports

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/gpu/web/_gpu.dart' as webgpu;
import 'package:web/web.dart' as web;

class VideoTexture implements TextureSource {
  VideoTexture(this.video, {this.fallback}) {
    _watchFrames();
  }

  final web.HTMLVideoElement video;

  /// What to show until the video has its first frame.
  TextureSource? fallback;
  webgpu.Texture? _tex;
  bool _fresh = true;
  bool _disposed = false;
  bool _hasFrameCallback = false;
  int _lastUpload = 0;

  static final _sampler = gpu.SamplerOptions(
    minFilter: gpu.MinMagFilter.linear,
    magFilter: gpu.MinMagFilter.linear,
    widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
    heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
  );

  /// Whether the video has a frame to show yet.
  bool get ready => video.readyState >= 2 && video.videoWidth > 0 && video.videoHeight > 0;

  /// Marks a new frame on each one the video presents (requestVideoFrameCallback), so a frame is
  /// uploaded once however many passes sample it. Without it, uploads run at most 30 times a second.
  void _watchFrames() {
    if (!video.has('requestVideoFrameCallback')) return;
    _hasFrameCallback = true;
    void onFrame(JSAny _, JSAny _) {
      if (_disposed) return;
      _fresh = true;
      video.requestVideoFrameCallback(onFrame.toJS);
    }

    video.requestVideoFrameCallback(onFrame.toJS);
  }

  @override
  gpu.Texture? get sampledTexture {
    if (_disposed || !ready) return _current;
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = _hasFrameCallback ? _fresh : now - _lastUpload >= 33;
    if (due || _tex == null) _upload(now);
    return _current;
  }

  /// The last uploaded frame, or the fallback's texture before there is one.
  gpu.Texture? get _current => _uploaded ? (_tex as Object?) as gpu.Texture? : fallback?.sampledTexture;
  bool _uploaded = false;

  void _upload(int now) {
    final ctx = webgpu.gpuContext;
    final gl = ctx.gl;
    final w = video.videoWidth, h = video.videoHeight;
    var tex = _tex;
    if (tex == null || tex.width != w || tex.height != h) {
      final old = tex?.glTexture;
      if (old != null) gl.deleteTexture(old);
      tex = _tex = ctx.createTexture(webgpu.StorageMode.hostVisible, w, h);
      _uploaded = false;
    }
    // The backend's setup unit: the last one, above any a render pass binds.
    gl.activeTexture(web.WebGL2RenderingContext.TEXTURE0 + (_setupUnit ??= _lastUnit(gl)));
    gl.bindTexture(web.WebGL2RenderingContext.TEXTURE_2D, tex.glTexture);
    try {
      gl.texSubImage2D(
        web.WebGL2RenderingContext.TEXTURE_2D,
        0,
        0,
        0,
        web.WebGL2RenderingContext.RGBA.toJS,
        web.WebGL2RenderingContext.UNSIGNED_BYTE.toJS,
        video,
      );
      _fresh = false;
      _uploaded = true;
      _lastUpload = now;
    } catch (_) {
      // No frame decoded yet: try again next draw.
    }
  }

  static int? _setupUnit;
  static int _lastUnit(web.WebGL2RenderingContext gl) {
    final max = gl.getParameter(web.WebGL2RenderingContext.MAX_COMBINED_TEXTURE_IMAGE_UNITS);
    return (max != null && max.isA<JSNumber>() ? (max as JSNumber).toDartInt : 32) - 1;
  }

  @override
  gpu.SamplerOptions get sampledSampler => _uploaded ? _sampler : (fallback?.sampledSampler ?? _sampler);

  /// The video has a new source: show the fallback until its first frame, not the old one's last.
  void restart() {
    _uploaded = false;
    _fresh = true;
  }

  void dispose() {
    _disposed = true;
    final t = _tex?.glTexture;
    if (t != null) webgpu.gpuContext.gl.deleteTexture(t);
    _tex = null;
    _uploaded = false;
  }
}
