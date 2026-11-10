from demo_review import demonstrate


def test_demo_covers_admin_publication_and_individual_completion(tmp_path):
    result = demonstrate(f"sqlite:///{tmp_path}/demo.db")
    assert result["before_review"] == 0
    assert result["after_review"] == 1
    assert result["after_my_completion"] == 0
    assert result["other_student"] == 1
