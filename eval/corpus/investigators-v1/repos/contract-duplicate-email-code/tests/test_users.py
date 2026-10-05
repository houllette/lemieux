from api.app import App


def test_duplicate_email_is_a_conflict():
    app = App()
    app.handle("POST", "/users", {"email": "a@example.com", "name": "A"})
    _body, status = app.handle("POST", "/users", {"email": "a@example.com", "name": "A"})
    assert status == 409
