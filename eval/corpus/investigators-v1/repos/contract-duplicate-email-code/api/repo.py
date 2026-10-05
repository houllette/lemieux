class Repo:
    def __init__(self):
        self.users = {}

    def exists(self, email):
        return email.lower() in self.users

    def insert(self, email, name):
        user = {"id": len(self.users) + 1, "email": email, "name": name}
        self.users[email.lower()] = user
        return user


repo = Repo()
