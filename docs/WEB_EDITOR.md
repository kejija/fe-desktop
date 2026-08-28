# Stock web-editor packaging

`npm run stage:web-editor` downloads the exact web-editor artifact named in `godot-version.lock.json`, verifies it against Godot's SHA-512 manifest, and extracts it under the ignored `dist/web-editor` directory.

The staging step creates `index.html` from the official shell and applies two narrowly checked bootstrap substitutions:

1. Fetch `/project-manifest.json`, verify each project file's SHA-256 with Web Crypto, and copy it into a versioned `/home/web_user/FutureEngineDesktop-<digest>` directory.
2. Launch `--editor --path` for that directory instead of opening the project manager.

The script refuses to patch the shell if the expected official startup markers change. It never changes or recompiles `godot.editor.wasm`.

Run the staged editor through the gateway:

```bash
npm run stage:web-editor
FE_BACKEND_MODE=mock FE_WEB_EDITOR_ROOT=dist/web-editor npm run gateway
```

Then open `http://127.0.0.1:8142/editor/`. The gateway supplies COOP, COEP, CORP, and same-origin project/API routes required by the threaded editor build. The versioned project directory and Godot's `/home/web_user` persistent mount survive browser reloads through IndexedDB.
