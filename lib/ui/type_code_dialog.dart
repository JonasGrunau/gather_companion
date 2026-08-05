import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/app_state.dart';
import '../src/pairing.dart';
import '../theme/gather_theme.dart';

/// Pairing by typing what the bridge printed, for when the camera is not an
/// option.
///
/// Two fields, because there is no relay in the middle: the code proves the person
/// was looking at the terminal, and the address says which computer to knock on. The
/// bridge prints both under the square for exactly this path.
///
/// Returns true when pairing succeeded.
Future<bool> showTypeCode(BuildContext context, AppState state) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _TypeCodeSheet(state: state),
  );
  return result ?? false;
}

class _TypeCodeSheet extends StatefulWidget {
  const _TypeCodeSheet({required this.state});

  final AppState state;

  @override
  State<_TypeCodeSheet> createState() => _TypeCodeSheetState();
}

class _TypeCodeSheetState extends State<_TypeCodeSheet> {
  final _form = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _address = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final code = normaliseCode(_code.text);
    final address = PairPayload.parseAddress(_address.text);
    if (code == null || address == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    final failure = await widget.state.pair(
      host: address.host,
      port: address.port,
      code: code,
    );
    if (!mounted) return;

    if (failure == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Padding(
      // Lifts the sheet clear of the keyboard, which otherwise covers the button
      // that submits it.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: BoxDecoration(
          color: t.popover,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: t.border)),
        ),
        padding: const EdgeInsets.fromLTRB(kGutter, 12, kGutter, 20),
        child: SafeArea(
          top: false,
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: t.ring,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text('Type the code', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Both are printed under the square.',
                  style: TextStyle(fontSize: 12.5, color: t.mutedForeground),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _code,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.next,
                  maxLength: 11, // eight characters plus the spaces people add
                  inputFormatters: [UpperCaseFormatter()],
                  style: TextStyle(
                    fontSize: 20,
                    letterSpacing: 4,
                    fontWeight: FontWeight.w600,
                    color: t.foreground,
                    fontFamilyFallback: kMonoFallback,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Code',
                    hintText: 'MAMGT98C',
                    counterText: '',
                  ),
                  validator: (value) =>
                      normaliseCode(value ?? '') == null ? 'Eight characters' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _address,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    labelText: 'Address',
                    hintText: '192.168.1.20:7799',
                  ),
                  validator: (value) => PairPayload.parseAddress(value ?? '') == null
                      ? 'Something like 192.168.1.20:7799'
                      : null,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _error!,
                    style: TextStyle(fontSize: 13, height: 1.4, color: t.danger),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Pair'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps the code field in upper case as it is typed, so it matches what is on
/// screen rather than being silently corrected later.
class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue before, TextEditingValue after) {
    return TextEditingValue(
      text: after.text.toUpperCase(),
      selection: after.selection,
      composing: TextRange.empty,
    );
  }
}
