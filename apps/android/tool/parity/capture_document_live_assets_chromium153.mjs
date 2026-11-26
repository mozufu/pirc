import * as fixture from './document_live_assets_fixture.mjs';
import { captureLiveAssetCases } from './capture_document_live_asset_cases.mjs';
await captureLiveAssetCases(fixture, {
  outputURL: new URL('../../../../packages/pirc_render/test/fixtures/parity/document-live-assets-chromium153.json', import.meta.url),
});
