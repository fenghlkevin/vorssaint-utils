# Bundled proxy core

Mihomo v1.19.31, official source: https://github.com/MetaCubeX/mihomo/tree/v1.19.31
License: GPL-3.0 (LICENSE.txt). No Mihomo source modifications.

Run `bash Tools/prepare-proxy-core.sh` from the repository root to download the
official Darwin arm64 binary. Both archive and unmodified binary hashes are pinned.
`build.sh --dev` prepares it automatically. Current app packaging targets arm64.

The build signs the bundled binary and updates its bundled manifest hash after
signing. The source manifest records the original upstream binary hash. Runtime
verification checks the packaged executable against that packaged manifest.

The binary is not committed. To rebuild Mihomo from source, use the tagged source
and its Makefile/build workflow. Keep corresponding source and this license
available when distributing the combined GPL application.
