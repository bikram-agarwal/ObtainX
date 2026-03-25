import 'dart:math';

import 'package:hsluv/hsluv.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:obtainium/components/app_page_section_title.dart';
import 'package:obtainium/components/generated_form_modal.dart';
import 'package:obtainium/theme/app_form_field_styles.dart';
import 'package:obtainium/theme/app_page_icon_colors.dart';
import 'package:obtainium/providers/source_provider.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';

abstract class GeneratedFormItem {
  late String key;
  late String label;
  late List<Widget> belowWidgets;
  late dynamic defaultValue;
  List<dynamic> additionalValidators;
  dynamic ensureType(dynamic val);
  GeneratedFormItem clone();

  GeneratedFormItem(
    this.key, {
    this.label = 'Input',
    this.belowWidgets = const [],
    this.defaultValue,
    this.additionalValidators = const [],
  });
}

class GeneratedFormTextField extends GeneratedFormItem {
  late bool required;
  late int max;
  late String? hint;
  late bool password;
  late TextInputType? textInputType;
  late List<String>? autoCompleteOptions;
  GeneratedFormTextFieldAssist? assistAction;
  Widget? suffixIcon;

  GeneratedFormTextField(
    super.key, {
    super.label,
    super.belowWidgets,
    String super.defaultValue = '',
    List<String? Function(String? value)> super.additionalValidators = const [],
    this.required = true,
    this.max = 1,
    this.hint,
    this.password = false,
    this.textInputType,
    this.autoCompleteOptions,
    this.assistAction,
    this.suffixIcon,
  });

  @override
  String ensureType(val) {
    return val.toString();
  }

  @override
  GeneratedFormTextField clone() {
    return GeneratedFormTextField(
      key,
      label: label,
      belowWidgets: belowWidgets,
      defaultValue: defaultValue,
      additionalValidators: List.from(additionalValidators),
      required: required,
      max: max,
      hint: hint,
      password: password,
      textInputType: textInputType,
      autoCompleteOptions: autoCompleteOptions,
      assistAction: assistAction,
      suffixIcon: suffixIcon,
    );
  }
}

class GeneratedFormDropdown extends GeneratedFormItem {
  late List<MapEntry<String, String>>? opts;
  List<String>? disabledOptKeys;

  GeneratedFormDropdown(
    super.key,
    this.opts, {
    super.label,
    super.belowWidgets,
    String super.defaultValue = '',
    this.disabledOptKeys,
    List<String? Function(String? value)> super.additionalValidators = const [],
  });

  @override
  String ensureType(val) {
    return val.toString();
  }

  @override
  GeneratedFormDropdown clone() {
    return GeneratedFormDropdown(
      key,
      opts?.map((e) => MapEntry(e.key, e.value)).toList(),
      label: label,
      belowWidgets: belowWidgets,
      defaultValue: defaultValue,
      disabledOptKeys: disabledOptKeys != null
          ? List.from(disabledOptKeys!)
          : null,
      additionalValidators: List.from(additionalValidators),
    );
  }
}

class GeneratedFormSwitch extends GeneratedFormItem {
  bool disabled = false;
  String? labelTooltip;

  GeneratedFormSwitch(
    super.key, {
    super.label,
    super.belowWidgets,
    bool super.defaultValue = false,
    bool disabled = false,
    this.labelTooltip,
    List<String? Function(bool value)> super.additionalValidators = const [],
  });

  @override
  bool ensureType(val) {
    return val == true || val == 'true';
  }

  @override
  GeneratedFormSwitch clone() {
    return GeneratedFormSwitch(
      key,
      label: label,
      belowWidgets: belowWidgets,
      defaultValue: defaultValue,
      disabled: false,
      labelTooltip: labelTooltip,
      additionalValidators: List.from(additionalValidators),
    );
  }
}

/// Visual group title for long forms; not written to [values] or app settings.
class GeneratedFormSectionHeader extends GeneratedFormItem {
  GeneratedFormSectionHeader(
    super.key, {
    required super.label,
  }) : super(defaultValue: null, belowWidgets: const []);

  @override
  dynamic ensureType(dynamic val) => null;

  @override
  GeneratedFormSectionHeader clone() {
    return GeneratedFormSectionHeader(key, label: label);
  }
}

class GeneratedFormTagInput extends GeneratedFormItem {
  late MapEntry<String, String>? deleteConfirmationMessage;
  late bool singleSelect;
  late WrapAlignment alignment;
  late String emptyMessage;
  late bool showLabelWhenNotEmpty;
  GeneratedFormTagInput(
    super.key, {
    super.label,
    super.belowWidgets,
    Map<String, MapEntry<int, bool>> super.defaultValue = const {},
    List<String? Function(Map<String, MapEntry<int, bool>> value)>
        super.additionalValidators =
        const [],
    this.deleteConfirmationMessage,
    this.singleSelect = false,
    this.alignment = WrapAlignment.start,
    this.emptyMessage = 'Input',
    this.showLabelWhenNotEmpty = true,
  });

  @override
  Map<String, MapEntry<int, bool>> ensureType(val) {
    return val is Map<String, MapEntry<int, bool>> ? val : {};
  }

  @override
  GeneratedFormTagInput clone() {
    return GeneratedFormTagInput(
      key,
      label: label,
      belowWidgets: belowWidgets,
      defaultValue: defaultValue,
      additionalValidators: List.from(additionalValidators),
      deleteConfirmationMessage: deleteConfirmationMessage,
      singleSelect: singleSelect,
      alignment: alignment,
      emptyMessage: emptyMessage,
      showLabelWhenNotEmpty: showLabelWhenNotEmpty,
    );
  }
}

typedef OnValueChanges =
    void Function(Map<String, dynamic> values, bool valid, bool isBuilding);

typedef FormValuesTextPatch = void Function(Map<String, String> patches);

typedef GeneratedFormTextFieldAssist = Future<void> Function(
  BuildContext context,
  FormValuesTextPatch patch,
);

/// Row indices of [items] grouped by [GeneratedFormSectionHeader] starts.
List<List<int>> generatedFormSectionRowIndices(
  List<List<GeneratedFormItem>> items,
) {
  final List<List<int>> sections = <List<int>>[];
  List<int> current = <int>[];
  for (int rowIndex = 0; rowIndex < items.length; rowIndex++) {
    final List<GeneratedFormItem> row = items[rowIndex];
    final bool headerRow =
        row.length == 1 && row.first is GeneratedFormSectionHeader;
    if (headerRow) {
      if (current.isNotEmpty) {
        sections.add(current);
      }
      current = <int>[rowIndex];
    } else {
      if (current.isEmpty) {
        current = <int>[rowIndex];
      } else {
        current.add(rowIndex);
      }
    }
  }
  if (current.isNotEmpty) {
    sections.add(current);
  }
  return sections;
}

class GeneratedForm extends StatefulWidget {
  const GeneratedForm({
    super.key,
    required this.items,
    required this.onValueChanges,
    this.outlinedInputFields = false,
    this.prominentSectionHeaders = false,
    this.outlinedFieldsExternalLabels = false,
    this.wrapFormSectionsInCards = false,
  });

  final List<List<GeneratedFormItem>> items;
  final OnValueChanges onValueChanges;

  /// Rounded filled outline around text fields and dropdowns (e.g. full-screen editors).
  final bool outlinedInputFields;

  /// Stronger section titles and a bar marker instead of a thin full-width divider.
  final bool prominentSectionHeaders;

  /// When [outlinedInputFields] is true, keep labels above the field instead of inside it.
  final bool outlinedFieldsExternalLabels;

  /// Group each [GeneratedFormSectionHeader] block in an app-page style card.
  final bool wrapFormSectionsInCards;

  @override
  State<GeneratedForm> createState() => _GeneratedFormState();
}

InputDecoration _generatedFormTextFieldDecoration({
  required BuildContext context,
  required GeneratedFormTextField formItem,
  required bool outlined,
  required bool externalLabels,
}) {
  if (!outlined) {
    return InputDecoration(
      helperText: formItem.label + (formItem.required ? ' *' : ''),
      hintText: formItem.hint,
    );
  }
  if (externalLabels) {
    return appPageOutlinedInputDecoration(
      context,
      labelText: null,
      hintText: formItem.hint,
    );
  }
  return appPageOutlinedInputDecoration(
    context,
    labelText: formItem.label + (formItem.required ? ' *' : ''),
    hintText: formItem.hint,
  );
}

InputDecoration _generatedFormDropdownDecoration({
  required BuildContext context,
  required String labelText,
  required bool outlined,
  required bool externalLabels,
}) {
  if (!outlined) {
    return InputDecoration(labelText: labelText);
  }
  if (externalLabels) {
    return appPageOutlinedInputDecoration(context, labelText: null);
  }
  return appPageOutlinedInputDecoration(context, labelText: labelText);
}

List<List<GeneratedFormItem>> cloneFormItems(
  List<List<GeneratedFormItem>> items,
) {
  List<List<GeneratedFormItem>> clonedItems = [];
  for (var row in items) {
    List<GeneratedFormItem> clonedRow = [];
    for (var it in row) {
      clonedRow.add(it.clone());
    }
    clonedItems.add(clonedRow);
  }
  return clonedItems;
}

class GeneratedFormSubForm extends GeneratedFormItem {
  final List<List<GeneratedFormItem>> items;

  GeneratedFormSubForm(
    super.key,
    this.items, {
    super.label,
    super.belowWidgets,
    super.defaultValue = const [],
  });

  @override
  ensureType(val) {
    return val; // Not easy to validate List<Map<String, dynamic>>
  }

  @override
  GeneratedFormSubForm clone() {
    return GeneratedFormSubForm(
      key,
      cloneFormItems(items),
      label: label,
      belowWidgets: belowWidgets,
      defaultValue: defaultValue,
    );
  }
}

// Generates a color in the HSLuv (Pastel) color space
// https://pub.dev/documentation/hsluv/latest/hsluv/Hsluv/hpluvToRgb.html
Color generateRandomLightColor() {
  final randomSeed = Random().nextInt(120);
  // https://en.wikipedia.org/wiki/Golden_angle
  final goldenAngle = 180 * (3 - sqrt(5));
  // Generate next golden angle hue
  final double hue = randomSeed * goldenAngle;
  // Map from HPLuv color space to RGB, use constant saturation=100, lightness=70
  final List<double> rgbValuesDbl = Hsluv.hpluvToRgb([hue, 100, 70]);
  // Map RBG values from 0-1 to 0-255:
  final List<int> rgbValues = rgbValuesDbl
      .map((rgb) => (rgb * 255).toInt())
      .toList();
  return Color.fromARGB(255, rgbValues[0], rgbValues[1], rgbValues[2]);
}

int generateRandomNumber(
  int seed1, {
  int seed2 = 0,
  int seed3 = 0,
  max = 10000,
}) {
  int combinedSeed = seed1.hashCode ^ seed2.hashCode ^ seed3.hashCode;
  Random random = Random(combinedSeed);
  int randomNumber = random.nextInt(max);
  return randomNumber;
}

bool validateTextField(TextFormField tf) =>
    (tf.key as GlobalKey<FormFieldState>).currentState?.isValid == true;

/// Reads [Theme] on each rebuild so colors follow async icon-derived themes.
///
/// [GeneratedForm.initForm] runs once from [State.initState]; widgets created
/// there would otherwise keep the first frame's colors (e.g. MaterialApp)
/// after [AdditionalOptionsPage] applies icon [Theme].
class _ThemePinnedDropdownFormField extends StatelessWidget {
  const _ThemePinnedDropdownFormField({
    required this.formItem,
    required this.outlinedInputFields,
    required this.outlinedFieldsExternalLabels,
    required this.value,
    required this.onChanged,
  });

  final GeneratedFormDropdown formItem;
  final bool outlinedInputFields;
  final bool outlinedFieldsExternalLabels;
  final dynamic value;
  final void Function(dynamic newValue) onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool showExternalFieldLabels =
        outlinedInputFields && outlinedFieldsExternalLabels;
    final TextStyle? dropdownTextStyle = theme.textTheme.bodyLarge?.copyWith(
      color: scheme.onSurface,
    );
    final Widget field = DropdownButtonFormField<dynamic>(
      decoration: _generatedFormDropdownDecoration(
        context: context,
        labelText: formItem.label,
        outlined: outlinedInputFields,
        externalLabels: showExternalFieldLabels,
      ),
      dropdownColor: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      style: dropdownTextStyle,
      iconEnabledColor: scheme.onSurfaceVariant,
      iconDisabledColor: scheme.onSurface.withValues(alpha: 0.38),
      initialValue: value,
      items: formItem.opts!.map((MapEntry<String, String> option) {
        final bool enabled =
            formItem.disabledOptKeys?.contains(option.key) != true;
        return DropdownMenuItem<dynamic>(
          value: option.key,
          enabled: enabled,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Text(option.value),
          ),
        );
      }).toList(),
      onChanged: onChanged,
    );
    if (showExternalFieldLabels) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              formItem.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          field,
        ],
      );
    }
    return field;
  }
}

class _GeneratedFormState extends State<GeneratedForm> {
  final _formKey = GlobalKey<FormState>();
  Map<String, dynamic> values = {};
  late List<List<Widget>> formInputs;
  List<List<Widget>> rows = [];
  String? initKey;
  int forceUpdateKeyCount = 0;
  final Map<String, TextEditingController> _textFieldControllers = {};

  void _disposeTextFieldControllers() {
    for (final TextEditingController controller in _textFieldControllers.values) {
      controller.dispose();
    }
    _textFieldControllers.clear();
  }

  void applyTextFieldPatches(Map<String, String> patches) {
    setState(() {
      patches.forEach((String key, String value) {
        values[key] = value;
        final TextEditingController? controller = _textFieldControllers[key];
        if (controller != null) {
          controller.text = value;
        }
      });
    });
    someValueChanged();
  }

  // If any value changes, call this to update the parent with value and validity
  void someValueChanged({bool isBuilding = false, bool forceInvalid = false}) {
    Map<String, dynamic> returnValues = values;
    var valid = true;
    for (int r = 0; r < formInputs.length; r++) {
      for (int i = 0; i < formInputs[r].length; i++) {
        if (formInputs[r][i] is TextFormField) {
          valid = valid && validateTextField(formInputs[r][i] as TextFormField);
        }
      }
    }
    if (forceInvalid) {
      valid = false;
    }
    widget.onValueChanges(returnValues, valid, isBuilding);
  }

  void initForm() {
    initKey = widget.key.toString();
    _disposeTextFieldControllers();
    // Initialize form values as all empty
    values.clear();
    for (var row in widget.items) {
      for (var e in row) {
        if (e is GeneratedFormSectionHeader) continue;
        values[e.key] = e.defaultValue;
      }
    }

    // Dynamically create form inputs
    formInputs = widget.items.asMap().entries.map((row) {
      return row.value.asMap().entries.map((e) {
        var formItem = e.value;
        if (formItem is GeneratedFormSectionHeader) {
          return const SizedBox.shrink();
        } else if (formItem is GeneratedFormTextField) {
          final formFieldKey = GlobalKey<FormFieldState>();
          final String initialText = values[formItem.key]?.toString() ?? '';
          final TextEditingController ctrl =
              _textFieldControllers.putIfAbsent(
            formItem.key,
            () => TextEditingController(text: initialText),
          );
          if (ctrl.text != initialText) {
            ctrl.text = initialText;
          }
          final bool showExternalFieldLabels = widget.outlinedInputFields &&
              widget.outlinedFieldsExternalLabels;
          final _GeneratedFormState formState = this;
          final Widget typeAhead = TypeAheadField<String>(
            controller: ctrl,
            builder: (context, controller, focusNode) {
              final InputDecoration baseDecoration =
                  _generatedFormTextFieldDecoration(
                context: context,
                formItem: formItem,
                outlined: widget.outlinedInputFields,
                externalLabels: showExternalFieldLabels,
              );
              return TextFormField(
                controller: ctrl,
                focusNode: focusNode,
                keyboardType: formItem.textInputType,
                obscureText: formItem.password,
                autocorrect: !formItem.password,
                enableSuggestions: !formItem.password,
                key: formFieldKey,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                onChanged: (value) {
                  setState(() {
                    values[formItem.key] = value;
                    someValueChanged();
                  });
                },
                decoration: baseDecoration.copyWith(
                  suffixIcon: formItem.suffixIcon ??
                      (formItem.assistAction == null
                          ? null
                          : IconButton(
                              tooltip: tr('regexAssistTooltip'),
                              icon: const Icon(Icons.auto_fix_high_outlined),
                              onPressed: () async {
                                await formItem.assistAction!(
                                  context,
                                  formState.applyTextFieldPatches,
                                );
                              },
                            )),
                ),
                minLines: formItem.max <= 1 ? null : formItem.max,
                maxLines: formItem.max <= 1 ? 1 : formItem.max,
                validator: (value) {
                  if (formItem.required &&
                      (value == null || value.trim().isEmpty)) {
                    return '${formItem.label} ${tr('requiredInBrackets')}';
                  }
                  for (var validator in formItem.additionalValidators) {
                    String? result = validator(value);
                    if (result != null) {
                      return result;
                    }
                  }
                  return null;
                },
              );
            },
            itemBuilder: (context, value) {
              return ListTile(title: Text(value));
            },
            onSelected: (value) {
              ctrl.text = value;
              setState(() {
                values[formItem.key] = value;
                someValueChanged();
              });
            },
            suggestionsCallback: (search) {
              return formItem.autoCompleteOptions
                  ?.where((t) => t.toLowerCase().contains(search.toLowerCase()))
                  .toList();
            },
            hideOnEmpty: true,
          );
          if (showExternalFieldLabels) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 6),
                  child: Text(
                    formItem.label + (formItem.required ? ' *' : ''),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                typeAhead,
              ],
            );
          }
          return typeAhead;
        } else if (formItem is GeneratedFormDropdown) {
          if (formItem.opts!.isEmpty) {
            return Text(tr('dropdownNoOptsError'));
          }
          return _ThemePinnedDropdownFormField(
            formItem: formItem,
            outlinedInputFields: widget.outlinedInputFields,
            outlinedFieldsExternalLabels: widget.outlinedFieldsExternalLabels,
            value: values[formItem.key],
            onChanged: (dynamic newValue) {
              setState(() {
                values[formItem.key] = newValue ?? formItem.opts!.first.key;
                someValueChanged();
              });
            },
          );
        } else if (formItem is GeneratedFormSubForm) {
          values[formItem.key] = [];
          for (Map<String, dynamic> v
              in ((formItem.defaultValue ?? []) as List<dynamic>)) {
            var fullDefaults = getDefaultValuesFromFormItems(formItem.items);
            for (var element in v.entries) {
              fullDefaults[element.key] = element.value;
            }
            values[formItem.key].add(fullDefaults);
          }
          return Container();
        } else {
          return Container(); // Some input types added in build
        }
      }).toList();
    }).toList();
    someValueChanged(isBuilding: true);
  }

  @override
  void initState() {
    super.initState();
    initForm();
  }

  @override
  void dispose() {
    _disposeTextFieldControllers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.key.toString() != initKey) {
      initForm();
    }
    for (var r = 0; r < formInputs.length; r++) {
      for (var e = 0; e < formInputs[r].length; e++) {
        String fieldKey = widget.items[r][e].key;
        if (widget.items[r][e] is GeneratedFormSectionHeader) {
          final GeneratedFormSectionHeader header =
              widget.items[r][e] as GeneratedFormSectionHeader;
          final bool showDivider = r > 0;
          final ThemeData theme = Theme.of(context);
          final ColorScheme scheme = theme.colorScheme;
          final bool prominent = widget.prominentSectionHeaders;
          final bool inSectionCard =
              prominent && widget.wrapFormSectionsInCards;
          formInputs[r][e] = Padding(
            padding: EdgeInsets.only(
              top: showDivider
                  ? (prominent
                      ? (inSectionCard ? 2 : 20)
                      : 16)
                  : (prominent ? (inSectionCard ? 0 : 8) : 4),
              bottom: prominent ? (inSectionCard ? 6 : 10) : 6,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showDivider && !prominent) ...[
                  Divider(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: 0.55),
                  ),
                  const SizedBox(height: 12),
                ],
                if (showDivider && prominent && !inSectionCard)
                  const SizedBox(height: 4),
                if (prominent)
                  appPageCardSectionHeaderLabel(context, header.label)
                else
                  Text(
                    header.label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
              ],
            ),
          );
          continue;
        }
        if (widget.items[r][e] is GeneratedFormSwitch) {
          final GeneratedFormSwitch switchItem =
              widget.items[r][e] as GeneratedFormSwitch;
          final ColorScheme switchScheme = Theme.of(context).colorScheme;
          final Widget? switchHelpIcon =
              switchItem.labelTooltip != null &&
                      switchItem.labelTooltip!.isNotEmpty
                  ? Tooltip(
                      message: switchItem.labelTooltip!,
                      triggerMode: TooltipTriggerMode.tap,
                      waitDuration: Duration.zero,
                      showDuration: const Duration(seconds: 5),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Icon(
                          Icons.help_outline,
                          size: 20,
                          color: switchScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : null;
          formInputs[r][e] = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(switchItem.label),
                    ),
                    ...[?switchHelpIcon],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: values[fieldKey],
                onChanged: switchItem.disabled
                    ? null
                    : (value) {
                        setState(() {
                          values[fieldKey] = value;
                          someValueChanged();
                        });
                      },
              ),
            ],
          );
        } else if (widget.items[r][e] is GeneratedFormTagInput) {
          onAddPressed() {
            showDialog<Map<String, dynamic>?>(
              context: context,
              builder: (BuildContext ctx) {
                return GeneratedFormModal(
                  title: widget.items[r][e].label,
                  items: [
                    [GeneratedFormTextField('label', label: tr('label'))],
                  ],
                );
              },
            ).then((value) {
              String? label = value?['label'];
              if (label != null) {
                setState(() {
                  var temp =
                      values[fieldKey] as Map<String, MapEntry<int, bool>>?;
                  temp ??= {};
                  if (temp[label] == null) {
                    var singleSelect =
                        (widget.items[r][e] as GeneratedFormTagInput)
                            .singleSelect;
                    var someSelected = temp.entries
                        .where((element) => element.value.value)
                        .isNotEmpty;
                    temp[label] = MapEntry(
                      generateRandomLightColor().toARGB32(),
                      !(someSelected && singleSelect),
                    );
                    values[fieldKey] = temp;
                    someValueChanged();
                  }
                });
              }
            });
          }

          formInputs[r][e] = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if ((values[fieldKey] as Map<String, MapEntry<int, bool>>?)
                          ?.isNotEmpty ==
                      true &&
                  (widget.items[r][e] as GeneratedFormTagInput)
                      .showLabelWhenNotEmpty)
                Column(
                  crossAxisAlignment:
                      (widget.items[r][e] as GeneratedFormTagInput).alignment ==
                          WrapAlignment.center
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.stretch,
                  children: [
                    Text(widget.items[r][e].label),
                    const SizedBox(height: 8),
                  ],
                ),
              Wrap(
                alignment:
                    (widget.items[r][e] as GeneratedFormTagInput).alignment,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // (values[fieldKey] as Map<String, MapEntry<int, bool>>?)
                  //             ?.isEmpty ==
                  //         true
                  //     ? Text(
                  //         (widget.items[r][e] as GeneratedFormTagInput)
                  //             .emptyMessage,
                  //       )
                  //     : const SizedBox.shrink(),
                  ...(values[fieldKey] as Map<String, MapEntry<int, bool>>?)
                          ?.entries
                          .map((e2) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: ChoiceChip(
                                label: Text(e2.key),
                                backgroundColor: Color(
                                  e2.value.key,
                                ).withAlpha(50),
                                selectedColor: Color(e2.value.key),
                                visualDensity: VisualDensity.compact,
                                selected: e2.value.value,
                                onSelected: (value) {
                                  setState(() {
                                    (values[fieldKey]
                                        as Map<String, MapEntry<int, bool>>)[e2
                                        .key] = MapEntry(
                                      (values[fieldKey]
                                              as Map<
                                                String,
                                                MapEntry<int, bool>
                                              >)[e2.key]!
                                          .key,
                                      value,
                                    );
                                    if ((widget.items[r][e]
                                                as GeneratedFormTagInput)
                                            .singleSelect &&
                                        value == true) {
                                      for (var key
                                          in (values[fieldKey]
                                                  as Map<
                                                    String,
                                                    MapEntry<int, bool>
                                                  >)
                                              .keys) {
                                        if (key != e2.key) {
                                          (values[fieldKey]
                                              as Map<
                                                String,
                                                MapEntry<int, bool>
                                              >)[key] = MapEntry(
                                            (values[fieldKey]
                                                    as Map<
                                                      String,
                                                      MapEntry<int, bool>
                                                    >)[key]!
                                                .key,
                                            false,
                                          );
                                        }
                                      }
                                    }
                                    someValueChanged();
                                  });
                                },
                              ),
                            );
                          }) ??
                      [const SizedBox.shrink()],
                  (values[fieldKey] as Map<String, MapEntry<int, bool>>?)
                              ?.values
                              .where((e) => e.value)
                              .length ==
                          1
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: IconButton(
                            onPressed: () {
                              setState(() {
                                var temp =
                                    values[fieldKey]
                                        as Map<String, MapEntry<int, bool>>;
                                // get selected category str where bool is true
                                final oldEntry = temp.entries.firstWhere(
                                  (entry) => entry.value.value,
                                );
                                // generate new color, ensure it is not the same
                                int newColor = oldEntry.value.key;
                                while (oldEntry.value.key == newColor) {
                                  newColor = generateRandomLightColor().toARGB32();
                                }
                                // Update entry with new color, remain selected
                                temp.update(
                                  oldEntry.key,
                                  (old) => MapEntry(newColor, old.value),
                                );
                                values[fieldKey] = temp;
                                someValueChanged();
                              });
                            },
                            icon: const Icon(Icons.format_color_fill_rounded),
                            visualDensity: VisualDensity.compact,
                            tooltip: tr('colour'),
                          ),
                        )
                      : const SizedBox.shrink(),
                  (values[fieldKey] as Map<String, MapEntry<int, bool>>?)
                              ?.values
                              .where((e) => e.value)
                              .isNotEmpty ==
                          true
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: IconButton(
                            onPressed: () {
                              fn() {
                                setState(() {
                                  var temp =
                                      values[fieldKey]
                                          as Map<String, MapEntry<int, bool>>;
                                  temp.removeWhere((key, value) => value.value);
                                  values[fieldKey] = temp;
                                  someValueChanged();
                                });
                              }

                              if ((widget.items[r][e] as GeneratedFormTagInput)
                                      .deleteConfirmationMessage !=
                                  null) {
                                var message =
                                    (widget.items[r][e]
                                            as GeneratedFormTagInput)
                                        .deleteConfirmationMessage!;
                                showDialog<Map<String, dynamic>?>(
                                  context: context,
                                  builder: (BuildContext ctx) {
                                    return GeneratedFormModal(
                                      title: message.key,
                                      message: message.value,
                                      items: const [],
                                    );
                                  },
                                ).then((value) {
                                  if (value != null) {
                                    fn();
                                  }
                                });
                              } else {
                                fn();
                              }
                            },
                            icon: const Icon(Icons.remove),
                            visualDensity: VisualDensity.compact,
                            tooltip: tr('remove'),
                          ),
                        )
                      : const SizedBox.shrink(),
                  (values[fieldKey] as Map<String, MapEntry<int, bool>>?)
                              ?.isEmpty ==
                          true
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: TextButton.icon(
                            onPressed: onAddPressed,
                            icon: const Icon(Icons.add),
                            label: Text(
                              (widget.items[r][e] as GeneratedFormTagInput)
                                  .label,
                            ),
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: IconButton(
                            onPressed: onAddPressed,
                            icon: const Icon(Icons.add),
                            visualDensity: VisualDensity.compact,
                            tooltip: tr('add'),
                          ),
                        ),
                ],
              ),
            ],
          );
        } else if (widget.items[r][e] is GeneratedFormSubForm) {
          List<Widget> subformColumn = [];
          var compact =
              (widget.items[r][e] as GeneratedFormSubForm).items.length == 1 &&
              (widget.items[r][e] as GeneratedFormSubForm).items[0].length == 1;
          for (int i = 0; i < values[fieldKey].length; i++) {
            var internalFormKey = ValueKey(
              generateRandomNumber(
                values[fieldKey].length,
                seed2: i,
                seed3: forceUpdateKeyCount,
              ),
            );
            subformColumn.add(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!compact) const SizedBox(height: 16),
                  if (!compact)
                    Text(
                      '${(widget.items[r][e] as GeneratedFormSubForm).label} (${i + 1})',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  GeneratedForm(
                    key: internalFormKey,
                    outlinedInputFields: widget.outlinedInputFields,
                    prominentSectionHeaders: widget.prominentSectionHeaders,
                    outlinedFieldsExternalLabels:
                        widget.outlinedFieldsExternalLabels,
                    wrapFormSectionsInCards: widget.wrapFormSectionsInCards,
                    items:
                        cloneFormItems(
                              (widget.items[r][e] as GeneratedFormSubForm)
                                  .items,
                            )
                            .map(
                              (x) => x.map((y) {
                                y.defaultValue = values[fieldKey]?[i]?[y.key];
                                y.key = '${y.key.toString()},$internalFormKey';
                                return y;
                              }).toList(),
                            )
                            .toList(),
                    onValueChanges: (values, valid, isBuilding) {
                      values = values.map(
                        (key, value) => MapEntry(key.split(',')[0], value),
                      );
                      if (valid) {
                        this.values[fieldKey]?[i] = values;
                      }
                      someValueChanged(
                        isBuilding: isBuilding,
                        forceInvalid: !valid,
                      );
                    },
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                        ),
                        onPressed: (values[fieldKey].length > 0)
                            ? () {
                                var temp = List.from(values[fieldKey]);
                                temp.removeAt(i);
                                values[fieldKey] = List.from(temp);
                                forceUpdateKeyCount++;
                                someValueChanged();
                              }
                            : null,
                        label: Text(
                          '${(widget.items[r][e] as GeneratedFormSubForm).label} (${i + 1})',
                        ),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }
          subformColumn.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 0, top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        values[fieldKey].add(
                          getDefaultValuesFromFormItems(
                            (widget.items[r][e] as GeneratedFormSubForm).items,
                          ),
                        );
                        forceUpdateKeyCount++;
                        someValueChanged();
                      },
                      icon: const Icon(Icons.add),
                      label: Text(
                        (widget.items[r][e] as GeneratedFormSubForm).label,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
          formInputs[r][e] = Column(children: subformColumn);
        }
      }
    }

    rows.clear();
    formInputs.asMap().entries.forEach((rowInputs) {
      if (rowInputs.key > 0) {
        rows.add([
          SizedBox(
            height: widget.items[rowInputs.key - 1][0] is GeneratedFormSwitch
                ? 8
                : 25,
          ),
        ]);
      }
      List<Widget> rowItems = [];
      rowInputs.value.asMap().entries.forEach((rowInput) {
        if (rowInput.key > 0) {
          rowItems.add(const SizedBox(width: 20));
        }
        rowItems.add(
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                rowInput.value,
                ...widget.items[rowInputs.key][rowInput.key].belowWidgets,
              ],
            ),
          ),
        );
      });
      rows.add(rowItems);
    });

    final List<Widget> rowBars = rows
        .map(
          (row) => Row(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [...row.map((e) => e)],
          ),
        )
        .toList();

    Widget formBody;
    if (widget.wrapFormSectionsInCards) {
      final List<List<int>> sections =
          generatedFormSectionRowIndices(widget.items);
      final List<Widget> sectionCards = <Widget>[];
      for (final List<int> sectionRows in sections) {
        final List<Widget> sectionChildren = <Widget>[];
        for (int index = 0; index < sectionRows.length; index++) {
          final int rowIndex = sectionRows[index];
          if (rowIndex > 0) {
            sectionChildren.add(rowBars[2 * rowIndex - 1]);
          }
          sectionChildren.add(rowBars[2 * rowIndex]);
        }
        sectionCards.add(
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 8),
            decoration: appPageSectionCardDecoration(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: sectionChildren,
              ),
            ),
          ),
        );
      }
      formBody = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: sectionCards,
      );
    } else {
      formBody = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rowBars,
      );
    }

    return Form(
      key: _formKey,
      child: formBody,
    );
  }
}
