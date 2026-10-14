import 'package:flutter_scene/build_hooks.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // flutter_scene:init:start
    // Import .glb and .fscene sources under assets/, loadable by source path
    // with loadScene (and hot-reloadable). A no-op when there are no scenes.
    //
    // The office's models (assets/models/*.glb) are imported at run time instead (world/models.dart),
    // the .glb files themselves listed as assets, so none are handed to the build-time importer here:
    // it would ship each one a second time.
    buildScenes(buildInput: input, buildOutput: output, inputFilePaths: const []);
    // Compile .fmat materials under assets/, loadable by source path with
    // loadFmatMaterial (and hot-reloadable). A no-op when there are none.
    await buildMaterials(buildInput: input, buildOutput: output);
    // flutter_scene:init:end
  });
}
