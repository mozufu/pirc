import { fixture } from './document_live_svg_fixture.mjs';
import { captureLiveAssetCases } from './capture_document_live_asset_cases.mjs';
await captureLiveAssetCases(fixture, {
  imagePath: '/photo.svg',
  imageMime: 'image/svg+xml',
  outputURL: new URL('../../../../packages/pirc_render/test/fixtures/parity/document-live-svg-chromium153.json', import.meta.url),
});
