import uuid

from middleware import HEADERS


def request_id(request, response):
    response.headers[HEADERS["request_id_header"]] = request.headers.get(
        HEADERS["request_id_header"], str(uuid.uuid4())
    )
    return response
