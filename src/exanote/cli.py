"""CLI entry points for the local app and batch processing."""

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(prog="exanote")
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="Open the local app")
    serve.add_argument("--port", type=int, default=8765)
    process = commands.add_parser("process", help="Process an existing recording")
    process.add_argument("audio", type=Path)
    process.add_argument("--output", type=Path)
    commands.add_parser("mcp", help="Serve meeting notes to MCP clients over stdio (read-only)")
    args = parser.parse_args()
    if args.command == "serve":
        import uvicorn

        uvicorn.run("exanote.server:app", host="127.0.0.1", port=args.port)
    elif args.command == "mcp":
        from .mcp_server import main as serve_mcp

        serve_mcp()
    else:
        from .pipeline import process_recording

        result = process_recording(args.audio)
        if args.output:
            args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            print(result["notes"])


if __name__ == "__main__":
    main()
