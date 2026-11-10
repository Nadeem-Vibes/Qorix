#!/usr/bin/env python3
"""Deterministic LSP server used by tests/lsp_e2e_runner.gd.

It implements just enough of the protocol for Qorix's client and manager
tests: initialize, full-text document sync, diagnostics, hover, completion,
definition, references, formatting, rename, code actions (including
codeAction/resolve), executeCommand and signature help. Every message is
mirrored to a JSONL transcript so a failed test can show exactly what the
editor sent.

Usage:
    python fake_lsp_server.py --transcript=C:/tmp/transcript.jsonl
"""

import json
import os
import re
import sys
import urllib.parse


def path_to_uri(path):
    normalized = path.replace("\\", "/")
    if normalized.startswith("//"):
        return "file:" + urllib.parse.quote(normalized, safe="/:")
    if not normalized.startswith("/"):
        normalized = "/" + normalized
    return "file://" + urllib.parse.quote(normalized, safe="/:")


def uri_to_path(uri):
    parsed = urllib.parse.urlparse(uri)
    path = urllib.parse.unquote(parsed.path)
    if parsed.netloc:
        path = "//" + parsed.netloc + path
    if re.match(r"^/[A-Za-z]:", path):
        path = path[1:]
    return path


class FakeServer:
    def __init__(self, transcript_path=""):
        self.transcript_path = transcript_path
        self.documents = {}
        self.root_path = ""
        self.main_uri = ""
        self.settings = {}
        self.shutdown_requested = False
        self.stderr = sys.stderr
        try:
            self.stderr.reconfigure(encoding="utf-8")
        except Exception:
            pass

    def log(self, text):
        self.stderr.write("[fake-lsp] " + str(text) + "\n")
        self.stderr.flush()

    def transcript(self, direction, message):
        if not self.transcript_path:
            return
        try:
            with open(self.transcript_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"dir": direction, "message": message}) + "\n")
        except Exception as error:
            self.log("transcript failed: " + str(error))

    def read_message(self):
        headers = {}
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                return None
            if line in (b"\r\n", b"\n"):
                break
            try:
                name, value = line.decode("utf-8").split(":", 1)
            except ValueError:
                continue
            headers[name.strip().lower()] = value.strip()
        try:
            length = int(headers.get("content-length", "0"))
        except ValueError:
            return None
        if length <= 0:
            return None
        body = sys.stdin.buffer.read(length)
        if not body:
            return None
        try:
            message = json.loads(body.decode("utf-8"))
        except Exception as error:
            self.log("bad JSON: " + str(error))
            return None
        self.transcript("in", message)
        return message

    def send(self, message):
        self.transcript("out", message)
        body = json.dumps(message).encode("utf-8")
        sys.stdout.buffer.write(
            ("Content-Length: %d\r\n\r\n" % len(body)).encode("ascii") + body
        )
        sys.stdout.buffer.flush()

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)

    def result(self, request_id, value):
        self.send({"jsonrpc": "2.0", "id": request_id, "result": value})

    def error(self, request_id, code, text):
        self.send({
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": code, "message": text},
        })

    # ── helpers ────────────────────────────────────────────────────────────

    def uri_for(self, *parts):
        return path_to_uri(os.path.join(self.root_path, *parts))

    def text_for_uri(self, uri):
        if uri in self.documents:
            return self.documents[uri]
        path = uri_to_path(uri)
        try:
            with open(path, "r", encoding="utf-8", newline="") as handle:
                return handle.read()
        except Exception:
            return ""

    def line_at(self, text, line):
        lines = text.split("\n")
        return lines[line] if 0 <= line < len(lines) else ""

    def word_at(self, text, position):
        line = self.line_at(text, int(position.get("line", 0)))
        column = max(0, int(position.get("character", 0)))
        if column > len(line):
            column = len(line)
        left = column
        while left > 0 and (line[left - 1].isalnum() or line[left - 1] == "_"):
            left -= 1
        right = column
        while right < len(line) and (line[right].isalnum() or line[right] == "_"):
            right += 1
        return line[left:right]

    def whole_document_edit(self, uri, new_text):
        text = self.text_for_uri(uri)
        lines = text.split("\n")
        return {
            "range": {
                "start": {"line": 0, "character": 0},
                "end": {"line": len(lines) - 1, "character": len(lines[-1])},
            },
            "newText": new_text,
        }

    def diagnostics_for(self, uri, text):
        out = []
        for index, line in enumerate(text.split("\n")):
            if "missing_symbol" in line:
                out.append({
                    "range": {
                        "start": {"line": index, "character": line.find("missing_symbol")},
                        "end": {"line": index, "character": line.find("missing_symbol") + len("missing_symbol")},
                    },
                    "severity": 1,
                    "message": "Undefined name 'missing_symbol'",
                    "source": "Pyright",
                    "code": "reportUndefinedVariable",
                })
            if "TODO" in line:
                out.append({
                    "range": {
                        "start": {"line": index, "character": line.find("TODO")},
                        "end": {"line": index, "character": line.find("TODO") + 4},
                    },
                    "severity": 2,
                    "message": "TODO left in code",
                    "source": "Fake",
                })
        return out

    def publish_diagnostics(self, uri):
        text = self.text_for_uri(uri)
        self.notify("textDocument/publishDiagnostics", {
            "uri": uri,
            "version": 1,
            "diagnostics": self.diagnostics_for(uri, text),
        })

    # ── protocol ───────────────────────────────────────────────────────────

    def initialize(self, params):
        root_uri = params.get("rootUri") or params.get("rootPath") or ""
        if root_uri and not str(root_uri).startswith("file:"):
            self.root_path = str(root_uri).replace("\\", "/")
        elif root_uri:
            self.root_path = uri_to_path(str(root_uri))
        self.settings = params.get("initializationOptions") or {}
        return {
            "capabilities": {
                "textDocumentSync": 1,
                "hoverProvider": True,
                "definitionProvider": True,
                "referencesProvider": True,
                "documentFormattingProvider": True,
                "renameProvider": True,
                "codeActionProvider": {
                    "codeActionKinds": ["quickfix", "refactor"],
                    "resolveProvider": True,
                },
                "signatureHelpProvider": {"triggerCharacters": ["(", ","]},
                "completionProvider": {
                    "triggerCharacters": [".", "("],
                    "resolveProvider": False,
                },
                "workspace": {
                    "workspaceFolders": {"supported": True, "changeNotifications": True},
                },
            },
            "serverInfo": {"name": "Fake LSP", "version": "1.0"},
        }

    def handle_request(self, message):
        method = str(message.get("method", ""))
        request_id = message.get("id")
        params = message.get("params") or {}

        if method == "initialize":
            self.result(request_id, self.initialize(params))
            return
        if method == "shutdown":
            self.shutdown_requested = True
            self.result(request_id, None)
            return
        if method == "workspace/executeCommand":
            command = str(params.get("command", ""))
            uri = self.main_uri or next(iter(self.documents), "")
            text = self.text_for_uri(uri)
            if command == "fake.explain":
                self.result(request_id, {"changes": {
                    uri: [self.whole_document_edit(uri, text.rstrip() + "\n# explained\n")],
                }})
                return
            if command == "fake.applyEdit":
                edit = {"changes": {
                    uri: [self.whole_document_edit(uri, text.rstrip() + "\n# applied by server\n")],
                }}
                self.send({
                    "jsonrpc": "2.0",
                    "id": 700,
                    "method": "workspace/applyEdit",
                    "params": {"label": "Fake server edit", "edit": edit},
                })
                self.result(request_id, None)
                return
            self.result(request_id, None)
            return

        if method == "textDocument/hover":
            uri = str(params.get("textDocument", {}).get("uri", ""))
            word = self.word_at(self.text_for_uri(uri), params.get("position", {}))
            self.result(request_id, {
                "contents": {
                    "kind": "markdown",
                    "value": "```python\ndef %s(value: str) -> str\n```\n\n**%s** greets a person. [Docs](https://example.test/%s)" % (word or "greet", word or "greet", word or "greet"),
                },
                "range": {
                    "start": {"line": 0, "character": 4},
                    "end": {"line": 0, "character": 9},
                },
            })
            return

        if method == "textDocument/completion":
            self.result(request_id, {
                "isIncomplete": False,
                "items": [
                    {
                        "label": "greet",
                        "kind": 3,
                        "detail": "def greet(name: str) -> str",
                        "documentation": {"kind": "markdown", "value": "**Greet** a person."},
                        "insertTextFormat": 2,
                        "insertText": "greet(${1:name})",
                    },
                    {"label": "greeting", "kind": 6, "insertText": "greeting"},
                    {"label": "print", "kind": 3, "insertText": "print()"},
                ],
            })
            return

        if method == "textDocument/definition":
            uri = self.main_uri or str(params.get("textDocument", {}).get("uri", ""))
            self.result(request_id, [{
                "uri": uri,
                "range": {
                    "start": {"line": 0, "character": 4},
                    "end": {"line": 0, "character": 9},
                },
            }])
            return

        if method == "textDocument/references":
            uri = self.main_uri or str(params.get("textDocument", {}).get("uri", ""))
            helper = self.uri_for("helper.py")
            self.result(request_id, [
                {
                    "uri": uri,
                    "range": {
                        "start": {"line": 5, "character": 10},
                        "end": {"line": 5, "character": 15},
                    },
                },
                {
                    "uri": helper,
                    "range": {
                        "start": {"line": 3, "character": 11},
                        "end": {"line": 3, "character": 16},
                    },
                },
            ])
            return

        if method == "textDocument/formatting":
            uri = self.main_uri or str(params.get("textDocument", {}).get("uri", ""))
            text = self.text_for_uri(uri).replace("\r\n", "\n").replace("Hello", "Hi")
            if not text.endswith("\n"):
                text += "\n"
            self.result(request_id, [self.whole_document_edit(uri, text)])
            return

        if method == "textDocument/rename":
            new_name = str(params.get("newName", "renamed"))
            uris = [self.main_uri] if self.main_uri else []
            helper = self.uri_for("helper.py")
            if os.path.isfile(uri_to_path(helper)):
                uris.append(helper)
            changes = {}
            for candidate in uris:
                text = self.text_for_uri(candidate)
                old_name = self.word_at(text, params.get("position", {}))
                if old_name and old_name == new_name:
                    continue
                edits = []
                if old_name:
                    for match in re.finditer(r"\b" + re.escape(old_name) + r"\b", text):
                        start = text.count("\n", 0, match.start())
                        line_start = text.rfind("\n", 0, match.start()) + 1
                        end_line_start = text.rfind("\n", 0, match.end()) + 1
                        edits.append({
                            "range": {
                                "start": {"line": start, "character": match.start() - line_start},
                                "end": {
                                    "line": text.count("\n", 0, match.end()),
                                    "character": match.end() - end_line_start,
                                },
                            },
                            "newText": new_name,
                        })
                if edits:
                    changes[candidate] = edits
            self.result(request_id, {"changes": changes})
            return

        if method == "textDocument/codeAction":
            uri = self.main_uri or str(params.get("textDocument", {}).get("uri", ""))
            text = self.text_for_uri(uri)
            self.result(request_id, [
                {
                    "title": "Add a helper comment",
                    "kind": "quickfix",
                    "isPreferred": True,
                    "edit": {"changes": {
                        uri: [self.whole_document_edit(uri, text.rstrip() + "\n# helper action\n")],
                    }},
                },
                {
                    "title": "Run the fake explain command",
                    "kind": "refactor",
                    "command": {
                        "title": "Explain",
                        "command": "fake.explain",
                        "arguments": [],
                    },
                },
                {
                    "title": "Ask the server to apply an edit",
                    "kind": "refactor",
                    "command": {
                        "title": "Apply",
                        "command": "fake.applyEdit",
                        "arguments": [],
                    },
                },
                {
                    "title": "Resolve a delayed fix",
                    "kind": "quickfix",
                    "data": {"suffix": "# resolved action"},
                },
            ])
            return

        if method == "codeAction/resolve":
            uri = self.main_uri or ""
            if not uri:
                self.error(request_id, -32602, "No main document for codeAction/resolve.")
                return
            text = self.text_for_uri(uri)
            data = params.get("data") or {}
            suffix = str(data.get("suffix", "# resolved action"))
            self.result(request_id, {
                "title": str(params.get("title", "Resolved action")),
                "kind": str(params.get("kind", "quickfix")),
                "edit": {"changes": {
                    uri: [self.whole_document_edit(uri, text.rstrip() + "\n" + suffix + "\n")],
                }},
            })
            return

        if method == "textDocument/signatureHelp":
            self.result(request_id, {
                "signatures": [{
                    "label": "greet(name: str) -> str",
                    "documentation": {"kind": "markdown", "value": "Greet someone."},
                    "parameters": [{
                        "label": "name: str",
                        "documentation": "The person to greet.",
                    }],
                }],
                "activeSignature": 0,
                "activeParameter": 0,
            })
            return

        self.error(request_id, -32601, "Unsupported method: " + method)

    def handle_notification(self, message):
        method = str(message.get("method", ""))
        params = message.get("params") or {}

        if method == "initialized":
            self.log("initialized")
            self.notify("window/logMessage", {
                "type": 3,
                "message": "Fake LSP is ready.",
            })
            self.send({
                "jsonrpc": "2.0",
                "id": 100,
                "method": "workspace/configuration",
                "params": {"items": [{"section": "python"}, {"section": "missing"}]},
            })
            return

        if method == "workspace/didChangeConfiguration":
            self.settings = params.get("settings", {})
            return

        if method == "textDocument/didOpen":
            document = params.get("textDocument", {})
            uri = str(document.get("uri", ""))
            self.main_uri = uri
            self.documents[uri] = str(document.get("text", ""))
            self.publish_diagnostics(uri)
            return

        if method == "textDocument/didChange":
            document = params.get("textDocument", {})
            uri = str(document.get("uri", ""))
            changes = params.get("contentChanges", [])
            text = str(changes[-1].get("text", "")) if changes else ""
            self.documents[uri] = text
            if "# crash" in text:
                self.log("crashing on request")
                os._exit(7)
            self.publish_diagnostics(uri)
            return

        if method == "textDocument/didClose":
            uri = str(params.get("textDocument", {}).get("uri", ""))
            self.documents.pop(uri, None)
            return

        if method == "exit":
            self.log("exiting")
            sys.exit(0)

    def handle_response(self, message):
        # workspace/configuration and workspace/applyEdit responses land here.
        self.log("response for id " + str(message.get("id")))
        if message.get("id") == 100:
            self.settings = message.get("result", self.settings)

    def run(self):
        self.log("started")
        while True:
            message = self.read_message()
            if message is None:
                self.log("stdin closed")
                return 0
            if "method" in message and "id" in message:
                self.handle_request(message)
            elif "method" in message:
                self.handle_notification(message)
            else:
                self.handle_response(message)


def main():
    transcript = ""
    for argument in sys.argv[1:]:
        if argument.startswith("--transcript="):
            transcript = argument.split("=", 1)[1]
    server = FakeServer(transcript)
    return server.run()


if __name__ == "__main__":
    sys.exit(main())
