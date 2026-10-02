#!/usr/bin/env python3
"""Check repository-local Markdown links and image paths without network access."""
import re
from pathlib import Path
from urllib.parse import unquote, urlsplit

root = Path(__file__).resolve().parent.parent
documents = [*root.glob("*.md"), *root.glob("docs/**/*.md"), *root.glob(".github/**/*.md")]
errors = []
for document in documents:
    content = document.read_text()
    links = re.findall(r"\]\(([^)\s]+)(?:\s+[^)]*)?\)", content)
    links += re.findall(r'''(?:src|href)=["']([^"']+)["']''', content)
    for link in links:
        parsed = urlsplit(link.strip("<>"))
        if parsed.scheme or parsed.netloc or not parsed.path:
            continue
        target = (document.parent / unquote(parsed.path)).resolve()
        if not target.is_relative_to(root) or not target.exists():
            errors.append(f"{document.relative_to(root)}: missing local target {link}")
if errors:
    raise SystemExit("\n".join(errors))
print(f"Local links and images checked in {len(documents)} Markdown files.")
