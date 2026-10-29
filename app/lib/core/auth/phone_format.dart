/// Bulgarian phone normalisation mirroring the backend rules.
///
/// Accepted inputs: `+359XXXXXXXXX`, `00359XXXXXXXXX`, `0XXXXXXXXX`, with
/// optional spaces, hyphens and parentheses. Canonical output is
/// `+359` + 9 digits, where the first national digit is 2–9. The backend
/// remains the authoritative validator.
abstract class PhoneFormat {
  static const String example = '0888123456';

  static final RegExp _separators = RegExp(r'[\s\-()]');
  static final RegExp _digitsOnly = RegExp(r'^\+?\d+$');
  static final RegExp _canonical = RegExp(r'^\+359[2-9]\d{8}$');

  static String? tryNormalize(String input) {
    final compact = input.replaceAll(_separators, '');
    if (compact.isEmpty || !_digitsOnly.hasMatch(compact)) return null;

    final String national;
    if (RegExp(r'^\+359\d{9}$').hasMatch(compact)) {
      national = compact.substring(4);
    } else if (RegExp(r'^00359\d{9}$').hasMatch(compact)) {
      national = compact.substring(5);
    } else if (RegExp(r'^0\d{9}$').hasMatch(compact)) {
      national = compact.substring(1);
    } else {
      return null;
    }

    final canonical = '+359$national';
    return _canonical.hasMatch(canonical) ? canonical : null;
  }

  static bool isValid(String input) => tryNormalize(input) != null;
}
