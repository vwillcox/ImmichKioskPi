# Adding a dashboard widget

A widget is a Flutter widget plus a `DashboardWidgetType` describing it.
Nothing else in the app needs changing: the browser editor builds its palette
and its settings form from that descriptor, and the saved configuration keeps
the options as an opaque bag.

## 1. Write the widget

```dart
class TideWidget extends StatelessWidget {
  const TideWidget({super.key, required this.w});
  final DashboardWidgetContext w;

  @override
  Widget build(BuildContext context) {
    // w.theme  — colours, corner radius, fonts for the chosen theme
    // w.option — a setting, with the type's default as the fallback
    final port = w.option('port', 'Harwich');
    return Text(port, style: TextStyle(color: w.theme.textPrimary));
  }
}
```

Read settings through `w.option(key, fallback)` rather than `w.config.options`
directly, so a dashboard saved before an option existed still behaves.

Draw with `w.theme`. A widget that hard-codes colours looks wrong in four of
the five shipped themes and in every one written later.

## 2. Describe it

```dart
final tideWidgetType = DashboardWidgetType(
  type: 'tide',                    // stored in the config — never rename in place
  name: 'Tide times',
  description: 'High and low water for a port.',
  glyph: '🌊',                      // shown in the editor's palette
  defaultWidth: 3, defaultHeight: 2,
  minWidth: 2, minHeight: 2,
  options: const [
    WidgetOption(
      key: 'port',
      label: 'Port',
      defaultValue: 'Harwich',
      help: 'Say what the setting is for, not what it is.',
    ),
  ],
  build: (context, w) => TideWidget(w: w),
);
```

`OptionKind` covers `text`, `multiline`, `number`, `boolean` and `choice`
(with `choices: {'value': 'Label'}`).

## 3. Register it

Add it to the list in `widgets.dart`. That is the whole integration.

## Fetching things

Widgets are rebuilt often — whenever the clock ticks, a track changes, or
anything else on the dashboard updates. Never fetch in `build`. For feeds,
use `FeedService`, which caches by URL, serves stale content while
refreshing, and shares one fetch between widgets pointed at the same address.

## Removing one

Deleting a type leaves any saved widget of that type in the configuration.
The dashboard draws it as "Unknown widget" and keeps its settings, so
reinstating the widget later brings it back intact rather than losing the
setup.
