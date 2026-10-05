class Repo:
    def first(self, n):
        return [{"id": i} for i in range(1, n + 1)]


repo = Repo()
