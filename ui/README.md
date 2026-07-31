# triage_ui

Flutter Web frontend for sentry-ai-triage. Normally you don't run it
directly — `dart run bin/serve.dart` at the repo root serves the built UI.

Development (hot reload against a running backend):

```bash
flutter run -d chrome --dart-define=API_BASE=http://localhost:8787
```

Build (output is served by the backend):

```bash
flutter build web
```
