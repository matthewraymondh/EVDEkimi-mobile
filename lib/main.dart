import 'package:evdekimi_ai/bootstrap.dart';

/// Entry point.
///
/// All composition lives in `bootstrap()` so that tests, and any future flavour
/// entry points (`main_staging.dart`), can reuse the same startup path instead of
/// duplicating it.
void main() => bootstrap();
