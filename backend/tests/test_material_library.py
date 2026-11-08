import base64
import io
import json
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from sqlalchemy import update

from app.models import Membership
from migrate import migrate

PDF = (Path(__file__).resolve().parents[2] / "mobile/assets/demo/sets.pdf").read_bytes()


@pytest.fixture
def library(setup, tmp_path, monkeypatch):
    root = tmp_path / "materials"
    monkeypatch.setenv("USITY_MATERIALS_DIR", str(root))
    monkeypatch.delenv("USITY_MATERIALS_S3_BUCKET", raising=False)
    migrate(setup["url"])
    with setup["engine"].begin() as db:
        db.execute(
            update(Membership)
            .where(Membership.user_id == setup["users"]["admin2"])
            .values(role="owner")
        )

    def request(who, method="GET", suffix="", **kwargs):
        headers = dict(kwargs.pop("headers", {}))
        if who:
            headers["Authorization"] = "Bearer " + setup["users"][who]
        return setup["client"].request(
            method,
            f"/groups/{setup['group']}/materials" + suffix,
            headers=headers,
            **kwargs,
        )

    return request, root


def metadata(**fields):
    return {
        "title": "Конспект",
        "category": "Лекции",
        "subjects": ["Математика"],
        "scope": "group",
        **fields,
    }


def upload(request, who="student", filename="Лекция.pdf", content=PDF, **fields):
    header = base64.urlsafe_b64encode(
        json.dumps(metadata(filename=filename, **fields)).encode()
    ).decode()
    return request(
        who, "POST", "/files", headers={"X-Material-Metadata": header}, content=content
    )


def test_private_links_and_group_categories(library):
    call, _ = library
    assert call(None).status_code == 401
    assert call("outsider").status_code == 403
    assert "Учебники" in call("student").json()["categories"]
    assert (
        call("student", "POST", "/categories", json={"name": "Справочники"}).status_code
        == 403
    )
    assert (
        call("admin", "POST", "/categories", json={"name": "Справочники"}).status_code
        == 201
    )
    assert (
        call("admin", "POST", "/categories", json={"name": "справочники"}).status_code
        == 409
    )
    body = metadata(
        scope="personal", category="Справочники", url="https://example.test/book"
    )
    item = call("student", "POST", "/links", json=body)
    assert item.status_code == 201, item.text
    assert item.json()["status"] == "published"
    assert call("student").json()["items"] == [item.json()]
    assert call("admin").json()["items"] == []
    assert call("student2").json()["items"] == []
    assert call("admin", "DELETE", "/" + item.json()["id"]).status_code == 404
    assert call("student", "DELETE", "/" + item.json()["id"]).is_success


@pytest.mark.parametrize("role", ["admin", "admin2"])
def test_direct_publication_and_atomic_review(library, role):
    call, _ = library
    body = metadata(url="https://example.test/book")
    published = call(role, "POST", "/links", json=body).json()
    assert published["status"] == "published"
    pending = call("student", "POST", "/links", json=body).json()
    assert pending["status"] == "pending"
    assert call("student2").json()["items"] == [published]
    path = "/" + pending["id"] + "/decision"
    assert call("student", "POST", path, json={"action": "approve"}).status_code == 403

    def decide(who):
        return call(who, "POST", path, json={"action": "approve"}).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(decide, ["admin", "admin2"])) == [200, 409]
    assert {r["id"] for r in call("student2").json()["items"]} == {
        published["id"],
        pending["id"],
    }


def test_authorized_download_and_rejection_removes_blob(library):
    call, root = library
    response = upload(call)
    assert response.status_code == 201, response.text
    item = response.json()
    assert item["filename"] == "Лекция.pdf" and item["size"] == len(PDF)
    assert item["url"] is None and "blob_key" not in item
    (obj,) = root.iterdir()
    assert obj.name != item["filename"] and obj.stat().st_mode & 0o077 == 0
    path = "/" + item["id"] + "/download"
    assert call(None, suffix=path).status_code == 401
    assert call("student2", suffix=path).status_code == 404
    assert call("outsider", suffix=path).status_code == 403
    preview = call("admin", suffix=path)
    assert preview.content == PDF
    assert preview.headers["Cache-Control"] == "private, no-store"
    assert call(
        "admin", "POST", "/" + item["id"] + "/decision", json={"action": "reject"}
    ).is_success
    assert not list(root.iterdir())
    assert call("student", suffix=path).status_code == 404


@pytest.mark.parametrize(
    "url",
    [
        "file:///etc/passwd",
        "javascript:alert(1)",
        "https://u:p@example.test",
        "https://x\\@evil.test",
        "//example.test",
    ],
)
def test_invalid_links(library, url):
    call, _ = library
    assert call("student", "POST", "/links", json=metadata(url=url)).status_code == 422


@pytest.mark.parametrize(
    ("name", "content"),
    [
        ("../lecture.pdf", PDF),
        ("demo.exe", PDF),
        ("fake.pdf", b"MZ" + bytes(30)),
        ("fake.docx", b"PK\x03\x04"),
        ("note\u202egnp.pdf", PDF),
        ("lecture.doc", b"MZ" + PDF),
        ("file.svg", b"<svg/>"),
    ],
)
def test_rejects_unsafe_uploads_without_blobs(library, name, content):
    call, root = library
    assert upload(call, filename=name, content=content).status_code == 422
    assert not root.exists() or not list(root.iterdir())
    assert call("student").json()["items"] == []


def test_subject_validation_and_limits(library, monkeypatch):
    from app import material_library

    call, root = library
    assert upload(call, subjects=["Чужой предмет"]).status_code == 422
    assert upload(call, category="Чужая категория").status_code == 422
    monkeypatch.setattr(material_library, "MAX_FILE_BYTES", len(PDF))
    assert upload(call, who="admin").status_code == 201
    assert upload(call, content=iter([PDF, b"!"])).status_code == 413
    assert len(list(root.iterdir())) == 1


def test_disguised_macro_container_rejected(library):
    call, _ = library
    raw = io.BytesIO()
    with zipfile.ZipFile(raw, "w") as archive:
        archive.writestr("[Content_Types].xml", "<Types/>")
        archive.writestr("word/document.xml", "<document/>")
        archive.writestr("word/vbaProject.bin", b"VBA")
    assert (
        upload(call, filename="безопасный.docx", content=raw.getvalue()).status_code
        == 422
    )
