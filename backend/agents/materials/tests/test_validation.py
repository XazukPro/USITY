import unittest
from copy import deepcopy

from backend.agents.materials import MaterialValidationError, validate_material_proposal


def event():
    return {
        "group_id": "group-a",
        "chat_id": -100123,
        "connected_chat_id": -100123,
        "topic_id": 11,
        "connected_topic_id": 11,
        "messages": [
            {
                "id": 41, "chat_id": -100123, "topic_id": 11,
                "text": "Учебник по матану и физике",
                "attachments": [
                    {"id": "pdf-1", "kind": "file", "file_name": "book.pdf", "mime_type": "application/pdf", "size_bytes": 1_000_000},
                    {"id": "photo-1", "kind": "photo", "mime_type": "image/jpeg", "size_bytes": 200_000},
                ],
            },
            {"id": 42, "chat_id": -100123, "topic_id": 11, "text": "Слайды: https://example.org/slides", "attachments": []},
        ],
        "subjects": [{"id": "math"}, {"id": "physics"}],
        "assignments": [{"id": "hw-1", "subject_id": "math"}],
        "categories": [{"id": "books"}, {"id": "lectures"}, {"id": "custom-labs"}],
    }


def proposal():
    return {
        "kind": "material", "source_message_ids": [41],
        "material_type": "file", "attachment_id": "pdf-1", "link_url": None,
        "category_id": "books", "subject_ids": ["math", "physics"],
        "assignment_ids": ["hw-1"], "uncertain": False,
        "reason": "Учебник указан в сообщении",
    }


class MaterialValidationTests(unittest.TestCase):
    def test_supported_pdf_with_custom_catalog_and_multiple_subjects(self):
        source, candidate = event(), proposal()
        candidate["category_id"] = "custom-labs"
        original = deepcopy(candidate)
        checked = validate_material_proposal(source, candidate)
        self.assertEqual(checked["category_id"], "custom-labs")
        self.assertEqual(checked["subject_ids"], ["math", "physics"])
        self.assertEqual(candidate, original)

    def test_photo_without_filename_and_link_in_second_message(self):
        candidate = proposal()
        candidate["attachment_id"] = "photo-1"
        self.assertEqual(validate_material_proposal(event(), candidate)["attachment_id"], "photo-1")
        candidate.update({"source_message_ids": [42], "material_type": "link", "attachment_id": None,
                          "link_url": "https://example.org/slides", "category_id": "lectures",
                          "assignment_ids": []})
        self.assertEqual(validate_material_proposal(event(), candidate)["link_url"], "https://example.org/slides")

    def test_link_attachment_is_valid_source(self):
        source, candidate = event(), proposal()
        source["messages"][1]["text"] = "Материал к паре"
        source["messages"][1]["attachments"] = [
            {"id": "link-1", "kind": "link", "url": "https://example.org/slides"}
        ]
        candidate.update({"source_message_ids": [42], "material_type": "link", "attachment_id": None,
                          "link_url": "https://example.org/slides", "assignment_ids": []})
        self.assertEqual(validate_material_proposal(source, candidate)["link_url"], "https://example.org/slides")

    def test_other_chat_or_topic_is_rejected(self):
        for field, value in (("chat_id", -100999), ("topic_id", 99)):
            source = event()
            source["messages"][0][field] = value
            with self.subTest(field=field), self.assertRaises(MaterialValidationError):
                validate_material_proposal(source, proposal())

    def test_file_size_and_type_are_rejected(self):
        for change in ({"size_bytes": 100_000_001}, {"mime_type": "video/mp4"},
                       {"file_name": "movie.mp4"}, {"file_name": "book.pdf", "mime_type": "image/png"}):
            source = event()
            source["messages"][0]["attachments"][0].update(change)
            with self.subTest(change=change), self.assertRaises(MaterialValidationError):
                validate_material_proposal(source, proposal())

    def test_file_must_appear_in_cited_message(self):
        candidate = proposal()
        candidate["source_message_ids"] = [42]
        with self.assertRaises(MaterialValidationError):
            validate_material_proposal(event(), candidate)

    def test_unknown_references_and_cross_subject_assignment_are_rejected(self):
        for field, value in (("source_message_ids", [999]), ("category_id", "unknown"),
                             ("subject_ids", ["unknown"]), ("assignment_ids", ["unknown"]),
                             ("subject_ids", ["physics"])):
            candidate = proposal()
            candidate[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(MaterialValidationError):
                validate_material_proposal(event(), candidate)

    def test_unknown_fields_require_uncertainty(self):
        candidate = proposal()
        candidate.update({"category_id": None, "subject_ids": None, "assignment_ids": None})
        with self.assertRaises(MaterialValidationError):
            validate_material_proposal(event(), candidate)
        candidate["uncertain"] = True
        checked = validate_material_proposal(event(), candidate)
        self.assertIsNone(checked["subject_ids"])

    def test_extra_fields_and_untrusted_link_are_rejected(self):
        candidate = proposal()
        candidate["publish"] = True
        with self.assertRaises(MaterialValidationError):
            validate_material_proposal(event(), candidate)
        candidate = proposal()
        candidate.update({"source_message_ids": [42], "material_type": "link", "attachment_id": None,
                          "link_url": "https://other.example/", "assignment_ids": []})
        with self.assertRaises(MaterialValidationError):
            validate_material_proposal(event(), candidate)
        candidate["link_url"] = "https://example.org/slide"
        with self.assertRaises(MaterialValidationError):
            validate_material_proposal(event(), candidate)


if __name__ == "__main__":
    unittest.main()
