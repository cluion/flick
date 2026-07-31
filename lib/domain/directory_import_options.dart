class DirectoryImportOptions {
  const DirectoryImportOptions({
    required this.recursive,
    required this.includeHidden,
    required this.patterns,
  });

  final bool recursive;
  final bool includeHidden;
  final List<String> patterns;
}

List<String> parseDirectoryPatterns(String value) {
  final result = <String>[];
  final seen = <String>{};
  for (final part in value.split(RegExp(r'[;,\n]'))) {
    final pattern = part.trim();
    if (pattern.isNotEmpty && seen.add(pattern.toLowerCase())) {
      result.add(pattern);
    }
  }
  return List.unmodifiable(result);
}
