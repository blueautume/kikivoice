"""Verified display renderings bound to an unchanged canonical consent manifest."""
import hashlib
import hmac
import json
from pathlib import Path


def load_english(path, canonical):
    """Return only a complete matching rendering; never replace receipt fields."""
    try:
        data = Path(path).read_bytes()
        if not data or len(data) > 512 * 1024:
            raise ValueError("Invalid legal rendering size")
        value = json.loads(data)
        expected = (set(canonical) - {"documentHash"}) | {"locale", "sourceDocumentHash", "renderingHash"}
        if not isinstance(value, dict) or set(value) != expected:
            raise ValueError("Invalid legal rendering fields")
        if value["locale"] != "en" or value["sourceDocumentHash"] != canonical["documentHash"]:
            raise ValueError("Legal rendering is not bound to the current consent manifest")
        for key in ("schemaVersion", "privacyVersion", "termsVersion", "updatedAt", "minimumAge"):
            if value[key] != canonical[key]:
                raise ValueError("Legal rendering versions do not match")
        if (set(value["operator"]) != {"name", "type", "email"}
                or not all(isinstance(v, str) and v.strip() for v in value["operator"].values())
                or value["operator"]["email"] != canonical["operator"]["email"]):
            raise ValueError("Legal rendering operator does not match")
        if len(value["documents"]) != len(canonical["documents"]):
            raise ValueError("Incomplete legal rendering")
        for translated, source in zip(value["documents"], canonical["documents"]):
            if (set(translated) != set(source) or translated["id"] != source["id"]
                    or translated["version"] != source["version"]
                    or not isinstance(translated["title"], str) or not translated["title"].strip()
                    or len(translated["sections"]) != len(source["sections"])):
                raise ValueError("Incomplete legal rendering document")
            for section, original in zip(translated["sections"], source["sections"]):
                if (set(section) != {"title", "paragraphs"}
                        or not isinstance(section["title"], str) or not section["title"].strip()
                        or len(section["paragraphs"]) != len(original["paragraphs"])
                        or any(not isinstance(p, str) or not p.strip() for p in section["paragraphs"])):
                    raise ValueError("Incomplete legal rendering paragraph")
        content = json.dumps({k: v for k, v in value.items() if k != "renderingHash"},
                             sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        if not isinstance(value["renderingHash"], str) or not hmac.compare_digest(hashlib.sha256(content).hexdigest(), value["renderingHash"]):
            raise ValueError("Legal rendering checksum mismatch")
        return value
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        raise ValueError("A complete English legal rendering bound to the canonical manifest is required") from error
