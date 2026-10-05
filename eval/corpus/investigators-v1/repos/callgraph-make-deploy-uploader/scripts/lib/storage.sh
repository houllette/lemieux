# Storage backends.
upload_s3() {
  aws s3 cp "$1" "s3://$(read_target S3_BUCKET)/$(basename "$1")"
}

upload_gcs() {
  gsutil cp "$1" "gs://$(read_target GCS_BUCKET)/$(basename "$1")"
}

upload_local() {
  cp "$1" "/var/artifacts/$(basename "$1")"
}
