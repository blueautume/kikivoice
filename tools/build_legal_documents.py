#!/usr/bin/env python3
"""Build the native, API and static legal documents from one reviewed source.

Run normally to generate outputs, or --check to verify tracked outputs are current.
No network, application credentials or third-party Python packages are needed.
"""

from __future__ import annotations

import argparse
from datetime import date
from hashlib import sha256
from html import escape
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "legal/documents.json"
ENGLISH_SOURCE = ROOT / "legal/documents.en.json"
WEB_ROOT = ROOT / "website/dist"
ROUTES = {
    "privacy": "/privacy/",
    "terms": "/terms/",
    "sdk": "/privacy/sdk/",
    "permissions": "/privacy/permissions/",
}
PLACEHOLDER = re.compile(r"TODO|TBD|PLACEHOLDER|example\.(?:com|org)|待填写|待补充|请填写|运营主体名称|your[-_ ]?email|\{\{|\}\}", re.I)


def canonical(value: dict) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def validate(source: dict) -> None:
    expected = {"schemaVersion", "privacyVersion", "termsVersion", "updatedAt", "minimumAge", "operator", "documents"}
    if set(source) != expected:
        raise ValueError("Canonical document fields are incomplete or unexpected")
    if source["schemaVersion"] != 1 or source["minimumAge"] != 18:
        raise ValueError("Expected schemaVersion 1 and confirmed minimumAge 18")
    for field in ("privacyVersion", "termsVersion", "updatedAt"):
        value = source[field]
        pattern = r"\d{4}-\d{2}-\d{2}" if field == "updatedAt" else r"\d{4}-\d{2}-\d{2}(?:-r[1-9][0-9]*)?"
        if not isinstance(value, str) or not re.fullmatch(pattern, value) or date.fromisoformat(value[:10]).isoformat() != value[:10]:
            raise ValueError(f"Invalid date version: {field}")
    operator = source["operator"]
    if set(operator) != {"name", "type", "email"} or any(not isinstance(v, str) or not v.strip() for v in operator.values()):
        raise ValueError("A real operator name, type and public email are required")
    if operator["name"] in {"kiki", "KikiTalk", "开发者", "姓名", "某某", "某公司"}:
        raise ValueError("Operator must identify the confirmed natural person or legal entity")
    if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", operator["email"]):
        raise ValueError("Invalid public contact email")
    if PLACEHOLDER.search(json.dumps(source, ensure_ascii=False)):
        raise ValueError("Placeholder legal content cannot be published")
    documents = source["documents"]
    if not isinstance(documents, list) or len(documents) != 4 or {d.get("id") for d in documents} != set(ROUTES):
        raise ValueError("Exactly one privacy, terms, sdk and permissions document is required")
    for document in documents:
        if set(document) != {"id", "title", "version", "sections"}:
            raise ValueError("Unexpected document fields")
        expected_version = source["termsVersion"] if document["id"] == "terms" else source["privacyVersion"]
        if document["version"] != expected_version or not document["title"].strip() or not document["sections"]:
            raise ValueError("Document version/title/sections are invalid")
        for section in document["sections"]:
            if set(section) != {"title", "paragraphs"} or not isinstance(section["title"], str) or not section["title"].strip():
                raise ValueError("Every section needs a title and paragraphs")
            paragraphs = section["paragraphs"]
            if not isinstance(paragraphs, list) or not paragraphs or any(not isinstance(p, str) or not p.strip() for p in paragraphs):
                raise ValueError("Paragraphs must be non-empty text")
    # A policy must contain the confirmed identity, age scope and a contact path.
    privacy_text = canonical(next(d for d in documents if d["id"] == "privacy")).decode("utf-8")
    if not all(value in privacy_text for value in (operator["name"], operator["email"], "18 周岁")):
        raise ValueError("Privacy policy must disclose the confirmed operator, contact and adult scope")


URL = re.compile(r"https://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+[A-Za-z0-9/#=]")


def paragraph_html(text: str) -> str:
    parts = []
    cursor = 0
    for match in URL.finditer(text):
        parts.append(escape(text[cursor:match.start()]))
        value = match.group()
        # Only HTTPS informational links; styles, images and fonts remain local.
        parts.append(f'<a href="{escape(value, quote=True)}" rel="noreferrer">{escape(value)}</a>')
        cursor = match.end()
    parts.append(escape(text[cursor:]))
    return "".join(parts)


def page_html(document: dict, source: dict, digest: str, archived: bool) -> bytes:
    version = document["version"]
    identifier = document["id"]
    title = escape(document["title"])
    navigation = "".join(f'<a href="{route}"' + (' aria-current="page"' if key == identifier else '') + f'>{escape(next(d["title"] for d in source["documents"] if d["id"] == key).replace("kiki ", ""))}</a>' for key, route in ROUTES.items())
    sections = "".join(
        f'<section id="section-{index}"><h2>{escape(section["title"])}</h2>'
        + "".join(f'<p>{paragraph_html(paragraph)}</p>' for paragraph in section["paragraphs"])
        + "</section>"
        for index, section in enumerate(document["sections"], start=1)
    )
    contents = "".join(f'<li><a href="#section-{index}">{escape(section["title"])}</a></li>' for index, section in enumerate(document["sections"], start=1))
    archive_path = f"/legal/{version}/{identifier}/"
    location = archive_path if archived else ROUTES[identifier]
    version_note = ('此页为留存版本。<a href="' + ROUTES[identifier] + '">查看当前版本</a>。') if archived else ('<a href="' + archive_path + '">查看此版本的留存文本</a>。')
    operator = source["operator"]
    return f'''<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="theme-color" content="#101018">
  <meta name="description" content="{title}，版本 {version}。运营者：{escape(operator['name'])}（{escape(operator['type'])}）。">
  <title>{title} · {version}</title>
  <link rel="canonical" href="https://kiki.group{location}">{'' if archived else f'<link rel="alternate" hreflang="en" href="https://kiki.group/en{ROUTES[identifier]}">'}
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/legal.css">
</head>
<body>
  <a class="skip-link" href="#main">跳至正文</a>
  <header class="legal-header"><a class="brand" href="/"><img src="/favicon.svg" width="34" height="34" alt=""><span>kiki</span></a>{'' if archived else f'<a class="home-link" href="/en{ROUTES[identifier]}" lang="en">English</a>'}<a class="home-link" href="/">返回官网 ↗</a></header>
  <main id="main" class="legal-main">
    <nav class="legal-nav" aria-label="协议与说明">{navigation}</nav>
    <div class="document-header"><span class="eyebrow">协议与说明 / LEGAL</span><h1>{title}</h1><p class="metadata">版本与生效日期：{version} · 最近更新：{source['updatedAt']}</p><p class="operator">运营者：{escape(operator['name'])}（{escape(operator['type'])}） · 联系邮箱：<a href="mailto:{escape(operator['email'], quote=True)}">{escape(operator['email'])}</a></p><p class="version-note">{version_note}</p></div>
    <details class="contents"><summary>目录</summary><ol>{contents}</ol></details>
    <article class="legal-article" aria-label="{title}正文">{sections}</article>
    <aside class="document-proof"><p>文档集合校验值（SHA-256）</p><code>{digest}</code><p>用于核对应用、服务端和官网所提供的同一组协议文本，不是签名或身份证明。</p></aside>
  </main>
  <footer class="legal-footer"><a href="/">kiki · kiki.group</a><span>仅限 18 周岁及以上 · iOS 内测中</span><a href="mailto:{escape(operator['email'], quote=True)}">联系运营者</a></footer>
</body>
</html>
'''.encode("utf-8")


def validate_translation(translation: dict, source: dict, digest: str) -> None:
    """A rendering never changes the canonical receipt or its documentHash."""
    if set(translation) != set(source) | {"locale", "sourceDocumentHash"}:
        raise ValueError("Unexpected translation fields")
    if translation["locale"] != "en" or translation["sourceDocumentHash"] != digest:
        raise ValueError("English rendering must bind to the current canonical text")
    for key in ("schemaVersion", "privacyVersion", "termsVersion", "updatedAt", "minimumAge"):
        if translation[key] != source[key]:
            raise ValueError(f"English rendering must preserve {key}")
    if translation["operator"]["email"] != source["operator"]["email"]:
        raise ValueError("English operator contact must match")
    if PLACEHOLDER.search(json.dumps(translation, ensure_ascii=False)):
        raise ValueError("Placeholder English legal content cannot be published")
    originals = source["documents"]
    translated = translation["documents"]
    if len(translated) != len(originals):
        raise ValueError("English rendering must contain every document")
    for document, original in zip(translated, originals):
        if (set(document) != set(original) or document["id"] != original["id"]
                or document["version"] != original["version"]
                or not document["title"].strip()
                or len(document["sections"]) != len(original["sections"])):
            raise ValueError("English document structure must match the canonical text")
        for section, original_section in zip(document["sections"], original["sections"]):
            if (set(section) != {"title", "paragraphs"} or not section["title"].strip()
                    or len(section["paragraphs"]) != len(original_section["paragraphs"])
                    or any(not isinstance(p, str) or not p.strip() for p in section["paragraphs"])):
                raise ValueError("Every canonical paragraph needs a complete English rendering")


def english_page_html(document: dict, source: dict, rendering_hash: str, archived: bool) -> bytes:
    identifier, version = document["id"], document["version"]
    title = escape(document["title"])
    route = "/en" + ROUTES[identifier]
    archive = f"/legal/{version}/en/{identifier}/"
    location = archive if archived else route
    navigation = "".join(f'<a href="/en{path}"' + (' aria-current="page"' if key == identifier else '') + f'>{escape(next(d["title"] for d in source["documents"] if d["id"] == key).removeprefix("kikitalk "))}</a>' for key, path in ROUTES.items())
    sections = "".join(f'<section id="section-{i}"><h2>{escape(s["title"])}</h2>' + "".join(f'<p>{paragraph_html(p)}</p>' for p in s["paragraphs"]) + '</section>' for i, s in enumerate(document["sections"], 1))
    contents = "".join(f'<li><a href="#section-{i}">{escape(s["title"])}</a></li>' for i, s in enumerate(document["sections"], 1))
    version_note = f'This is an archived version. <a href="{route}">Read the current version</a>.' if archived else f'<a href="{archive}">Read the archived text for this version</a>.'
    operator = source["operator"]
    return f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="theme-color" content="#101018">
  <meta name="description" content="{title}, version {version}. Operated by {escape(operator['name'])} ({escape(operator['type'])}).">
  <title>{title} · {version}</title>
  <link rel="canonical" href="https://kiki.group{location}">
  <link rel="alternate" hreflang="zh-Hans" href="https://kiki.group{ROUTES[identifier]}">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/legal.css">
</head>
<body>
  <a class="skip-link" href="#main">Skip to content</a>
  <header class="legal-header"><a class="brand" href="/"><img src="/favicon.svg" width="34" height="34" alt=""><span>kikitalk</span></a><a class="home-link" href="{ROUTES[identifier]}" lang="zh-Hans">中文</a><a class="home-link" href="/">Website ↗</a></header>
  <main id="main" class="legal-main">
    <nav class="legal-nav" aria-label="Legal documents">{navigation}</nav>
    <div class="document-header"><span class="eyebrow">LEGAL</span><h1>{title}</h1><p class="metadata">Version and effective date: {version} · Updated: {source['updatedAt']}</p><p class="operator">Operator: {escape(operator['name'])} ({escape(operator['type'])}) · Contact: <a href="mailto:{escape(operator['email'], quote=True)}">{escape(operator['email'])}</a></p><p class="version-note">{version_note}</p></div>
    <details class="contents"><summary>Contents</summary><ol>{contents}</ol></details>
    <article class="legal-article" aria-label="{title}">{sections}</article>
    <aside class="document-proof"><p>Canonical document collection checksum (SHA-256)</p><code>{source['sourceDocumentHash']}</code><p>This English rendering is bound to the same canonical Chinese document collection and consent version. The checksum is not a signature or proof of identity.</p><p>English rendering checksum (SHA-256)</p><code>{rendering_hash}</code></aside>
  </main>
  <footer class="legal-footer"><a href="/">kikitalk · kiki.group</a><span>Ages 18 and over · iOS testing</span><a href="mailto:{escape(operator['email'], quote=True)}">Contact the operator</a></footer>
</body>
</html>
'''.encode("utf-8")


def outputs(source: dict) -> tuple[dict[Path, bytes], str]:
    validate(source)
    digest = sha256(canonical(source)).hexdigest()
    resource = canonical({**source, "documentHash": digest}) + b"\n"
    result = {
        ROOT / "ios/KikiTalk/Resources/KikiLegalDocuments.json": resource,
        ROOT / "backend/app/legal_documents.json": resource,
        ROOT / "experiments/livekit/shared/legal_documents.json": resource,
    }
    for document in source["documents"]:
        result[WEB_ROOT / ROUTES[document["id"]].strip("/") / "index.html"] = page_html(document, source, digest, False)
        result[WEB_ROOT / "legal" / document["version"] / document["id"] / "index.html"] = page_html(document, source, digest, True)
    english = json.loads(ENGLISH_SOURCE.read_text(encoding="utf-8"))
    validate_translation(english, source, digest)
    rendering_hash = sha256(canonical(english)).hexdigest()
    translated_resource = canonical({**english, "renderingHash": rendering_hash}) + b"\n"
    result.update({
        ROOT / "ios/KikiTalk/Resources/KikiLegalDocuments.en.json": translated_resource,
        ROOT / "backend/app/legal_documents.en.json": translated_resource,
        ROOT / "experiments/livekit/shared/legal_documents.en.json": translated_resource,
    })
    for document in english["documents"]:
        result[WEB_ROOT / "en" / ROUTES[document["id"]].strip("/") / "index.html"] = english_page_html(document, english, rendering_hash, False)
        result[WEB_ROOT / "legal" / document["version"] / "en" / document["id"] / "index.html"] = english_page_html(document, english, rendering_hash, True)
    return result, digest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if generated resources or pages are missing/stale")
    args = parser.parse_args()
    source = json.loads(SOURCE.read_text(encoding="utf-8"))
    expected, digest = outputs(source)
    stale = []
    for path, content in expected.items():
        if args.check:
            if not path.is_file() or path.read_bytes() != content:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.is_relative_to(WEB_ROOT / "legal") and path.exists() and path.read_bytes() != content:
                raise ValueError(f"Published legal archives are immutable; use a new revision: {path.relative_to(ROOT)}")
            path.write_bytes(content)
    if stale:
        print("Legal outputs are missing or stale:\n" + "\n".join(stale), file=sys.stderr)
        return 1
    print(f"{'Verified' if args.check else 'Generated'} {len(expected)} legal outputs; documentHash={digest}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, TypeError, KeyError, OSError) as error:
        print(f"Legal publishing validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
