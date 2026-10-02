/// Order of two firmware versions (`esp_app_desc_t.version`, from
/// `firmware/VERSION`): semver `MAJOR.MINOR.PATCH[-PRE]`, a pre-release
/// sorts before its release (`0.1.1-dev` < `0.1.1`). A leading `v` is
/// ignored. Something that is not semver sorts before every semver and,
/// among itself, by its text — never an exception.
///
/// Negative when [a] is older than [b], zero when equal, positive when newer.
int compareFirmwareVersions(String a, String b) {
  final pa = _parse(a), pb = _parse(b);
  if (pa == null || pb == null) {
    if (pa != null) return 1;
    if (pb != null) return -1;
    return a.compareTo(b);
  }
  for (var i = 0; i < 3; i++) {
    final c = pa.core[i].compareTo(pb.core[i]);
    if (c != 0) return c;
  }
  if (pa.pre == pb.pre) return 0;
  if (pa.pre.isEmpty) return 1;
  if (pb.pre.isEmpty) return -1;
  return pa.pre.compareTo(pb.pre);
}

({List<int> core, String pre})? _parse(String raw) {
  var s = raw.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  final dash = s.indexOf('-');
  final core = dash < 0 ? s : s.substring(0, dash);
  final pre = dash < 0 ? '' : s.substring(dash + 1);
  final parts = core.split('.');
  if (parts.length != 3) return null;
  final nums = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0) return null;
    nums.add(n);
  }
  return (core: nums, pre: pre);
}
