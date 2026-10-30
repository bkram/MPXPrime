// The one version string in the repository. Everything else derives from it:
// `AppConfig.appVersion` (Studio: --version, the About box, the REST status),
// the Meter's About box, `scripts/version.sh` (the packagers' default version,
// the dashboard render check), and the release workflow, which refuses a tag
// that does not match this value. Bump it here and nowhere else; the
// integration branch is named after the same number (develop/v.NNN).
public enum MPXPrimeVersion {
    public static let string = "0.65"
}
