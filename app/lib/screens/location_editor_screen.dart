import 'package:flutter/material.dart';

import '../core/api/api_exception.dart';
import '../core/api/api_scope.dart';
import '../core/auth/auth_messages.dart';
import '../core/session/session_scope.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_tokens.dart';
import '../models/location.dart';
import '../widgets/primary_button.dart';

class LocationEditorScreen extends StatefulWidget {
  const LocationEditorScreen({super.key, this.location});

  final Location? location;

  @override
  State<LocationEditorScreen> createState() => _LocationEditorScreenState();
}

class _LocationEditorScreenState extends State<LocationEditorScreen> {
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();

  bool _submitting = false;
  String? _formError;

  bool get _isEditing => widget.location != null;

  @override
  void initState() {
    super.initState();
    final location = widget.location;
    if (location != null) {
      _nameController.text = location.name;
      _addressController.text = location.address;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;

    final name = _nameController.text.trim();
    final address = _addressController.text.trim();

    if (name.isEmpty) {
      setState(() => _formError = 'Въведете име на пункта.');
      return;
    }
    if (name.length > 120) {
      setState(() => _formError = 'Името може да е до 120 знака.');
      return;
    }
    if (address.isEmpty) {
      setState(() => _formError = 'Въведете адрес на пункта.');
      return;
    }
    if (address.length > 255) {
      setState(() => _formError = 'Адресът може да е до 255 знака.');
      return;
    }

    final session = SessionScope.maybeOf(context);
    final token = session?.session?.token;
    if (token == null) {
      setState(() => _formError = AuthMessages.forCode('UNAUTHORIZED'));
      return;
    }
    final api = ApiScope.maybeOf(context);
    if (api == null) {
      setState(() => _formError = AuthMessages.fallback);
      return;
    }

    setState(() {
      _submitting = true;
      _formError = null;
    });

    try {
      final Location result;
      if (_isEditing) {
        result = await api.updateLocation(
          widget.location!.id,
          name: name,
          address: address,
          token: token,
        );
      } else {
        result = await api.createLocation(
          name: name,
          address: address,
          token: token,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        session?.handleUnauthorized();
      }
      setState(() {
        _submitting = false;
        _formError = AuthMessages.forException(error);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _formError = AuthMessages.fallback;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Редактиране на пункт' : 'Нов пункт'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.spaceLg),
          children: [
            TextFormField(
              key: const Key('location-name-field'),
              controller: _nameController,
              enabled: !_submitting,
              maxLength: 120,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Име на пункта'),
            ),
            const SizedBox(height: AppTokens.spaceMd),
            TextFormField(
              key: const Key('location-address-field'),
              controller: _addressController,
              enabled: !_submitting,
              maxLength: 255,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: 'Адрес'),
            ),
            if (_formError != null) ...[
              const SizedBox(height: AppTokens.spaceLg),
              Text(
                _formError!,
                key: const Key('location-form-error'),
                style: const TextStyle(
                  color: AppColors.error,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: AppTokens.spaceXl),
            PrimaryButton(
              label: _isEditing ? 'Запази промените' : 'Създай пункт',
              icon: _isEditing ? Icons.save_outlined : Icons.add,
              busy: _submitting,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
