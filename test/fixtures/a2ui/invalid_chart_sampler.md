Here are two more samplers: one for charts and progress, and one for the native diagram component families.

```a2ui Charts and progress
{"version":"v0.9.1","createSurface":{"surfaceId":"demo-charts","catalogId":"https://lemieux.dev/a2ui/terminal/v1"}}
{"version":"v0.9.1","updateComponents":{"surfaceId":"demo-charts","components":[{"id":"root","component":"Column","children":["title","progress","sparkline","bars"],"gap":1},{"id":"title","component":"Text","text":"Charts and progress"},{"id":"progress","component":"ProgressBar","label":"Build complete","value":72},{"id":"sparkline","component":"Sparkline","label":"Requests","values":[3,5,4,8,7,10],"sampleRate":"1m","unit":"req/s"},{"id":"bars","component":"BarChart","title":"Tasks by state","labels":["Done","Active","Queued"],"values":[12,4,3]}]}}
```

```a2ui Diagram families
{"version":"v0.9.1","createSurface":{"surfaceId":"demo-families","catalogId":"https://lemieux.dev/a2ui/terminal/v1"}}
{"version":"v0.9.1","updateComponents":{"surfaceId":"demo-families","components":[{"id":"root","component":"Column","children":["flow","state","sequence"],"gap":1},{"id":"flow","component":"MermaidDiagram","source":"flowchart LR\n  Input --> Process --> Output"},{"id":"state","component":"MermaidDiagram","source":"stateDiagram-v2\n  [*] --> Ready\n  Ready --> Running: start\n  Running --> [*]: finish"},{"id":"sequence","component":"MermaidDiagram","source":"sequenceDiagram\n  User->>App: Request\n  App-->>User: Response"}]}}
```
