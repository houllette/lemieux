profile = Lemieux.Learning.Builder.profile(System.fetch_env!("LMX_MODEL"))

profile =
  if System.get_env("BUILDER_USAGE_MODE") == "quota" do
    requests = System.get_env("BUILDER_REQUESTS_PER_ATTEMPT", "12") |> String.to_integer()
    Lemieux.Extension.Profile.quota(profile, requests)
  else
    reservation = System.fetch_env!("BUILDER_ATTEMPT_CAP_USD") |> String.to_float()
    put_in(profile, ["options", "max_cost_usd"], reservation)
  end

[
  source: File.cwd!(),
  profile: profile
]
