import re

from api.errors import DuplicateEmail, InvalidEmail
from api.repo import repo

EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def create_user(payload):
    email = payload.get("email", "")
    if not EMAIL.match(email):
        raise InvalidEmail(email)
    if repo.exists(email):
        raise DuplicateEmail(email)
    user = repo.insert(email, payload.get("name", ""))
    return {"id": user["id"], "email": user["email"]}, 201
