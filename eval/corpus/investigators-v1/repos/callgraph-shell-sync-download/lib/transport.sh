# Transport implementations. Only one is wired up at a time.
download_with_curl() {
  curl -fsSL --retry 0 -o "$2" "$1"
}

download_with_wget() {
  wget -q -O "$2" "$1"
}
