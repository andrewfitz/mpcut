# Still image fixtures

The 32×32 patches share an RGB gradient with a half-transparent right half in the alpha-capable formats. The RGB values at (x, y) are (8x, 8y, 240). The alpha values are 255 for x < 16 and 128 otherwise. The PNG was generated directly, the JPEG, TIFF, AVIF and HEIC with macOS sips, and the lossless WebP with cwebp.

The unchanged JPEG XL fixtures come from libjxl/testdata, revision 73695d303670c90e4d506ea89d9901b081385089. They are distributed under Creative Commons Attribution 4.0. [PQ gradient](https://github.com/libjxl/testdata/blob/73695d303670c90e4d506ea89d9901b081385089/jxl/pq_gradient.jxl) · [Extended-size container](https://github.com/libjxl/testdata/blob/73695d303670c90e4d506ea89d9901b081385089/jxl/boxes/square-extended-size-container.jxl) · [License](https://github.com/libjxl/testdata/blob/73695d303670c90e4d506ea89d9901b081385089/LICENSE)

The gain-map JPEG and HEIC are original two-patch Core Image fixtures. Their SDR base has linear neutral levels 0.5 and 1.0. The HDR alternate has linear neutral levels 0.5 and 4.0. Core Image embedded an ISO gain map in each file.

The Apple gain-map HEIC is an original 64×64 Image I/O fixture written the way an iPhone writes one: an 8-bit sRGB base with linear neutral levels 0.5 (left half) and 1.0 (right half), an Apple HDR gain map (`kCGImageAuxiliaryDataTypeHDRGainMap`, `HDRGainMapVersion` 65536) of 0 and 1, and Apple maker tags 33 and 48 both 1.0, which give a headroom of 4. Its HDR rendition holds 0.5 and 4.0, like the ISO fixtures, and it has no ISO gain map.

The tagged 10-bit AVIF fixtures contain neutral limited-range patches at signal levels of approximately 0.58 and 0.75, with two additional HLG highlights at 0.86 and 0.96. Each AV1 image uses BT.2020 primaries and a BT.2020 non-constant luminance matrix, with PQ or HLG transfer.

The animated WebP is an original two-frame test. The unchanged animated JPEG XL is from the same libjxl revision and license as the other JPEG XL fixtures. [Cropped traffic light](https://github.com/libjxl/testdata/blob/73695d303670c90e4d506ea89d9901b081385089/jxl/blending/cropped_traffic_light.jxl)
