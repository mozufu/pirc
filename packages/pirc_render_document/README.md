# pirc_render_document

Fetched documents and the script runtime side of the renderer (tier 3 in
[plans/client.md](../../plans/client.md#rendering)). Chat content never
imports this package; hosts that show fetched documents install
`NativeDocumentRuntime` as `RenderHost.documentRuntime`.
