# Chooses the artifact store from deploy/target.env.
. scripts/lib/storage.sh

push_artifact() {
  store=$(read_target ARTIFACT_STORE)
  case "$store" in
    s3) upload_s3 "$1" ;;
    gcs) upload_gcs "$1" ;;
    *) upload_local "$1" ;;
  esac
}
