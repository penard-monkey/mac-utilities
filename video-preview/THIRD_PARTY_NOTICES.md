# Third-party notices

## VLCKit

Video Preview's Quick Look extension plays media with **VLCKit 3.7.3**
(libVLC 3.0.23) by VideoLAN and the VLC authors, <https://www.videolan.org/>.

VLCKit is licensed under the **GNU Lesser General Public License, version 2.1
or later** (LGPL-2.1+). Its full text ships next to this notice as
`VLCKit-LGPL-2.1.txt` in the app's Resources, and in this repository as
`video-preview/licenses/LGPL-2.1.txt`.

The library is VideoLAN's unmodified official binary, downloaded from
<https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.7.3-319ed2c0-79128878.tar.xz>
(SHA-256 `019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d`).
Only its install name is changed so that it can be embedded as the separate,
replaceable file
`Video Preview.app/Contents/PlugIns/VideoPreviewQuickLook.appex/Contents/Frameworks/VLCKit.dylib`.
You may replace that file with your own build of a compatible VLCKit and
re-sign the bundle. VLCKit's source code is available from VideoLAN at
<https://code.videolan.org/videolan/VLCKit>.
